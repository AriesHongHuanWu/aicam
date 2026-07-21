//  DirectorTipBanner.swift
//  AICam — 導演建議膠囊（跨模組契約，A4 擁有）。
//
//  自己讀 DirectorCenter.shared；無 tip 時不佔空間。
//  黑 80% 膠囊 + 0.5pt 白 20% 邊框，§9 黑白 tokens、動效 ≤200ms。

import SwiftUI

struct DirectorTipBanner: View {

    /// §9 gray2 #8E8E93（不依賴他人 Tokens 檔，自帶常數）。
    private static let gray2 = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    var body: some View {
        Group {
            if let tip = DirectorCenter.shared.latestTip {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("AI 導演")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.gray2)
                    Text(tip.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                .id(tip.date)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: DirectorCenter.shared.latestTip?.date)
    }
}
