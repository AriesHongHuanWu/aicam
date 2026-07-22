//  CameraController.swift
//  AICam — 相機控制器（A2：相機層）。MASTER-PLAN §8 P0 子集 + D8。
//
//  架構：
//  - CameraController：@MainActor @Observable，UI 讀的狀態全在這裡（跨模組契約 surface）。
//  - CaptureSessionService：非隔離 @unchecked Sendable，持有 AVCaptureSession；
//    所有 session / device 操作限定在私有 sessionQueue 上執行，
//    透過 async 方法（withCheckedContinuation）把結果送回 MainActor。
//  - 拍照：capturePhoto() async 以 continuation 包 PhotoCaptureDelegate；
//    isCapturing 防重入；閃光燈 P0 一律 .off；HEVC 可用才用，否則 JPEG。
//
//  v0.3.0（AI 全面接管）新增：
//  - AI 代操曝光契約：applyExposureBias / setExposurePoint / currentExposureBias
//    （AIControlCenter 呼叫；device 操作全在 sessionQueue，bias 鏡像值供同步讀）。
//  - captureLookProvider：拍照處理背景 queue 詢問要烘焙的 LookRecipe；
//    非 passthrough → LookEngine 轉出帶 Look 的 JPEG 存相簿（失敗 fallback 原檔，
//    look.keepOriginal 開啟時原檔一併存）。
//  - 單一共用 videoTap（本控制器擁有）＋出帧仲裁：attachVideoTapIfNeeded 冪等
//    掛載自有 tap（非教練模式的即時濾鏡預覽用）；setVideoTapEnabled（教練）與
//    setPreviewFramesEnabled（Metal 預覽）任一需要即出帧，互不誤關。
//  - 重配（啟動/切鏡）時曝光狀態歸中性：AVCaptureDevice 是共享實例，
//    bias / 測光點會跨 session 殘留，必須主動歸零。
//
//  v0.4.0（對準點導引 + AI 代操擴充）新增：
//  - currentHorizontalFOVDegrees()：activeFormat.videoFieldOfView 鏡像
//    （A2 陀螺儀角度→normalized 位移換算用；語意警告見方法注釋 — 直立顯示時
//    此「水平」視角對應畫面的「垂直」方向）。
//  - rampZoom(to:rate:)：AI 自動變焦（AIControlCenter 呼叫）；平滑 ramp、
//    夾到裝置範圍、currentLens 同步為最接近焦段（LensBar 高亮跟著走）。

import AVFoundation
import Observation
import UIKit
import AICamCore

@MainActor
@Observable
final class CameraController {

    enum Status { case idle, running, denied, failed }

    private(set) var status: Status = .idle
    private(set) var lensOptions: [LensOption] = []
    private(set) var currentLens: LensOption?
    private(set) var isFront: Bool = false
    private(set) var lastThumbnail: UIImage?
    private(set) var isCapturing: Bool = false

    let previewSource: PreviewSource

    /// 拍照成功後回傳 ~1280px JPEG data（教練 / 導演層用）。
    var onPhotoCaptured: ((Data) -> Void)?

    /// 相機重配完成（前後鏡切換／鏡位切換 = 取景座標整體跳變）後通知。
    /// CoachSession 據此重置導引管線（planner / One-Euro / tracker / stabilizer），
    /// 舊座標不得帶進新畫面（A5 設定；MainActor 上呼叫）。
    var onCameraReconfigured: (() -> Void)?

    /// 拍照 Look 供應者（v0.3.0 契約；A3/A4 接線）。
    /// 拍照處理於「背景 queue」呼叫（契約明定）：回 nil 或 passthrough = 不烘焙。
    /// 閉包必須執行緒安全 — 建議只讀不可變值或 UserDefaults，
    /// 勿在閉包內碰 MainActor 隔離狀態（Swift 5 模式不會擋，靠紀律）。
    @ObservationIgnored var captureLookProvider: (() -> LookRecipe?)?

