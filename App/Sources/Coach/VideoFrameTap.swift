//  VideoFrameTap.swift
//  AICam — 教練即時分析管線（A5）：AVCaptureVideoDataOutput → FrameAnalyzer → FrameFacts。
//
//  執行緒模型：
//  - captureOutput 在專用 serial analysisQueue 上被呼叫；分析「同步」在同一 queue 執行，
//    分析期間 alwaysDiscardsLateVideoFrames=true 會自動丟遲到帧（isBusy 只是防禦保險）。
//  - latestPixelBuffer / isActive / isFrontCamera / minAnalysisInterval 由 NSLock 保護：
//    MainActor（snapshot、開關、熱降級）與 sessionQueue（前後鏡標記）都會跨執行緒存取。
//  - onFacts 於 analysisQueue 上呼叫；由 CoachSession 在啟用前設定一次、之後不再改。
//  - onPreviewFrame（v0.3.0 A3 契約）於 analysisQueue 上「每帧」呼叫（~30fps，
//    不受分析節流、也不受 setActive 限制 — 非教練模式掛 tap 純做即時濾鏡預覽
//    也要出帧）；MetalPreviewView 動態設定/清除 → 同一把鎖保護。nil 時零成本。
//
//  座標鐵律（MASTER-PLAN §3 + 本輪契約）：
//  - connection 已設 videoRotationAngle=90（CameraController.attachVideoTap / configureLocked）
//    → buffer 為直立 portrait，Vision 一律用 orientation .up。
//  - 前鏡 connection isVideoMirrored=true → buffer 已鏡像、與 preview 視覺一致，
//    Vision 結果「不需」再翻 x。
//
//  快照：不長持有 CMSampleBuffer；只保留最新 CVPixelBuffer（鎖保護、「僅啟用時」每帧替換
//  = 教練模式中恆持有 1 顆 pool buffer，停用即釋放），需要時用 CIContext 轉 JPEG
//  （Gemini 導演即時模式用；同步版之外另有背景編碼的 async 版）。
//
//  待真機驗證。

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import AICamCore

