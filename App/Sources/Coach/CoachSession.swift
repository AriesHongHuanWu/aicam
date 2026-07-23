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
//  - 融合（→ v0.6.0 整組退役，見下）：專屬 CMMotionManager 100Hz rotationRate
//    → FOV 換算 normalized 位移
//    → GyroFusedPoint.predict（高頻）；每個 Vision tick 以 AimPointSolver.marker
//    量測 correct（互補濾波拉回防漂）— 標記「黏在世界上」的 AR 感，不用 ARKit。
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
//  v0.5.0 群組合照（A3）：
//  - isGroupMode 發布（≥2 臉；FrameAnalyzer 已對第 2 張臉起做信心門檻把關，
//    此處只看 faces.count）→ A4 據此畫「合照」小字。
//  - GroupGuard（CoachPipeline.process 內、stabilizer 前）：群組時任一臉框
//    距畫面四邊 < 3% → 「有人被切到了」（.jointCut, priority 105）硬警告插隊
//    （AdviceStabilizer priority ≥ 100 立即切換語意自然生效），並取消該帧
//    自動抓拍；規則層真切關節（110）仍更優先。
//  - 群組導引語意（錨點 = 整群 union 中心、headroom 以最高臉框頂為準）在
//    Core TargetSolver（單人路徑 bit-不變，TargetSolverTests 鎖定）。
//
//  v0.5.1 對準標記「跟手飄」緊急修復（→ v0.6.0 隨融合路徑整組退役，僅留史）：
//  真機回饋：鏡頭對準時標記一直往移動方向飄走。三個共症一次免疫：
//  (a) 某軸陀螺儀符號實機相反（紙上推導自洽但未實證）／(b) FOV/變焦換算殘差
//      → 增益過低、標記跟不上景物（視覺 = 黏著螢幕跟手走）：GyroFusedPoint
//      AutoGain 逐軸線上學增益 — 符號反收斂到負值自動翻號、增益低收斂 >1
//      補償（自癒）；學得值以 UserDefaults 持久化、前後鏡各一組
//      （aim.gain.{x,y}.{back,front}；存取順序鐵律見 resetGuidance）。
//  (c) Vision 量測延遲 100–200ms：舊版 correct 把融合值往「舊帧位置」（恆在
//      用戶移動方向後方）拖，15fps×0.35 的回拖速率與陀螺儀前進速率同量級
//      ⇒ 移動中標記像被手拖著走：改 correct(marker, measuredAt:
//      facts.timestamp) 延遲補償 — Core 回溯環形緩衝在「帧時間」上算
//      innovation（時基一致性論證＋1.0s 防禦退化 guard 見
//      AimFusionCoordinator.correct）。
//  predict 帶 CMDeviceMotion.timestamp（= 回溯緩衝時間軸）；其餘行為
//  （黏性目標／tracker／發布節奏）一律不動。
//
//  v0.6.0 姿態主導標記（本輪架構重構；數學在 Core/AttitudeMarker.swift，A1）：
//  四輪真機回饋核心：標記不穩、跟不住、飄。根本病因 = 標記每帧從「主體
//  即時偵測位置 A」重算（P = C + A − T）— 主體晃動／偵測抖動／anchor 切換
//  全部直接搖標記；v0.4.0 的相機運動補償與 v0.5.1 的延遲補償都只能救
//  「相機在動」，救不了「主體本身在動」。
//  新架構（判斷一下 → 固定一個點 → 讓使用者移動角度或位置去符合）：
//  (1) 承諾瞬間：以「靠近帧時間戳的裝置姿態 q_commit（0.5s 姿態環形緩衝
//      回查；分析帧延遲 ~100–200ms，不可用『現在』的姿態）＋當帧
//      (A − T) 畫面偏移」合成固定目標姿態 q_goal（AttitudeProjection.goalQuat）。
//  (2) 之後標記螢幕位置 = 純由 q_current 相對 q_goal 的旋轉差投影
//      （AttitudeProjection.marker；100Hz motion tick）— 零延遲、零主體耦合：
//      主體怎麼晃標記都不動，只有「使用者自己轉動手機」會動標記。
//  (3) Vision 降為慢速覆核：每個分析 tick 算 P_vis = C + A − T（沿用現算式）
//      與「同帧時間的姿態版標記」比較 — SubjectMoveDetector 判定偏差 > 0.12
//      且持續 > 0.8s 才視為主體真的走位 → GoalEaser 0.3s slerp 平滑滑移
//      q_goal（標記滑移、永不瞬移）；抖動／短暫偏差一律無視。
//  (4) v0.5.1 陀螺儀積分融合（GyroFusedPoint predict/correct + AutoGain
//      增益自動校準/持久化）整組退役：姿態是絕對量 — 無積分漂移可補、
//      無「角速度×dt×FOV」增益殘差可學。Core 檔（AimPoint.swift）與測試
//      保留（AimPointSolver 重投影/AimGeometry 顯示幾何仍在用；
//      GyroFusedPoint 契約仍在、App 不再使用）；aim.gain.* UserDefaults
//      不再讀寫（殘值無害，見檔內退役注釋）。
//  (5) motion 改 startDeviceMotionUpdates(using: .xArbitraryZVertical)：
//      重力錨定 pitch/roll（絕對穩定）、yaw 任意起點「不用磁力計」—
//      磁力校正版在室內／金屬環境偶發 yaw 跳變，姿態主導下跳變 = 標記直接跳；
//      絕對 yaw 本來就不需要（目標與當下姿態同參考系，只吃相對旋轉差），
//      無磁力的慢速 yaw 漂移由 (3) 的 Vision 覆核自然吸收。
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
    /// 對準點導引（契約 surface；A3 只讀）：世界標記顯示狀態。
    /// v0.6.0 姿態主導：100Hz 裝置姿態投影（零主體耦合）+ Vision 慢速覆核，
    /// 以 ~60Hz timer 節流發布。
    /// 只有對準 overlay（本來就逐帧重繪的 Canvas 層）應讀取 —
    /// 大型 view body 讀了會被拖著以 ~60Hz diff（見檔尾註記）。
    private(set) var aim: AimState?
    /// |標記 marker − 準星 (0.5, 0.5)|（normalized）；標記未亮時 nil。
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
    /// v0.5.0 群組模式（合照）指示：本帧 faces ≥ 2。FrameAnalyzer 已在組 facts
    /// 時對第 2 張臉起做信心門檻把關 — 這裡只看 count，語意與 union 主體框、
    /// GroupGuard 完全一致。A4 據此畫「合照」小字。只在值變化時寫入。
    private(set) var isGroupMode: Bool = false

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

    // MARK: 對準點標記（v0.4.0 融合 → v0.6.0 姿態主導）

    /// 姿態主導標記協調器（執行緒安全薄封裝，見檔尾類別；v0.6.0 起內部 =
    /// 姿態環形緩衝 + GoalEaser + SubjectMoveDetector，GyroFusedPoint
    /// 積分路徑退役）。motion queue（100Hz 姿態投影）、MainActor
    ///（承諾/覆核/reset）、analysisQueue（tracker 距離）三方共用。
    @ObservationIgnored private let aimFusion = AimFusionCoordinator()
    /// 專屬 motion 管理器（v0.6.0：100Hz deviceMotion「姿態」，不再讀
    /// rotationRate）。FrameAnalyzer 的 60Hz
    /// gravity 管理器為其檔案私有（本輪只准改本檔）→ 另建專屬實例。
    /// Apple 建議整 app 單一 CMMotionManager；多實例各以自身 interval 收回呼、
    /// 感測器以最高需求率運轉 — 兩者只在教練模式同時活躍，可接受；
    /// 後續整併輪可把姿態訂閱併進 FrameAnalyzer 的那顆（⚠ 屆時參考系必須
    /// 統一為 .xArbitraryZVertical，見 startAimUpdates 的參考系注釋）。
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
    /// 已承諾進 aimFusion 的凍結 target（承諾記帳）：planner 換靶（重新
    /// 承諾）的邊緣偵測用。v0.6.0：換靶 = 以帧時間姿態重算目標姿態 +
    /// GoalEaser 0.3s slerp 滑移（標記永不瞬移 — v0.5.1 的「跳切」語意
    /// 廢除，與覆核路徑同款滑移）；姿態樣本未就緒（motion 剛啟動）時
    /// 不記帳，下一分析 tick 自動重試（見 updateAimFusion）。
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
            isGroupMode = false
            wasLocked = false
        }
    }

    /// 相機重配（flipCamera / 鏡位切換）後：排程分析管線 + 分析器快取重置、
    /// 立即清空導引發布狀態，並推進發布世代（重置前已在處理的舊帧
    /// publish 時被世代比對丟棄 — 不讓舊環在新畫面上多留一帧）。
    private func resetGuidance() {
        // v0.6.0 修正：翻鏡／鏡位切換後「立即」刷新 FOV／前後鏡投影快取 —
        // refreshAimProjection 平時只在 ~1s 發布 tick 刷新（aimTickCount %
        // 60 == 1），而 planner 的重新承諾通常在切換後 1s 內就發生：不刷新
        // 的話 q_goal 會以「另一顆鏡頭」的 FOV 合成（例：後鏡長焦有效 vFOV
        // ~0.3 rad vs 前鏡 ~1.2 rad ⇒ 角度／標記靈敏度錯到 ~4 倍），要等
        // Vision 覆核 ~1.1s（0.8s dwell + 0.3s 滑移）才修正 — 每次翻鏡都
        // 出現 1–2s「跟不住」。本函式在 MainActor、成本僅兩次 atan + 一次
        // 鎖寫，直接刷。
        refreshAimProjection()
        expectedGeneration = pipeline.scheduleReset()
        tap.analyzer.scheduleReset()
        guidance = nil
        anchorPoint = nil
        targetPoint = nil
        lockState = .searching
        alignDistance = nil
        wasLocked = false
        // v0.6.0：取景座標跳變 → 目標姿態清除（GoalEaser／SubjectMoveDetector
        // reset）+ 標記立即熄滅。姿態環形緩衝「不清」— 裝置姿態是絕對量、
        // 與取景座標／鏡位無關，翻鏡後的下一次承諾照樣要回查「帧時間附近」
        // 的姿態樣本（清了反而要等 0.1–0.2s 緩衝重新蓋到帧延遲深度）。
        // （v0.5.1 的「翻鏡增益存取順序鐵律」三步儀式隨 AutoGain 路徑整組
        // 退役 — 姿態是絕對量，無增益可學、無狀態可落盤。）
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
        // v0.5.0 群組模式指示（少變 → 只在值變化時寫入）
        let group = output.facts.faces.count >= 2
        if group != isGroupMode {
            isGroupMode = group
            // v0.6.0：臉數跨 2 邊緣（單人錨點 ↔ 群組 union 中心）的錨點定義
            // 跳變不再需要特殊防護（v0.5.1 曾清 AutoGain 學習基準）—
            // 姿態主導下 Vision 只是慢速覆核：錨點跳變頂多讓
            // SubjectMoveDetector 的偏差計時起算，持續 > 0.8s 才會以
            // 0.3s 滑移重定目標姿態，正是期望行為。
        }
        // 實際 buffer 比例（僅接受直立帧：橫向 = 旋轉未生效，維持前值不畫錯）
        if bufferWidth > 0, bufferHeight >= bufferWidth {
            let aspect = Double(bufferWidth) / Double(bufferHeight)
            if aspect != contentAspect {
                contentAspect = aspect
            }
        }

        // v0.6.0：對準點承諾／慢速覆核步（量測 = 未平滑錨點 × 凍結目標；
        // 帧 PTS 時間 facts.timestamp 供姿態環形緩衝回查「帧當下」姿態）。
        updateAimFusion(
            guidance: output.guidance,
            rawAnchor: output.rawAnchor,
            isFront: output.facts.isFrontCamera,
            frameTime: output.facts.timestamp
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

    /// 教練啟用：刷新 FOV 快取 → 清姿態流（參考系重立）→ 啟動 100Hz
    /// deviceMotion 姿態 → 啟動 ~60Hz 發布 timer。
    private func startAimUpdates() {
        refreshAimProjection()
        // v0.6.0：motion 每次 start 都可能重立 .xArbitraryZVertical 的任意
        // yaw 參考系 — 上個啟用會期的姿態樣本與新參考系不可比，必須清空
        // （目標姿態已由 stopAimUpdates 的 aimFusion.reset() 清除）。
        aimFusion.resetAttitudeStream()
        if aimMotionManager.isDeviceMotionAvailable, !aimMotionManager.isDeviceMotionActive {
            // 契約：interval 1/100（Vision 分析 tick 之間標記靠姿態投影推進）。
            aimMotionManager.deviceMotionUpdateInterval = 1.0 / 100.0
            // 參考系選擇（v0.6.0 契約）：.xArbitraryZVertical —
            // 重力錨定 z（pitch/roll 絕對穩定）、yaw 任意起點「不用磁力計」。
            // 不選 .xMagneticNorthZVertical / .xTrueNorthZVertical：磁力校正
            // 在室內／金屬環境會偶發 yaw 跳變，姿態主導下跳變 = 標記直接跳；
            // 絕對 yaw 本來就不需要（q_goal 與 q_current 同參考系，marker
            // 只吃兩者的「相對」旋轉差），無磁力的慢速 yaw 漂移（~度/分鐘級）
            // 遠低於 SubjectMoveDetector 門檻速率，由 Vision 覆核自然吸收。
            // 只捕捉 coordinator（@unchecked Sendable、內部鎖），不捕捉 self —
            // 回呼在背景 OperationQueue，不得觸碰 MainActor 隔離狀態。
            let fusion = aimFusion
            aimMotionManager.startDeviceMotionUpdates(
                using: .xArbitraryZVertical, to: aimMotionQueue
            ) { motion, _ in
                guard let motion else { return }
                // CMAttitude.quaternion（CMQuaternion x/y/z/w）描述
                // 「裝置座標 → 參考座標」的旋轉（CoreMotion 慣例），原樣轉
                // Core Quat — 方向符號的逐步推導與單元測試在
                // Core/AttitudeMarker.swift（A1；Core 只吃純 Double，
                // 避開 CMAttitude API 的 Linux CI 禁令）。
                // ⚠ 不餵 attitude.roll（v0.6.0 修正）：完整四元數「已內含」
                // 滾轉 — Core 契約明訂 current 為完整裝置姿態時 marker 一律
                // 傳 rollRad = 0（q_rel 帶著 roll，偏移向量自動被畫面旋轉，
                // 手算推導見 AimFusionCoordinator.review）；再疊 Euler roll =
                // 對偏移「二次旋轉」。且 portrait 直立恰為 CMAttitude Euler
                // 萬向鎖奇點（pitch ≈ +90°，roll/yaw 只有和可定）—
                // attitude.roll 在此病態、微小晃動即大幅跳變，疊進投影
                // = 靜止主體下標記自搖（「不穩」）＋偏差被 roll 持續再旋轉
                // 而永不收斂 → 覆核每 0.8s 誤觸發重定目標（「飄」）。
                let q = motion.attitude.quaternion
                fusion.ingestAttitude(
                    quat: Quat(x: q.x, y: q.y, z: q.z, w: q.w),
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

    /// 教練停用：motion／timer 全停 + 目標姿態清除 + 發布熄滅。
    /// （v0.6.0：無增益可落盤 — AutoGain 持久化隨積分路徑退役。）
    private func stopAimUpdates() {
        aimMotionManager.stopDeviceMotionUpdates()
        aimPublishTimer?.invalidate()
        aimPublishTimer = nil
        aimFusion.reset()
        lastAimTarget = nil
        aim = nil
        aimDistance = nil
    }

    /// ~60Hz 發布 tick（MainActor）：讀最新姿態投影標記 → AimGeometry →
    /// aim/aimDistance。值未變不寫（@Observable 逐屬性追蹤：不寫就不觸發
    /// 讀取端 diff — 手機靜止時姿態投影值穩定，整個 tick 幾乎零發布成本）。
    private func aimPublishTick() {
        guard isActive else { return }
        aimTickCount += 1
        // FOV 快取每 ~1s 刷新一次（zoom ramp / 鏡位切換後跟上；
        // 鏡位切換另有 onCameraReconfigured → resetGuidance 立即清目標姿態。
        // FOV 變更瞬間（zoom 中）q_goal 是舊 FOV 下合成的 — 投影殘差由
        // Vision 覆核在 0.8s dwell 後以 0.3s 滑移吸收，不需即時重算）
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
    ///     FOV 會恆常錯 2 倍、標記投影靈敏度剩一半（持續性誤差，非 ramp 過渡）。
    ///     鏡像在 ramp 進行中為目標值（~1s 漸進近似，殘差由 Vision 覆核吸收），
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

    /// Vision tick 的承諾／慢速覆核步（publish 內、MainActor；已過世代比對 —
    /// 重置前的舊座標帧到不了這裡，不可能污染目標姿態）。
    ///
    /// v0.6.0 姿態主導：本函式「不再逐帧修正標記」— 標記位置由 100Hz motion
    /// tick 的姿態投影全權決定（AimFusionCoordinator.ingestAttitude），
    /// 主體晃動／偵測抖動根本進不了那條路徑。這裡只做三件事：
    ///
    /// - target 撤銷（planner 超過寬限確認主體丟失／無解）→ 目標姿態清除 +
    ///   標記熄滅（aim 發 nil）。
    /// - 承諾／重承諾（凍結 target 從 nil→值 或 值變更的分析 tick）→ 以
    ///   「靠近 frameTime 的姿態緩衝樣本 + 當帧 (rawAnchor − target) 畫面
    ///   偏移」合成 q_goal：首次 snap（標記直接出現）、換靶 retarget
    ///   （0.3s slerp 滑移 — v0.5.1 的「跳切」語意廢除：滑移同樣明確傳達
    ///   新目標，且與覆核路徑「永不瞬移」一致）。姿態樣本未就緒（motion
    ///   剛啟動／不可用）→ 本 tick 不記 lastAimTarget，下一 tick 自動重試。
    /// - 慢速覆核：P_vis = C + (rawAnchor − target)（AimPointSolver.marker，
    ///   沿用 v0.4.0 現算式）與「同帧時間的姿態版標記」比較 —
    ///   SubjectMoveDetector 判定偏差 > 0.12 且持續 > 0.8s 才視為主體真的
    ///   走位 → 重算 q_goal → 0.3s 滑移。抖動／短暫偏差一律無視 —
    ///   這正是本輪「標記不穩、跟不住、飄」的根治點。
    ///
    /// anchor 沿用「未平滑」rawAnchor（One-Euro 版留給 planner／舊 UI）：
    /// 覆核有 0.8s dwell + 0.12 門檻自帶抗噪（anchor 噪聲 ~0.01 量級，
    /// 遠低於門檻），不需要再疊平滑；且 commit 與覆核用同一量測源，
    /// 偏差基準自洽。target 必須用凍結值（當帧重算 = 回到「追會跑的靶」）。
    ///
    /// 帧與姿態的時間對齊（⚠）：分析帧有 ~100–200ms 延遲，commit／覆核
    /// 必須用「帧當下」而非「現在」的姿態 — 否則手機在這段延遲內轉過的
    /// 角度全額進 q_goal 誤差／被誤判成主體走位。coordinator 維護 0.5s
    /// 姿態環形緩衝以 facts.timestamp 回查；時基同源論證沿用 v0.5.1
    /// （frameTime 與 CMDeviceMotion.timestamp 同為開機起算 mach 時基秒），
    /// 差 > 1s 視為時基不合 → 防禦性退用當下姿態（見 attitudeNearLocked）。
    ///
    /// rawAnchor 短暫 nil（planner 寬限期掉主體）→ 本 tick 無量測可覆核，
    /// 標記純靠姿態投影續命 — 姿態主導下這本來就是常態路徑，不熄滅。
    private func updateAimFusion(
        guidance: TargetGuidance, rawAnchor: NPoint?, isFront: Bool, frameTime: Double
    ) {
        aimFusion.setIsFront(isFront)
        guard let target = guidance.target else {
            lastAimTarget = nil
            aimFusion.reset()
            if aim != nil { aim = nil }
            if aimDistance != nil { aimDistance = nil }
            return
        }
        if target != lastAimTarget {
            // 承諾／重承諾。rawAnchor nil（極端：planner 換靶帧恰逢寬限）或
            // 姿態未就緒 → 不記帳，下一 tick 以 target != lastAimTarget 重試；
            // 期間標記維持舊目標姿態（1–2 帧過渡，可接受）或尚未點亮。
            if let rawAnchor,
               aimFusion.commitGoal(anchor: rawAnchor, target: target, frameTime: frameTime) {
                lastAimTarget = target
            }
            return
        }
        if let rawAnchor {
            aimFusion.review(anchor: rawAnchor, target: target, frameTime: frameTime)
        } else {
            // v0.6.0 修正：planner 寬限期（本 tick 無主體量測）必須通報 —
            // SubjectMoveDetector 只在被餵的 tick 前進，偵測空窗期間
            // deviatedSince 殘留：空窗前一帧＋空窗後一帧兩個「孤立」偏差
            // 樣本即可湊滿 0.8s 觸發（連續偏差從未被觀測到 = 違反
            // 「持續 > 0.8s」語意；遮擋前後各一帧 Vision 抖動就會誤重定
            // 目標）。類注釋的呼叫端責任「主體丟失…請 reset()」在此落實：
            // 一帧掉檢即重啟 dwell 計時 — 正是「抖動／短暫偏差一律無視」
            // 規格要的保守行為。標記本身不受影響（純姿態投影續命）。
            aimFusion.reviewGap()
        }
    }

    // MARK: - 對準增益持久化（v0.5.1 → v0.6.0 退役）
    //
    // v0.5.1 的 AutoGain 增益持久化（aim.gain.{x,y}.{back,front} UserDefaults，
    // saveAimGains / seedAimGains / aimGainsIsFront 三件套）隨陀螺儀積分路徑
    // 整組退役：姿態主導下標記由「絕對姿態差」投影，沒有「角速度 × dt ×
    // FOV 換算」的增益殘差可學，也就沒有可落盤的狀態。舊 key 不再讀寫 —
    // 用戶裝置上的殘值無害，不做清除遷移（少一次啟動期 UserDefaults 寫入，
    // 也保留萬一回退 v0.5.1 路徑時的學得值）。

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

        // v0.5.0 GroupGuard 可能取消本帧自動抓拍 → var（見下方注入點）。
        var result = engine.evaluate(facts, config: config)
        var solved = TargetSolver.solve(facts: facts, result: result)
        // v0.6.0：對準點承諾／覆核的量測要「未平滑」當帧錨點 — 在 One-Euro
        // 覆寫前先取原始 solver 輸出（覆核有 0.8s dwell + 0.12 門檻自帶抗噪，
        // 不需疊平滑；commit 與覆核同一量測源，偏差基準自洽 —
        // 見 CoachSession.updateAimFusion 注釋）。
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
        // v0.6.0：距離餵「姿態投影 marker → 準星」（100Hz 姿態新鮮度：兩次
        // Vision 之間手機的轉動也立即反映進鎖定判斷）。門檻域不變 —
        // 標記語意 |marker − C| ≈ |anchor − target|（承諾瞬間精確相等，
        // 之後由姿態差投影延續同一尺度），tracker 參數
        // （lockAt/unlockAt/dwell）原封沿用。
        // - target 未承諾 → 必須餵 nil（→ .searching）；不得讓上一靶殘留的
        //   標記值誤導狀態機（coordinator 的 reset 在 MainActor，跨 queue
        //   有一帧時差）。
        // - 標記無值（剛啟動／剛重置／無 motion 裝置）→ fallback 當帧
        //   normalizedDistance（= v0.3.0 行為，鎖定功能不依賴 motion 存在）。
        // - planner 寬限期（target 在、當帧主體短暫丟失 → normalizedDistance
        //   nil）時標記距離仍在 → 鎖定狀態由姿態投影續命，不閃 .searching。
        // - 換靶帧（target 本帧才變 = planner 重新承諾）→ 同樣不得餵標記距離：
        //   coordinator 的 commitGoal（重算 q_goal + 0.3s 滑移）在 MainActor
        //   的 updateAimFusion，跨 queue 晚一帧 — 此刻標記還黏著「舊靶」，
        //   餵進 tracker 會以舊靶距離判新靶的鎖定（極端下 locked 多殘留
        //   一帧、maybeAutoCapture 可能對錯靶開拍）。該帧 fallback 當帧
        //   normalizedDistance（與標記無值同一退路）；下一帧起標記已在
        //   往新靶滑移，距離漸進收斂（滑移 0.3s ≪ tracker lock dwell，
        //   不影響鎖定時序）。
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
        // v0.5.0 GroupGuard（A3；合照防切人，stabilizer 前 = 契約的「publish 前」）：
        // 群組（≥2 臉）時任一臉框距畫面四邊 < jointCutEdgeMargin（0.03，契約值）
        // → 硬警告「有人被切到了」（priority 105 ≥ AdviceStabilizer 硬錯誤門檻
        // 100 → 立即插隊，不等遲滯）。臉框貼邊看的是「臉」，與規則層 jointCut
        // 看的膝/踝/腕互補 — 真切到關節（110）比「臉快出框」更嚴重，不覆蓋。
        // 同帧一併取消自動抓拍（引擎「不自動拍下明顯犯錯構圖」安全網的群組
        // 延伸；faces.count < 2 完全不進此分支 — 單人路徑不受影響）。
        if facts.faces.count >= 2 {
            let margin = config.jointCutEdgeMargin
            let anyFaceCut = facts.faces.contains { face in
                face.box.minX < margin || face.box.minY < margin
                    || face.box.maxX > 1 - margin || face.box.maxY > 1 - margin
            }
            if anyFaceCut {
                result.shouldAutoCapture = false
                if (candidate?.priority ?? Int.min) < 105 {
                    candidate = CoachAdvice(
                        category: .jointCut, message: "有人被切到了", priority: 105
                    )
                }
            }
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

// MARK: - AimFusionCoordinator（v0.6.0 姿態主導；三執行緒共用的薄封裝）

/// 姿態主導標記的執行緒安全協調器。v0.6.0 起取代 v0.4.0/v0.5.1 的
/// GyroFusedPoint 角速度積分＋AutoGain 增益路徑（Core 檔與測試保留、
/// 契約仍在，App 端不再使用 — 姿態是絕對量：無積分漂移可補、無增益可學，
/// v0.5.1 的三共症〔符號反／增益殘差／延遲回拖〕在姿態表示下根本不存在）。
///
/// 內部組件全是 Core 純數學（AttitudeProjection／GoalEaser／
/// SubjectMoveDetector — 方向符號推導與測試在 Core/AttitudeMarker.swift，
/// A1），本類只負責執行緒協調與狀態保管：
/// - aimMotionQueue（~100Hz）：ingestAttitude() 存姿態樣本（0.5s 環形緩衝）
///   ＋以「當下姿態 vs 目標姿態」投影最新標記位置 — 標記位置的唯一來源，
///   主體偵測完全不參與（零主體耦合 = 本輪穩定性的來源）。
/// - MainActor（~15fps publish）：commitGoal()／review()／reset()；
///   （~60Hz timer）讀 value。
/// - analysisQueue（tracker 距離）：distanceFromCrosshair()。
/// 全部經同一把 NSLock（臨界區皆為小常數時間運算 — 四元數乘法／≤50 筆
/// 線性掃描，100Hz 無競爭壓力）。FOV／前後鏡等投影參數由呼叫端快取餵入
/// （Core 不懂 AVFoundation）；@unchecked Sendable 的安全性由鎖保證。
private final class AimFusionCoordinator: @unchecked Sendable {

    private let lock = NSLock()

    // MARK: 投影參數（MainActor 寫入）

    /// 畫面「水平」視角（rad；對應感光器短邊 — 軸向換算見 refreshAimProjection）。
    /// 預設 = 60° 長邊基準 × 3:4 tan 換算，首次 refreshAimProjection 前的保守值。
    private var hFOVRad: Double = 2.0 * atan(tan(60.0 * Double.pi / 180.0 / 2.0) * 0.75)
    /// 畫面「垂直」視角（rad；對應感光器長邊 = videoFieldOfView 本體）。
    private var vFOVRad: Double = 60.0 * Double.pi / 180.0
    private var isFront = false

    // MARK: 姿態流（aimMotionQueue 寫入）

    /// 姿態樣本。time = CMDeviceMotion.timestamp（開機起算 mach 時基秒 —
    /// 與 facts.timestamp 同源；論證沿用 v0.5.1：AVCaptureSession 內建鏡頭
    /// PTS 掛 host time clock、CMDeviceMotion.timestamp 官方明訂開機起算秒，
    /// 兩者同一 mach 時基可直接互減；防禦 guard 見 attitudeNearLocked）。
    private struct AttitudeSample {
        var time: Double
        var quat: Quat
        // v0.6.0 修正：不存 Euler roll — 完整四元數已內含滾轉（marker 一律
        // rollRad = 0，見 review 的手算推導）；portrait 直立是 Euler 奇點，
        // attitude.roll 在此病態不可用。
    }
    /// 最近 attitudeWindow 秒的姿態環形緩衝（時間遞增）：分析帧延遲
    /// ~100–200ms，commit／覆核必須用「帧當下」的姿態而非「現在」的 —
    /// 否則手機在延遲期間轉過的角度全額進 q_goal 誤差。最新樣本 =
    /// samples.last（剪枝永不丟最新筆）。
    private var samples: [AttitudeSample] = []
    /// 保留窗 0.5s（契約值）：帧延遲 100–200ms 的 2.5 倍餘裕。
    private static let attitudeWindow: Double = 0.5
    /// 硬上限筆數：100Hz × 0.5s = 50 筆常態，128 容納極端呼叫率；
    /// 記憶體 O(1) 上界（128 × 48B ≈ 6KB）。
    private static let sampleCapacity = 128

    // MARK: 目標姿態（MainActor 寫入）

    /// q_goal 的 0.3s slerp ease-out 滑移器（Core；duration 契約值 0.3）。
    private let easer = GoalEaser(duration: 0.3)
    /// 主體走位偵測（Core；偏差 > 0.12 持續 > 0.8s 才觸發，契約值）。
    private let moveDetector = SubjectMoveDetector(threshold: 0.12, dwell: 0.8)
    /// 是否已有承諾目標姿態（easer 已 snap 過；reset 清除）。
    /// snap（首次）vs retarget（滑移）的分流依據。
    private var hasGoal = false

    /// 最新標記位置（可出界；100Hz motion tick 與 commit/review 後重算）。
    private var latestMarker: NPoint?

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

    /// motion 重啟時清姿態流：.xArbitraryZVertical 每次 start 重立任意 yaw
    /// 參考系，跨啟用會期的樣本不可比（目標姿態由呼叫端另走 reset()）。
    func resetAttitudeStream() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }

    // MARK: 姿態投影步（aimMotionQueue ~100Hz）

    /// 100Hz 姿態樣本：入環形緩衝 + 立即投影最新標記。
    /// 標記位置 = AttitudeProjection.marker(q_current, q_goal)（純姿態差，
    /// FOV 投影 + roll 補償）— 100Hz 零延遲、零主體耦合：主體怎麼晃、
    /// Vision 偵測怎麼抖，都進不了這條路徑；只有使用者自己轉動手機
    /// 會動標記。積分／dt／增益一概不存在（姿態是絕對量）。
    func ingestAttitude(quat: Quat, timestamp: Double) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(AttitudeSample(time: timestamp, quat: quat))
        // 剪枝（同 v0.5.1 緩衝模式）：留最近 attitudeWindow 秒，再套硬上限；
        // 兩規則都永不丟最新筆。removeFirst(k) 攤還 O(1)/tick。
        let cutoff = timestamp - Self.attitudeWindow
        var drop = 0
        while drop < samples.count - 1, samples[drop].time < cutoff {
            drop += 1
        }
        if samples.count - drop > Self.sampleCapacity {
            drop = samples.count - Self.sampleCapacity
        }
        if drop > 0 {
            samples.removeFirst(drop)
        }
        refreshMarkerLocked(at: timestamp)
    }

    // MARK: 承諾／覆核（MainActor ~15fps）

    /// 承諾／重承諾：以「靠近 frameTime 的姿態樣本 q_commit + 當帧
    /// (anchor − target) 畫面偏移」合成目標姿態 q_goal
    /// （AttitudeProjection.goalQuat；偏移→小旋轉的符號推導在 Core）。
    /// 首次 snap（標記直接出現在 P_vis 位置）、其後 retarget（0.3s slerp
    /// 滑移）。回傳 false = 姿態樣本未就緒（motion 剛啟動／模擬器無
    /// motion）→ 呼叫端本 tick 不記帳、下一分析 tick 自動重試。
    func commitGoal(anchor: NPoint, target: NPoint, frameTime: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let sample = attitudeNearLocked(frameTime) else { return false }
        let goal = AttitudeProjection.goalQuat(
            commit: sample.quat,
            screenOffsetX: anchor.x - target.x,
            screenOffsetY: anchor.y - target.y,
            hFOVRad: hFOVRad,
            vFOVRad: vFOVRad,
            isFront: isFront
        )
        // ease 的動畫時間軸用「最新 motion 時間」（= coordinator 的「現在」；
        // frameTime 落後 100–200ms，用它當起點會讓滑移憑空快進一截）。
        let now = samples.last?.time ?? frameTime
        if hasGoal {
            easer.retarget(to: goal, at: now)
        } else {
            easer.snap(to: goal)
            hasGoal = true
        }
        // 新目標 = 新覆核基準：偏差計時重新起算（滑移期間的暫時偏差
        // 不得計入下一次走位判定）。
        moveDetector.reset()
        refreshMarkerLocked(at: now)
        return true
    }

    /// Vision 慢速覆核（每個分析 tick；量測 = 當帧 rawAnchor × 凍結 target）：
    /// P_vis = C + (anchor − target)（AimPointSolver.marker，沿用 v0.4.0
    /// 算式）與「同帧時間的姿態版標記」比較。⚠ 比較雙方都對齊 frameTime —
    /// 姿態版標記以「帧當下」的緩衝姿態投影，帧延遲期間手機自身的轉動
    /// 兩邊同步消掉，不會被誤判成主體走位。
    /// SubjectMoveDetector 判定「偏差 > 0.12 且持續 > 0.8s」才視為主體
    /// 真的走位 → 以同帧姿態＋量測重算 q_goal → 0.3s slerp 滑移（標記
    /// 滑移、永不瞬移）；抖動／短暫偏差一律無視。
    func review(anchor: NPoint, target: NPoint, frameTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard hasGoal, let sample = attitudeNearLocked(frameTime) else { return }
        let now = samples.last?.time ?? frameTime
        guard let goal = easer.value(at: now) else { return }
        // 姿態版標記（frameTime 對齊）。goal 取 ease 瞬時值：滑移期間
        // P_vis 與滑移中標記的殘差 < 門檻起算條件，且 commit/review 觸發後
        // 都 reset 偵測器 — 不會因滑移自觸發。
        // rollRad = 0（Core 契約：current 為「完整」裝置姿態時滾轉已內含於
        // q_rel 投影）。手算證明：commit = 單位、goal = R_y(−a)（目標在畫面
        // 右 offset a/hFOV），裝置繞自身 z 滾 φ ⇒ current = R_z(φ)、
        // q_rel = R_z(−φ)⊗R_y(−a) ⇒ v = R_z(−φ)·(sin a, 0, −cos a)
        //       = (sin a·cosφ, −sin a·sinφ, −cos a)、fwd = cos a
        // ⇒ 偏移 = (a·cosφ/hFOV, a·sinφ/vFOV) — 基準偏移 (a/hFOV, 0) 已被
        // roll 旋轉 φ；再傳 rollRad = 對偏移二次旋轉（雙重計算）。
        let attitudeMarker = AttitudeProjection.marker(
            current: sample.quat,
            goal: goal,
            hFOVRad: hFOVRad,
            vFOVRad: vFOVRad,
            rollRad: 0,
            isFront: isFront
        )
        let visionMarker = AimPointSolver.marker(anchor: anchor, target: target)
        guard moveDetector.update(
            visionMarker: visionMarker, attitudeMarker: attitudeMarker, at: frameTime
        ) else { return }
        // 主體確定走位：以「同一帧」的姿態與量測重算 q_goal → 滑移。
        let newGoal = AttitudeProjection.goalQuat(
            commit: sample.quat,
            screenOffsetX: anchor.x - target.x,
            screenOffsetY: anchor.y - target.y,
            hFOVRad: hFOVRad,
            vFOVRad: vFOVRad,
            isFront: isFront
        )
        easer.retarget(to: newGoal, at: now)
        // 滑移期間偏差必然暫時仍大 — 立刻重置偵測器（dwell 重新起算），
        // 否則下一 tick 又觸發、每 tick retarget 一次（雖仍收斂但無謂）。
        moveDetector.reset()
        refreshMarkerLocked(at: now)
    }

    /// 偵測空窗通報（MainActor；planner 寬限期、本 tick 無主體量測）：
    /// 清 SubjectMoveDetector 的 dwell 時鐘 — 「持續 > 0.8s」必須是
    /// 「連續觀測到」的偏差，跨空窗的孤立樣本不得湊數（呼叫端語意見
    /// CoachSession.updateAimFusion）。目標姿態與標記一概不動。
    func reviewGap() {
        lock.lock()
        defer { lock.unlock() }
        moveDetector.reset()
    }

    /// 清目標姿態（easer／moveDetector）＋標記熄滅。姿態環形緩衝「不清」—
    /// 裝置姿態是絕對量、與取景座標／目標無關（清緩衝屬 motion 參考系
    /// 重立：resetAttitudeStream）。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        easer.reset()
        moveDetector.reset()
        hasGoal = false
        latestMarker = nil
    }

    // MARK: 讀值

    /// 最新姿態投影標記（可出界）；nil = 尚無承諾目標／已熄滅。
    var value: NPoint? {
        lock.lock()
        defer { lock.unlock() }
        return latestMarker
    }

    /// |標記 − 準星|（GuidanceTracker 餵入用；analysisQueue 呼叫）。
    func distanceFromCrosshair() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let v = latestMarker else { return nil }
        let dx = v.x - AimPointSolver.crosshair.x
        let dy = v.y - AimPointSolver.crosshair.y
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: 內部（呼叫端持鎖）

    /// 靠近時刻 t 的姿態樣本：緩衝內線性掃 |time − t| 最小者（n ≤ 50，
    /// 15fps 呼叫下成本可忽略）。防禦（v0.5.1 同款 guard，有它永不劣於
    /// 沒有）：最佳樣本與 t 差 > 1.0s = 時基不合（capture clock 非 host
    /// clock 的外接鏡頭／未來 OS）或樣本過舊 → 退用「當下」樣本
    /// （= 放棄延遲對齊，仍優於不承諾）；完全無樣本 → nil（呼叫端重試）。
    private func attitudeNearLocked(_ t: Double) -> AttitudeSample? {
        guard let newest = samples.last else { return nil }
        var best = newest
        var bestDiff = abs(newest.time - t)
        for sample in samples {
            let diff = abs(sample.time - t)
            if diff < bestDiff {
                best = sample
                bestDiff = diff
            }
        }
        return bestDiff > 1.0 ? newest : best
    }

    /// 以「最新姿態 vs 目標姿態（ease 瞬時值）」重算最新標記。
    /// 呼叫路徑上 hasGoal 與樣本必在（guard 僅為防禦：條件不足時維持
    /// 前值，熄滅語意一律由 reset 負責 — 不在此偷偷清 nil）。
    private func refreshMarkerLocked(at time: Double) {
        guard hasGoal, let newest = samples.last, let goal = easer.value(at: time) else {
            return
        }
        // rollRad = 0：current 為完整裝置姿態，滾轉已內含於 q_rel 投影
        // （Core 契約；手算推導見 review()）。
        latestMarker = AttitudeProjection.marker(
            current: newest.quat,
            goal: goal,
            hFOVRad: hFOVRad,
            vFOVRad: vFOVRad,
            rollRad: 0,
            isFront: isFront
        )
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
//  標記已由姿態 100Hz 投影（v0.6.0），顯示端「不需要」再補間。
