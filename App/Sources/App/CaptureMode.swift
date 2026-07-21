//  CaptureMode.swift
//  AICam — 4 種拍攝模式（跨模組契約，A3 擁有；改名/改 case 需經整合者同意）。

import Foundation

enum CaptureMode: String, CaseIterable {
    case photo
    case coach
    case pro
    case review

    /// 用戶可見名稱（繁體中文）。
    var displayName: String {
        switch self {
        case .photo:  return "拍照"
        case .coach:  return "教練"
        case .pro:    return "專業"
        case .review: return "回顧"
        }
    }
}
