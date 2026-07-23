//  AttitudeMarker.swift
//  AICamCore — v0.6.0 姿態主導標記（attitude-locked marker）的數學地基。
//
//  ── 背景（四輪真機回饋的根本病因）──
//  舊路徑的標記每帧從「主體即時偵測位置 A」重算（P = C + A − T）：
//  主體晃動、偵測抖動、anchor 切換全部直接搖標記 — 相機運動補償
//  （GyroFusedPoint）與延遲補償都救不了「主體本身在動」。
//  新架構（判斷一下 → 固定一個點 → 讓使用者移動去符合）：
//  (1) 承諾瞬間記錄裝置姿態 q_commit 與當下畫面偏移 (A − T)，
//      合成「目標姿態」q_goal（goalQuat）；
//  (2) 之後標記位置 = 純由 current 對 goal 的旋轉差投影（marker）—
//      100Hz、零延遲、零主體耦合：主體怎麼晃標記都不動；
//  (3) Vision 降為慢速覆核（SubjectMoveDetector 判定主體真的走位）
//      → 以 GoalEaser 用 0.3s ease 平滑更新 q_goal（滑移、永不瞬移）。
//  App 端的 GyroFusedPoint 融合路徑由本檔取代（該檔與測試保留 —
//  Core 契約仍在，App 不再使用）；姿態是絕對量，不再需要增益自動校準。
//
//  ── 四元數慣例 ──
//  Hamilton 乘法、右手座標、主動旋轉：單位四元數 q 對向量 v 的作用
//  v′ = q ⊗ (v, 0) ⊗ q*，語意 =「把裝置座標中的向量轉進參考座標」。
//  CMDeviceMotion.attitude.quaternion 同慣例（參考系 xArbitraryZVertical —
//  不需羅盤；其任意 yaw 基準在 marker 的相對旋轉 conj(current) ⊗ goal
//  中抵銷，不影響結果，測試以「閉環與 commit 姿態無關」鎖死）。
//  App 端把 CMQuaternion 的 x/y/z/w 原樣餵入即可 — Core 只收純數字，
//  避開 CMAttitude API 風險（Linux CI 必須可測）。
//  繞單位軸 u 轉角 θ 的四元數 = (sin(θ/2)·u, cos(θ/2))（注意半角）。
//  裝置軸（直立 portrait、螢幕朝使用者）：+x = 畫面右、+y = 畫面上、
//  +z = 出螢幕朝使用者；後鏡光軸 = −z、前鏡光軸 = +z。
//  NormalizedFrame（CoreTypes 契約）：x 向右、y 向下
//  ⇒ 畫面 x 對應裝置 +x、畫面 y 對應裝置 −y。
//
//  ── marker 投影推導（逐步；錯這裡整個交互報廢）──
//  (1) 相對旋轉 q_rel = conj(current) ⊗ goal：把「goal 裝置座標」中的
//      向量轉進「current 裝置座標」（兩個絕對姿態的參考系在共軛乘法中
//      抵銷）。
//  (2) 目標視線方向（current 裝置座標）v = q_rel 作用於相機前向 f；
//      後鏡 f = (0, 0, −1)、前鏡 f = (0, 0, +1)。
//  (3) 角度制針孔投影：前向分量 fwd = f · v = fz·v.z（fz = ∓1）。
//        offsetX = atan2(v.x, fwd) / hFOV
//        offsetY = atan2(−v.y, fwd) / vFOV
//      符號逐項：
//      · 畫面 x 向右 = 裝置 +x（前後鏡「同形」— 前鏡預覽的水平鏡像
//        被光軸反向的第二重反向抵銷，見前鏡推導）⇒ v.x 取正。
//      · 畫面 y 向下 = 裝置 −y ⇒ 取 −v.y。
//      · 以「角度 / FOV」線性映射：|角| = FOV/2 ⇔ |偏移| = 0.5（畫面
//        邊緣）；|角| > FOV/2 照樣給連續值（出界標記，顯示夾取與邊緣
//        箭頭交給 AimGeometry）；連續範圍到 |角| < π（±π = 目標在正
//        背後，atan2 有跳變 — 實際交互到不了，走位覆核早已介入）。
//      · 退化點：v 恰沿 ±裝置 y（fwd = v.x = 0）時 atan2(0, 0) = 0 —
//        超出任何實體 FOV 的極端，僅為數學上有定義。
//  (4) marker P = C + (offsetX, offsetY)（C = AimPointSolver.crosshair）。
//      current = goal ⇒ q_rel = 單位 ⇒ v = f ⇒ P = C（對準即中心）。
//
//  ── goalQuat 合成推導 ──
//  承諾瞬間標記在畫面偏移 (ox, oy)（呼叫端餵 A_commit − T：
//  P = C + (A − T) 的偏移部分）。目標姿態 = 讓該世界方向落到畫面中心
//  的裝置姿態：
//    q_goal = q_commit ⊗ R_y(yaw) ⊗ R_x(pitch)
//  （內在旋轉：先繞承諾姿態的裝置 y 軸 yaw、再繞轉後的裝置 x 軸 pitch。）
//  符號求解（後鏡）：令 current = commit，marker 必須重建 (ox, oy)：
//    v = R_y(a)·R_x(b)·(0, 0, −1) = (−sin a·cos b, sin b, −cos a·cos b)
//    offsetX = atan2(v.x, fwd)/hFOV = atan2(−sin a·cos b, cos a·cos b)/hFOV
//            = −a/hFOV（精確 — yaw 在外層時 cos b 在分子分母同消）
//    offsetY = atan2(−v.y, fwd)/vFOV = atan2(−sin b, cos a·cos b)/vFOV
//            ≈ −b/vFOV（近似，見下）
//    ⇒ a = −ox·hFOV、b = −oy·vFOV。前鏡：兩角一併反號（見前鏡推導）。
//  次序與近似：取「yaw 在外、pitch 在內」（規格：yaw 後 pitch）
//  ⇒ x 軸往返精確；y 軸重建值 β′ = atan(tan β / cos a)（β = |pitch|、
//  a = yaw），誤差 β′ − β ≈ β·a²/2（二階小量）。例：offset (0.2, −0.1)、
//  hFOV 1.2、vFOV 0.9 ⇒ a = 0.24、β = 0.09 ⇒ 誤差 ≈ 0.0026 rad
//  （偏移 ≈ 0.0029，畫面 0.3%）— 固定偏置不抖動、遠低於走位門檻 0.12
//  （⇒ 覆核「不會」觸發修正：殘差恆存，但 0.3% 視覺不可辨，可接受）。
//
//  另一個已知系統殘差 — 線性 angle↔offset vs 真實 tan 針孔投影：Vision 的
//  A/T 座標活在相機 tan（pinhole）投影裡（偏移 0.5 ⇔ tan θ = tan(FOV/2)，
//  即 θ = atan(2·ox·tan(FOV/2))），本檔取「角度/FOV」線性映射。goalQuat 與
//  marker 成對自洽（commit 閉環精確、方向符號不受影響），但使用者轉到標記
//  置中時，主體實際落點與 T 有殘差：
//    真實所需旋轉 = atan(2·ox·tan(hFOV/2))、線性烘進 q_goal 的 = ox·hFOV。
//  手算：ox = 0.3、hFOV = 1.2 ⇒ 線性 0.36 rad vs 真實
//  atan(0.6·tan 0.6) ≈ 0.3895 rad ⇒ 殘差 ≈ 0.0295 rad ≈ 畫面 2.5%
//  （界 ≲ 3% @ |offset| ≤ 0.3）— 比上述次序誤差大一個量級，同樣「低於」
//  走位門檻 0.12 ⇒ Vision 覆核不會吸收（鎖定時實際構圖恆偏 ~2–3%）。
//  固定偏置、不抖動不飄 — 列入待真機驗證：實測若可辨，改用精確 tan 映射
//  （goalQuat 角 = atan(2·ox·tan(FOV/2))、marker 偏移 =
//  tan(角)/(2·tan(FOV/2))）— 成對仍閉環，方向符號測試全數沿用（期望值變）。
//
//  ── 前鏡推導（isFront 的一處統一處理）──
//  兩個效應疊加：
//  (a) 光軸反向：前鏡沿 +z 看世界。同一繞裝置 y 軸的實體旋轉，對 +z
//      與 −z 視向的畫面側向響應相反；繞裝置 x 軸同理（畫面 y 響應相反）。
//  (b) 顯示鏡像：前鏡預覽水平翻轉（自拍鏡像）⇒ 畫面 x 再反一次；y 不動。
//  淨效果（逐軸）：
//    x：(a) 反一次 + (b) 反一次 = 不反 ⇒ 投影公式 v.x 取正、與後鏡同形；
//    y：(a) 反一次 + (b) 不動   = 反   ⇒ 由前向 f 的 fz 符號連同
//       fwd = fz·v.z 吸收 — 代入即得前後鏡同一組 atan2 公式。
//  對 goalQuat 表現為：同一畫面偏移，前鏡 yaw 與 pitch「皆」反號
//  （isFront ⇒ 角度符號 s = +1；後鏡 s = −1）。
//  注意：這與直覺的「前鏡只翻 x」不同 — 只翻 x 會讓前鏡俯仰響應反掉
//  （使用者把手機頂端朝自己傾，臉在預覽中上移，標記卻往下跑 = 以
//  2 倍速離開主體）。鏡像實驗語意已進單元測試鎖死：同一實體旋轉，
//  後鏡標記右移 ⇔ 前鏡標記左移；後鏡標記下移 ⇔ 前鏡標記上移。
//
//  ── roll 補償 ──
//  current 為「完整」裝置姿態時，滾轉已內含於投影（q_rel 帶著 roll，
//  v 的 x/y 分量自動反映畫面旋轉）⇒ 應傳 rollRad = 0。
//  rollRad 保留給「姿態源不含滾轉」或「顯示方位與裝置方位有殘差」的
//  呼叫端：把偏移向量在螢幕平面內旋轉 rollRad。螢幕座標 y 向下，
//  正 rollRad = 偏移向量「順時針」旋轉（視覺方向）：
//    x′ = x·cos − y·sin、y′ = x·sin + y·cos。portrait 近直立時 roll ≈ 0。
//
//  時間律（GoalEaser / SubjectMoveDetector）：本檔無內建時鐘、絕不讀
//  Date()；帶入的時間一律是呼叫端統一時基（秒、單調遞增）— 與
//  OneEuroFilter / GyroFusedPoint / StickyTargetPlanner 同一可測性原則。
//  本檔只准 import Foundation（Linux CI 必須可編譯可測）。

