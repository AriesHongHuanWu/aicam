//  StickyTargetPlanner.swift
//  AICamCore — 黏性目標規劃器：把目標環「釘住」，根治「追會跑的靶」飄移 bug。
//
//  真機回饋：對齊目標環時 TargetSolver 的 target 每帧跟著 anchor 重算 —
//  用戶朝環移動 → anchor 變 → target 被重算跑掉 → 永遠追不上（追會跑的靶）。
//  修法：target 一經「承諾」即凍結；對齊期間絕不因 anchor 移動而重算。
//
//  狀態機規則（與 StickyTargetPlannerTests 一一對應）：
//  (1) 承諾：尚無承諾目標時，主體連續存在 ≥ commitStableSeconds 且當帧
//      solved.target 非 nil → 承諾（copy）該目標，之後凍結不動。
//      穩定期間輸出只帶 anchor、不帶 target（不給用戶一個還會飄的環）。
//  (2) 凍結輸出：target = 承諾值（每帧 bit-相同）；anchor / cameraMoveHint /
//      normalizedDistance 用「當帧 anchor 對承諾目標」重算
//      （cameraMoveHint = normalize(anchor − target)，與 TargetSolver 同語意）；
//      lockState 一律回 .searching — 鎖定判定屬外部 GuidanceTracker。
//  (3) 撤銷（重新求解）只在四種情況：
//      a. result.subjectMode 與承諾時不同 — 僅在主體在場時檢查：主體消失帧
//         subjectMode 會變 .none，必須走 b 的 grace 邏輯而非本條（順序敏感！）；
//      b. 主體消失連續 > subjectLossGraceSeconds（短暫丟失 ≤ grace 保留目標）；
//      c. 外部 reset()（切鏡/翻轉/切模式由呼叫端觸發）；
//      d. 用戶顯然改變構圖意圖：anchor 越過承諾目標所在三分線到另一側、
//         超出 sideHysteresis 帶、且持續 ≥ sideDwellSeconds。
//  (4) 撤銷後穩定時鐘重啟（presentSince = 撤銷當下）：重新承諾仍須滿足 (1)
//      — 防 subjectMode 在判定邊界抖動時目標環逐帧亂跳。
//
//  「另一側」定義（承諾目標 x = T）：
//    T < 0.5（主體在左三分線）→ 越線 = anchor.x > T + sideHysteresis；
//    T > 0.5（主體在右三分線）→ 越線 = anchor.x < T − sideHysteresis；
//    T = 0.5（置中構圖）      → 越線 = |anchor.x − 0.5| > sideHysteresis。
//  帶寬 0.08 < 三分線到中線距離 1/6：在 T 與中線之間撤銷重解時，最近三分線
//  仍是同一條 → 重新承諾得到同一目標，目標環不會亂跳（自然遲滯）。
//
//  已知限制（規格缺口，A2/A3 注意）：規則 3d 只看 x，y 方向沒有撤銷路徑。
//  nonHuman 承諾目標（TargetSolver 的 power-point，y ∈ {1/3, 2/3}）在用戶大幅
//  垂直重構圖（例：anchor.y 0.3 → 0.7、x 不變）時，只要主體不消失、subjectMode
//  不變，目標的 y 永遠凍在舊排 — 需靠主體短暫離帧（3b）或 subjectMode 變化（3a）
//  才會重解。人像模式受 closeUp/halfBody/fullBody 切換保護，nonHuman 沒有等效
//  保護。下一輪契約演進擬加 y 向對稱規則：target.y < 0.5 時 anchor.y >
//  target.y + sideHysteresis（反之亦然）持續 ≥ sideDwellSeconds 即撤銷
//  （帶寬 0.08 < 1/6 同樣保證重解落回同一交點的自然遲滯）。
//
//  時間一律由呼叫端注入（對齊 FrameFacts.timestamp 的單調秒數），絕不讀 Date()。
//  「連續存在」由呼叫端逐帧 update 定義：主體消失的帧必須以 solved.anchor == nil 餵入。
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

public final class StickyTargetPlanner {

    private let sideHysteresis: Double
    private let sideDwellSeconds: Double
    private let subjectLossGraceSeconds: Double
    private let commitStableSeconds: Double

    /// 承諾目標（凍結中）；nil = 未承諾。
    private var committedTarget: NPoint?
    /// 承諾當下的 subjectMode（規則 3a 比對用）。
    private var committedSubjectMode: SubjectMode?
    /// 主體本輪「連續存在」的起始時間；主體消失或撤銷時重啟。
    private var presentSince: Double?
    /// 承諾期間主體消失的起始時間（grace 計時）。
    private var lostSince: Double?
    /// anchor 越線（出遲滯帶）的起始時間（dwell 計時）。
    private var sideOutsideSince: Double?

