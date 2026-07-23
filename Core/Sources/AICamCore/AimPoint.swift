//  AimPoint.swift
//  AICamCore — v0.4.0 對準點導引（Apple 測距儀式）的數學地基。
//
//  背景（真機回饋）：舊「點對環」模式是反向控制 — 導引畫在「主體」上，
//  用戶手往右轉、主體點在畫面上往左跑，動的方向與手相反，根本對不準。
//  全面改為正向控制：螢幕中央固定準星 + 世界標記點 P。用戶往標記轉，
//  標記自然滑向準星；標記進準星的那一刻 = 主體剛好滑到目標構圖位置。
//
//  ── 標記重投影推導（本檔最重要的注釋，錯這裡整個交互反向）──
//  已知：主體錨點 A（當帧量測）、構圖目標 T（StickyTargetPlanner 凍結值）、
//  準星 C = (0.5, 0.5)。目的 =「讓主體從 A 移到 T」。
//  (1) 主體在畫面上需要的位移 Δ = T − A。
//  (2) 相機純旋轉（小角度近似）時，所有世界點在畫面上的位移近似相同：
//      讓主體移動 Δ 的那次轉動，也會讓「任何」世界點在畫面上移動 Δ。
//  (3) 我們要一個世界標記 P，滿足「P 落進準星」⇔「構圖完成」。
//      構圖完成的那一刻 P 必須位於 C，而這段轉動讓 P 移了 Δ：
//        P + Δ = C  ⇒  P = C − Δ = C − (T − A) = C + (A − T)。
//  (4) 正向控制驗證：主體該右移（T 在 A 右）⇒ 相機該左轉 ⇒ P 在 C 左側
//      ⇒ 用戶朝標記（左）轉 ⇒ 世界景物在畫面中右移 ⇒ 標記右移滑進準星，
//      同時主體右移滑到 T。手往哪轉、標記就往準星走 — 正向，與手同向。
//
//  餵入原則：anchor 用「未平滑或輕平滑」的當帧量測（延遲越低越好，
//  GyroFusedPoint 本身就是平滑器，疊兩層平滑只會多延遲）；
//  target 必須用 StickyTargetPlanner 的凍結值 — 用當帧重算的 target
//  會回到「追會跑的靶」的老 bug。
//
//  ── GyroFusedPoint（陀螺儀預測 + Vision 修正的互補濾波）──
//  Vision ~15fps 太慢，標記逐帧跳；陀螺儀 ~100Hz 平滑但會漂。融合：
//    predict(dx, dy, at t)：  value ← value + (gainX·dx, gainY·dy)（高頻）
//    correct(m, measuredAt)： value ← w·m′ + (1−w)·value（低頻，延遲補償拉回）
//  dx/dy 的定義 =「標記在畫面上的 normalized 位移」（NormalizedFrame：
//  x 向右、y 向下），由呼叫端（CoachSession）用 FOV 換算好傳入。
//  Core 不懂 FOV / 裝置軸 / 前後鏡 — 角速度→畫面位移的全部符號推導
//  （相機右轉 ⇒ 世界景物左移 ⇒ 標記 x 減小…，以及 videoFieldOfView 是
//  「水平」視角、直立 portrait 顯示時對應畫面「垂直」方向的陷阱、
//  前鏡預覽鏡像的 x 再翻號）一律寫在呼叫端；本類只做座標空間內的純數學。
//  時間律：本類無內建時鐘、絕不讀 Date()；predict / correct 帶入的時間
//  一律是「呼叫端統一時基」（秒），本類只比大小、取差值，不解讀絕對值 —
//  與 OneEuroFilter / GuidanceTracker 同一可測性原則。
//
//  ── v0.5.1 緊急修復：「標記跟著移動方向飄走」三共症一次免疫 ──
//  真機回饋：用鏡頭對準星時，標記一直跟著手移動的方向跑。三個嫌疑：
//  (a) 某軸陀螺儀符號實機相反（呼叫端紙上推導自洽但未實證）；
//  (b) 陀螺儀增益過低（FOV/變焦換算殘差 ⇒ 標記跟不上景物，視覺上
//      像黏著螢幕跟手走）；
//  (c) Vision 量測延遲 100–200ms：快速移動時 correct 把融合值往
//      「舊帧的位置」（= 用戶移動方向的後方）拖回；15fps × w=0.35 的
//      回拖速度與陀螺儀前進速度同量級 ⇒ 移動中標記像被拖著走。
//  對策（全部在本類，呼叫端只需改傳時間戳）：
//  (c) 延遲補償：predict 推入 (time, 原始位移累計) 的回溯環形緩衝
//      （0.6s）；correct(m, measuredAt:) 用緩衝把舊帧量測「前推」到
//      現在再融合 — innovation 對齊同帧，舊量測不再往移動反方向拖。
//  (a)(b) 逐軸線上 AutoGain：比對「兩次 correct 間的量測位移」與
//      「同期陀螺儀原始位移」，線上收斂出每軸增益（可為負 = 自動翻號）。
//      符號反 ⇒ gain 收斂到負值；增益低 ⇒ gain 收斂 >1 補償 — 自癒，
//      並由呼叫端以 gainX/gainY 讀出持久化、seedGains 跨 session 恢復。
//
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

