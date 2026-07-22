//  CoachSession.swift
//  AICam — 教練 session 中樞（A5；跨模組契約 surface，UI 讀這裡）。
//
//  資料流（MASTER-PLAN §3；品質大修輪重接）：
//  VideoFrameTap（analysisQueue，~15fps）→ FrameAnalyzer → FrameFacts
//    → CoachPipeline（同 queue：L1 引擎 evaluate → TargetSolver.solve →
//       錨點 OneEuroFilter2D → StickyTargetPlanner 承諾目標（凍結；A1 契約：
//       平滑錨點先進 planner）→ GuidanceTracker 鎖定判斷 → AdviceStabilizer →
//       ScoreSmoother）
//    → Task { @MainActor } 一次發布全部 @Observable 屬性（渲染與分析解耦）。
//
//  飄移根治（本輪核心）：
//  - targetPoint 來自 StickyTargetPlanner「承諾後」的目標 — 對齊期間絕不動、
//    絕不再對 target 做任何平滑（凍結本身就是最強穩定）。舊版把 target 跟著
//    主體位置逐帧重算＝「追會跑的靶」，已根治。
//  - anchorPoint 過 One-Euro 濾波：近靜止強力去抖、快速移動低延遲跟上。
//  - PointSmoother（Core）App 端不再使用（Core 檔不動）。
//
//  - 鎖定（.locked）轉變邊緣觸發一次 UINotificationFeedbackGenerator.success。
//  - 自動抓拍：coach.autoCapture 開 && result.shouldAutoCapture && lockState == .locked
//    （承諾目標的鎖定）&& 距上次自動拍 ≥ 3s（media timestamp 防抖）→ camera.capturePhoto()。
//    （v1 簡化：單張、無 gyro 穩定度／臉部銳利度檢查；MASTER-PLAN §4.7 的
//    「靜音連拍 3 張進 Session」屬 P4/P5，後續執行者勿誤以為已完成。）
//  - 熱降級：thermalState ≥ .serious → 分析間隔 0.25s + 停 body pose（thermalReduced 發布）。
//  - 重置時機：進出教練模式（setActive）、flipCamera 完成、鏡位切換
//    （camera.onCameraReconfigured）→ planner/One-Euro/tracker/stabilizer 全重置。
//  - snapshotJPEG(maxDimension:)：最新分析帧同步轉 JPEG（Gemini 導演即時模式取帧用）。
//
//  v0.3.0 Reframe 模型整合（A1；MASTER-PLAN §4.3b / §4.6）：
//  - CoachPipeline 內 lazy 建 ReframeScorer（首個模型 tick 於 analysisQueue 觸發；
//    init 失敗 = 無模型，全程規則路徑，不 crash 不重試）。
//  - 節奏：每 3 次分析 tick 跑一次（~5fps）；取 %3==2 與 FrameAnalyzer 的
//    body pose tick（%3==1，兩計數器同事件重置、近似同步）錯開，不疊峰。
//    AppStorage "coach.model.enabled"（預設 true）關閉或熱降級 ≥ .serious 時停跑。
//  - 取帧：VideoFrameTap.latestAnalysisBuffer() 直取當帧 buffer 餵
//    ReframeScorer.score(_:)（onFacts 同 queue 同步呼叫，latestPixelBuffer
//    恰為本帧；v0.3.0 修正輪已捨棄 snapshotJPEG(448) 的 JPEG 繞路）。
//  - 分數混合（§4.6）：模型分未過期（≤1s）→ 0.6×規則分 + 0.4×score01×100，
//    混合「先於」ScoreSmoother EMA（分數環不跳；§4.6 的 EMA 是獨立穩定層）；
//    否則純規則分。發布 modelActive 供 UI 顯示「AI 構圖模型」啟用狀態。
//  - 模型建議（保守）：dzoom > 0.25 且本帧規則候選為 nil 且未鎖定 →
//    「退後兩步」（.distance, priority 20）進 stabilizer。修正 = −delta，
//    dzoom>0 = 退後；dzoom 訓練標籤恆 ≥0，負/小值不可解讀成上前。
//    dx/dy 本輪不驅動 UI（黏性目標語意不可破壞），只記 os_log（category "reframe"）。
//
//  待真機驗證（發布頻率 ~15fps；facts 屬性只有教練 overlay 應讀取，見檔尾註記）。

