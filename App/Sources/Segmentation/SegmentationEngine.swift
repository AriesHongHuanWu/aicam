//  SegmentationEngine.swift
//  AICam — v0.5.0 分割特效引擎（A1）：即時人像 mask + 拍照精細 mask + MaskStore。
//
//  兩條路徑（跨模組契約）：
//  - liveMask(for:)：VNGeneratePersonSegmentationRequest .balanced、
//    kCVPixelFormatType_OneComponent8、request 重用。呼叫端 = FrameAnalyzer
//    （analysisQueue、每 2 次分析 tick 一次 ≈ 7fps）。同步執行、回 mask buffer。
//  - accurateMask(forJPEG:)：拍照烘焙用 .accurate 等級對 JPEG data；
//    「無人」時 fallback iOS 17 VNGenerateForegroundInstanceMaskRequest
//    （任意主體，instances 全選 generateScaledMaskForImage），再無 → nil。
//    輸出 CGImage（灰階；A2 EffectCompositor 轉 CIImage 後縮放對齊主影像）。
//
//  mask 語意（跨模組契約，A2 合成端依此寫 blend）：
//  - 人／主體 = 白（255 / 1.0）、背景 = 黑（0）；邊緣有羽化中間值。
//  - liveMask 輸出解析度「低於」輸入帧（.balanced 為速度優先的縮小 mask；
//    Apple 未文件化確切尺寸，實測常為輸入的 1/2～1/4 級距）→ 合成端必須把
//    mask CIImage 縮放到主影像 extent（EffectCompositor 契約已寫明）。
//  - accurateMask 同樣可能低於照片解析度（person 路徑）；foreground instance
//    fallback 的 generateScaledMaskForImage 則已放大到與輸入影像同尺寸。
//    無論哪條路徑，A2 一律按 extent 對齊縮放，解析度差異不外漏。
//
//  方向鐵律（與 LookEngine.renderJPEG 的烘焙慣例對齊 — 錯這裡 mask 整張轉 90°）：
//  - liveMask：分析 buffer 已由 connection 轉直立 portrait + 前鏡已鏡像
//    （VideoFrameTap 檔頭鐵律）→ orientation 一律 .up，mask 與取景畫面同向。
//  - accurateMask：LookEngine.renderJPEG 會先把 EXIF orientation 烘平成直立
//    像素再進 filter 鏈（A2 的 bake 沿用同慣例：Look 先全域套用）→ mask 必須
//    產在「轉正後」的空間：本檔自 JPEG 讀出 EXIF orientation 傳給 Vision，
//    Vision 內部轉正後輸出的 mask 即與烘平後的主影像同向。
//    （假設「傳 orientation 後 mask 空間 = 轉正空間」— Vision 文件語焉不詳，
//    待真機驗證；若驗出 mask 轉了 90°，改為不傳 orientation + 由 A2 對 mask
//    套同一 oriented(forExifOrientation:) 即修。）
//
//  執行緒模型：
//  - liveMask：重用的 liveRequest 為單一呼叫 queue 專屬（FrameAnalyzer 的
//    analysisQueue），不得多 queue 並發呼叫 — 與 FrameAnalyzer 其他 Vision
//    request 同紀律。
//  - accurateMask：無共享可變狀態（request 每次新建；.accurate 單次推論成本
//    遠大於 request 配置，重用不值得引入跨 queue 風險）→ 任意背景執行緒可呼叫
//    （拍照烘焙 queue），與 liveMask 併發亦安全。
//  - MaskStore：@MainActor 單例；FrameAnalyzer 以 Task { @MainActor } 發布，
//    帶單調序號防亂序（unstructured Task 抵達順序無保證 — 不設防的話
//    「清空」可能被稍早排入的舊 mask 蓋回）。
//
//  ⚠️ 幻覺高風險區（本檔 Vision API，逐一列出供 reviewer 對照 SDK）：
//  - VNGeneratePersonSegmentationRequest：qualityLevel（.balanced／.accurate）、
//    outputPixelFormat（OSType；OneComponent8）、results: [VNPixelBufferObservation]
//    （iOS 15+）。
//  - VNGenerateForegroundInstanceMaskRequest（iOS 17+）：results:
//    [VNInstanceMaskObservation]；observation.allInstances: IndexSet；
//    observation.generateScaledMaskForImage(forInstances:from:) throws
//    → CVPixelBuffer（kCVPixelFormatType_OneComponent32Float、已縮放到輸入
//    影像尺寸）。簽名若與 SDK 不符，優先核對此三處。
//  - VNImageRequestHandler(data:orientation:options:)：不傳 orientation 時
//    Vision「不會」自行解析 EXIF（假定 .up）→ 本檔明確傳入。
//
//  無本機編譯，全檔待 CI／真機驗證。

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Observation
import Vision

// MARK: - SegmentationEngine

final class SegmentationEngine {

    /// 即時路徑重用 request（呼叫 queue 專屬；見檔頭執行緒模型）。
    private let liveRequest: VNGeneratePersonSegmentationRequest

