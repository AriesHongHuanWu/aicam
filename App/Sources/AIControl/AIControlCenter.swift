//  AIControlCenter.swift
//  AICam — AI 代操中樞（A2 擁有；v0.3.0「AI 全面接管」契約 surface）。
//
//  角色：CoachSession 每次 publish FrameFacts 後呼叫 evaluate(facts:)（MainActor），
//  依規則自動代操曝光（bias / 測光點）；每次動作發布 latestAction，
//  AIControlToast 顯示並提供「還原」（undoLastAction）。
//
//  規則（v1；時間一律用 facts.timestamp = media clock，單調遞增）：
//  a) 逆光保臉：有臉且（臉亮度 − 場景中位亮度）< −0.18 → bias 往 +0.7 緩步
//     （每次 +0.35）。臉亮度 = 主臉（最大面積）左右半亮度平均；場景中位 =
//     LumaHistogram 累積 50% 落點 bin 中心。
//  b) 高光溢出：無臉且 highlightClippedFraction > 0.10 → bias 往 −0.3 緩步（每次 −0.3）。
//  c) 臉部測光點：主臉中心距上次測光點移動 > 0.12（首見臉視同已移動）→
//     setExposurePoint 鎖臉（此項自身 rate-limit ≥4s）。
//  d) 條件（a、b）皆解除且 bias ≠ 0 持續 ≥3s → bias 緩步歸零（每次 0.35，
//     餘量 ≤0.35 時直接落 0 收尾）。
//
//  節流：所有動作共用「任兩次動作間隔 ≥2.5s」的全域閘（c 另加自身 ≥4s）；
//  bias 值變化 < 0.15 EV 不動作（歸零收尾步例外 — 回到中性即結束介入）。
//
//  衝突策略（v1）：AI 只在教練模式動作 — evaluate 僅由 CoachSession publish 觸發，
//  其他模式沒有 facts 流；app 亦無手動曝光 UI，無用戶手動操作衝突面。
//  undoLastAction 後有 10s 冷靜期，避免 AI 立刻把還原的值蓋回去。
//
//  接線（整合者）：A4 於 RootView .task 設 AIControlCenter.shared.camera = camera；
//  CoachSession publish 尾端呼叫 AIControlCenter.shared.evaluate(facts:)。

import Foundation
import Observation
import AICamCore

/// AI 代操的一次動作（跨模組契約型別；AIControlToast 讀）。
struct AIAction: Equatable {
    let text: String
    let date: Date
}

@MainActor
@Observable
final class AIControlCenter {

    static let shared = AIControlCenter()

    /// 最新一次 AI 動作；nil = toast 不顯示。動作後 5s 自動清空（淡出）。
    private(set) var latestAction: AIAction?

    /// 相機接線（A4 於 RootView .task 設定）。weak：不影響 camera 生命週期。
    @ObservationIgnored weak var camera: CameraController?

