//  AspectFillMapper.swift
//  AICamCore — aspect-fill 幾何映射（NormalizedFrame 點 → 螢幕 container 座標）。
//
//  Preview 是 aspect-FILL：content（相機 buffer 直立帧）等比放大到「蓋滿」
//  container（螢幕 view），置中，超出的部分被裁掉。因此 buffer 長寬比 ≠ 螢幕時，
//  NormalizedFrame 的點不可直接乘 view 尺寸 — 必須經本 mapper。
//
//  數學：scale = max(containerW/contentW, containerH/contentH)；
//  scaled = content × scale；offset = (container − scaled) / 2（恆 ≤ 0 的那軸被裁）。
//  containerPoint(for:) 輸出 = container 座標系的「絕對點值（pt）」，型別仍用
//  NPoint 裝 x/y（非 normalized！）；可為負或超出 container 尺寸，代表該點落在
//  被裁掉的區域，由呼叫端決定要不要畫。
//
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

public struct AspectFillMapper: Equatable, Sendable {

    /// content = 相機 buffer 的像素（或 pt）尺寸；container = 螢幕 view 的 pt 尺寸。
    public let contentWidth: Double
    public let contentHeight: Double
    public let containerWidth: Double
    public let containerHeight: Double

    public init(contentWidth: Double, contentHeight: Double, containerWidth: Double, containerHeight: Double) {
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
    }

    /// 等比放大蓋滿 container 的縮放倍率；content 尺寸非法時為 0（映射退化為 offset）。
    private var scale: Double {
        guard contentWidth > 0, contentHeight > 0 else { return 0 }
        return max(containerWidth / contentWidth, containerHeight / contentHeight)
    }

    private var scaledWidth: Double { contentWidth * scale }
    private var scaledHeight: Double { contentHeight * scale }
    private var offsetX: Double { (containerWidth - scaledWidth) / 2 }
    private var offsetY: Double { (containerHeight - scaledHeight) / 2 }

    /// NormalizedFrame 點（0…1，原點左上）→ container 絕對座標（pt）。
    /// 可為負／超出 container，代表落在被裁區域。
    public func containerPoint(for p: NPoint) -> NPoint {
        NPoint(
            x: offsetX + p.x * scaledWidth,
            y: offsetY + p.y * scaledHeight
        )
    }

    /// 反函式：container 絕對座標（pt）→ NormalizedFrame 點。
    /// 供測試對偶驗證與觸控命中換算；退化尺寸時回 .zero。
    public func normalizedPoint(forContainerX x: Double, y: Double) -> NPoint {
        let w = scaledWidth
        let h = scaledHeight
        guard w > 0, h > 0 else { return .zero }
        return NPoint(x: (x - offsetX) / w, y: (y - offsetY) / h)
    }
}
