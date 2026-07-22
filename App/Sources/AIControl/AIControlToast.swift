//  AIControlToast.swift
//  AICam — AI 代操動作 toast（A2 擁有；v0.3.0）。
//
//  自己讀 AIControlCenter.shared.latestAction；nil 時不佔空間（Group 空分支）。
//  樣式（§9 黑白 + 材質，對齊 DirectorTipBanner）：ultraThinMaterial 玻璃膠囊 +
//  0.5pt 白 18% hairline + 黑 40% 軟陰影；出現 = 底部滑入 spring(0.35)、
//  5s 淡出（AIControlCenter 清 latestAction → transition opacity + 下滑）；
//  右側「還原」小字按鈕 → undoLastAction()。
//
//  放置（A4）：RootView 底部控制區上方（建議 DirectorTipBanner 同層、其上方），
//  本 view 不自帶定位/邊距。

import SwiftUI

struct AIControlToast: View {

    /// §9 樣式常數（自帶、不依賴他人檔案；數值與 Tokens 一致）。
    private static let gray2 = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    private static let glassHairline = Color.white.opacity(0.18)

    var body: some View {
        Group {
            if let action = AIControlCenter.shared.latestAction {
                HStack(spacing: 12) {
                    Text(action.text)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Button {
                        AIControlCenter.shared.undoLastAction()
                    } label: {
                        Text("還原")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Self.gray2)
                            // 撐大點按面積（膠囊視覺不變）
                            .padding(.vertical, 8)
                            .padding(.leading, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("還原 AI 動作")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Self.glassHairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
                .environment(\.colorScheme, .dark)
                // 換句 = 以 date 為身分重新滑入
                .id(action.date)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: AIControlCenter.shared.latestAction?.date)
    }
}
