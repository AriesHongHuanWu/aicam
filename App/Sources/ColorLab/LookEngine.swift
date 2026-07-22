//  LookEngine.swift
//  AICam — LookRecipe → Core Image filter 鏈（A3；v0.3.0 契約）。
//
//  Filter 鏈順序（固定）：
//  1. CIToneCurve（5 點曲線）
//  2. CIColorControls（只動 saturation；isMono 一律 0）
//  3. CITemperatureAndTint（6500 基準 ± shift；isMono 跳過 — 去飽和後再套會重新染色）
//  4. CIVignette（vignette > 0 才套）
//
//  ⚠️ 幻覺高風險區：所有 CIFilter 一律用 KVC 字串 key。本檔用到的 filter 與 key
//  （逐字，供 reviewer 對照 Core Image Filter Reference）：
//  - "CIToneCurve"：inputImage、inputPoint0、inputPoint1、inputPoint2、
//    inputPoint3、inputPoint4（各 CIVector 2 維 (x, y)）
//  - "CIColorControls"：inputImage、inputSaturation
//  - "CITemperatureAndTint"：inputImage、inputNeutral、inputTargetNeutral
//    （各 CIVector 2 維 (色溫 K, tint)）
//  - "CIVignette"：inputImage、inputIntensity、inputRadius
//
//  色溫方向約定（無法本機驗證，待真機確認）：
//  inputNeutral = (6500 + temperatureShift, tintShift)、inputTargetNeutral = (6500, 0)
//  → 告訴 filter「畫面裡應為中性的顏色目前偏到 (6500+shift)」，filter 反向補償。
//  正 shift 預期結果 = 畫面變暖。若真機驗出方向相反，只需把 shift 移到
//  inputTargetNeutral 一側（單點修改，見 temperatureFilter 注釋）。
//
//  執行緒：apply / renderJPEG 皆無共享可變狀態（CIFilter 每次新建；CIContext
//  執行緒安全且為共享單例）→ 任意執行緒可呼叫（拍照處理在背景 queue）。

import AICamCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum LookEngine {

    /// 共享 CIContext（執行緒安全；renderJPEG 專用 — MetalPreviewView 另持
    /// 自己的 CIContext(mtlDevice:)，兩者互不干擾）。
    private static let ciContext = CIContext()

    // MARK: - 套用配方（CIImage → CIImage）

    /// 把配方套到影像上。id == "none"（原色）原樣返回 — 不建任何 filter，
    /// 即時預覽的 passthrough 路徑零濾鏡成本。
    /// 任一 filter 建立失敗（理論上不會；防禦）→ 跳過該級、繼續下一級。
    static func apply(_ recipe: LookRecipe, to image: CIImage) -> CIImage {
        guard recipe.id != LookRecipe.passthrough.id else { return image }
        var result = image

        // 1. Tone curve（Looks.swift 已保證 5 點、x 嚴格遞增 — LooksTests 強制）
        if recipe.toneCurve.count == 5, let filter = CIFilter(name: "CIToneCurve") {
            filter.setValue(result, forKey: "inputImage")
            for (index, point) in recipe.toneCurve.enumerated() {
                filter.setValue(
                    CIVector(x: CGFloat(point.x), y: CGFloat(point.y)),
                    forKey: "inputPoint\(index)"
                )
            }
            if let output = filter.outputImage {
                result = output
            }
        }

        // 2. Saturation（isMono 一律 0；等於 1 時跳過 — 不建無效 filter）
        let saturation = recipe.isMono ? 0 : recipe.saturation
        if saturation != 1, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: "inputImage")
            filter.setValue(saturation, forKey: "inputSaturation")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 3. 色溫/色調（isMono 跳過：黑白不得被重新染色；無偏移也跳過）
        if !recipe.isMono, recipe.temperatureShift != 0 || recipe.tintShift != 0,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setValue(result, forKey: "inputImage")
            // 方向約定見檔頭注釋；真機驗出相反時把 shift 換到 target 一側即可。
            filter.setValue(
                CIVector(x: CGFloat(6500 + recipe.temperatureShift), y: CGFloat(recipe.tintShift)),
                forKey: "inputNeutral"
            )
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            if let output = filter.outputImage {
                result = output
            }
        }

        // 4. 暗角（vignette 0…1 → CIVignette intensity 同值；radius 固定 1.5
        //    給較寬的柔和衰減。強度上限 1 已足夠重 — noir 0.5 是全表最重）
        if recipe.vignette > 0, let filter = CIFilter(name: "CIVignette") {
            filter.setValue(result, forKey: "inputImage")
            filter.setValue(recipe.vignette, forKey: "inputIntensity")
            filter.setValue(1.5, forKey: "inputRadius")
            if let output = filter.outputImage {
                result = output
            }
        }

        return result
    }

    // MARK: - 拍照落地（JPEG → 套 Look → JPEG）

    /// 拍照後處理：把 Look 烘進 JPEG。
    /// - 原色配方直接回傳原 data（不重壓縮 = 零世代損失）。
    /// - EXIF orientation 先烘平成直立像素再進 filter chain — filter 輸出的
    ///   CIImage 不保證保留 properties，靠 metadata 轉向不可靠。
    /// - 解不開 / 輸出失敗回 nil（呼叫端契約：nil = 存原始檔，絕不丟照片）。
    static func renderJPEG(from jpegData: Data, recipe: LookRecipe, quality: CGFloat) -> Data? {
        guard recipe.id != LookRecipe.passthrough.id else { return jpegData }
        guard var image = CIImage(data: jpegData) else { return nil }

        if let raw = image.properties[kCGImagePropertyOrientation as String] as? Int32, raw != 1 {
            image = image.oriented(forExifOrientation: raw)
        }

        let output = apply(recipe, to: image)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        return ciContext.jpegRepresentation(
            of: output,
            colorSpace: colorSpace,
            options: [qualityKey: quality]
        )
    }
}