    init() {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        liveRequest = request
    }

    // MARK: 即時 mask（analysisQueue）

    /// 即時人像 mask（.balanced；同步）。buffer 已直立、前鏡已鏡像 → .up。
    /// 無人時 Vision 慣常回「全黑 mask」而非空 results — 即時路徑不做有無人
    /// 判定（全黑 mask 餵給合成端 = 特效自然呈現「無主體」，語意正確且零額外成本）。
    /// perform 失敗回 nil（呼叫端沿用上一張已發布 mask，短暫失敗不閃爍）。
    func liveMask(for buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([liveRequest])
        } catch {
            return nil
        }
        // compactMap-cast 同 FrameAnalyzer 慣例：相容 typed results 與 [VNObservation]
        return (liveRequest.results ?? [])
            .compactMap { $0 as? VNPixelBufferObservation }
            .first?
            .pixelBuffer
    }

    // MARK: 拍照精細 mask（背景 queue；無共享狀態）

    /// 拍照烘焙 mask（.accurate）。流程：
    /// 1. person segmentation .accurate — 有「實質」人像覆蓋才採用
    ///    （全黑 mask = 無人，不能光看 results 非空，否則永遠擋掉 fallback）。
    /// 2. 無人 → iOS 17 VNGenerateForegroundInstanceMaskRequest 任意主體
    ///    （instances 全選、generateScaledMaskForImage 放大到影像尺寸）。
    /// 3. 再無 → nil（呼叫端契約：nil = 不套 mask 特效，照片照樣保存）。
    func accurateMask(forJPEG data: Data) -> CGImage? {
        // EXIF orientation 明確傳入：mask 產在「轉正後」空間，
        // 與 LookEngine.renderJPEG 烘平慣例對齊（見檔頭方向鐵律）。
        let orientation = Self.exifOrientation(of: data)
        let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])

        // 1. 人像 .accurate
        let personRequest = VNGeneratePersonSegmentationRequest()
        personRequest.qualityLevel = .accurate
        personRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if (try? handler.perform([personRequest])) != nil,
           let maskBuffer = (personRequest.results ?? [])
               .compactMap({ $0 as? VNPixelBufferObservation })
               .first?
               .pixelBuffer,
           Self.hasMeaningfulCoverage(maskBuffer) {
            return Self.makeCGImage(from: maskBuffer)
        }

        // 2. 任意主體 fallback（min target 已是 iOS 17，#available 依契約明寫）
        if #available(iOS 17.0, *) {
            let foregroundRequest = VNGenerateForegroundInstanceMaskRequest()
            guard (try? handler.perform([foregroundRequest])) != nil,
                  let observation = (foregroundRequest.results ?? [])
                      .compactMap({ $0 as? VNInstanceMaskObservation })
                      .first
            else { return nil }
            let instances = observation.allInstances
            guard !instances.isEmpty,
                  let maskBuffer = try? observation.generateScaledMaskForImage(
                      forInstances: instances,
                      from: handler
                  )
            else { return nil }
            return Self.makeCGImage(from: maskBuffer)
        }
        return nil
    }

    // MARK: - EXIF orientation

    /// JPEG data 的 EXIF orientation（讀不到 = .up）。
    /// 值域 1…8 與 CGImagePropertyOrientation rawValue 同編碼（TIFF/EXIF 標準）。
    private static func exifOrientation(of data: Data) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else { return .up }
        return orientation
    }

    // MARK: - 有無人判定（accurate 路徑的 fallback 門檻）

    /// 人像 mask 是否「實質有人」：格點取樣 ~1024 點，亮度 ≥ 32/255 的點佔比
    /// ≥ 0.5% 判有人。門檻刻意極低 — 只為分辨「全黑（無人）」與「有人」，
    /// 不是品質判定；誤把小人像當無人會走 fallback（任意主體多半也會抓到人，
    /// 結果仍合理）。非預期格式不判定（保守回 true，不誤觸 fallback）。
    private static func hasMeaningfulCoverage(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
            return true
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return false }

        let step = max(1, Int((Double(width * height) / 1024.0).squareRoot()))
        var hit = 0
        var total = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let value = base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)
                if value >= 32 { hit += 1 }
                total += 1
                x += step
            }
            y += step
        }
        guard total > 0 else { return false }
        return Double(hit) / Double(total) >= 0.005
    }

    // MARK: - CVPixelBuffer → CGImage（灰階）

    /// 防禦 fallback 專用（未知格式才建；static let 語意 = 首次用到才配置）。
    private static let ciContext = CIContext()

    /// mask buffer → 8-bit 灰階 CGImage（deviceGray、無 alpha）。
    /// 兩種已知格式手動轉（位元組確定性，不吃 Core Image 對單通道格式的
    /// 色彩空間詮釋風險）；其他格式走 CIContext 防禦 fallback。
    private static func makeCGImage(from buffer: CVPixelBuffer) -> CGImage? {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            return grayImageFromOneComponent8(buffer)
        case kCVPixelFormatType_OneComponent32Float:
            return grayImageFromOneComponent32Float(buffer)
        default:
            let image = CIImage(cvPixelBuffer: buffer)
            guard image.extent.width > 0, image.extent.height > 0 else { return nil }
            return ciContext.createCGImage(image, from: image.extent)
        }
    }

    /// OneComponent8（person 路徑）：逐列 memcpy 去掉 row padding。
    private static func grayImageFromOneComponent8(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, bytesPerRow >= width else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let destBase = destination.baseAddress else { return }
            for y in 0..<height {
                memcpy(destBase + y * width, base + y * bytesPerRow, width)
            }
        }
        return grayImage(pixels: pixels, width: width, height: height)
    }

    /// OneComponent32Float（foreground instance 路徑）：0…1 float → 0…255。
    /// 照片尺寸單次迴圈（~12MP 數十 ms），拍照烘焙背景 queue 可接受。
    /// loadUnaligned：不賭 bytesPerRow 對齊（stdlib inline，無 OS 版本依賴）。
    private static func grayImageFromOneComponent32Float(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { destination in
            for y in 0..<height {
                let rowOffset = y * bytesPerRow
                for x in 0..<width {
                    let value = base.loadUnaligned(
                        fromByteOffset: rowOffset + x * 4, as: Float.self
                    )
                    let clamped = min(1, max(0, value))
                    destination[y * width + x] = UInt8(clamped * 255)
                }
            }
        }
        return grayImage(pixels: pixels, width: width, height: height)
    }

    /// 8-bit 灰階像素陣列 → CGImage（deviceGray、bytesPerRow = width、無 padding）。
    private static func grayImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - MaskStore（@MainActor 單例；跨模組契約 surface）

