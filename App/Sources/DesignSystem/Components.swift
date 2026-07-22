//  Components.swift
//  AICam — 設計系統共用元件（A3 擁有）。全部走 Tokens 黑白灰階、繁中文案。
//
//  本輪 UI 高級化：
//  - 快門：按壓 0.88 彈簧 + 瞬亮；分數環 trim 以 spring 追分、≥85 白色柔光。
//  - 鏡頭列：選中 chip 放大 1.08 白底黑字；未選玻璃底白字；morph 彈簧。
//  - 模式列：選中膠囊玻璃底以 matchedGeometryEffect 滑動；selection haptic。
//  - 縮圖：新照片以 scale 0.3→1 + offset 彈簧飛入。
//  - 狀態列 / 翻轉鈕：玻璃材質層次（dsGlass 系列）。

import SwiftUI
import UIKit

// MARK: - 按壓縮放 style（0.92，設計系統統一手感）

struct DSPressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Tokens.springFast, value: configuration.isPressed)
    }
}

// MARK: - 快門按壓 style（0.88 彈簧 + 按下瞬亮）

/// 縮放走 springFast；亮度提升放在 animation 之外 → 按下瞬亮、不補間。
struct DSShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(Tokens.springFast, value: configuration.isPressed)
            .brightness(configuration.isPressed ? 0.18 : 0)
    }
}

// MARK: - 快門

/// 72pt 白色雙圈快門。
/// `score` 非 nil（教練模式）時外圈變成 0–100 構圖分數進度環：
/// 背景白 20% 素圈 + 白色 trim 進度（12 點鐘起順時針），trim 以 spring 追分數；
/// 分數 ≥85 時環外緣加白色柔光（radius 8）。
/// `score == nil` 時為白色素圈。
struct ShutterButton: View {
    let score: Int?
    let action: () -> Void

    init(score: Int? = nil, action: @escaping () -> Void) {
        self.score = score
        self.action = action
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            ZStack {
                if let score {
                    let clamped = min(max(score, 0), 100)
                    Circle()
                        .stroke(Tokens.fg.opacity(0.2), lineWidth: 3)
                        .frame(width: 72, height: 72)
                    Circle()
                        .trim(from: 0, to: CGFloat(clamped) / 100)
                        .stroke(Tokens.fg, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 72, height: 72)
                        .shadow(
                            color: .white.opacity(clamped >= 85 ? 0.8 : 0),
                            radius: clamped >= 85 ? 8 : 0
                        )
                        .animation(Tokens.springFast, value: clamped)
                } else {
                    Circle()
                        .stroke(Tokens.fg, lineWidth: 3)
                        .frame(width: 72, height: 72)
                }
                Circle()
                    .fill(Tokens.fg)
                    .frame(width: 58, height: 58)
            }
        }
        .buttonStyle(DSShutterButtonStyle())
        .accessibilityLabel("快門")
    }
}

// MARK: - 焦段列

/// 焦段 chips。選中＝白底黑字放大 1.08；未選＝玻璃底白字。無鏡頭資料時不佔空間。
struct LensBar: View {
    let options: [LensOption]
    let selectedID: String?
    let onSelect: (LensOption) -> Void

    init(options: [LensOption], selectedID: String?, onSelect: @escaping (LensOption) -> Void) {
        self.options = options
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    var body: some View {
        if !options.isEmpty {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    chip(option)
                }
            }
        }
    }

    private func chip(_ option: LensOption) -> some View {
        let isSelected = option.id == selectedID
        return Button {
            guard !isSelected else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(option)
        } label: {
            Text(option.label)
                .font(Tokens.mono(12, weight: .semibold))
                .foregroundStyle(isSelected ? Tokens.bg : Tokens.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                            .fill(Tokens.fg)
                    } else {
                        RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.clear : Tokens.glassHairline,
                            lineWidth: Tokens.hairline
                        )
                )
                .shadow(color: Tokens.softShadow, radius: 8, x: 0, y: 2)
                .scaleEffect(isSelected ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .animation(Tokens.springFast, value: isSelected)
    }
}

