//  Tokens.swift
//  AICam — 設計 tokens（MASTER-PLAN §9：純黑白、方正、克制、無彩色 accent）。

import SwiftUI

enum Tokens {

    // MARK: - 色彩（黑白灰階；狀態靠白階/動效/haptics 表達）

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

    // MARK: - 尺寸

    /// 髮絲線寬（pt）。
    static let hairline: CGFloat = 0.5
    /// 圓角（方正硬朗）。
    static let cornerRadius: CGFloat = 2

    // MARK: - 動效

    /// 標準動效時長（秒，§9 規定 ≤200ms）。
    static let duration: Double = 0.18
    /// 標準動效曲線。
    static let animation = Animation.easeOut(duration: duration)

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
