//  EffectsTests.swift
//  AICamCoreTests — 特效配方驗證（A2；v0.5.0 分割特效引擎契約硬規則）。
//
//  這些測試是「配方合約」：EffectCompositor（App 層，CI 無法單測）盲信這裡
//  驗過的不變量 — id 唯一且鎖定、none 全中性、四款特效 needsMask 為 true、
//  各參數在域內。改配方先過這關。

import XCTest
import AICamCore

final class EffectsTests: XCTestCase {

    // MARK: - 全表結構：無 + 特效 4 款

    func testAllHasFiveRecipesNoneFirst() {
        XCTAssertEqual(EffectRecipe.all.count, 5)
        XCTAssertEqual(EffectRecipe.all.first, EffectRecipe.none)
    }

    // MARK: - id 唯一且鎖定（id 持久化進 AppStorage "effect.selected"，釋出後不可改名）

    func testIDsAreUniqueAndStable() {
        let ids = EffectRecipe.all.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "id 重複")
        XCTAssertEqual(
            ids,
            ["none", "pop", "blur", "spotlight", "duotone"],
            "id 清單被改動 — id 已持久化進用戶設定，改名即破壞既有用戶"
        )
    }

    func testNamesAreNonEmptyAndUnique() {
        let names = EffectRecipe.all.map { $0.name }
        XCTAssertFalse(names.contains(where: { $0.isEmpty }))
        XCTAssertEqual(Set(names).count, names.count, "顯示名重複")
    }

    // MARK: - none = 全中性（App 層零成本跳過的前提）

    func testNoneIsNeutral() {
        let none = EffectRecipe.none
        XCTAssertEqual(none.id, "none")
        XCTAssertEqual(none.name, "無")
        XCTAssertFalse(none.needsMask)
        XCTAssertEqual(none.bgSaturation, 1, "中性飽和度必須為 1")
        XCTAssertEqual(none.bgBlurRadius, 0)
        XCTAssertEqual(none.bgExposure, 0)
        XCTAssertEqual(none.subjectWarmth, 0)
        XCTAssertEqual(none.bgTemperatureShift, 0)
    }

    // MARK: - needsMask：四款特效皆需 mask、只有 none 不需

    func testNeedsMaskIsCorrect() {
        for recipe in EffectRecipe.all {
            if recipe.id == EffectRecipe.none.id {
                XCTAssertFalse(recipe.needsMask, "none 不得要求 mask")
            } else {
                XCTAssertTrue(recipe.needsMask, "\(recipe.id)：分割特效必須 needsMask")
            }
        }
    }

    // MARK: - 參數域

    func testBgSaturationWithinRange() {
        for recipe in EffectRecipe.all {
            XCTAssertGreaterThanOrEqual(recipe.bgSaturation, 0, "\(recipe.id)：bgSaturation < 0")
            XCTAssertLessThanOrEqual(recipe.bgSaturation, 2, "\(recipe.id)：bgSaturation > 2")
        }
    }

    func testBgBlurRadiusWithinRange() {
        for recipe in EffectRecipe.all {
            XCTAssertGreaterThanOrEqual(recipe.bgBlurRadius, 0, "\(recipe.id)：bgBlurRadius < 0")
            XCTAssertLessThanOrEqual(
                recipe.bgBlurRadius, 50,
                "\(recipe.id)：bgBlurRadius 超出合理域（1440px 寬基準下 > 50px 已不可辨識）"
            )
        }
    }

    /// 背景曝光只准壓暗或不動：正 EV 提亮背景會反轉主體/背景的視覺主從。
    func testBgExposureWithinRange() {
        for recipe in EffectRecipe.all {
            XCTAssertGreaterThanOrEqual(recipe.bgExposure, -4, "\(recipe.id)：bgExposure < −4 EV")
            XCTAssertLessThanOrEqual(recipe.bgExposure, 0, "\(recipe.id)：bgExposure 不得為正（背景不得比主體亮）")
        }
    }

    func testTemperatureShiftsWithinRange() {
        for recipe in EffectRecipe.all {
            XCTAssertLessThanOrEqual(abs(recipe.subjectWarmth), 1000, "\(recipe.id)：subjectWarmth 超出 ±1000K")
            XCTAssertLessThanOrEqual(abs(recipe.bgTemperatureShift), 1000, "\(recipe.id)：bgTemperatureShift 超出 ±1000K")
        }
    }

    // MARK: - 設計意圖鎖定（v0.5.0 參數表；改值需同步 MASTER-PLAN 與本測試）

    func testDesignIntentParameters() {
        // 跳色 = 背景全去飽和，其餘中性
        let pop = EffectRecipe.colorPop
        XCTAssertEqual(pop.bgSaturation, 0)
        XCTAssertEqual(pop.bgBlurRadius, 0)
        XCTAssertEqual(pop.bgExposure, 0)
        XCTAssertEqual(pop.subjectWarmth, 0)
        XCTAssertEqual(pop.bgTemperatureShift, 0)

        // 背景虛化 = 只模糊（14 @1440px 寬基準）
        let blur = EffectRecipe.backgroundBlur
        XCTAssertEqual(blur.bgBlurRadius, 14)
        XCTAssertEqual(blur.bgSaturation, 1)
        XCTAssertEqual(blur.bgExposure, 0)
        XCTAssertEqual(blur.subjectWarmth, 0)
        XCTAssertEqual(blur.bgTemperatureShift, 0)

        // 聚光 = 背景壓暗 −1.6 EV + 降飽和 0.6
        let spot = EffectRecipe.spotlight
        XCTAssertEqual(spot.bgExposure, -1.6)
        XCTAssertEqual(spot.bgSaturation, 0.6)
        XCTAssertEqual(spot.bgBlurRadius, 0)
        XCTAssertEqual(spot.subjectWarmth, 0)
        XCTAssertEqual(spot.bgTemperatureShift, 0)

        // 雙色調 = 主體 +300K / 背景 −500K / 背景飽和 0.75
        let duo = EffectRecipe.duotone
        XCTAssertEqual(duo.subjectWarmth, 300)
        XCTAssertEqual(duo.bgTemperatureShift, -500)
        XCTAssertEqual(duo.bgSaturation, 0.75)
        XCTAssertEqual(duo.bgBlurRadius, 0)
        XCTAssertEqual(duo.bgExposure, 0)
    }

    // MARK: - 查表

    func testByIDLookup() {
        XCTAssertEqual(EffectRecipe.byID("none"), EffectRecipe.none)
        XCTAssertEqual(EffectRecipe.byID("pop")?.name, "跳色")
        XCTAssertEqual(EffectRecipe.byID("blur")?.name, "背景虛化")
        XCTAssertEqual(EffectRecipe.byID("spotlight")?.name, "聚光")
        XCTAssertEqual(EffectRecipe.byID("duotone")?.name, "雙色調")
        XCTAssertNil(EffectRecipe.byID("不存在的id"))
    }

    // MARK: - Codable round-trip（配方可序列化，未來雲端同步/匯出用）

    func testCodableRoundTrip() throws {
        for recipe in EffectRecipe.all {
            let data = try JSONEncoder().encode(recipe)
            let decoded = try JSONDecoder().decode(EffectRecipe.self, from: data)
            XCTAssertEqual(decoded, recipe)
        }
    }
}
