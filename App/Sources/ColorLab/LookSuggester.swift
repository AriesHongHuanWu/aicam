//  LookSuggester.swift
//  AICam — 場景 → Look 推薦 top-3（A3；MASTER-PLAN §6 F12 / v0.3.0 契約）。
//
//  規則表（不是模型）：VNClassifyImageRequest 場景標籤（FrameAnalyzer 每 ~1s
//  產出、經 facts.sceneTags 流進來）+ 亮度直方圖 + 有無人臉 → 有序候選 →
//  去重取前 3。誠實原則：拿不到標籤/直方圖時規則自然靜默，fallback 保底
//  永遠給滿 3 款。
//
//  優先序（高 → 低）：
//  1. 人臉存在 → 「奶油膚」（人像永遠第一優先）
//  2. 食物標籤 → 「食光」
//  3. 戶外/天空 + 高亮（平均 luma > 0.55）→ 「日系清透」
//  4. 夜間標籤 或 低亮（平均 luma < 0.25）→ 「夜色」
//  5. fallback：「銀鹽」「電影青橙」「奶油膚」
//
//  標籤匹配用小寫子字串（VNClassifyImageRequest 的 identifier 是英文分類樹
//  節點名，如 "food"、"sky"、"night"；精確詞表無法本機驗證 → 寬鬆子字串
//  匹配 + 真機觀察後再收斂）。
//
//  契約：@MainActor @Observable、static let shared、
//  func ingest(sceneTags:histogram:)。hasFace 為新增的「有預設值」參數 —
//  照契約簽名的呼叫端照常編譯，知道臉況的呼叫端（讀 facts.faces）多傳一個 Bool。

import AICamCore
import Foundation
import Observation

@MainActor
@Observable
final class LookSuggester {

    static let shared = LookSuggester()

    /// 推薦 top-3 Look id（恆 3 個、恆為 LookRecipe.all 內的有效 id、不重複）。
    /// UI 一排三個縮圖讀這裡；只在內容變化時寫入（@Observable 逐屬性追蹤，
    /// 不寫就不觸發讀取端 diff — 場景穩定時零 UI 成本）。
    private(set) var suggestedIDs: [String] = LookSuggester.fallbackIDs

    /// 保底推薦（黑白招牌 + 彩色招牌 + 人像）；也是初始值。
    private static let fallbackIDs = ["silver", "tealorange", "cream"]

    private init() {}

    /// 餵入最新場景觀測（呼叫端在 MainActor；CoachSession publish 後的節奏即可，
    /// 內部無節流 — 上游 sceneTags 本來就 ~1s 才變一次）。
    func ingest(sceneTags: [String], histogram: LumaHistogram?, hasFace: Bool = false) {
        let tags = sceneTags.map { $0.lowercased() }

        /// 任一標籤含任一關鍵子字串即中。
        func tagsContain(_ keywords: [String]) -> Bool {
            tags.contains { tag in keywords.contains { tag.contains($0) } }
        }

        // 平均亮度（0…1）：64-bin 直方圖的加權平均（bin 中心值 × 占比）。
        let meanLuma: Double? = histogram.map { h in
            h.bins.enumerated().reduce(0.0) { sum, item in
                sum + item.element * (Double(item.offset) + 0.5) / 64.0
            }
        }

        var picks: [String] = []
        if hasFace {
            picks.append("cream")
        }
        if tagsContain(["food", "meal", "dessert", "cuisine", "fruit", "drink", "coffee", "cake"]) {
            picks.append("food")
        }
        if tagsContain(["outdoor", "sky", "beach", "mountain", "landscape", "snow", "cloud", "sea"]),
           let luma = meanLuma, luma > 0.55 {
            picks.append("airy")
        }
        if tagsContain(["night", "dark", "concert", "firework", "moon"])
            || (meanLuma ?? 1) < 0.25 {
            picks.append("night")
        }
        picks.append(contentsOf: Self.fallbackIDs)

        // 去重保序、取前 3（fallback 有 3 款 → 恆給滿）
        var seen = Set<String>()
        let top3 = Array(picks.filter { seen.insert($0).inserted }.prefix(3))

        if top3 != suggestedIDs {
            suggestedIDs = top3
        }
    }
}
