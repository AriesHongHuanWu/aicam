//  EngineTests.swift
//  AICamCoreTests — L1 規則構圖引擎測試（Linux swift test 必須可跑）。

import XCTest
import AICamCore

final class EngineTests: XCTestCase {

    private let engine = RuleCompositionEngine()
    private let config = ScoringConfig.standard

    // MARK: - 測試素材

    /// 中段均勻直方圖：無高光／陰影剪裁，場景平均亮度 ≈ 0.5。
    private func midToneHistogram() -> LumaHistogram {
        var bins = [Double](repeating: 0, count: 64)
        for i in 16..<48 {
            bins[i] = 1.0 / 32.0
        }
        return LumaHistogram(bins: bins)
    }

    /// 完美三分特寫人像：臉中心貼 (2/3, 1/3) 三分點、headroom 8%（理想區間內）、
    /// 臉高 0.5（closeUp 理想上緣）、光線均衡、水平、關節未切、面向鏡頭。
    private func perfectPortraitFacts(
        leftEyeOpen: Double? = 0.9,
        rightEyeOpen: Double? = 0.9,
        smile: Double? = 0.8,
        rollDeg: Double = 0.2
    ) -> FrameFacts {
        let face = FaceFact(
            box: NRect(x: 2.0 / 3.0 - 0.175, y: 0.08, width: 0.35, height: 0.5),
            leftEyeOpen: leftEyeOpen,
            rightEyeOpen: rightEyeOpen,
            smile: smile,
            yawDeg: 0,
            leftBrightness: 0.55,
            rightBrightness: 0.6
        )
        let joints = [
            JointFact(name: .leftWrist, point: NPoint(x: 0.45, y: 0.8), confidence: 0.9),
            JointFact(name: .rightWrist, point: NPoint(x: 0.75, y: 0.8), confidence: 0.9)
        ]
        return FrameFacts(
            faces: [face],
            joints: joints,
            horizonRollDeg: rollDeg,
            histogram: midToneHistogram(),
            timestamp: 1
        )
    }

    // MARK: - SubjectMode 推斷

    func testSubjectModeInference() {
        // 特寫：臉高 > 0.25。
        let closeUp = FrameFacts(faces: [FaceFact(box: NRect(x: 0.3, y: 0.2, width: 0.3, height: 0.4))])
        XCTAssertEqual(RuleCompositionEngine.inferSubjectMode(closeUp), SubjectMode.closeUp)
        // 全身：臉小 + 主體框高 > 0.72。
        let fullBody = FrameFacts(
            faces: [FaceFact(box: NRect(x: 0.45, y: 0.08, width: 0.1, height: 0.12))],
            subjectBox: NRect(x: 0.3, y: 0.08, width: 0.4, height: 0.8)
        )
        XCTAssertEqual(RuleCompositionEngine.inferSubjectMode(fullBody), SubjectMode.fullBody)
        // 半身：有臉、其餘。
        let halfBody = FrameFacts(faces: [FaceFact(box: NRect(x: 0.42, y: 0.1, width: 0.16, height: 0.2))])
        XCTAssertEqual(RuleCompositionEngine.inferSubjectMode(halfBody), SubjectMode.halfBody)
        // 非人：無臉有主體框。
        let nonHuman = FrameFacts(subjectBox: NRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
        XCTAssertEqual(RuleCompositionEngine.inferSubjectMode(nonHuman), SubjectMode.nonHuman)
        // 空帧。
        XCTAssertEqual(RuleCompositionEngine.inferSubjectMode(FrameFacts()), SubjectMode.none)
    }

    // MARK: - 完美構圖

    func testPerfectThirdsPortraitScoresHigh() {
        let result = engine.evaluate(perfectPortraitFacts(), config: config)
        XCTAssertEqual(result.subjectMode, SubjectMode.closeUp)
        XCTAssertGreaterThanOrEqual(result.score, 80)
        XCTAssertNil(result.advice)
    }

    // MARK: - 切關節

    func testKneeCutTriggersHardAdvice() throws {
        let face = FaceFact(box: NRect(x: 0.45, y: 0.06, width: 0.1, height: 0.12))
        let facts = FrameFacts(
            faces: [face],
            joints: [JointFact(name: .leftKnee, point: NPoint(x: 0.5, y: 0.985), confidence: 0.9)],
            subjectBox: NRect(x: 0.3, y: 0.06, width: 0.4, height: 0.8),
            horizonRollDeg: 0
        )
        let result = engine.evaluate(facts, config: config)
        XCTAssertEqual(result.subjectMode, SubjectMode.fullBody)
        let advice = try XCTUnwrap(result.advice)
        XCTAssertEqual(advice.category, AdviceCategory.jointCut)
        XCTAssertGreaterThanOrEqual(advice.priority, 100)
        XCTAssertEqual(result.components[.jointCut], 0)
    }

    // MARK: - 水平硬錯誤

    func testSixDegreeRollIsHardHorizonError() throws {
        let facts = FrameFacts(
            subjectBox: NRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3),
            horizonRollDeg: 6.0,
            histogram: midToneHistogram()
        )
        let result = engine.evaluate(facts, config: config)
        let advice = try XCTUnwrap(result.advice)
        XCTAssertEqual(advice.category, AdviceCategory.horizon)
        XCTAssertGreaterThanOrEqual(advice.priority, 100)
        XCTAssertEqual(advice.message, SuggestionCatalog.horizonLevel.message)
    }

