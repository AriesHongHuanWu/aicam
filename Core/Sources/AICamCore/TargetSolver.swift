//  TargetSolver.swift
//  AICamCore — P2 目標點導引：主體錨點 + 最佳構圖目標點求解（Doka 式）。
//
//  座標契約：全部在 NormalizedFrame 空間（原點左上、x 向右、y 向下、0…1）。
//  App 層必須先經 VisionCoordinateMapping 把 Vision 座標轉入本空間再組 FrameFacts。
//
//  ── 方向語意（本檔最重要的注釋，錯這裡整個功能反向）──
//  cameraMoveHint = 「相機該移動的方向」單位向量 = normalize(anchor − target)。
//  推導：主體在畫面中須往 Δ = target − anchor 移動；相機平移／擺動會讓主體在
//  畫面中往「反方向」移（相機往左 ⇒ 主體在畫面中往右）⇒ 相機移動方向 = −Δ =
//  anchor − target。TargetSolverTests 以測試鎖死此語意
//  （testCameraMoveHintPointsOppositeToSubjectMotion）。
//
//  v0.5.0 群組合照（A3）：≥2 臉且 App 層已組出整群 union subjectBox 時，
//  錨點 = 整群中心（aim 標記語意 = 把「整群」帶到最佳構圖位，不再追最大臉）、
//  headroom 以「最高的臉框頂」（所有臉 minY 最小值）為準。
//  單人路徑 bit-不變（既有 TargetSolverTests 全數原樣通過鎖定）。
//
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

// MARK: - 契約型別

/// 對齊鎖定狀態。TargetSolver 一律回 .searching；
/// aligning / locked 的判定屬於 GuidanceTracker（含遲滯與 dwell）。
public enum LockState: String, Codable, Sendable {
    case searching, aligning, locked
}

/// 一帧的目標點導引輸出（取景器上：anchor = 主體目前錨點、target = 最佳構圖目標環）。
public struct TargetGuidance: Equatable, Sendable {
    /// 主體目前錨點（NormalizedFrame）；無主體時 nil。
    public var anchor: NPoint?
    /// 最佳構圖目標點；無法求解時 nil。
    public var target: NPoint?
    /// 相機該移動方向的單位向量 = normalize(anchor − target)；已重合或無解時 nil。
    public var cameraMoveHint: NPoint?
    /// |anchor − target| 歐氏距離（normalized 空間）；無解時 nil。
    public var normalizedDistance: Double?
    public var lockState: LockState

    public init(
        anchor: NPoint? = nil,
        target: NPoint? = nil,
        cameraMoveHint: NPoint? = nil,
        normalizedDistance: Double? = nil,
        lockState: LockState = .searching
    ) {
        self.anchor = anchor
        self.target = target
        self.cameraMoveHint = cameraMoveHint
        self.normalizedDistance = normalizedDistance
        self.lockState = lockState
    }
}

// MARK: - 求解器

public enum TargetSolver {

    /// target 允許的安全範圍（clamp 邊界，避免目標環貼畫面邊）。
    public static let safeAreaMin = 0.08
    public static let safeAreaMax = 0.92

    /// 視線空間覆寫的 |yaw| 門檻（度）。
    static let gazeYawThresholdDeg = 12.0
    /// 對稱置中允許的 anchor.x 距畫面中心門檻。
    static let symmetryCenterTolerance = 0.06

    /// 契約版：使用 ScoringConfig.standard 的 headroom 區間。
    /// 回傳的 lockState 一律 .searching — 鎖定判斷交給 GuidanceTracker。
    public static func solve(facts: FrameFacts, result: CompositionResult) -> TargetGuidance {
        solve(facts: facts, result: result, config: .standard)
    }