    public init(
        sideHysteresis: Double = 0.08,
        sideDwellSeconds: Double = 1.0,
        subjectLossGraceSeconds: Double = 0.6,
        commitStableSeconds: Double = 0.3
    ) {
        self.sideHysteresis = sideHysteresis
        self.sideDwellSeconds = sideDwellSeconds
        self.subjectLossGraceSeconds = subjectLossGraceSeconds
        self.commitStableSeconds = commitStableSeconds
    }

    /// 餵入本帧事實 + 引擎結果 + TargetSolver 原始解，回傳「釘住」後的導引。
    /// 呼叫端（CoachSession）應把 One-Euro 平滑後的錨點放進 solved.anchor 再餵入；
    /// solved 內的 cameraMoveHint / normalizedDistance 本類不讀（凍結期間自行重算）。
    public func update(
        facts: FrameFacts,
        result: CompositionResult,
        solved: TargetGuidance,
        at time: Double
    ) -> TargetGuidance {
        // facts 目前僅為契約保留（規則演進時可看 sceneTags 等），本版邏輯不依賴。
        _ = facts

        // ── 主體不在場（順序敏感：先於 subjectMode 檢查，見規則 3a 注釋）──
        guard let anchor = solved.anchor else {
            presentSince = nil
            sideOutsideSince = nil
            guard let target = committedTarget else {
                return TargetGuidance(lockState: .searching)
            }
            let lostStart = lostSince ?? time
            lostSince = lostStart
            if time - lostStart > subjectLossGraceSeconds {
                // (3b) 丟失超過 grace → 撤銷（主體不在場，穩定時鐘歸零）。
                revoke(newPresentSince: nil)
                return TargetGuidance(lockState: .searching)
            }
            // grace 內：目標保留（anchor / hint / distance 本帧無值）。
            return TargetGuidance(target: target, lockState: .searching)
        }

        lostSince = nil
        let presentStart = presentSince ?? time
        presentSince = presentStart

        // ── 已承諾（凍結期）──
        if let target = committedTarget {
            // (3a) subjectMode 改變 → 立即撤銷，穩定時鐘重啟。
            if result.subjectMode != committedSubjectMode {
                revoke(newPresentSince: time)
                return TargetGuidance(anchor: anchor, lockState: .searching)
            }
            // (3d) 越線意圖：出帶起算 dwell，持續 ≥ sideDwellSeconds 才撤銷。
            if isBeyondCommittedSide(anchorX: anchor.x, targetX: target.x) {
                let outsideStart = sideOutsideSince ?? time
                sideOutsideSince = outsideStart
                if time - outsideStart >= sideDwellSeconds {
                    revoke(newPresentSince: time)
                    return TargetGuidance(anchor: anchor, lockState: .searching)
                }
            } else {
                sideOutsideSince = nil
            }
            // (2) 凍結輸出：target 絕不因 anchor 移動而動。
            return frozenGuidance(anchor: anchor, target: target)
        }

        // ── 未承諾：等穩定 ──
        if time - presentStart >= commitStableSeconds, let target = solved.target {
            // (1) 承諾當帧的 solved.target，並立即以凍結語意輸出。
            committedTarget = target
            committedSubjectMode = result.subjectMode
            sideOutsideSince = nil
            return frozenGuidance(anchor: anchor, target: target)
        }
        // 穩定未滿（或本帧 solver 無解）：只回 anchor，不輸出會飄的 target。
        return TargetGuidance(anchor: anchor, lockState: .searching)
    }

    /// 清空全部狀態（切鏡/前後翻轉/切模式時由呼叫端使用）。
    public func reset() {
        committedTarget = nil
        committedSubjectMode = nil
        presentSince = nil
        lostSince = nil
        sideOutsideSince = nil
    }

    // MARK: - 私有

    private func revoke(newPresentSince: Double?) {
        committedTarget = nil
        committedSubjectMode = nil
        lostSince = nil
        sideOutsideSince = nil
        presentSince = newPresentSince
    }

    /// 「另一側 + 出帶」判定（定義見檔頭）。
    private func isBeyondCommittedSide(anchorX: Double, targetX: Double) -> Bool {
        if targetX < 0.5 { return anchorX > targetX + sideHysteresis }
        if targetX > 0.5 { return anchorX < targetX - sideHysteresis }
        return abs(anchorX - 0.5) > sideHysteresis
    }

    /// 凍結輸出：當帧 anchor 對承諾目標重算距離與方向。
    /// cameraMoveHint = normalize(anchor − target)（與 TargetSolver 同語意、同 1e-9 防除零）。
    private func frozenGuidance(anchor: NPoint, target: NPoint) -> TargetGuidance {
        let dx = anchor.x - target.x
        let dy = anchor.y - target.y
        let distance = (dx * dx + dy * dy).squareRoot()
        var hint: NPoint?
        if distance > 1e-9 {
            hint = NPoint(x: dx / distance, y: dy / distance)
        }
        return TargetGuidance(
            anchor: anchor,
            target: target,
            cameraMoveHint: hint,
            normalizedDistance: distance,
            lockState: .searching
        )
    }
}