import CoreVideo
import Foundation
import Observation
import UIKit
import os
import AICamCore

@MainActor
@Observable
final class CoachSession {

    // MARK: - 對外發布（跨模組契約）

    private(set) var facts: FrameFacts?
    private(set) var result: CompositionResult?
    private(set) var guidance: TargetGuidance?
    /// One-Euro 平滑後主體錨點（NormalizedFrame）。A3 overlay 畫錨點讀這裡。
    private(set) var anchorPoint: NPoint?
    /// StickyTargetPlanner 承諾後的固定目標：對齊期間絕不動（凍結語意，
    /// 不做任何平滑）。A3 overlay 畫目標環讀這裡。
    private(set) var targetPoint: NPoint?
    /// 承諾目標的鎖定狀態（GuidanceTracker 遲滯 + dwell）。
    private(set) var lockState: LockState = .searching
    /// 平滑錨點到承諾目標的歐氏距離（normalized）；無解時 nil。
    private(set) var alignDistance: Double?
    /// 已過 AdviceStabilizer 的顯示建議（防箭頭閃爍）。
    private(set) var advice: CoachAdvice?
    /// 分數 EMA（alpha 0.25）。
    private(set) var smoothedScore: Double = 0
    /// smoothedScore 的整數版：只在整數值變化時才寫入 —
    /// RootView（快門外圈）讀這個，避免大型 view body 以 ~15fps 重算 diff（見檔尾註記）。
    private(set) var displayScore: Int = 0
    /// 分析 buffer 的直立寬高比（寬/高；預設 3:4）。CoachOverlayView 的
    /// AspectFillMapper 取代寫死比例用；僅在收到有效直立帧時更新。
    private(set) var contentAspect: Double = 3.0 / 4.0
    /// 最近 10 次分析間隔倒數的平均。
    private(set) var analysisFPS: Double = 0
    private(set) var thermalReduced: Bool = false
    /// Reframe 構圖模型此刻是否參與評分（契約：UI 顯示「AI 構圖模型」啟用狀態）。
    /// true = 模型已載入且最近一次模型分未過期（≤1s）正在混入 displayScore。
    /// 只在值變化時寫入（@Observable 逐屬性追蹤）。
    private(set) var modelActive: Bool = false

    // MARK: - 內部

    @ObservationIgnored private let camera: CameraController
    /// v0.3.0 修正輪：tap 改由 CameraController 擁有（camera.videoTap）——
    /// session 只能掛一顆 AVCaptureVideoDataOutput，教練分析與 MetalPreviewView
    /// 的即時濾鏡預覽必須共用同一實例。
    @ObservationIgnored private let tap: VideoFrameTap
    @ObservationIgnored private let pipeline = CoachPipeline()
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var hasAttachedTap = false
    @ObservationIgnored private var wasLocked = false
    /// 最新發布世代（MainActor）：resetGuidance / setActive(true) 時取
    /// pipeline.scheduleReset() 的回傳值。publish 比對 Output.generation —
    /// 重置前已進入處理、尚在 Task 佇列的舊座標帧一律丟棄
    /// （否則清空後的發布會被舊環蓋回新畫面 ~1 帧）。
    @ObservationIgnored private var expectedGeneration = 0
    @ObservationIgnored private var lastAutoCaptureAt: Double = -.greatestFiniteMagnitude
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private let lockHaptics = UINotificationFeedbackGenerator()