final class VideoFrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// 由 CameraController.attachVideoTap 加進 session（32BGRA、丟遲到帧）。
    let output = AVCaptureVideoDataOutput()

    /// 每次分析完成的回呼（在 analysisQueue 上呼叫）。啟用前設定一次。
    /// 附帶該帧 buffer 像素尺寸（寬、高）：CoachSession 據此發布實際 content 比例，
    /// CoachOverlayView 的 AspectFillMapper 不再寫死 3:4。
    var onFacts: ((FrameFacts, _ bufferWidth: Int, _ bufferHeight: Int) -> Void)?

    /// 即時濾鏡預覽回呼（v0.3.0 A3 契約）：設定後「每帧」在 delegate queue
    /// （analysisQueue）上回呼，帶原始 CVPixelBuffer（已直立、前鏡已鏡像）；
    /// 不經分析節流（濾鏡預覽要滿帧率 ~30fps，分析只要 15fps）、不受 setActive
    /// 影響（教練關閉時 Metal 取景器照樣要畫）。nil 時零成本（captureOutput
    /// 只多一次鎖內指標讀取）。MetalPreviewView 擁有設定與清除。
    var onPreviewFrame: ((CVPixelBuffer) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onPreviewFrame
        }
        set {
            lock.lock()
            _onPreviewFrame = newValue
            _previewFrameOwner = nil
            lock.unlock()
        }
    }

    /// onPreviewFrame 的「帶擁有者」設定版（v0.3.0 修正輪）：搭配
    /// clearPreviewFrameHandler(owner:) 使用。SwiftUI 重建 MetalPreviewView 時
    /// 舊 Coordinator 的 detach/deinit 可能晚於新 Coordinator 的 attach 執行 —
    /// 無條件清空會把新回呼一併抹掉（預覽靜默凍結）。擁有者比對根治此時序。
    func setPreviewFrameHandler(_ handler: @escaping (CVPixelBuffer) -> Void, owner: AnyObject) {
        lock.lock()
        _onPreviewFrame = handler
        _previewFrameOwner = ObjectIdentifier(owner)
        lock.unlock()
    }

    /// 只在回呼仍屬於 owner 時清除（不屬於 = 已被新擁有者接手 → 不動）。
    func clearPreviewFrameHandler(owner: AnyObject) {
        lock.lock()
        if _previewFrameOwner == ObjectIdentifier(owner) {
            _onPreviewFrame = nil
            _previewFrameOwner = nil
        }
        lock.unlock()
    }

    /// Vision + 像素統計 + CoreMotion（analyze 只在 analysisQueue 上跑）。
    let analyzer = FrameAnalyzer()

    private let analysisQueue = DispatchQueue(label: "com.arieswu.aicam.coach.analysis")
    /// CIContext 執行緒安全；只用於 snapshot 轉 JPEG。
    private let ciContext = CIContext()

    // MARK: - 鎖保護狀態（跨執行緒存取）

    private let lock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var _isActive = false
    private var _isFrontCamera = false
    private var _minAnalysisInterval: Double = 0.066
    private var _onPreviewFrame: ((CVPixelBuffer) -> Void)?
    /// 目前 onPreviewFrame 的擁有者（setPreviewFrameHandler 設定；
    /// 經 property setter 設定時為 nil）。時序防護見 setPreviewFrameHandler 注釋。
    private var _previewFrameOwner: ObjectIdentifier?

    // MARK: - analysisQueue 專屬狀態（不需鎖）

    private var isBusy = false
    private var lastAnalysisTime: Double = -.greatestFiniteMagnitude

    override init() {
        super.init()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: analysisQueue)
    }

    // MARK: - 開關（CoachSession / CameraController 呼叫）

    /// 啟用/停用分析（false = 不跑分析、不回呼，並釋放 snapshot buffer —
    /// 停用時 snapshotJPEG 契約本來就回 nil，不需要保留 pool buffer）。
    func setActive(_ active: Bool) {
        lock.lock()
        _isActive = active
        if !active {
            latestPixelBuffer = nil
        }
        lock.unlock()
    }

    /// CameraController 於 attach / 前後鏡重配時呼叫（sessionQueue 上）。
    func setFrontCamera(_ front: Bool) {
        lock.lock()
        _isFrontCamera = front
        lock.unlock()
    }

    /// 分析節流間隔（熱降級時 CoachSession 調成 0.25s，正常 0.066s ≈ 15fps）。
    func setMinAnalysisInterval(_ interval: Double) {
        lock.lock()
        _minAnalysisInterval = interval
        lock.unlock()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate（analysisQueue）

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // timestamp = CMSampleBuffer PTS 秒數（單調 media clock，對齊 FrameFacts.timestamp 契約）
        var timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if !timestamp.isFinite {
            timestamp = ProcessInfo.processInfo.systemUptime
        }

        lock.lock()
        let active = _isActive
        if active {
            latestPixelBuffer = pixelBuffer   // 僅啟用時每帧替換：停用不佔 pool buffer
        }
        let front = _isFrontCamera
        let interval = _minAnalysisInterval
        let previewCallback = _onPreviewFrame
        lock.unlock()

        // 即時濾鏡預覽（A3）：每帧、先於分析節流 — 預覽要滿帧率，分析只要 15fps。
        // 回呼內只存 buffer 引用 + 排主執行緒重繪（見 MetalPreviewView），
        // 不在此 queue 做任何濾鏡運算。
        previewCallback?(pixelBuffer)

        // v0.5.0 修正輪：分割不能只綁教練分析 — 拍照等模式（active=false）選了
        // 特效時，Metal 取景器仍要有 mask 才能畫即時特效。只在「有預覽消費者」
        // （previewCallback 非 nil = Metal 取景器正在收帧）時跑；特效開關／
        // look.livePreview／熱降級／0.15s 節流守門全在 analyzer 內（同
        // analysisQueue，狀態不跨執行緒）。教練啟用時走 analyze 內的既有節奏。
        if !active, previewCallback != nil {
            analyzer.runStandaloneSegmentationIfDue(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }

        // 節流：未啟用／分析中（同 queue 理論上不會發生，防禦用）／距上次分析 < interval → 丟帧
        guard active, !isBusy, timestamp - lastAnalysisTime >= interval else { return }
        isBusy = true
        lastAnalysisTime = timestamp
        let facts = analyzer.analyze(pixelBuffer: pixelBuffer, timestamp: timestamp, isFront: front)
        isBusy = false
        onFacts?(facts, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
    }

    // MARK: - 快照

    /// 最新分析帧的 buffer 引用（鎖內一行讀取；教練停用或尚無帧時 nil）。
    /// Reframe 模型 tick 直餵 scorer 用（v0.3.0 修正輪：取代 snapshotJPEG 繞路，
    /// 免去每 tick 一次 JPEG 編解碼與其壓縮噪聲）。onFacts 於 captureOutput 內
    /// 同 queue 同步呼叫時，回傳值恰為本帧。
    func latestAnalysisBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestPixelBuffer
    }

    /// 最新帧同步轉 JPEG（呼叫端執行緒執行；buffer 已直立且與 preview 同向、前鏡已鏡像）。
    /// maxDimension = 長邊上限（pt 無關，純像素）；無帧時回 nil。
    func snapshotJPEG(maxDimension: CGFloat) -> Data? {
        lock.lock()
        let buffer = latestPixelBuffer
        lock.unlock()
        guard let buffer else { return nil }
        return Self.encodeJPEG(buffer: buffer, maxDimension: maxDimension, context: ciContext)
    }

    /// snapshotJPEG 的非阻塞版：呼叫端（MainActor）只付「取 buffer 引用」的成本，
    /// CIContext 縮放 + JPEG 編碼移到背景 Task 執行（導演即時模式每 10 秒一次，
    /// 同步版在主執行緒會造成可感知微卡帧）。CIContext 執行緒安全（見上方註）。
    func snapshotJPEGAsync(maxDimension: CGFloat) async -> Data? {
        lock.lock()
        let buffer = latestPixelBuffer
        lock.unlock()
        guard let buffer else { return nil }
        let context = ciContext
        return await Task.detached(priority: .userInitiated) {
            Self.encodeJPEG(buffer: buffer, maxDimension: maxDimension, context: context)
        }.value
    }

    /// 縮放 + JPEG 編碼（純函式；任意執行緒可呼叫）。
    private static func encodeJPEG(
        buffer: CVPixelBuffer, maxDimension: CGFloat, context: CIContext
    ) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let maxSide = max(image.extent.width, image.extent.height)
        if maxDimension > 0, maxSide > maxDimension {
            let scale = maxDimension / maxSide
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        return context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [qualityKey: 0.85]
        )
    }
}
