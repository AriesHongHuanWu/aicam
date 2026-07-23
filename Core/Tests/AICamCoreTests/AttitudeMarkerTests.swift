//  AttitudeMarkerTests.swift
//  AICamCoreTests — v0.6.0 姿態主導標記數學測試（Linux swift test 必須可跑）。
//
//  這裡鎖死新交互的地基語意：
//  (1) Quat：Hamilton 乘法／共軛／正規化的手算恆等式；
//  (2) goalQuat → marker 閉環：任意 commit 姿態（含非平凡 roll）往返一致，
//      x 軸精確、y 軸帶已知二階近似誤差（手算誤差值一併鎖死）；
//  (3) 方向語意：goal 在畫面左 ⇒ 標記在左；使用者轉一半 ⇒ 標記滑一半
//      （slerp 中點）；出界（|角| > FOV/2）仍給連續值；
//  (4) roll 補償（30° 手算 sin/cos）；
//  (5) 前鏡：同一畫面偏移 ⇒ yaw/pitch 皆反號（鏡像 x + 光軸反向的合成，
//      推導見 AttitudeMarker.swift 檔頭）＋同一實體旋轉的鏡像響應語意；
//  (6) GoalEaser：snap／首次 retarget 即 snap／二次 ease-out 手算
//      （u = 0.5 ⇒ p = 0.75；p = 0.5 ⇔ u = 1 − √½）／中途 retarget 不跳
//      ／nlerp 分支／−q 最短路徑；
//  (7) SubjectMoveDetector：0.15 偏差 0.5s 不觸發、1.0s 觸發、觸發後時鐘
//      重啟、抖動穿越門檻重置 dwell、門檻與 dwell 的嚴格不等式邊界。
//  全部手算基準（reviewer 請逐行驗算）。慣例：四元數「半角」—
//  R_y(θ) = (0, sin(θ/2), 0, cos(θ/2))；FOV 取 hFOV = 1.2、vFOV = 0.9 rad。

import XCTest
import AICamCore

final class AttitudeMarkerTests: XCTestCase {

    // MARK: - 測試工具（半角公式手工建四元數）

    /// 繞裝置 y 軸轉 angle：(0, sin(θ/2), 0, cos(θ/2))。
    private func rotY(_ angle: Double) -> Quat {
        Quat(x: 0, y: sin(angle / 2), z: 0, w: cos(angle / 2))
    }

    /// 繞裝置 x 軸轉 angle：(sin(θ/2), 0, 0, cos(θ/2))。
    private func rotX(_ angle: Double) -> Quat {
        Quat(x: sin(angle / 2), y: 0, z: 0, w: cos(angle / 2))
    }

    /// 繞裝置 z 軸轉 angle（滾轉）：(0, 0, sin(θ/2), cos(θ/2))。
    private func rotZ(_ angle: Double) -> Quat {
        Quat(x: 0, y: 0, z: sin(angle / 2), w: cos(angle / 2))
    }