// MARK: - 標記重投影

public enum AimPointSolver {

    /// 準星位置 = 畫面中心（固定，UI 與數學共用同一常數）。
    public static let crosshair = NPoint(x: 0.5, y: 0.5)

    /// 標記重投影：P = C + (anchor − target)（推導見檔頭）。
    /// 回傳值「允許出界」（< 0 或 > 1）— 出界的顯示夾取與邊緣箭頭
    /// 交給 AimGeometry.state(for:)，本函式不夾。
    /// 附帶語意：|marker − C| = |anchor − target|，
    /// 所以 aimDistance 可直接沿用既有 GuidanceTracker 的距離門檻。
    public static func marker(anchor: NPoint, target: NPoint) -> NPoint {
        NPoint(
            x: crosshair.x + (anchor.x - target.x),
            y: crosshair.y + (anchor.y - target.y)
        )
    }
}

// MARK: - 陀螺儀／Vision 互補濾波

/// 世界標記點的高頻融合器：陀螺儀 predict（~100Hz 累加位移）+
/// Vision correct（~15fps 延遲補償互補濾波拉回）。讓標記「黏在世界上」：
/// 兩次 Vision 之間標記仍隨手機轉動即時滑動，Vision 一到再輕輕校正，
/// 不跳、不漂、不回拖 — AR 感，不用 ARKit。
/// v0.5.1：延遲補償（回溯環形緩衝）＋逐軸線上增益/符號自動校準
/// （設計動機見檔頭「v0.5.1 緊急修復」）。
public final class GyroFusedPoint {

    // MARK: 調參常數（v0.5.1 全集中此處）

    /// 回溯環形緩衝保留窗（秒）：Vision 延遲實測 100–200ms，0.6s 給 3 倍餘裕。
    private static let bufferWindow: Double = 0.6

    /// 緩衝硬上限筆數：100Hz × 0.6s = 60 筆為常態，256 可容納到 ~426Hz 的
    /// 極端呼叫端；超過丟最舊 — 記憶體 O(1) 上界（256 × 24B ≈ 6KB）。
    private static let bufferCapacity = 256

    /// AutoGain 更新門檻：兩次 correct 間 |陀螺儀原始位移和| ≤ 0.008
    /// 視為「沒在動」— 靜止手抖 + Vision 量測抖動算出的比值全是雜訊，
    /// 不准污染增益（「嚴格 >」才更新）。
    private static let autoGainMinRawSum: Double = 0.008

    /// 目標比 r 與增益的共同 clamp ±2.5：FOV 換算殘差 + 符號反轉的合理
    /// 範圍之內；更大的比值只可能是量測跳點（遮擋/誤偵測），夾掉防污染。
    private static let gainClamp: Double = 2.5

    /// 增益學習率：每筆 correct 向目標比 r 靠 15% —
    /// 15fps 下約 20 筆（≈1.3s）收斂 96%（0.85²⁰ ≈ 0.039）：夠快自癒、夠慢抗噪。
    private static let gainLearningRate: Double = 0.15

    /// 互補濾波量測權重 w ∈ [0, 1]：correct 時 value ← w·量測′ + (1−w)·預測。
    /// 預設 0.35：Vision ~15fps 下約 3 筆量測收斂 72%+（誤差每筆 ×0.65），
    /// 校正肉眼看是「滑過去」而非「跳過去」；同時陀螺儀漂移被每筆量測
    /// 持續吃掉 35%，不會累積。init 夾到 [0, 1]（與 PointSmoother 同防禦）。
    public let measurementWeight: Double

    // MARK: 狀態

    /// 目前融合值；nil = 尚無任何量測（不可憑空預測）。
    private var current: NPoint?

    /// 融合後的標記位置（可出界；出界處理見 AimGeometry）。
    public var value: NPoint? { current }

