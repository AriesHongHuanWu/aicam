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

import AVFoundation
import Observation
import UIKit

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

    private let service: CaptureSessionService

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

        // 存相簿（addOnly）與縮圖 / 1280px JPEG 併行處理
        async let saved = PhotoSaver.save(photoData: data)
        let outputs = await Task.detached(priority: .userInitiated) {
            CapturedPhotoProcessor.process(data)
        }.value
        _ = await saved

        if let thumbnail = outputs.thumbnail {
            lastThumbnail = thumbnail
        }
        if let jpeg = outputs.coachJPEG {
            onPhotoCaptured?(jpeg)
        }
    }

    // MARK: - 教練分析 tap（A5：CoachSession 掛載一次）

    /// 把教練層的 AVCaptureVideoDataOutput 接進 session（sessionQueue 上執行）；
    /// 之後前後鏡重配時會自動對新 connection 重設 rotation / mirroring。
    func attachVideoTap(_ tap: VideoFrameTap) {
        service.attachVideoTap(tap)
    }

    /// 開/關教練 tap connection 的出帧（sessionQueue 上執行）。
    /// 離開教練模式停帧（不拆 output）：拍照/專業模式不付 30fps 資料流與功耗成本；
    /// 前後鏡重配後的新 connection 也會沿用此狀態。
    func setVideoTapEnabled(_ enabled: Bool) {
        service.setVideoTapEnabled(enabled)
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
            } catch {
                // lock 失敗：放棄本次 zoom，不影響 session
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
            guard self.videoTap !== tap else { return }
            self.videoTap = tap
            self.session.beginConfiguration()
            if !self.session.outputs.contains(tap.output), self.session.canAddOutput(tap.output) {
                self.session.addOutput(tap.output)
            }
            self.configureVideoTapConnectionLocked(
                front: self.videoInput?.device.position == .front
            )
            self.session.commitConfiguration()
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
        if let defaultLens = DeviceMatrix.defaultLens(in: options),
           defaultLens.zoomFactor != 1.0 {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(
                    max(defaultLens.zoomFactor, device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor
                )
                device.unlockForConfiguration()
            } catch {
                // 失敗就維持 1.0，UI 仍可手動選鏡
            }
        }

        // 直向固定：session 內所有支援的 connection（含已附掛的 preview layer）都轉 90°
        for connection in session.connections where connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        // 教練 video tap 的 connection 在 input 重配後是新物件：
        // 重設 rotation / 前鏡 mirroring（A5；flipCamera 走這條路徑）
        configureVideoTapConnectionLocked(front: front)

        session.commitConfiguration()
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
