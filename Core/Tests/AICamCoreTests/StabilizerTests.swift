//  StabilizerTests.swift
//  AICamCoreTests — 建議穩定器與 EMA 平滑測試（全部使用注入時間，不碰 Date()）。

import XCTest
import AICamCore

final class StabilizerTests: XCTestCase {

    private func advice(
        _ category: AdviceCategory, _ message: String, priority: Int = 10
    ) -> CoachAdvice {
        CoachAdvice(category: category, message: message, priority: priority)
    }

    // MARK: - 基本顯示

    func testShowsFirstAdviceImmediately() {
        let stabilizer = AdviceStabilizer()
        let a = advice(.thirds, "往左移一點")
        XCTAssertEqual(stabilizer.update(candidate: a, at: 0), a)
    }

    // MARK: - 最短顯示時間

    func testMinimumDisplayHoldsAgainstNil() {
        let stabilizer = AdviceStabilizer(minDisplaySeconds: 1.5, switchAfterSeconds: 0.7)
        let a = advice(.thirds, "往左移一點")
        _ = stabilizer.update(candidate: a, at: 0)
        // 未滿 1.5s：即使候選消失也續顯。
        XCTAssertEqual(stabilizer.update(candidate: nil, at: 1.0), a)
        // 滿 1.5s 後才收掉。
        XCTAssertNil(stabilizer.update(candidate: nil, at: 1.6))
    }

    func testMinimumDisplayDelaysSwitchEvenAfterPersistence() {
        let stabilizer = AdviceStabilizer(minDisplaySeconds: 1.5, switchAfterSeconds: 0.7)
        let a = advice(.thirds, "往左移一點")
        let b = advice(.headroom, "鏡頭壓低一點")
        _ = stabilizer.update(candidate: a, at: 0)
        XCTAssertEqual(stabilizer.update(candidate: b, at: 0.2), a)
        // b 已連續 0.8s ≥ 0.7s，但 a 只顯示了 1.0s < 1.5s → 不切。
        XCTAssertEqual(stabilizer.update(candidate: b, at: 1.0), a)
        // 兩個條件都滿足 → 切換。
        XCTAssertEqual(stabilizer.update(candidate: b, at: 1.6), b)
    }

    // MARK: - 0.7s 持續才切換

    func testNewAdviceMustPersistBeforeSwitch() {
        let stabilizer = AdviceStabilizer(minDisplaySeconds: 1.5, switchAfterSeconds: 0.7)
        let a = advice(.thirds, "往左移一點")
        let b = advice(.headroom, "鏡頭壓低一點")
        _ = stabilizer.update(candidate: a, at: 0)
        // a 已顯示 2s（> 1.5s），但 b 才剛出現 → 不切。
        XCTAssertEqual(stabilizer.update(candidate: b, at: 2.0), a)
        // b 連續 0.5s < 0.7s → 不切。
        XCTAssertEqual(stabilizer.update(candidate: b, at: 2.5), a)
        // b 連續 0.8s ≥ 0.7s → 切換。
        XCTAssertEqual(stabilizer.update(candidate: b, at: 2.8), b)
    }

    func testRevertingCandidateResetsPendingTimer() {
        let stabilizer = AdviceStabilizer(minDisplaySeconds: 1.5, switchAfterSeconds: 0.7)
        let a = advice(.thirds, "往左移一點")
        let b = advice(.headroom, "鏡頭壓低一點")
        _ = stabilizer.update(candidate: a, at: 0)
        _ = stabilizer.update(candidate: b, at: 2.0)
        // 候選回到 a → pending 歸零。
        XCTAssertEqual(stabilizer.update(candidate: a, at: 2.3), a)
        // b 重新開始累積。
        XCTAssertEqual(stabilizer.update(candidate: b, at: 2.4), a)
        XCTAssertEqual(stabilizer.update(candidate: b, at: 3.0), a) // 只累積 0.6s
        XCTAssertEqual(stabilizer.update(candidate: b, at: 3.2), b) // 0.8s → 切換
    }

    func testNilGapResetsPendingTimer() {
        let stabilizer = AdviceStabilizer(minDisplaySeconds: 1.5, switchAfterSeconds: 0.7)
        let a = advice(.thirds, "往左移一點")
        let b = advice(.headroom, "鏡頭壓低一點")
        _ = stabilizer.update(candidate: a, at: 0)
        XCTAssertEqual(stabilizer.update(candidate: b, at: 0.2), a)
        // 候選中斷（nil 帧）→ pending 必須歸零。
        XCTAssertEqual(stabilizer.update(candidate: nil, at: 0.5), a)
        // b 回來：從 1.6 重新累積，不得沿用 0.2 的舊計時直接切換。
        XCTAssertEqual(stabilizer.update(candidate: b, at: 1.6), a)
        XCTAssertEqual(stabilizer.update(candidate: b, at: 2.2), a) // 只累積 0.6s
        XCTAssertEqual(stabilizer.update(candidate: b, at: 2.4), b) // 0.8s ≥ 0.7s → 切換
    }

    // MARK: - 硬錯誤插隊

    func testHardErrorSwitchesImmediately() {
        let stabilizer = AdviceStabilizer(minDisplaySeconds: 1.5, switchAfterSeconds: 0.7)
        let a = advice(.thirds, "往左移一點")
        let hard = advice(.jointCut, "寧切大腿別切膝", priority: 110)
        _ = stabilizer.update(candidate: a, at: 0)
        // a 才顯示 0.1s，硬錯誤仍立即插隊。
        XCTAssertEqual(stabilizer.update(candidate: hard, at: 0.1), hard)
    }

    func testHardErrorThenNormalFlowResumes() {
        let stabilizer = AdviceStabilizer(minDisplaySeconds: 1.5, switchAfterSeconds: 0.7)
        let a = advice(.thirds, "往左移一點")
        let hard = advice(.horizon, "拉直水平", priority: 100)
        _ = stabilizer.update(candidate: hard, at: 0)
        // 硬錯誤成為目前建議後，一般建議仍要走最短顯示 + 遲滯。
        XCTAssertEqual(stabilizer.update(candidate: a, at: 0.5), hard)
        XCTAssertEqual(stabilizer.update(candidate: a, at: 1.0), hard)
        XCTAssertEqual(stabilizer.update(candidate: a, at: 1.6), a) // 1.6 ≥ 1.5 且 a 已連續 ≥ 0.7
    }

    // MARK: - EMA

    func testEMAFirstValuePassesThrough() {
        var smoother = ScoreSmoother(alpha: 0.3)
        XCTAssertEqual(smoother.update(80), 80, accuracy: 1e-9)
    }

    func testEMASmoothing() {
        var smoother = ScoreSmoother(alpha: 0.5)
        XCTAssertEqual(smoother.update(100), 100, accuracy: 1e-9)
        XCTAssertEqual(smoother.update(0), 50, accuracy: 1e-9)
        XCTAssertEqual(smoother.update(0), 25, accuracy: 1e-9)
        XCTAssertEqual(smoother.update(75), 50, accuracy: 1e-9)
    }

    func testEMAResetForgetsHistory() {
        var smoother = ScoreSmoother(alpha: 0.5)
        _ = smoother.update(100)
        smoother.reset()
        XCTAssertNil(smoother.currentValue)
        XCTAssertEqual(smoother.update(40), 40, accuracy: 1e-9)
    }
}