    private let service: CaptureSessionService

    /// 教練分析與 Metal 即時濾鏡預覽「共用」的單一 video tap（v0.3.0 修正輪）：
    /// 一般 session 只能掛一顆 AVCaptureVideoDataOutput → CoachSession 與
    /// MetalPreviewView 必須用同一實例（CoachSession init 取這裡；RootView 直讀
    /// 傳給 MetalPreviewView）。
    @ObservationIgnored let videoTap = VideoFrameTap()

    /// 出帧需求仲裁（MainActor；v0.3.0 修正輪）：教練分析（CoachSession.setActive）
    /// 與 Metal 即時預覽（RootView 依取景器可見性）各自表態，任一需要即開
    /// connection — 離開教練模式不得誤關拍照模式的即時濾鏡取景器。
    @ObservationIgnored private var coachWantsFrames = false
    @ObservationIgnored private var previewWantsFrames = false

    init() {
        let service = CaptureSessionService()
        self.service = service
        self.previewSource = PreviewSource(session: service.session)
    }

    // MARK: - 生命週期

    /// 要求相機權限 → 配置 session → 啟動。
    func start() async {
        guard status != .running else { return }

        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }
        guard granted else {
            status = .denied
            return
        }

        guard let options = await service.configureAndStart(front: isFront) else {
            status = .failed
            return
        }
        applyLensOptions(options)
        status = .running
    }

    func stop() {
        service.stop()
        if status == .running { status = .idle }
    }

    // MARK: - 鏡頭

    func select(lens: LensOption) {
        guard status == .running, lensOptions.contains(lens) else { return }
        let changed = lens != currentLens
        currentLens = lens
        service.setZoom(factor: lens.zoomFactor, ramped: true)
        // 焦段真的變了才通知（重按同一顆鏡頭不清教練導引狀態）
        if changed {
            onCameraReconfigured?()
        }
    }

    /// 前後鏡切換：重配 input 並重算焦段表。失敗時嘗試回復原鏡位。
    func flipCamera() async {
        guard status == .running, !isCapturing else { return }
        let targetFront = !isFront

        guard let options = await service.configureAndStart(front: targetFront) else {
            if let restored = await service.configureAndStart(front: isFront) {
                applyLensOptions(restored)
                // 回復原鏡也重配過 session（帧序中斷）→ 一樣通知教練層重置
                onCameraReconfigured?()
            } else {
                status = .failed
            }
            return
        }
        isFront = targetFront
        applyLensOptions(options)
        onCameraReconfigured?()
    }

    // MARK: - 拍照

    func capturePhoto() async {
        guard status == .running, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let data = await service.capturePhoto() else { return }

        // v0.3.0 Look 烘焙：provider 於「背景 queue」呼叫（契約）；
        // nil / passthrough → lookJPEG = nil，流程與 v0.2.1 完全相同。
        // 縮圖與教練/導演 1280px JPEG 一律以「實際存入相簿的樣子」為準
        //（有 Look 用烘焙後影像 — 縮圖、導演評語都對應用戶真正拿到的照片）。
        let provider = captureLookProvider
        let keepOriginal = UserDefaults.standard.bool(forKey: "look.keepOriginal")

        let outputs = await Task.detached(
            priority: .userInitiated
        ) { () -> (processed: ProcessedPhoto, lookJPEG: Data?) in
            var lookJPEG: Data?
            if let recipe = provider?(), recipe.id != LookRecipe.passthrough.id {
                lookJPEG = CapturedPhotoProcessor.bakeLook(into: data, recipe: recipe)
            }
            let processed = CapturedPhotoProcessor.process(lookJPEG ?? data)
            return (processed, lookJPEG)
        }.value

        // 存相簿（addOnly；PhotoSaver 內部處理權限請求，路徑復用）：
        // 有 Look → 存烘焙 JPEG；look.keepOriginal 開啟時原檔（HEIF/JPEG）也一併存。
        // 烘焙失敗（lookJPEG nil）→ fallback 存原檔，照片永不丟失。
        if let lookJPEG = outputs.lookJPEG {
            _ = await PhotoSaver.save(photoData: lookJPEG)
            if keepOriginal {
                _ = await PhotoSaver.save(photoData: data)
            }
        } else {
            _ = await PhotoSaver.save(photoData: data)
        }

        if let thumbnail = outputs.processed.thumbnail {
            lastThumbnail = thumbnail
        }
        if let jpeg = outputs.processed.coachJPEG {
            onPhotoCaptured?(jpeg)
        }
    }

    // MARK: - AI 代操曝光（v0.3.0 契約；AIControlCenter 呼叫）

    /// 設定曝光補償 EV（sessionQueue 上執行；夾到 device.minExposureTargetBias…max）。
    /// AE 維持 continuousAutoExposure 下 bias 是疊加偏移 → 立即反映在 preview。
    func applyExposureBias(_ ev: Float) {
        service.setExposureBias(ev)
    }

    /// 最近一次成功套用（夾限後）的曝光補償鏡像值；重配（啟動/切鏡）後歸 0。
    /// 同步、非阻塞（不讀 device 本體 — device 狀態限 sessionQueue，
    /// 這裡讀 service 的鎖保護鏡像），供 AIControlCenter 決策用。
    func currentExposureBias() -> Float {
        service.currentExposureBias()
    }

    /// 設定曝光測光點。輸入 NormalizedFrame 頂左座標（直立顯示帧、前鏡已鏡像）；
    /// 內部轉 AVFoundation 感光元件空間並處理前鏡（推導見 service 注釋）。
    /// 裝置不支援 POI 時靜默略過。
    func setExposurePoint(normalizedX: Double, y: Double) {
        service.setExposurePoint(normalizedX: normalizedX, y: y)
    }

    // MARK: - AI 代操變焦與 FOV（v0.4.0 契約；AIControlCenter / CoachSession 呼叫）

    /// 當前 activeFormat 的水平視角（度）。session 尚未成功配置（或裝置回報 0）
    /// 時回 nil — 呼叫端（A2）fallback 60°。
    ///
    /// 座標語意警告（v0.4.0 對準點導引換算最易錯處，逐步寫明）：
    /// videoFieldOfView 是「感光元件原生 landscape 影像的橫向（長邊）」視角。
    /// 本 app 直立 portrait 顯示（connection videoRotationAngle=90）→
    /// 感光器長邊直立後成為畫面的「垂直」方向 — 亦即此值對應畫面 y 軸的視角；
    /// 畫面 x 軸（水平）視角對應感光器短邊，需由呼叫端依帧長寬比換算
    ///（A2 責任，本 API 只回裝置原始值，不做任何軸向換算）。
    /// 另注意：此值是該 format 在 videoZoomFactor = 1.0 的基準 —
    /// 數位變焦後有效視角 ≈ 2·atan(tan(FOV/2) / zoomFactor)；
    /// 目前 zoom factor 讀 currentZoomFactor()（實際 videoZoomFactor 鏡像，
    /// 非 currentLens 的量化焦段值 — 兩者在 ramp 到非焦段 factor 時不同，
    /// 見 rampZoom / CaptureSessionService.zoomFactorMirror 注釋）。
    ///
    /// 同步、非阻塞：讀 service 鎖保護的鏡像值（configureAndStart 成功時更新），
    /// 不碰 sessionQueue 隔離的 device 本體（與 currentExposureBias 同模式）。
    func currentHorizontalFOVDegrees() -> Double? {
        service.currentHorizontalFOVDegrees().map(Double.init)
    }

    /// 實際 videoZoomFactor（夾限後鏡像值；v0.4.0 修正輪）。
    /// currentLens 只是「最接近焦段」的 UI 高亮近似 — FOV 換算與 AI 顯示倍率
    /// 判斷必須讀本值（三鏡 Pro 上 2x = factor 4.0 時 currentLens 停在 1x@2.0，
    /// 差 2 倍）。ramp 進行中回傳 ramp 目標值（漸進近似，注釋見 service）。
    func currentZoomFactor() -> CGFloat {
        service.currentZoomFactor()
    }

    /// 平滑 zoom 到指定 factor（AI 自動變焦；v0.4.0 契約）。
    /// sessionQueue 上 ramp(toVideoZoomFactor:withRate:)，夾到裝置支援範圍；
    /// 既有 select(lens:) 不動、不經過本方法。
    ///
    /// UI 狀態同步：currentLens 改為「最接近目標 factor」的 LensOption —
    /// LensBar 既有高亮邏輯讀 currentLens 即自動生效，不改 UI 檔。
    /// 焦段實際變化（目標 factor 偏離原 currentLens）時發 onCameraReconfigured，
    /// 與 select(lens:) 同語意：取景範圍跳變，教練層須重置導引
    ///（planner 凍結 target 的 normalized 座標在新視角下失效）。
    func rampZoom(to factor: CGFloat, rate: Float) {
        guard status == .running else { return }
        // previousFactor 讀「實際」zoom 鏡像而非 currentLens 量化值：
        // 三鏡 Pro ramp 到 2x（factor 4.0）後 currentLens 停在 1x@2.0，
        // 用它比對會把「同值重 ramp」誤判為變化 → 每次誤發 onCameraReconfigured
        // 清空教練導引／融合器。鏡像值同值重 ramp 時正確跳過通知。
        let previousFactor = currentZoomFactor()
        service.rampZoom(to: factor, rate: rate)
        if let nearest = lensOptions.min(by: {
            abs($0.zoomFactor - factor) < abs($1.zoomFactor - factor)
        }) {
            currentLens = nearest
        }
        if abs(previousFactor - factor) > 0.01 {
            onCameraReconfigured?()
        }
    }

    // MARK: - 教練分析 tap（A5：CoachSession 掛載一次）

    /// 把教練層的 AVCaptureVideoDataOutput 接進 session（sessionQueue 上執行）；
    /// 之後前後鏡重配時會自動對新 connection 重設 rotation / mirroring。
    func attachVideoTap(_ tap: VideoFrameTap) {
        service.attachVideoTap(tap)
    }

    /// 教練分析的出帧需求（CoachSession.setActive 驅動；契約簽名不變）。
    /// v0.3.0 修正輪：實際 connection 開關改走仲裁 — 教練或 Metal 預覽任一
    /// 需要即出帧；兩者皆不需要才停帧（不拆 output，不付 30fps 功耗成本）。
    /// 前後鏡重配後的新 connection 沿用仲裁後狀態。
    func setVideoTapEnabled(_ enabled: Bool) {
        coachWantsFrames = enabled
        applyTapFrameArbitration()
    }

    /// Metal 即時濾鏡預覽的出帧需求（RootView 依取景器可見性驅動；v0.3.0 修正輪）。
    /// 進同一套仲裁：教練不啟用時 Metal 取景器也要有帧；Metal 退場（關開關/
    /// 失敗 fallback）且教練不啟用 → 停帧省電。
    func setPreviewFramesEnabled(_ enabled: Bool) {
        previewWantsFrames = enabled
        applyTapFrameArbitration()
    }

    /// 確保本控制器擁有的 videoTap 已掛在 session 上（冪等；v0.3.0 修正輪：
    /// 原版在 tap 未經教練層註冊前是 no-op → 非教練模式的 Metal 取景器永遠
    /// 收不到帧。現在直接註冊自有 tap；教練層 attachVideoTap 傳同一實例，
    /// service 端冪等處理）。
    func attachVideoTapIfNeeded() {
        service.attachVideoTap(videoTap)
    }

    /// 仲裁後套用 connection 出帧狀態（sessionQueue 上執行）。
    private func applyTapFrameArbitration() {
        service.setVideoTapEnabled(coachWantsFrames || previewWantsFrames)
    }

    // MARK: - 私有

    private func applyLensOptions(_ options: [LensOption]) {
        lensOptions = options
        currentLens = DeviceMatrix.defaultLens(in: options)
        // 預設 zoom（如 1x = virtual device 的第一個 switchover）
        // 已由 CaptureSessionService 在配置時直接設好，這裡只同步 UI 狀態。
    }
}