    init(camera: CameraController) {
        self.camera = camera
        self.tap = camera.videoTap

        let pipeline = self.pipeline
        // Reframe 模型 tick 的取帧出口（啟用前設定一次；analysisQueue 上呼叫）。
        // 必須 weak tap：tap → onFacts 閉包 → pipeline → provider → tap 會成環。
        // onFacts 於 captureOutput 內同 queue 同步呼叫 → latestPixelBuffer 恰為本帧。
        // v0.3.0 修正輪：直餵 buffer（scorer.score(_:)），不再繞 snapshotJPEG(448)
        // 的 JPEG 編解碼（省 3–8ms/tick，且不引入與訓練分佈無關的壓縮噪聲）。
        let tap = self.tap
        pipeline.frameBufferProvider = { [weak tap] in
            tap?.latestAnalysisBuffer()
        }
        tap.onFacts = { [weak self] facts, bufferWidth, bufferHeight in
            // analysisQueue：pipeline 狀態只在此 queue 觸碰
            let output = pipeline.process(facts)
            Task { @MainActor in
                self?.publish(output, bufferWidth: bufferWidth, bufferHeight: bufferHeight)
            }
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyThermalPolicy()
            }
        }
        applyThermalPolicy()

        // 前後鏡切換完成／鏡位切換 = 取景座標整體跳變 → 全導引管線重置
        // （planner 承諾目標、One-Euro、tracker、stabilizer 都不得帶舊座標）
        camera.onCameraReconfigured = { [weak self] in
            self?.resetGuidance()
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    // MARK: - 開關（契約）

    /// true：向 camera 掛 video tap（僅第一次）+ CoreMotion 啟動 + 開始分析；
    /// false：停分析（tap 丟帧）+ motion 停 + 清空發布狀態。
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if !hasAttachedTap {
                hasAttachedTap = true
                camera.attachVideoTap(tap)
            }
            // tap connection 恢復出帧（sessionQueue 序列化，恆排在 attach 之後）
            camera.setVideoTapEnabled(true)
            expectedGeneration = pipeline.scheduleReset()
            tap.analyzer.scheduleReset()
            applyThermalPolicy()
            tap.analyzer.startMotion()
            tap.setActive(true)
            lockHaptics.prepare()
            wasLocked = false
        } else {
            tap.setActive(false)
            tap.analyzer.stopMotion()
            // 停 connection 出帧：離開教練模式不再付 30fps 資料流／功耗成本
            camera.setVideoTapEnabled(false)
            facts = nil
            result = nil
            guidance = nil
            anchorPoint = nil
            targetPoint = nil
            lockState = .searching
            alignDistance = nil
            advice = nil
            smoothedScore = 0
            displayScore = 0
            analysisFPS = 0
            modelActive = false
            wasLocked = false
        }
    }

    /// 相機重配（flipCamera / 鏡位切換）後：排程分析管線 + 分析器快取重置、
    /// 立即清空導引發布狀態，並推進發布世代（重置前已在處理的舊帧
    /// publish 時被世代比對丟棄 — 不讓舊環在新畫面上多留一帧）。
    private func resetGuidance() {
        expectedGeneration = pipeline.scheduleReset()
        tap.analyzer.scheduleReset()
        guidance = nil
        anchorPoint = nil
        targetPoint = nil
        lockState = .searching
        alignDistance = nil
        wasLocked = false
    }

    /// 最新分析帧轉 JPEG（同步；教練未啟用或尚無帧時 nil）。導演即時模式取帧用。
    func snapshotJPEG(maxDimension: CGFloat) -> Data? {
        tap.snapshotJPEG(maxDimension: maxDimension)
    }

    /// snapshotJPEG 的非阻塞版：主執行緒只取 buffer 引用，
    /// CIContext 縮放 + JPEG 編碼在背景執行（避免導演即時模式每 10 秒卡取景 UI）。
    func snapshotJPEGAsync(maxDimension: CGFloat) async -> Data? {
        await tap.snapshotJPEGAsync(maxDimension: maxDimension)
    }

    // MARK: - 發布（MainActor）

    private func publish(_ output: CoachPipeline.Output, bufferWidth: Int, bufferHeight: Int) {
        // 世代比對：重置（切鏡/翻鏡/重啟）前已開始處理的帧帶舊座標 → 丟棄。
        guard isActive, output.generation == expectedGeneration else { return }
        facts = output.facts
        result = output.result
        guidance = output.guidance
        advice = output.advice
        smoothedScore = output.smoothedScore
        analysisFPS = output.analysisFPS

        // 契約新 surface：anchor/distance 逐帧變、直接寫；
        // target（凍結）與 lockState 少變 → 只在值變化時寫入
        // （@Observable 逐屬性追蹤：不寫就不觸發讀取端 diff）
        anchorPoint = output.guidance.anchor
        alignDistance = output.guidance.normalizedDistance
        if output.guidance.target != targetPoint {
            targetPoint = output.guidance.target
        }
        if output.guidance.lockState != lockState {
            lockState = output.guidance.lockState
        }

        // 整數分數只在值變化時寫入（@Observable 逐屬性追蹤：不寫就不觸發 diff）
        let score = Int(output.smoothedScore.rounded())
        if score != displayScore {
            displayScore = score
        }
        // 模型參與狀態（少變 → 只在值變化時寫入）
        if output.modelActive != modelActive {
            modelActive = output.modelActive
        }
        // 實際 buffer 比例（僅接受直立帧：橫向 = 旋轉未生效，維持前值不畫錯）
        if bufferWidth > 0, bufferHeight >= bufferWidth {
            let aspect = Double(bufferWidth) / Double(bufferHeight)
            if aspect != contentAspect {
                contentAspect = aspect
            }
        }

        // 鎖定轉變邊緣觸發一次 haptic（success）
        let locked = output.guidance.lockState == .locked
        if locked && !wasLocked {
            lockHaptics.notificationOccurred(.success)
            lockHaptics.prepare()
        }
        wasLocked = locked

        maybeAutoCapture(output: output, locked: locked)

        // AI 代操曝光（v0.3.0 契約：CoachSession 每次 publish 後呼叫；同在
        // MainActor）。enabled 開關與 camera 接線檢查都在 evaluate 內部。
        AIControlCenter.shared.evaluate(facts: output.facts)
    }

    private func maybeAutoCapture(output: CoachPipeline.Output, locked: Bool) {
        // @AppStorage 在 @Observable class 內不可靠 → 直讀 UserDefaults（預設 false）
        guard UserDefaults.standard.bool(forKey: "coach.autoCapture"),
              output.result.shouldAutoCapture,
              locked,
              output.facts.timestamp - lastAutoCaptureAt >= 3
        else { return }
        lastAutoCaptureAt = output.facts.timestamp
        Task { await camera.capturePhoto() }
    }

    // MARK: - 熱降級（F30）

    private func applyThermalPolicy() {
        let state = ProcessInfo.processInfo.thermalState
        let reduced = state == .serious || state == .critical
        thermalReduced = reduced
        // 正常 0.066s ≈ 15fps（提速輪 0.1 → 0.066）；熱降級 0.25s + 停 body pose
        tap.setMinAnalysisInterval(reduced ? 0.25 : 0.066)
        tap.analyzer.setBodyPoseEnabled(!reduced)
    }
}