import Foundation

// MARK: - 四元數

/// 純 Double 四元數（x, y, z, w；w = 純量部）。慣例見檔頭。
public struct Quat: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    /// 單位四元數（零旋轉）。
    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    /// Hamilton 乘積 a ⊗ b：先施 b、再施 a 的合成旋轉
    /// （作用於向量時 rot(a ⊗ b, v) = rot(a, rot(b, v))）。
    public static func multiply(_ a: Quat, _ b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    /// 共軛（單位四元數的共軛 = 逆旋轉）。
    public var conjugate: Quat {
        Quat(x: -x, y: -y, z: -z, w: w)
    }

    /// 正規化為單位四元數。範數退化（≈ 0，損毀輸入）時回 identity —
    /// 寧可回零旋轉也不回 NaN（與 AimGeometry 的除零防禦同哲學）。
    public func normalized() -> Quat {
        let norm = (x * x + y * y + z * z + w * w).squareRoot()
        guard norm > 1e-12 else { return .identity }
        return Quat(x: x / norm, y: y / norm, z: z / norm, w: w / norm)
    }
}

// MARK: - 姿態投影

public enum AttitudeProjection {

    /// 由「承諾姿態 + 承諾時畫面偏移」合成目標姿態（推導見檔頭）。
    /// screenOffset = 承諾瞬間 (A_commit − T)（NormalizedFrame，可為任意
    /// 實數）；hFOVRad / vFOVRad = 直立顯示帧的水平／垂直視角（弧度，恆正
    /// — App 端由 videoFieldOfView 換算，注意該值是感測器「長邊」視角、
    /// portrait 顯示時對應畫面垂直方向的既知陷阱屬呼叫端責任）。
    public static func goalQuat(
        commit: Quat,
        screenOffsetX: Double,
        screenOffsetY: Double,
        hFOVRad: Double,
        vFOVRad: Double,
        isFront: Bool
    ) -> Quat {
        // 角度符號（推導見檔頭「goalQuat 合成」與「前鏡」兩段）：
        // 後鏡 a = −ox·hFOV、b = −oy·vFOV；前鏡兩角一併反號。
        let sign: Double = isFront ? 1 : -1
        let yaw = sign * screenOffsetX * hFOVRad
        let pitch = sign * screenOffsetY * vFOVRad
        // q_goal = q_commit ⊗ R_y(yaw) ⊗ R_x(pitch)（內在旋轉：yaw 在外）。
        let composed = Quat.multiply(
            Quat.multiply(commit, rotationAboutY(yaw)),
            rotationAboutX(pitch)
        )
        return composed.normalized()
    }

