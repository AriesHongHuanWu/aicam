//  AimPointTests.swift
//  AICamCoreTests — v0.4.0 對準點導引數學測試（Linux swift test 必須可跑）。
//
//  這裡鎖死整個新交互的地基語意：
//  (1) 標記重投影 P = C + (anchor − target) 與「正向控制」方向語意；
//  (2) GyroFusedPoint 互補濾波（predict 累加 / correct 收斂 / 交錯序列）；
//  (3) AimGeometry 顯示夾取 [0.06, 0.94]、出界判定 [0, 1]、出界方向向量。
//  全部手算基準；GyroFusedPoint 預設 w = 0.35（誤差每筆 correct ×0.65）。

import XCTest
import AICamCore

final class AimPointTests: XCTestCase {

    // MARK: - AimPointSolver：標記重投影

    func testMarkerFormulaHandComputedWithForwardControlSemantics() {
        // 場景：主體錨點 A = (0.4, 0.5)，凍結目標 T = (0.66, 0.5)（右三分線附近）。
        //
        // 逐步推導（reviewer 請逐行驗算）：
        // (1) 主體在畫面上需要的位移 Δ = T − A = (+0.26, 0)：主體該「右移」。
        // (2) 相機右轉 ⇒ 世界景物在畫面中左移 ⇒ 主體左移。要主體右移 ⇒ 相機該「左轉」。
        // (3) 相機左轉時所有世界點右移 Δ；標記 P 要在構圖完成那刻落進準星 C = (0.5, 0.5)
        //     ⇒ P + Δ = C ⇒ P = C − Δ = (0.5 − 0.26, 0.5) = (0.24, 0.5)。
        //     同式 = C + (A − T) = (0.5 + 0.4 − 0.66, 0.5 + 0.5 − 0.5) = (0.24, 0.5) ✓
        // (4) 正向控制驗證：標記在準星「左側」⇒ 用戶朝標記方向（左）轉手機
        //     ⇒ 世界景物右移 ⇒ 標記從 0.24 往 0.5 滑進準星，主體同步從 0.4 滑到 0.66。
        //     手往哪轉、標記就往準星走 — 與舊「點對環」的反向控制正好相反。
        let marker = AimPointSolver.marker(
            anchor: NPoint(x: 0.4, y: 0.5),
            target: NPoint(x: 0.66, y: 0.5)
        )
        XCTAssertEqual(marker.x, 0.24, accuracy: 1e-12)
        XCTAssertEqual(marker.y, 0.5, accuracy: 1e-12)
        // 附帶語意：|marker − C| = |anchor − target| = 0.26
        // ⇒ A2 的 aimDistance 與舊 anchor–target 距離同尺度，
        //   GuidanceTracker 的 lockAt / unlockAt 門檻可直接沿用。
        let dx = marker.x - 0.5
        let dy = marker.y - 0.5
        XCTAssertEqual((dx * dx + dy * dy).squareRoot(), 0.26, accuracy: 1e-12)
    }