// MARK: - CaptureSessionService

/// 持有 AVCaptureSession 與拍照 delegate 的服務物件。
/// 所有可變狀態只在 sessionQueue 上讀寫；對外方法可從任何 actor 呼叫。
final class CaptureSessionService: @unchecked Sendable {

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.arieswu.aicam.sessionQueue")
    private let photoOutput = AVCapturePhotoOutput()
    /// 以下狀態僅限 sessionQueue 存取。
    private var videoInput: AVCaptureDeviceInput?
    private var inflightDelegates: [Int64: PhotoCaptureDelegate] = [:]
    /// 教練層 video tap（A5）；attach 後常駐。
    private var videoTap: VideoFrameTap?
    /// tap connection 是否出帧（CoachSession.setActive 驅動；重配後套用到新 connection）。
    /// 預設 false：attach 恆發生在教練首次啟用時，緊接的 setVideoTapEnabled(true)
    /// 在同一 serial queue 上排在 attach 之後，順序保證先關後開。
    private var videoTapEnabled = false

    /// 曝光補償鏡像值的鎖（v0.3.0）：sessionQueue 寫、任意執行緒讀。
    private let stateLock = NSLock()
    /// 最近一次成功套用（夾限後）的曝光補償；重配時歸 0（stateLock 保護）。
    /// 不直接讀 device.exposureTargetBias：device 狀態限 sessionQueue 存取，
    /// 同步讀 device 需 sessionQueue.sync（重配中會卡主執行緒）— 鏡像值可行
    /// 因為本 app 只有 AI 這一條寫入路徑（無手動曝光 UI），鏡像即真值。
    private var exposureBiasMirror: Float = 0
    /// activeFormat.videoFieldOfView 鏡像（度；v0.4.0，stateLock 保護）。
    /// configureLocked 成功 commit 後更新；nil = 尚未配置或裝置回報 0。
    /// 語意警告見 CameraController.currentHorizontalFOVDegrees() 注釋。
    private var horizontalFOVMirror: Float?
    /// 實際 videoZoomFactor 鏡像（v0.4.0 修正輪；stateLock 保護）。
    /// setZoom / rampZoom / configureLocked 更新為「夾限後的目標值」。
    /// 為什麼不能用 currentLens?.zoomFactor 代替：currentLens 只是「最接近
    /// 焦段」的量化值 — 三鏡 Pro（0.5x@1 / 1x@2 / 3x@6）ramp 到 2x（factor 4.0）
    /// 時與 1x@2、3x@6 等距、min(by:) 取 1x → currentLens 讀 2.0 而實際 4.0，
    /// FOV 換算錯 2 倍、AI 顯示倍率判斷恆 1.0（規則 e 每 20s 重複觸發）。
    /// 已知近似：ramp 是漸進的，鏡像存的是 ramp「目標值」— ramp 進行中
    /// （~1s）鏡像超前實際值；停在任何 factor 後即為精確值。
    private var zoomFactorMirror: CGFloat = 1.0

