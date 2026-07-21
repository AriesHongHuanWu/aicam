//  Rules.swift
//  AICamCore — L1 規則文法層（MASTER-PLAN §4.2）。
//
//  每條規則 = 純函式：輸入 FrameFacts + ScoringConfig（+ 必要脈絡），
//  輸出 RuleOutcome(score 0…1, advice)；回傳 nil 表示該成分對本帧「不適用」
//  （缺乏判定所需的觀測資料），不適用成分不進 CompositionResult.components。
//
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

/// 單一評分成分的結果。
public struct RuleOutcome: Equatable, Sendable {
    /// 0…1，1 = 完全符合該構圖文法。
    public let score: Double
    /// 該成分建議的修正；不需修正時為 nil。
    public let advice: CoachAdvice?

    public init(score: Double, advice: CoachAdvice? = nil) {
        self.score = score
        self.advice = advice
    }
}

/// 建議優先級（仲裁用；≥ 100 = 硬錯誤，顯示層立即插隊）。
public enum AdvicePriority {
    public static let jointCut = 110
    public static let hardError = 100   // 爆頭頂、嚴重歪斜
    public static let backlight = 90
    public static let sideLight = 60
    public static let horizonSoft = 55
    public static let headroom = 50
    public static let exposure = 45
    public static let subjectSize = 40
    public static let gazeSpace = 30
    public static let thirds = 20
}

public enum CompositionRules {

    // MARK: - 共用

    /// 主要臉 = 面積最大的臉（多人時以最大臉為構圖主體）。
    public static func primaryFace(_ facts: FrameFacts) -> FaceFact? {
        facts.faces.max { $0.box.area < $1.box.area }
    }

    /// 區間計分：v 落在 [lo, hi] 內 = 1；超出後在 falloff 距離內線性降到 0。
    static func intervalScore(_ v: Double, lo: Double, hi: Double, falloff: Double) -> Double {
        if v < lo { return max(0, 1 - (lo - v) / falloff) }
        if v > hi { return max(0, 1 - (v - hi) / falloff) }
        return 1
    }

    // MARK: - 三分線對齊

    /// 三分線對齊。
    /// 幾何依據：三分線位於 x ∈ {1/3, 2/3}、y ∈ {1/3, 2/3}。
    /// 錨點 = 主要臉框中心（無臉時 subjectBox 中心）。每軸取到最近三分線的距離 d，
    /// 以 1/6（畫面正中心到三分線的距離）為滿扣尺度：axisScore = 1 − min(d / (1/6), 1)；
    /// 總分 = 兩軸平均（貼一條線 ≥ 0.5，貼三分點 = 1）。
    /// 建議方向：主體該往 Δ 移 ⇒ 相機往 −Δ 移（相機左移 ⇒ 主體在畫面中右移）。
    public static func thirds(_ facts: FrameFacts, _ config: ScoringConfig) -> RuleOutcome? {
        let anchor: NPoint
        if let face = primaryFace(facts) {
            anchor = face.box.center
        } else if let subject = facts.subjectBox {
            anchor = subject.center
        } else {
            return nil
        }
        let lineA = 1.0 / 3.0
        let lineB = 2.0 / 3.0
        func nearestLine(to v: Double) -> Double {
            abs(v - lineA) <= abs(v - lineB) ? lineA : lineB
        }
        let targetX = nearestLine(to: anchor.x)
        let targetY = nearestLine(to: anchor.y)
        let unit = 1.0 / 6.0
        let scoreX = 1 - min(abs(anchor.x - targetX) / unit, 1)
        let scoreY = 1 - min(abs(anchor.y - targetY) / unit, 1)
        let score = (scoreX + scoreY) / 2

        var advice: CoachAdvice?
        if score < 0.55 {
            // 取偏差較大的軸給單一指令；Δ = 主體該移動的方向（畫面空間）。
            let deltaX = targetX - anchor.x
            let deltaY = targetY - anchor.y
            let entry: SuggestionCatalog.Entry
            if abs(deltaX) >= abs(deltaY) {
                // 主體該右移（Δx > 0）⇒ 相機往左移。
                entry = deltaX > 0 ? SuggestionCatalog.thirdsMoveLeft : SuggestionCatalog.thirdsMoveRight
            } else {
                // 主體該下移（Δy > 0）⇒ 相機取景抬高。
                entry = deltaY > 0 ? SuggestionCatalog.thirdsAimUp : SuggestionCatalog.thirdsAimDown
            }
            advice = entry.advice(priority: AdvicePriority.thirds)
        }
        return RuleOutcome(score: score, advice: advice)
    }