    /// 由「當下姿態 vs 目標姿態」求標記畫面位置（推導見檔頭）。
    /// 回傳值允許出界（顯示夾取與邊緣箭頭交給 AimGeometry.state(for:)）。
    /// current = goal ⇒ 回 (0.5, 0.5)。rollRad 語意見檔頭「roll 補償」
    /// （完整姿態請傳 0）。FOV 非正（契約違例）時回中心，不產生 NaN。
    public static func marker(
        current: Quat,
        goal: Quat,
        hFOVRad: Double,
        vFOVRad: Double,
        rollRad: Double,
        isFront: Bool
    ) -> NPoint {
        guard hFOVRad > 0, vFOVRad > 0 else { return AimPointSolver.crosshair }

        // (1) 相對旋轉（參考系抵銷；normalized 防輸入非嚴格單位）。
        let rel = Quat.multiply(current.conjugate, goal).normalized()
        // (2) 目標視線方向 = q_rel 作用於相機前向（後鏡 −z、前鏡 +z）。
        let fz: Double = isFront ? 1 : -1
        let v = rotate(rel, x: 0, y: 0, z: fz)
        // (3) 角度制投影（符號推導見檔頭；fwd = f·v 統一前後鏡公式）。
        let fwd = fz * v.z
        let offsetX = atan2(v.x, fwd) / hFOVRad
        let offsetY = atan2(-v.y, fwd) / vFOVRad
        // roll 補償：偏移向量在螢幕平面內旋轉（y 向下座標系的標準旋轉
        // 矩陣 = 視覺順時針）。rollRad = 0 時 cos = 1、sin = 0，恆等。
        let c = cos(rollRad)
        let s = sin(rollRad)
        return NPoint(
            x: AimPointSolver.crosshair.x + offsetX * c - offsetY * s,
            y: AimPointSolver.crosshair.y + offsetX * s + offsetY * c
        )
    }