/// 即時 mask 的發布點：FrameAnalyzer（analysisQueue）產出 → MainActor 發布，
/// MetalPreviewView 的 render chain（A4 契約：Look → Effect(mask:)）讀取。
/// 「僅特效啟用時更新」— 特效關閉／熱降級／切鏡時由 FrameAnalyzer 發 nil 清空。
///
/// mask buffer 跨執行緒傳遞：CVPixelBuffer 本身非 Sendable（Swift 5 模式僅警告），
/// 但 Vision 輸出的 mask buffer 在回傳後無人再寫入（Vision 每次 perform 產新
/// buffer；分析端只轉手引用不觸碰內容）→ 實質唯讀轉移，安全。
@MainActor
@Observable
final class MaskStore {

    static let shared = MaskStore()

    /// 最新即時 mask（人=白 255／背景=黑 0；解析度低於取景帧，合成端縮放對齊）。
    /// nil = 特效未啟用／已清空 → 合成端 needsMask 特效回原圖（A2 契約）。
    var latestMask: CVPixelBuffer?
    /// latestMask 的來源帧 media timestamp（無 mask 時 0）。
    var maskTimestamp: Double = 0
    /// 最近一次 mask 發布時的偵測人數（FrameAnalyzer faces 數帶入；上限 3 —
    /// 分析層只取最大 3 張臉。A3 群組構圖的 ≥2 判定不受上限影響；
    /// 獨立分割路徑（教練未啟用）無臉部觀測 → 0）。
    var personCount: Int = 0
    /// 發布時的 systemUptime（v0.5.0 修正輪；渲染端時效判定用）：
    /// MetalPreviewView.draw 以「uptime − publishedAt > 0.5s」視為無 mask —
    /// 分割一停（模式／開關切換、分析中斷）凍結的舊 mask 不得永久錯位合成。
    /// 用 systemUptime 而非 media timestamp：與渲染端同一時基可直接相減，
    /// 不賭 CMSampleBuffer 時基與主執行緒時鐘的對映。非契約 surface、
    /// 只被 draw 命令式讀取 → @ObservationIgnored（不觸發 SwiftUI diff）。
    @ObservationIgnored private(set) var publishedAt: TimeInterval = 0

    /// 已套用的發布序號（亂序防護；見 apply）。
    @ObservationIgnored private var lastAppliedSequence = 0

    /// 唯一寫入口（FrameAnalyzer 專用）：sequence 必須嚴格遞增才套用 —
    /// unstructured Task 抵達 MainActor 的順序無保證，沒有這道防護，
    /// 「清空」發布可能被稍早排入、較晚執行的舊 mask 蓋回（stale 復活）。
    func apply(mask: CVPixelBuffer?, timestamp: Double, personCount: Int, sequence: Int) {
        guard sequence > lastAppliedSequence else { return }
        lastAppliedSequence = sequence
        latestMask = mask
        maskTimestamp = timestamp
        publishedAt = ProcessInfo.processInfo.systemUptime
        // 少變屬性只在值變化時寫入（@Observable 逐屬性追蹤，同 CoachSession 慣例）
        if self.personCount != personCount {
            self.personCount = personCount
        }
    }
}
