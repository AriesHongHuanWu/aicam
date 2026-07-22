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
//  規則（v0.4.0 擴充）：
//  e) 人像焦段：後鏡有臉、臉高 0.12–0.28（<0.12 = 人太小/太遠，跳過）、
//     顯示倍率 < 1.8x、主體距離（有值時）> 1.6m → 2x（人像壓縮）。
//     ai.zoom.enabled（預設 false）= 直接 rampZoom 代操（可還原）；
//     否則 ai.zoom.suggest（預設 true）= 建議 toast，AIAction 帶 apply 閉包
//     （toast 顯示「套用」鈕；按下才 rampZoom，之後轉為可還原 toast）。
//     自身 rate-limit ≥20s。顯示倍率 = camera.currentZoomFactor() / 主鏡(1x)
//     factor（實際 videoZoomFactor 鏡像；超廣角 virtual device 下
//     device factor ≠ 顯示倍率）。
//  f) 低光處置：histogram 中位亮度 < 0.18 持續 ≥3s →「光線不足」提示
//     （純 toast，不動參數）；若 bias > 0 先歸零（低光下正補償只會拉長快門
//     更晃 — 註：a 的逆光條件在中位 <0.18 時數學上不可能成立，臉亮度 ≥0
//     無法低於 median−0.18<0，兩規則不會互搶）。自身 rate-limit ≥30s。
//
//  節流：所有動作共用「任兩次動作間隔 ≥2.5s」的全域閘（c 另加自身 ≥4s、
//  e ≥20s、f ≥30s）；bias 值變化 < 0.15 EV 不動作（歸零收尾步例外 —
//  回到中性即結束介入）。e 的「建議」雖不動參數，仍佔全域閘與 toast slot
//  （避免建議 toast 被下一動作瞬間蓋掉、用戶來不及按「套用」）。
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
    /// v0.4.0：建議型動作的「套用」閉包。nil = 已執行的動作（toast 顯示「還原」）；
    /// 非 nil = 尚未執行的建議（toast 顯示「套用」）。MainActor 上建立、
    /// 由 toast 按鈕（MainActor）呼叫；不參與 Equatable（閉包不可比，
    /// 以 text+date 為身分 — date 每次動作都是新值，語意足夠）。
    let apply: (() -> Void)?

    init(text: String, date: Date, apply: (() -> Void)? = nil) {
        self.text = text
        self.date = date
        self.apply = apply
    }

    static func == (lhs: AIAction, rhs: AIAction) -> Bool {
        lhs.text == rhs.text && lhs.date == rhs.date
    }
}

@MainActor
@Observable
final class AIControlCenter {

    static let shared = AIControlCenter()

    /// 最新一次 AI 動作；nil = toast 不顯示。動作 5s / 建議（帶 apply）8s 自動清空（淡出）。
    private(set) var latestAction: AIAction?

    /// 相機接線（A4 於 RootView .task 設定）。weak：不影響 camera 生命週期。
    @ObservationIgnored weak var camera: CameraController?

