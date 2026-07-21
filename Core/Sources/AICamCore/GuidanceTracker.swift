//  GuidanceTracker.swift
//  AICamCore — P2 目標點導引：對齊鎖定遲滯狀態機 + 錨點 EMA 平滑。
//
//  狀態機（distance = TargetGuidance.normalizedDistance）：
//  - distance == nil → .searching，並重置 dwell（主體消失）。
//  - 未鎖定：distance < lockAt 連續維持 ≥ lockDwellSeconds → .locked；
//    dwell 未滿或 distance ≥ lockAt → .aligning（出鎖區即重置 dwell）。
//  - 已鎖定：distance > unlockAt 立即回 .aligning（遲滯：lockAt…unlockAt 之間
//    維持鎖定，防止在門檻附近抖動時鎖定環閃爍）。
//  時間一律由呼叫端注入（對齊 FrameFacts.timestamp 的單調秒數），
//  絕不讀 Date() — 與 AdviceStabilizer 同一可測性原則。
//
//  本檔只准 import Foundation（Linux CI 必須可測）。

import Foundation

public final class GuidanceTracker {

    private let lockAt: Double
    private let unlockAt: Double
    private let lockDwellSeconds: Double

    private var state: LockState = .searching
    /// distance 首次（連續）進入 < lockAt 區間的時間；出區或 nil 即重置。
    private var dwellStart: Double?

    public init(lockAt: Double = 0.045, unlockAt: Double = 0.075, lockDwellSeconds: Double = 0.25) {
        self.lockAt = lockAt
        self.unlockAt = unlockAt
        self.lockDwellSeconds = lockDwellSeconds
    }

    /// 餵入本帧的 anchor–target 距離，回傳目前鎖定狀態。
    /// 判準：進鎖用嚴格 `< lockAt`、出鎖用嚴格 `> unlockAt`；
    /// dwell 以「首次進區的時間」起算，(time − dwellStart) ≥ lockDwellSeconds 才鎖。
    public func update(distance: Double?, at time: Double) -> LockState {
        guard let distance = distance else {
            state = .searching
            dwellStart = nil
            return state
        }
        switch state {
        case .locked:
            if distance > unlockAt {
                state = .aligning
                dwellStart = nil
            }
        case .searching, .aligning:
            if distance < lockAt {
                let start = dwellStart ?? time
                dwellStart = start
                state = (time - start) >= lockDwellSeconds ? .locked : .aligning
            } else {
                dwellStart = nil
                state = .aligning
            }
        }
        return state
    }

    /// 清空狀態（如切換模式／前後鏡時由呼叫端使用）。
    public func reset() {
        state = .searching
        dwellStart = nil
    }
}

/// 錨點／目標點 EMA 平滑器（per 座標）。
/// 第一筆直接採用；之後 p ← α·new + (1−α)·prev。餵入 nil = 重置內部狀態並回 nil
/// （主體消失後重新出現不得從舊位置滑過去）。α 夾在 0…1。
public struct PointSmoother: Sendable {

    public let alpha: Double
    private var value: NPoint?

    public init(alpha: Double) {
        self.alpha = min(max(alpha, 0), 1)
    }

    public mutating func update(_ p: NPoint?) -> NPoint? {
        guard let p = p else {
            value = nil
            return nil
        }
        if let previous = value {
            let next = NPoint(
                x: alpha * p.x + (1 - alpha) * previous.x,
                y: alpha * p.y + (1 - alpha) * previous.y
            )
            value = next
            return next
        }
        value = p
        return p
    }
}