    // MARK: - 頭部空間

    /// 頭部空間（headroom）。
    /// 幾何依據：headroom = 臉框頂到畫面頂的正規化距離 = face.box.minY。
    /// 理想區間 [idealHeadroomMin, idealHeadroomMax]（預設 5–12%）。
    /// minY ≤ 0.005 視為頭頂貼邊／被切 = 硬錯誤（priority 100）。
    /// 過少：score = headroom / idealHeadroomMin（線性 0→1）；
    /// 過多：超出 idealHeadroomMax 後以 0.25 為滿扣尺度線性降到 0。
    public static func headroom(_ facts: FrameFacts, _ config: ScoringConfig) -> RuleOutcome? {
        guard let face = primaryFace(facts) else { return nil }
        let headroom = face.box.minY
        if headroom <= 0.005 {
            return RuleOutcome(
                score: 0,
                advice: SuggestionCatalog.headroomClipped.advice(priority: AdvicePriority.hardError)
            )
        }
        if headroom < config.idealHeadroomMin {
            let score = max(0, min(1, headroom / max(config.idealHeadroomMin, 0.001)))
            var advice: CoachAdvice?
            if score < 0.8 {
                advice = SuggestionCatalog.headroomTooTight.advice(priority: AdvicePriority.headroom)
            }
            return RuleOutcome(score: score, advice: advice)
        }
        if headroom > config.idealHeadroomMax {
            let score = max(0, 1 - (headroom - config.idealHeadroomMax) / 0.25)
            var advice: CoachAdvice?
            if score < 0.8 {
                advice = SuggestionCatalog.headroomTooMuch.advice(priority: AdvicePriority.headroom)
            }
            return RuleOutcome(score: score, advice: advice)
        }
        return RuleOutcome(score: 1)
    }

    // MARK: - 主體占比

    /// 主體占比。
    /// 幾何依據（正規化「高度占比」的理想區間，人像攝影慣例）：
    /// closeUp：臉高 0.25–0.50（臉再大會壓迫）；halfBody：主體框高 0.45–0.70；
    /// fullBody：主體框高 0.72–0.92（貼滿 > 0.92 = 太擠）。
    /// 超出區間在 0.25 falloff 內線性扣分。過小 →「上前兩步」；過大 →「退後兩步」。
    /// halfBody / fullBody 需要 subjectBox；沒有就視為不適用。
    public static func subjectSize(
        _ facts: FrameFacts, _ config: ScoringConfig, mode: SubjectMode
    ) -> RuleOutcome? {
        let measured: Double
        let lo: Double
        let hi: Double
        switch mode {
        case .closeUp:
            guard let face = primaryFace(facts) else { return nil }
            measured = face.box.height
            lo = 0.25
            hi = 0.50
        case .halfBody:
            guard let subject = facts.subjectBox else { return nil }
            measured = subject.height
            lo = 0.45
            hi = 0.70
        case .fullBody:
            guard let subject = facts.subjectBox else { return nil }
            measured = subject.height
            lo = 0.72
            hi = 0.92
        case .nonHuman, .none:
            return nil
        }
        let score = intervalScore(measured, lo: lo, hi: hi, falloff: 0.25)
        var advice: CoachAdvice?
        if score < 0.8 {
            let entry = measured < lo ? SuggestionCatalog.sizeTooSmall : SuggestionCatalog.sizeTooLarge
            advice = entry.advice(priority: AdvicePriority.subjectSize)
        }
        return RuleOutcome(score: score, advice: advice)
    }

    // MARK: - 水平