    // MARK: 對外（任意 actor）

    /// 配置指定鏡位（beginConfiguration/commitConfiguration）並啟動 session。
    /// 成功回傳該鏡位的焦段表；失敗回 nil。
    func configureAndStart(front: Bool) async -> [LensOption]? {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                let options = self.configureLocked(front: front)
                if options != nil, !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume(returning: options)
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// 設定 videoZoomFactor；ramped = true 用平滑 zoom。
    func setZoom(factor: CGFloat, ramped: Bool) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(
                    max(factor, device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor
                )
                if ramped {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 5)
                } else {
                    device.videoZoomFactor = clamped
                }
                device.unlockForConfiguration()
                self.stateLock.lock()
                self.zoomFactorMirror = clamped
                self.stateLock.unlock()
            } catch {
                // lock 失敗：本次 zoom 不套用、鏡像值不更新（保持一致）
            }
        }
    }

    /// 設定曝光補償（v0.3.0）：sessionQueue 上 lock → set → unlock，夾到裝置範圍。
    func setExposureBias(_ ev: Float) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            let clamped = min(
                max(ev, device.minExposureTargetBias),
                device.maxExposureTargetBias
            )
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
                self.stateLock.lock()
                self.exposureBiasMirror = clamped
                self.stateLock.unlock()
            } catch {
                // lock 失敗：本次 bias 不套用、鏡像值不更新（保持一致）
            }
        }
    }

    /// 曝光補償鏡像值（任意執行緒；stateLock 保護、非阻塞）。
    func currentExposureBias() -> Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return exposureBiasMirror
    }

    /// activeFormat 水平視角鏡像（度；任意執行緒；stateLock 保護、非阻塞；v0.4.0）。
    func currentHorizontalFOVDegrees() -> Float? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return horizontalFOVMirror
    }

    /// 平滑 zoom（v0.4.0 AI 自動變焦）：sessionQueue 上夾到裝置範圍後 ramp。
    /// rate 單位 = zoom factor 的 2 的冪次／秒（AVFoundation 語意）。
    func rampZoom(to factor: CGFloat, rate: Float) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(
                    max(factor, device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor
                )
                device.ramp(toVideoZoomFactor: clamped, withRate: rate)
                device.unlockForConfiguration()
                self.stateLock.lock()
                self.zoomFactorMirror = clamped
                self.stateLock.unlock()
            } catch {
                // lock 失敗：本次 zoom 不套用、鏡像值不更新（保持一致）
            }
        }
    }

    /// 實際 videoZoomFactor 鏡像值（任意執行緒；stateLock 保護、非阻塞；
    /// v0.4.0 修正輪）。ramp 進行中為目標值（注釋見 zoomFactorMirror）。
    func currentZoomFactor() -> CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        return zoomFactorMirror
    }

    /// 曝光測光點（v0.3.0）。輸入 NormalizedFrame（直立顯示帧頂左原點、前鏡已鏡像）。
    ///
    /// AVFoundation POI 空間推導（reviewer 驗算用）：
    /// exposurePointOfInterest 的 (0,0) = 感光元件「原生 landscape 影像」左上、
    /// (1,1) = 右下（Apple 文件的 home 鍵在右 landscape 即後鏡原生方向）。
    /// - 後鏡原生 = landscapeRight（home 鍵在右）。直立 buffer（本 app connection
    ///   已設 videoRotationAngle=90）是原生影像「順時針轉 90°」而來：normalized 下
    ///   CW90 為 (u,v) → (x,y) = (1−v, u)，反解 u = y、v = 1−x → POI = (y, 1−x)。
    ///   驗算：直立帧頂緣中點 (0.5, 0) → POI (0, 0.5) = 原生影像左緣中點 ——
    ///   直拿手機時場景上方確實成像在原生 landscape 帧的左緣 ✓。
    /// - 前鏡原生 = landscapeLeft（home 鍵在左，感光元件與後鏡 180° 裝配），
    ///   且本 app 前鏡 connection isVideoMirrored=true（NormalizedFrame 與 preview
    ///   視覺一致）。逐軸推導：原生 landscapeLeft 時 u+ 軸沿機身「頂→底」方向 →
    ///   直拿時 u+ 指向下，與 y 同向且鏡像不影響垂直向 → u = y；v+ 軸沿機身
    ///   「左緣→右緣」= 用戶右手方向，鏡像 preview 中用戶右手在 x→1 側 → v = x。
    ///   → POI = (y, x)。與後鏡相比 x 不再翻轉：180° 裝配與鏡像在水平向恰好抵銷。
    func setExposurePoint(normalizedX: Double, y: Double) {
        sessionQueue.async {
            guard let device = self.videoInput?.device,
                  device.isExposurePointOfInterestSupported
            else { return }
            let nx = min(max(normalizedX, 0), 1)
            let ny = min(max(y, 0), 1)
            let front = device.position == .front
            let poi = front ? CGPoint(x: ny, y: nx) : CGPoint(x: ny, y: 1 - nx)
            do {
                try device.lockForConfiguration()
                // 順序鐵律：先設 point、再重設 exposureMode，AE 才以新點重新收斂。
                device.exposurePointOfInterest = poi
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                // lock 失敗：放棄本次測光點設定
            }
        }
    }

    /// 拍一張，回傳原始檔 data（HEIF/JPEG）；失敗回 nil。
    func capturePhoto() async -> Data? {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                guard self.videoInput != nil, self.session.isRunning else {
                    continuation.resume(returning: nil)
                    return
                }

                let settings = self.makePhotoSettings()
                let id = settings.uniqueID
                let delegate = PhotoCaptureDelegate { [weak self] data in
                    continuation.resume(returning: data)
                    guard let self else { return }
                    self.sessionQueue.async {
                        self.inflightDelegates[id] = nil
                    }
                }
                // AVFoundation 弱持有 delegate：完成前存 dictionary 強持有
                self.inflightDelegates[id] = delegate

                // 直向固定（雙保險；配置時已設過）
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// 教練層 video tap 掛載（A5）：加 output 並設 connection 的 rotation / mirroring。
    /// 可在 session 尚未配置時呼叫（connection 尚不存在則只記住 tap，configureLocked 時補設）。
    func attachVideoTap(_ tap: VideoFrameTap) {
        sessionQueue.async {
            if self.videoTap !== tap, let old = self.videoTap {
                // 換 tap（正常流程不發生，防禦）：先拆舊 output —
                // 一般 session 掛第二顆 AVCaptureVideoDataOutput 會 canAddOutput 失敗，
                // 不拆會讓新 tap 永遠收不到帧。
                self.session.beginConfiguration()
                self.session.removeOutput(old.output)
                self.session.commitConfiguration()
            }
            self.videoTap = tap
            self.ensureVideoTapAttachedLocked()
        }
    }

    /// 已註冊 tap 的冪等重掛（v0.3.0 契約）：未註冊過 tap 時 no-op。
    func attachVideoTapIfNeeded() {
        sessionQueue.async {
            self.ensureVideoTapAttachedLocked()
        }
    }

    /// 教練 tap connection 出帧開關（A5：CoachSession.setActive 驅動）。
    func setVideoTapEnabled(_ enabled: Bool) {
        sessionQueue.async {
            self.videoTapEnabled = enabled
            self.videoTap?.output.connection(with: .video)?.isEnabled = enabled
        }
    }

    // MARK: sessionQueue only

    /// 把已註冊的 tap output 掛進 session 並配置 connection（僅 sessionQueue；冪等：
    /// 已掛 = 跳過 addOutput、connection 設定重設為相同值）。attachVideoTap 與
    /// attachVideoTapIfNeeded 共用（v0.3.0 抽出）。
    private func ensureVideoTapAttachedLocked() {
        guard let tap = videoTap else { return }
        session.beginConfiguration()
        if !session.outputs.contains(tap.output), session.canAddOutput(tap.output) {
            session.addOutput(tap.output)
        }
        configureVideoTapConnectionLocked(
            front: videoInput?.device.position == .front
        )
        session.commitConfiguration()
    }

    /// 對 video tap 的 connection 設直向 90° 與前鏡 mirroring（僅 sessionQueue）。
    /// automaticallyAdjustsVideoMirroring 必須先關才准手動設 isVideoMirrored（順序不可倒）。
    /// 前鏡設 isVideoMirrored=true → buffer 與 preview 視覺一致，Vision 結果不需再翻 x。
    private func configureVideoTapConnectionLocked(front: Bool) {
        guard let tap = videoTap else { return }
        tap.setFrontCamera(front)
        guard let connection = tap.output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = front
        }
        // 重配後的新 connection 預設出帧：沿用教練模式的開關狀態
        // （例：拍照模式下切前後鏡，tap 應維持停帧）。
        connection.isEnabled = videoTapEnabled
    }

    /// 重配 input（先移除舊的）＋確保 photoOutput 已加入。成功回傳焦段表。
    private func configureLocked(front: Bool) -> [LensOption]? {
        guard let device = DeviceMatrix.bestDevice(front: front),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }

        session.beginConfiguration()
        session.sessionPreset = .photo

        if let old = videoInput {
            session.removeInput(old)
            videoInput = nil
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)
        videoInput = input

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                return nil
            }
            session.addOutput(photoOutput)
        }

        let options = DeviceMatrix.lensOptions(for: device)

        // 預設鏡位 zoom：有超廣角的 virtual device 1.0 = 0.5x，
        // 直接把 1x（第一個 switchover）設成起始 zoom，避免開場是超廣角。
        // appliedZoom 同步進 zoomFactorMirror（重配 = zoom 狀態重來）。
        var appliedZoom: CGFloat = 1.0
        if let defaultLens = DeviceMatrix.defaultLens(in: options),
           defaultLens.zoomFactor != 1.0 {
            do {
                try device.lockForConfiguration()
                let clamped = min(
                    max(defaultLens.zoomFactor, device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor
                )
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                appliedZoom = clamped
            } catch {
                // 失敗就維持 1.0，UI 仍可手動選鏡
            }
        }

        // 曝光狀態歸中性（v0.3.0 AI 代操）：AVCaptureDevice 是共享實例，
        // 上一段 session 的 bias / 測光點會殘留 → 重配（啟動/切鏡）一律回
        // bias 0、POI 中心、continuousAutoExposure，AI 對新畫面重新決策。
        // v0.2.1 從未動過曝光（裝置本來就是這組預設值），此舉不改變既有行為。
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(0, completionHandler: nil)
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            // lock 失敗：維持裝置現狀（殘留 bias），AI 下次動作時會再套用
        }
        stateLock.lock()
        exposureBiasMirror = 0
        zoomFactorMirror = appliedZoom
        stateLock.unlock()

        // 直向固定：session 內所有支援的 connection（含已附掛的 preview layer）都轉 90°
        for connection in session.connections where connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        // 教練 video tap 的 connection 在 input 重配後是新物件：
        // 重設 rotation / 前鏡 mirroring（A5；flipCamera 走這條路徑）
        configureVideoTapConnectionLocked(front: front)

        session.commitConfiguration()

        // FOV 鏡像更新（v0.4.0）：commit 後 activeFormat 才確定（sessionPreset
        // 於 commit 時真正套用），不能在 begin/commit 之間讀。
        // videoFieldOfView 語意警告見 CameraController.currentHorizontalFOVDegrees()。
        let fov = device.activeFormat.videoFieldOfView
        stateLock.lock()
        horizontalFOVMirror = fov > 0 ? fov : nil
        stateLock.unlock()

        return options
    }

    /// HEVC 可用 → HEIF；否則系統預設（JPEG）。閃光燈 P0 一律 .off。
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        return settings
    }
}
