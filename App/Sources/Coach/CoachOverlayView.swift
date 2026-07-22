//  CoachOverlayView.swift
//  AICam — 教練模式取景器 overlay（A3 擁有）。P2 目標點導引 UI。
//
//  本輪起改讀 CoachSession（A2）的契約新 surface 繪製：
//  - anchorPoint：One-Euro 平滑後主體錨點
//  - targetPoint：StickyTargetPlanner 承諾後的固定目標（對齊期間絕不動 → 不再追會跑的靶）
//  - lockState / alignDistance：鎖定狀態與錨點到承諾目標的距離
//  另讀 advice / displayScore / smoothedScore（既有 surface）。
//
//  高級化特效：
//  - 目標環：aligning 呼吸 + 依 alignDistance 靠近時環變粗、柔光漸強（0.2→0.05 映射）。
//  - 鎖定慶祝：白圈自目標環 scale 1→1.8 + opacity 1→0（0.5s ease-out）爆開 +
//    環內縮實心 + 「完美，拍！」膠囊 pop（haptic 由 A2 觸發，此處不重複）。
//  - 錨點：白點 + 1pt 黑描邊 + 柔光；移動 linear 0.08s 補間。
//  - 分數 chip：頂部置中玻璃膠囊，數字滾動（contentTransition(.numericText())）。
//
//  座標鐵律：NPoint 屬 NormalizedFrame（左上原點、y 向下、0…1）；
//  preview 是 aspect-FILL（buffer 長寬比 ≠ 螢幕），一律經 AspectFillMapper
//  映射成 container 絕對 pt，不可直接乘 view 尺寸。
//
//  content 比例取自 CoachSession.contentAspect（分析 buffer 實測寬/高，預設 3:4；
//  由 VideoFrameTap 逐帧帶出）— 不寫死，改 preset / 裝置例外輸出 16:9 也不會偏位。
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
    /// 鎖定慶祝爆開動畫進行旗標（false→true 以 0.5s ease-out 補間）。
    @State private var lockBurst = false

    var body: some View {
        let lockState = session.lockState
        let anchorPoint = containerPoint(session.anchorPoint)
        let targetPoint = containerPoint(session.targetPoint)
        let closeness = alignCloseness

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
                targetRing(isLocked: lockState == .locked, closeness: closeness)
                    .position(t)
                    .animation(.linear(duration: 0.1), value: t)
            }

            // 鎖定慶祝：白圈自目標環爆開（結束後 opacity 0 不可見；解鎖即移除）。
            if lockState == .locked, let t = targetPoint {
                Circle()
                    .stroke(Tokens.fg, lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .scaleEffect(lockBurst ? 1.8 : 1)
                    .opacity(lockBurst ? 0 : 1)
                    .position(t)
                    .allowsHitTesting(false)
            }

            // 主體錨點。
            if let a = anchorPoint {
                anchorDot
                    .position(a)
                    .animation(Tokens.tween, value: a)
            }

            scoreReadout

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
        .onAppear {
            // 進場即已鎖定：不播爆開（直接停在結束狀態）。
            lockBurst = session.lockState == .locked
        }
        .onChange(of: session.lockState) { _, newState in
            if newState == .locked {
                // 先無動畫回到起點，再以 0.5s ease-out 爆開。
                lockBurst = false
                withAnimation(.easeOut(duration: 0.5)) {
                    lockBurst = true
                }
            } else {
                lockBurst = false
            }
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

    /// alignDistance → 0…1 靠近度（distance 0.2→0.05 映射 0→1；nil = 0）。
    private var alignCloseness: Double {
        guard let d = session.alignDistance else { return 0 }
        return min(max((0.2 - d) / 0.15, 0), 1)
    }

    // MARK: - 主體錨點

    /// 8pt 實心白點 + 1pt 黑描邊（亮背景也可見）+ 白色柔光。
    private var anchorDot: some View {
        Circle()
            .fill(Tokens.fg)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.black, lineWidth: 1))
            .shadow(color: .white.opacity(0.6), radius: 4)
    }

    // MARK: - 目標環

    /// 直徑 44pt 白圈。
    /// aligning：呼吸 opacity 0.6↔1.0（單程 1.2s，TimelineView 驅動，免 repeatForever 殘留）；
    /// 依 closeness（alignDistance 0.2→0.05）環變粗（1.5→2.7pt）、外圈白色柔光漸強。
    /// locked：外環加粗至 2.5pt + 8pt 實心白圓縮入，並暫停 timeline 省重繪。
    private func targetRing(isLocked: Bool, closeness: Double) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: isLocked)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // sin 週期 2.4s → 0.6 → 1.0 → 0.6，每方向 1.2s。
            let breathe = 0.6 + 0.4 * (sin(t * .pi / 1.2) + 1) / 2
            let ringWidth: CGFloat = isLocked ? 2.5 : 1.5 + 1.2 * CGFloat(closeness)
            let glowOpacity = isLocked ? 0.9 : 0.7 * closeness
            let glowRadius: CGFloat = isLocked ? 8 : 8 * CGFloat(closeness)
            ZStack {
                Circle()
                    .stroke(Tokens.fg, lineWidth: ringWidth)
                    .frame(width: 44, height: 44)
                    .opacity(isLocked ? 1 : breathe)
                    .shadow(color: .white.opacity(glowOpacity), radius: glowRadius)
                Circle()
                    .fill(Tokens.fg)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isLocked ? 1 : 0.001)
                    .opacity(isLocked ? 1 : 0)
            }
            .animation(Tokens.animation, value: isLocked)
            .animation(.linear(duration: 0.1), value: closeness)
        }
    }

    // MARK: - 分數 chip（數字滾動）

    /// 頂部置中玻璃膠囊，displayScore 只在整數變化時發布 → 不逐帧 diff。
    private var scoreReadout: some View {
        Text("\(session.displayScore)")
            .font(Tokens.mono(15, weight: .semibold))
            .foregroundStyle(Tokens.fg)
            .contentTransition(.numericText())
            .animation(Tokens.springFast, value: session.displayScore)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .dsGlassCapsule()
            .position(x: containerSize.width / 2, y: containerSize.height * 0.15)
            .allowsHitTesting(false)
            .accessibilityLabel("構圖分數 \(session.displayScore)")
    }

    // MARK: - 建議文字

    /// 畫面上方 1/4 置中玻璃膠囊：locked 顯示「完美，拍！」；
    /// 否則顯示仲裁後 top-1 建議；無建議時不顯示。
    /// 出現/換句 = pop（scale 0.8→1 spring + 淡入）。
    @ViewBuilder
    private func advicePill(isLocked: Bool) -> some View {
        let message: String? = isLocked ? "完美，拍！" : session.advice?.message
        ZStack {
            if let message {
                Text(message)
                    .font(Tokens.label(15, weight: .semibold))
                    .foregroundStyle(Tokens.fg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .dsGlassCapsule()
                    .id(message)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Tokens.springAppear, value: message)
        .position(x: containerSize.width / 2, y: containerSize.height * 0.25)
        .allowsHitTesting(false)
    }

    // MARK: - Debug 小字（長按顯示）

    private func debugReadout(lockState: LockState) -> some View {
        let distanceText = session.alignDistance.map { String(format: "%.3f", $0) } ?? "–"
        return Text("\(Int(session.smoothedScore.rounded())) \(Self.glyph(for: lockState)) d=\(distanceText)")
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