    /// 水平。
    /// 幾何依據：|roll| ≤ maxGoodRollDeg（1.5°）人眼難以察覺 = 滿分；
    /// 1.5°–badRollDeg（4°）之間線性內插 1 → 0.3（越歪越扣）；
    /// > badRollDeg = 明顯歪斜 = 硬錯誤（priority 100），之後再 6° 內線性降到 0。
    public static func horizon(_ facts: FrameFacts, _ config: ScoringConfig) -> RuleOutcome? {
        let roll = abs(facts.horizonRollDeg)
        if roll <= config.maxGoodRollDeg {
            return RuleOutcome(score: 1)
        }
        if roll <= config.badRollDeg {
            let span = max(config.badRollDeg - config.maxGoodRollDeg, 0.001)
            let t = (roll - config.maxGoodRollDeg) / span
            let score = 1 - 0.7 * t
            var advice: CoachAdvice?
            if score < 0.8 {
                advice = SuggestionCatalog.horizonLevel.advice(priority: AdvicePriority.horizonSoft)
            }
            return RuleOutcome(score: score, advice: advice)
        }
        let score = max(0, 0.3 - 0.3 * (roll - config.badRollDeg) / 6.0)
        return RuleOutcome(
            score: score,
            advice: SuggestionCatalog.horizonLevel.advice(priority: AdvicePriority.hardError)
        )
    }

    // MARK: - 切關節

    /// 切關節偵測。
    /// 幾何依據：人像裁切落在關節上最刺眼 —「寧切大腿不切膝」。
    /// 監看膝／踝／腕（信心 ≥ 0.3）；關節點距任一畫面邊緣 < jointCutEdgeMargin（預設 3%）
    /// 即判定切關節 = 硬錯誤 priority 110、成分 0 分。
    /// 訊息取最嚴重者：膝 > 踝 > 腕。畫面中沒有任何可信的監看關節時視為不適用。
    public static func jointCut(_ facts: FrameFacts, _ config: ScoringConfig) -> RuleOutcome? {
        let watched: [JointName] = [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .leftWrist, .rightWrist]
        let joints = facts.joints.filter { watched.contains($0.name) && $0.confidence >= 0.3 }
        guard !joints.isEmpty else { return nil }
        let margin = config.jointCutEdgeMargin
        func nearEdge(_ p: NPoint) -> Bool {
            p.x < margin || p.x > 1 - margin || p.y < margin || p.y > 1 - margin
        }
        let cut = joints.filter { nearEdge($0.point) }
        guard !cut.isEmpty else { return RuleOutcome(score: 1) }
        let entry: SuggestionCatalog.Entry
        if cut.contains(where: { $0.name == .leftKnee || $0.name == .rightKnee }) {
            entry = SuggestionCatalog.jointCutKnee
        } else if cut.contains(where: { $0.name == .leftAnkle || $0.name == .rightAnkle }) {
            entry = SuggestionCatalog.jointCutAnkle
        } else {
            entry = SuggestionCatalog.jointCutWrist
        }
        return RuleOutcome(score: 0, advice: entry.advice(priority: AdvicePriority.jointCut))
    }

    // MARK: - 視線空間

    /// 視線空間。
    /// 幾何依據：臉明顯轉向一側（|yaw| > 15°）時，視線前方應留 ≥ 1/3 畫面寬的呼吸空間。
    /// 朝右（yaw > 0，臉朝畫面右緣）看右側留白 = 1 − face.box.maxX；
    /// 朝左看左側留白 = face.box.minX。score = min(space / (1/3), 1)。
    /// 面向鏡頭（|yaw| ≤ 15°）不評扣。不足時建議把鏡頭往視線方向帶（主體反向移出空間）。
    public static func gazeSpace(_ facts: FrameFacts, _ config: ScoringConfig) -> RuleOutcome? {
        guard let face = primaryFace(facts), let yaw = face.yawDeg else { return nil }
        guard abs(yaw) > 15 else { return RuleOutcome(score: 1) }
        let facingRight = yaw > 0
        let space = facingRight ? (1 - face.box.maxX) : face.box.minX
        let score = min(max(space, 0) / (1.0 / 3.0), 1)
        var advice: CoachAdvice?
        if score < 0.6 {
            let entry = facingRight
                ? SuggestionCatalog.gazeNeedRightSpace
                : SuggestionCatalog.gazeNeedLeftSpace
            advice = entry.advice(priority: AdvicePriority.gazeSpace)
        }
        return RuleOutcome(score: score, advice: advice)
    }