    // MARK: 私有幾何

    /// 繞裝置 y 軸轉 angle 的四元數（半角公式）。
    private static func rotationAboutY(_ angle: Double) -> Quat {
        Quat(x: 0, y: sin(angle / 2), z: 0, w: cos(angle / 2))
    }

    /// 繞裝置 x 軸轉 angle 的四元數（半角公式）。
    private static func rotationAboutX(_ angle: Double) -> Quat {
        Quat(x: sin(angle / 2), y: 0, z: 0, w: cos(angle / 2))
    }

    /// 單位四元數旋轉向量：v′ = v + w·t + u × t，t = 2·(u × v)
    /// （q v q* 的標準展開，少一次完整四元數乘法）。
    private static func rotate(
        _ q: Quat, x vx: Double, y vy: Double, z vz: Double
    ) -> (x: Double, y: Double, z: Double) {
        let tx = 2 * (q.y * vz - q.z * vy)
        let ty = 2 * (q.z * vx - q.x * vz)
        let tz = 2 * (q.x * vy - q.y * vx)
        return (
            x: vx + q.w * tx + (q.y * tz - q.z * ty),
            y: vy + q.w * ty + (q.z * tx - q.x * tz),
            z: vz + q.w * tz + (q.x * ty - q.y * tx)
        )
    }
}