    /// 「AI 代操」總開關（AppStorage key "ai.control.enabled"，預設 true —
    /// UserDefaults 無值時視為 true，不能用 bool(forKey:) 的預設 false）。
    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "ai.control.enabled") as? Bool) ?? true
    }

    /// 「AI 自動變焦」（key "ai.zoom.enabled"，預設 false — bool(forKey:) 即可）。
    private var isAutoZoomEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ai.zoom.enabled")
    }

    /// 「AI 變焦建議」（key "ai.zoom.suggest"，預設 true — 無值視為 true）。
    private var isZoomSuggestEnabled: Bool {
        (UserDefaults.standard.object(forKey: "ai.zoom.suggest") as? Bool) ?? true
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
    /// e) 人像焦段：臉高範圍、顯示倍率上限、主體距離下限（公尺）、自身間隔（秒）。
    private static let zoomFaceHeightMin = 0.12
    private static let zoomFaceHeightMax = 0.28
    private static let zoomMaxDisplayZoom = 1.8
    private static let zoomMinSubjectDistanceM = 1.6
    private static let zoomSuggestInterval = 20.0
    /// e) ramp 速率（2 的冪次／秒）：比手動選鏡（rate 5）慢，AI 介入更從容可辨。
    private static let zoomRampRate: Float = 3.0
    /// f) 低光：中位亮度門檻、持續秒數、自身間隔（秒）。
    private static let lowLightMedianThreshold = 0.18
    private static let lowLightDwell = 3.0
    private static let lowLightInterval = 30.0

    // MARK: - 內部狀態（MainActor；時間軸 = facts.timestamp）

    @ObservationIgnored private var lastActionAt: Double = -.greatestFiniteMagnitude
    @ObservationIgnored private var lastMeteringAt: Double = -.greatestFiniteMagnitude
    /// 最近一次 AI 設定的測光點（NormalizedFrame）；nil = 尚未鎖過（POI 在中心）。
    @ObservationIgnored private var lastMeteringPoint: NPoint?
    /// a、b 條件皆解除的起始時間戳；條件重現或 bias 歸零時清空。
    @ObservationIgnored private var clearedSince: Double?
    /// e) 上次變焦建議/代操時間戳（media clock）。
    @ObservationIgnored private var lastZoomSuggestAt: Double = -.greatestFiniteMagnitude
    /// f) 低光條件成立的起始時間戳；亮度回升時清空。
    @ObservationIgnored private var lowLightSince: Double?
    /// f) 上次低光提示時間戳。
    @ObservationIgnored private var lastLowLightAt: Double = -.greatestFiniteMagnitude
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
            lowLightSince = nil
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

        // f) 低光 dwell 計時（同樣獨立於動作節流）：中位亮度 <0.18 → 起算；
        // 回升或無直方圖 → 清零（缺數據不判低光，誠實原則）。
        let sceneMedian = facts.histogram.flatMap(Self.medianLuma)
        if let sceneMedian, sceneMedian < Self.lowLightMedianThreshold {
            if lowLightSince == nil { lowLightSince = now }
        } else {
            lowLightSince = nil
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

        // ---- f) 低光處置（v0.4.0；自身 ≥30s + 全域 ≥2.5s）----
        // 純提示為主；bias > 0 時先歸零（低光下正補償拉長快門更晃、雜訊更重）。
        // 與 a) 不互搶：中位 <0.18 時逆光條件（臉亮度 < 中位−0.18 < 0）數學上
        // 不可能成立，見檔頭規則注釋。
        if !actedThisTick,
           let since = lowLightSince, now - since >= Self.lowLightDwell,
           now - lastLowLightAt >= Self.lowLightInterval,
           now - lastActionAt >= Self.actionInterval {
            if bias > 0 {
                camera.applyExposureBias(0)
                undo = { [weak self] in
                    self?.camera?.applyExposureBias(bias)
                }
                clearedSince = nil  // bias 已歸零，d) 的歸零計時作廢
            } else {
                undo = nil  // 純提示，無可還原之事（toast 端 apply 亦為 nil → 顯示還原鈕，按了只清 toast）
            }
            lastLowLightAt = now
            lastActionAt = now
            actedThisTick = true
            show("AI：光線不足，拿穩手機")
        }

        // ---- e) 人像焦段（v0.4.0；自身 ≥20s + 全域 ≥2.5s；僅後鏡）----
        // 顯示倍率 = 實際 videoZoomFactor / 主鏡(1x) factor（超廣角 virtual
        // device 下 device factor 2.0 = 顯示 1x）；2x 目標 factor = 2 × 主鏡 factor。
        // 實際 factor 讀 camera.currentZoomFactor()（鏡像值）— 不可讀
        // currentLens.zoomFactor：rampZoom 到非焦段 factor（單鏡機 2x、
        // 三鏡 Pro 2x=4.0 的 tie case）後 currentLens 不變 → 顯示倍率恆讀
        // 1.0，已在 2x 仍每 20s 重複建議/重 ramp。
        // 建議模式雖不動參數，仍佔全域閘與 toast slot（檔頭注釋）。
        if !actedThisTick,
           !facts.isFrontCamera,
           isAutoZoomEnabled || isZoomSuggestEnabled,
           now - lastZoomSuggestAt >= Self.zoomSuggestInterval,
           now - lastActionAt >= Self.actionInterval,
           let face = primaryFace(facts),
           face.box.height >= Self.zoomFaceHeightMin,
           face.box.height <= Self.zoomFaceHeightMax,
           facts.subjectDistanceM.map({ $0 > Self.zoomMinSubjectDistanceM }) ?? true,
           let wideFactor = camera.lensOptions.first(where: { $0.label == "1x" })?.zoomFactor,
           wideFactor > 0,
           Double(camera.currentZoomFactor() / wideFactor) < Self.zoomMaxDisplayZoom {
            let targetFactor = 2.0 * wideFactor
            lastZoomSuggestAt = now
            lastActionAt = now
            actedThisTick = true
            if isAutoZoomEnabled {
                // 代操：直接 ramp；還原走 select(lens:)（恢復焦段 + LensBar 高亮
                // + onCameraReconfigured 通知，語意與手動選鏡一致）。
                let previousLens = camera.currentLens
                camera.rampZoom(to: targetFactor, rate: Self.zoomRampRate)
                undo = { [weak self] in
                    guard let previousLens else { return }
                    self?.camera?.select(lens: previousLens)
                }
                show("AI：切換 2x（人像壓縮）")
            } else {
                // 建議：不動參數，AIAction 帶 apply 閉包（toast 顯示「套用」）。
                // 按下才 ramp，並轉為可還原 toast；lastZoomSuggestAt 與
                // lastActionAt 皆以最近 evaluate 的 media 時鐘重置（apply 由
                // UI 觸發、無 facts 可拿）。lastActionAt 必須一併重置：建議
                // toast 可停留 8s，用戶按「套用」時距發出建議可能已超過全域閘
                // 2.5s — 不重置的話下一個 evaluate tick 其他規則（如 c 測光點）
                // 立刻動作，覆蓋剛轉為可還原的 2x toast 與 undo 閉包，
                // 用戶剛套用的變焦馬上失去還原路徑。
                undo = nil
                show("AI：建議切換 2x（人像壓縮）", apply: { [weak self] in
                    guard let self, let camera = self.camera else { return }
                    let previousLens = camera.currentLens
                    camera.rampZoom(to: targetFactor, rate: Self.zoomRampRate)
                    self.lastZoomSuggestAt = self.lastEvaluateAt
                    self.lastActionAt = self.lastEvaluateAt
                    self.undo = { [weak self] in
                        guard let previousLens else { return }
                        self?.camera?.select(lens: previousLens)
                    }
                    self.show("AI：切換 2x（人像壓縮）")
                })
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

    /// 發布動作並排自動清空（toast 淡出由 latestAction → nil 驅動）：
    /// 已執行動作 5s；建議（帶 apply）8s — 用戶要讀完再決定按「套用」，多給緩衝。
    private func show(_ text: String, apply: (() -> Void)? = nil) {
        latestAction = AIAction(text: text, date: Date(), apply: apply)
        clearTask?.cancel()
        let duration: Double = apply == nil ? 5 : 8
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
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
