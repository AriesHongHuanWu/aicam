//  Effects.swift
//  AICamCore — 分割特效配方（A2；v0.5.0 分割特效引擎契約）。
//
//  純資料 + 驗證，Linux CI 可編譯可測：只 import Foundation。
//  CIFilter 落地（mask 分域合成）在 App 層 EffectCompositor
//  （App/Sources/ColorLab/EffectCompositor.swift）；本檔只定義配方。
//
//  契約（v0.5.0，精確照抄）：
//  - needsMask：此特效是否需要人像/主體分割 mask 才能生效。App 層在 mask
//    不可得（無人、分割失敗）時對 needsMask 特效回原圖 — 不做半套特效。
//  - bgSaturation ∈ [0, 2]（1 = 不動；背景層飽和度）。
//  - bgBlurRadius ≥ 0（px；定義於 1440px 寬基準影像 — App 層以實際影像寬
//    線性縮放，全尺寸照片半徑按比例放大，見 EffectCompositor 注釋）。
//  - bgExposure（EV；負 = 壓暗背景；App 層 CIExposureAdjust 落地）。
//  - subjectWarmth（K，6500 基準偏移；正 = 主體變暖；App 層 CITemperatureAndTint，
//    方向約定與 LookRecipe.temperatureShift 相同，待真機驗證）。
//  - bgTemperatureShift（K，6500 基準偏移；負 = 背景變冷/偏青；同上落地）。
//  - id 為持久化字串（AppStorage "effect.selected" 直接存 id）→ 一經釋出
//    不可改名，EffectsTests 鎖定完整 id 清單。
//  - none：id "none"、名「無」、needsMask false、全參數中性 — App 層對
//    id == "none" 完整跳過合成（特效未啟用零成本鐵律）。

import Foundation

/// 一款分割特效配方。純值型別，App 層 EffectCompositor 負責把它變成
/// 「背景層加工 + 主體層加工 + CIBlendWithMask 合成」。
public struct EffectRecipe: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    /// 繁體中文顯示名。
    public let name: String
    /// 需要分割 mask 才能生效（App 層 mask 不可得時回原圖）。
    public let needsMask: Bool
    /// 背景層飽和度 0…2；1 = 不動（0 = 背景全黑白）。
    public let bgSaturation: Double
    /// 背景層高斯模糊半徑（px，1440px 寬基準；0 = 不模糊）。
    public let bgBlurRadius: Double
    /// 背景層曝光偏移（EV；負 = 壓暗；0 = 不動）。
    public let bgExposure: Double
    /// 主體層色溫偏移（K，6500 基準；正 = 暖；0 = 不動）。
    public let subjectWarmth: Double
    /// 背景層色溫偏移（K，6500 基準；負 = 冷/偏青；0 = 不動）。
    public let bgTemperatureShift: Double

    public init(
        id: String,
        name: String,
        needsMask: Bool,
        bgSaturation: Double,
        bgBlurRadius: Double,
        bgExposure: Double,
        subjectWarmth: Double,
        bgTemperatureShift: Double
    ) {
        self.id = id
        self.name = name
        self.needsMask = needsMask
        self.bgSaturation = bgSaturation
        self.bgBlurRadius = bgBlurRadius
        self.bgExposure = bgExposure
        self.subjectWarmth = subjectWarmth
        self.bgTemperatureShift = bgTemperatureShift
    }

    // MARK: - 無（恆等配方）

    /// 恆等：needsMask false、全參數中性。EffectCompositor 對 id == "none"
    /// 完整跳過（不建 filter、不取 mask — 特效未啟用零成本鐵律）。
    /// ⚠️ 命名注意：在 Optional 語境寫 `.none` 會解析成 Optional.none —
    /// 呼叫端一律寫全名 `EffectRecipe.none`。
    public static let none = EffectRecipe(
        id: "none",
        name: "無",
        needsMask: false,
        bgSaturation: 1,
        bgBlurRadius: 0,
        bgExposure: 0,
        subjectWarmth: 0,
        bgTemperatureShift: 0
    )

    // MARK: - 特效四款（v0.5.0）

    /// 跳色：主體彩色、背景黑白。設計意圖 — 只動 bgSaturation 0（背景完全
    /// 去飽和），其餘全中性：經典 color-pop，主體顏色靠對比自己跳出來，
    /// 不額外壓暗或模糊（保留環境敘事，只抽掉顏色）。
    public static let colorPop = EffectRecipe(
        id: "pop",
        name: "跳色",
        needsMask: true,
        bgSaturation: 0,
        bgBlurRadius: 0,
        bgExposure: 0,
        subjectWarmth: 0,
        bgTemperatureShift: 0
    )

    /// 背景虛化：模擬大光圈淺景深。設計意圖 — bgBlurRadius 14（1440px 寬
    /// 基準；全尺寸照片由 App 層按影像寬線性放大），顏色曝光全不動：
    /// 只做「光學感」的分離，虛化本身就是全部語言。
    public static let backgroundBlur = EffectRecipe(
        id: "blur",
        name: "背景虛化",
        needsMask: true,
        bgSaturation: 1,
        bgBlurRadius: 14,
        bgExposure: 0,
        subjectWarmth: 0,
        bgTemperatureShift: 0
    )

    /// 聚光：舞台追光感。設計意圖 — 背景壓暗 −1.6 EV（暗但不死黑，保留
    /// 環境輪廓）＋ 降飽和 0.6（暗部顏色收斂才像光衰減，不像調色失誤），
    /// 主體維持原樣 = 唯一被「光」打到的存在。
    public static let spotlight = EffectRecipe(
        id: "spotlight",
        name: "聚光",
        needsMask: true,
        bgSaturation: 0.6,
        bgBlurRadius: 0,
        bgExposure: -1.6,
        subjectWarmth: 0,
        bgTemperatureShift: 0
    )

    /// 雙色調：主體暖/背景青的 teal-orange 分域版。設計意圖 — 主體 +300K
    /// 推向橙、背景 −500K 推向青（兩層方向相反、總分離 800K），背景飽和
    /// 降到 0.75 讓青色退成底色不搶戲；不模糊不壓暗 — 分離全靠色彩對比。
    public static let duotone = EffectRecipe(
        id: "duotone",
        name: "雙色調",
        needsMask: true,
        bgSaturation: 0.75,
        bgBlurRadius: 0,
        bgExposure: 0,
        subjectWarmth: 300,
        bgTemperatureShift: -500
    )

    // MARK: - 全表

    /// 順序即 UI 顯示順序：無 → 跳色 → 背景虛化 → 聚光 → 雙色調（共 5）。
    public static let all: [EffectRecipe] = [
        .none, .colorPop, .backgroundBlur, .spotlight, .duotone
    ]

    /// 以 id 查配方（AppStorage "effect.selected" → 配方；未知 id 回 nil，
    /// 呼叫端自行決定 fallback 到 none）。
    public static func byID(_ id: String) -> EffectRecipe? {
        all.first { $0.id == id }
    }
}