    /// 完整版：headroom 理想區間取自 config（idealHeadroomMin/Max 中點）。
    public static func solve(
        facts: FrameFacts, result: CompositionResult, config: ScoringConfig
    ) -> TargetGuidance {
        // 無主體模式：anchor / target 全 nil。
        guard result.subjectMode != .none else {
            return TargetGuidance(lockState: .searching)
        }

        let face = CompositionRules.primaryFace(facts)

        // 錨點：
        // - v0.5.0 群組（≥2 臉且 App 層已組出整群 union subjectBox）→ 整群中心：
        //   導引／aim 標記語意 = 把「整群」帶到最佳構圖位（App 層契約：≥2 臉時
        //   subjectBox = 所有臉框 union 外擴 15%）。無 union（上游未組）時退回
        //   最大臉中心 — 舊多人行為，testLargestFaceWins 鎖定。
        // - 單臉 → 最大臉框中心（與 L1 primaryFace 同源；路徑 bit-不變）。
        // - 無臉有 subjectBox → 其中心；都無 → searching。
        let anchor: NPoint
        if facts.faces.count >= 2, let subject = facts.subjectBox {
            anchor = subject.center
        } else if let face = face {
            anchor = face.box.center
        } else if let subject = facts.subjectBox {
            anchor = subject.center
        } else {
            return TargetGuidance(lockState: .searching)
        }

        let rawTarget: NPoint
        switch result.subjectMode {
        case .none:
            // 已被前方 guard 排除；為 switch 完整性保留。
            return TargetGuidance(lockState: .searching)
        case .nonHuman:
            rawTarget = nearestPowerPoint(to: anchor)
        case .closeUp, .halfBody, .fullBody:
            guard let face = face else {
                // 防禦：人像模式但本帧觀測不到臉（輸入不一致）→ 給錨點、不給目標。
                return TargetGuidance(anchor: anchor, lockState: .searching)
            }
            let x = portraitTargetX(anchor: anchor, face: face, sceneTags: facts.sceneTags)
            // v0.5.0 群組：headroom 以「最高的臉框頂」（所有臉 minY 最小值）為準 —
            // 只顧最大臉會把整群往上帶到爆掉最高那顆頭。單人 = face.box.minY
            //（同一條算式、同一個值 → 路徑 bit-不變）。
            let faceTopY = facts.faces.count >= 2
                ? (facts.faces.map { $0.box.minY }.min() ?? face.box.minY)
                : face.box.minY
            let y: Double
            if result.subjectMode == .fullBody, let subject = facts.subjectBox {
                y = fullBodyTargetY(
                    anchor: anchor, faceTopY: faceTopY, subject: subject, config: config
                )
            } else {
                y = headroomTargetY(anchor: anchor, faceTopY: faceTopY, config: config)
            }
            rawTarget = NPoint(x: x, y: y)
        }

        let target = clampToSafeArea(rawTarget)
        let dx = anchor.x - target.x
        let dy = anchor.y - target.y
        let distance = (dx * dx + dy * dy).squareRoot()

        // 已重合（或數值上趨近重合）時不給方向提示，避免除以 0 產生 NaN 向量。
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

    // MARK: - 目標點規則（人像 x）

    /// 人像目標 x：
    /// 1. 對稱置中 guard：anchor.x 距中心 < 0.06 且場景標籤含 "symmetry" → 允許置中。
    ///    P2 App 層尚未產出 symmetry sceneTag（L2c 構圖模式分類是 P5 範疇），
    ///    此分支目前恆不成立 — 保留可讀形狀，P5 讓 sceneTags 帶入即生效。
    /// 2. |yaw| > 12° → 強制放在「視線來向」那側的三分線，提供視線空間：
    ///    yaw < 0（臉朝畫面左緣看）→ 主體放右 2/3 線（左側留白）；
    ///    yaw > 0（臉朝畫面右緣看，CoreTypes 契約）→ 主體放左 1/3 線（右側留白）。
    /// 3. 其餘：取距 anchor 較近的三分線（1/3 或 2/3；等距時取 1/3）。
    static func portraitTargetX(anchor: NPoint, face: FaceFact, sceneTags: [String]) -> Double {
        let third = 1.0 / 3.0
        let twoThirds = 2.0 / 3.0

        if abs(anchor.x - 0.5) < symmetryCenterTolerance, sceneTags.contains("symmetry") {
            return 0.5
        }
        if let yaw = face.yawDeg, abs(yaw) > gazeYawThresholdDeg {
            return yaw < 0 ? twoThirds : third
        }
        return abs(anchor.x - third) <= abs(anchor.x - twoThirds) ? third : twoThirds
    }

    // MARK: - 目標點規則（人像 y）

    /// closeUp / halfBody 目標 y：讓「臉頂」落在理想 headroom 區間中點。
    /// faceTopY = 單人時主要臉框頂 face.box.minY；群組時最高的臉框頂
    /// （所有臉 minY 最小值，呼叫端算好傳入）。
    /// idealTop = (idealHeadroomMin + idealHeadroomMax) / 2（standard = 0.085）。
    /// 臉是剛體：臉頂要移 δ = idealTop − faceTopY，錨點（anchor）同移 δ
    /// ⇒ target.y = anchor.y + (idealTop − faceTopY)。
    /// 方向自查：臉太低（topY 大 → headroom 過多）⇒ δ < 0 ⇒ target.y < anchor.y
    /// ⇒ 主體須在畫面中上移 ⇒ hint.y > 0（相機往下）。
    static func headroomTargetY(anchor: NPoint, faceTopY: Double, config: ScoringConfig) -> Double {
        let idealTop = (config.idealHeadroomMin + config.idealHeadroomMax) / 2
        return anchor.y + (idealTop - faceTopY)
    }

    /// fullBody 目標 y：主體框中心 y 對齊 0.5，再夾 headroom —
    /// 位移 δ 先取 0.5 − subject.midY，再 clamp 使移動後臉頂
    /// faceTopY + δ 落在 [idealHeadroomMin, idealHeadroomMax] 內
    /// （headroom 約束優先於置中對齊；faceTopY 語意同 headroomTargetY —
    /// 單人 = 主要臉框頂、群組 = 最高的臉框頂）。target.y = anchor.y + δ。
    static func fullBodyTargetY(
        anchor: NPoint, faceTopY: Double, subject: NRect, config: ScoringConfig
    ) -> Double {
        var delta = 0.5 - subject.midY
        let minDelta = config.idealHeadroomMin - faceTopY
        let maxDelta = config.idealHeadroomMax - faceTopY
        delta = min(max(delta, minDelta), maxDelta)
        return anchor.y + delta
    }

    // MARK: - 目標點規則（nonHuman）

    /// 非人主體：對齊最近的三分交點（4 個 power points 取歐氏距離最近者）。
    static func nearestPowerPoint(to p: NPoint) -> NPoint {
        let lines = [1.0 / 3.0, 2.0 / 3.0]
        var best = NPoint(x: lines[0], y: lines[0])
        var bestDistSq = Double.greatestFiniteMagnitude
        for x in lines {
            for y in lines {
                let dx = p.x - x
                let dy = p.y - y
                let distSq = dx * dx + dy * dy
                if distSq < bestDistSq {
                    bestDistSq = distSq
                    best = NPoint(x: x, y: y)
                }
            }
        }
        return best
    }

    // MARK: - Clamp

    /// target 一律夾進 [safeAreaMin, safeAreaMax]，避免目標環貼邊。
    /// 註：現行規則下人像 target.y = 臉高/2 + 0.085 ∈ [0.085, 0.585]、
    /// x ∈ {1/3, 0.5, 2/3}、power points ∈ {1/3, 2/3}，數學上都不會出界 —
    /// 此函式是規則演進時的安全網，公開供測試直接鎖定行為。
    public static func clampToSafeArea(_ p: NPoint) -> NPoint {
        NPoint(
            x: min(max(p.x, safeAreaMin), safeAreaMax),
            y: min(max(p.y, safeAreaMin), safeAreaMax)
        )
    }
}
