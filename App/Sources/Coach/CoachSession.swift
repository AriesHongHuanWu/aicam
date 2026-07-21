//  CoachSession.swift
//  AICam — 教練 session 中樞（A5；跨模組契約 surface，UI 讀這裡）。
//
//  資料流（MASTER-PLAN §3）：
//  VideoFrameTap（analysisQueue）→ FrameAnalyzer → FrameFacts
//    → CoachPipeline（同 queue：L1 引擎 evaluate → TargetSolver.solve →
//       GuidanceTracker 鎖定判斷 → anchor/target PointSmoother → AdviceStabilizer → ScoreSmoother）
//    → Task { @MainActor } 一次發布全部 @Observable 屬性（渲染與分析解耦）。
//
//  - 鎖定（.locked）轉變邊緣觸發一次 UINotificationFeedbackGenerator.success。
//  - 自動抓拍：coach.autoCapture 開 && result.shouldAutoCapture && lockState == .locked
//    && 距上次自動拍 ≥ 3s（media timestamp 防抖）→ camera.capturePhoto()。
//    （v1 簡化：單張、無 gyro 穩定度／臉部銳利度檢查；MASTER-PLAN §4.7 的
//    「靜音連拍 3 張進 Session」屬 P4/P5，後續執行者勿誤以為已完成。）
//  - 熱降級：thermalState ≥ .serious → 分析間隔 0.25s + 停 body pose（thermalReduced 發布）。
//  - snapshotJPEG(maxDimension:)：最新分析帧同步轉 JPEG（Gemini 導演即時模式取帧用）。
//
//  待真機驗證（發布頻率 ~10fps；facts 屬性只有教練 overlay 應讀取，見檔尾註記）。

import Foundation
import Observation
import UIKit
import AICamCore

@MainActor
@Observable
final class CoachSession {

    // MARK: - 對外發布（跨模組契約）

    private(set) var facts: FrameFacts?
    private(set) var result: CompositionResult?
    private(set) var guidance: TargetGuidance?
    /// 已過 AdviceStabilizer 的顯示建議（防箭頭閃爍）。
    private(set) var advice: CoachAdvice?
    /// 分數 EMA（alpha 0.25）。
    private(set) var smoothedScore: Double = 0
    /// smoothedScore 的整數版：只在整數值變化時才寫入 —
    /// RootView（快門外圈）讀這個，避免大型 view body 以 ~10fps 重算 diff（見檔尾註記）。
    private(set) var displayScore: Int = 0
    /// 分析 buffer 的直立寬高比（寬/高；預設 3:4）。CoachOverlayView 的
    /// AspectFillMapper 取代寫死比例用；僅在收到有效直立帧時更新。
    private(set) var contentAspect: Double = 3.0 / 4.0
    /// 最近 10 次分析間隔倒數的平均。
    private(set) var analysisFPS: Double = 0
    private(set) var thermalReduced: Bool = false

    // MARK: - 內部

    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let tap = VideoFrameTap()
    @ObservationIgnored private let pipeline = CoachPipeline()
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var hasAttachedTap = false
    @ObservationIgnored private var wasLocked = false
    @ObservationIgnored private var lastAutoCaptureAt: Double = -.greatestFiniteMagnitude
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private let lockHaptics = UINotificationFeedbackGenerator()

    init(camera: CameraController) {
        self.camera = camera

        let pipeline = self.pipeline
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
            pipeline.scheduleReset()
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
            advice = nil
            smoothedScore = 0
            displayScore = 0
            analysisFPS = 0
            wasLocked = false
        }
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
        guard isActive else { return }
        facts = output.facts
        result = output.result
        guidance = output.guidance
        advice = output.advice
        smoothedScore = output.smoothedScore
        analysisFPS = output.analysisFPS

        // 整數分數只在值變化時寫入（@Observable 逐屬性追蹤：不寫就不觸發 diff）
        let score = Int(output.smoothedScore.rounded())
        if score != displayScore {
            displayScore = score
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
        tap.setMinAnalysisInterval(reduced ? 0.25 : 0.1)
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
    }

    private let engine = RuleCompositionEngine()
    private let config = ScoringConfig.standard
    private let stabilizer = AdviceStabilizer()
    private var scoreSmoother = ScoreSmoother(alpha: 0.25)
    private var anchorSmoother = PointSmoother(alpha: 0.35)
    private var targetSmoother = PointSmoother(alpha: 0.35)
    private var tracker = GuidanceTracker()
    private var recentIntervals: [Double] = []
    private var lastTimestamp: Double?
    /// 上一帧的前後鏡標記：切鏡瞬間 buffer 鏡像翻轉、座標跳變，
    /// 必須重置（否則 smoother 從舊位置滑過去、tracker 可能短暫保持錯誤 locked）。
    private var lastIsFront: Bool?

    private let resetLock = NSLock()
    private var resetPending = false

    /// 任意執行緒可呼叫；實際重置延到下一次 process（分析 queue 上）執行。
    func scheduleReset() {
        resetLock.lock()
        resetPending = true
        resetLock.unlock()
    }

    func process(_ facts: FrameFacts) -> Output {
        resetLock.lock()
        let doReset = resetPending
        resetPending = false
        resetLock.unlock()
        if doReset {
            resetState()
        }
        // 前後鏡切換偵測：facts.isFrontCamera 變化 = 座標空間鏡像翻轉 → 全管線重置
        if let last = lastIsFront, last != facts.isFrontCamera {
            resetState()
        }
        lastIsFront = facts.isFrontCamera

        let result = engine.evaluate(facts, config: config)
        var guidance = TargetSolver.solve(facts: facts, result: result)
        // solver 一律回 .searching；鎖定判斷交給 tracker（遲滯 + 停留時間）
        guidance.lockState = tracker.update(distance: guidance.normalizedDistance, at: facts.timestamp)
        // 錨點／目標點 EMA 平滑（餵 nil 會重置各自的 smoother）
        guidance.anchor = anchorSmoother.update(guidance.anchor)
        guidance.target = targetSmoother.update(guidance.target)

        // 目標環（target）本身就是三分構圖位置指引的上位替代（含 yaw 視線空間 /
        // headroom 修正）：Rules.thirds 的文字建議取「就近三分線」，與 solver 的
        // yaw 覆寫目標可能整段方向矛盾（例：yaw<0 時 solver 鎖 2/3 線、thirds 卻叫
        // 用戶往 1/3 線移）→ 有環時抑制 .thirds 文字建議，膠囊留給環無法表達的維度
        // （光位/占比/切關節/水平/曝光）。分數不受影響（thirds 成分照算）。
        var candidate = result.advice
        if candidate?.category == .thirds, guidance.target != nil {
            candidate = nil
        }
        let advice = stabilizer.update(candidate: candidate, at: facts.timestamp)
        let smoothed = scoreSmoother.update(Double(result.score))

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
            analysisFPS: fps
        )
    }

    private func resetState() {
        stabilizer.reset()
        scoreSmoother.reset()
        _ = anchorSmoother.update(nil)
        _ = targetSmoother.update(nil)
        tracker = GuidanceTracker()   // 契約無 reset()：重建即重置
        recentIntervals = []
        lastTimestamp = nil
        lastIsFront = nil
    }
}

//  發布頻率備註（給 A3 / reviewer）：
//  Observation 是逐屬性追蹤 — 只讀 advice / smoothedScore / guidance 的 view
//  只在該屬性變動時 diff；facts 每次分析（~10fps）都變，只有教練 overlay 的
//  Canvas 這類本來就要逐帧重繪的 view 才應該讀 facts，不要在大型 view body 裡讀。