    func testMarkerTwoAxisHandComputed() {
        // A = (0.3, 0.7)、T = (0.5, 0.33)：
        // Δ = T − A = (+0.2, −0.37)：主體該右移 + 上移（y 向下為正，−0.37 = 往上）。
        // P = C + (A − T) = (0.5 + 0.3 − 0.5, 0.5 + 0.7 − 0.33) = (0.3, 0.87)。
        // 語意：P 在準星「左下」⇒ 用戶往左下轉（左轉 + 下俯）。
        // 驗證 y 向：相機下俯 ⇒ 鏡頭指向更低 ⇒ 世界景物在畫面中上移
        // ⇒ 主體上移（0.7 → 0.33）✓，同時標記上移（0.87 → 0.5）滑進準星 ✓。
        let marker = AimPointSolver.marker(
            anchor: NPoint(x: 0.3, y: 0.7),
            target: NPoint(x: 0.5, y: 0.33)
        )
        XCTAssertEqual(marker.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(marker.y, 0.87, accuracy: 1e-12)
    }

    func testMarkerAtCrosshairWhenAnchorEqualsTarget() {
        // 構圖已完成（A == T）⇒ Δ = 0 ⇒ 標記正好在準星上。
        let marker = AimPointSolver.marker(
            anchor: NPoint(x: 0.7, y: 0.4),
            target: NPoint(x: 0.7, y: 0.4)
        )
        XCTAssertEqual(marker, AimPointSolver.crosshair)
    }

    func testMarkerMayBeOffscreen() {
        // A = (0.1, 0.5)、T = (0.9, 0.5)：Δ = +0.8（大幅右移）
        // ⇒ P = (0.5 − 0.8, 0.5) = (−0.3, 0.5)，出界值合法 —
        // 本函式不夾，顯示夾取與邊緣箭頭是 AimGeometry 的職責。
        let marker = AimPointSolver.marker(
            anchor: NPoint(x: 0.1, y: 0.5),
            target: NPoint(x: 0.9, y: 0.5)
        )
        XCTAssertEqual(marker.x, -0.3, accuracy: 1e-12)
        XCTAssertEqual(marker.y, 0.5, accuracy: 1e-12)
    }

    // MARK: - GyroFusedPoint：首筆與 nil 規則

    func testFirstCorrectPassesThroughBitExact() {
        let fused = GyroFusedPoint()
        XCTAssertNil(fused.value)
        fused.correct(NPoint(x: 0.31, y: 0.72))
        // 首筆 pass-through（bit-精確），不得被權重稀釋。
        XCTAssertEqual(fused.value, NPoint(x: 0.31, y: 0.72))
    }

    func testPredictBeforeAnyCorrectIsIgnored() {
        // 尚無任何 Vision 量測 ⇒ 沒有基準點 ⇒ predict 靜默忽略。
        let fused = GyroFusedPoint()
        fused.predict(dxNormalized: 0.1, dyNormalized: -0.2)
        XCTAssertNil(fused.value)
        // 之後第一筆 correct 仍是 pass-through（先前的 predict 不得殘留）。
        fused.correct(NPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(fused.value, NPoint(x: 0.5, y: 0.5))
    }

    // MARK: - GyroFusedPoint：純 predict 累加

    func testPurePredictAccumulates() throws {
        // correct(0.5, 0.5) 後連續三筆 predict(+0.01, −0.02)：
        // value = (0.5 + 3×0.01, 0.5 − 3×0.02) = (0.53, 0.44)。
        // 這就是兩次 Vision 之間的陀螺儀外推：標記隨手機轉動即時滑動。
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.5, y: 0.5))
        for _ in 0..<3 {
            fused.predict(dxNormalized: 0.01, dyNormalized: -0.02)
        }
        let value = try XCTUnwrap(fused.value)
        XCTAssertEqual(value.x, 0.53, accuracy: 1e-12)
        XCTAssertEqual(value.y, 0.44, accuracy: 1e-12)
    }

    // MARK: - GyroFusedPoint：correct 收斂（互補濾波）