// MARK: - CachedLookChain（v0.3.0 修正輪；MetalPreviewView.draw 每帧路徑專用）

/// LookEngine.apply 的「filter 重用」版：以 recipe.id 快取已建好的 CIFilter 陣列，
/// 每帧只 setValue(inputImage) — 30fps 預覽下不再每帧新建最多 4 顆 filter
/// （CIFilter(name:) 查表 + KVC 靜態參數設值 ≈ 每秒 ~120 次可避免配置）。
/// 語意與 LookEngine.apply 逐級一致（同 filter、同 key、同跳級條件）；
/// 靜態參數在建鏈時設定一次，recipe 變更（id 不同）時整鏈重建。
/// ⚠️ 非執行緒安全：僅限單一執行緒序列使用（draw 恆在主執行緒）。
/// 拍照烘焙（renderJPEG，背景 queue）仍走無狀態的 LookEngine.apply。
final class CachedLookChain {

    private var cachedRecipeID: String?
    private var filters: [CIFilter] = []

    /// 把配方套到影像上（passthrough 原樣返回，與 LookEngine.apply 同契約）。
    func apply(_ recipe: LookRecipe, to image: CIImage) -> CIImage {
        guard recipe.id != LookRecipe.passthrough.id else { return image }
        if recipe.id != cachedRecipeID {
            filters = Self.buildFilters(recipe)
            cachedRecipeID = recipe.id
        }
        var result = image
        for filter in filters {
            filter.setValue(result, forKey: "inputImage")
            if let output = filter.outputImage {
                result = output
            }
        }
        return result
    }

    /// 建鏈（靜態參數設定一次；與 LookEngine.apply 的四級順序/條件逐一對齊）。
    private static func buildFilters(_ recipe: LookRecipe) -> [CIFilter] {
        var chain: [CIFilter] = []

        // 1. Tone curve
        if recipe.toneCurve.count == 5, let filter = CIFilter(name: "CIToneCurve") {
            for (index, point) in recipe.toneCurve.enumerated() {
                filter.setValue(
                    CIVector(x: CGFloat(point.x), y: CGFloat(point.y)),
                    forKey: "inputPoint\(index)"
                )
            }
            chain.append(filter)
        }

        // 2. Saturation（isMono 一律 0；等於 1 時跳過）
        let saturation = recipe.isMono ? 0 : recipe.saturation
        if saturation != 1, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(saturation, forKey: "inputSaturation")
            chain.append(filter)
        }

        // 3. 色溫/色調（isMono 跳過；方向約定見檔頭注釋）
        if !recipe.isMono, recipe.temperatureShift != 0 || recipe.tintShift != 0,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setValue(
                CIVector(x: CGFloat(6500 + recipe.temperatureShift), y: CGFloat(recipe.tintShift)),
                forKey: "inputNeutral"
            )
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            chain.append(filter)
        }

        // 4. 暗角
        if recipe.vignette > 0, let filter = CIFilter(name: "CIVignette") {
            filter.setValue(recipe.vignette, forKey: "inputIntensity")
            filter.setValue(1.5, forKey: "inputRadius")
            chain.append(filter)
        }

        return chain
    }
}
