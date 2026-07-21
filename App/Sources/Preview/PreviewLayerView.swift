//  PreviewLayerView.swift
//  AICam — AVCaptureVideoPreviewLayer 取景器（A2：相機層）。
//
//  直向固定 app（Info.plist 只允許 Portrait）：
//  connection 一律設 videoRotationAngle = 90（iOS 17 API，基準版本即 17.0，直接用；
//  不用已棄用的 videoOrientation）。
//  CaptureSessionService 在每次配置完成時也會對 session 全部 connection 設 90°，
//  這裡的 applyPortraitRotation 是雙保險（view 早於 session 配置建立時 connection 還不存在）。

import AVFoundation
import SwiftUI
import UIKit

/// 相機 preview 的資料來源（A2 擁有定義；A3 由 CameraController.previewSource 取得）。
struct PreviewSource {
    let session: AVCaptureSession
}

/// P0 取景器：把 AVCaptureVideoPreviewLayer 包成 SwiftUI view，videoGravity = .resizeAspectFill。
struct PreviewLayerView: UIViewRepresentable {

    let source: PreviewSource

    func makeUIView(context: Context) -> VideoPreviewUIView {
        let view = VideoPreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = source.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.applyPortraitRotation()
        return view
    }

    func updateUIView(_ uiView: VideoPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== source.session {
            uiView.previewLayer.session = source.session
        }
        uiView.applyPortraitRotation()
    }

    /// layerClass 直接換成 AVCaptureVideoPreviewLayer 的 UIView 子類
    /// （layer 即 preview layer，尺寸跟著 view 走，不需手動同步 frame）。
    final class VideoPreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyPortraitRotation()
        }

        /// connection 存在且支援時，把 preview 固定成直向（90°）。
        func applyPortraitRotation() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
                connection.videoRotationAngle = 90
            }
        }
    }
}