// MARK: - CoachPipeline（分析 queue 專屬）

/// 引擎／求解／平滑／追蹤管線。狀態只在 analysisQueue 觸碰
/// （scheduleReset 例外：跨執行緒旗標，鎖保護，下一次 process 時在分析 queue 上執行重置）。
private final class CoachPipeline {

    struct Output: Sendable {
        var facts: FrameFacts
        var result: CompositionResult
        var guidance: TargetGuidance
        var advice: CoachAdvice?
        var smoothedScore: Double
        var analysisFPS: Double
        /// Reframe 模型此帧是否參與評分混合（模型已載入且模型分未過期 ≤1s）。
        var modelActive: Bool
        /// 本帧開始處理時的發布世代（scheduleReset 每次 +1）。
        /// CoachSession.publish 比對最新世代 — 重置「前」已在處理的舊座標帧
        /// 抵達 MainActor 時世代已過期 → 丟棄，杜絕清空後被舊帧蓋回 ~1 帧。
        var generation: Int
    }

    private let engine = RuleCompositionEngine()
    private let config = ScoringConfig.standard
    private let stabilizer = AdviceStabilizer()
    private var scoreSmoother = ScoreSmoother(alpha: 0.25)
    /// 錨點 One-Euro 濾波（A1）：近靜止強力去抖、快速移動低延遲。
    /// beta 必須配 OneEuroFilter 檔頭的速度尺度（畫面/秒；預設 20）— 舊值 0.25
    /// 低了 ~80 倍，快速重構圖時 fc 只升到 <1 Hz，退化成固定延遲 EMA（用戶
    /// 抱怨的「很慢」）。手算（15fps、dt=1/15）：v=0.05 畫面/秒（慢速微調）→
    /// fc = 0.6 + 15×0.05 = 1.35 Hz（α≈0.36，仍濾抖）；v=1.0（快速重構圖）→
    /// fc = 15.6 Hz（r = 2π×15.6/15 = 6.53、α = 6.53/7.53 ≈ 0.87，幾乎即時跟上）。
    /// minCutoff 0.6 維持靜止穩定。待真機微調。
    private let anchorFilter = OneEuroFilter2D(minCutoff: 0.6, beta: 15.0, dCutoff: 1.0)
    /// 目標承諾規劃器（A1）：目標一經承諾即凍結，換側需遲滯＋停留 —
    /// 根治「目標跟著主體逐帧重算 = 追會跑的靶」。target 絕不再過任何平滑。
    private let planner = StickyTargetPlanner()
    private let tracker = GuidanceTracker()
    private var recentIntervals: [Double] = []
    private var lastTimestamp: Double?

