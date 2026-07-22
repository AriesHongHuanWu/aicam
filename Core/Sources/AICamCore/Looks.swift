//  Looks.swift
//  AICamCore — 自動調色 Look 系統（A3；MASTER-PLAN §6 F11 / v0.3.0 契約）。
//
//  純資料 + 驗證，Linux CI 可編譯可測：只 import Foundation。
//  CIFilter 落地（tone curve / saturation / temperature / vignette）在 App 層
//  LookEngine（App/Sources/ColorLab/LookEngine.swift）；本檔只定義配方。
//
//  契約（v0.3.0，精確照抄）：
//  - toneCurve：5 點、x 嚴格遞增、首點 x=0、末點 x=1、y 皆在 0…1（LooksTests 強制）。
//  - saturation ∈ [0, 2]（1 = 不動；isMono 時引擎一律套 0，配方欄位存 0 表誠實）。
//  - temperatureShift：色溫 K 偏移（6500K 基準；正 = 暖、負 = 冷；App 層
//    CITemperatureAndTint 落地，方向待真機驗證）。isMono 配方恆 0 —
//    去飽和後再套色溫會把黑白重新染色（LooksTests 強制）。
//  - tintShift：CITemperatureAndTint 的 tint 軸偏移。green↔magenta 方向無法
//    本機驗證 → 本輪全部配方保守設 0，欄位留給真機調校輪使用。
//  - vignette ∈ [0, 1]（0 = 無暗角；App 層映射 CIVignette 強度）。
//  - id 為持久化字串（AppStorage "look.selected" 直接存 id）→ 一經釋出不可改名，
//    LooksTests 鎖定完整 id 清單。

import Foundation

