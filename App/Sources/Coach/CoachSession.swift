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
//  v0.4.0 對準點導引（Apple 測距儀式；本檔接線，數學地基在 Core/AimPoint.swift）：
//  - 舊「點對環」反向控制根治：改為螢幕中央固定準星 + 世界標記
//    P = C + (A − T)（A = 當帧「未平滑」錨點、T = planner 凍結目標；
//    重投影推導與正向控制驗證見 AimPoint.swift 檔頭，錯那裡整個交互反向）。
//  - 融合：專屬 CMMotionManager 100Hz rotationRate → FOV 換算 normalized 位移
//    → GyroFusedPoint.predict（高頻）；每個 Vision tick 以 AimPointSolver.marker
//    量測 correct（互補濾波拉回防漂）— 標記「黏在世界上」的 AR 感，不用 ARKit。
//    角速度→畫面位移的全部符號推導寫在 AimFusionCoordinator.ingest（檔尾），
//    待真機驗證，反了翻正負號一行修。
//  - 發布節流：motion 100Hz 不可直接打 @Observable — ~60Hz Timer（main runloop
//    .common mode）讀融合值發布 aim / aimDistance；教練模式停用即停 timer。
//  - FOV：camera.currentHorizontalFOVDegrees()（A4）每秒刷新一次快取；
//    nil fallback 60°；zoom 修正 + portrait 軸向換算（videoFieldOfView =
//    感光器長邊視角 = 直立畫面的「垂直」FOV — 最易錯處）見 refreshAimProjection。
//  - GuidanceTracker 改餵「融合 marker → 準星」距離（AimPointSolver 附帶語意：
//    |marker − C| = |anchor − target| → 門檻域相同，tracker 參數不動）；
//    融合器無值時 fallback 當帧 normalizedDistance（= v0.3.0 行為）。
//    鎖定 haptic／自動抓拍邏輯自然沿用（仍吃 lockState 邊緣）。
//  - anchorPoint / targetPoint 照舊發布（相容）；UI 改畫準星＋標記屬 A3。
//
//  待真機驗證（發布頻率 ~15fps；facts 屬性只有教練 overlay 應讀取，見檔尾註記）。

