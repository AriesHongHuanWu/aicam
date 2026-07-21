//  AspectFillMapperTests.swift
//  AICamCoreTests — aspect-fill 映射 + Vision 座標翻轉測試（Linux swift test 必須可跑）。
//
//  所有期望值皆手算，過程寫在各測試注釋。

import XCTest
import AICamCore

final class AspectFillMapperTests: XCTestCase {

    // MARK: - 直立機：9:16 buffer 在 9:19.5 螢幕 → 左右被裁

    func testPortraitBufferInTallerScreenCropsLeftRight() {
        // content 900×1600、container 900×1950：
        // scale = max(900/900, 1950/1600) = max(1, 1.21875) = 1.21875
        // scaledW = 900 × 1.21875 = 1096.875、scaledH = 1600 × 1.21875 = 1950
        // offsetX = (900 − 1096.875)/2 = −98.4375、offsetY = 0 → 左右各裁 98.4375pt。
        let mapper = AspectFillMapper(
            contentWidth: 900, contentHeight: 1600,
            containerWidth: 900, containerHeight: 1950
        )
        // 中心點 (0.5, 0.5) → (−98.4375 + 548.4375, 975) = (450, 975) = container 中心 ✓。
        let center = mapper.containerPoint(for: NPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(center.x, 450, accuracy: 1e-9)
        XCTAssertEqual(center.y, 975, accuracy: 1e-9)
        // 左上角 (0, 0) → (−98.4375, 0)：x 為負 = 落在被裁區域（契約允許）。
        let topLeft = mapper.containerPoint(for: NPoint(x: 0, y: 0))
        XCTAssertEqual(topLeft.x, -98.4375, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-9)
        // 右下角 (1, 1) → (−98.4375 + 1096.875, 1950) = (998.4375, 1950)：超出 container 寬。
        let bottomRight = mapper.containerPoint(for: NPoint(x: 1, y: 1))
        XCTAssertEqual(bottomRight.x, 998.4375, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.y, 1950, accuracy: 1e-9)
    }

    // MARK: - 反例：16:9 buffer 在更扁的 container → 上下被裁

    func testWideBufferInShorterContainerCropsTopBottom() {
        // content 1600×900、container 1600×750：
        // scale = max(1600/1600, 750/900) = max(1, 0.8333) = 1
        // scaledW = 1600、scaledH = 900、offsetX = 0、offsetY = (750 − 900)/2 = −75
        // → 上下各裁 75pt。
        let mapper = AspectFillMapper(
            contentWidth: 1600, contentHeight: 900,
            containerWidth: 1600, containerHeight: 750
        )
        // (0.5, 0) → (800, −75)：y 為負 = 頂部被裁區域。
        let topMid = mapper.containerPoint(for: NPoint(x: 0.5, y: 0))
        XCTAssertEqual(topMid.x, 800, accuracy: 1e-9)
        XCTAssertEqual(topMid.y, -75, accuracy: 1e-9)
        // (0.5, 1) → (800, 825)：超出 container 高。
        let bottomMid = mapper.containerPoint(for: NPoint(x: 0.5, y: 1))
        XCTAssertEqual(bottomMid.y, 825, accuracy: 1e-9)
        // (0.5, 0.5) → (800, 375) = container 中心 ✓。
        let center = mapper.containerPoint(for: NPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(center.x, 800, accuracy: 1e-9)
        XCTAssertEqual(center.y, 375, accuracy: 1e-9)
    }

    // MARK: - 等比縮小（無裁切）

    func testUniformDownscaleNoCrop() {
        // content 1080×1920、container 540×960（同比）：scale = 0.5、offset = (0, 0)。
        // (0.25, 0.75) → (0.25×540, 0.75×960) = (135, 720)。
        let mapper = AspectFillMapper(
            contentWidth: 1080, contentHeight: 1920,
            containerWidth: 540, containerHeight: 960
        )
        let p = mapper.containerPoint(for: NPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(p.x, 135, accuracy: 1e-9)
        XCTAssertEqual(p.y, 720, accuracy: 1e-9)
    }

    // MARK: - 對偶 round-trip

    func testRoundTripForwardThenInverse() {
        let mapper = AspectFillMapper(
            contentWidth: 900, contentHeight: 1600,
            containerWidth: 900, containerHeight: 1950
        )
        let original = NPoint(x: 0.123, y: 0.789)
        let mapped = mapper.containerPoint(for: original)
        let back = mapper.normalizedPoint(forContainerX: mapped.x, y: mapped.y)
        XCTAssertEqual(back.x, original.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, original.y, accuracy: 1e-9)
    }

    func testInverseHandComputed() {
        // 同直立機 mapper：container 中心 (450, 975) → normalized (0.5, 0.5)。
        let mapper = AspectFillMapper(
            contentWidth: 900, contentHeight: 1600,
            containerWidth: 900, containerHeight: 1950
        )
        let n = mapper.normalizedPoint(forContainerX: 450, y: 975)
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
    }

    func testDegenerateContentReturnsSafeValues() {
        // content 尺寸 0：不可 NaN / 崩潰；正向退化為 offset、反向回 .zero。
        let mapper = AspectFillMapper(
            contentWidth: 0, contentHeight: 0,
            containerWidth: 100, containerHeight: 100
        )
        let p = mapper.containerPoint(for: NPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(p.x.isNaN)
        XCTAssertFalse(p.y.isNaN)
        let n = mapper.normalizedPoint(forContainerX: 50, y: 50)
        XCTAssertEqual(n, NPoint.zero)
    }
}

// MARK: - Vision 座標翻轉

final class VisionCoordinateMappingTests: XCTestCase {

    func testRectFlipHandComputed() {
        // Vision（原點左下）rect (x 0.1, y 0.2, w 0.3, h 0.4)：
        // 頂邊在 Vision y = 0.2 + 0.4 = 0.6 → NormalizedFrame y' = 1 − 0.6 = 0.4
        // → NRect(0.1, 0.4, 0.3, 0.4)。x / w / h 不變。
        let r = VisionCoordinateMapping.toNormalizedFrame(
            visionRect: 0.1, y: 0.2, width: 0.3, height: 0.4
        )
        XCTAssertEqual(r.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(r.y, 0.4, accuracy: 1e-12)
        XCTAssertEqual(r.width, 0.3, accuracy: 1e-12)
        XCTAssertEqual(r.height, 0.4, accuracy: 1e-12)
    }

    func testRectNearImageTopMapsToSmallY() {
        // 臉靠近畫面「頂部」：Vision y = 0.8、h = 0.15（Vision y 向上，大 y = 上方）
        // → y' = 1 − 0.8 − 0.15 = 0.05 → NormalizedFrame 小 y = 頂部 ✓。
        let r = VisionCoordinateMapping.toNormalizedFrame(
            visionRect: 0.4, y: 0.8, width: 0.2, height: 0.15
        )
        XCTAssertEqual(r.y, 0.05, accuracy: 1e-12)
    }

    func testPointFlipHandComputed() {
        // Vision 點 (0.25, 0.75) → (0.25, 1 − 0.75) = (0.25, 0.25)。
        let p = VisionCoordinateMapping.toNormalizedFrame(visionPoint: 0.25, y: 0.75)
        XCTAssertEqual(p.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(p.y, 0.25, accuracy: 1e-12)
    }

    func testPointFlipIsInvolution() {
        // 翻轉是對合：套兩次回原值。
        let once = VisionCoordinateMapping.toNormalizedFrame(visionPoint: 0.31, y: 0.87)
        let twice = VisionCoordinateMapping.toNormalizedFrame(visionPoint: once.x, y: once.y)
        XCTAssertEqual(twice.x, 0.31, accuracy: 1e-12)
        XCTAssertEqual(twice.y, 0.87, accuracy: 1e-12)
    }

    func testRectFlipIsInvolution() {
        let once = VisionCoordinateMapping.toNormalizedFrame(
            visionRect: 0.12, y: 0.34, width: 0.25, height: 0.4
        )
        let twice = VisionCoordinateMapping.toNormalizedFrame(
            visionRect: once.x, y: once.y, width: once.width, height: once.height
        )
        XCTAssertEqual(twice.x, 0.12, accuracy: 1e-12)
        XCTAssertEqual(twice.y, 0.34, accuracy: 1e-12)
        XCTAssertEqual(twice.height, 0.4, accuracy: 1e-12)
    }
}