    /// 逐軸線上增益（起始 1.0；可為負 = 符號自動翻正）。reset「不清」—
    /// 增益是學到的「裝置級事實」（某軸符號 / FOV 換算殘差），切鏡換景
    /// 不改變裝置；跨 session 由呼叫端持久化後用 seedGains 恢復。
    public private(set) var gainX: Double = 1.0
    public private(set) var gainY: Double = 1.0

    /// 陀螺儀「原始」位移累計（未乘增益；緩衝樣本與 AutoGain 共用基準）。
    private var cumRawX: Double = 0
    private var cumRawY: Double = 0

    /// 回溯環形緩衝樣本：predict 當下的 (time, 原始位移累計)，時間遞增。
    private struct RawSample {
        var time: Double
        var cumRawX: Double
        var cumRawY: Double
    }
    private var samples: [RawSample] = []

    /// 最近一次 predict 的時間（相容版 correct 以它視為 frameTime）。
    private var lastPredictTime: Double?

    /// AutoGain 基準：上一筆 correct 的量測值與當時的原始位移累計。
    /// reset 時清除（規格：上次量測基準不得跨 reset 殘留）。
    private var lastMeasurement: NPoint?
    private var lastCorrectCumRawX: Double = 0
    private var lastCorrectCumRawY: Double = 0

    public init(measurementWeight: Double = 0.35) {
        self.measurementWeight = min(max(measurementWeight, 0), 1)
        samples.reserveCapacity(64)
    }

    // MARK: 預測（陀螺儀 ~100Hz）

    /// 陀螺儀預測步：value ← value + (gainX·dx, gainY·dy)。
    /// dxNormalized / dyNormalized =「標記在畫面上的 normalized 原始位移」
    /// （呼叫端已完成 角位移(rad) / FOV(rad) 換算與符號推導 — 見檔頭；
    /// 換算殘差與符號錯誤由 AutoGain 線上吸收）。
    /// time = 呼叫端統一時基（秒），必須與 correct(measuredAt:) 同一時基、
    /// 「嚴格」遞增（同值 / 回退未定義：兩筆 predict 同 time 時，相容版
    /// correct 的回退查詢會取到第一筆樣本 ⇒ 回退量 ≠ 0，bit-exact 相容
    /// 保證不成立；現行唯一呼叫端有 dt > 0 guard，實際不可達）。
    /// value 為 nil（還沒有任何 Vision 量測）時靜默忽略：
    /// 沒有基準點，位移無從累加（緩衝與累計也不推 — 不留任何殘跡）。
    public func predict(dxNormalized: Double, dyNormalized: Double, at time: Double) {
        guard let v = current else { return }
        cumRawX += dxNormalized
        cumRawY += dyNormalized
        // 有效位移 = 原始位移 × 逐軸增益（gain 為負 = 翻號自癒）。
        current = NPoint(
            x: v.x + dxNormalized * gainX,
            y: v.y + dyNormalized * gainY
        )
        lastPredictTime = time
        samples.append(RawSample(time: time, cumRawX: cumRawX, cumRawY: cumRawY))
        // 剪枝：只留最近 bufferWindow 秒，再套硬上限（先進先出）。
        // removeFirst(k) 單次 O(n)，但每筆 predict 平均只剪 ~1 筆，攤還 O(1)。
        let cutoff = time - Self.bufferWindow
        var drop = 0
        while drop < samples.count, samples[drop].time < cutoff {
            drop += 1
        }
        if samples.count - drop > Self.bufferCapacity {
            drop = samples.count - Self.bufferCapacity
        }
        if drop > 0 {
            samples.removeFirst(drop)
        }
    }

    // MARK: 修正（Vision ~15fps）

    /// 相容版：以「最近一次 predict 的時間」視為 frameTime（= 視量測為
    /// 零延遲）⇒ 回退量恰為 0，融合數值與 v0.4.0 完全一致（bit-exact，
    /// 見 correct(_:measuredAt:) 步驟 (2) 的公式形式注釋）；從未 predict
    /// 過時傳 −∞ ⇒ 同樣走回退 0 路徑。
    public func correct(_ measurement: NPoint) {
        correct(measurement, measuredAt: lastPredictTime ?? -Double.infinity)
    }

