//  CatalogTests.swift
//  AICamCoreTests — 語料庫與 ScoringConfig 序列化測試。

import XCTest
import AICamCore

final class CatalogTests: XCTestCase {

    // MARK: - 文案硬規則：非空、≤10 字（MASTER-PLAN §14「中文教練文案超框」對策）

    func testAllMessagesAreNonEmptyAndWithinTenCharacters() {
        XCTAssertFalse(SuggestionCatalog.allMessages.isEmpty)
        for message in SuggestionCatalog.allMessages {
            XCTAssertFalse(message.isEmpty, "語料不得為空字串")
            XCTAssertLessThanOrEqual(message.count, 10, "文案超過 10 字：「\(message)」")
        }
    }

    // MARK: - 類別覆蓋：每個 AdviceCategory 都有語料可用

    func testEveryCategoryHasAtLeastOneEntry() {
        let covered = Set(SuggestionCatalog.allEntries.map { $0.category })
        for category in AdviceCategory.allCases {
            XCTAssertTrue(covered.contains(category), "缺少 \(category.rawValue) 的語料")
        }
    }

    // MARK: - 箭頭皆為單位向量（UI 只需縮放、不需再正規化）

    func testArrowsAreUnitDirections() {
        for entry in SuggestionCatalog.allEntries {
            if let arrow = entry.arrow {
                let length = (arrow.x * arrow.x + arrow.y * arrow.y).squareRoot()
                XCTAssertEqual(length, 1.0, accuracy: 1e-9, "arrow 非單位向量：「\(entry.message)」")
            }
        }
    }

    // MARK: - Entry → CoachAdvice 包裝

    func testEntryAdvicePreservesFields() {
        let entry = SuggestionCatalog.thirdsMoveLeft
        let advice = entry.advice(priority: 20)
        XCTAssertEqual(advice.category, entry.category)
        XCTAssertEqual(advice.message, entry.message)
        XCTAssertEqual(advice.arrow, entry.arrow)
        XCTAssertEqual(advice.priority, 20)
    }

    // MARK: - ScoringConfig JSON round-trip（含 [AdviceCategory: Double] 字典鍵）

    func testScoringConfigJSONRoundTrip() throws {
        let original = ScoringConfig.standard
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScoringConfig.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.weights[.jointCut], 25)
        XCTAssertEqual(decoded.weights[.thirds], 20)
        XCTAssertEqual(decoded.autoCaptureMinScore, 85)
        XCTAssertEqual(decoded.ruleBlendWeight, 1.0, accuracy: 1e-12)
    }
}