import CoreMotion
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
    /// v0.4.0 對準點導引（契約 surface；A3 只讀）：融合後世界標記顯示狀態。
    /// 陀螺儀 ~100Hz predict + Vision ~15fps correct，以 ~60Hz timer 節流發布。
    /// 只有對準 overlay（本來就逐帧重繪的 Canvas 層）應讀取 —
    /// 大型 view body 讀了會被拖著以 ~60Hz diff（見檔尾註記）。
    private(set) var aim: AimState?
    /// |融合 marker − 準星 (0.5, 0.5)|（normalized）；融合器無值時 nil。
    /// 與 aim 同節奏（~60Hz）發布。
    private(set) var aimDistance: Double?
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

    // MARK: 對準點融合（v0.4.0）

    /// 陀螺儀／Vision 融合協調器（執行緒安全外殼，見檔尾類別）。
    /// motion queue（100Hz predict）、MainActor（correct/reset/讀值）、
    /// analysisQueue（tracker 距離）三方共用。
    @ObservationIgnored private let aimFusion = AimFusionCoordinator()
    /// v0.4.0 專屬 gyro 管理器（100Hz rotationRate）。FrameAnalyzer 的 60Hz
    /// gravity 管理器為其檔案私有（本輪只准改本檔）→ 另建專屬實例。
    /// Apple 建議整 app 單一 CMMotionManager；多實例各以自身 interval 收回呼、
    /// 感測器以最高需求率運轉 — 兩者只在教練模式同時活躍，可接受；
    /// 後續整併輪可把 rotationRate 併進 FrameAnalyzer 的那顆（見交付 notes）。
    @ObservationIgnored private let aimMotionManager = CMMotionManager()
    /// motion 回呼專用 serial queue（與 FrameAnalyzer.motionQueue 同模式）。
    @ObservationIgnored private let aimMotionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.arieswu.aicam.coach.aimmotion"
        return queue
    }()
    /// ~60Hz 發布節流 timer（MainActor；教練停用時 invalidate）。
    @ObservationIgnored private var aimPublishTimer: Timer?
    /// 發布 tick 計數：每 60 tick（~1s）刷新一次 FOV 快取。
    @ObservationIgnored private var aimTickCount = 0
    /// 上一次 correct 所用的凍結 target：planner 換靶（重新承諾）時
    /// 融合器 reset + 以新量測 pass-through 重播 — 標記「跳切」到新靶
    ///（換靶是刻意動作，跳切明確傳達「新目標」；不從舊靶滑過去）。
    @ObservationIgnored private var lastAimTarget: NPoint?

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
        // v0.4.0：tracker 距離來源 = 融合 marker → 準星（analysisQueue 上呼叫；
        // 執行緒安全由 coordinator 內部鎖保證）。捕捉 coordinator 本體、
        // 不捕捉 self（MainActor 隔離，背景 queue 不得觸碰）。
        let aimFusion = self.aimFusion
        pipeline.fusedDistanceProvider = { aimFusion.distanceFromCrosshair() }

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
        // 與 thermalObserver 同模式（Swift 5 模式、deinit 直接觸碰）：
        // CoachSession 與 app 同壽命，此處僅為完備性。
        aimPublishTimer?.invalidate()
        aimMotionManager.stopDeviceMotionUpdates()
    }

    // MARK: - 開關（契約）

    /// true：向 camera 掛 video tap（僅第一次）+ CoreMotion 啟動（重力 60Hz +
    /// 對準點 gyro 100Hz）+ 60Hz 對準點發布 timer + 開始分析；
    /// false：停分析（tap 丟帧）+ motion／timer 全停 + 清空發布狀態。
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
            startAimUpdates()
        } else {
            tap.setActive(false)
            tap.analyzer.stopMotion()
            // 停 connection 出帧：離開教練模式不再付 30fps 資料流／功耗成本
            camera.setVideoTapEnabled(false)
            stopAimUpdates()
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
        // v0.4.0：取景座標跳變 → 融合器清空（GyroFusedPoint value 歸 nil 後
        // predict 靜默忽略 — 新座標空間的首筆 correct pass-through 前，
        // 舊符號／舊 FOV 的陀螺儀預測「不可能」污染標記）+ 標記立即熄滅。
        aimFusion.reset()
        lastAimTarget = nil
        aim = nil
        aimDistance = nil
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

        // v0.4.0：對準點融合 Vision 修正步（量測 = 未平滑錨點 × 凍結目標）
        updateAimFusion(
            guidance: output.guidance,
            rawAnchor: output.rawAnchor,
            isFront: output.facts.isFrontCamera
        )

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

    // MARK: - 對準點導引（v0.4.0）

    /// 教練啟用：刷新 FOV 快取 → 啟動 100Hz gyro → 啟動 ~60Hz 發布 timer。
    private func startAimUpdates() {
        refreshAimProjection()
        aimFusion.resetMotionClock()
        if aimMotionManager.isDeviceMotionAvailable, !aimMotionManager.isDeviceMotionActive {
            // 契約：interval 提到 1/100（Vision ~15fps 之間標記靠這裡推算）。
            aimMotionManager.deviceMotionUpdateInterval = 1.0 / 100.0
            // 只捕捉 coordinator（@unchecked Sendable、內部鎖），不捕捉 self —
            // 回呼在背景 OperationQueue，不得觸碰 MainActor 隔離狀態。
            // rotationRate（deviceMotion 版）已由 CoreMotion 感測融合去除
            // gyro bias — 選它而非 attitude 差分的理由見交付 notes 與
            // AimFusionCoordinator.ingest 注釋。
            let fusion = aimFusion
            aimMotionManager.startDeviceMotionUpdates(to: aimMotionQueue) { motion, _ in
                guard let motion else { return }
                fusion.ingest(
                    rotationRateX: motion.rotationRate.x,
                    rotationRateY: motion.rotationRate.y,
                    timestamp: motion.timestamp
                )
            }
        }
        aimTickCount = 0
        // Timer 60Hz（契約允許 Timer；.common mode — 曝光滑桿等 UI tracking
        // 期間 .default mode timer 會停擺，標記不得跟著凍結）。
        // 回呼閉包按 SDK 標記可能是 @Sendable → 只做 MainActor hop，不直接碰狀態。
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.aimPublishTick()
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        aimPublishTimer = timer
    }

    /// 教練停用：gyro／timer 全停 + 融合器清空 + 發布熄滅。
    private func stopAimUpdates() {
        aimMotionManager.stopDeviceMotionUpdates()
        aimPublishTimer?.invalidate()
        aimPublishTimer = nil
        aimFusion.reset()
        lastAimTarget = nil
        aim = nil
        aimDistance = nil
    }

    /// ~60Hz 發布 tick（MainActor）：讀融合值 → AimGeometry → aim/aimDistance。
    /// 值未變不寫（@Observable 逐屬性追蹤：不寫就不觸發讀取端 diff —
    /// 手機靜止且無新量測時整個 tick 零發布成本）。
    private func aimPublishTick() {
        guard isActive else { return }
        aimTickCount += 1
        // FOV 快取每 ~1s 刷新一次（zoom ramp / 鏡位切換後跟上；
        // 鏡位切換另有 onCameraReconfigured → resetGuidance 立即清融合器）
        if aimTickCount % 60 == 1 {
            refreshAimProjection()
        }
        guard let marker = aimFusion.value else {
            if aim != nil { aim = nil }
            if aimDistance != nil { aimDistance = nil }
            return
        }
        let state = AimGeometry.state(for: marker)
        if state != aim {
            aim = state
        }
        let dx = marker.x - AimPointSolver.crosshair.x
        let dy = marker.y - AimPointSolver.crosshair.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance != aimDistance {
            aimDistance = distance
        }
    }

    /// FOV／前後鏡快取刷新（MainActor；~1s 一次 + setActive 時一次）。
    ///
    /// 軸向換算（座標鐵律，最易錯處，逐步寫明）：
    /// (1) camera.currentHorizontalFOVDegrees() = activeFormat.videoFieldOfView =
    ///     感光元件「原生 landscape 影像的橫向（長邊）」視角、videoZoomFactor=1 基準。
    /// (2) zoom 修正（A4 注釋公式）：有效長邊視角 = 2·atan(tan(base/2) / zoom)，
    ///     zoom 讀 camera.currentZoomFactor()（「實際」videoZoomFactor 鏡像）。
    ///     不可讀 currentLens?.zoomFactor：那是量化到最接近焦段的 UI 近似 —
    ///     三鏡 Pro 上 AI ramp 到 2x（factor 4.0）後 currentLens 停在 1x@2.0，
    ///     FOV 會恆常錯 2 倍、陀螺儀靈敏度剩一半（持續性誤差，非 ramp 過渡）。
    ///     鏡像在 ramp 進行中為目標值（~1s 漸進近似，殘差由 correct 吃掉），
    ///     停在任何 factor 後即精確。
    /// (3) 本 app 直立 portrait 顯示（connection videoRotationAngle=90）→
    ///     感光器長邊直立後對應畫面的「垂直」方向 ⇒ 有效長邊視角 = 畫面 vFOV。
    ///     （憑直覺把 videoFieldOfView 當畫面水平視角 = 兩軸靈敏度各錯 ~33%。）
    /// (4) 畫面 hFOV（對應感光器短邊）用焦平面幾何換算（同一焦距、平面感光器）：
    ///     tan(hFOV/2) = tan(vFOV/2) × (畫面寬/畫面高)；寬高比取 contentAspect
    ///     （直立分析帧 寬/高，如 3:4 = 0.75；未收到有效帧前為預設 0.75）。
    ///     不用線性比例 hFOV ≈ vFOV×aspect：廣角端 tan 非線性誤差可觀。
    /// 全鏈「待真機驗證」：靈敏度若整體偏高/偏低，先查 (2) 的 zoom 語意與
    /// (4) 的 aspect 來源，兩軸「互換」錯誤則回頭查 (3)。
    private func refreshAimProjection() {
        // 契約：session 尚未配置成功（或裝置回報 0）→ fallback 60°
        let baseLongSideDeg = camera.currentHorizontalFOVDegrees() ?? 60.0
        let zoom = max(1.0, Double(camera.currentZoomFactor()))
        let baseLongSideRad = baseLongSideDeg * Double.pi / 180.0
        let effectiveLongSideRad = 2.0 * atan(tan(baseLongSideRad / 2.0) / zoom)
        let vFOVRad = effectiveLongSideRad
        let aspect = (contentAspect > 0 && contentAspect <= 1) ? contentAspect : 0.75
        let hFOVRad = 2.0 * atan(tan(effectiveLongSideRad / 2.0) * aspect)
        aimFusion.setProjection(hFOVRad: hFOVRad, vFOVRad: vFOVRad, isFront: camera.isFront)
    }

    /// Vision tick 的融合修正步（publish 內、MainActor；已過世代比對 —
    /// 重置前的舊座標帧到不了這裡，不可能污染融合器）。
    ///
    /// 量測 = AimPointSolver.marker(anchor: 當帧「未平滑」錨點, target: planner
    /// 凍結目標)。anchor 不用 One-Euro 平滑版（A1 餵入原則：融合器本身就是
    /// 平滑器，疊兩層只多延遲）；target 必須用凍結值（當帧重算 = 回到
    /// 「追會跑的靶」老 bug）。
    ///
    /// 三種情況：
    /// - target 撤銷（planner 超過寬限確認主體丟失／無解）→ reset + aim 發 nil。
    /// - target 在、rawAnchor 短暫 nil（planner 寬限期掉主體）→ 本 tick 不修正，
    ///   標記靠陀螺儀預測續命 — 「黏在世界上」的價值所在，不熄滅。
    /// - 換靶（凍結 target 變了 = planner 重新承諾）→ reset 後 correct
    ///   pass-through：標記「跳切」到新靶（刻意；互補濾波從舊靶滑過去 ~0.5s
    ///   會讓 tracker 距離短暫失真，跳切同時明確傳達「新目標」）。
    private func updateAimFusion(guidance: TargetGuidance, rawAnchor: NPoint?, isFront: Bool) {
        aimFusion.setIsFront(isFront)
        guard let target = guidance.target else {
            lastAimTarget = nil
            aimFusion.reset()
            if aim != nil { aim = nil }
            if aimDistance != nil { aimDistance = nil }
            return
        }
        if target != lastAimTarget {
            aimFusion.reset()
            lastAimTarget = target
        }
        if let rawAnchor {
            aimFusion.correct(AimPointSolver.marker(anchor: rawAnchor, target: target))
        }
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
        /// TargetSolver 當帧「未平滑」錨點（v0.4.0）：對準點融合的量測輸入。
        /// guidance.anchor 是 One-Euro 平滑版（planner／舊 UI 用）；融合器要
        /// 最低延遲的原始量測（A1 餵入原則，見 AimPoint.swift 檔頭）。
        var rawAnchor: NPoint?
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
    /// v0.4.0：GuidanceTracker 的距離來源 =「融合 marker → 準星」距離
    ///（CoachSession init 設定一次；analysisQueue 上呼叫，執行緒安全由
    /// AimFusionCoordinator 內部鎖保證）。nil = 融合器目前無值（教練剛啟動／
    /// 剛重置／模擬器無 gyro）→ process 內 fallback 當帧 normalizedDistance。
    var fusedDistanceProvider: (() -> Double?)?
    /// 上一帧承諾的凍結 target（analysisQueue 專屬）：換靶帧防護用。
    /// 融合器的 reset + pass-through correct 在 MainActor（updateAimFusion），
    /// 比本 queue 的 process 晚 — planner 本帧換新靶時融合器仍持有「舊靶」
    /// 的 marker，該帧不得餵 tracker（見 process 內注釋）。
    private var lastFusedTarget: NPoint?
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
        // v0.4.0：對準點融合的量測要「未平滑」當帧錨點 — 在 One-Euro 覆寫前
        // 先取原始 solver 輸出（延遲最低；平滑交給 GyroFusedPoint 互補濾波，
        // 疊兩層平滑只會多延遲 — AimPoint.swift 檔頭餵入原則）。
        let rawAnchor = solved.anchor
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
        // 鎖定判斷：tracker（遲滯 + 停留時間）對「承諾目標」的距離判定。
        // v0.4.0：距離改餵「融合 marker → 準星」（~100Hz 陀螺儀新鮮度：兩次
        // Vision 之間手機的轉動也立即反映進鎖定判斷）。門檻域不變 —
        // AimPointSolver 附帶語意 |marker − C| = |anchor − target|，tracker
        // 參數（lockAt/unlockAt/dwell）原封沿用。
        // - target 未承諾 → 必須餵 nil（→ .searching）；不得讓上一靶殘留的
        //   融合值誤導狀態機（融合器的 reset 在 MainActor，跨 queue 有一帧時差）。
        // - 融合器無值（剛啟動／剛重置／無 gyro 裝置）→ fallback 當帧
        //   normalizedDistance（= v0.3.0 行為，鎖定功能不依賴 gyro 存在）。
        // - planner 寬限期（target 在、當帧主體短暫丟失 → normalizedDistance
        //   nil）時融合距離仍在 → 鎖定狀態由陀螺儀續命，不閃 .searching。
        // - 換靶帧（target 本帧才變 = planner 重新承諾）→ 同樣不得餵融合距離：
        //   融合器的 reset + pass-through 在 MainActor 的 updateAimFusion，
        //   跨 queue 晚一帧 — 此刻融合器還持有「舊靶」的 marker，餵進 tracker
        //   會以舊靶距離判新靶的鎖定（極端下 locked 多殘留一帧、
        //   maybeAutoCapture 可能對錯靶開拍）。該帧 fallback 當帧
        //   normalizedDistance（與融合器無值同一退路），下一帧融合器已重播新靶。
        let retargeted = guidance.target != lastFusedTarget
        lastFusedTarget = guidance.target
        let fusedDistance = (guidance.target != nil && !retargeted)
            ? fusedDistanceProvider.flatMap { $0() }
            : nil
        guidance.lockState = tracker.update(
            distance: fusedDistance ?? guidance.normalizedDistance,
            at: facts.timestamp
        )

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
            rawAnchor: rawAnchor,
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
        lastFusedTarget = nil
        // 模型暫存清空（切鏡/翻鏡 = 取景空間跳變，舊 delta/分數不可跨用）；
        // scorer 本身與座標空間無關 → 保留已載入的模型，不重載
        analysisTick = 0
        lastModelScore01 = nil
        lastModelDelta = nil
        lastModelAt = -.greatestFiniteMagnitude
    }
}

