//  TargetSolverTests.swift
//  AICamCoreTests — 目標點求解測試（Linux swift test 必須可跑）。
//
//  所有期望值皆手算，過程寫在各測試注釋。config = ScoringConfig.standard：
//  idealHeadroom 0.05…0.12 → 理想臉頂 idealTop = (0.05+0.12)/2 = 0.085。

import XCTest
import AICamCore

final class TargetSolverTests: XCTestCase {

    private let config = ScoringConfig.standard

    private func result(_ mode: SubjectMode) -> CompositionResult {
        CompositionResult(score: 70, subjectMode: mode)
    }

    /// halfBody 人像素材：單臉 + 可調 yaw / sceneTags。
    private func halfBodyFacts(
        faceBox: NRect, yawDeg: Double? = nil, sceneTags: [String] = []
    ) -> FrameFacts {
        FrameFacts(
            faces: [FaceFact(box: faceBox, yawDeg: yawDeg)],
            sceneTags: sceneTags
        )
    }

    // MARK: - 臉在中央偏左 → 較近的左三分線

    func testCenterLeftFaceTargetsNearerLeftThird() throws {
        // 臉框 (0.32, 0.20, 0.16, 0.20) → anchor = 中心 (0.40, 0.30)。
        // x：|0.40 − 1/3| = 0.0667 < |0.40 − 2/3| = 0.2667 → target.x = 1/3。
        // y：idealTop = 0.085，臉頂 minY = 0.20 → δ = 0.085 − 0.20 = −0.115
        //    → target.y = 0.30 − 0.115 = 0.185。
        // distance = √(0.0667² + 0.115²) = √(0.004444 + 0.013225) ≈ 0.13293。
        let facts = halfBodyFacts(faceBox: NRect(x: 0.32, y: 0.20, width: 0.16, height: 0.20))
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))

        let anchor = try XCTUnwrap(g.anchor)
        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(anchor.x, 0.40, accuracy: 1e-12)
        XCTAssertEqual(anchor.y, 0.30, accuracy: 1e-12)
        XCTAssertEqual(target.x, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(target.y, 0.185, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(g.normalizedDistance), 0.13293, accuracy: 1e-4)
        // Solver 一律回 .searching；鎖定判斷屬於 GuidanceTracker。
        XCTAssertEqual(g.lockState, LockState.searching)
    }

    // MARK: - 視線空間：yaw 覆寫三分線選擇

    func testYawLookingLeftForcesRightTwoThirdsLine() throws {
        // 臉框 (0.27, 0.085, 0.16, 0.20) → anchor = (0.35, 0.185)。
        // yaw = −20°（CoreTypes：正 yaw = 臉朝畫面右緣 ⇒ 負 = 朝左看）。
        // 就近則是 1/3，但 |yaw| > 12 強制放「視線來向」側 = 右 2/3 線（左側留白）。
        // y：臉頂 minY = 0.085 = idealTop → δ = 0 → target.y = anchor.y = 0.185。
        let facts = halfBodyFacts(
            faceBox: NRect(x: 0.27, y: 0.085, width: 0.16, height: 0.20), yawDeg: -20
        )
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))

        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(target.x, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(target.y, 0.185, accuracy: 1e-9)
        // 主體須右移（target.x > anchor.x）⇒ 相機往左 ⇒ hint = (−1, 0)。
        // distance = 2/3 − 0.35 = 0.31667。
        let hint = try XCTUnwrap(g.cameraMoveHint)
        XCTAssertEqual(hint.x, -1.0, accuracy: 1e-9)
        XCTAssertEqual(hint.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(g.normalizedDistance), 0.31667, accuracy: 1e-4)
    }

    func testYawLookingRightForcesLeftThirdLine() throws {
        // anchor.x = 0.60（就近則是 2/3），yaw = +20°（朝右看）→ 強制左 1/3 線（右側留白）。
        let facts = halfBodyFacts(
            faceBox: NRect(x: 0.52, y: 0.085, width: 0.16, height: 0.20), yawDeg: 20
        )
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))
        XCTAssertEqual(try XCTUnwrap(g.target).x, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testSmallYawDoesNotOverrideNearestThird() throws {
        // |yaw| = 10 ≤ 12 → 不覆寫，仍取就近三分線（anchor.x = 0.60 → 2/3）。
        let facts = halfBodyFacts(
            faceBox: NRect(x: 0.52, y: 0.085, width: 0.16, height: 0.20), yawDeg: 10
        )
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))
        XCTAssertEqual(try XCTUnwrap(g.target).x, 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - headroom 修正方向（逐案手算）

    func testFaceTooLowTargetsHigherY() throws {
        // 臉太低（headroom 過多）：臉框 (0.42, 0.30, 0.16, 0.20) → anchor = (0.50, 0.40)。
        // δ = 0.085 − 0.30 = −0.215 → target.y = 0.40 − 0.215 = 0.185 < anchor.y ✓
        // （target 在 anchor 上方 = 主體須在畫面中上移）。
        // hint.y = (anchor.y − target.y)/d > 0 = 相機往下（NormalizedFrame y 向下）✓。
        let facts = halfBodyFacts(faceBox: NRect(x: 0.42, y: 0.30, width: 0.16, height: 0.20))
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))

        let anchor = try XCTUnwrap(g.anchor)
        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(target.y, 0.185, accuracy: 1e-9)
        XCTAssertLessThan(target.y, anchor.y)
        XCTAssertGreaterThan(try XCTUnwrap(g.cameraMoveHint).y, 0)
    }

    func testFaceTooHighTargetsLowerY() throws {
        // 臉太高（headroom 過少）：臉框 (0.42, 0.01, 0.16, 0.20) → anchor = (0.50, 0.11)。
        // δ = 0.085 − 0.01 = +0.075 → target.y = 0.11 + 0.075 = 0.185 > anchor.y ✓。
        // hint.y < 0 = 相機往上。
        let facts = halfBodyFacts(faceBox: NRect(x: 0.42, y: 0.01, width: 0.16, height: 0.20))
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))

        let anchor = try XCTUnwrap(g.anchor)
        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(target.y, 0.185, accuracy: 1e-9)
        XCTAssertGreaterThan(target.y, anchor.y)
        XCTAssertLessThan(try XCTUnwrap(g.cameraMoveHint).y, 0)
    }

    // MARK: - cameraMoveHint 方向語意（鎖死，錯這裡整個功能反向)

    func testCameraMoveHintPointsOppositeToSubjectMotion() throws {
        // 臉框 (0.47, 0.085, 0.16, 0.20) → anchor = (0.55, 0.185)。
        // 就近三分線 = 2/3 → target = (2/3, 0.185)：主體須「右移」到 target
        // ⇒ 相機往「左」⇒ hint = normalize(anchor − target) = (−1, 0)，hint.x < 0。
        // distance = 2/3 − 0.55 = 0.11667。
        let facts = halfBodyFacts(faceBox: NRect(x: 0.47, y: 0.085, width: 0.16, height: 0.20))
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))

        let hint = try XCTUnwrap(g.cameraMoveHint)
        XCTAssertLessThan(hint.x, 0)
        XCTAssertEqual(hint.x, -1.0, accuracy: 1e-9)
        XCTAssertEqual(hint.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(g.normalizedDistance), 0.11667, accuracy: 1e-4)
    }

    // MARK: - nonHuman：最近 power point

    func testNonHumanSnapsToNearestPowerPoint() throws {
        // subjectBox (0.6, 0.5, 0.2, 0.2) → anchor = (0.70, 0.60)。
        // 到 4 個 power point 的距離：(2/3, 2/3) 最近（Δ = (0.0333, −0.0667)）。
        // distance = √(0.0333² + 0.0667²) = √0.005556 ≈ 0.07454。
        // hint = normalize(anchor − target) = (0.0333, −0.0667)/0.07454 ≈ (0.4472, −0.8944)。
        // 語意自查：主體須往「左下」移到 target（Δx < 0、Δy > 0，y 向下）
        // ⇒ 相機反向移「右上」⇒ hint.x > 0、hint.y < 0 ✓。
        let facts = FrameFacts(subjectBox: NRect(x: 0.6, y: 0.5, width: 0.2, height: 0.2))
        let g = TargetSolver.solve(facts: facts, result: result(.nonHuman))

        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(target.x, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(target.y, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(g.normalizedDistance), 0.07454, accuracy: 1e-4)
        let hint = try XCTUnwrap(g.cameraMoveHint)
        XCTAssertEqual(hint.x, 0.4472, accuracy: 1e-4)
        XCTAssertEqual(hint.y, -0.8944, accuracy: 1e-4)
        // 單位向量。
        XCTAssertEqual((hint.x * hint.x + hint.y * hint.y).squareRoot(), 1.0, accuracy: 1e-9)
    }

    func testNonHumanUpperLeftSnapsToUpperLeftPowerPoint() throws {
        // anchor = (0.30, 0.30) → 最近 power point = (1/3, 1/3)。
        let facts = FrameFacts(subjectBox: NRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        let g = TargetSolver.solve(facts: facts, result: result(.nonHuman))
        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(target.x, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(target.y, 1.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - fullBody：主體框中心對齊 0.5，夾 headroom

    func testFullBodyAlignsSubjectCenterWithinHeadroomClamp() throws {
        // 臉框 (0.45, 0.10, 0.10, 0.12) → anchor = (0.50, 0.16)。
        // 未夾案例：subject (0.3, 0.10, 0.4, 0.80) → midY = 0.50 → δ₀ = 0。
        // clamp 區間 = [0.05 − 0.10, 0.12 − 0.10] = [−0.05, 0.02]，0 在內 → δ = 0
        // → target.y = 0.16。
        let face = FaceFact(box: NRect(x: 0.45, y: 0.10, width: 0.10, height: 0.12))
        let facts = FrameFacts(
            faces: [face],
            subjectBox: NRect(x: 0.3, y: 0.10, width: 0.4, height: 0.80)
        )
        let g = TargetSolver.solve(facts: facts, result: result(.fullBody))
        XCTAssertEqual(try XCTUnwrap(g.target).y, 0.16, accuracy: 1e-9)
    }

    func testFullBodyHeadroomClampOverridesCenterAlignment() throws {
        // 同臉框；subject (0.3, 0.05, 0.4, 0.70) → midY = 0.40 → δ₀ = 0.5 − 0.40 = 0.10。
        // clamp 上限 = idealHeadroomMax − minY = 0.12 − 0.10 = 0.02 → δ = 0.02
        // → target.y = 0.16 + 0.02 = 0.18（headroom 約束優先於置中）。
        let face = FaceFact(box: NRect(x: 0.45, y: 0.10, width: 0.10, height: 0.12))
        let facts = FrameFacts(
            faces: [face],
            subjectBox: NRect(x: 0.3, y: 0.05, width: 0.4, height: 0.70)
        )
        let g = TargetSolver.solve(facts: facts, result: result(.fullBody))
        XCTAssertEqual(try XCTUnwrap(g.target).y, 0.18, accuracy: 1e-9)
    }

    // MARK: - 多人取最大臉

    func testLargestFaceWins() throws {
        // 小臉 (0.1, 0.25, 0.08, 0.10)、大臉 (0.52, 0.15, 0.24, 0.30)（面積大）
        // → anchor = 大臉中心 (0.64, 0.30)。closeUp：
        // x：|0.64 − 2/3| = 0.0267 < |0.64 − 1/3| → 2/3；
        // y：δ = 0.085 − 0.15 = −0.065 → target.y = 0.30 − 0.065 = 0.235。
        let facts = FrameFacts(faces: [
            FaceFact(box: NRect(x: 0.1, y: 0.25, width: 0.08, height: 0.10)),
            FaceFact(box: NRect(x: 0.52, y: 0.15, width: 0.24, height: 0.30))
        ])
        let g = TargetSolver.solve(facts: facts, result: result(.closeUp))

        let anchor = try XCTUnwrap(g.anchor)
        XCTAssertEqual(anchor.x, 0.64, accuracy: 1e-12)
        XCTAssertEqual(anchor.y, 0.30, accuracy: 1e-12)
        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(target.x, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(target.y, 0.235, accuracy: 1e-9)
    }

    // MARK: - 對稱置中 guard（P2 dormant：App 層尚未產出 symmetry tag）

    func testSymmetrySceneAllowsCenterTarget() throws {
        // anchor.x = 0.52（距中心 0.02 < 0.06）+ sceneTags 含 "symmetry" → target.x = 0.5。
        let facts = halfBodyFacts(
            faceBox: NRect(x: 0.44, y: 0.085, width: 0.16, height: 0.20),
            sceneTags: ["symmetry"]
        )
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))
        XCTAssertEqual(try XCTUnwrap(g.target).x, 0.5, accuracy: 1e-9)
    }

    func testNoSymmetryTagFallsBackToThirds() throws {
        // 同 anchor（0.52）但無 symmetry tag → 就近三分線 2/3。
        let facts = halfBodyFacts(faceBox: NRect(x: 0.44, y: 0.085, width: 0.16, height: 0.20))
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))
        XCTAssertEqual(try XCTUnwrap(g.target).x, 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - clamp

    func testClampToSafeArea() {
        // 出界點夾回 [0.08, 0.92]；界內點原樣通過。
        let clamped = TargetSolver.clampToSafeArea(NPoint(x: -0.5, y: 2.0))
        XCTAssertEqual(clamped.x, 0.08, accuracy: 1e-12)
        XCTAssertEqual(clamped.y, 0.92, accuracy: 1e-12)
        let passthrough = TargetSolver.clampToSafeArea(NPoint(x: 0.5, y: 0.185))
        XCTAssertEqual(passthrough.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(passthrough.y, 0.185, accuracy: 1e-12)
    }

    // MARK: - 無主體 / 邊界

    func testEmptyFrameReturnsSearchingWithNils() {
        let g = TargetSolver.solve(facts: FrameFacts(), result: result(.none))
        XCTAssertNil(g.anchor)
        XCTAssertNil(g.target)
        XCTAssertNil(g.cameraMoveHint)
        XCTAssertNil(g.normalizedDistance)
        XCTAssertEqual(g.lockState, LockState.searching)
    }

    func testPortraitModeWithoutFaceGivesAnchorOnly() throws {
        // 防禦：人像模式但本帧沒臉（輸入不一致）→ anchor = subjectBox 中心、無 target。
        let facts = FrameFacts(subjectBox: NRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4))
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))
        XCTAssertNotNil(g.anchor)
        XCTAssertNil(g.target)
        XCTAssertNil(g.normalizedDistance)
        XCTAssertEqual(g.lockState, LockState.searching)
    }

    func testPerfectAlignmentGivesZeroDistanceAndNoHint() throws {
        // 臉中心正好在 target：臉框 (1/3 − 0.08, 0.085, 0.16, 0.20)
        // → anchor = (1/3, 0.185) = target → distance 0、hint nil、
        // lockState 仍 .searching（鎖定屬於 tracker）。
        let facts = halfBodyFacts(
            faceBox: NRect(x: 1.0 / 3.0 - 0.08, y: 0.085, width: 0.16, height: 0.20)
        )
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))
        XCTAssertEqual(try XCTUnwrap(g.normalizedDistance), 0.0, accuracy: 1e-9)
        XCTAssertNil(g.cameraMoveHint)
        XCTAssertEqual(g.lockState, LockState.searching)
    }

    // MARK: - v0.5.0 群組合照（≥2 臉 + 整群 union subjectBox）

    func testGroupAnchorIsUnionSubjectCenter() throws {
        // 群組：臉 A (0.10, 0.30, 0.16, 0.20)（面積 0.032）、
        // 臉 B (0.60, 0.20, 0.20, 0.25)（面積 0.050 = 最大）。
        // App 層 union subjectBox = (0.05, 0.15, 0.80, 0.45)
        // → anchor = 整群中心 (0.45, 0.375)，「不再是」最大臉中心 (0.70, 0.325)。
        // x：無 yaw → 就近三分線：|0.45 − 1/3| = 0.1167 < |0.45 − 2/3| = 0.2167 → 1/3。
        // y：最高臉頂 topY = min(0.30, 0.20) = 0.20 → δ = 0.085 − 0.20 = −0.115
        //    → target.y = 0.375 − 0.115 = 0.26。
        let facts = FrameFacts(
            faces: [
                FaceFact(box: NRect(x: 0.10, y: 0.30, width: 0.16, height: 0.20)),
                FaceFact(box: NRect(x: 0.60, y: 0.20, width: 0.20, height: 0.25))
            ],
            subjectBox: NRect(x: 0.05, y: 0.15, width: 0.80, height: 0.45)
        )
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))

        let anchor = try XCTUnwrap(g.anchor)
        XCTAssertEqual(anchor.x, 0.45, accuracy: 1e-12)
        XCTAssertEqual(anchor.y, 0.375, accuracy: 1e-12)
        let target = try XCTUnwrap(g.target)
        XCTAssertEqual(target.x, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(target.y, 0.26, accuracy: 1e-9)
    }

    func testGroupHeadroomUsesHighestFaceTopNotPrimary() throws {
        // 最大臉 B (0.55, 0.30, 0.24, 0.30)（minY = 0.30）、
        // 較小但站得更高的臉 A (0.15, 0.10, 0.10, 0.12)（minY = 0.10 = 最高臉頂）。
        // union subjectBox = (0.10, 0.05, 0.75, 0.60) → anchor = (0.475, 0.35)。
        // topY = 0.10 → δ = 0.085 − 0.10 = −0.015 → target.y = 0.35 − 0.015 = 0.335。
        // 若誤用最大臉 minY = 0.30：δ = −0.215 → target.y = 0.135 —
        // 整群被抬到爆掉 A 的頭（本測試就是鎖死這個錯誤不得回歸）。
        let facts = FrameFacts(
            faces: [
                FaceFact(box: NRect(x: 0.55, y: 0.30, width: 0.24, height: 0.30)),
                FaceFact(box: NRect(x: 0.15, y: 0.10, width: 0.10, height: 0.12))
            ],
            subjectBox: NRect(x: 0.10, y: 0.05, width: 0.75, height: 0.60)
        )
        let g = TargetSolver.solve(facts: facts, result: result(.halfBody))
        XCTAssertEqual(try XCTUnwrap(g.target).y, 0.335, accuracy: 1e-9)
    }

    func testGroupFullBodyClampUsesHighestFaceTop() throws {
        // 群組全身：臉 A (0.15, 0.08, 0.10, 0.12)（minY = 0.08 = 最高）、
        // 最大臉 B (0.55, 0.20, 0.20, 0.25)（minY = 0.20）。
        // union subjectBox = (0.10, 0.05, 0.80, 0.80) → midY = 0.45、
        // anchor = 整群中心 (0.50, 0.45)。
        // δ₀ = 0.5 − 0.45 = 0.05；clamp 以最高臉頂：[0.05 − 0.08, 0.12 − 0.08]
        // = [−0.03, 0.04] → δ = 0.04 → target.y = 0.45 + 0.04 = 0.49。
        // 若誤用最大臉 minY = 0.20：上限 = −0.08 → target.y = 0.37。
        let facts = FrameFacts(
            faces: [
                FaceFact(box: NRect(x: 0.15, y: 0.08, width: 0.10, height: 0.12)),
                FaceFact(box: NRect(x: 0.55, y: 0.20, width: 0.20, height: 0.25))
            ],
            subjectBox: NRect(x: 0.10, y: 0.05, width: 0.80, height: 0.80)
        )
        let g = TargetSolver.solve(facts: facts, result: result(.fullBody))
        XCTAssertEqual(try XCTUnwrap(g.target).y, 0.49, accuracy: 1e-9)
    }

    func testGroupWithoutUnionSubjectFallsBackToLargestFace() throws {
        // 防禦：≥2 臉但 subjectBox = nil（上游未組 union）→ 群組分支的 guard
        // 不成立 → 錨點退回最大臉中心（= testLargestFaceWins 的舊多人行為）。
        let facts = FrameFacts(faces: [
            FaceFact(box: NRect(x: 0.1, y: 0.25, width: 0.08, height: 0.10)),
            FaceFact(box: NRect(x: 0.52, y: 0.15, width: 0.24, height: 0.30))
        ])
        let g = TargetSolver.solve(facts: facts, result: result(.closeUp))
        let anchor = try XCTUnwrap(g.anchor)
        XCTAssertEqual(anchor.x, 0.64, accuracy: 1e-12)
        XCTAssertEqual(anchor.y, 0.30, accuracy: 1e-12)
    }
}
