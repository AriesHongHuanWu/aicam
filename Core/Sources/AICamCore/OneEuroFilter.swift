//  OneEuroFilter.swift
//  AICamCore — One Euro Filter（Casiez, Roussel & Vogel, CHI 2012）：主體錨點抗飄移平滑。
//
//  問題背景（真機回饋）：對齊目標環時錨點高頻抖動、固定 α 的 EMA 又整體拖延遲
//  →「一直飄、很慢」。One Euro = 截止頻率隨速度自適應的一階低通：
//    低速（對齊微調）→ 截止低 → 強力濾除手抖；
//    高速（重新構圖）→ 截止隨速度線性升高 → 幾乎零延遲跟上。
//
//  每筆樣本的計算（時間一律由呼叫端注入，絕不讀 Date()）：
//    dt    = clamp(time − lastTime, 1/120 … 1)   // 取樣頻率夾在 1…120 Hz
//    ẋ     = (x − lastRaw) / dt                  // 原始速度（對「原始值」差分，同原論文實作）
//    ẋ̂     = lowpass(ẋ, α(dCutoff, dt))          // 速度再低通（防速度雜訊把截止打高）
//    fc    = minCutoff + beta × |ẋ̂|              // 自適應截止頻率
//    x̂     = lowpass(x, α(fc, dt))               // 位置低通
//  其中一階 IIR：lowpass(v) = α·v + (1−α)·prev，α(fc, dt) = r/(r+1)、r = 2π·fc·dt
//  （等價於教科書式 α = 1/(1 + τ/dt)、τ = 1/(2π·fc)）。
//
//  預設參數推導（NormalizedFrame 座標 0…1；速度單位 =「畫面/秒」，beta 必須配這個尺度）：
//  - 手持瞄準抖動：幅度約 0.2–0.5% 畫面、頻率 3–10 Hz；刻意構圖移動約 0.2–1 畫面/秒。
//  - minCutoff 1.2 Hz：靜止時截止 1.2 Hz（30fps 下 α ≈ 0.20，時間常數約 5 帧），
//    把 3–10 Hz 手抖大幅衰減，又不至於慢速微調時黏住不動。
//  - beta 20：截止隨速度升高 — v=0.05 畫面/秒（慢速微調）→ fc = 2.2 Hz（α≈0.32）；
//    v=0.3 → fc = 7.2 Hz（α≈0.60）；v=1.0（快速重構圖）→ fc = 21.2 Hz（α≈0.82，幾乎即時）。
//  - dCutoff 1.0 Hz：速度估計本身 1 Hz 低通，抑制逐帧差分放大的觀測雜訊。
//
//  nil 輸入 = 主體消失 → 重置內部狀態並回 nil（主體重現後第一筆 pass-through，
//  不得從舊位置滑過去 — 與 PointSmoother 同原則）。
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

/// 1D One Euro Filter 核心。x/y 各用一顆，由 OneEuroFilter2D 包裝。
public final class OneEuroFilter {

    public let minCutoff: Double
    public let beta: Double
    public let dCutoff: Double

    /// 相鄰 timestamp 推得的頻率 clamp 範圍（Hz）。
    static let minFrequencyHz = 1.0
    static let maxFrequencyHz = 120.0

    /// 上一筆「原始」輸入（速度差分用，同原論文實作對 raw 差分）。
    private var lastRaw: Double?
    /// 上一筆濾波後輸出。
    private var lastFiltered: Double?
    /// 上一筆濾波後速度（首筆為 0）。
    private var lastDerivative: Double = 0
    private var lastTime: Double?

    public init(minCutoff: Double = 1.2, beta: Double = 20.0, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    /// 餵入一筆樣本；nil = 重置內部狀態並回 nil。
    public func update(_ x: Double?, at time: Double) -> Double? {
        guard let x = x else {
            reset()
            return nil
        }
        guard let lastRaw = lastRaw, let lastFiltered = lastFiltered, let lastTime = lastTime else {
            // 第一筆 pass-through：無 dt 可推頻率，也無前值可濾。
            self.lastRaw = x
            self.lastFiltered = x
            self.lastDerivative = 0
            self.lastTime = time
            return x
        }
        // 頻率由相鄰 timestamp 推得，clamp 1…120 Hz ⇔ dt 夾在 1/120…1 秒。
        // 亂序/重複 timestamp（dt ≤ 0）也會被夾到 1/120，不會產生 NaN 或負 α。
        let dt = min(max(time - lastTime, 1.0 / Self.maxFrequencyHz), 1.0 / Self.minFrequencyHz)
        let rawDerivative = (x - lastRaw) / dt
        let derivative = Self.lowpass(
            rawDerivative, previous: lastDerivative, alpha: Self.alpha(cutoff: dCutoff, dt: dt)
        )
        let cutoff = minCutoff + beta * abs(derivative)
        let filtered = Self.lowpass(
            x, previous: lastFiltered, alpha: Self.alpha(cutoff: cutoff, dt: dt)
        )
        self.lastRaw = x
        self.lastFiltered = filtered
        self.lastDerivative = derivative
        self.lastTime = time
        return filtered
    }

    /// 清空內部狀態（下一筆視同第一筆 pass-through）。
    public func reset() {
        lastRaw = nil
        lastFiltered = nil
        lastDerivative = 0
        lastTime = nil
    }

    // MARK: - 數學

    /// α(fc, dt) = r/(r+1)，r = 2π·fc·dt。fc、dt 皆 > 0 時 α ∈ (0, 1)。
    static func alpha(cutoff: Double, dt: Double) -> Double {
        let r = 2 * Double.pi * cutoff * dt
        return r / (r + 1)
    }

    /// 一階 IIR：α·x + (1−α)·prev。
    static func lowpass(_ x: Double, previous: Double, alpha: Double) -> Double {
        alpha * x + (1 - alpha) * previous
    }
}

/// NPoint 包裝：x/y 兩軸各自獨立濾波（共用同一組參數與注入時間）。
public final class OneEuroFilter2D {

    private let filterX: OneEuroFilter
    private let filterY: OneEuroFilter

    public init(minCutoff: Double = 1.2, beta: Double = 20.0, dCutoff: Double = 1.0) {
        filterX = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        filterY = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }

    /// 餵入一點；nil = 主體消失 → 重置兩軸並回 nil。
    public func update(_ p: NPoint?, at time: Double) -> NPoint? {
        guard let p = p else {
            reset()
            return nil
        }
        // 非 nil 輸入下兩軸必回非 nil；guard 僅為防禦性寫法。
        guard let x = filterX.update(p.x, at: time),
              let y = filterY.update(p.y, at: time) else {
            return nil
        }
        return NPoint(x: x, y: y)
    }

    public func reset() {
        filterX.reset()
        filterY.reset()
    }
}
