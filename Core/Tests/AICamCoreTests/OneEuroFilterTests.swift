//  OneEuroFilterTests.swift
//  AICamCoreTests — One Euro Filter 測試（Linux swift test 必須可跑）。
//
//  預設參數 minCutoff 1.2、beta 20、dCutoff 1.0；手算基準統一取 30fps（dt = 1/30）：
//  α(fc) = r/(r+1)、r = 2π·fc·(1/30)；αd = α(1.0) = 0.20944/1.20944 = 0.17317。
//  雜訊一律用固定種子 LCG（跨平台 bit-穩定），不用 SystemRandom。

import XCTest
import AICamCore
#if canImport(Glibc)
import Glibc
#endif

final class OneEuroFilterTests: XCTestCase {

    private let dt = 1.0 / 30.0

    /// 決定性偽隨機雜訊（64-bit LCG，Knuth 常數；wrapping 運算跨平台一致）。
    private struct NoiseGenerator {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        /// 回傳 ±amplitude 均勻雜訊。
        mutating func next(amplitude: Double) -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(seed >> 11) * (1.0 / 9_007_199_254_740_992.0) // [0, 1)
            return (unit - 0.5) * 2.0 * amplitude
        }
    }

    private func variance(_ xs: [Double]) -> Double {
        let mean = xs.reduce(0, +) / Double(xs.count)
        return xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
    }

    // MARK: - 靜止輸入收斂

    func testConstantInputStaysPut() throws {
        let filter = OneEuroFilter()
        for i in 0..<60 {
            let out = try XCTUnwrap(filter.update(0.5, at: Double(i) * dt))
            // 第一筆 pass-through = 0.5；之後恆為 α·0.5 + (1−α)·0.5 = 0.5
            //（浮點捨入僅 ~1 ulp 級，用 1e-12 容差）。速度差分恆 0 → 截止恆 minCutoff，
            // 狀態不會自激漂走。
            XCTAssertEqual(out, 0.5, accuracy: 1e-12)
        }
    }

    // MARK: - 階躍輸入低延遲到位

    func testStepResponseReachesTargetFast() throws {
        // 手算（30fps；beta=20 配 normalized 座標、速度單位 = 畫面/秒）：
        // 帧1：ẋ = (1−0)/(1/30) = 30 畫面/秒；ẋ̂ = 0.17317×30 = 5.1952
        //      fc = 1.2 + 20×5.1952 = 105.10 Hz；r = 2π×105.10/30 = 22.013
        //      α = 22.013/23.013 = 0.95655 → x̂₁ = 0.95655×1 + 0.04345×0 ≈ 0.9565
        // 帧2：ẋ = 0；ẋ̂ = (1−0.17317)×5.1952 = 4.2955；fc = 87.11；α = 0.94804
        //      x̂₂ = 0.94804 + 0.05196×0.95655 ≈ 0.9977
        // 帧3：ẋ̂ = 3.5516；fc = 72.23；α = 0.93800；x̂₃ ≈ 0.99986
        // ⇒ 快速移動時一帧內就跟上 95%（低延遲），三帧內收斂 99.5%+。
        let filter = OneEuroFilter()
        XCTAssertEqual(try XCTUnwrap(filter.update(0.0, at: 0)), 0.0) // 首筆 pass-through
        let s1 = try XCTUnwrap(filter.update(1.0, at: dt))
        XCTAssertEqual(s1, 0.9565, accuracy: 0.005)
        let s2 = try XCTUnwrap(filter.update(1.0, at: 2 * dt))
        XCTAssertEqual(s2, 0.9977, accuracy: 0.003)
        let s3 = try XCTUnwrap(filter.update(1.0, at: 3 * dt))
        XCTAssertGreaterThan(s3, 0.995)
        // 單調逼近、不過衝（輸出恆為新值與前值的凸組合）。
        XCTAssertGreaterThan(s2, s1)
        XCTAssertGreaterThanOrEqual(s3, s2)
        XCTAssertLessThanOrEqual(s3, 1.0)
    }

    // MARK: - 雜訊抑制

    func testStaticJitterSuppressed() throws {
        // 靜止主體 + ±0.02 手抖雜訊：一階低通對白雜訊的方差衰減係數 = α/(2−α)。
        // 本參數下（雜訊速度把 fc 打到 ~2–10 Hz）有效 α 約 0.2–0.5
        // → 理論衰減至 ~0.1–0.35 倍；斷言 < 0.7 倍留足裕度。
        let filter = OneEuroFilter()
        var noise = NoiseGenerator()
        var inputs: [Double] = []
        var outputs: [Double] = []
        for i in 0..<120 {
            let x = 0.5 + noise.next(amplitude: 0.02)
            let out = try XCTUnwrap(filter.update(x, at: Double(i) * dt))
            if i >= 30 { // 跳過暖機段
                inputs.append(x)
                outputs.append(out)
            }
        }
        XCTAssertLessThan(variance(outputs), variance(inputs) * 0.7)
    }

    func testSineWithNoiseTrackingErrorBounded() throws {
        // 0.5 Hz、振幅 0.2 的正弦（構圖擺動）+ ±0.02 雜訊。
        // 注意：此情境「不能」斷言 var(out) < var(in) —「凸組合 ⇒ 增益 ≤ 1 ⇒ 方差下降」
        // 對這顆自適應非線性濾波不成立：正弦峰值速度 0.2·2π·0.5 ≈ 0.63 畫面/秒把
        // fc 打到 10+ Hz（α ≈ 0.5–0.75），雜訊幾乎全通過；且雜訊本身調變 α
        //（雜訊尖峰 → |ẋ̂| 大 → α 大 → 追著尖峰跑）產生 signal×noise 互調 +
        // 相位滯後誤差，總方差反而略高於輸入（同 seed 精算 ratio ≈ 1.033）。
        // 運動中真正要保證的性質是「低延遲跟上低頻訊號」→ 斷言追蹤誤差上界：
        // 同 seed 精算 max|out − clean| = 0.03192；跨 seed 0.026–0.033；
        // 無雜訊純相位滯後 0.0166 ⇒ 上界 0.05 有 ~1.5 倍裕度，
        // 且對 libm sin 的跨平台 ulp 差異完全免疫。
        let filter = OneEuroFilter()
        var noise = NoiseGenerator()
        var outputs: [Double] = []
        var cleans: [Double] = []
        for i in 0..<180 {
            let t = Double(i) * dt
            let clean = 0.5 + 0.2 * sin(2 * Double.pi * 0.5 * t)
            let x = clean + noise.next(amplitude: 0.02)
            let out = try XCTUnwrap(filter.update(x, at: t))
            if i >= 30 {
                outputs.append(out)
                cleans.append(clean)
            }
        }
        var worst = 0.0
        for (i, out) in outputs.enumerated() {
            worst = max(worst, abs(out - cleans[i]))
        }
        XCTAssertLessThan(worst, 0.05)
    }

    // MARK: - nil 重置

    func testNilInputResetsState() throws {
        let filter = OneEuroFilter()
        for i in 0..<10 {
            _ = filter.update(0.2, at: Double(i) * dt)
        }
        // nil = 主體消失 → 重置並回 nil。
        XCTAssertNil(filter.update(nil, at: 11 * dt))
        // 重現後第一筆 pass-through（bit-精確 0.9），不得從舊位置 0.2 滑過去。
        XCTAssertEqual(try XCTUnwrap(filter.update(0.9, at: 12 * dt)), 0.9)
    }

    // MARK: - 頻率 clamp（1…120 Hz）

    func testFrequencyClampedToOneThroughOneTwentyHz() throws {
        // dt = 10s（0.1 Hz）夾到下限 1 Hz ⇔ 行為與 dt = 1s 完全相同。
        let slowA = OneEuroFilter()
        let slowB = OneEuroFilter()
        _ = slowA.update(0.0, at: 0)
        _ = slowB.update(0.0, at: 0)
        XCTAssertEqual(
            try XCTUnwrap(slowA.update(1.0, at: 10.0)),
            try XCTUnwrap(slowB.update(1.0, at: 1.0))
        )
        // dt = 1ms（1000 Hz）夾到上限 120 Hz ⇔ 行為與 dt = 1/120 完全相同。
        let fastA = OneEuroFilter()
        let fastB = OneEuroFilter()
        _ = fastA.update(0.0, at: 0)
        _ = fastB.update(0.0, at: 0)
        XCTAssertEqual(
            try XCTUnwrap(fastA.update(1.0, at: 0.001)),
            try XCTUnwrap(fastB.update(1.0, at: 1.0 / 120.0))
        )
        // 亂序 timestamp（dt < 0）也被夾住：不得產生 NaN，輸出仍在新舊值之間。
        let outOfOrder = OneEuroFilter()
        _ = outOfOrder.update(0.5, at: 1.0)
        let out = try XCTUnwrap(outOfOrder.update(0.6, at: 0.5))
        XCTAssertFalse(out.isNaN)
        XCTAssertGreaterThanOrEqual(out, 0.5)
        XCTAssertLessThanOrEqual(out, 0.6)
    }

    // MARK: - 2D 包裝

    func test2DFiltersAxesIndependently() throws {
        // OneEuroFilter2D 必須等價於兩顆獨立 1D filter 分別餵 x、y（逐帧 bit-相同）。
        let filter2D = OneEuroFilter2D(minCutoff: 1.2, beta: 20.0, dCutoff: 1.0)
        let filterX = OneEuroFilter(minCutoff: 1.2, beta: 20.0, dCutoff: 1.0)
        let filterY = OneEuroFilter(minCutoff: 1.2, beta: 20.0, dCutoff: 1.0)
        var noise = NoiseGenerator()
        for i in 0..<40 {
            let t = Double(i) * dt
            let p = NPoint(
                x: 0.4 + noise.next(amplitude: 0.1),
                y: 0.6 + noise.next(amplitude: 0.05)
            )
            let out = try XCTUnwrap(filter2D.update(p, at: t))
            XCTAssertEqual(out.x, try XCTUnwrap(filterX.update(p.x, at: t)))
            XCTAssertEqual(out.y, try XCTUnwrap(filterY.update(p.y, at: t)))
        }
    }

    func test2DNilResetsBothAxes() throws {
        let filter = OneEuroFilter2D(minCutoff: 1.2, beta: 20.0, dCutoff: 1.0)
        _ = filter.update(NPoint(x: 0.2, y: 0.3), at: 0)
        _ = filter.update(NPoint(x: 0.25, y: 0.35), at: dt)
        XCTAssertNil(filter.update(nil, at: 2 * dt))
        // 重置後第一筆 pass-through（兩軸皆 bit-精確）。
        let fresh = try XCTUnwrap(filter.update(NPoint(x: 0.8, y: 0.1), at: 3 * dt))
        XCTAssertEqual(fresh.x, 0.8)
        XCTAssertEqual(fresh.y, 0.1)
    }
}
