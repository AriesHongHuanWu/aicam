//  StickyTargetPlannerTests.swift
//  AICamCoreTests — 黏性目標規劃器測試（Linux swift test 必須可跑）。
//
//  預設參數：sideHysteresis 0.08、sideDwellSeconds 1.0、
//  subjectLossGraceSeconds 0.6、commitStableSeconds 0.3。
//  全部用腳本化 anchor 軌跡、帧距 0.1s（Tier B 10fps）。
//  浮點慣例（同 GuidanceTrackerTests）：非零起點的時間差有捨入誤差
//  （如 2.3 − 2.0 = 0.2999…98 < 0.3），邊界斷言一律留 margin。

import XCTest
import AICamCore

final class StickyTargetPlannerTests: XCTestCase {

    // MARK: - 腳本工具

    /// 模擬 TargetSolver 輸出：hint = normalize(anchor − target)、distance = |anchor − target|。
    private func solved(anchor: NPoint?, target: NPoint?) -> TargetGuidance {
        guard let anchor = anchor else { return TargetGuidance(lockState: .searching) }
        guard let target = target else {
            return TargetGuidance(anchor: anchor, lockState: .searching)
        }
        let dx = anchor.x - target.x
        let dy = anchor.y - target.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let hint = distance > 1e-9 ? NPoint(x: dx / distance, y: dy / distance) : nil
        return TargetGuidance(
            anchor: anchor,
            target: target,
            cameraMoveHint: hint,
            normalizedDistance: distance,
            lockState: .searching
        )
    }

    @discardableResult
    private func step(
        _ planner: StickyTargetPlanner,
        anchor: NPoint?,
        target: NPoint?,
        mode: SubjectMode,
        at time: Double
    ) -> TargetGuidance {
        planner.update(
            facts: FrameFacts(timestamp: time),
            result: CompositionResult(score: 70, subjectMode: mode),
            solved: solved(anchor: anchor, target: target),
            at: time
        )
    }

    /// 標準開場：t = 0.0/0.1/0.2 穩定期（不得輸出 target），t = 0.3 承諾
    ///（0.3 − 0.0 = 0.3，起點為 0 時浮點精確）。回傳承諾點。
    @discardableResult
    private func commit(
        _ planner: StickyTargetPlanner,
        anchor: NPoint,
        target: NPoint,
        mode: SubjectMode = .halfBody
    ) -> NPoint {
        for i in 0...2 {
            let out = step(planner, anchor: anchor, target: target, mode: mode, at: Double(i) * 0.1)
            XCTAssertNil(out.target, "穩定期（< commitStableSeconds）不得輸出 target")
        }
        let out = step(planner, anchor: anchor, target: target, mode: mode, at: 0.3)
        XCTAssertEqual(out.target, target, "t=0.3（≥ 0.3s 穩定）應承諾當帧 solved.target")
        return target
    }

    // MARK: - a) 承諾後凍結：anchor 移動 10 帧，target 每帧 bit-相同

