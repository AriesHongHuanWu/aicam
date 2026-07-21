//  RootView.swift
//  AICam — 主畫面版面（A3：UI 殼）。
//
//  依賴其他模組（同一 module「AICam」，不需 import）：
//  - CameraController / LensOption / PreviewSource / PreviewLayerView（A2，Capture）
//  - DirectorCenter / DirectorTipBanner / SettingsView（A4，Director）

import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @State private var camera = CameraController()
    @AppStorage("mode") private var mode: CaptureMode = .photo
    @State private var isSettingsPresented = false

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()

            PreviewLayerView(source: camera.previewSource)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                StatusStrip { isSettingsPresented = true }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                // P0：非拍照模式只在取景器上緣顯示極淡模式名（功能後續階段開通）。
                if mode != .photo {
                    Text(mode.displayName)
                        .font(Tokens.label(12, weight: .medium))
                        .foregroundStyle(Tokens.fg.opacity(0.3))
                        .padding(.top, 12)
                }

                Spacer()

                if camera.status == .failed {
                    Text("相機啟動失敗")
                        .font(Tokens.label(13))
                        .foregroundStyle(Tokens.gray2)
                    Spacer()
                }

                DirectorTipBanner()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)

                controls
            }

            if camera.status == .denied {
                deniedOverlay
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .task {
            camera.onPhotoCaptured = { data in
                Task { @MainActor in
                    DirectorCenter.shared.photoCaptured(jpeg: data)
                }
            }
            await camera.start()
        }
    }

    // MARK: - 底部控制區

    private var controls: some View {
        VStack(spacing: 16) {
            LensBar(
                options: camera.lensOptions,
                selectedID: camera.currentLens?.id
            ) { camera.select(lens: $0) }

            HStack {
                ThumbnailButton(image: camera.lastThumbnail) {
                    openSystemPhotoAlbum()
                }
                Spacer()
                ShutterButton {
                    Task { await camera.capturePhoto() }
                }
                .opacity(camera.isCapturing ? 0.4 : 1)
                .disabled(camera.isCapturing)
                Spacer()
                FlipButton {
                    Task { await camera.flipCamera() }
                }
            }
            .padding(.horizontal, 32)

            ModeCarousel(mode: $mode)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 權限未開啟

    private var deniedOverlay: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("相機權限未開啟")
                    .font(Tokens.label(17, weight: .semibold))
                    .foregroundStyle(Tokens.fg)
                Text("請在設定中允許 AICam 使用相機")
                    .font(Tokens.label(13))
                    .foregroundStyle(Tokens.gray2)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("前往設定")
                        .font(Tokens.label(15, weight: .medium))
                        .foregroundStyle(Tokens.bg)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                                .fill(Tokens.fg)
                        )
                }
                .buttonStyle(DSPressScaleButtonStyle())
                .padding(.top, 8)
            }
        }
    }

    // MARK: - 動作

    /// 開系統相簿 app；開不了就無動作。
    private func openSystemPhotoAlbum() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:]) { _ in }
    }
}
