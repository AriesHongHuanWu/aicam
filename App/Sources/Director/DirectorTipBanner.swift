//  DirectorTipBanner.swift
//  AICam — 導演建議膠囊（跨模組契約，A4 擁有；本輪 A3 高級化改造樣式）。
//
//  自己讀 DirectorCenter.shared；無 tip 時不佔空間。
//  來源標籤：live tip 標「AI 導演・現場」、拍後 tip 標「AI 導演」。
//  樣式：ultraThinMaterial 玻璃膠囊 + 0.5pt 白 18% hairline + 黑 40% 軟陰影；
//  出現 = 底部滑入彈簧、換句 = 重新滑入、消失 = fade + 下滑。

import SwiftUI

struct DirectorTipBanner: View {

    /// §9 gray2 #8E8E93（不依賴他人 Tokens 檔，自帶常數）。
    private static let gray2 = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    /// 玻璃 hairline：白 18%。
    private static let glassHairline = Color.white.opacity(0.18)

    var body: some View {
        Group {
            if let tip = DirectorCenter.shared.latestTip {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tip.source == .live ? "AI 導演・現場" : "AI 導演")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.gray2)
                    Text(tip.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Self.glassHairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
                .environment(\.colorScheme, .dark)
                .id(tip.date)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: DirectorCenter.shared.latestTip?.date)
    }
}
