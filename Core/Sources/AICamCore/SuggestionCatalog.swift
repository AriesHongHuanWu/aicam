//  SuggestionCatalog.swift
//  AICamCore — 教練建議語料庫（MASTER-PLAN §4.2 / F2）。
//
//  所有用戶可見教練文案集中於此：繁體中文、硬規則 ≤10 字（CatalogTests 掃描強制）。
//
//  arrow 契約：建議的「相機移動方向」，NormalizedFrame 螢幕座標（x+ 向右、y+ 向下）。
//  相機往左移／往左帶 ⇒ 主體在畫面中往右移；相機抬高（arrow y = −1）⇒ 主體在畫面中下移。
//  前後距離、旋轉、光線類建議無螢幕方向 → arrow = nil。

import Foundation

public enum SuggestionCatalog {

    /// 一則語料：類別 + 文案 + 方向箭頭（可無）。
    public struct Entry: Equatable, Sendable {
        public let category: AdviceCategory
        public let message: String
        public let arrow: NPoint?

        public init(category: AdviceCategory, message: String, arrow: NPoint? = nil) {
            self.category = category
            self.message = message
            self.arrow = arrow
        }

        /// 以指定優先級包成 CoachAdvice。
        public func advice(priority: Int) -> CoachAdvice {
            CoachAdvice(category: category, message: message, arrow: arrow, priority: priority)
        }
    }

    // MARK: - 三分構圖（thirds）

    public static let thirdsMoveLeft = Entry(
        category: .thirds, message: "往左移一點", arrow: NPoint(x: -1, y: 0))
    public static let thirdsMoveRight = Entry(
        category: .thirds, message: "往右移一點", arrow: NPoint(x: 1, y: 0))
    public static let thirdsAimUp = Entry(
        category: .thirds, message: "取景抬高一點", arrow: NPoint(x: 0, y: -1))
    public static let thirdsAimDown = Entry(
        category: .thirds, message: "取景壓低一點", arrow: NPoint(x: 0, y: 1))

    // MARK: - 頭部空間（headroom）

    /// 硬錯誤：頭頂貼邊／被切。
    public static let headroomClipped = Entry(
        category: .headroom, message: "別切到頭頂", arrow: NPoint(x: 0, y: -1))
    /// 頭頂留白過少。
    public static let headroomTooTight = Entry(
        category: .headroom, message: "鏡頭抬高一點", arrow: NPoint(x: 0, y: -1))
    /// 頭頂留白過多。
    public static let headroomTooMuch = Entry(
        category: .headroom, message: "鏡頭壓低一點", arrow: NPoint(x: 0, y: 1))

    // MARK: - 主體占比（subjectSize）

    public static let sizeTooSmall = Entry(category: .subjectSize, message: "上前兩步")
    public static let sizeTooLarge = Entry(category: .subjectSize, message: "退後兩步")

    // MARK: - 水平（horizon）

    public static let horizonLevel = Entry(category: .horizon, message: "拉直水平")

    // MARK: - 切關節（jointCut）— 寧切大腿不切膝

    public static let jointCutKnee = Entry(category: .jointCut, message: "寧切大腿別切膝")
    public static let jointCutAnkle = Entry(category: .jointCut, message: "退後把腳拍進去")
    public static let jointCutWrist = Entry(category: .jointCut, message: "退後別切手腕")

    // MARK: - 視線空間（gazeSpace）

    /// 臉朝畫面右緣、右側留白不足 → 相機往右帶讓主體左移。
    public static let gazeNeedRightSpace = Entry(
        category: .gazeSpace, message: "鏡頭往右帶一點", arrow: NPoint(x: 1, y: 0))
    /// 臉朝畫面左緣、左側留白不足 → 相機往左帶讓主體右移。
    public static let gazeNeedLeftSpace = Entry(
        category: .gazeSpace, message: "鏡頭往左帶一點", arrow: NPoint(x: -1, y: 0))

    // MARK: - 光位（light）

    /// 側逆光：臉左右亮度差過大。
    public static let lightTurnToBright = Entry(category: .light, message: "請她轉向亮處")
    /// 逆光：臉明顯暗於場景。
    public static let lightBacklit = Entry(category: .light, message: "請她面向光源")

    // MARK: - 曝光（exposure）

    public static let exposureTooBright = Entry(category: .exposure, message: "降低曝光一點")
    public static let exposureTooDark = Entry(category: .exposure, message: "提高曝光一點")

    // MARK: - 距離／高度／穩定（供 F3/F8/F25 等其他模組共用同一語料出口）

    public static let distanceTooClose = Entry(category: .distance, message: "退後兩步")
    public static let distanceTooFar = Entry(category: .distance, message: "上前兩步")
    public static let heightCrouchLower = Entry(category: .height, message: "蹲低一點")
    public static let heightRaiseHigher = Entry(category: .height, message: "鏡頭舉高一點")
    public static let stabilityHold = Entry(category: .stability, message: "拿穩手機")

    // MARK: - 總表

    /// 全部語料（新增 Entry 時必須同步加進來，CatalogTests 依此掃描）。
    public static let allEntries: [Entry] = [
        thirdsMoveLeft, thirdsMoveRight, thirdsAimUp, thirdsAimDown,
        headroomClipped, headroomTooTight, headroomTooMuch,
        sizeTooSmall, sizeTooLarge,
        horizonLevel,
        jointCutKnee, jointCutAnkle, jointCutWrist,
        gazeNeedRightSpace, gazeNeedLeftSpace,
        lightTurnToBright, lightBacklit,
        exposureTooBright, exposureTooDark,
        distanceTooClose, distanceTooFar,
        heightCrouchLower, heightRaiseHigher,
        stabilityHold
    ]

    /// 供測試掃描長度用。
    public static var allMessages: [String] {
        allEntries.map { $0.message }
    }
}
