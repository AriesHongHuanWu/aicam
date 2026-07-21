//  CoachOverlayView.swift
//  AICam — 教練模式取景器 overlay（A3 擁有）。P2 目標點導引 UI。
//
//  讀 CoachSession（A2）的 guidance / advice / smoothedScore 繪製：
//  主體錨點、最佳構圖目標環、錨點→目標虛線、建議文字膠囊、（長按）debug 小字。
//
//  座標鐵律：guidance 的 NPoint 屬 NormalizedFrame（左上原點、y 向下、0…1）；
//  preview 是 aspect-FILL（buffer 長寬比 ≠ 螢幕），一律經 AspectFillMapper
//  映射成 container 絕對 pt，不可直接乘 view 尺寸。
//
//  content 比例取自 CoachSession.contentAspect（分析 buffer 實測寬/高，預設 3:4；
//  由 VideoFrameTap 逐帧帶出）— 不再寫死，改 preset / 裝置例外輸出 16:9 也不會偏位。
//  AspectFillMapper 只吃比例：contentWidth = aspect、contentHeight = 1。

import AICamCore
import Foundation
import SwiftUI

@MainActor
struct CoachOverlayView: View {

    let session: CoachSession
    let containerSize: CGSize

    /// debug 小字：長按取景器切換顯示；平常不畫。
    @State private var showDebug = false

    var body: some View {
        let guidance = session.guidance
        let lockState = guidance?.lockState ?? .searching
        let anchorPoint = containerPoint(guidance?.anchor)
        let targetPoint = containerPoint(guidance?.target)

        ZStack {
            // 錨點 → 目標虛線（locked 隱藏；畫在點與環之下）。
            if lockState != .locked, let a = anchorPoint, let t = targetPoint {
                GuideLineShape(from: a, to: t)
                    .stroke(
                        Color.white.opacity(0.6),
                        style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                    )
                    .animation(.linear(duration: 0.1), value: a)
                    .animation(.linear(duration: 0.1), value: t)
            }

            // 目標環（searching 隱藏）。
            if lockState != .searching, let t = targetPoint {
                targetRing(isLocked: lockState == .locked)
                    .position(t)
                    .animation(.linear(duration: 0.1), value: t)
            }

            // 主體錨點。
            if let a = anchorPoint {
                anchorDot
                    .position(a)
                    .animation(.linear(duration: 0.1), value: a)
            }

            advicePill(isLocked: lockState == .locked)

            if showDebug {
                debugReadout(lockState: lockState)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.6) {
            showDebug.toggle()
        }
    }

    // MARK: - 座標映射

    /// NormalizedFrame → container 絕對 pt（座標鐵律 4：必經 AspectFillMapper）。
    /// content 比例 = CoachSession.contentAspect（buffer 實測 寬/高）；mapper 只吃比例，
    /// 故 contentWidth = aspect、contentHeight = 1。
    private func containerPoint(_ p: NPoint?) -> CGPoint? {
        guard let p, containerSize.width > 0, containerSize.height > 0 else { return nil }
        let mapper = AspectFillMapper(
            contentWidth: session.contentAspect,
            contentHeight: 1,
            containerWidth: Double(containerSize.width),
            containerHeight: Double(containerSize.height)
        )
        let mapped = mapper.containerPoint(for: p)
        return CGPoint(x: mapped.x, y: mapped.y)
    }

    // MARK: - 主體錨點

    /// 8pt 實心白點 + 1pt 黑描邊（亮背景也可見）。
    private var anchorDot: some View {
        Circle()
            .fill(Tokens.fg)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.black, lineWidth: 1))
    }

    // MARK: - 目標環

    /// 直徑 44pt、1.5pt 白圈。
    /// aligning：呼吸 opacity 0.6↔1.0（單程 1.2s，TimelineView 驅動，免 repeatForever 殘留）；
    /// locked：外環加粗至 2.5pt + 8pt 實心白圓縮入（≤200ms tokens 動效），並暫停 timeline 省重繪。
    private func targetRing(isLocked: Bool) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: isLocked)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // sin 週期 2.4s → 0.6 → 1.0 → 0.6，每方向 1.2s。
            let breathe = 0.6 + 0.4 * (sin(t * .pi / 1.2) + 1) / 2
            ZStack {
                Circle()
                    .stroke(Tokens.fg, lineWidth: isLocked ? 2.5 : 1.5)
                    .frame(width: 44, height: 44)
                    .opacity(isLocked ? 1 : breathe)
                Circle()
                    .fill(Tokens.fg)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isLocked ? 1 : 0.001)
                    .opacity(isLocked ? 1 : 0)
            }
            .animation(Tokens.animation, value: isLocked)
        }
    }

    // MARK: - 建議文字

    /// 畫面上方 1/4 置中膠囊：locked 顯示「完美，拍！」；
    /// 否則顯示仲裁後 top-1 建議；無建議時不顯示。
    @ViewBuilder
    private func advicePill(isLocked: Bool) -> some View {
        let message: String? = isLocked ? "完美，拍！" : session.advice?.message
        if let message {
            Text(message)
                .font(Tokens.label(15, weight: .semibold))
                .foregroundStyle(Tokens.fg)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .position(x: containerSize.width / 2, y: containerSize.height * 0.25)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Debug 小字（長按顯示）

    private func debugReadout(lockState: LockState) -> some View {
        Text("\(Int(session.smoothedScore.rounded())) \(Self.glyph(for: lockState))")
            .font(Tokens.mono(11, weight: .medium))
            .foregroundStyle(Tokens.fg.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 12)
            .padding(.top, 64)
            .allowsHitTesting(false)
    }

    private static func glyph(for lockState: LockState) -> String {
        switch lockState {
        case .searching: return "○"
        case .aligning:  return "◎"
        case .locked:    return "●"
        }
    }
}

// MARK: - 虛線 Shape

/// 兩端點皆可動畫的直線（animatableData 讓 0.1s 線性補間跟著端點插值）。
private struct GuideLineShape: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(from.x, from.y),
                AnimatablePair(to.x, to.y)
            )
        }
        set {
            from = CGPoint(x: newValue.first.first, y: newValue.first.second)
            to = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}
