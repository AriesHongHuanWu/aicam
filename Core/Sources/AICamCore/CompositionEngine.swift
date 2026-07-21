//  CompositionEngine.swift
//  AICamCore — L1 規則構圖引擎（MASTER-PLAN §4.2、§4.6）。
//
//  流程：
//  1. 推斷 SubjectMode（臉高 > 0.25 → closeUp；subjectBox 高 > 0.72 → fullBody；
//     其餘有臉 → halfBody；無臉有主體 → nonHuman；都無 → none：50 分、無建議）。
//  2. 逐成分呼叫 CompositionRules 純函式取得 (score, advice)；
//     nonHuman 只允許 thirds / horizon / exposure。
//  3. 依 ScoringConfig.weights 加權平均 → 0–100 總分。
//  4. 仲裁 top-1 建議：priority 最高者優先；同 priority 取成分得分最低者（扣最多分的問題）。
//  5. shouldAutoCapture：score ≥ autoCaptureMinScore 且雙眼 open > 0.5 且 smile > 0.4，
//     且無硬錯誤建議（priority ≥ 100）— 安全網：不自動拍下明顯犯錯的構圖。

import Foundation

public final class RuleCompositionEngine: CompositionScoring, Sendable {

    public init() {}

    // MARK: - 主流程

    public func evaluate(_ facts: FrameFacts, config: ScoringConfig) -> CompositionResult {
        let mode = Self.inferSubjectMode(facts)
        guard mode != .none else {
            // 無臉也無主體：中性 50 分，不給建議、不抓拍。
            return CompositionResult(score: 50, subjectMode: .none)
        }

        let outcomes = Self.evaluateComponents(mode: mode, facts: facts, config: config)

        var components: [AdviceCategory: Double] = [:]
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (category, outcome) in outcomes {
            components[category] = outcome.score
            let weight = config.weights[category] ?? 0
            guard weight > 0 else { continue }
            weightedSum += weight * outcome.score
            weightTotal += weight
        }

        let score: Int
        if weightTotal > 0 {
            score = min(100, max(0, Int((100 * weightedSum / weightTotal).rounded())))
        } else {
            score = 50
        }

        let advice = Self.arbitrate(outcomes)
        let auto = Self.autoCaptureDecision(score: score, advice: advice, facts: facts, config: config)
        return CompositionResult(
            score: score,
            subjectMode: mode,
            components: components,
            advice: advice,
            shouldAutoCapture: auto
        )
    }

    // MARK: - SubjectMode 推斷

    /// 幾何依據：正規化臉高 ≈ 臉在畫面中的占比。
    /// 特寫時臉占比大（> 0.25）；全身照主體框幾乎貫穿畫面（> 0.72）；
    /// 有臉但都不符合 → 半身。無臉有主體框（saliency）→ nonHuman。
    public static func inferSubjectMode(_ facts: FrameFacts) -> SubjectMode {
        if let face = CompositionRules.primaryFace(facts) {
            if face.box.height > 0.25 { return .closeUp }
            if let subject = facts.subjectBox, subject.height > 0.72 { return .fullBody }
            return .halfBody
        }
        if facts.subjectBox != nil { return .nonHuman }
        return .none
    }

    // MARK: - 成分評估

    private static func evaluateComponents(
        mode: SubjectMode, facts: FrameFacts, config: ScoringConfig
    ) -> [(AdviceCategory, RuleOutcome)] {
        var list: [(AdviceCategory, RuleOutcome)] = []
        func add(_ category: AdviceCategory, _ outcome: RuleOutcome?) {
            if let outcome = outcome {
                list.append((category, outcome))
            }
        }
        // 所有模式共用（nonHuman 只允許這三項，MASTER-PLAN §4.2）。
        add(.thirds, CompositionRules.thirds(facts, config))
        add(.horizon, CompositionRules.horizon(facts, config))
        add(.exposure, CompositionRules.exposure(facts, config))
        guard mode != .nonHuman else { return list }
        // 人像模式限定。
        add(.headroom, CompositionRules.headroom(facts, config))
        add(.subjectSize, CompositionRules.subjectSize(facts, config, mode: mode))
        add(.jointCut, CompositionRules.jointCut(facts, config))
        add(.gazeSpace, CompositionRules.gazeSpace(facts, config))
        add(.light, CompositionRules.light(facts, config))
        return list
    }

    // MARK: - 仲裁

    /// top-1 建議：priority 高者優先；同 priority 取成分得分最低者。
    private static func arbitrate(_ outcomes: [(AdviceCategory, RuleOutcome)]) -> CoachAdvice? {
        var best: (advice: CoachAdvice, score: Double)?
        for (_, outcome) in outcomes {
            guard let advice = outcome.advice else { continue }
            if let current = best {
                let better = advice.priority > current.advice.priority
                    || (advice.priority == current.advice.priority && outcome.score < current.score)
                if better {
                    best = (advice, outcome.score)
                }
            } else {
                best = (advice, outcome.score)
            }
        }
        return best?.advice
    }

    // MARK: - 自動抓拍

    /// score ≥ 門檻、雙眼 open > 0.5、smile > 0.4（缺任一觀測值 = 不抓拍），
    /// 且仲裁結果不是硬錯誤（priority ≥ 100）— 不自動拍下切關節／爆頭頂／嚴重歪斜的帧。
    private static func autoCaptureDecision(
        score: Int, advice: CoachAdvice?, facts: FrameFacts, config: ScoringConfig
    ) -> Bool {
        guard score >= config.autoCaptureMinScore,
              let face = CompositionRules.primaryFace(facts),
              let leftEye = face.leftEyeOpen,
              let rightEye = face.rightEyeOpen,
              let smile = face.smile,
              leftEye > 0.5, rightEye > 0.5, smile > 0.4
        else { return false }
        if let advice = advice, advice.priority >= AdvicePriority.hardError {
            return false
        }
        return true
    }
}

// MARK: - Codable 字典鍵

/// 讓 [AdviceCategory: Double]（ScoringConfig.weights / CompositionResult.components）
/// 編成正常的 JSON 物件 {"thirds": 20, ...} 而不是攤平的無鍵陣列 —
/// 手寫的 ScoringConfig.json（§4.2 可調不改碼）才能正確解碼。
/// SE-0320：String raw value enum 宣告 conformance 後 stdlib 提供預設實作。
/// App 端 iOS 17 ≥ 15.4，永遠生效；Linux CI（swift test）無 availability 檢查。
@available(iOS 15.4, macOS 12.3, tvOS 15.4, watchOS 8.5, *)
extension AdviceCategory: CodingKeyRepresentable {}