    func testCorrectConvergesGeometrically() throws {
        // w = 0.35：value ← 0.35·m + 0.65·value ⇒ 誤差 e ← 0.65·e。
        // 起點 (0.2, 0.2)（首筆 pass-through）、量測固定 (0.6, 0.6)、e₀ = 0.4：
        //   correct 1 次：v = 0.35×0.6 + 0.65×0.2  = 0.21 + 0.13   = 0.34
        //   correct 2 次：v = 0.35×0.6 + 0.65×0.34 = 0.21 + 0.221  = 0.431
        //   correct 3 次：v = 0.35×0.6 + 0.65×0.431 = 0.21 + 0.28015 = 0.49015
        // 誤差序列 0.4 → 0.26 → 0.169 → 0.10985（每筆 ×0.65）✓
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.2, y: 0.2))
        let m = NPoint(x: 0.6, y: 0.6)

        fused.correct(m)
        var v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.34, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.34, accuracy: 1e-12)

        fused.correct(m)
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.431, accuracy: 1e-12)

        fused.correct(m)
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.49015, accuracy: 1e-12)

        // 長期：20 筆後誤差 ≤ 0.4×0.65²⁰ ≈ 7.3e-5（幾何收斂，不振盪、不過衝）。
        for _ in 0..<17 {
            fused.correct(m)
        }
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.6, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(v.x, 0.6) // 凸組合 ⇒ 永不過衝
    }

    // MARK: - GyroFusedPoint：predict / correct 交錯序列（手算）

    func testInterleavedPredictCorrectHandComputed() throws {
        // 模擬真實節奏：Vision 量測之間夾陀螺儀位移，w = 0.35。
        // 步驟逐行手算（reviewer 請驗算）：
        // (1) correct(0.5, 0.5)        → v = (0.5, 0.5)（首筆 pass-through）
        // (2) predict(+0.1, 0)         → v = (0.6, 0.5)（陀螺儀外推）
        // (3) correct(0.58, 0.5)：
        //       x = 0.35×0.58 + 0.65×0.6 = 0.203 + 0.39 = 0.593
        //       y = 0.35×0.5  + 0.65×0.5 = 0.5
        //     （Vision 說 0.58、陀螺儀說 0.6 → 融合值輕輕靠向量測，不跳）
        // (4) predict(−0.02, +0.03)    → v = (0.573, 0.53)
        // (5) correct(0.57, 0.52)：
        //       x = 0.35×0.57 + 0.65×0.573 = 0.1995 + 0.37245 = 0.57195
        //       y = 0.35×0.52 + 0.65×0.53  = 0.182  + 0.3445  = 0.5265
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.5, y: 0.5))
        fused.predict(dxNormalized: 0.1, dyNormalized: 0)
        var v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.5, accuracy: 1e-12)

        fused.correct(NPoint(x: 0.58, y: 0.5))
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.593, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.5, accuracy: 1e-12)

        fused.predict(dxNormalized: -0.02, dyNormalized: 0.03)
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.573, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.53, accuracy: 1e-12)

        fused.correct(NPoint(x: 0.57, y: 0.52))
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.57195, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.5265, accuracy: 1e-12)
    }

    // MARK: - GyroFusedPoint：權重邊界與 clamp

    func testWeightOneAlwaysJumpsToMeasurement() {
        // w = 1：correct 完全信量測（陀螺儀只在量測之間有效）。
        let fused = GyroFusedPoint(measurementWeight: 1.0)
        fused.correct(NPoint(x: 0.2, y: 0.2))
        fused.predict(dxNormalized: 0.3, dyNormalized: 0.3)
        fused.correct(NPoint(x: 0.7, y: 0.9))
        // 1×m + 0×v = m（乘法後仍 bit-精確）。
        XCTAssertEqual(fused.value, NPoint(x: 0.7, y: 0.9))
    }

    func testWeightZeroIgnoresMeasurementAfterFirst() throws {
        // w = 0：首筆 pass-through 不受權重影響；之後 correct 完全不動
        // （純陀螺儀航跡推算 — 實務不用，但邊界行為必須有定義）。
        let fused = GyroFusedPoint(measurementWeight: 0)
        fused.correct(NPoint(x: 0.2, y: 0.2))
        fused.correct(NPoint(x: 0.9, y: 0.9))
        let v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.2, accuracy: 1e-12)
    }

    func testWeightClampedToUnitInterval() {
        // 與 PointSmoother 同防禦：出範圍的權重夾回 [0, 1]。
        XCTAssertEqual(GyroFusedPoint(measurementWeight: 1.5).measurementWeight, 1.0)
        XCTAssertEqual(GyroFusedPoint(measurementWeight: -0.5).measurementWeight, 0.0)
        XCTAssertEqual(GyroFusedPoint().measurementWeight, 0.35)
    }

    // MARK: - GyroFusedPoint：reset

    func testResetClearsStateAndNextCorrectPassesThrough() {
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.3, y: 0.4))
        fused.predict(dxNormalized: 0.05, dyNormalized: 0.05)
        fused.reset()
        XCTAssertNil(fused.value)
        // reset 後 predict 同樣被忽略（不得從殘留狀態累加）。
        fused.predict(dxNormalized: 0.1, dyNormalized: 0.1)
        XCTAssertNil(fused.value)
        // 下一筆 correct 重新 pass-through，不得從舊位置 (0.35, 0.45) 滑過去。
        fused.correct(NPoint(x: 0.8, y: 0.1))
        XCTAssertEqual(fused.value, NPoint(x: 0.8, y: 0.1))
    }

    // MARK: - AimGeometry：畫面內 pass-through

    func testOnscreenMarkerPassesThrough() {
        let state = AimGeometry.state(for: NPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(state.marker, NPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(state.clamped, NPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(state.isOffscreen)
        XCTAssertNil(state.offscreenDirection)
        // 顯示範圍角落 (0.06, 0.94)：正好在夾取邊界上，不動。
        let corner = AimGeometry.state(for: NPoint(x: 0.06, y: 0.94))
        XCTAssertEqual(corner.clamped, NPoint(x: 0.06, y: 0.94))
        XCTAssertFalse(corner.isOffscreen)
        XCTAssertNil(corner.offscreenDirection)
    }

    func testMarginBandClampsDisplayButNotOffscreen() {
        // marker = (0.97, 0.5)：仍在畫面 [0,1] 內 ⇒ 不算出界（不畫箭頭），
        // 但顯示位置夾到 0.94（標記圖示不貼死畫面邊）。
        let state = AimGeometry.state(for: NPoint(x: 0.97, y: 0.5))
        XCTAssertEqual(state.marker.x, 0.97, accuracy: 1e-12) // marker 保留原始值
        XCTAssertEqual(state.clamped, NPoint(x: 0.94, y: 0.5))
        XCTAssertFalse(state.isOffscreen)
        XCTAssertNil(state.offscreenDirection)
        // 低側同理：(0.02, 0.5) → 顯示 0.06、不算出界。
        let low = AimGeometry.state(for: NPoint(x: 0.02, y: 0.5))
        XCTAssertEqual(low.clamped, NPoint(x: 0.06, y: 0.5))
        XCTAssertFalse(low.isOffscreen)
    }

    func testExactScreenEdgeIsOnscreen() {
        // 出界判定用「嚴格」不等式：x/y 恰為 0 或 1 仍算畫面內。
        let state = AimGeometry.state(for: NPoint(x: 0.0, y: 1.0))
        XCTAssertFalse(state.isOffscreen)
        XCTAssertNil(state.offscreenDirection)
        XCTAssertEqual(state.clamped, NPoint(x: 0.06, y: 0.94))
    }

    // MARK: - AimGeometry：出界（單軸）

    func testOffscreenRightPointsRight() throws {
        // marker = (1.2, 0.5)：clamped = (0.94, 0.5)；
        // 方向 = normalize(marker − clamped) = normalize((0.26, 0)) = (1, 0)。
        // 語意：邊緣箭頭畫在 clamped、指向右 = 用戶該往右轉。
        let state = AimGeometry.state(for: NPoint(x: 1.2, y: 0.5))
        XCTAssertTrue(state.isOffscreen)
        XCTAssertEqual(state.clamped, NPoint(x: 0.94, y: 0.5))
        let dir = try XCTUnwrap(state.offscreenDirection)
        XCTAssertEqual(dir.x, 1.0, accuracy: 1e-12)
        XCTAssertEqual(dir.y, 0.0, accuracy: 1e-12)
    }

    func testOffscreenTopPointsUp() throws {
        // marker = (0.5, −0.3)：clamped = (0.5, 0.06)；
        // 方向 = normalize((0, −0.36)) = (0, −1)（y 向下為正 ⇒ −1 = 指向上）。
        let state = AimGeometry.state(for: NPoint(x: 0.5, y: -0.3))
        XCTAssertTrue(state.isOffscreen)
        XCTAssertEqual(state.clamped, NPoint(x: 0.5, y: 0.06))
        let dir = try XCTUnwrap(state.offscreenDirection)
        XCTAssertEqual(dir.x, 0.0, accuracy: 1e-12)
        XCTAssertEqual(dir.y, -1.0, accuracy: 1e-12)
    }

    // MARK: - AimGeometry：出界（角落）

    func testOffscreenCornerHandComputed() throws {
        // marker = (1.3, 1.2)（右下角外）：clamped = (0.94, 0.94)。
        // diff = (0.36, 0.26)；|diff| = √(0.36² + 0.26²) = √(0.1296 + 0.0676)
        //      = √0.1972 ≈ 0.4440721。
        // 方向 = (0.36, 0.26)/0.4440721 ≈ (0.8107, 0.5855)（指向右下）。
        let state = AimGeometry.state(for: NPoint(x: 1.3, y: 1.2))
        XCTAssertTrue(state.isOffscreen)
        XCTAssertEqual(state.clamped, NPoint(x: 0.94, y: 0.94))
        let dir = try XCTUnwrap(state.offscreenDirection)
        let length = (0.36 * 0.36 + 0.26 * 0.26).squareRoot()
        XCTAssertEqual(dir.x, 0.36 / length, accuracy: 1e-12)
        XCTAssertEqual(dir.y, 0.26 / length, accuracy: 1e-12)
        XCTAssertEqual(dir.x, 0.8107, accuracy: 5e-4) // 手算近似值互驗
        XCTAssertEqual(dir.y, 0.5855, accuracy: 5e-4)
        // 單位向量 + 分量比 = diff 比（方向不被 clamp 扭曲）。
        XCTAssertEqual(dir.x * dir.x + dir.y * dir.y, 1.0, accuracy: 1e-12)
        XCTAssertEqual(dir.x / dir.y, 0.36 / 0.26, accuracy: 1e-9)
    }

    func testOffscreenDirectionAlwaysUnitLength() throws {
        // 幾個代表性出界點：方向向量長度恆為 1。
        let markers = [
            NPoint(x: -0.5, y: 0.5),
            NPoint(x: 0.5, y: 1.7),
            NPoint(x: -0.2, y: -0.4),
            NPoint(x: 1.01, y: 0.99)
        ]
        for marker in markers {
            let state = AimGeometry.state(for: marker)
            XCTAssertTrue(state.isOffscreen, "\(marker) 應判出界")
            let dir = try XCTUnwrap(state.offscreenDirection)
            XCTAssertEqual(dir.x * dir.x + dir.y * dir.y, 1.0, accuracy: 1e-12)
        }
    }

    // MARK: - 端到端語意：solver → geometry

    func testSolverOffscreenMarkerYieldsLeftEdgeArrow() throws {
        // 接 testMarkerMayBeOffscreen 的場景：A = (0.1, 0.5)、T = (0.9, 0.5)
        // ⇒ marker = (−0.3, 0.5)（該大幅左轉）。
        // AimGeometry：clamped = (0.06, 0.5)、方向 = normalize((−0.36, 0)) = (−1, 0)
        // ⇒ 邊緣箭頭在畫面左緣指向左 = 用戶往左轉，標記進場後繼續滑向準星。
        let marker = AimPointSolver.marker(
            anchor: NPoint(x: 0.1, y: 0.5),
            target: NPoint(x: 0.9, y: 0.5)
        )
        let state = AimGeometry.state(for: marker)
        XCTAssertTrue(state.isOffscreen)
        XCTAssertEqual(state.clamped, NPoint(x: 0.06, y: 0.5))
        let dir = try XCTUnwrap(state.offscreenDirection)
        XCTAssertEqual(dir.x, -1.0, accuracy: 1e-12)
        XCTAssertEqual(dir.y, 0.0, accuracy: 1e-12)
    }
}