    func testCommittedTargetIsBitStableWhileAnchorApproaches() {
        let planner = StickyTargetPlanner()
        // 承諾窗：solver 目標每帧都在飄（重現「追會跑的靶」的輸入），穩定期不輸出 target。
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.60, y: 0.50),
                          target: NPoint(x: 0.660, y: 0.42), mode: .halfBody, at: 0.0).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.60, y: 0.50),
                          target: NPoint(x: 0.664, y: 0.41), mode: .halfBody, at: 0.1).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.61, y: 0.49),
                          target: NPoint(x: 0.668, y: 0.405), mode: .halfBody, at: 0.2).target)
        // t=0.3：主體連續存在 0.3s → 承諾「當帧」目標 (2/3, 0.40)。
        let committed = NPoint(x: 2.0 / 3.0, y: 0.40)
        let atCommit = step(planner, anchor: NPoint(x: 0.61, y: 0.49),
                            target: committed, mode: .halfBody, at: 0.3)
        XCTAssertEqual(atCommit.target, committed)

        // 10 帧線性逼近承諾點；solver 每帧回傳持續飄移的新解，planner 必須全部無視。
        // 側邊安全檢查：target x = 2/3 > 0.5 → 越線帶 = anchor.x < 2/3−0.08 = 0.5867；
        // anchor.x 路徑 0.61 → 2/3 全程 ≥ 0.61 > 0.5867，絕不觸發撤銷。
        let startAnchor = NPoint(x: 0.61, y: 0.49)
        for i in 1...10 {
            let f = Double(i) / 10.0
            let anchor = NPoint(
                x: startAnchor.x + (committed.x - startAnchor.x) * f,
                y: startAnchor.y + (committed.y - startAnchor.y) * f
            )
            let drifting = NPoint(x: committed.x + 0.01 * Double(i),
                                  y: committed.y - 0.01 * Double(i))
            let out = step(planner, anchor: anchor, target: drifting,
                           mode: .halfBody, at: 0.3 + 0.1 * Double(i))
            XCTAssertEqual(out.target, committed,
                           "第 \(i) 帧 target 必須 bit-相同（絕不因 anchor 移動重算）")
        }
    }

    func testFrozenGuidanceRecomputesDistanceAndHintFromCurrentAnchor() throws {
        let planner = StickyTargetPlanner()
        let target = commit(planner, anchor: NPoint(x: 0.61, y: 0.49),
                            target: NPoint(x: 2.0 / 3.0, y: 0.40))
        // 半途 anchor = (0.6383333, 0.445)：
        //   dx = 0.6383333 − 0.6666667 = −0.0283333、dy = 0.445 − 0.40 = 0.045
        //   distance = √(0.0283333² + 0.045²) = √(0.00080278 + 0.002025)
        //            = √0.00282778 = 0.0531768
        //   hint = (−0.0283333, 0.045)/0.0531768 = (−0.53282, +0.84624)
        //  （= normalize(anchor − target)，與 TargetSolver 同語意：相機該移動的方向）。
        let out = step(planner, anchor: NPoint(x: 0.6383333, y: 0.445),
                       target: NPoint(x: 0.70, y: 0.38), mode: .halfBody, at: 0.4)
        XCTAssertEqual(out.target, target)
        XCTAssertEqual(try XCTUnwrap(out.normalizedDistance), 0.0531768, accuracy: 1e-4)
        let hint = try XCTUnwrap(out.cameraMoveHint)
        XCTAssertEqual(hint.x, -0.53282, accuracy: 1e-3)
        XCTAssertEqual(hint.y, 0.84624, accuracy: 1e-3)
        // anchor 與承諾點重合 → distance ≈ 0、hint nil（不得除以 0 產生 NaN）。
        let coincident = step(planner, anchor: NPoint(x: 2.0 / 3.0, y: 0.40),
                              target: NPoint(x: 0.71, y: 0.37), mode: .halfBody, at: 0.5)
        XCTAssertEqual(coincident.target, target)
        XCTAssertEqual(try XCTUnwrap(coincident.normalizedDistance), 0, accuracy: 1e-12)
        XCTAssertNil(coincident.cameraMoveHint)
    }

    // MARK: - b) 短暫越線（< dwell）不動

    func testBriefSideCrossingKeepsTarget() {
        let planner = StickyTargetPlanner()
        let target = commit(planner, anchor: NPoint(x: 0.30, y: 0.45),
                            target: NPoint(x: 1.0 / 3.0, y: 0.40))
        // 越線帶：target x = 1/3 < 0.5 → anchor.x > 1/3 + 0.08 = 0.41333 才算越線。
        // t = 0.4…0.8 anchor.x = 0.55 越線，共 0.4s < dwell 1.0s → target 不動。
        for i in 4...8 {
            let out = step(planner, anchor: NPoint(x: 0.55, y: 0.45),
                           target: NPoint(x: 2.0 / 3.0, y: 0.45), mode: .halfBody,
                           at: Double(i) * 0.1)
            XCTAssertEqual(out.target, target, "短暫越線（< dwell）期間 target 不得動")
        }
        // t=0.9 回到帶內（0.35 < 0.41333）→ 越線計時重置。
        XCTAssertEqual(step(planner, anchor: NPoint(x: 0.35, y: 0.44),
                            target: NPoint(x: 1.0 / 3.0, y: 0.40), mode: .halfBody,
                            at: 0.9).target, target)
        // 再走 1.4s（t = 1.0…2.3）帶內：若剛才的計時未重置，早該在 ~1.4s 撤銷；
        // target 必須全程不動。
        for i in 10...23 {
            let out = step(planner, anchor: NPoint(x: 0.35, y: 0.44),
                           target: NPoint(x: 1.0 / 3.0, y: 0.40), mode: .halfBody,
                           at: Double(i) * 0.1)
            XCTAssertEqual(out.target, target)
        }
    }

    // MARK: - c) 持續越線 ≥ dwell → 撤銷 + 重新承諾新目標

    func testSustainedSideCrossingResolvesAndRecommits() {
        let planner = StickyTargetPlanner()
        let oldTarget = commit(planner, anchor: NPoint(x: 0.30, y: 0.45),
                               target: NPoint(x: 1.0 / 3.0, y: 0.40))
        // t = 0.4…0.9 帶內穩定。
        for i in 4...9 {
            XCTAssertEqual(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                                target: oldTarget, mode: .halfBody,
                                at: Double(i) * 0.1).target, oldTarget)
        }
        // t=1.0 起 anchor 持續在另一側（0.60 > 0.41333）；solver 重解出 2/3 線新目標。
        let newTarget = NPoint(x: 2.0 / 3.0, y: 0.45)
        // t = 1.0…1.9：越線 dwell 未滿 — Double(19)*0.1 = 1.9000000000000001（略高於
        // 字面值 1.9），減 Double(10)*0.1（捨入恰為精確 1.0）= 0.9000000000000001 < 1.0
        // → target 凍結不動。
        for i in 10...19 {
            let out = step(planner, anchor: NPoint(x: 0.60, y: 0.45),
                           target: newTarget, mode: .halfBody, at: Double(i) * 0.1)
            XCTAssertEqual(out.target, oldTarget,
                           "dwell 未滿前 target 不得動（t=\(Double(i) * 0.1)）")
        }
        // t=2.0：越線滿 1.0s（2.0 − 1.0 = 1.0，整數差浮點精確）→ 撤銷，本帧無 target。
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.60, y: 0.45),
                          target: newTarget, mode: .halfBody, at: 2.0).target)
        // 規則 (4)：撤銷後穩定時鐘重啟（presentSince = 2.0）→ 2.1/2.2 未滿 0.3s。
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.60, y: 0.45),
                          target: newTarget, mode: .halfBody, at: 2.1).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.60, y: 0.45),
                          target: newTarget, mode: .halfBody, at: 2.2).target)
        // t=2.35（margin：2.3 − 2.0 = 0.2999…98 是浮點邊界，避開）→ 重新承諾新目標。
        XCTAssertEqual(step(planner, anchor: NPoint(x: 0.60, y: 0.45),
                            target: newTarget, mode: .halfBody, at: 2.35).target, newTarget)
    }

    // MARK: - d) 主體丟失：grace 內保留、超過撤銷

    func testBriefSubjectLossKeepsTarget() {
        let planner = StickyTargetPlanner()
        let target = commit(planner, anchor: NPoint(x: 0.30, y: 0.45),
                            target: NPoint(x: 1.0 / 3.0, y: 0.40))
        // t=0.4 起主體消失。消失帧 subjectMode 變 .none — 必須走 grace 邏輯、
        // 不得誤觸 subjectMode 撤銷（順序敏感，本測試鎖死）。
        // 丟失 0.3s（0.4 → 0.7）< grace 0.6 → target 保留（anchor/distance 此期間無值）。
        for i in 4...7 {
            let out = step(planner, anchor: nil, target: nil, mode: .none, at: Double(i) * 0.1)
            XCTAssertEqual(out.target, target, "grace 內 target 必須保留")
            XCTAssertNil(out.anchor)
            XCTAssertNil(out.normalizedDistance)
        }
        // t=0.8 主體重現 → 承諾仍在、距離恢復重算。
        let back = step(planner, anchor: NPoint(x: 0.32, y: 0.44),
                        target: NPoint(x: 1.0 / 3.0, y: 0.40), mode: .halfBody, at: 0.8)
        XCTAssertEqual(back.target, target)
        XCTAssertNotNil(back.normalizedDistance)
    }

    func testSubjectLossBeyondGraceRevokes() {
        let planner = StickyTargetPlanner()
        let target = commit(planner, anchor: NPoint(x: 0.30, y: 0.45),
                            target: NPoint(x: 1.0 / 3.0, y: 0.40))
        // 丟失計時自 t=0.4；t = 0.4…0.9（經過 ≤ 0.5s ≤ grace）目標保留。
        for i in 4...9 {
            XCTAssertEqual(step(planner, anchor: nil, target: nil, mode: .none,
                                at: Double(i) * 0.1).target, target)
        }
        // t=1.05：經過 0.65 > 0.6 → 撤銷（margin：1.0 − 0.4 浮點上恰等於 0.6，避開）。
        XCTAssertNil(step(planner, anchor: nil, target: nil, mode: .none, at: 1.05).target)
        // t=1.1 主體重現 → 穩定時鐘從 1.1 重新起算；
        // t=1.5（1.5 − 1.1 = 0.3999…≥ 0.3）重新承諾新目標。
        let newTarget = NPoint(x: 2.0 / 3.0, y: 0.42)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.62, y: 0.5),
                          target: newTarget, mode: .halfBody, at: 1.1).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.62, y: 0.5),
                          target: newTarget, mode: .halfBody, at: 1.2).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.62, y: 0.5),
                          target: newTarget, mode: .halfBody, at: 1.3).target)
        XCTAssertEqual(step(planner, anchor: NPoint(x: 0.62, y: 0.5),
                            target: newTarget, mode: .halfBody, at: 1.5).target, newTarget)
    }

    // MARK: - e) subjectMode 改變 → 撤銷 + 重新承諾

    func testSubjectModeChangeRecommits() {
        let planner = StickyTargetPlanner()
        _ = commit(planner, anchor: NPoint(x: 0.30, y: 0.45),
                   target: NPoint(x: 1.0 / 3.0, y: 0.40), mode: .halfBody)
        // t=0.4：退後拍到全身 → subjectMode 變 fullBody → 立即撤銷（穩定時鐘重啟）。
        let newTarget = NPoint(x: 1.0 / 3.0, y: 0.50)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                          target: newTarget, mode: .fullBody, at: 0.4).target)
        // t=0.5/0.6 穩定未滿（0.6 − 0.4 = 0.1999…< 0.3）→ 無 target。
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                          target: newTarget, mode: .fullBody, at: 0.5).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                          target: newTarget, mode: .fullBody, at: 0.6).target)
        // t=0.75（0.35 ≥ 0.3）→ 重新承諾新目標。
        XCTAssertEqual(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                            target: newTarget, mode: .fullBody, at: 0.75).target, newTarget)
    }

    // MARK: - f) reset() 清空

    func testResetClearsCommitmentAndStability() {
        let planner = StickyTargetPlanner()
        _ = commit(planner, anchor: NPoint(x: 0.30, y: 0.45),
                   target: NPoint(x: 1.0 / 3.0, y: 0.40))
        planner.reset()
        // reset 後如同新建：穩定時鐘重新起算，0.3s 內不得輸出 target。
        let target = NPoint(x: 1.0 / 3.0, y: 0.42)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                          target: target, mode: .halfBody, at: 0.4).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                          target: target, mode: .halfBody, at: 0.5).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                          target: target, mode: .halfBody, at: 0.6).target)
        XCTAssertEqual(step(planner, anchor: NPoint(x: 0.30, y: 0.45),
                            target: target, mode: .halfBody, at: 0.75).target, target)
    }

    // MARK: - 承諾前置條件

    func testCommitWaitsForSolvableTarget() {
        let planner = StickyTargetPlanner()
        // 主體穩定存在但 solver 無解（target nil）→ 永不承諾（規則 1 的雙條件）。
        for i in 0...5 {
            XCTAssertNil(step(planner, anchor: NPoint(x: 0.5, y: 0.5),
                              target: nil, mode: .closeUp, at: Double(i) * 0.1).target)
        }
        // t=0.6 出現可解目標，穩定條件早已滿足（0.6 ≥ 0.3）→ 當帧承諾。
        let target = NPoint(x: 1.0 / 3.0, y: 0.30)
        XCTAssertEqual(step(planner, anchor: NPoint(x: 0.5, y: 0.5),
                            target: target, mode: .closeUp, at: 0.6).target, target)
    }

    func testStabilityClockStartsAtAppearance() {
        let planner = StickyTargetPlanner()
        let target = NPoint(x: 2.0 / 3.0, y: 0.40)
        // t=0.0 無主體；t=0.1 主體出現 → 穩定時鐘從 0.1 起算（不是從 0.0）。
        XCTAssertNil(step(planner, anchor: nil, target: nil, mode: .none, at: 0.0).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.6, y: 0.5),
                          target: target, mode: .halfBody, at: 0.1).target)
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.6, y: 0.5),
                          target: target, mode: .halfBody, at: 0.2).target)
        // 0.3 − 0.1 = 0.1999…< 0.3 → 仍未承諾。
        XCTAssertNil(step(planner, anchor: NPoint(x: 0.6, y: 0.5),
                          target: target, mode: .halfBody, at: 0.3).target)
        // 0.45 − 0.1 = 0.35 ≥ 0.3 → 承諾。
        XCTAssertEqual(step(planner, anchor: NPoint(x: 0.6, y: 0.5),
                            target: target, mode: .halfBody, at: 0.45).target, target)
    }
}
