//  VisionCoordinateMapping.swift
//  AICamCore — Vision 正規化座標（原點左下、y 向上）→ NormalizedFrame（原點左上、y 向下）。
//
//  座標鐵律（MASTER-PLAN §14「座標系混亂」對策；App 層組 FrameFacts 前必經此處）：
//  1. Vision 輸出 normalized、原點左下、y 向上（VNImageRectForNormalizedRect 語意）
//     → 本檔負責翻成 NormalizedFrame：y' = 1 − y −（rect 再減 height）。x 不變。
//  2. 前鏡：video connection 已設 isVideoMirrored = true（與 preview 視覺一致），
//     buffer 本身已是鏡像 → Vision 結果「不需」再翻 x，本檔也不翻。
//  3. videoDataOutput connection 已設 videoRotationAngle = 90 → buffer 直立 portrait，
//     Vision 用 .up、不帶 orientation 參數；旋轉不在本檔處理範圍。
//  翻轉是對合（involution）：套兩次回到原值 — 測試鎖住。
//
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

public enum VisionCoordinateMapping {

    /// Vision 正規化 rect（原點左下）→ NormalizedFrame rect（原點左上）。
    /// y' = 1 − y − height（rect 的「頂」在 Vision 空間是 y + height）。
    public static func toNormalizedFrame(
        visionRect x: Double, y: Double, width: Double, height: Double
    ) -> NRect {
        NRect(x: x, y: 1 - y - height, width: width, height: height)
    }

    /// Vision 正規化點（原點左下）→ NormalizedFrame 點（原點左上）。y' = 1 − y。
    public static func toNormalizedFrame(visionPoint x: Double, y: Double) -> NPoint {
        NPoint(x: x, y: 1 - y)
    }
}