// MARK: - 目標姿態緩動

/// 目標姿態的平滑更新器：SubjectMoveDetector 判定主體真的走位後，
/// q_goal 以 slerp ease-out 在 duration 秒內滑到新姿態 —
/// 標記「滑移、永不瞬移」。首次設定（snap / 無現值的 retarget）直接就位。
///
/// 緩動曲線 p(u) = 1 − (1 − u)²（二次 ease-out）：
///   p(0) = 0、p(1) = 1、p′(1) = 0（到位前減速、無突停感）、
///   p′(0) = 2（起步輕快）；u = 0.5 ⇒ p = 0.75；p = 0.5 ⇔ u = 1 − √½。
/// 時間律：呼叫端統一時基（秒、單調遞增），本類只取差值。
public final class GoalEaser {

    /// 緩動時長（秒）。≤ 0 = 退化為瞬移（retarget 等同 snap）。
    public let duration: Double

    /// 緩動起點（nil = 非緩動中：value 恆回 target）。
    private var fromQuat: Quat?
    /// 目前目標（nil = 尚未設定任何目標）。
    private var targetQuat: Quat?
    /// 本輪緩動的起始時間。
    private var startTime: Double = 0

    public init(duration: Double = 0.3) {
        self.duration = duration
    }

    /// 立即就位（無緩動）：之後 value 恆回 quat。
    /// 給「承諾瞬間的首次目標」與「切鏡等必須瞬移」的情況用。
    public func snap(to quat: Quat) {
        fromQuat = nil
        targetQuat = quat
    }

    /// 從「當下顯示值」緩動到新目標。尚無任何現值（從未 snap /
    /// retarget）時退化為 snap（規格：首次 snap — 不得從單位姿態滑入）。
    /// 緩動進行中再 retarget：以進行中的插值當下值為新起點（不跳）。
    public func retarget(to quat: Quat, at time: Double) {
        guard let current = value(at: time) else {
            snap(to: quat)
            return
        }
        fromQuat = current
        targetQuat = quat
        startTime = time
    }

    /// 目前應使用的目標姿態；nil = 尚未設定。
    /// 緩動中回 slerp(from, target, p(u))；u 夾 [0, 1]（time 早於起點回
    /// 起點值、晚於結束回目標值）。完成後回傳「原樣的」target（四元數
    /// q 與 −q 表同一旋轉；下游 conj/multiply 對符號不敏感）。
    public func value(at time: Double) -> Quat? {
        guard let target = targetQuat else { return nil }
        guard let from = fromQuat, duration > 0 else { return target }
        let u = min(max((time - startTime) / duration, 0), 1)
        guard u < 1 else { return target }
        let eased = 1 - (1 - u) * (1 - u)
        return Self.slerp(from, target, eased)
    }

    /// 清空（切鏡/翻轉/切模式由呼叫端觸發）；之後 value 回 nil。
    public func reset() {
        fromQuat = nil
        targetQuat = nil
    }

    // MARK: 私有

