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
//    predict(dx, dy)：value ← value + (dx, dy)   （高頻，陀螺儀角速度換算）
//    correct(m)：     value ← w·m + (1−w)·value  （低頻，Vision 量測拉回，防漂）
//  dx/dy 的定義 =「標記在畫面上的 normalized 位移」（NormalizedFrame：
//  x 向右、y 向下），由呼叫端（CoachSession）用 FOV 換算好傳入。
//  Core 不懂 FOV / 裝置軸 / 前後鏡 — 角速度→畫面位移的全部符號推導
//  （相機右轉 ⇒ 世界景物左移 ⇒ 標記 x 減小…，以及 videoFieldOfView 是
//  「水平」視角、直立 portrait 顯示時對應畫面「垂直」方向的陷阱、
//  前鏡預覽鏡像的 x 再翻號）一律寫在呼叫端；本類只做座標空間內的純數學，
//  符號若反了在呼叫端翻正負號一行修，本類不動。
//  時間律：本類無內建時鐘、絕不讀 Date()；predict / correct 的節奏
//  （含「連續 predict 太久沒 correct」的處置）完全由呼叫端管理 —
//  與 OneEuroFilter / GuidanceTracker 同一可測性原則。
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
/// Vision correct（~15fps 互補濾波拉回）。讓標記「黏在世界上」：
/// 兩次 Vision 之間標記仍隨手機轉動即時滑動，Vision 一到再輕輕校正，
/// 不跳、不漂 — AR 感，不用 ARKit。
public final class GyroFusedPoint {

    /// 互補濾波量測權重 w ∈ [0, 1]：correct 時 value ← w·量測 + (1−w)·預測。
    /// 預設 0.35：Vision ~15fps 下約 3 筆量測收斂 72%+（誤差每筆 ×0.65），
    /// 校正肉眼看是「滑過去」而非「跳過去」；同時陀螺儀漂移被每筆量測
    /// 持續吃掉 35%，不會累積。init 夾到 [0, 1]（與 PointSmoother 同防禦）。
    public let measurementWeight: Double

    /// 目前融合值；nil = 尚無任何量測（不可憑空預測）。
    private var current: NPoint?

    /// 融合後的標記位置（可出界；出界處理見 AimGeometry）。
    public var value: NPoint? { current }

    public init(measurementWeight: Double = 0.35) {
        self.measurementWeight = min(max(measurementWeight, 0), 1)
    }

    /// 陀螺儀預測步：value ← value + (dx, dy)。
    /// dxNormalized / dyNormalized =「標記在畫面上的 normalized 位移」
    /// （呼叫端已完成 角位移(rad) / FOV(rad) 換算與符號推導 — 見檔頭）。
    /// value 為 nil（還沒有任何 Vision 量測）時靜默忽略：
    /// 沒有基準點，位移無從累加。
    public func predict(dxNormalized: Double, dyNormalized: Double) {
        guard let v = current else { return }
        current = NPoint(x: v.x + dxNormalized, y: v.y + dyNormalized)
    }

    /// Vision 修正步（互補濾波）：value ← w·measurement + (1−w)·value。
    /// 首筆（value == nil）pass-through 直接採用量測 —
    /// 不得從任何舊位置滑過去（與 OneEuroFilter / PointSmoother 同原則）。
    public func correct(_ measurement: NPoint) {
        guard let v = current else {
            current = measurement
            return
        }
        let w = measurementWeight
        current = NPoint(
            x: w * measurement.x + (1 - w) * v.x,
            y: w * measurement.y + (1 - w) * v.y
        )
    }

    /// 清空狀態（切鏡／前後翻轉／切模式／主體丟失逾時由呼叫端觸發）；
    /// 之後第一筆 correct 重新 pass-through。
    public func reset() {
        current = nil
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
