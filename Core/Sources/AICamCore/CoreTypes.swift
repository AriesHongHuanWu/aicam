//  CoreTypes.swift
//  AICamCore — 全專案共用的型別契約（已定案，修改需經整合者同意）。
//
//  本模組必須能在 Linux CI 上編譯與測試：
//  禁止 import UIKit / CoreGraphics / CoreImage / Vision / AVFoundation。
//
//  座標契約（NormalizedFrame）：
//  原點 = 直立顯示帧的左上角，x 向右、y 向下，數值一律 0…1。
//  App 層負責在建構 FrameFacts 前，把 Vision / AVFoundation 座標轉進本空間。

import Foundation

// MARK: - 幾何

public struct NPoint: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public static let zero = NPoint(x: 0, y: 0)
}

public struct NRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { width * height }
    public var center: NPoint { NPoint(x: midX, y: midY) }
}

// MARK: - 觀測事實

public struct FaceFact: Equatable, Codable, Sendable {
    public var box: NRect
    /// 0…1；該帧沒有 landmarks 時為 nil。
    public var leftEyeOpen: Double?
    public var rightEyeOpen: Double?
    public var smile: Double?
    /// 度。正 yaw = 主體臉朝向畫面右緣。
    public var yawDeg: Double?
    public var pitchDeg: Double?
    /// 臉框左/右半（以畫面左右為準）平均亮度 0…1，用於光位判定。
    public var leftBrightness: Double?
    public var rightBrightness: Double?
    /// VNDetectFaceCaptureQualityRequest 結果 0…1。
    public var captureQuality: Double?

    public init(
        box: NRect,
        leftEyeOpen: Double? = nil,
        rightEyeOpen: Double? = nil,
        smile: Double? = nil,
        yawDeg: Double? = nil,
        pitchDeg: Double? = nil,
        leftBrightness: Double? = nil,
        rightBrightness: Double? = nil,
        captureQuality: Double? = nil
    ) {
        self.box = box
        self.leftEyeOpen = leftEyeOpen
        self.rightEyeOpen = rightEyeOpen
        self.smile = smile
        self.yawDeg = yawDeg
        self.pitchDeg = pitchDeg
        self.leftBrightness = leftBrightness
        self.rightBrightness = rightBrightness
        self.captureQuality = captureQuality
    }
}

public enum JointName: String, Codable, CaseIterable, Sendable {
    case head, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

public struct JointFact: Equatable, Codable, Sendable {
    public var name: JointName
    public var point: NPoint
    /// 0…1。
    public var confidence: Double
    public init(name: JointName, point: NPoint, confidence: Double) {
        self.name = name
        self.point = point
        self.confidence = confidence
    }
}

public struct LumaHistogram: Equatable, Codable, Sendable {
    /// 64 bins，總和正規化 ≈ 1。
    public var bins: [Double]
    public init(bins: [Double]) {
        self.bins = bins
    }
    public var shadowClippedFraction: Double { bins.prefix(2).reduce(0, +) }
    public var highlightClippedFraction: Double { bins.suffix(2).reduce(0, +) }
}

/// 一次評分所需的事實快照。App 層每 ~100ms 組一份。
public struct FrameFacts: Equatable, Codable, Sendable {
    public var faces: [FaceFact]
    public var joints: [JointFact]
    /// 主體框（人優先，否則 saliency）；無主體時 nil。
    public var subjectBox: NRect?
    /// CoreMotion 推得的水平滾轉角（度，0 = 水平）。
    public var horizonRollDeg: Double
    /// 相機俯仰角（度，0 = 水平持機，正值 = 朝上仰）。
    public var cameraPitchDeg: Double
    /// 主體距離（公尺）；無深度資訊時 nil。
    public var subjectDistanceM: Double?
    public var histogram: LumaHistogram?
    public var sceneTags: [String]
    public var isFrontCamera: Bool
    /// 單調遞增秒數（media timestamp），供 AdviceStabilizer 用。
    public var timestamp: Double

