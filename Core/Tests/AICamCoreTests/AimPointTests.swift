//  AimPointTests.swift
//  AICamCoreTests — v0.4.0 對準點導引數學測試（Linux swift test 必須可跑）。
//
//  這裡鎖死整個新交互的地基語意：
//  (1) 標記重投影 P = C + (anchor − target) 與「正向控制」方向語意；
//  (2) GyroFusedPoint 互補濾波（predict 累加 / correct 收斂 / 交錯序列）；
//  (3) AimGeometry 顯示夾取 [0.06, 0.94]、出界判定 [0, 1]、出界方向向量；
//  (4) v0.5.1「標記跟手飄走」修復：延遲補償（回溯環形緩衝）、
//      逐軸增益/符號 AutoGain 自癒、reset 保留增益 + seedGains 持久化恢復。
//  全部手算基準；GyroFusedPoint 預設 w = 0.35（誤差每筆 correct ×0.65）。
//  v0.5.1 調整：predict 依新契約帶時間戳（呼叫端統一時基，秒）— 既有
//  測試僅補上任意單調時間值，「無延遲、增益 1」情境下融合數值與 v0.4.0
//  完全相同（相容版 correct 回退 0，公式逐位一致），語意不變。

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
        fused.predict(dxNormalized: 0.1, dyNormalized: -0.2, at: 0.01)
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
        for i in 0..<3 {
            // 時間戳 10ms 網格（任意單調即可，純 predict 不查緩衝）。
            fused.predict(dxNormalized: 0.01, dyNormalized: -0.02, at: Double(i + 1) / 100.0)
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
        // v0.5.1 調整原因：AutoGain 併入本類後，每筆 correct 會依「兩次
        // correct 間的量測位移/原始位移比」更新逐軸增益，之後的 predict
        // 用有效位移（原始 × gain）— 互補濾波「融合」語意不變，但手算
        // 序列必須把契約規定的增益自癒效果一併算進去（步驟 3 起）。
        // 步驟逐行手算（reviewer 請驗算）：
        // (1) correct(0.5, 0.5)          → v = (0.5, 0.5)（首筆 pass-through；
        //     AutoGain 基準：量測 (0.5, 0.5)、原始累計 (0, 0)）
        // (2) predict(+0.1, 0, at 0.01)  → v = (0.6, 0.5)（gain 仍 (1, 1)）
        // (3) correct(0.58, 0.5)（相容版 ⇒ frameTime = 0.01 = 最新樣本 ⇒ 回退 0）：
        //       x = 0.35×0.58 + 0.65×0.6 = 0.203 + 0.39 = 0.593
        //       y = 0.35×0.5  + 0.65×0.5 = 0.5
        //     （Vision 說 0.58、陀螺儀說 0.6 → 融合值輕輕靠向量測，不跳）
        //     AutoGain：x 軸 rawSum = 0.1 > 0.008、measDelta = 0.58 − 0.5 = 0.08
        //       ⇒ r = 0.8 ⇒ gainX = 1 + 0.15×(0.8 − 1) = 0.97
        //     y 軸 rawSum = 0 ≤ 0.008 ⇒ gainY 凍結 = 1
        // (4) predict(−0.02, +0.03, at 0.02)：有效位移 = (−0.02×0.97, 0.03×1)
        //       → v = (0.593 − 0.0194, 0.5 + 0.03) = (0.5736, 0.53)
        // (5) correct(0.57, 0.52)（相容版，回退 0）：
        //       x = 0.35×0.57 + 0.65×0.5736 = 0.1995 + 0.37284 = 0.57234
        //       y = 0.35×0.52 + 0.65×0.53   = 0.182  + 0.3445  = 0.5265
        //     AutoGain：x 軸 rawSum = −0.02、measDelta = 0.57 − 0.58 = −0.01
        //       ⇒ r = 0.5 ⇒ gainX = 0.97 + 0.15×(0.5 − 0.97) = 0.8995
        //     y 軸 rawSum = 0.03、measDelta = 0.52 − 0.5 = 0.02
        //       ⇒ r = 2/3 ⇒ gainY = 1 + 0.15×(2/3 − 1) = 0.95
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.5, y: 0.5))
        fused.predict(dxNormalized: 0.1, dyNormalized: 0, at: 0.01)
        var v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.5, accuracy: 1e-12)

        fused.correct(NPoint(x: 0.58, y: 0.5))
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.593, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(fused.gainX, 0.97, accuracy: 1e-9)
        XCTAssertEqual(fused.gainY, 1.0, accuracy: 1e-12)

        fused.predict(dxNormalized: -0.02, dyNormalized: 0.03, at: 0.02)
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.5736, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.53, accuracy: 1e-12)

        fused.correct(NPoint(x: 0.57, y: 0.52))
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.57234, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.5265, accuracy: 1e-12)
        XCTAssertEqual(fused.gainX, 0.8995, accuracy: 1e-9)
        XCTAssertEqual(fused.gainY, 0.95, accuracy: 1e-9)
    }

    // MARK: - GyroFusedPoint：權重邊界與 clamp

    func testWeightOneAlwaysJumpsToMeasurement() {
        // w = 1：correct 完全信量測（陀螺儀只在量測之間有效）。
        let fused = GyroFusedPoint(measurementWeight: 1.0)
        fused.correct(NPoint(x: 0.2, y: 0.2))
        fused.predict(dxNormalized: 0.3, dyNormalized: 0.3, at: 0.01)
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
        fused.predict(dxNormalized: 0.05, dyNormalized: 0.05, at: 0.01)
        fused.reset()
        XCTAssertNil(fused.value)
        // reset 後 predict 同樣被忽略（不得從殘留狀態累加）。
        fused.predict(dxNormalized: 0.1, dyNormalized: 0.1, at: 0.02)
        XCTAssertNil(fused.value)
        // 下一筆 correct 重新 pass-through，不得從舊位置 (0.35, 0.45) 滑過去。
        fused.correct(NPoint(x: 0.8, y: 0.1))
        XCTAssertEqual(fused.value, NPoint(x: 0.8, y: 0.1))
    }

    // MARK: - GyroFusedPoint v0.5.1 (a)：延遲補償勝出（回溯環形緩衝）

    func testDelayCompensationBeatsCompatUnderUniformPan() throws {
        // 情境 = 真機爆症 (c) 的最小重現：勻速 pan，Vision 量測固定延遲 120ms。
        // 真值 true(t) = 0.2 + 1.0·t（每 10ms 右移 0.01；gyro 每 10ms 回報
        // dx = 0.01，增益/符號皆正確 — 隔離延遲效應）。
        // Vision ~15fps：每 60ms 一筆 correct（10ms 網格對齊便於手算；
        // 規格的 66ms 同量級）、量測值 = true(correct 時刻 − 0.12)。
        // 種子（t = 0 的首筆量測）本身也是 120ms 前的舊值 true(−0.12) = 0.08。
        //
        // ── 手算：舊行為（相容版）──
        // 種子後落後量 L = true(t) − v(t) = 0.12。predict 與真值同速 ⇒ 兩次
        // correct 間 L 不變；每筆 correct：v ← v + w·(m − v)，m = true(t) − 0.12
        //   ⇒ L ← L − 0.35·(L − 0.12) = 0.65·L + 0.042。
        // L₀ = 0.12 恰為不動點：0.65×0.12 + 0.042 = 0.12 ⇒ 舊行為「永遠」
        // 落後 0.12 — 標記持續被拖在移動方向後方（跟著手走），正是回報的病。
        //
        // ── 手算：新行為（measuredAt）──
        // valueAt(frameTime) = v − (frameTime 之後的位移) 把 v 拉回量測同帧
        //   ⇒ innovation = true(frameTime) − valueAt = L（整段落後被完整觀測）
        //   ⇒ L ← 0.65·L（幾何歸零，延遲不再產生穩態落後）。
        // 6 筆 correct 後：L = 0.12 × 0.65⁶ = 0.12 × 0.075418890625
        //                    = 0.009050266875。
        // AutoGain 兩邊都不動：每段 gyroRawSum = 0.06、measDelta = 0.06
        //   ⇒ r = 1 = 不動點 ⇒ gain 恆 1（本測試隔離延遲，不牽動增益）。
        func runPan(useMeasuredAt: Bool) -> (residual: Double, gainX: Double) {
            let fused = GyroFusedPoint()
            func trueAt(_ t: Double) -> Double { 0.2 + 1.0 * t }
            // t = 0 種子：量測 = true(−0.12) = 0.08（首筆 pass-through）。
            if useMeasuredAt {
                fused.correct(NPoint(x: trueAt(-0.12), y: 0.5), measuredAt: -0.12)
            } else {
                fused.correct(NPoint(x: trueAt(-0.12), y: 0.5))
            }
            var lastT = 0.0
            var corrections = 0
            var step = 1
            while corrections < 6 {
                let t = Double(step) / 100.0    // 10ms 網格（與 frameTime 同構法，逐位相等）
                fused.predict(dxNormalized: 0.01, dyNormalized: 0, at: t)
                lastT = t
                // 第一筆 correct 在 t = 0.13（frameTime = 0.01 = 緩衝最舊樣本，
                // 剛好可回溯），之後每 60ms 一筆：0.19、0.25、0.31、0.37、0.43。
                if step >= 13 && (step - 13) % 6 == 0 {
                    let frameTime = Double(step - 12) / 100.0
                    let m = NPoint(x: trueAt(frameTime), y: 0.5)
                    if useMeasuredAt {
                        fused.correct(m, measuredAt: frameTime)
                    } else {
                        fused.correct(m)
                    }
                    corrections += 1
                }
                step += 1
            }
            let v = fused.value!
            return (trueAt(lastT) - v.x, fused.gainX)
        }

        let old = runPan(useMeasuredAt: false)
        let new = runPan(useMeasuredAt: true)
        // 舊：殘差鎖死在 0.12（= 整個延遲量的回拖）。
        XCTAssertEqual(old.residual, 0.12, accuracy: 1e-9)
        // 新：0.12 × 0.65⁶ = 0.009050266875（手算幾何數列）。
        XCTAssertEqual(new.residual, 0.009050266875, accuracy: 1e-9)
        // 規格門檻：新版殘差 < 舊版殘差的 1/3（實際 ≈ 1/13）。
        XCTAssertLessThan(new.residual, old.residual / 3)
        // 兩邊 AutoGain 都不受擾動（r = 1 不動點）。
        XCTAssertEqual(old.gainX, 1.0, accuracy: 1e-9)
        XCTAssertEqual(new.gainX, 1.0, accuracy: 1e-9)
    }

    func testDelayRollbackUsesEffectiveDisplacement() throws {
        // 回退量必須用「有效位移」（原始 × gain），不是原始位移。
        // seedGains(2, 1)；correct(0.5) 後兩筆 predict dx = 0.01（有效 0.02/筆）：
        //   t = 0.1：v = 0.52、cumRaw = 0.01；t = 0.2：v = 0.54、cumRaw = 0.02。
        // correct(m = 0.52, measuredAt: 0.1)：取 time ≥ 0.1 最近樣本 = t0.1
        //   （cumRaw 0.01）⇒ rollbackRaw = 0.02 − 0.01 = 0.01 ⇒ 有效回退
        //   = 0.01×2 = 0.02 ⇒ valueAt = 0.54 − 0.02 = 0.52 = m ⇒ innovation = 0
        //   ⇒ v 不動（= 0.54）。
        // 對照：相容版會往舊量測回拖 → 0.35×0.52 + 0.65×0.54 = 0.533（病徵）。
        let fused = GyroFusedPoint()
        fused.seedGains(x: 2.0, y: 1.0)
        fused.correct(NPoint(x: 0.5, y: 0.5), measuredAt: 0)
        fused.predict(dxNormalized: 0.01, dyNormalized: 0, at: 0.1)
        fused.predict(dxNormalized: 0.01, dyNormalized: 0, at: 0.2)
        fused.correct(NPoint(x: 0.52, y: 0.5), measuredAt: 0.1)
        let v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.54, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.5, accuracy: 1e-12)
        // AutoGain 順帶驗證（用原始量／原始位移）：rawSum = 0.02、
        // measDelta = 0.52 − 0.5 = 0.02 ⇒ r = 1 ⇒ gainX = 2 + 0.15×(1 − 2) = 1.85
        // （增益同時往正確值自修）。
        XCTAssertEqual(fused.gainX, 1.85, accuracy: 1e-9)
    }

    func testMeasurementOlderThanBufferFallsBackToCompat() throws {
        // 規格：frameTime 早於緩衝最舊樣本 ⇒ 退化為相容版（回退 0）。
        // correct(0.5)、predict(0.01, at: 1.0) → v = 0.51、緩衝最舊 = 1.0。
        // correct(0.6, measuredAt: 0.2)：0.2 < 1.0 ⇒ 相容版：
        //   v = 0.35×0.6 + 0.65×0.51 = 0.21 + 0.3315 = 0.5415。
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.5, y: 0.5), measuredAt: 0)
        fused.predict(dxNormalized: 0.01, dyNormalized: 0, at: 1.0)
        fused.correct(NPoint(x: 0.6, y: 0.5), measuredAt: 0.2)
        let v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.5415, accuracy: 1e-12)
    }

    func testBufferPrunesBeyondWindow() throws {
        // 緩衝只留最近 0.6s：t = 0 的樣本在 t = 0.7 推入時被剪
        // （cutoff = 0.7 − 0.6 = 0.1 > 0）⇒ measuredAt 0（老過窗）退化為相容版。
        // correct(0.5)；predict(0.01, at: 0) → v = 0.51；
        // predict(0.01, at: 0.7) → v = 0.52。
        // correct(0.4, measuredAt: 0)：
        //   若 t=0 樣本未剪：rollbackRaw = 0.02 − 0.01 = 0.01 ⇒ m′ = 0.41
        //     ⇒ v = 0.35×0.41 + 0.65×0.52 = 0.4815（錯誤路徑）；
        //   已剪（正確）：相容版 v = 0.35×0.4 + 0.65×0.52 = 0.14 + 0.338 = 0.478。
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.5, y: 0.5), measuredAt: 0)
        fused.predict(dxNormalized: 0.01, dyNormalized: 0, at: 0)
        fused.predict(dxNormalized: 0.01, dyNormalized: 0, at: 0.7)
        fused.correct(NPoint(x: 0.4, y: 0.5), measuredAt: 0)
        let v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.478, accuracy: 1e-12)
    }

    // MARK: - GyroFusedPoint v0.5.1 (b)：符號自癒（gain 收斂為負）

    func testSignFlippedAxisSelfHealsToNegativeGain() throws {
        // 情境 = 真機爆症 (a)：某軸陀螺儀符號實機相反。
        // 真值每 10ms 右移 +0.01，但 gyro 回報 dx = −0.01（反號）；
        // Vision 每 60ms 給「正確」位置（取零延遲、measuredAt = 當下，
        // 隔離符號自癒；延遲補償已由上面測試覆蓋）。
        // 每段（6 筆 predict）：gyroRawSum = −0.06、measDelta = +0.06
        //   ⇒ r = −1 ⇒ gain ← gain + 0.15×(−1 − gain)，g₀ = 1：
        //   g_n = −1 + 2×0.85ⁿ（手算：g₁ = 0.7、g₂ = 0.445、g₃ = 0.22825、
        //   g₄ = 0.0440125、g₅ = −0.11259 — 第 5 筆已翻負，遠在 20 筆內）
        //   g₂₀ = −1 + 2×0.85²⁰ = −1 + 2×0.03875953… = −0.92248094…
        // 之後有效位移 = (−0.01)×(負 gain) ≈ +0.01 = 真實運動 ⇒ 標記跟上真值：
        // 殘差 e_n = 0.65×(e_{n−1} − 0.12×0.85ⁿ⁻¹) 幾何衰減
        // （峰值 ≈ −0.134 in n=4 過渡期，之後 → 0；40 筆後 |e| < 1e-3）。
        let fused = GyroFusedPoint()
        var trueX = 0.2
        fused.correct(NPoint(x: trueX, y: 0.5), measuredAt: 0)
        var step = 1
        var corrections = 0
        var gainAt20 = 0.0
        var residual = 0.0
        while corrections < 40 {
            let t = Double(step) / 100.0
            trueX += 0.01
            fused.predict(dxNormalized: -0.01, dyNormalized: 0, at: t)   // 反號！
            if step % 6 == 0 {
                fused.correct(NPoint(x: trueX, y: 0.5), measuredAt: t)
                corrections += 1
                if corrections == 20 { gainAt20 = fused.gainX }
                residual = abs(trueX - fused.value!.x)
            }
            step += 1
        }
        // 規格：20 筆 correct 內 gainX 收斂為負值（實際第 5 筆已翻負）。
        XCTAssertLessThan(gainAt20, 0)
        XCTAssertEqual(gainAt20, -0.92248094, accuracy: 1e-4)
        // 之後 value 跟上真值：40 筆後殘差有界（實際 ≈ 6e-4 ≪ 0.02）。
        XCTAssertLessThan(residual, 0.02)
        // y 軸位移恆 0 ⇒ gainY 從未更新（bit-exact 1.0）。
        XCTAssertEqual(fused.gainY, 1.0)
    }

    // MARK: - GyroFusedPoint v0.5.1 (c)：增益自癒（半增益 → 收斂 ≈ 2）

    func testHalfGainSelfHealsTowardTwo() throws {
        // 情境 = 真機爆症 (b)：FOV/變焦換算殘差 ⇒ gyro 位移只有真值一半。
        // 真值每 10ms +0.01，gyro 回報 +0.005。每段（6 筆 predict）：
        // gyroRawSum = 0.03、measDelta = 0.06 ⇒ r = 2（在 clamp ±2.5 內，不截）
        //   ⇒ gain ← gain + 0.15×(2 − gain)，g₀ = 1：
        //   g_n = 2 − 0.85ⁿ（g₁ = 1.15、g₂ = 1.2775、…、
        //   g₂₀ = 2 − 0.03875953… = 1.96124047…）
        let fused = GyroFusedPoint()
        var trueX = 0.2
        fused.correct(NPoint(x: trueX, y: 0.5), measuredAt: 0)
        var step = 1
        var corrections = 0
        while corrections < 20 {
            let t = Double(step) / 100.0
            trueX += 0.01
            fused.predict(dxNormalized: 0.005, dyNormalized: 0, at: t)   // 半增益
            if step % 6 == 0 {
                fused.correct(NPoint(x: trueX, y: 0.5), measuredAt: t)
                corrections += 1
            }
            step += 1
        }
        // 規格驗收：收斂 ≈ 2（容差 ±0.3）；手算精確值 1.96124047。
        XCTAssertEqual(fused.gainX, 2.0, accuracy: 0.3)
        XCTAssertEqual(fused.gainX, 1.96124047, accuracy: 1e-3)
        XCTAssertEqual(fused.gainY, 1.0)   // y 軸無位移 ⇒ 凍結
    }

    // MARK: - GyroFusedPoint v0.5.1 (d)：靜止門檻（|rawSum| ≤ 0.008 不學）

    func testTinyGyroSumDoesNotPolluteGains() {
        // 靜止手抖：兩次 correct 間 |gyroRawSum| ≤ 0.008 ⇒ 增益凍結。
        // 位移用 2⁻⁷ = 0.0078125（二進位可精確表示，嚴格 < 0.008，
        // 門檻判定不受十進位浮點誤差影響）。
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.5, y: 0.5), measuredAt: 0)
        fused.predict(dxNormalized: 0.0078125, dyNormalized: 0, at: 0.01)
        // 量測大跳（Vision 抖動/短遮擋跳點）：x 動 0.05、y 動 0.04，
        // 但 x 原始位移僅 0.0078125 ≤ 0.008、y 為 0 ⇒ 兩軸增益都不准動。
        fused.correct(NPoint(x: 0.55, y: 0.54), measuredAt: 0.01)
        XCTAssertEqual(fused.gainX, 1.0)   // bit-exact：未經任何更新
        XCTAssertEqual(fused.gainY, 1.0)
        // 對照組：位移 0.01 > 0.008 ⇒ x 軸開始學習。
        // measDelta = 0.58 − 0.55 = 0.03、rawSum = 0.01 ⇒ r = 3 → 截到 2.5
        //   ⇒ gainX = 1 + 0.15×(2.5 − 1) = 1.225（同時驗證 r 的 clamp）。
        fused.predict(dxNormalized: 0.01, dyNormalized: 0, at: 0.02)
        fused.correct(NPoint(x: 0.58, y: 0.54), measuredAt: 0.02)
        XCTAssertEqual(fused.gainX, 1.225, accuracy: 1e-9)
        XCTAssertEqual(fused.gainY, 1.0)   // y 軸位移仍 0 ⇒ 依舊凍結
    }

    // MARK: - GyroFusedPoint v0.5.1 (e)：reset 保留增益 + seedGains

    func testResetKeepsGainsAndSeedGainsApplies() throws {
        let fused = GyroFusedPoint()
        // 持久化恢復：上個 session 學到 gainX = 2.0、gainY = −1.0（負 = 翻號軸）。
        fused.seedGains(x: 2.0, y: -1.0)
        XCTAssertEqual(fused.gainX, 2.0)
        XCTAssertEqual(fused.gainY, -1.0)

        fused.correct(NPoint(x: 0.5, y: 0.5), measuredAt: 0)
        // 有效位移 = 原始 × gain：dx 0.01×2 = +0.02；dy 0.01×(−1) = −0.01。
        fused.predict(dxNormalized: 0.01, dyNormalized: 0.01, at: 0.01)
        let v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.52, accuracy: 1e-12)
        XCTAssertEqual(v.y, 0.49, accuracy: 1e-12)

        // reset 清 value / 緩衝 / 量測基準，「不清」增益（裝置級事實）。
        fused.reset()
        XCTAssertNil(fused.value)
        XCTAssertEqual(fused.gainX, 2.0)
        XCTAssertEqual(fused.gainY, -1.0)
        // reset 後第一筆 correct 重新 pass-through 且不學習（基準已清 —
        // reset 前的 0.5 與這裡的 0.3 之間的假位移不得污染增益）。
        fused.correct(NPoint(x: 0.3, y: 0.3), measuredAt: 5)
        XCTAssertEqual(fused.value, NPoint(x: 0.3, y: 0.3))
        XCTAssertEqual(fused.gainX, 2.0)
        XCTAssertEqual(fused.gainY, -1.0)

        // seedGains 超界夾取：與線上學習同界 [−2.5, 2.5]。
        fused.seedGains(x: 9.9, y: -9.9)
        XCTAssertEqual(fused.gainX, 2.5)
        XCTAssertEqual(fused.gainY, -2.5)
        // 非有限值（損毀的持久化資料）整組拒收，保持現值。
        fused.seedGains(x: Double.nan, y: 1.0)
        XCTAssertEqual(fused.gainX, 2.5)
        XCTAssertEqual(fused.gainY, -2.5)
    }

    // MARK: - GyroFusedPoint：invalidateGainBaseline（anchor 定義跳變隔離）

    func testInvalidateGainBaselineSkipsOneLearningStep() throws {
        // 情境：群組模式臉數跨 2 邊緣 ⇒ 量測 anchor 定義跳變（union 中心）、
        // target 未變 ⇒ 呼叫端不 reset — 跳變不得進增益學習，但融合 value
        // 必須照常修正（標記連續性）。逐步手算（reviewer 請驗算）：
        // (1) correct(0.5) at 0     → pass-through；基準 = (量測 0.5, 累計 0)
        // (2) predict(+0.02, at 0.01) → v.x = 0.52、cumRawX = 0.02
        // (3) invalidateGainBaseline()：value / 緩衝 / 增益全不動（只清基準）
        // (4) correct(0.6, at 0.01)（回退 0 — frameTime = 最新樣本時間）：
        //       v.x = 0.35×0.6 + 0.65×0.52 = 0.21 + 0.338 = 0.548 ✓ 照常融合
        //     增益「不學」：若未隔離，measDelta = 0.1、rawSum = 0.02 ⇒ r = 5
        //       夾 2.5 ⇒ gainX 會被污染成 1 + 0.15×(2.5 − 1) = 1.225；
        //       隔離後 gainX 仍 = 1.0，且基準重立 = (0.6, 累計 0.02)
        // (5) predict(+0.02, at 0.02) → v.x = 0.568、cumRawX = 0.04
        // (6) correct(0.63, at 0.02)：學習恢復 —
        //       rawSum = 0.04 − 0.02 = 0.02、measDelta = 0.63 − 0.6 = 0.03
        //       ⇒ r = 1.5 ⇒ gainX = 1 + 0.15×(1.5 − 1) = 1.075
        //       v.x = 0.35×0.63 + 0.65×0.568 = 0.2205 + 0.3692 = 0.5897
        let fused = GyroFusedPoint()
        fused.correct(NPoint(x: 0.5, y: 0.5), measuredAt: 0)
        fused.predict(dxNormalized: 0.02, dyNormalized: 0, at: 0.01)
        var v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.52, accuracy: 1e-12)

        fused.invalidateGainBaseline()
        // 只清學習基準：value / 增益不動。
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.52, accuracy: 1e-12)
        XCTAssertEqual(fused.gainX, 1.0)
        XCTAssertEqual(fused.gainY, 1.0)

        // 跳變帧：融合照常、學習跳過。
        fused.correct(NPoint(x: 0.6, y: 0.5), measuredAt: 0.01)
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.548, accuracy: 1e-12)
        XCTAssertEqual(fused.gainX, 1.0)   // 未隔離會是 1.225（見手算 (4)）
        XCTAssertEqual(fused.gainY, 1.0)

        // 下一筆起學習恢復（基準已在跳變帧重立）。
        fused.predict(dxNormalized: 0.02, dyNormalized: 0, at: 0.02)
        fused.correct(NPoint(x: 0.63, y: 0.5), measuredAt: 0.02)
        v = try XCTUnwrap(fused.value)
        XCTAssertEqual(v.x, 0.5897, accuracy: 1e-12)
        XCTAssertEqual(fused.gainX, 1.075, accuracy: 1e-9)
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
