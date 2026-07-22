//  EffectCompositor.swift
//  AICam — EffectRecipe → mask 分域合成（A2；v0.5.0 分割特效引擎契約）。
//
//  合成次序鐵律（跨模組契約）：Look 先「全域」套用 → 特效以 mask「分域」。
//  bake 內部即此順序；即時預覽（MetalPreviewView，A4 接線）在 draw 內先
//  CachedLookChain.apply 再呼叫本檔 apply — 兩條路徑同一鐵律。
//
//  分域模型：
//  背景層 = 輸入影像依 bgSaturation / bgExposure / bgTemperatureShift /
//  bgBlurRadius 加工；主體層 = subjectWarmth ≠ 0 時暖化否則原圖；
//  CIBlendWithMask 以 mask 亮度取層 — mask 白（主體，Vision 人像/主體分割
//  的前景即白）取 inputImage（主體層）、黑取 inputBackgroundImage（背景層）。
//
//  ⚠️ 幻覺高風險區：所有 CIFilter 一律用 KVC 字串 key。本檔用到的 filter 與 key
//  （逐字，供 reviewer 對照 Core Image Filter Reference）：
//  - "CIColorControls"：inputImage、inputSaturation
//  - "CIExposureAdjust"：inputImage、inputEV
//  - "CITemperatureAndTint"：inputImage、inputNeutral、inputTargetNeutral
//    （各 CIVector 2 維 (色溫 K, tint)）
//  - "CIGaussianBlur"：inputImage、inputRadius
//  - "CIBlendWithMask"：inputImage（主體層）、inputBackgroundImage（背景層）、
//    inputMaskImage（mask，白 = 取 inputImage）
//
//  色溫方向約定（與 LookEngine 完全相同、同一真機驗證輪一起定案）：
//  inputNeutral = (6500 + shift, 0)、inputTargetNeutral = (6500, 0) →
//  正 shift 預期畫面變暖。若真機驗出方向相反，LookEngine 與本檔要「一起」
//  把 shift 移到 target 一側（兩檔各一處，注釋互相指路）。
//
//  blur 半徑縮放（v0.5.0 契約 notes 項）：bgBlurRadius 定義於 1440px「寬」
//  基準影像（.photo preset 即時預覽帧直立後寬 ≈ 1440）。套用時以
//  image.extent.width / 1440 線性縮放 — 全尺寸直立照片（寬 3024）×2.1
//  （14 → 29.4）、landscape 4032 寬 ×2.8（14 → 39.2）；預覽與成品的
//  「視覺模糊比例」因此一致（半徑 ∝ 影像寬）。
//
//  mask 對齊（契約明定要寫清楚）：分割 mask 的解析度低於主影像
//  （VNGeneratePersonSegmentationRequest .balanced/.accurate 皆是縮小圖）。
//  apply 內以 CGAffineTransform 把 mask extent 映射到主影像 extent：
//  ① 平移 −mask.origin 把 mask 移回 (0,0)；② 各軸獨立縮放
//  image.width/mask.width、image.height/mask.height（同長寬比時即等比）；
//  ③ 平移 +image.origin 對齊主影像原點。前提：mask 與主影像同方向同視野
//  （A1 的 SegmentationEngine 對「同一張影像」出 mask — live 帧已直立
//  已鏡像；bake 的 accurateMask(forJPEG:) 依 JPEG 內 EXIF 出直立 mask，
//  與 bake 內 oriented(forExifOrientation:) 後的主影像同向）。
//
//  執行緒：apply / bake 皆無共享可變狀態（CIFilter 每次新建；CIContext
//  執行緒安全共享單例）→ 任意執行緒可呼叫。bake 在拍照處理背景 queue
//  （含 .accurate 分割 ~1–2s，契約允許）；apply 另被 draw（主執行緒）呼叫。

import AICamCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum EffectCompositor {

    /// 共享 CIContext（執行緒安全；bake 輸出 JPEG 專用 — 與 LookEngine、
    /// MetalPreviewView 的 context 互不干擾）。
    private static let ciContext = CIContext()

    /// bgBlurRadius 的基準影像寬（px）。配方半徑定義於此寬度；
    /// 套用時按 image.extent.width / blurReferenceWidth 線性縮放（檔頭注釋）。
    private static let blurReferenceWidth: CGFloat = 1440

    // MARK: - 套用特效（CIImage → CIImage；契約簽名）

    /// 把特效以 mask 分域套到影像上。
    /// - id == "none" 原樣返回（不建 filter、不碰 mask — 特效未啟用零成本）。
    /// - mask nil 且 needsMask → 回原圖（契約：不做半套特效）。
    /// - mask 會被縮放對齊 image.extent（詳見檔頭「mask 對齊」注釋）。
    static func apply(_ effect: EffectRecipe, to image: CIImage, mask: CIImage?) -> CIImage {
        guard effect.id != EffectRecipe.none.id, effect.needsMask else { return image }
        guard let mask, let alignedMask = aligned(mask: mask, to: image.extent) else {
            return image
        }

        let background = backgroundLayer(for: effect, from: image)
        let subject = subjectLayer(for: effect, from: image)
        // 兩層皆未動（理論上不會 — 四款配方至少動一參數；防禦）→ 免合成
        if background === image && subject === image { return image }

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(subject, forKey: "inputImage")
        blend.setValue(background, forKey: "inputBackgroundImage")
        blend.setValue(alignedMask, forKey: "inputMaskImage")
        return blend.outputImage ?? image
    }

    // MARK: - 拍照烘焙（JPEG → Look 全域 → 特效分域 → JPEG；契約簽名）

    /// 拍照落地：Look 先全域套用 → accurateMask 分域套特效 → JPEG。
    /// - EXIF orientation 先烘平成直立像素（與 LookEngine.renderJPEG 同法同因：
    ///   filter 輸出不保證保留 properties，靠 metadata 轉向不可靠）——
    ///   maskProvider 出的 mask 也是直立向（檔頭「mask 對齊」前提）。
    /// - maskProvider 只在特效真的需要 mask 時才呼叫（.accurate 分割 ~1–2s，
    ///   不白付）；回 nil（無人且任意主體 fallback 也失敗）→ 特效靜默略過，
    ///   照片仍帶 Look 落地。
    /// - 解不開 / 輸出失敗回 nil（呼叫端契約：nil = fallback，絕不丟照片）。
    static func bake(
        jpeg: Data,
        look: LookRecipe,
        effect: EffectRecipe,
        maskProvider: () -> CGImage?,
        quality: CGFloat
    ) -> Data? {
        guard var image = CIImage(data: jpeg) else { return nil }
        if let raw = image.properties[kCGImagePropertyOrientation as String] as? Int32, raw != 1 {
            image = image.oriented(forExifOrientation: raw)
        }

        // 鐵律第一步：Look 全域（passthrough 在 LookEngine.apply 內原樣返回）
        var result = LookEngine.apply(look, to: image)

        // 鐵律第二步：特效以 mask 分域（套在「已帶 Look」的影像上）
        if effect.id != EffectRecipe.none.id, effect.needsMask {
            if let cgMask = maskProvider() {
                result = apply(effect, to: result, mask: CIImage(cgImage: cgMask))
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        return ciContext.jpegRepresentation(
            of: result,
            colorSpace: colorSpace,
            options: [qualityKey: quality]
        )
    }

    // MARK: - 私有：分層

    /// 背景層：飽和 → 曝光 → 色溫 → 模糊（模糊最後做 — 對「已加工」的背景
    /// 模糊，且 clampedToExtent 先延展邊緣再 crop 回，避免高斯核在影像邊緣
    /// 混入 extent 外的透明像素造成邊緣暈黑/暈開）。
    /// 各級參數為中性值時跳過（不建無效 filter）。
    private static func backgroundLayer(for effect: EffectRecipe, from image: CIImage) -> CIImage {
        var result = image

        // 1. 飽和（跳色 0 / 聚光 0.6 / 雙色調 0.75；1 = 跳過）
        if effect.bgSaturation != 1, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: "inputImage")
            filter.setValue(effect.bgSaturation, forKey: "inputSaturation")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 2. 曝光（聚光 −1.6 EV；0 = 跳過）
        if effect.bgExposure != 0, let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(result, forKey: "inputImage")
            filter.setValue(effect.bgExposure, forKey: "inputEV")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 3. 色溫（雙色調背景 −500K 偏青；方向約定見檔頭注釋）
        if effect.bgTemperatureShift != 0, let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setValue(result, forKey: "inputImage")
            filter.setValue(
                CIVector(x: CGFloat(6500 + effect.bgTemperatureShift), y: 0),
                forKey: "inputNeutral"
            )
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 4. 模糊（半徑按影像寬線性縮放，見檔頭；clamp → blur → crop 回原 extent）
        if effect.bgBlurRadius > 0, let filter = CIFilter(name: "CIGaussianBlur") {
            let radius = scaledBlurRadius(effect.bgBlurRadius, imageWidth: image.extent.width)
            filter.setValue(result.clampedToExtent(), forKey: "inputImage")
            filter.setValue(radius, forKey: "inputRadius")
            if let output = filter.outputImage {
                result = output.cropped(to: image.extent)
            }
        }

        return result
    }

    /// 主體層：subjectWarmth ≠ 0 時暖化（雙色調 +300K），否則原圖。
    private static func subjectLayer(for effect: EffectRecipe, from image: CIImage) -> CIImage {
        guard effect.subjectWarmth != 0,
              let filter = CIFilter(name: "CITemperatureAndTint")
        else { return image }
        filter.setValue(image, forKey: "inputImage")
        filter.setValue(
            CIVector(x: CGFloat(6500 + effect.subjectWarmth), y: 0),
            forKey: "inputNeutral"
        )
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage ?? image
    }

    // MARK: - 私有：mask 對齊與半徑縮放

    /// 把 mask 的 extent 映射到目標 extent（推導見檔頭「mask 對齊」注釋）。
    /// mask extent 退化（零尺寸/無限）→ nil，呼叫端回原圖。
    private static func aligned(mask: CIImage, to extent: CGRect) -> CIImage? {
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0,
              !maskExtent.isInfinite, extent.width > 0, extent.height > 0
        else { return nil }

        // ① 移回原點 → ② 各軸縮放 → ③ 對齊目標原點
        //（concatenating 語意：a.concatenating(b) = 先套 a 再套 b）
        let transform = CGAffineTransform(
            translationX: -maskExtent.origin.x,
            y: -maskExtent.origin.y
        )
        .concatenating(CGAffineTransform(
            scaleX: extent.width / maskExtent.width,
            y: extent.height / maskExtent.height
        ))
        .concatenating(CGAffineTransform(
            translationX: extent.origin.x,
            y: extent.origin.y
        ))
        return mask.transformed(by: transform)
    }

    /// 半徑線性縮放：radius × (影像寬 / 1440)。寬讀不到（退化 extent）時
    /// 用配方原值（防禦；正常路徑不會發生）。
    private static func scaledBlurRadius(_ radius: Double, imageWidth: CGFloat) -> Double {
        guard imageWidth > 0 else { return radius }
        return radius * Double(imageWidth / blurReferenceWidth)
    }
}
