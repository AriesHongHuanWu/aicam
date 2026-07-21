//  AdviceStabilizer.swift
//  AICamCore — 建議顯示穩定器 + 分數 EMA 平滑（MASTER-PLAN §4.6）。
//
//  防止建議／分數在帧間跳動（箭頭閃爍）：
//  建議有最短顯示時間與切換遲滯；硬錯誤（priority ≥ 100）立即插隊。
//  一律使用呼叫端傳入的單調時間（秒，對齊 FrameFacts.timestamp），
//  絕不讀 Date() — 保證可測性與 media timestamp 一致。

import Foundation

public final class AdviceStabilizer {

    private let minDisplaySeconds: Double
    private let switchAfterSeconds: Double

    /// 目前顯示中的建議與其開始顯示時間。
    private var current: CoachAdvice?
    private var currentSince: Double = 0
    /// 候選中的新建議與其首次連續出現時間。
    private var pending: CoachAdvice?
    private var pendingSince: Double = 0

    public init(minDisplaySeconds: Double = 1.5, switchAfterSeconds: Double = 0.7) {
        self.minDisplaySeconds = minDisplaySeconds
        self.switchAfterSeconds = switchAfterSeconds
    }

    /// 兩則建議視為「同一則」的判準：類別與文案相同（arrow 微幅變動不算切換）。
    private func isSame(_ a: CoachAdvice?, _ b: CoachAdvice?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (x?, y?):
            return x.category == y.category && x.message == y.message
        default:
            return false
        }
    }

    /// 餵入本帧仲裁出的候選建議，回傳「此刻應顯示」的建議。
    /// 規則：
    /// 1. 與目前顯示相同 → 續顯（內容如箭頭更新，但不重置計時）。
    /// 2. 候選為硬錯誤（priority ≥ 100）→ 立即切換。
    /// 3. 目前無顯示 → 立即顯示新候選。
    /// 4. 候選為 nil → 目前建議至少顯示滿 minDisplaySeconds 才消失。
    /// 5. 不同的新建議 → 需同時滿足：目前建議已顯示 ≥ minDisplaySeconds、
    ///    新建議連續出現 ≥ switchAfterSeconds（候選中斷或變別的建議會重算）。
    public func update(candidate: CoachAdvice?, at time: Double) -> CoachAdvice? {
        // 1. 相同 → 續顯。
        if isSame(candidate, current) {
            pending = nil
            if let candidate = candidate {
                current = candidate
            }
            return current
        }
        // 2. 硬錯誤插隊。
        if let candidate = candidate, candidate.priority >= AdvicePriority.hardError {
            current = candidate
            currentSince = time
            pending = nil
            return current
        }
        // 3. 目前沒顯示東西 → 立即顯示。
        if current == nil {
            current = candidate
            currentSince = time
            pending = nil
            return current
        }
        let shownLongEnough = (time - currentSince) >= minDisplaySeconds
        // 4. 候選消失 → 滿最短顯示時間才收掉。
        //    無論如何都清掉 pending：nil 帧代表候選「中斷」，之後同一建議再出現
        //    必須重新累積 switchAfterSeconds（規則 5 的文件語意）。
        guard let candidate = candidate else {
            pending = nil
            if shownLongEnough {
                current = nil
            }
            return current
        }
        // 5. 不同的新建議 → 遲滯切換。
        if !isSame(candidate, pending) {
            pendingSince = time
        }
        pending = candidate
        if shownLongEnough, (time - pendingSince) >= switchAfterSeconds {
            current = candidate
            currentSince = time
            pending = nil
        }
        return current
    }

    /// 清空狀態（如切換拍攝模式時）。
    public func reset() {
        current = nil
        pending = nil
        currentSince = 0
        pendingSince = 0
    }
}

/// 分數 EMA 平滑器（§4.6）。第一筆直接採用；之後 s ← α·v + (1−α)·s。
/// α 越大反應越快、越小越平滑；α 夾在 0…1。
public struct ScoreSmoother: Sendable {

    public let alpha: Double
    private var value: Double?

    public init(alpha: Double) {
        self.alpha = min(max(alpha, 0), 1)
    }

    /// 目前平滑值；尚未餵入任何值時為 nil。
    public var currentValue: Double? { value }

    @discardableResult
    public mutating func update(_ v: Double) -> Double {
        let next: Double
        if let previous = value {
            next = alpha * v + (1 - alpha) * previous
        } else {
            next = v
        }
        value = next
        return next
    }

    public mutating func reset() {
        value = nil
    }
}