// MARK: - AimFusionCoordinator（v0.4.0；三執行緒共用的融合外殼）

/// GyroFusedPoint（Core，純數學、無鎖）的執行緒安全協調器：
/// - aimMotionQueue（~100Hz）：ingest() 角速度 → normalized 位移 → predict
/// - MainActor（~15fps publish）：correct() / reset()；（~60Hz timer）讀 value
/// - analysisQueue（tracker 距離）：distanceFromCrosshair()
/// 全部經同一把 NSLock（臨界區皆為常數時間純算術，100Hz 無競爭壓力）。
/// Core 檔不動 — A1 契約：融合器只做座標空間內純數學，FOV／裝置軸／
/// 前後鏡符號全在本呼叫端；@unchecked Sendable 的安全性由鎖保證。
private final class AimFusionCoordinator: @unchecked Sendable {

    private let lock = NSLock()
    private let fused = GyroFusedPoint()   // 量測權重用預設 0.35（契約值）

    /// 畫面「水平」視角（rad；對應感光器短邊 — 軸向換算見 refreshAimProjection）。
    /// 預設 = 60° 長邊基準 × 3:4 tan 換算，首次 refreshAimProjection 前的保守值。
    private var hFOVRad: Double = 2.0 * atan(tan(60.0 * Double.pi / 180.0 / 2.0) * 0.75)
    /// 畫面「垂直」視角（rad；對應感光器長邊 = videoFieldOfView 本體）。
    private var vFOVRad: Double = 60.0 * Double.pi / 180.0
    private var isFront = false
    /// 上一筆 motion 樣本時間（CMDeviceMotion.timestamp，開機起算秒）；
    /// nil = 下一筆只建基準不積分。
    private var lastMotionTimestamp: TimeInterval?