/// 一款調色配方（Look）。純值型別，App 層 LookEngine 負責把它變成 CIFilter 鏈。
public struct LookRecipe: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    /// 繁體中文顯示名。
    public let name: String
    /// 黑白 Look：引擎強制 saturation 0、跳過色溫（不讓黑白被重新染色）。
    public let isMono: Bool
    /// 5 點 tone curve（x 遞增 0…1；y 0…1）。App 層轉 CIToneCurve inputPoint0…4。
    public let toneCurve: [NPoint]
    /// 0…2；1 = 不動。
    public let saturation: Double
    /// 色溫偏移（K，6500 基準；正暖負冷）。
    public let temperatureShift: Double
    /// 色調偏移（CITemperatureAndTint tint 軸）。
    public let tintShift: Double
    /// 暗角強度 0…1；0 = 無。
    public let vignette: Double

    public init(
        id: String,
        name: String,
        isMono: Bool,
        toneCurve: [NPoint],
        saturation: Double,
        temperatureShift: Double,
        tintShift: Double,
        vignette: Double
    ) {
        self.id = id
        self.name = name
        self.isMono = isMono
        self.toneCurve = toneCurve
        self.saturation = saturation
        self.temperatureShift = temperatureShift
        self.tintShift = tintShift
        self.vignette = vignette
    }

    // MARK: - 原色（恆等配方）

    /// 恆等：curve y=x、saturation 1、無色溫/色調偏移、無暗角。
    /// LookEngine 對 id == "none" 完整跳過 filter chain（即時預覽零濾鏡成本）。
    public static let passthrough = LookRecipe(
        id: "none",
        name: "原色",
        isMono: false,
        toneCurve: [
            NPoint(x: 0, y: 0),
            NPoint(x: 0.25, y: 0.25),
            NPoint(x: 0.5, y: 0.5),
            NPoint(x: 0.75, y: 0.75),
            NPoint(x: 1, y: 1)
        ],
        saturation: 1,
        temperatureShift: 0,
        tintShift: 0,
        vignette: 0
    )

    // MARK: - 黑白系（6 款）

    /// 銀鹽：經典銀鹽相紙。中段 S 曲線（暗部略壓、亮部略提）拉出銀鹽的
    /// 厚重灰階層次，微暗角模擬放大機邊緣失光。
    public static let silver = LookRecipe(
        id: "silver",
        name: "銀鹽",
        isMono: true,
        toneCurve: [
            NPoint(x: 0, y: 0),
            NPoint(x: 0.25, y: 0.20),
            NPoint(x: 0.5, y: 0.52),
            NPoint(x: 0.75, y: 0.82),
            NPoint(x: 1, y: 1)
        ],
        saturation: 0,
        temperatureShift: 0,
        tintShift: 0,
        vignette: 0.15
    )

    /// 墨：水墨般的重對比。暗部大幅下壓（0.25 → 0.12）讓黑就是黑，
    /// 亮部拉開，中間調陡峭 — 線條感、輪廓感優先，細節讓位。
    public static let ink = LookRecipe(
        id: "ink",
        name: "墨",
        isMono: true,
        toneCurve: [
            NPoint(x: 0, y: 0),
            NPoint(x: 0.25, y: 0.12),
            NPoint(x: 0.5, y: 0.48),
            NPoint(x: 0.75, y: 0.85),
            NPoint(x: 1, y: 1)
        ],
        saturation: 0,
        temperatureShift: 0,
        tintShift: 0,
        vignette: 0.25
    )

    /// 霧白：高調（high-key）黑白。黑點抬到 0.10（沒有純黑）、白點壓到 0.96
    /// （沒有刺眼白）、整條曲線上移 — 柔霧、輕盈、適合窗光與淺色場景。
    public static let mist = LookRecipe(
        id: "mist",
        name: "霧白",
        isMono: true,
        toneCurve: [
            NPoint(x: 0, y: 0.10),
            NPoint(x: 0.25, y: 0.34),
            NPoint(x: 0.5, y: 0.60),
            NPoint(x: 0.75, y: 0.82),
            NPoint(x: 1, y: 0.96)
        ],
        saturation: 0,
        temperatureShift: 0,
        tintShift: 0,
        vignette: 0
    )

    /// 街頭：報導攝影的粗礪感。黑點微抬 0.04（保住暗部紋理不死黑）、
    /// 中段對比拉硬、白點微壓，配重暗角把視線推向畫面中心。
    public static let street = LookRecipe(
        id: "street",
        name: "街頭",
        isMono: true,
        toneCurve: [
            NPoint(x: 0, y: 0.04),
            NPoint(x: 0.25, y: 0.18),
            NPoint(x: 0.5, y: 0.50),
            NPoint(x: 0.75, y: 0.84),
            NPoint(x: 1, y: 0.98)
        ],
        saturation: 0,
        temperatureShift: 0,
        tintShift: 0,
        vignette: 0.35
    )

    /// 重曝黑：低調（low-key）劇場感。整條曲線下壓（白點只到 0.92、
    /// 亮部 0.75 → 0.72 提早滾降），配最重暗角 — 只有光打到的地方存在。
    public static let noir = LookRecipe(
        id: "noir",
        name: "重曝黑",
        isMono: true,
        toneCurve: [
            NPoint(x: 0, y: 0),
            NPoint(x: 0.25, y: 0.10),
            NPoint(x: 0.5, y: 0.40),
            NPoint(x: 0.75, y: 0.72),
            NPoint(x: 1, y: 0.92)
        ],
        saturation: 0,
        temperatureShift: 0,
        tintShift: 0,
        vignette: 0.5
    )

    /// 靜物灰：低對比中灰調。黑白點都往中間收（0.06 / 0.94）、曲線平緩 —
    /// 質感與形狀優先的靜物、產品、建築細節拍法。
    public static let still = LookRecipe(
        id: "still",
        name: "靜物灰",
        isMono: true,
        toneCurve: [
            NPoint(x: 0, y: 0.06),
            NPoint(x: 0.25, y: 0.28),
            NPoint(x: 0.5, y: 0.52),
            NPoint(x: 0.75, y: 0.76),
            NPoint(x: 1, y: 0.94)
        ],
        saturation: 0,
        temperatureShift: 0,
        tintShift: 0,
        vignette: 0.1
    )

    // MARK: - 彩色系（6 款）

    /// 奶油膚：人像優先。提亮中間調（0.5 → 0.58）讓膚色透亮、微降飽和（0.9）
    /// 收掉數位豔感、暖 +200K 給奶油底色，極輕暗角聚焦臉部。
    public static let cream = LookRecipe(
        id: "cream",
        name: "奶油膚",
        isMono: false,
        toneCurve: [
            NPoint(x: 0, y: 0.02),
            NPoint(x: 0.25, y: 0.30),
            NPoint(x: 0.5, y: 0.58),
            NPoint(x: 0.75, y: 0.80),
            NPoint(x: 1, y: 0.98)
        ],
        saturation: 0.9,
        temperatureShift: 200,
        tintShift: 0,
        vignette: 0.08
    )

    /// 日系清透：空氣感。暗部整段抬起（黑點 0.08）不留死黑、整體提亮、
    /// 飽和降到 0.85、微冷 −150K — 白牆、天光、日常的乾淨透明感。
    public static let airy = LookRecipe(
        id: "airy",
        name: "日系清透",
        isMono: false,
        toneCurve: [
            NPoint(x: 0, y: 0.08),
            NPoint(x: 0.25, y: 0.33),
            NPoint(x: 0.5, y: 0.58),
            NPoint(x: 0.75, y: 0.81),
            NPoint(x: 1, y: 0.98)
        ],
        saturation: 0.85,
        temperatureShift: -150,
        tintShift: 0,
        vignette: 0
    )

    /// 電影青橙：好萊塢 teal-orange 的單軸近似 — 全域暖 +250K 把膚色推向橙、
    /// S 曲線加對比、飽和 1.15 讓互補色互頂，中等暗角收邊。
    public static let tealOrange = LookRecipe(
        id: "tealorange",
        name: "電影青橙",
        isMono: false,
        toneCurve: [
            NPoint(x: 0, y: 0.02),
            NPoint(x: 0.25, y: 0.20),
            NPoint(x: 0.5, y: 0.52),
            NPoint(x: 0.75, y: 0.83),
            NPoint(x: 1, y: 0.98)
        ],
        saturation: 1.15,
        temperatureShift: 250,
        tintShift: 0,
        vignette: 0.2
    )

    /// 暖片：過期負片的暖。最重的色溫偏移 +500K、輕 S 曲線、飽和只加 1.05
    /// （暖靠色溫不靠豔）、黑點微抬 — 黃昏、室內鎢絲燈、回憶感。
    public static let warmFilm = LookRecipe(
        id: "warm",
        name: "暖片",
        isMono: false,
        toneCurve: [
            NPoint(x: 0, y: 0.03),
            NPoint(x: 0.25, y: 0.24),
            NPoint(x: 0.5, y: 0.54),
            NPoint(x: 0.75, y: 0.80),
            NPoint(x: 1, y: 0.97)
        ],
        saturation: 1.05,
        temperatureShift: 500,
        tintShift: 0,
        vignette: 0.15
    )

    /// 夜色：夜景保細節。暗部抬起（0.25 → 0.24 相對線性偏上）保住陰影層次、
    /// 白點壓 0.94 防燈爆、冷 −300K 給夜的藍、飽和 1.1 讓霓虹出來，重暗角。
    public static let night = LookRecipe(
        id: "night",
        name: "夜色",
        isMono: false,
        toneCurve: [
            NPoint(x: 0, y: 0.05),
            NPoint(x: 0.25, y: 0.24),
            NPoint(x: 0.5, y: 0.50),
            NPoint(x: 0.75, y: 0.78),
            NPoint(x: 1, y: 0.94)
        ],
        saturation: 1.1,
        temperatureShift: -300,
        tintShift: 0,
        vignette: 0.3
    )

    /// 食光：食物優先。中間調大幅提亮（0.5 → 0.60）讓餐盤發光、
    /// 飽和 1.25 全表最高（食慾靠顏色）、暖 +300K 模擬鎢絲餐燈、無暗角。
    public static let food = LookRecipe(
        id: "food",
        name: "食光",
        isMono: false,
        toneCurve: [
            NPoint(x: 0, y: 0.02),
            NPoint(x: 0.25, y: 0.30),
            NPoint(x: 0.5, y: 0.60),
            NPoint(x: 0.75, y: 0.84),
            NPoint(x: 1, y: 1)
        ],
        saturation: 1.25,
        temperatureShift: 300,
        tintShift: 0,
        vignette: 0
    )

    // MARK: - 全表

    /// 順序即 UI 顯示順序：原色 → 黑白 6 → 彩色 6（共 13）。
    public static let all: [LookRecipe] = [
        .passthrough,
        .silver, .ink, .mist, .street, .noir, .still,
        .cream, .airy, .tealOrange, .warmFilm, .night, .food
    ]

    /// 以 id 查配方（AppStorage "look.selected" → 配方；未知 id 回 nil，
    /// 呼叫端自行決定 fallback 到 passthrough）。
    public static func byID(_ id: String) -> LookRecipe? {
        all.first { $0.id == id }
    }
}
