//  LooksTests.swift
//  AICamCoreTests — Look 配方驗證（A3；v0.3.0 契約硬規則）。
//
//  這些測試是「配方合約」：LookEngine（App 層，CI 無法單測）盲信這裡驗過的
//  不變量 — curve 5 點 x 嚴格遞增、首尾在 0/1、y 域內、saturation/vignette 範圍、
//  黑白配方無色彩偏移。改配方先過這關。

import XCTest
import AICamCore

final class LooksTests: XCTestCase {

    // MARK: - 全表結構：原色 + 黑白 6 + 彩色 6

    func testAllHasThirteenRecipesPassthroughFirst() {
        XCTAssertEqual(LookRecipe.all.count, 13)
        XCTAssertEqual(LookRecipe.all.first, LookRecipe.passthrough)
        let monoCount = LookRecipe.all.filter { $0.isMono }.count
        XCTAssertEqual(monoCount, 6, "黑白系應恰為 6 款")
        XCTAssertEqual(LookRecipe.all.count - monoCount - 1, 6, "彩色系（不含原色）應恰為 6 款")
    }

    // MARK: - id 唯一且鎖定（id 持久化進 AppStorage "look.selected"，釋出後不可改名）

    func testIDsAreUniqueAndStable() {
        let ids = LookRecipe.all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "id 重複")
        XCTAssertEqual(
            ids,
            [
                "none",
                "silver", "ink", "mist", "street", "noir", "still",
                "cream", "airy", "tealorange", "warm", "night", "food"
            ],
            "id 清單被改動 — id 已持久化進用戶設定，改名即破壞既有用戶"
        )
    }

    func testNamesAreNonEmptyAndUnique() {
        let names = LookRecipe.all.map { $0.name }
        XCTAssertFalse(names.contains(where: { $0.isEmpty }))
        XCTAssertEqual(Set(names).count, names.count, "顯示名重複")
    }

    // MARK: - toneCurve：5 點、x 嚴格遞增、首 x=0 末 x=1、y 皆域內

    func testToneCurvesAreWellFormed() {
        for recipe in LookRecipe.all {
            XCTAssertEqual(recipe.toneCurve.count, 5, "\(recipe.id)：curve 必須恰 5 點")
            XCTAssertEqual(recipe.toneCurve.first?.x, 0, "\(recipe.id)：首點 x 必須為 0")
            XCTAssertEqual(recipe.toneCurve.last?.x, 1, "\(recipe.id)：末點 x 必須為 1")
            for (a, b) in zip(recipe.toneCurve, recipe.toneCurve.dropFirst()) {
                XCTAssertLessThan(a.x, b.x, "\(recipe.id)：curve x 必須嚴格遞增")
            }
            for point in recipe.toneCurve {
                XCTAssertGreaterThanOrEqual(point.y, 0, "\(recipe.id)：curve y < 0")
                XCTAssertLessThanOrEqual(point.y, 1, "\(recipe.id)：curve y > 1")
            }
        }
    }

    /// 曲線單調不減（y 也不往回走）：CIToneCurve 對非單調 y 會產生色調反轉。
    func testToneCurveYIsMonotonicNonDecreasing() {
        for recipe in LookRecipe.all {
            for (a, b) in zip(recipe.toneCurve, recipe.toneCurve.dropFirst()) {
                XCTAssertLessThanOrEqual(a.y, b.y, "\(recipe.id)：curve y 反轉（\(a.y) → \(b.y)）")
            }
        }
    }

    // MARK: - 參數範圍

    func testSaturationWithinRange() {
        for recipe in LookRecipe.all {
            XCTAssertGreaterThanOrEqual(recipe.saturation, 0, "\(recipe.id)：saturation < 0")
            XCTAssertLessThanOrEqual(recipe.saturation, 2, "\(recipe.id)：saturation > 2")
        }
    }

    func testVignetteWithinRange() {
        for recipe in LookRecipe.all {
            XCTAssertGreaterThanOrEqual(recipe.vignette, 0, "\(recipe.id)：vignette < 0")
            XCTAssertLessThanOrEqual(recipe.vignette, 1, "\(recipe.id)：vignette > 1")
        }
    }

    /// 黑白配方不得帶任何色彩參數：去飽和後再套色溫/色調會把黑白重新染色。
    func testMonoRecipesCarryNoColorShift() {
        for recipe in LookRecipe.all where recipe.isMono {
            XCTAssertEqual(recipe.saturation, 0, "\(recipe.id)：黑白配方 saturation 應為 0")
            XCTAssertEqual(recipe.temperatureShift, 0, "\(recipe.id)：黑白配方不得帶色溫偏移")
            XCTAssertEqual(recipe.tintShift, 0, "\(recipe.id)：黑白配方不得帶色調偏移")
        }
    }

    // MARK: - 原色 = 恆等

    func testPassthroughIsIdentity() {
        let p = LookRecipe.passthrough
        XCTAssertEqual(p.id, "none")
        XCTAssertEqual(p.name, "原色")
        XCTAssertFalse(p.isMono)
        for point in p.toneCurve {
            XCTAssertEqual(point.y, point.x, accuracy: 1e-12, "原色 curve 必須 y = x")
        }
        XCTAssertEqual(p.saturation, 1)
        XCTAssertEqual(p.temperatureShift, 0)
        XCTAssertEqual(p.tintShift, 0)
        XCTAssertEqual(p.vignette, 0)
    }

    // MARK: - 查表

    func testByIDLookup() {
        XCTAssertEqual(LookRecipe.byID("none"), LookRecipe.passthrough)
        XCTAssertEqual(LookRecipe.byID("cream")?.name, "奶油膚")
        XCTAssertEqual(LookRecipe.byID("tealorange")?.name, "電影青橙")
        XCTAssertNil(LookRecipe.byID("不存在的id"))
    }

    // MARK: - Codable round-trip（配方可序列化，未來雲端同步/匯出用）

    func testCodableRoundTrip() throws {
        for recipe in LookRecipe.all {
            let data = try JSONEncoder().encode(recipe)
            let decoded = try JSONDecoder().decode(LookRecipe.self, from: data)
            XCTAssertEqual(decoded, recipe)
        }
    }
}