    // MARK: - 光位

    /// 光位。
    /// 幾何依據：
    /// 1) 側逆光：臉左右半亮度差 diff > 0.25 ⇒ 單側陰影明顯；
    ///    sideScore = 1 − (diff − 0.25) × 2（diff = 0.75 時 0 分）→「請她轉向亮處」。
    /// 2) 逆光：臉平均亮度低於場景平均（直方圖期望值）0.18 以上 ⇒ 臉被壓暗；
    ///    backScore = 1 − (deficit − 0.18) / 0.3 → priority 90「請她面向光源」。
    /// 成分分 = 兩者取低；建議取較嚴重者（逆光優先）。需要臉左右亮度資料，否則不適用；
    /// 無直方圖時只做側光檢查。
    public static func light(_ facts: FrameFacts, _ config: ScoringConfig) -> RuleOutcome? {
        guard let face = primaryFace(facts),
              let left = face.leftBrightness,
              let right = face.rightBrightness
        else { return nil }

        let diff = abs(left - right)
        let sideScore = diff <= 0.25 ? 1.0 : max(0, 1 - (diff - 0.25) * 2)

        var backScore = 1.0
        var isBacklit = false
        if let histogram = facts.histogram {
            let sceneMean = meanLuma(histogram)
            let faceBrightness = (left + right) / 2
            let deficit = sceneMean - faceBrightness
            if deficit > 0.18 {
                isBacklit = true
                backScore = max(0, 1 - (deficit - 0.18) / 0.3)
            }
        }

        let score = min(sideScore, backScore)
        var advice: CoachAdvice?
        if isBacklit {
            advice = SuggestionCatalog.lightBacklit.advice(priority: AdvicePriority.backlight)
        } else if sideScore < 0.8 {
            advice = SuggestionCatalog.lightTurnToBright.advice(priority: AdvicePriority.sideLight)
        }
        return RuleOutcome(score: score, advice: advice)
    }

    /// 直方圖平均亮度：Σ bins[i] × bin 中點（(i + 0.5) / binCount）。
    /// bins 總和未必嚴格為 1，除以總權重做保護。
    static func meanLuma(_ histogram: LumaHistogram) -> Double {
        let n = histogram.bins.count
        guard n > 0 else { return 0.5 }
        var total = 0.0
        var weightSum = 0.0
        for (i, w) in histogram.bins.enumerated() {
            total += w * ((Double(i) + 0.5) / Double(n))
            weightSum += w
        }
        return weightSum > 0 ? total / weightSum : 0.5
    }

    // MARK: - 曝光剪裁

    /// 曝光剪裁。
    /// 幾何依據：直方圖最亮兩 bin 佔比 > 8% ⇒ 高光剪裁（過曝）；
    /// 最暗兩 bin 佔比 > 12% ⇒ 陰影死黑。超出容忍後以 0.25 為滿扣尺度線性扣分；
    /// 建議依較嚴重的一側。無直方圖時不適用。
    public static func exposure(_ facts: FrameFacts, _ config: ScoringConfig) -> RuleOutcome? {
        guard let histogram = facts.histogram else { return nil }
        let highlightExcess = max(0, histogram.highlightClippedFraction - 0.08)
        let shadowExcess = max(0, histogram.shadowClippedFraction - 0.12)
        let score = max(0, 1 - min(1, (highlightExcess + shadowExcess) / 0.25))
        var advice: CoachAdvice?
        if highlightExcess > 0 || shadowExcess > 0 {
            let entry = highlightExcess >= shadowExcess
                ? SuggestionCatalog.exposureTooBright
                : SuggestionCatalog.exposureTooDark
            advice = entry.advice(priority: AdvicePriority.exposure)
        }
        return RuleOutcome(score: score, advice: advice)
    }
}
