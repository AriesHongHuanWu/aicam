//  RootView.swift
//  AICam — 主畫面版面（A3：UI 殼）。
//
//  依賴其他模組（同一 module「AICam」，不需 import）：
//  - CameraController / LensOption / PreviewSource / PreviewLayerView（A2，Capture）
//  - CoachSession（A2，Coach）；CoachOverlayView（A3，Coach）
//  - DirectorCenter / DirectorTipBanner / SettingsView（A4，Director）

import AICamCore
import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @State private var camera = CameraController()
    /// P2 教練 session：init 需引用 camera，而 @State 初始器內拿不到另一個
    /// @State 的值，故延後到 .task 內 lazy 建立（optional）。
    @State private var coach: CoachSession?
    @AppStorage("mode") private var mode: CaptureMode = .photo
    @AppStorage("director.live") private var directorLive = false
    @State private var isSettingsPresented = false

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()

            // GeometryReader 取得 preview 實際 container 尺寸（full-bleed），
            // 供 CoachOverlayView 的 AspectFillMapper 映射用。
            GeometryReader { geo in
                ZStack {
                    PreviewLayerView(source: camera.previewSource)
                    if mode == .coach, let coach {
                        CoachOverlayView(session: coach, containerSize: geo.size)
                    }
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                StatusStrip { isSettingsPresented = true }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                // 尚未開通的模式只顯示極淡模式名（教練已於 P2 開通，改由 overlay 呈現）。
                if mode == .pro || mode == .review {
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
            if coach == nil {
                coach = CoachSession(camera: camera)
            }
            updateCoachWiring()
        }
        .onChange(of: mode) { _, _ in
            updateCoachWiring()
        }
        .onChange(of: directorLive) { _, _ in
            updateCoachWiring()
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
                ShutterButton(score: coachScore) {
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

    // MARK: - 教練接線

    /// 教練模式 = coach 分析啟動；配合 director.live 開關接上／斷開導演即時建議。
    /// 呼叫時機：.task（coach 建立後）、mode 變更、director.live 變更。
    /// stopLive() 在未 startLive 時呼叫視為 no-op（A4 契約）。
    private func updateCoachWiring() {
        let inCoach = mode == .coach
        coach?.setActive(inCoach)
        if inCoach, directorLive, let coach {
            DirectorCenter.shared.startLive(
                snapshot: { await coach.snapshotJPEGAsync(maxDimension: 512) },
                context: { Self.liveContext(for: coach) }
            )
        } else {
            DirectorCenter.shared.stopLive()
        }
    }

    /// 教練模式時快門外圈的構圖分數；其他模式 nil（素圈）。
    /// 讀 displayScore（Int，只在整數值變化時發布）而非 smoothedScore（Double，
    /// 每次分析必變）：避免整個 RootView body 以 ~10fps 重算 diff。
    private var coachScore: Int? {
        guard mode == .coach, let coach else { return nil }
        return coach.displayScore
    }

    /// 給導演即時建議的簡短繁中脈絡（主體位置／分數／目前建議）。
    private static func liveContext(for coach: CoachSession) -> String? {
        guard let result = coach.result else { return nil }
        var parts = ["構圖分數 \(result.score)"]
        // 主體判斷加臉 fallback：FrameAnalyzer 在「有臉但無可信關節」時刻意不造
        // subjectBox（誠實原則）、熱降級也會停 body pose — 只看 subjectBox 會對著
        // 人臉卻告訴 Gemini「未偵測到主體」，導演會被誤導成畫面沒人。
        let subjectBox = coach.facts.flatMap { facts in
            facts.subjectBox ?? CompositionRules.primaryFace(facts)?.box
        }
        if let box = subjectBox {
            let h = box.midX < 1.0 / 3.0 ? "左" : (box.midX > 2.0 / 3.0 ? "右" : "中")
            let v = box.midY < 1.0 / 3.0 ? "上" : (box.midY > 2.0 / 3.0 ? "下" : "中")
            let region: String
            if h == "中" && v == "中" {
                region = "中央"
            } else if v == "中" {
                region = h + "側"
            } else if h == "中" {
                region = "中" + v
            } else {
                region = h + v
            }
            parts.append("主體在畫面\(region)")
        } else {
            parts.append("未偵測到主體")
        }
        if let advice = coach.advice {
            parts.append("目前建議：\(advice.message)")
        }
        return parts.joined(separator: "，")
    }

    // MARK: - 動作

    /// 開系統相簿 app；開不了就無動作。
    private func openSystemPhotoAlbum() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:]) { _ in }
    }
}
