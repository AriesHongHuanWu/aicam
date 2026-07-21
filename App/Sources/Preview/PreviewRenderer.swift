//  PreviewRenderer.swift
//  AICam — 取景器渲染器 swap 點（A2：相機層）。
//
//  MASTER-PLAN §3 / §14：`AVCaptureVideoPreviewLayer` 不能套濾鏡，
//  所以 P0 就把「取景器怎麼畫」抽成 protocol：
//  - P0–P2：LayerPreviewRenderer（AVCaptureVideoPreviewLayer，零成本）。
//  - P3：新增 MetalPreviewRenderer（MTKView + CIContext，逐帧套 LUT），
//    呼叫端只需換一個 renderer 實例，不動其他程式碼。

import SwiftUI

/// 取景器渲染器。實作者提供一個全幅、resizeAspectFill 的 preview view。
@MainActor
protocol PreviewRenderer {
    /// 此 renderer 產生的 preview view 型別（P0 = PreviewLayerView；P3 = Metal 版）。
    associatedtype PreviewBody: View

    /// 以指定的 PreviewSource 建立取景器 view。
    @ViewBuilder func makePreview(source: PreviewSource) -> PreviewBody
}

/// P0 預設實作：直接包 PreviewLayerView（AVCaptureVideoPreviewLayer）。
struct LayerPreviewRenderer: PreviewRenderer {
    func makePreview(source: PreviewSource) -> some View {
        PreviewLayerView(source: source)
    }
}