    public init(
        faces: [FaceFact] = [],
        joints: [JointFact] = [],
        subjectBox: NRect? = nil,
        horizonRollDeg: Double = 0,
        cameraPitchDeg: Double = 0,
        subjectDistanceM: Double? = nil,
        histogram: LumaHistogram? = nil,
        sceneTags: [String] = [],
        isFrontCamera: Bool = false,
        timestamp: Double = 0
    ) {
        self.faces = faces
        self.joints = joints
        self.subjectBox = subjectBox
        self.horizonRollDeg = horizonRollDeg
        self.cameraPitchDeg = cameraPitchDeg
        self.subjectDistanceM = subjectDistanceM
        self.histogram = histogram
        self.sceneTags = sceneTags
        self.isFrontCamera = isFrontCamera
        self.timestamp = timestamp
    }
}

// MARK: - 評分輸出

public enum SubjectMode: String, Codable, CaseIterable, Sendable {
    case fullBody, halfBody, closeUp, nonHuman, none
}

public enum AdviceCategory: String, Codable, CaseIterable, Sendable {
    case headroom, thirds, jointCut, horizon, gazeSpace
    case subjectSize, light, distance, height, stability, exposure
}

public struct CoachAdvice: Equatable, Codable, Sendable {
    public var category: AdviceCategory
    /// 繁體中文、≤10 字（由 SuggestionCatalog 測試強制）。
    public var message: String
    /// 建議移動方向向量（normalized 空間）；無箭頭時 nil。
    public var arrow: NPoint?
    /// 越大越緊急；L1 硬錯誤（切關節/爆頭/嚴重歪斜）≥ 100。
    public var priority: Int

    public init(category: AdviceCategory, message: String, arrow: NPoint? = nil, priority: Int = 0) {
        self.category = category
        self.message = message
        self.arrow = arrow
        self.priority = priority
    }
}

public struct CompositionResult: Equatable, Codable, Sendable {
    /// 0…100。
    public var score: Int
    public var subjectMode: SubjectMode
    /// 各成分得分 0…1（已判定不適用的成分不出現）。
    public var components: [AdviceCategory: Double]
    /// top-1 建議（仲裁後）；畫面已完美時 nil。
    public var advice: CoachAdvice?
    public var shouldAutoCapture: Bool

    public init(
        score: Int,
        subjectMode: SubjectMode,
        components: [AdviceCategory: Double] = [:],
        advice: CoachAdvice? = nil,
        shouldAutoCapture: Bool = false
    ) {
        self.score = score
        self.subjectMode = subjectMode
        self.components = components
        self.advice = advice
        self.shouldAutoCapture = shouldAutoCapture
    }
}

// MARK: - 設定

public struct ScoringConfig: Codable, Equatable, Sendable {
    /// 成分權重（正 = 加分項滿分權重；jointCut 等懲罰項為扣分幅度）。
    public var weights: [AdviceCategory: Double]
    /// 頭頂留白占畫面高的理想區間。
    public var idealHeadroomMin: Double
    public var idealHeadroomMax: Double
    /// |roll| 低於此值視為水平（度）。
    public var maxGoodRollDeg: Double
    /// |roll| 高於此值視為嚴重歪斜（度）。
    public var badRollDeg: Double
    /// 關節距邊緣多近算「切關節」（normalized）。
    public var jointCutEdgeMargin: Double
    /// 自動抓拍最低分。
    public var autoCaptureMinScore: Int
    /// 規則分在總分中的權重（L2 上線前 = 1.0）。
    public var ruleBlendWeight: Double

    public init(
        weights: [AdviceCategory: Double],
        idealHeadroomMin: Double,
        idealHeadroomMax: Double,
        maxGoodRollDeg: Double,
        badRollDeg: Double,
        jointCutEdgeMargin: Double,
        autoCaptureMinScore: Int,
        ruleBlendWeight: Double
    ) {
        self.weights = weights
        self.idealHeadroomMin = idealHeadroomMin
        self.idealHeadroomMax = idealHeadroomMax
        self.maxGoodRollDeg = maxGoodRollDeg
        self.badRollDeg = badRollDeg
        self.jointCutEdgeMargin = jointCutEdgeMargin
        self.autoCaptureMinScore = autoCaptureMinScore
        self.ruleBlendWeight = ruleBlendWeight
    }

    /// MASTER-PLAN §4.2 權重。
    public static let standard = ScoringConfig(
        weights: [
            .thirds: 20, .headroom: 15, .subjectSize: 15, .horizon: 10,
            .jointCut: 25, .gazeSpace: 10, .light: 15, .exposure: 5
        ],
        idealHeadroomMin: 0.05,
        idealHeadroomMax: 0.12,
        maxGoodRollDeg: 1.5,
        badRollDeg: 4.0,
        jointCutEdgeMargin: 0.03,
        autoCaptureMinScore: 85,
        ruleBlendWeight: 1.0
    )
}

// MARK: - 引擎協定

public protocol CompositionScoring: Sendable {
    func evaluate(_ facts: FrameFacts, config: ScoringConfig) -> CompositionResult
}