    /// 延遲補償版：measurement 是 frameTime（呼叫端統一時基，秒）那一帧
    /// 算出來的位置 — Vision 管線耗時 100–200ms，送到這裡時手機早又轉了
    /// 一段。步驟：
    /// (1) 從環形緩衝查「frameTime 之後」的原始位移：取 time ≥ frameTime
    ///     的最近（最舊）樣本，回退量 = 目前累計 − 該樣本累計（線性插值
    ///     省略 — 樣本間距 ~10ms，誤差遠小於 Vision 量測噪聲）。
    /// (2) 量測前推 m′ = m + 回退原始位移 × gain，再走互補濾波
    ///     value ← w·m′ + (1−w)·value。與規格式
    ///     value ← value + w·(m − valueAt(frameTime)) 代數同義
    ///     （valueAt = value − 回退有效位移）；取 m′ 形式是為了回退 = 0 時
    ///     與 v0.4.0 的 w·m + (1−w)·v 逐位一致 — 相容行為由既有測試鎖死。
    /// (3) AutoGain 逐軸更新（見 updatedGain）。
    /// frameTime 早於緩衝最舊樣本（量測老過 0.6s 窗）⇒ 退化為相容版
    /// 行為（回退 0）。
    /// 首筆（value == nil）pass-through 直接採用量測 —
    /// 不得從任何舊位置滑過去（與 OneEuroFilter / PointSmoother 同原則）。
    public func correct(_ measurement: NPoint, measuredAt frameTime: Double) {
        guard let v = current else {
            current = measurement
            lastMeasurement = measurement   // 立 AutoGain 基準（首筆不學習）
            lastCorrectCumRawX = cumRawX
            lastCorrectCumRawY = cumRawY
            return
        }

        // (1) 回退量查詢：frameTime 之後的「原始」位移。
        var rollbackRawX = 0.0
        var rollbackRawY = 0.0
        if let oldest = samples.first, frameTime >= oldest.time {
            // 線性掃描第一筆 time ≥ frameTime（樣本時間單調遞增）。
            // n ≤ 60（100Hz × 0.6s），15fps 修正下成本可忽略。
            for sample in samples where sample.time >= frameTime {
                rollbackRawX = cumRawX - sample.cumRawX
                rollbackRawY = cumRawY - sample.cumRawY
                break
            }
            // 掃不到（frameTime 晚於最新樣本）⇒ 量測比 predict 還新 ⇒ 回退 0。
        }
        // else：frameTime 早於最舊樣本（或緩衝空）⇒ 退化為相容版（回退 0）。

        // (2) 前推量測 + 互補濾波。回退用「目前」增益近似回退段的歷史增益 —
        //     增益每筆 correct 最多動 15%，0.2s 內漂移可忽略。
        let mx = measurement.x + rollbackRawX * gainX
        let my = measurement.y + rollbackRawY * gainY
        let w = measurementWeight
        current = NPoint(
            x: w * mx + (1 - w) * v.x,
            y: w * my + (1 - w) * v.y
        )

        // (3) AutoGain（逐軸）：用「原始」量測（非 m′）與「原始」位移累計 —
        //     前後兩筆量測同樣延遲，相減後延遲自然消掉，不需補償。
        if let last = lastMeasurement {
            gainX = Self.updatedGain(
                gainX,
                rawSum: cumRawX - lastCorrectCumRawX,
                measDelta: measurement.x - last.x
            )
            gainY = Self.updatedGain(
                gainY,
                rawSum: cumRawY - lastCorrectCumRawY,
                measDelta: measurement.y - last.y
            )
        }
        lastMeasurement = measurement
        lastCorrectCumRawX = cumRawX
        lastCorrectCumRawY = cumRawY
    }

    /// AutoGain 單軸更新：目標比 r = 量測位移 / 陀螺儀原始位移，
    /// gain ← gain + 0.15 × (r − gain)，r 與 gain 恆夾 [−2.5, 2.5]。
    /// 自癒語意：某軸符號實機相反 ⇒ r 恆負 ⇒ gain 收斂到負值 = 自動翻號；
    /// FOV/變焦換算殘差 ⇒ r ≠ 1 ⇒ gain 收斂到補償倍率。
    private static func updatedGain(
        _ gain: Double,
        rawSum: Double,
        measDelta: Double
    ) -> Double {
        // 靜止/微動不學：|rawSum| ≤ 0.008 時比值全是雜訊（嚴格 > 才更新）。
        guard abs(rawSum) > autoGainMinRawSum else { return gain }
        let r = min(max(measDelta / rawSum, -gainClamp), gainClamp)
        let next = gain + gainLearningRate * (r - gain)
        return min(max(next, -gainClamp), gainClamp)
    }

    // MARK: 增益持久化 / 清空

    /// 持久化恢復：呼叫端把上個 session 學到的增益種回來，開場即免疫、
    /// 不用重學。夾到 [−2.5, 2.5]（與線上學習同界）；非有限值（損毀的
    /// 持久化資料）整組拒收、保持現值。不動 value / 緩衝 / 量測基準。
    public func seedGains(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        gainX = min(max(x, -Self.gainClamp), Self.gainClamp)
        gainY = min(max(y, -Self.gainClamp), Self.gainClamp)
    }

