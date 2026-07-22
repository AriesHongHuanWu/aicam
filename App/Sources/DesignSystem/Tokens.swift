//  Tokens.swift
//  AICam — 設計 tokens（MASTER-PLAN §9：純黑白、方正、克制、無彩色 accent）。
//
//  本輪 UI 高級化擴充：
//  - 統一動效節奏：互動回饋 springFast（0.25/0.25）、出現消失 springAppear（0.35）、
//    分析結果位置補間 tween（linear 0.08）。
//  - 玻璃材質層次：ultraThinMaterial 底 + 0.5pt 白 18% hairline + 黑 40% 軟陰影
//    （dsGlass / dsGlassCapsule ViewModifier，全 app 引用一致）。

import SwiftUI

enum Tokens {

    // MARK: - 色彩（黑白灰階；狀態靠白階/材質/動效/haptics 表達）

    /// #000000
    static let bg = Color.black
    /// #FFFFFF
    static let fg = Color.white
    /// #EBEBF0
    static let gray1 = Color(red: 235 / 255, green: 235 / 255, blue: 240 / 255)
    /// #8E8E93
    static let gray2 = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    /// #3A3A3C
    static let gray3 = Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255)
    /// 髮絲線用色：白 20%。
    static let hairlineColor = Color.white.opacity(0.2)
    /// 玻璃元件 hairline：白 18%。
    static let glassHairline = Color.white.opacity(0.18)
    /// 軟陰影：黑 40%。
    static let softShadow = Color.black.opacity(0.4)

    // MARK: - 尺寸

    /// 髮絲線寬（pt）。
    static let hairline: CGFloat = 0.5
    /// 圓角（方正硬朗）。
    static let cornerRadius: CGFloat = 2
    /// 軟陰影半徑。
    static let softShadowRadius: CGFloat = 12
    /// 軟陰影 y 偏移。
    static let softShadowY: CGFloat = 4

    // MARK: - 動效（全 app 統一節奏）

    /// 標準動效時長（秒）。
    static let duration: Double = 0.18
    /// 標準動效曲線（既有元件沿用）。
    static let animation = Animation.easeOut(duration: duration)
    /// 互動回饋（按壓、選中切換、數值跳動）。
    static let springFast = Animation.spring(duration: 0.25, bounce: 0.25)
    /// 出現／消失（膠囊、縮圖飛入、結果訊息）。
    static let springAppear = Animation.spring(duration: 0.35)
    /// 分析結果（~10–15fps）位置補間。
    static let tween = Animation.linear(duration: 0.08)

    // MARK: - 字體（SF Pro 系統字）

    /// 介面文字。
    static func label(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 參數/數據文字（等寬數字，數值變動不跳版）。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

// MARK: - 玻璃材質層次（§9：層次靠材質不靠顏色）

/// ultraThinMaterial 底 + 0.5pt 白 18% hairline + 黑 40% 軟陰影（圓角矩形）。
/// 強制深色 render：取景器上永遠是暗玻璃，不受環境 colorScheme 影響。
struct DSGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = Tokens.cornerRadius

    func body(content: Content) -> some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Tokens.glassHairline, lineWidth: Tokens.hairline)
            )
            .shadow(
                color: Tokens.softShadow,
                radius: Tokens.softShadowRadius,
                x: 0,
                y: Tokens.softShadowY
            )
            .environment(\.colorScheme, .dark)
    }
}

/// 膠囊版玻璃層次（建議膠囊、banner、分數 chip）。
struct DSGlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Tokens.glassHairline, lineWidth: Tokens.hairline))
            .shadow(
                color: Tokens.softShadow,
                radius: Tokens.softShadowRadius,
                x: 0,
                y: Tokens.softShadowY
            )
            .environment(\.colorScheme, .dark)
    }
}

/// 圓形版玻璃層次（圓形圖示按鈕）。
struct DSGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Tokens.glassHairline, lineWidth: Tokens.hairline))
            .shadow(
                color: Tokens.softShadow,
                radius: Tokens.softShadowRadius,
                x: 0,
                y: Tokens.softShadowY
            )
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// 玻璃圓角矩形底（chips、狀態列）。
    func dsGlass(cornerRadius: CGFloat = Tokens.cornerRadius) -> some View {
        modifier(DSGlassModifier(cornerRadius: cornerRadius))
    }

    /// 玻璃膠囊底（膠囊文字、banner）。
    func dsGlassCapsule() -> some View {
        modifier(DSGlassCapsuleModifier())
    }

    /// 玻璃圓形底（圓形圖示按鈕）。
    func dsGlassCircle() -> some View {
        modifier(DSGlassCircleModifier())
    }
}
