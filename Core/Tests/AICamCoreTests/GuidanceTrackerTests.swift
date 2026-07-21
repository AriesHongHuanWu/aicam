//  GuidanceTrackerTests.swift
//  AICamCoreTests — 鎖定遲滯狀態機 + PointSmoother 測試（Linux swift test 必須可跑）。
//
//  預設參數：lockAt = 0.045、unlockAt = 0.075、lockDwellSeconds = 0.25。
//  進鎖 = distance < lockAt「連續」≥ 0.25s；出鎖 = 鎖定後 distance > unlockAt 立即；
//  lockAt…unlockAt 之間為遲滯帶（鎖定時維持、未鎖定時不進 dwell）。

import XCTest
import AICamCore

final class GuidanceTrackerTests: XCTestCase {

    // MARK: - dwell 進鎖

    func testDwellEntersLockAfterContinuousTime() {
        let tracker = GuidanceTracker()
        // t=0.00 首帧進區（dwell 起算）：0 < 0.25 → aligning。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.00), LockState.aligning)
        // t=0.10：累積 0.10 < 0.25 → 仍 aligning。
        XCTAssertEqual(tracker.update(distance: 0.02, at: 0.10), LockState.aligning)
        // t=0.25：累積 0.25 ≥ 0.25 → locked。
        XCTAssertEqual(tracker.update(distance: 0.04, at: 0.25), LockState.locked)
    }

    func testDwellResetsWhenDistanceLeavesLockZone() {
        let tracker = GuidanceTracker()
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.00), LockState.aligning)
        // t=0.10 出鎖區（0.05 ≥ lockAt=0.045）→ dwell 重置、aligning。
        XCTAssertEqual(tracker.update(distance: 0.05, at: 0.10), LockState.aligning)
        // t=0.30 重新進區 → dwell 從 0.30 重新起算。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.30), LockState.aligning)
        // t=0.54：累積 0.24 < 0.25 → 仍 aligning（未因先前累積提早鎖）。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.54), LockState.aligning)
        // t=0.56：累積 0.26 ≥ 0.25 → locked。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.56), LockState.locked)
    }

    // MARK: - 遲滯出鎖

    func testHysteresisKeepsLockBetweenThresholds() {
        let tracker = GuidanceTracker()
        _ = tracker.update(distance: 0.03, at: 0.00)
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.25), LockState.locked)
        // 鎖定後 0.06 ∈ (lockAt, unlockAt] → 遲滯帶內維持 locked（防閃爍）。
        XCTAssertEqual(tracker.update(distance: 0.06, at: 0.30), LockState.locked)
        XCTAssertEqual(tracker.update(distance: 0.075, at: 0.35), LockState.locked)
        // 0.076 > unlockAt=0.075 → 立即回 aligning。
        XCTAssertEqual(tracker.update(distance: 0.076, at: 0.40), LockState.aligning)
        // 出鎖後要重新累積 dwell 才能再鎖（0.75 − 0.45 = 0.30 ≥ 0.25，
        // 刻意留 margin 避開浮點誤差如 0.70 − 0.45 = 0.2499…97）。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.45), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.75), LockState.locked)
    }

    // MARK: - nil 重置

    func testNilDistanceResetsToSearching() {
        let tracker = GuidanceTracker()
        _ = tracker.update(distance: 0.03, at: 0.00)
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.25), LockState.locked)
        // 主體消失 → searching。
        XCTAssertEqual(tracker.update(distance: nil, at: 0.30), LockState.searching)
        // 重新出現：dwell 已重置 → aligning，需重新累積 0.25s
        // （0.61 − 0.35 = 0.26，留 margin 避開浮點邊界）。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.35), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.59), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.61), LockState.locked)
    }

    func testNilMidDwellResetsDwell() {
        let tracker = GuidanceTracker()
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.00), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: nil, at: 0.10), LockState.searching)
        // t=0.20 重新進區 → 從 0.20 起算，t=0.44 累積 0.24 未滿；
        // t=0.46 累積 0.26 ≥ 0.25 → locked（留 margin 避開浮點邊界）。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.20), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.44), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.46), LockState.locked)
    }

    // MARK: - 自訂參數 + reset

    func testCustomParameters() {
        let tracker = GuidanceTracker(lockAt: 0.1, unlockAt: 0.2, lockDwellSeconds: 1.0)
        XCTAssertEqual(tracker.update(distance: 0.09, at: 0.0), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: 0.09, at: 0.9), LockState.aligning)
        XCTAssertEqual(tracker.update(distance: 0.09, at: 1.0), LockState.locked)
        // 0.15 < unlockAt=0.2 → 維持。
        XCTAssertEqual(tracker.update(distance: 0.15, at: 1.1), LockState.locked)
        XCTAssertEqual(tracker.update(distance: 0.21, at: 1.2), LockState.aligning)
    }

    func testResetReturnsToSearching() {
        let tracker = GuidanceTracker()
        _ = tracker.update(distance: 0.03, at: 0.00)
        _ = tracker.update(distance: 0.03, at: 0.25)
        tracker.reset()
        // reset 後如同新建：首帧進區只是 aligning。
        XCTAssertEqual(tracker.update(distance: 0.03, at: 0.30), LockState.aligning)
    }

    // MARK: - PointSmoother

    func testPointSmootherEMAAndNilReset() throws {
        var smoother = PointSmoother(alpha: 0.5)
        // 第一筆直接採用。
        let first = try XCTUnwrap(smoother.update(NPoint(x: 0, y: 0)))
        XCTAssertEqual(first.x, 0, accuracy: 1e-12)
        XCTAssertEqual(first.y, 0, accuracy: 1e-12)
        // EMA：0.5×1 + 0.5×0 = 0.5（每座標獨立）。
        let second = try XCTUnwrap(smoother.update(NPoint(x: 1, y: 1)))
        XCTAssertEqual(second.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(second.y, 0.5, accuracy: 1e-12)
        // 再一筆：0.5×1 + 0.5×0.5 = 0.75。
        let third = try XCTUnwrap(smoother.update(NPoint(x: 1, y: 1)))
        XCTAssertEqual(third.x, 0.75, accuracy: 1e-12)
        // nil → 重置並回 nil。
        XCTAssertNil(smoother.update(nil))
        // 重置後第一筆直接採用（不得從舊位置 0.75 滑過去）。
        let fresh = try XCTUnwrap(smoother.update(NPoint(x: 1, y: 1)))
        XCTAssertEqual(fresh.x, 1.0, accuracy: 1e-12)
        XCTAssertEqual(fresh.y, 1.0, accuracy: 1e-12)
    }

    func testPointSmootherClampsAlpha() throws {
        // alpha 出界會被夾住：alpha=2 → 1（新值全採用）。
        var smoother = PointSmoother(alpha: 2)
        _ = smoother.update(NPoint(x: 0, y: 0))
        let next = try XCTUnwrap(smoother.update(NPoint(x: 1, y: 1)))
        XCTAssertEqual(next.x, 1.0, accuracy: 1e-12)
    }
}