    /// 「AI 代操」總開關（AppStorage key "ai.control.enabled"，預設 true —
    /// UserDefaults 無值時視為 true，不能用 bool(forKey:) 的預設 false）。
    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "ai.control.enabled") as? Bool) ?? true
    }

    // MARK: - 規則常數

    /// a) 臉亮度 − 場景中位亮度低於此值 = 逆光。
    private static let backlitDelta = -0.18
    private static let backlitTargetEV: Float = 0.7
    private static let backlitStepEV: Float = 0.35
    /// b) 高光裁切比例門檻與步長／目標。
    private static let highlightClipThreshold = 0.10
    private static let highlightStepEV: Float = 0.3
    private static let highlightTargetEV: Float = -0.3
    /// bias 值變化低於此值不動作（避免無感微調）。
    private static let minActionDeltaEV: Float = 0.15
    /// 全域動作間隔（秒）。
    private static let actionInterval = 2.5
    /// c) 測光點自身間隔（秒）與觸發移動距離（normalized）。
    private static let meteringInterval = 4.0
    private static let meteringMoveThreshold = 0.12
    /// d) 條件解除需持續此秒數才開始歸零；每步幅度。
    private static let restoreDwell = 3.0
    private static let restoreStepEV: Float = 0.35
    /// undo 後冷靜期（秒）：期間 evaluate 不動作。
    private static let undoCooldown = 10.0

    // MARK: - 內部狀態（MainActor；時間軸 = facts.timestamp）

    @ObservationIgnored private var lastActionAt: Double = -.greatestFiniteMagnitude
    @ObservationIgnored private var lastMeteringAt: Double = -.greatestFiniteMagnitude
    /// 最近一次 AI 設定的測光點（NormalizedFrame）；nil = 尚未鎖過（POI 在中心）。
    @ObservationIgnored private var lastMeteringPoint: NPoint?
    /// a、b 條件皆解除的起始時間戳；條件重現或 bias 歸零時清空。
    @ObservationIgnored private var clearedSince: Double?
    @ObservationIgnored private var suppressedUntil: Double = -.greatestFiniteMagnitude
    @ObservationIgnored private var lastEvaluateAt: Double = 0
    /// 前後鏡偵測（以 facts 流自偵測，不佔用 camera.onCameraReconfigured —
    /// 該 callback 是單一 slot、已被 CoachSession 使用）。
    @ObservationIgnored private var lastIsFront: Bool?
    /// 最後一次動作的還原閉包（恢復前值）。
    @ObservationIgnored private var undo: (() -> Void)?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    private init() {}

    // MARK: - 契約 API

    /// CoachSession 每次 publish 後呼叫（MainActor，~15fps）。enabled false 直接 return。
    func evaluate(facts: FrameFacts) {
        guard isEnabled, let camera else { return }
        let now = facts.timestamp
        lastEvaluateAt = now

        // 前後鏡切換：座標空間鏡像翻轉、裝置曝光已在重配時歸中性（bias 0 / POI 中心）
        // → 測光點記憶與歸零計時作廢，undo 也不再有意義（前值屬於舊裝置）。
        if let last = lastIsFront, last != facts.isFrontCamera {
            lastMeteringPoint = nil
            clearedSince = nil
            undo = nil
        }
        lastIsFront = facts.isFrontCamera

        guard now >= suppressedUntil else { return }

        let bias = camera.currentExposureBias()
        let backlit = isBacklit(facts)
        let highlightBlown = facts.faces.isEmpty
            && (facts.histogram?.highlightClippedFraction ?? 0) > Self.highlightClipThreshold

        // d) 的 dwell 計時獨立於動作節流：條件在 → 清零；條件解除且 bias ≠ 0 → 起算。
        if backlit || highlightBlown {
            clearedSince = nil
        } else if bias != 0 {
            if clearedSince == nil { clearedSince = now }
        } else {
            clearedSince = nil
        }

        // ---- bias 規則（a / b / d 互斥；全域 ≥2.5s 一動）----
        var actedThisTick = false
        if now - lastActionAt >= Self.actionInterval {
            if backlit {
                let next = min(bias + Self.backlitStepEV, Self.backlitTargetEV)
                if next - bias >= Self.minActionDeltaEV {
                    performBias(next, from: bias, text: "AI：EV +0.35（逆光保臉）", at: now)
                    actedThisTick = true
                }
            } else if highlightBlown {
                let next = max(bias - Self.highlightStepEV, Self.highlightTargetEV)
                if bias - next >= Self.minActionDeltaEV {
                    performBias(next, from: bias, text: "AI：EV −0.3（保高光）", at: now)
                    actedThisTick = true
                }
            } else if bias != 0, let since = clearedSince, now - since >= Self.restoreDwell {
                // 餘量 ≤ 一步 → 直接落 0 收尾（<0.15EV 規則的唯一例外：
                // 回到中性即結束 AI 介入，允許最後一小步）。
                let next: Float = abs(bias) <= Self.restoreStepEV
                    ? 0
                    : bias - (bias > 0 ? Self.restoreStepEV : -Self.restoreStepEV)
                performBias(next, from: bias, text: "AI：曝光還原", at: now)
                actedThisTick = true
                if next == 0 { clearedSince = nil }
            }
        }

        // ---- c) 臉部測光點（自身 ≥4s + 全域 ≥2.5s；本 tick 已有動作則下個 tick 再議）----
        if !actedThisTick,
           now - lastMeteringAt >= Self.meteringInterval,
           now - lastActionAt >= Self.actionInterval,
           let face = primaryFace(facts) {
            let center = face.box.center
            let moved = lastMeteringPoint.map {
                hypot(center.x - $0.x, center.y - $0.y) > Self.meteringMoveThreshold
            } ?? true
            if moved {
                let previous = lastMeteringPoint
                camera.setExposurePoint(normalizedX: center.x, y: center.y)
                lastMeteringPoint = center
                lastMeteringAt = now
                lastActionAt = now
                undo = { [weak self] in
                    // 恢復前值：之前鎖過的點；從未鎖過 = 回裝置預設中心點
                    let restore = previous ?? NPoint(x: 0.5, y: 0.5)
                    self?.camera?.setExposurePoint(normalizedX: restore.x, y: restore.y)
                    self?.lastMeteringPoint = previous
                }
                show("AI：測光鎖定臉部")
            }
        }
    }

    /// 還原最後一次 AI 動作（bias 恢復前值 / 測光點恢復前點），並進入 10s 冷靜期。
    func undoLastAction() {
        guard undo != nil || latestAction != nil else { return }
        undo?()
        undo = nil
        clearTask?.cancel()
        latestAction = nil
        clearedSince = nil
        // 冷靜期基準 = 最近一次 evaluate 的 media 時鐘（undo 由 UI 觸發、無 facts 可拿；
        // 下一帧的 timestamp 必然 ≥ lastEvaluateAt，冷靜期語意正確）。
        suppressedUntil = lastEvaluateAt + Self.undoCooldown
    }

    // MARK: - 私有

    /// 套 bias、記還原閉包、發 toast（呼叫端已通過節流與 min-delta 檢查）。
    private func performBias(_ next: Float, from previous: Float, text: String, at now: Double) {
        camera?.applyExposureBias(next)
        lastActionAt = now
        undo = { [weak self] in
            self?.camera?.applyExposureBias(previous)
        }
        show(text)
    }

    /// 發布動作並排 5s 自動清空（toast 淡出由 latestAction → nil 驅動）。
    private func show(_ text: String) {
        latestAction = AIAction(text: text, date: Date())
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.latestAction = nil
        }
    }

    /// a) 逆光判定：主臉亮度 − 場景中位亮度 < −0.18。缺任一數據 = 不判逆光（誠實原則）。
    private func isBacklit(_ facts: FrameFacts) -> Bool {
        guard let face = primaryFace(facts),
              let faceLuma = faceBrightness(face),
              let histogram = facts.histogram,
              let median = Self.medianLuma(histogram)
        else { return false }
        return faceLuma - median < Self.backlitDelta
    }

    /// 主臉 = 最大面積臉。
    private func primaryFace(_ facts: FrameFacts) -> FaceFact? {
        facts.faces.max(by: { $0.box.area < $1.box.area })
    }

    /// 臉亮度 = 左右半亮度平均（只有單邊時用單邊；皆缺 = nil）。
    private func faceBrightness(_ face: FaceFact) -> Double? {
        switch (face.leftBrightness, face.rightBrightness) {
        case let (left?, right?): return (left + right) / 2
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }

    /// 場景中位亮度：64-bin 直方圖累積過半的 bin 中心（0…1）；空直方圖 = nil。
    private static func medianLuma(_ histogram: LumaHistogram) -> Double? {
        let bins = histogram.bins
        guard !bins.isEmpty else { return nil }
        let total = bins.reduce(0, +)
        guard total > 0 else { return nil }
        var cumulative = 0.0
        for (index, weight) in bins.enumerated() {
            cumulative += weight
            if cumulative >= total / 2 {
                return (Double(index) + 0.5) / Double(bins.count)
            }
        }
        return nil
    }
}
