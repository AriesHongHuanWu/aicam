//  Components.swift
//  AICam — 設計系統共用元件（A3 擁有）。全部走 Tokens 黑白灰階、繁中文案。

import SwiftUI
import UIKit

// MARK: - 按壓縮放 style（0.92，設計系統統一手感）

struct DSPressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Tokens.animation, value: configuration.isPressed)
    }
}

// MARK: - 快門

/// 72pt 白色雙圈快門。
/// P0 外圈為素圈；`score` 參數保留給後續階段的構圖分數環（P0 不繪製）。
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
                Circle()
                    .stroke(Tokens.fg, lineWidth: 3)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Tokens.fg)
                    .frame(width: 58, height: 58)
            }
        }
        .buttonStyle(DSPressScaleButtonStyle())
        .accessibilityLabel("快門")
    }
}

// MARK: - 焦段列

/// 焦段 chips。選中＝白底黑字；未選＝白字髮絲邊框。無鏡頭資料時不佔空間。
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
                .background(
                    RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                        .fill(isSelected ? Tokens.fg : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                        .stroke(isSelected ? Color.clear : Tokens.hairlineColor, lineWidth: Tokens.hairline)
                )
        }
        .buttonStyle(.plain)
        .animation(Tokens.animation, value: isSelected)
    }
}

// MARK: - 模式切換

/// 4 模式橫向文字：選中白、未選 gray2；點擊或左右 swipe 切換。
struct ModeCarousel: View {
    @Binding var mode: CaptureMode

    var body: some View {
        HStack(spacing: 28) {
            ForEach(CaptureMode.allCases, id: \.self) { candidate in
                Text(candidate.displayName)
                    .font(Tokens.label(13, weight: candidate == mode ? .semibold : .regular))
                    .foregroundStyle(candidate == mode ? Tokens.fg : Tokens.gray2)
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
        withAnimation(Tokens.animation) { mode = newMode }
    }
}

// MARK: - 頂部狀態列

/// 左：格式 chip（P0 固定 HEIF）；右：設定齒輪。
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                        .fill(Tokens.gray3.opacity(0.55))
                )
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Tokens.fg)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("設定")
        }
    }
}

// MARK: - 相簿縮圖

/// 36pt 圓角縮圖；尚無照片時顯示髮絲空框。
struct ThumbnailButton: View {
    let image: UIImage?
    let action: () -> Void

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
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressScaleButtonStyle())
        .accessibilityLabel("相簿")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
    }
}

// MARK: - 前後鏡切換

struct FlipButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Tokens.fg)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Tokens.gray3.opacity(0.55)))
        }
        .buttonStyle(DSPressScaleButtonStyle())
        .accessibilityLabel("切換前後鏡頭")
    }
}