    // MARK: Reframe 模型（v0.3.0；analysisQueue 專屬）

    /// 模型 tick 取帧來源（CoachSession 啟用前設定一次；analysisQueue 上呼叫）。
    /// 回傳當帧 CVPixelBuffer（VideoFrameTap.latestAnalysisBuffer；onFacts 同
    /// queue 同步呼叫 → 恰為本帧）。v0.3.0 修正輪：取代 JPEG 繞路直餵 scorer。
    var frameBufferProvider: (() -> CVPixelBuffer?)?
    /// dx/dy 本輪只記 log 不驅動 UI（黏性目標語意不可破壞）。
    private static let reframeLog = Logger(subsystem: "com.arieswu.aicam", category: "reframe")
    /// 分析 tick 計數（每次 process +1；resetState 歸零）。%3==2 跑模型 —
    /// 與 FrameAnalyzer 的 body pose tick（%3==1，同事件重置、近似同步）錯開。
    private var analysisTick = 0
    /// lazy 載入：首個符合條件的模型 tick 才建 ReframeScorer（analysisQueue 上，
    /// 首次可能含 mlpackage 現場編譯，期間遲到帧由 alwaysDiscardsLateVideoFrames 自然丟棄）。
    /// init 失敗（無模型/載入失敗）只試一次 → 全程規則路徑，不重試不 crash。
    private var scorerLoadAttempted = false
    private var scorer: ReframeScorer?
    /// 最近一次模型輸出（帶 media timestamp；>1s 過期不用）。
    private var lastModelScore01: Double?
    private var lastModelDelta: SIMD3<Double>?
    private var lastModelAt: Double = -.greatestFiniteMagnitude
    /// 上一帧的前後鏡標記：切鏡瞬間 buffer 鏡像翻轉、座標跳變，
    /// 必須重置（否則 One-Euro 從舊位置滑過去、planner 保著錯誤承諾目標、
    /// tracker 可能短暫維持錯誤 locked）。與 CameraController.onCameraReconfigured
    /// 的重置互為雙保險（此處以 facts 流本身偵測，不依賴通知時序）。
    private var lastIsFront: Bool?

    private let resetLock = NSLock()
    private var resetPending = false
    /// 發布世代（resetLock 保護）：scheduleReset 每次 +1，process 蓋進 Output。
    private var generation = 0

    /// 任意執行緒可呼叫；實際重置延到下一次 process（分析 queue 上）執行。
    /// 回傳新世代 — 呼叫端以此為基準過濾稍後才抵達 MainActor 的舊帧輸出。
    @discardableResult
    func scheduleReset() -> Int {
        resetLock.lock()
        defer { resetLock.unlock() }
        resetPending = true
        generation += 1
        return generation
    }