    // MARK: 設定（MainActor 呼叫）

    func setProjection(hFOVRad: Double, vFOVRad: Double, isFront: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.hFOVRad = hFOVRad
        self.vFOVRad = vFOVRad
        self.isFront = isFront
    }

    func setIsFront(_ front: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isFront = front
    }

    /// motion 重啟時清 dt 基準（教練停用期間 timestamp 斷層不得被積分）。
    func resetMotionClock() {
        lock.lock()
        defer { lock.unlock() }
        lastMotionTimestamp = nil
    }

    // MARK: 陀螺儀預測步（aimMotionQueue ~100Hz）

    /// 陀螺儀樣本 → 標記 normalized 位移 → predict。
    ///
    /// ── 符號推導（本輪成敗；逐步寫明）──
    /// 裝置軸（CoreMotion，直立 portrait）：+x = 畫面右、+y = 畫面上（機頂）、
    /// +z = 出螢幕朝使用者；rotationRate = 繞各軸角速度（rad/s，右手定則）。
    /// 後鏡光軸 = −z、前鏡光軸 = +z。NormalizedFrame：x 向右、y 向下。
    ///
    /// 後鏡 pan（dx）：
    /// (1) rotationRate.y > 0 = 繞 +y 右手定則（+z 轉向 +x）= 俯視逆時針。
    /// (2) 光軸 −z 隨之轉向 −x 側 = 相機「左轉」。
    /// (3) 相機左轉 ⇒ 世界景物在畫面上「右移」⇒ 標記 x 增大。
    /// (4) 等價反述：相機右轉（rotationRate.y < 0）⇒ 景物左移 ⇒ 標記 x 減小 ✓
    /// ⇒ dx = +rotationRate.y × dt ÷ hFOV
    ///
    /// 後鏡 tilt（dy）：
    /// (1) rotationRate.x > 0 = 繞 +x 右手定則（+y 轉向 +z）= 機頂向使用者傾。
    /// (2) 光軸 −z 隨之轉向 +y = 相機「上仰」。
    /// (3) 相機上仰 ⇒ 景物在畫面上「下移」⇒ y（向下為正）增大。
    /// ⇒ dy = +rotationRate.x × dt ÷ vFOV
    ///
    /// 前鏡（兩軸都翻號，但原因不同 — 拆成 sx/sy 兩個因子，單軸反了可各修）：
    /// - dx（翻號原因 =「預覽鏡像」）：rotationRate.y > 0 時前鏡光軸 +z 轉向
    ///   +x 側，以前鏡自身朝向而言同樣是「向自己的左」轉（兩鏡繞同一 +y 軸，
    ///   「左」由各自朝向定義）⇒ 景物在「感光器原生影像」中右移；但前鏡
    ///   分析／預覽 buffer 已水平鏡像（FrameAnalyzer 檔頭鐵律：NormalizedFrame
    ///   的「左」= 螢幕左）⇒ 畫面 x 翻轉 ⇒ dx 翻號。
    /// - dy（翻號原因 =「光軸反向」，與鏡像無關 — 垂直方向沒有鏡像）：
    ///   機頂向使用者傾（rotationRate.x > 0）時前鏡光軸 +z 轉向 −y = 前鏡
    ///   「下俯」（與後鏡上仰相反）⇒ 自拍主體在畫面上「上移」⇒ dy 翻號。
    ///   （實機自查法：自拍時機頂朝自己傾，臉在預覽中上移 = dy 應為負。）
    ///
    /// 近似說明：
    /// - 位移 = 角位移(rad) ÷ FOV(rad) 是小角度線性近似（嚴格為 tan 投影）；
    ///   兩次 Vision 修正之間角位移 ≪ FOV，殘差由互補濾波 correct 吃掉。
    /// - 繞光軸的 roll（rotationRate.z）刻意忽略：離心標記會微幅弧移，
    ///   量級小且同樣被 correct 拉回（有意簡化，非遺漏）。
    ///
    /// ⚠ 全部符號「待真機驗證」：實測若某軸反向，翻對應 sx / sy 一行即修。
    func ingest(rotationRateX: Double, rotationRateY: Double, timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastMotionTimestamp else {
            lastMotionTimestamp = timestamp
            return
        }
        let dt = timestamp - last
        lastMotionTimestamp = timestamp
        // 正常間隔 ~0.01s；>0.1s = 回呼曾中斷（app 掛起等），斷層不積分
        guard dt > 0, dt < 0.1 else { return }
        guard hFOVRad > 1e-6, vFOVRad > 1e-6 else { return }
        let sx: Double = isFront ? -1 : 1   // 前鏡：鏡像翻 x（推導見上）
        let sy: Double = isFront ? -1 : 1   // 前鏡：光軸反向翻 y（推導見上）
        let dx = sx * (rotationRateY * dt) / hFOVRad
        let dy = sy * (rotationRateX * dt) / vFOVRad
        // 融合器 value 為 nil（尚無首筆 Vision 量測）時 predict 靜默忽略 —
        // 沒有基準點無從累加（GyroFusedPoint 契約），此處不必再判。
        fused.predict(dxNormalized: dx, dyNormalized: dy)
    }