// MARK: - 模式切換

/// 4 模式橫向文字：選中白字 + 玻璃膠囊底（matchedGeometryEffect 滑動彈簧）、
/// 未選 gray2；點擊或左右 swipe 切換，切換觸發 selection haptic。
struct ModeCarousel: View {
    @Binding var mode: CaptureMode
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 10) {
            ForEach(CaptureMode.allCases, id: \.self) { candidate in
                let isSelected = candidate == mode
                Text(candidate.displayName)
                    .font(Tokens.label(13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Tokens.fg : Tokens.gray2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Capsule().strokeBorder(
                                        Tokens.glassHairline,
                                        lineWidth: Tokens.hairline
                                    )
                                )
                                .environment(\.colorScheme, .dark)
                                .matchedGeometryEffect(id: "mode.pill", in: pillNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(candidate) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width < -24 {
                        step(1)   // 往左滑 → 下一個模式
                    } else if value.translation.width > 24 {
                        step(-1)  // 往右滑 → 上一個模式
                    }
                }
        )
    }

    private func step(_ delta: Int) {
        let all = CaptureMode.allCases
        guard let index = all.firstIndex(of: mode) else { return }
        let target = index + delta
        guard all.indices.contains(target) else { return }
        select(all[target])
    }

    private func select(_ newMode: CaptureMode) {
        guard newMode != mode else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(Tokens.springFast) { mode = newMode }
    }
}

// MARK: - 頂部狀態列

/// 左：格式 chip（玻璃底）；右：設定齒輪（玻璃圓底）。
struct StatusStrip: View {
    let formatLabel: String
    let onSettings: () -> Void

    init(formatLabel: String = "HEIF", onSettings: @escaping () -> Void) {
        self.formatLabel = formatLabel
        self.onSettings = onSettings
    }

    var body: some View {
        HStack {
            Text(formatLabel)
                .font(Tokens.mono(11, weight: .medium))
                .foregroundStyle(Tokens.gray1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .dsGlass()
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tokens.fg)
                    .frame(width: 36, height: 36)
                    .dsGlassCircle()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DSPressScaleButtonStyle())
            .accessibilityLabel("設定")
        }
    }
}

// MARK: - 相簿縮圖

/// 36pt 圓角縮圖；尚無照片時顯示髮絲空框。
/// 新照片出現時以彈簧飛入（scale 0.3→1 + 由快門方向 offset 歸位）。
struct ThumbnailButton: View {
    let image: UIImage?
    let action: () -> Void

    @State private var appearScale: CGFloat = 1
    @State private var appearOffset: CGSize = .zero

    init(image: UIImage?, action: @escaping () -> Void) {
        self.image = image
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.clear
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(shape)
            .overlay(shape.stroke(Tokens.hairlineColor, lineWidth: Tokens.hairline))
            .shadow(color: Tokens.softShadow, radius: 8, x: 0, y: 2)
            .scaleEffect(appearScale)
            .offset(appearOffset)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressScaleButtonStyle())
        .accessibilityLabel("相簿")
        .onChange(of: image) { _, newValue in
            guard newValue != nil else { return }
            // 先無動畫落到起點（縮小、偏向快門方向），再彈簧歸位 = 飛入。
            appearScale = 0.3
            appearOffset = CGSize(width: 36, height: 8)
            withAnimation(Tokens.springAppear) {
                appearScale = 1
                appearOffset = .zero
            }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
    }
}

// MARK: - 前後鏡切換

/// 玻璃圓底 + 點擊時圖示旋轉 180°。
struct FlipButton: View {
    let action: () -> Void

    @State private var spinDegrees: Double = 0

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Tokens.springAppear) {
                spinDegrees += 180
            }
            action()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Tokens.fg)
                .rotationEffect(.degrees(spinDegrees))
                .frame(width: 44, height: 44)
                .dsGlassCircle()
        }
        .buttonStyle(DSPressScaleButtonStyle())
        .accessibilityLabel("切換前後鏡頭")
    }
}