    func process(_ facts: FrameFacts) -> Output {
        resetLock.lock()
        let doReset = resetPending
        resetPending = false
        let currentGeneration = generation
        resetLock.unlock()
        if doReset {
            resetState()
        }
        // 前後鏡切換偵測：facts.isFrontCamera 變化 = 座標空間鏡像翻轉 → 全管線重置
        if let last = lastIsFront, last != facts.isFrontCamera {
            resetState()
        }
        lastIsFront = facts.isFrontCamera

        // Reframe 模型 tick（先於評分：本帧模型分立即可混入本帧顯示分）
        analysisTick += 1
        runModelTickIfDue(timestamp: facts.timestamp)
        // 模型分未過期（≤1s）才參與混合／建議；過期靜默退回純規則
        let modelFresh = lastModelScore01 != nil && facts.timestamp - lastModelAt <= 1.0

        let result = engine.evaluate(facts, config: config)
        var solved = TargetSolver.solve(facts: facts, result: result)
        // 錨點 One-Euro 平滑「先於」planner（A1 契約：StickyTargetPlanner.update 的
        // 呼叫端注釋要求把平滑後錨點放進 solved.anchor 再餵入 — 承諾時機與越線
        // dwell 都以平滑錨點判定）。餵 nil = 主體消失 → 濾波器重置，重現時不從
        // 舊位置滑過去；平滑不改變 nil/非 nil，presence/grace 語意不受影響。
        solved.anchor = anchorFilter.update(solved.anchor, at: facts.timestamp)
        // 承諾目標：planner 決定何時換目標（側邊遲滯＋停留＋主體短暫消失寬限）。
        // 承諾後 target 凍結不動 — 凍結本身就是最強穩定，絕不再對 target 平滑。
        // 凍結期間的 normalizedDistance / cameraMoveHint 由 planner 以「平滑錨點 →
        // 承諾目標」重算（frozenGuidance，與 TargetSolver 同語意、同 1e-9 防除零）
        // — alignDistance 契約語意在此已滿足，管線不再重複計算。
        var guidance = planner.update(facts: facts, result: result, solved: solved, at: facts.timestamp)
        // 鎖定判斷：tracker（遲滯 + 停留時間）對「承諾目標」的距離判定
        guidance.lockState = tracker.update(distance: guidance.normalizedDistance, at: facts.timestamp)

        // 目標環（target）本身就是三分構圖位置指引的上位替代（含 yaw 視線空間 /
        // headroom 修正）：Rules.thirds 的文字建議取「就近三分線」，與 solver 的
        // yaw 覆寫目標可能整段方向矛盾（例：yaw<0 時 solver 鎖 2/3 線、thirds 卻叫
        // 用戶往 1/3 線移）→ 有環時抑制 .thirds 文字建議，膠囊留給環無法表達的維度
        // （光位/占比/切關節/水平/曝光）。分數不受影響（thirds 成分照算）。
        var candidate = result.advice
        if candidate?.category == .thirds, guidance.target != nil {
            candidate = nil
        }
        // 模型建議（保守；MASTER-PLAN §4.3b）：修正 = −delta、dzoom>0 = 太緊 → 退後。
        // 只在「規則層本帧無話可說、且尚未鎖定」時補位；dzoom 訓練標籤恆 ≥0，
        // 負/小值不可解讀成上前 → 只有 > 0.25 的明確「太緊」訊號才發話。
        // dx/dy 本輪不驅動 UI（目標環的黏性語意不可破壞），只在 tick 時記 log。
        if candidate == nil,
           modelFresh,
           let delta = lastModelDelta, delta.z > 0.25,
           guidance.lockState != .locked {
            candidate = SuggestionCatalog.distanceTooClose.advice(priority: 20)
        }
        let advice = stabilizer.update(candidate: candidate, at: facts.timestamp)
        // 分數混合（§4.6）：0.6×規則 + 0.4×模型（0…100 域），混合先於 EMA
        //（displayScore = EMA(混合分)：模型出現/過期時分數環漸變不跳）
        let ruleScore = Double(result.score)
        let blendedScore: Double
        if modelFresh, let model01 = lastModelScore01 {
            blendedScore = 0.6 * ruleScore + 0.4 * model01 * 100.0
        } else {
            blendedScore = ruleScore
        }
        let smoothed = scoreSmoother.update(blendedScore)

        if let last = lastTimestamp {
            let dt = facts.timestamp - last
            if dt > 0 {
                recentIntervals.append(dt)
                if recentIntervals.count > 10 {
                    recentIntervals.removeFirst()
                }
            }
        }
        lastTimestamp = facts.timestamp
        let fps = recentIntervals.isEmpty
            ? 0
            : recentIntervals.reduce(0) { $0 + 1 / $1 } / Double(recentIntervals.count)

        return Output(
            facts: facts,
            result: result,
            guidance: guidance,
            advice: advice,
            smoothedScore: smoothed,
            analysisFPS: fps,
            modelActive: modelFresh,
            generation: currentGeneration
        )
    }