    // MARK: - Headroom 過大

    func testExcessHeadroomTriggersAdvice() throws {
        // 臉頂在 30% 處，遠超理想 5–12% → headroom 建議應勝過 thirds（priority 50 > 20）。
        let face = FaceFact(box: NRect(x: 0.42, y: 0.3, width: 0.16, height: 0.2))
        let facts = FrameFacts(faces: [face], horizonRollDeg: 0)
        let result = engine.evaluate(facts, config: config)
        XCTAssertEqual(result.subjectMode, SubjectMode.halfBody)
        let advice = try XCTUnwrap(result.advice)
        XCTAssertEqual(advice.category, AdviceCategory.headroom)
        XCTAssertEqual(advice.message, SuggestionCatalog.headroomTooMuch.message)
    }

    // MARK: - 主體占比

    func testSmallHalfBodySubjectSuggestsSteppingForward() throws {
        let face = FaceFact(box: NRect(x: 0.45, y: 0.08, width: 0.1, height: 0.12))
        let facts = FrameFacts(
            faces: [face],
            subjectBox: NRect(x: 0.4, y: 0.08, width: 0.2, height: 0.3),
            horizonRollDeg: 0
        )
        let result = engine.evaluate(facts, config: config)
        XCTAssertEqual(result.subjectMode, SubjectMode.halfBody)
        let advice = try XCTUnwrap(result.advice)
        XCTAssertEqual(advice.category, AdviceCategory.subjectSize)
        XCTAssertEqual(advice.message, SuggestionCatalog.sizeTooSmall.message)
    }

    // MARK: - 光位（逆光）

    func testBacklitFaceGetsHighPriorityLightAdvice() throws {
        // 場景以亮 bins 為主（平均 ≈ 0.86、無剪裁 bin），臉平均亮度 0.2 → 逆光 priority 90。
        var bins = [Double](repeating: 0, count: 64)
        for i in 48..<62 {
            bins[i] = 1.0 / 14.0
        }
        let face = FaceFact(
            box: NRect(x: 0.42, y: 0.08, width: 0.16, height: 0.2),
            leftBrightness: 0.2,
            rightBrightness: 0.2
        )
        let facts = FrameFacts(faces: [face], horizonRollDeg: 0, histogram: LumaHistogram(bins: bins))
        let result = engine.evaluate(facts, config: config)
        let advice = try XCTUnwrap(result.advice)
        XCTAssertEqual(advice.category, AdviceCategory.light)
        XCTAssertEqual(advice.priority, 90)
        XCTAssertEqual(advice.message, SuggestionCatalog.lightBacklit.message)
    }

    // MARK: - nonHuman 成分白名單

    func testNonHumanOnlyUsesAllowedComponents() {
        let facts = FrameFacts(
            subjectBox: NRect(x: 0.55, y: 0.25, width: 0.2, height: 0.2),
            horizonRollDeg: 0.5,
            histogram: midToneHistogram()
        )
        let result = engine.evaluate(facts, config: config)
        XCTAssertEqual(result.subjectMode, SubjectMode.nonHuman)
        XCTAssertEqual(Set(result.components.keys), Set([AdviceCategory.thirds, .horizon, .exposure]))
        XCTAssertFalse(result.shouldAutoCapture)
    }

    // MARK: - 空帧

    func testEmptyFrameReturnsNeutral() {
        let result = engine.evaluate(FrameFacts(), config: config)
        XCTAssertEqual(result.subjectMode, SubjectMode.none)
        XCTAssertEqual(result.score, 50)
        XCTAssertNil(result.advice)
        XCTAssertTrue(result.components.isEmpty)
        XCTAssertFalse(result.shouldAutoCapture)
    }

    // MARK: - 自動抓拍條件

    func testAutoCaptureFiresWhenAllConditionsMet() {
        let result = engine.evaluate(perfectPortraitFacts(), config: config)
        XCTAssertGreaterThanOrEqual(result.score, config.autoCaptureMinScore)
        XCTAssertTrue(result.shouldAutoCapture)
    }

    func testAutoCaptureRequiresSmile() {
        let result = engine.evaluate(perfectPortraitFacts(smile: 0.2), config: config)
        XCTAssertFalse(result.shouldAutoCapture)
    }

    func testAutoCaptureRequiresBothEyesOpen() {
        let result = engine.evaluate(perfectPortraitFacts(rightEyeOpen: 0.3), config: config)
        XCTAssertFalse(result.shouldAutoCapture)
    }

    func testAutoCaptureRequiresObservedSignals() {
        // 沒有睜眼／微笑觀測值（nil）= 保守不抓拍。
        let result = engine.evaluate(
            perfectPortraitFacts(leftEyeOpen: nil, rightEyeOpen: nil, smile: nil),
            config: config
        )
        XCTAssertFalse(result.shouldAutoCapture)
    }

    func testAutoCaptureBlockedByHardError() {
        // 歪 6° = 硬錯誤；即使總分仍 ≥ 門檻、睜眼微笑，也不得自動抓拍。
        let result = engine.evaluate(perfectPortraitFacts(rollDeg: 6.0), config: config)
        XCTAssertGreaterThanOrEqual(result.score, config.autoCaptureMinScore)
        XCTAssertFalse(result.shouldAutoCapture)
    }
}