    /// 逐分量比較（同號比較 — 本檔所有期望值都構造成同號）。
    private func assertQuat(
        _ actual: Quat, _ expected: Quat, accuracy: Double = 1e-9,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.w, expected.w, accuracy: accuracy, message, file: file, line: line)
    }

    private let hFOV = 1.2
    private let vFOV = 0.9

    // MARK: - Quat：基本恆等式

    func testQuatIdentityAndInverse() {
        let q = rotY(0.6)
        // 單位元：id ⊗ q = q ⊗ id = q。
        assertQuat(Quat.multiply(.identity, q), q, accuracy: 1e-12)
        assertQuat(Quat.multiply(q, .identity), q, accuracy: 1e-12)
        // 逆旋轉：q ⊗ q* = id（單位四元數的共軛 = 逆）。
        // 手算：R_y(0.6) ⊗ R_y(−0.6)：y 分量 = c·(−s) + s·c = 0、
        // w = c·c − s·(−s) = c² + s² = 1（s = sin 0.3、c = cos 0.3）。
        assertQuat(Quat.multiply(q, q.conjugate), .identity, accuracy: 1e-12)
    }

    func testQuatMultiplyHandComputed() {
        // R_y(90°) = (0, √2/2, 0, √2/2)、R_x(90°) = (√2/2, 0, 0, √2/2)。
        // Hamilton 乘積 R_y(90°) ⊗ R_x(90°) 逐項手算（√2/2·√2/2 = 1/2）：
        //   w = w₁w₂ − x₁x₂ − y₁y₂ − z₁z₂ = 1/2 − 0 − 0 − 0 = 1/2
        //   x = w₁x₂ + x₁w₂ + y₁z₂ − z₁y₂ = 1/2 + 0 + 0 − 0 = 1/2
        //   y = w₁y₂ − x₁z₂ + y₁w₂ + z₁x₂ = 0 − 0 + 1/2 + 0 = 1/2
        //   z = w₁z₂ + x₁y₂ − y₁x₂ + z₁w₂ = 0 + 0 − 1/2 + 0 = −1/2
        let yx = Quat.multiply(rotY(Double.pi / 2), rotX(Double.pi / 2))
        assertQuat(yx, Quat(x: 0.5, y: 0.5, z: -0.5, w: 0.5), accuracy: 1e-12)
        // 反序 R_x(90°) ⊗ R_y(90°)：同法手算 z 反號 ⇒ 乘法不可交換。
        let xy = Quat.multiply(rotX(Double.pi / 2), rotY(Double.pi / 2))
        assertQuat(xy, Quat(x: 0.5, y: 0.5, z: 0.5, w: 0.5), accuracy: 1e-12)
        // 乘積仍為單位範數：4 × (1/2)² = 1。
        let norm = (yx.x * yx.x + yx.y * yx.y + yx.z * yx.z + yx.w * yx.w).squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-12)
        // 同軸角度相加：R_y(0.3) ⊗ R_y(0.5) = R_y(0.8) —
        // 半角和角公式：sin(0.15)cos(0.25) + cos(0.15)sin(0.25) = sin(0.40)、
        //             cos(0.15)cos(0.25) − sin(0.15)sin(0.25) = cos(0.40) ✓
        assertQuat(Quat.multiply(rotY(0.3), rotY(0.5)), rotY(0.8), accuracy: 1e-12)
    }

    func testQuatNormalized() {
        // (3, 0, 0, 4)：範數 5 ⇒ (0.6, 0, 0, 0.8)。
        assertQuat(
            Quat(x: 3, y: 0, z: 0, w: 4).normalized(),
            Quat(x: 0.6, y: 0, z: 0, w: 0.8), accuracy: 1e-12
        )
        // 單位四元數正規化不動。
        assertQuat(Quat.identity.normalized(), .identity, accuracy: 1e-15)
        // 退化（全零,損毀輸入）⇒ identity（防 NaN 防禦語意）。
        assertQuat(Quat(x: 0, y: 0, z: 0, w: 0).normalized(), .identity, accuracy: 1e-15)
    }

    // MARK: - goalQuat → marker 閉環（往返一致性）

    func testGoalQuatMarkerRoundTripBackCamera() {
        // 契約核心：commit 姿態 + 偏移 (0.2, −0.1) 造出 goal，再以
        // current = commit 回算 marker ⇒ 必須 ≈ C + (0.2, −0.1) = (0.7, 0.4)。
        //
        // 手算（推導全文見 AttitudeMarker.swift 檔頭）：後鏡
        //   a(yaw)  = −ox·hFOV = −0.24、b(pitch) = −oy·vFOV = +0.09
        //   v = R_y(a)·R_x(b)·(0,0,−1) = (−sin a·cos b, sin b, −cos a·cos b)
        //   offsetX = atan2(−sin a·cos b, cos a·cos b)/hFOV = −a/1.2 = 0.2（精確）
        //   offsetY = atan2(−sin b, cos a·cos b)/vFOV
        //           = −atan(tan 0.09 / cos 0.24)/0.9
        //           = −0.0926407468…/0.9 = −0.1029342…
        //   ⇒ marker = (0.7, 0.39706584)。y 與理想 0.4 差 −0.00293 =
        //   「yaw 後 pitch」合成的二階近似誤差 β·a²/2 ≈ 0.09×0.0288 ≈
        //   0.0026 rad（固定偏置、不抖動，由 vision 覆核路徑吸收）。
        //
        // 閉環數學上與 commit 無關（q_rel = conj(commit)⊗commit⊗R_y⊗R_x
        // = R_y⊗R_x）⇒ 三組 commit（單位／任意手捏／含非平凡 roll 的
        // 合成姿態）期望值完全相同 — 一併鎖死「xArbitraryZVertical 任意
        // yaw 基準被抵銷」的參考系無關性。
        let wild = Quat(x: 0.3, y: -0.5, z: 0.4, w: 0.7).normalized() // 範數 √0.99
        let rolled = Quat.multiply(
            Quat.multiply(rotZ(0.5), rotY(-0.4)), rotX(0.25)
        ) // 滾轉 0.5 rad 在最外層 — 非平凡 roll
        let expectedY = 0.5 - atan2(sin(0.09), cos(0.24) * cos(0.09)) / 0.9

        for commit in [Quat.identity, wild, rolled] {
            let goal = AttitudeProjection.goalQuat(
                commit: commit, screenOffsetX: 0.2, screenOffsetY: -0.1,
                hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
            )
            let marker = AttitudeProjection.marker(
                current: commit, goal: goal,
                hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
            )
            XCTAssertEqual(marker.x, 0.7, accuracy: 1e-9)
            XCTAssertEqual(marker.y, expectedY, accuracy: 1e-9)
            XCTAssertEqual(marker.y, 0.39706584, accuracy: 1e-7) // 手算數值互驗
            XCTAssertEqual(marker.y, 0.4, accuracy: 0.004)       // 近似誤差有界
        }
    }

    func testMarkerAtCenterWhenCurrentEqualsGoal() {
        // 相機轉到位（current = goal）⇒ q_rel = 單位 ⇒ v = 前向
        // ⇒ atan2(0, 1) = 0 ⇒ marker = C = (0.5, 0.5)。前後鏡皆然。
        let commit = Quat.multiply(
            Quat.multiply(rotZ(0.5), rotY(-0.4)), rotX(0.25)
        )
        for isFront in [false, true] {
            let goal = AttitudeProjection.goalQuat(
                commit: commit, screenOffsetX: 0.2, screenOffsetY: -0.1,
                hFOVRad: hFOV, vFOVRad: vFOV, isFront: isFront
            )
            let marker = AttitudeProjection.marker(
                current: goal, goal: goal,
                hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: isFront
            )
            XCTAssertEqual(marker.x, 0.5, accuracy: 1e-12)
            XCTAssertEqual(marker.y, 0.5, accuracy: 1e-12)
        }
    }

    // MARK: - 方向語意（後鏡）

    func testYawDirectionSemanticsAndHalfwayConvergence() {
        // goal 在 commit 畫面「左側」：offset = (−0.2, 0)。
        // (1) goalQuat 符號：a = −(−0.2)×1.2 = +0.24 ⇒ q_goal = R_y(0.24)。
        //     物理驗證：R_y(0.24) 把後鏡前向 −z 轉向 −x（畫面左）—
        //     「標記在左 ⇒ 使用者該往左轉」✓ 正向控制。
        let goal = AttitudeProjection.goalQuat(
            commit: .identity, screenOffsetX: -0.2, screenOffsetY: 0,
            hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
        )
        assertQuat(goal, rotY(0.24)) // = (0, sin 0.12, 0, cos 0.12) 半角
        // (2) current = commit ⇒ marker.x = 0.5 − 0.2 = 0.3 < 0.5 ✓。
        let atCommit = AttitudeProjection.marker(
            current: .identity, goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(atCommit.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(atCommit.y, 0.5, accuracy: 1e-12)
        // (3) 使用者往左轉一半：slerp(id, R_y(0.24), 0.5) = R_y(0.12)
        //     （同軸旋轉的 slerp = 角度線性插值 — 同一 4D 大圓）。
        //     q_rel = R_y(−0.12) ⊗ R_y(0.24) = R_y(0.12)
        //     ⇒ offsetX = −0.12/1.2 = −0.1 ⇒ marker.x = 0.4 —
        //     標記正好向中心滑了一半 ✓（手轉多少、標記滑多少,零延遲）。
        let halfway = AttitudeProjection.marker(
            current: rotY(0.12), goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(halfway.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(halfway.y, 0.5, accuracy: 1e-12)
    }

    func testPitchDirectionSemanticsAndHalfwayConvergence() {
        // goal 在 commit 畫面「下方」：offset = (0, 0.15)。
        // b = −0.15×0.9 = −0.135 ⇒ q_goal = R_x(−0.135) =
        // (−sin 0.0675, 0, 0, cos 0.0675)。物理驗證：R_x(−0.135) 把後鏡
        // 前向 −z 轉向 −y（裝置下方）—「標記在下 ⇒ 使用者該下俯」✓。
        let goal = AttitudeProjection.goalQuat(
            commit: .identity, screenOffsetX: 0, screenOffsetY: 0.15,
            hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
        )
        assertQuat(goal, rotX(-0.135))
        // 純 pitch（a = 0）⇒ y 往返「精確」：marker.y = 0.65。
        let atCommit = AttitudeProjection.marker(
            current: .identity, goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(atCommit.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(atCommit.y, 0.65, accuracy: 1e-9)
        // 下俯一半（current = R_x(−0.0675)）：q_rel = R_x(−0.0675)
        // ⇒ offsetY = 0.0675/0.9 = 0.075 ⇒ marker.y = 0.575（一半）✓。
        let halfway = AttitudeProjection.marker(
            current: rotX(-0.0675), goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(halfway.y, 0.575, accuracy: 1e-9)
    }

    func testMarkerContinuousBeyondFOV() {
        // |角| > FOV/2 仍給連續值（出界標記交 AimGeometry 畫邊緣箭頭）。
        // offset (−0.8, 0)：a = 0.96 rad > hFOV/2 = 0.6 ⇒
        // marker.x = 0.5 − 0.8 = −0.3（atan2 線性重建、無夾取）。
        let far = AttitudeProjection.goalQuat(
            commit: .identity, screenOffsetX: -0.8, screenOffsetY: 0,
            hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
        )
        let farMarker = AttitudeProjection.marker(
            current: .identity, goal: far,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(farMarker.x, -0.3, accuracy: 1e-9)
        // offset (−1.5, 0)：a = 1.8 rad > π/2（前向分量已為負,目標在
        // 側後方）：atan2 全象限連續 ⇒ marker.x = 0.5 − 1.5 = −1.0。
        // 連續範圍到 |角| < π（±π = 正背後,實際交互到不了）。
        let behind = AttitudeProjection.goalQuat(
            commit: .identity, screenOffsetX: -1.5, screenOffsetY: 0,
            hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
        )
        let behindMarker = AttitudeProjection.marker(
            current: .identity, goal: behind,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(behindMarker.x, -1.0, accuracy: 1e-9)
    }

    // MARK: - roll 補償

    func testRollCompensationRotatesOffsetVector() {
        // 純 yaw 目標（offset (0.2, 0)）⇒ 基礎偏移精確 = (0.2, 0)，
        // roll 旋轉後的手算不被 y 近似誤差污染。
        let goal = AttitudeProjection.goalQuat(
            commit: .identity, screenOffsetX: 0.2, screenOffsetY: 0,
            hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
        )
        // rollRad = +30°：x′ = 0.2·cos30 − 0·sin30 = 0.2·(√3/2) = 0.1·√3
        //              = 0.17320508…；y′ = 0.2·sin30 + 0 = 0.2·(1/2) = 0.1。
        // （螢幕 y 向下 ⇒ 正 roll = 視覺順時針:右偏移轉為右下 ✓）
        let cw = AttitudeProjection.marker(
            current: .identity, goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: Double.pi / 6, isFront: false
        )
        XCTAssertEqual(cw.x, 0.5 + 0.1 * 3.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(cw.x, 0.67320508, accuracy: 1e-8) // 手算數值互驗
        XCTAssertEqual(cw.y, 0.6, accuracy: 1e-9)
        // rollRad = −30°：y′ = 0.2·sin(−30°) = −0.1 ⇒ 右上（逆時針）。
        let ccw = AttitudeProjection.marker(
            current: .identity, goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: -Double.pi / 6, isFront: false
        )
        XCTAssertEqual(ccw.x, 0.5 + 0.1 * 3.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(ccw.y, 0.4, accuracy: 1e-9)
        // rollRad = 0：恆等（cos = 1、sin = 0）。
        let flat = AttitudeProjection.marker(
            current: .identity, goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(flat.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(flat.y, 0.5, accuracy: 1e-12)
    }

    // MARK: - 前鏡（x 鏡像 × 光軸反向）

    func testFrontCameraRoundTrip() {
        // 前鏡閉環：與後鏡同一組期望值（前鏡的 yaw/pitch 反號與投影的
        // fz 反號在往返中互相抵銷；y 的二階誤差量值相同）。
        let wild = Quat(x: 0.3, y: -0.5, z: 0.4, w: 0.7).normalized()
        let goal = AttitudeProjection.goalQuat(
            commit: wild, screenOffsetX: 0.2, screenOffsetY: -0.1,
            hFOVRad: hFOV, vFOVRad: vFOV, isFront: true
        )
        let marker = AttitudeProjection.marker(
            current: wild, goal: goal,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: true
        )
        let expectedY = 0.5 - atan2(sin(0.09), cos(0.24) * cos(0.09)) / 0.9
        XCTAssertEqual(marker.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(marker.y, expectedY, accuracy: 1e-9)
    }

    func testFrontCameraGoalAnglesAreNegatedVersusBack() {
        // 同一畫面偏移,前鏡 yaw 與 pitch「皆」反號（推導見
        // AttitudeMarker.swift 檔頭「前鏡」段:x 由鏡像＋光軸反向兩重
        // 反向相消、y 由光軸反向單獨反向 — 淨效果 = 兩角一併反號）。
        // yaw:offset (0.2, 0) ⇒ 後鏡 R_y(−0.24)、前鏡 R_y(+0.24)。
        assertQuat(
            AttitudeProjection.goalQuat(
                commit: .identity, screenOffsetX: 0.2, screenOffsetY: 0,
                hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
            ),
            rotY(-0.24)
        )
        assertQuat(
            AttitudeProjection.goalQuat(
                commit: .identity, screenOffsetX: 0.2, screenOffsetY: 0,
                hFOVRad: hFOV, vFOVRad: vFOV, isFront: true
            ),
            rotY(0.24)
        )
        // pitch:offset (0, −0.1) ⇒ 後鏡 R_x(+0.09)、前鏡 R_x(−0.09)。
        assertQuat(
            AttitudeProjection.goalQuat(
                commit: .identity, screenOffsetX: 0, screenOffsetY: -0.1,
                hFOVRad: hFOV, vFOVRad: vFOV, isFront: false
            ),
            rotX(0.09)
        )
        assertQuat(
            AttitudeProjection.goalQuat(
                commit: .identity, screenOffsetX: 0, screenOffsetY: -0.1,
                hFOVRad: hFOV, vFOVRad: vFOV, isFront: true
            ),
            rotX(-0.09)
        )
    }

    func testFrontCameraMirrorResponseToPhysicalRotation() {
        // 同一「實體」裝置旋轉,前後鏡標記響應成鏡像 — 自拍鏡像的
        // 物理語意（goal = commit = id,標記原在中心;裝置轉動後看標記
        // 往哪跑）。
        //
        // (1) 繞 +y 轉 0.12（右手定則:+z 轉向 +x）:
        //     後鏡（−z 前向掃向 −x = 畫面左）⇒ 景物右移 ⇒
        //       q_rel = R_y(−0.12)、v = (sin 0.12, 0, −cos 0.12)
        //       ⇒ offsetX = atan2(sin 0.12, cos 0.12)/1.2 = +0.1 ⇒ x = 0.6。
        //     前鏡（+z 前向掃向 +x = 使用者右側）⇒ 鏡像預覽中臉左移 ⇒
        //       v = (−sin 0.12, 0, cos 0.12)
        //       ⇒ offsetX = atan2(−sin 0.12, cos 0.12)/1.2 = −0.1 ⇒ x = 0.4。
        let yawed = rotY(0.12)
        let backYaw = AttitudeProjection.marker(
            current: yawed, goal: .identity,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        let frontYaw = AttitudeProjection.marker(
            current: yawed, goal: .identity,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: true
        )
        XCTAssertEqual(backYaw.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(frontYaw.x, 0.4, accuracy: 1e-9)
        // (2) 繞 +x 轉 0.09（頂端朝使用者傾）:
        //     後鏡前向 −z 上仰 ⇒ 景物下移 ⇒ offsetY = +0.09/0.9 = 0.1
        //       ⇒ y = 0.6。
        //     前鏡前向 +z 下俯（同一旋轉、光軸反向!）⇒ 臉在預覽中
        //       「上移」⇒ y = 0.4 — 這正是「前鏡只翻 x」會做錯的軸:
        //       只翻 x 的話這裡會得到 0.6（標記與臉反向逃逸,2 倍速離開）。
        let pitched = rotX(0.09)
        let backPitch = AttitudeProjection.marker(
            current: pitched, goal: .identity,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        let frontPitch = AttitudeProjection.marker(
            current: pitched, goal: .identity,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: true
        )
        XCTAssertEqual(backPitch.y, 0.6, accuracy: 1e-9)
        XCTAssertEqual(frontPitch.y, 0.4, accuracy: 1e-9)
    }

    // MARK: - GoalEaser：snap / reset / 首次 retarget

    func testGoalEaserSnapResetAndFirstRetarget() {
        let easer = GoalEaser()
        // 尚未設定 ⇒ nil。
        XCTAssertNil(easer.value(at: 0))
        // snap ⇒ 任意時間都回同一姿態（無緩動）。
        easer.snap(to: rotY(0.4))
        assertQuat(easer.value(at: 0)!, rotY(0.4), accuracy: 1e-12)
        assertQuat(easer.value(at: 99)!, rotY(0.4), accuracy: 1e-12)
        // reset ⇒ 回 nil。
        easer.reset()
        XCTAssertNil(easer.value(at: 100))
        // 無現值的 retarget 退化為 snap（首次不得從單位姿態滑入）。
        easer.retarget(to: rotY(0.4), at: 5.0)
        assertQuat(easer.value(at: 5.0)!, rotY(0.4), accuracy: 1e-12)
    }

    // MARK: - GoalEaser：二次 ease-out 手算

    func testGoalEaserQuadraticEaseOutHandComputed() {
        // id → R_y(0.4)、duration 0.3、t₀ = 10。曲線 p(u) = 1 − (1−u)²。
        // 同軸旋轉的 slerp = 角度線性插值 ⇒ value = R_y(p·0.4)。
        // 4D 夾角驗證:dot(id, R_y(0.4)) = cos(0.2) = 0.98007 < 0.9995
        // ⇒ 走真 slerp 分支;θ = 0.2（= 旋轉角差的一半）。
        // slerp 手算範例（t = 0.75;係數 wa = sin(0.25·θ)/sin θ、
        // wb = sin(0.75·θ)/sin θ,即 wa = sin 0.05/sin 0.2、wb = sin 0.15/sin 0.2）:
        //   y = [sin(0.05)·0 + sin(0.15)·sin(0.2)]/sin(0.2) = sin(0.15)
        //   w = [sin(0.05) + sin(0.15)cos(0.2)]/sin(0.2)
        //     = [sin(0.05) + (sin(0.35) − sin(0.05))/2]/sin(0.2)
        //     = [(sin(0.05) + sin(0.35))/2]/sin(0.2)
        //     = sin(0.2)cos(0.15)/sin(0.2) = cos(0.15)   （和差化積）
        //   ⇒ 恰為 R_y(0.3) = (0, sin 0.15, 0, cos 0.15) ✓
        let easer = GoalEaser()
        easer.snap(to: .identity)
        easer.retarget(to: rotY(0.4), at: 10.0)
        // t = t₀:u = 0 ⇒ p = 0 ⇒ 起點。
        assertQuat(easer.value(at: 10.0)!, .identity)
        // t = 10.15:u = 0.5 ⇒ p = 1 − 0.25 = 0.75 ⇒ R_y(0.75×0.4) = R_y(0.3)。
        assertQuat(easer.value(at: 10.15)!, rotY(0.3))
        // p = 0.5 ⇔ u = 1 − √½（(1−u)² = ½）⇒ t = 10 + 0.3(1 − √½)
        // ⇒ 恰為角度中點 R_y(0.2)（slerp t = 0.5 手算錨點）。
        let tHalf = 10.0 + 0.3 * (1.0 - 0.5.squareRoot())
        assertQuat(easer.value(at: tHalf)!, rotY(0.2))
        // t ≥ t₀ + duration:完成,恆回目標。
        assertQuat(easer.value(at: 10.3)!, rotY(0.4), accuracy: 1e-12)
        assertQuat(easer.value(at: 11.0)!, rotY(0.4), accuracy: 1e-12)
        // t < t₀（時基防禦）:u 夾 0 ⇒ 起點值,不外插。
        assertQuat(easer.value(at: 9.9)!, .identity)
    }

    func testGoalEaserRetargetMidEaseStartsFromCurrentValue() {
        // 緩動進行中再 retarget:必須從「進行中的插值當下值」續滑（不跳）。
        // 前段同上:t = 10.15 時 value = R_y(0.3)。此刻 retarget 到 R_y(−0.2):
        // 新緩動 R_y(0.3) → R_y(−0.2)（角差 −0.5;dot = cos(0.25) =
        // 0.96891 < 0.9995 ⇒ 真 slerp）。
        let easer = GoalEaser()
        easer.snap(to: .identity)
        easer.retarget(to: rotY(0.4), at: 10.0)
        easer.retarget(to: rotY(-0.2), at: 10.15)
        // 起點 = 舊緩動的當下值 R_y(0.3)（若跳到舊目標 R_y(0.4) 即 bug）。
        assertQuat(easer.value(at: 10.15)!, rotY(0.3))
        // u = 0.5 ⇒ p = 0.75 ⇒ R_y(0.3 + 0.75×(−0.5)) = R_y(−0.075)。
        assertQuat(easer.value(at: 10.30)!, rotY(-0.075))
        // 完成 ⇒ R_y(−0.2)。
        assertQuat(easer.value(at: 10.45)!, rotY(-0.2), accuracy: 1e-12)
    }

    func testGoalEaserNlerpBranchForTinyAngle() {
        // 小角:id → R_y(0.04)。dot = cos(0.02) = 0.99980 > 0.9995
        // ⇒ 走 nlerp 分支（sin θ ≈ 0 除法不穩的防禦）。
        // u = 0.5 ⇒ p = 0.75 ⇒ 期望 ≈ R_y(0.03);nlerp 與 slerp 的角參數
        // 差 < θ³/24 ≈ (0.02)³/24 ≈ 3e-7 rad ⇒ 1e-6 容差內成立。
        let easer = GoalEaser()
        easer.snap(to: .identity)
        easer.retarget(to: rotY(0.04), at: 0)
        assertQuat(easer.value(at: 0.15)!, rotY(0.03), accuracy: 1e-6)
    }

    func testGoalEaserShortestPathWithNegatedQuat() {
        // 四元數雙覆蓋:−q 與 q 表同一旋轉。目標傳 −R_y(0.4)
        // （dot(id, −R_y(0.4)) = −cos(0.2) < 0）:slerp 必須翻符號走短弧,
        // 不得繞 4D 大圓遠路（繞遠路 = 標記瞬間甩半圈的災難）。
        // 驗證走下游投影（對四元數符號不敏感）:
        //   中點 t = 0.15（p = 0.75）等效 R_y(0.3):
        //     marker.x = 0.5 − 0.3/1.2 = 0.25;
        //   完成後等效 R_y(0.4):marker.x = 0.5 − 0.4/1.2 = 1/6。
        let easer = GoalEaser()
        easer.snap(to: .identity)
        let negated = Quat(x: 0, y: -sin(0.2), z: 0, w: -cos(0.2)) // = −R_y(0.4)
        easer.retarget(to: negated, at: 0)
        let mid = AttitudeProjection.marker(
            current: .identity, goal: easer.value(at: 0.15)!,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(mid.x, 0.25, accuracy: 1e-9)
        let done = AttitudeProjection.marker(
            current: .identity, goal: easer.value(at: 0.3)!,
            hFOVRad: hFOV, vFOVRad: vFOV, rollRad: 0, isFront: false
        )
        XCTAssertEqual(done.x, 0.5 - 0.4 / 1.2, accuracy: 1e-9)
    }

    // MARK: - SubjectMoveDetector：dwell 與觸發

    func testSubjectMoveDetectorDwellAndTrigger() {
        // 預設 threshold 0.12、dwell 0.8。偏差取 3-4-5 三角:
        // vision (0.59, 0.62) vs attitude (0.5, 0.5):
        // 距離 = √(0.09² + 0.12²) = √0.0225 = 0.15 > 0.12 ⇒ 計時。
        let detector = SubjectMoveDetector()
        let attitude = NPoint(x: 0.5, y: 0.5)
        let vision = NPoint(x: 0.59, y: 0.62)
        // t = 0:起算,未達 dwell ⇒ false。
        XCTAssertFalse(detector.update(visionMarker: vision, attitudeMarker: attitude, at: 0))
        // t = 0.5:持續 0.5s ≤ 0.8 ⇒ false（規格:0.5s 不觸發）。
        XCTAssertFalse(detector.update(visionMarker: vision, attitudeMarker: attitude, at: 0.5))
        // t = 1.0:持續 1.0s > 0.8 ⇒ true（規格:1.0s 觸發）。
        XCTAssertTrue(detector.update(visionMarker: vision, attitudeMarker: attitude, at: 1.0))
        // 觸發後時鐘重啟（事件化,防 0.3s ease 進行中逐帧重定目標）:
        // t = 1.1 持續僅 0.1s ⇒ false。
        XCTAssertFalse(detector.update(visionMarker: vision, attitudeMarker: attitude, at: 1.1))
    }

    func testSubjectMoveDetectorJitterResetsDwell() {
        // 抖動穿越門檻 ⇒ dwell 重置（短暫偏差一律無視）。
        let detector = SubjectMoveDetector()
        let attitude = NPoint(x: 0.5, y: 0.5)
        let big = NPoint(x: 0.59, y: 0.62)     // 距離 0.15 > 0.12
        let small = NPoint(x: 0.56, y: 0.58)   // 距離 √(0.06²+0.08²) = 0.10 ≤ 0.12
        XCTAssertFalse(detector.update(visionMarker: big, attitudeMarker: attitude, at: 0))
        // t = 0.4 回到門檻內:時鐘歸零。
        XCTAssertFalse(detector.update(visionMarker: small, attitudeMarker: attitude, at: 0.4))
        // t = 0.6 再偏差:重新起算。
        XCTAssertFalse(detector.update(visionMarker: big, attitudeMarker: attitude, at: 0.6))
        // t = 1.3:自 0.6 起僅 0.7s < 0.8 ⇒ false —
        // 若未重置（自 t = 0 起算 1.3s）這裡會錯誤觸發。
        XCTAssertFalse(detector.update(visionMarker: big, attitudeMarker: attitude, at: 1.3))
        // t = 1.5:自 0.6 起 0.9s > 0.8 ⇒ true。
        XCTAssertTrue(detector.update(visionMarker: big, attitudeMarker: attitude, at: 1.5))
    }

    func testSubjectMoveDetectorStrictBoundariesAndReset() {
        // 門檻用二進位可精確表示的 0.125（2⁻³）,邊界判定不受十進位
        // 浮點誤差影響（同 GyroFusedPoint 測試的 2⁻⁷ 手法）。
        let detector = SubjectMoveDetector(threshold: 0.125, dwell: 0.5)
        let attitude = NPoint(x: 0.5, y: 0.5)
        // 距離「恰等於」門檻:0.625 − 0.5 = 0.125（二進位精確）
        // ⇒ 不嚴格大於 ⇒ 永不起算。
        let atThreshold = NPoint(x: 0.625, y: 0.5)
        XCTAssertFalse(detector.update(visionMarker: atThreshold, attitudeMarker: attitude, at: 0))
        XCTAssertFalse(detector.update(visionMarker: atThreshold, attitudeMarker: attitude, at: 9))
        // dwell 邊界:距離 0.25 > 0.125 起算於 t = 10（整數,二進位精確）。
        let big = NPoint(x: 0.75, y: 0.5)
        XCTAssertFalse(detector.update(visionMarker: big, attitudeMarker: attitude, at: 10.0))
        // t = 10.5:持續「恰等於」dwell = 0.5 ⇒ 不嚴格大於 ⇒ false。
        XCTAssertFalse(detector.update(visionMarker: big, attitudeMarker: attitude, at: 10.5))
        // t = 10.5009765625（10.5 + 2⁻¹⁰,二進位精確）:> dwell ⇒ true。
        XCTAssertTrue(detector.update(visionMarker: big, attitudeMarker: attitude, at: 10.5009765625))
        // reset 清時鐘:同樣偏差要重新累積 dwell。
        detector.reset()
        XCTAssertFalse(detector.update(visionMarker: big, attitudeMarker: attitude, at: 20.0))
        XCTAssertFalse(detector.update(visionMarker: big, attitudeMarker: attitude, at: 20.5))
        XCTAssertTrue(detector.update(visionMarker: big, attitudeMarker: attitude, at: 20.6))
    }
}