    /// Reframe 模型 tick（analysisQueue）：開關/熱降級/節奏檢查 → lazy 載入 →
    /// 取當帧 buffer → 推論 → 暫存（帶 timestamp）。任何一步失敗都靜默跳過本 tick。
    private func runModelTickIfDue(timestamp: Double) {
        // @AppStorage 在非 View 不可靠 → 直讀 UserDefaults；key 預設 true
        //（object(forKey:) 為 nil = 用戶從未動過開關 = 開）
        let enabled = (UserDefaults.standard.object(forKey: "coach.model.enabled") as? Bool) ?? true
        guard enabled else { return }
        // 熱降級 ≥ .serious 停跑模型（與 applyThermalPolicy 同判準；此處直讀
        // thermalState，不依賴 MainActor 通知時序）
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else { return }
        // 每 3 次分析 tick 跑一次（~5fps）；%3==2 與 body pose tick 錯開（見屬性注釋)
        guard analysisTick % 3 == 2 else { return }

        if !scorerLoadAttempted {
            scorerLoadAttempted = true
            scorer = ReframeScorer()   // nil = 無模型 → 之後全程規則路徑
        }
        guard let scorer,
              let buffer = frameBufferProvider?(),
              let output = scorer.score(buffer)
        else { return }

        lastModelScore01 = output.score01
        lastModelDelta = output.delta
        lastModelAt = timestamp
        // dx/dy 本輪只記 log（修正 = −delta；debug 級，正式版零成本）
        Self.reframeLog.debug(
            "score01=\(output.score01) dx=\(output.delta.x) dy=\(output.delta.y) dzoom=\(output.delta.z)"
        )
    }

    private func resetState() {
        stabilizer.reset()
        scoreSmoother.reset()
        anchorFilter.reset()
        planner.reset()
        tracker.reset()
        recentIntervals = []
        lastTimestamp = nil
        lastIsFront = nil
        // 模型暫存清空（切鏡/翻鏡 = 取景空間跳變，舊 delta/分數不可跨用）；
        // scorer 本身與座標空間無關 → 保留已載入的模型，不重載
        analysisTick = 0
        lastModelScore01 = nil
        lastModelDelta = nil
        lastModelAt = -.greatestFiniteMagnitude
    }
}

//  發布頻率備註（給 A3 / reviewer）：
//  Observation 是逐屬性追蹤 — 只讀 advice / smoothedScore / lockState 的 view
//  只在該屬性變動時 diff；facts / anchorPoint / alignDistance 每次分析（~15fps）
//  都變，只有教練 overlay 的 Canvas 這類本來就要逐帧重繪的 view 才應該讀，
//  不要在大型 view body 裡讀。targetPoint（凍結）與 lockState 只在值變化時寫入。
//  分析 ~15fps、渲染 60fps：A3 overlay 若要更順，可對 anchorPoint 做
//  顯示端補間（分析層不再加平滑，補間屬渲染層自由）。