    /// 球面線性插值（含最短路徑處理）。
    /// dot < 0 時翻轉 b 的符號（q 與 −q 表同一旋轉，取短弧不繞遠路）；
    /// dot > 0.9995（旋轉角差 ≲ 3.6°）時退化為 nlerp —
    /// sin θ ≈ 0 的除法不穩，且該範圍 nlerp 與 slerp 的角參數差
    /// < θ³/24 ≈ 1.3e-6 rad，視覺不可辨。結果一律正規化。
    private static func slerp(_ a: Quat, _ b: Quat, _ t: Double) -> Quat {
        var bq = b
        var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
        if dot < 0 {
            bq = Quat(x: -b.x, y: -b.y, z: -b.z, w: -b.w)
            dot = -dot
        }
        if dot > 0.9995 {
            return Quat(
                x: a.x + t * (bq.x - a.x),
                y: a.y + t * (bq.y - a.y),
                z: a.z + t * (bq.z - a.z),
                w: a.w + t * (bq.w - a.w)
            ).normalized()
        }
        // θ = 兩四元數在 4D 單位球上的夾角 = 旋轉角差的一半。
        let theta = acos(min(max(dot, -1), 1))
        let sinTheta = sin(theta)
        let wa = sin((1 - t) * theta) / sinTheta
        let wb = sin(t * theta) / sinTheta
        return Quat(
            x: wa * a.x + wb * bq.x,
            y: wa * a.y + wb * bq.y,
            z: wa * a.z + wb * bq.z,
            w: wa * a.w + wb * bq.w
        ).normalized()
    }
}

// MARK: - 主體走位偵測

/// Vision 慢速覆核：比較「vision 版標記」P_vis = C + (A − T) 與「姿態版
/// 標記」（AttitudeProjection.marker），兩者歐氏距離「嚴格 >」threshold
/// 且持續「嚴格 >」dwell 秒 → 判定主體真的走位（回 true 一次，呼叫端
/// 以 GoalEaser.retarget 平滑更新 q_goal）。
/// 抖動免疫：距離一旦 ≤ threshold，dwell 時鐘立即歸零（短暫偏差 /
/// 偵測抖動穿越門檻一律無視）。
/// 觸發後時鐘重啟：偏差若持續（例：主體持續走動），每 dwell 至多再觸發
/// 一次 — 事件化而非逐帧觸發，避免 0.3s ease 進行中被逐帧重設起點。
/// 呼叫端只在「vision 本 tick 有解」時餵入；主體丟失／切鏡請 reset()。
public final class SubjectMoveDetector {

    /// 偏差門檻（NormalizedFrame 距離；嚴格 > 才計時）。
    public let threshold: Double
    /// 持續時長門檻（秒；嚴格 > 才觸發）。
    public let dwell: Double

    /// 本輪連續偏差的起始時間；nil = 目前未偏差。
    private var deviatedSince: Double?

    public init(threshold: Double = 0.12, dwell: Double = 0.8) {
        // 負值防禦性夾零（負門檻 = 恆偏差、負 dwell = 立即觸發,皆非本意）。
        self.threshold = max(threshold, 0)
        self.dwell = max(dwell, 0)
    }

    /// 餵入本分析 tick 的兩版標記；true = 該重定目標（q_goal 需更新）。
    public func update(
        visionMarker: NPoint,
        attitudeMarker: NPoint,
        at time: Double
    ) -> Bool {
        let dx = visionMarker.x - attitudeMarker.x
        let dy = visionMarker.y - attitudeMarker.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > threshold else {
            // 回到門檻內：抖動／短暫偏差，dwell 時鐘歸零。
            deviatedSince = nil
            return false
        }
        let since = deviatedSince ?? time
        deviatedSince = since
        if time - since > dwell {
            // 觸發並重啟時鐘（語意見類注釋）。
            deviatedSince = time
            return true
        }
        return false
    }

    /// 清空 dwell 時鐘（主體丟失／切鏡／切模式由呼叫端觸發）。
    public func reset() {
        deviatedSince = nil
    }
}