    /// 只清 AutoGain 量測基準（lastMeasurement / 上次 correct 的原始位移累計），
    /// 「不動」value / 環形緩衝 / 增益 — 給呼叫端在「量測 anchor 定義跳變、但
    /// target 未變」時用（例：群組模式臉數跨 2 邊緣，union 中心跳變）。
    /// 效果 = 下一筆 correct 跳過一次增益學習（if let lastMeasurement 不成立）、
    /// 學習基準重立；融合 value 照常修正，標記連續性不受影響。
    /// （anchor 跳變若不隔離：跳變全額進 measDelta，最壞單筆可把 gain 拉動
    /// 0.15 × (2.5 − (−2.5)) = 0.75 — 雖 ~5 筆正常 correct 後自癒
    /// （0.85⁵ ≈ 0.44 殘留），仍屬可避免的污染。）
    public func invalidateGainBaseline() {
        lastMeasurement = nil
        lastCorrectCumRawX = 0
        lastCorrectCumRawY = 0
    }

    /// 清空 value / 環形緩衝 / AutoGain 量測基準（切鏡、前後翻轉、切模式、
    /// 主體丟失逾時由呼叫端觸發）；之後第一筆 correct 重新 pass-through。
    /// 「不清」增益 — 理由見 gainX 注釋；要一併清增益 = reset() + seedGains(x: 1, y: 1)。
    public func reset() {
        current = nil
        samples.removeAll(keepingCapacity: true)
        lastPredictTime = nil
        cumRawX = 0
        cumRawY = 0
        lastMeasurement = nil
        lastCorrectCumRawX = 0
        lastCorrectCumRawY = 0
    }
}

// MARK: - 顯示幾何（夾取 + 出界指示）

/// 標記的顯示狀態。marker 是「真實」融合位置（可出界）；
/// UI 一律畫在 clamped；isOffscreen 時另在 clamped 處畫指向
/// offscreenDirection 的邊緣箭頭（= 用戶該往哪轉）。
public struct AimState: Equatable, Sendable {
    /// 融合後的原始標記位置（NormalizedFrame，可出界）。
    public var marker: NPoint
    /// 夾進顯示安全範圍 [0.06, 0.94] 的顯示位置（標記圖示不貼死畫面邊）。
    public var clamped: NPoint
    /// 原始 marker 是否超出畫面 [0, 1]（嚴格 < 0 或 > 1 才算出界；
    /// 0.94…1.0 之間只被夾顯示位置、仍算畫面內，不畫出界箭頭）。
    public var isOffscreen: Bool
    /// 出界時 = normalize(marker − clamped)：從顯示位置指向真實標記的
    /// 單位向量（即出界方向 = 用戶該轉的方向）；畫面內時 nil。
    public var offscreenDirection: NPoint?

    public init(
        marker: NPoint,
        clamped: NPoint,
        isOffscreen: Bool,
        offscreenDirection: NPoint? = nil
    ) {
        self.marker = marker
        self.clamped = clamped
        self.isOffscreen = isOffscreen
        self.offscreenDirection = offscreenDirection
    }
}

public enum AimGeometry {

    /// 顯示夾取範圍（顯示專用；與 TargetSolver.safeArea 0.08…0.92 是
    /// 不同用途的另一組常數，勿混用）。
    public static let displayMin = 0.06
    public static let displayMax = 0.94

    /// 由原始 marker 算出顯示狀態（逐軸 clamp；出界判定與方向見 AimState 注釋）。
    public static func state(for marker: NPoint) -> AimState {
        let clamped = NPoint(
            x: min(max(marker.x, displayMin), displayMax),
            y: min(max(marker.y, displayMin), displayMax)
        )
        let isOffscreen = marker.x < 0 || marker.x > 1 || marker.y < 0 || marker.y > 1
        var direction: NPoint?
        if isOffscreen {
            let dx = marker.x - clamped.x
            let dy = marker.y - clamped.y
            let length = (dx * dx + dy * dy).squareRoot()
            // 出界 ⇒ 至少一軸 |marker − clamped| > 1 − displayMax = 0.06
            // ⇒ length > 0，除零不可能；1e-9 僅為浮點防禦（防禦分支不可達，
            // 可達時寧可回 nil 也不回 NaN 向量）。
            if length > 1e-9 {
                direction = NPoint(x: dx / length, y: dy / length)
            }
        }
        return AimState(
            marker: marker,
            clamped: clamped,
            isOffscreen: isOffscreen,
            offscreenDirection: direction
        )
    }
}