    // MARK: Vision 修正／讀值

    func correct(_ marker: NPoint) {
        lock.lock()
        defer { lock.unlock() }
        fused.correct(marker)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        fused.reset()
    }

    var value: NPoint? {
        lock.lock()
        defer { lock.unlock() }
        return fused.value
    }

    /// |融合 marker − 準星|（GuidanceTracker 餵入用；analysisQueue 呼叫）。
    func distanceFromCrosshair() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let v = fused.value else { return nil }
        let dx = v.x - AimPointSolver.crosshair.x
        let dy = v.y - AimPointSolver.crosshair.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

//  發布頻率備註（給 A3 / reviewer）：
//  Observation 是逐屬性追蹤 — 只讀 advice / smoothedScore / lockState 的 view
//  只在該屬性變動時 diff；facts / anchorPoint / alignDistance 每次分析（~15fps）
//  都變，只有教練 overlay 的 Canvas 這類本來就要逐帧重繪的 view 才應該讀，
//  不要在大型 view body 裡讀。targetPoint（凍結）與 lockState 只在值變化時寫入。
//  分析 ~15fps、渲染 60fps：A3 overlay 若要更順，可對 anchorPoint 做
//  顯示端補間（分析層不再加平滑，補間屬渲染層自由）。
//  v0.4.0 追加：aim / aimDistance 以 ~60Hz 發布（值未變不寫；手機轉動時
//  幾乎每 tick 都變）— 同樣只有對準 overlay 的逐帧重繪層應讀取；
//  標記已由 gyro 100Hz 融合推算，顯示端「不需要」再補間。
