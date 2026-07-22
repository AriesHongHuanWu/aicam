//  CoachOverlayView.swift
//  AICam — 教練模式取景器 overlay（A3 擁有）。v0.4.0 對準點導引 UI。
//
//  Apple 測距儀（Measure）式導引，取代舊「點對環」模式：
//  舊模式是反向控制（點的移動方向與手的轉向相反，用戶根本對不準）；
//  新模式把「主體從 A 移到 T」重投影成「相機瞄準 P = C + (A − T)」——
//  用戶朝標記方向轉動手機，標記自然滑向中央準星（正向控制）。
//
//  讀 CoachSession（A2）契約新 surface：
//  - aim: AimState?      — 陀螺儀（~100Hz 推算）+ Vision（~15fps 修正）互補濾波
//                          融合後的世界標記，~60Hz 更新。
//                          注意：本 view「只用 aim.marker」（未夾取的真實位置）；
//                          aim.clamped / aim.isOffscreen 是 content-normalized
//                          空間的夾取（Core 契約照舊），在 full-bleed aspect-fill
//                          預覽下不可用於定位 — 顯示夾取改在 container pt 空間
//                          自行處理（推導見 body 內注釋）。
//  - aimDistance: Double? — |融合 marker − (0.5, 0.5)|，餵靠近度視覺。
//  - lockState / advice / displayScore / smoothedScore（既有 surface）。
//
//  視覺：
//  - 固定準星：畫面正中央 24pt 細圈（1pt 白）+ 內部 4 條 3pt 刻線
//    （上下左右留缺口的 reticle 風格），永遠不動；idle 60% 透明度，
//    靠近時提高不透明度、鎖定時滿版 + 柔光。
//  - 世界標記：36pt 外圈 + 10pt 實心白點（Measure 風格）；
//    靠近準星（aimDistance 0.25→0.05）外圈變粗 + 柔光漸強；
//    位置補間 .linear(duration: 0.05)（60Hz 資料下的細補間）。
//  - 出界：marker 映射 pt 超出 container 可視框 → 貼邊 chevron（指向出界方向）+ 呼吸。
//  - 鎖定：標記吸進準星（spring）→ 準星 + 標記合體白閃爆圈
//    （沿用既有爆圈語彙：44pt 白圈 scale 1→1.8 + opacity 1→0，0.5s ease-out）
//    + 「完美，拍！」（haptic 由 A2 觸發，此處不重複）。
//  - 首次進教練模式教學浮層（一次性，AppStorage "coach.tutorial.shown"）。
//  - 分數 chip / 建議膠囊 / debug 小字沿用既有語彙不動。
//
//  座標鐵律：NPoint 屬 NormalizedFrame（左上原點、y 向下、0…1）；
//  preview 是 aspect-FILL（buffer 長寬比 ≠ 螢幕），一律經 AspectFillMapper
//  映射成 container 絕對 pt，不可直接乘 view 尺寸。
//  aspect-fill = 均勻縮放 + 置中裁切 → content (0.5, 0.5) 恆映射到 container 中心，
//  故準星畫在 container 中心即與 marker 抵達 (0.5, 0.5) 的位置重合。
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
    /// 首次進教練模式教學浮層（一次性；點擊或首次鎖定即永久關閉）。
    @AppStorage("coach.tutorial.shown") private var tutorialShown = false

    var body: some View {
        let lockState = session.lockState
        let isLocked = lockState == .locked
        let aim = session.aim
        let closeness = aimCloseness
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)

        // ── 標記顯示幾何（v0.4.0 修正輪：夾取改在 container pt 空間）──
        // preview 是 full-bleed aspect-fill：content 3:4 蓋滿更窄長的螢幕
        // （~9:19.5）時左右各裁掉 ~19% content — content-normalized 的
        // aim.clamped [0.06, 0.94] 映射後可能仍在被裁區（marker 消失且無
        // chevron）甚至 container 外（393pt 寬螢幕上 x=0.94 映射 ~+466pt、
        // 0.06 映射 ~−72pt → chevron 永遠不可見）。水平 pan 正是本輪主要
        // 矯正軸，偏移一大導引就整個蒸發。
        // 改法：映射「未夾取」的 aim.marker（AspectFillMapper 是線性映射，
        // 出界點合法），在 pt 空間對 container 內縮 24pt 的可視框判界：
        // 框內 → 畫標記；框外 → 夾到框邊畫 chevron（方向 = 映射點 − 中心）。
        // Core 的 AimState.clamped / isOffscreen 保留不動（契約與測試照舊），
        // 本 view 不再用它們定位。
        let visibleRect: CGRect = {
            let bounds = CGRect(origin: .zero, size: containerSize)
            let inset = bounds.insetBy(dx: 24, dy: 24)
            // container 過小（inset 後翻轉/空）→ 退回整個 bounds，不畫壞座標
            return (inset.isNull || inset.isEmpty) ? bounds : inset
        }()
        // 未夾取 marker 的映射 pt（可在 container 外；無 aim 時 nil）。
        let markerRawPt: CGPoint? = aim.flatMap { containerPoint($0.marker) }

        // 標記顯示位置：鎖定時吸進準星（= container 中心）；
        // 其餘時候 = 可視框內的映射 pt；框外／無 aim 不畫（畫 chevron／不畫）。
        let markerPosition: CGPoint? = {
            if isLocked { return center }
            guard let markerRawPt, visibleRect.contains(markerRawPt) else { return nil }
            return markerRawPt
        }()

        ZStack {
            // 固定準星（永遠不動；靠近提高不透明度、鎖定滿版 + 柔光）。
            reticle(closeness: closeness, isLocked: isLocked)
                .position(center)

            // 世界標記：60Hz 資料下的細補間；鎖定瞬間位置跳到中心 →
            // 同一 view 識別 + springFast = 「吸進準星」動畫。
            if let markerPosition {
                marker(closeness: isLocked ? 1 : closeness, isLocked: isLocked)
                    .position(markerPosition)
                    .animation(
                        isLocked ? Tokens.springFast : .linear(duration: 0.05),
                        value: markerPosition
                    )
            }

            // 出界（= 映射 pt 在可視框外，含「content 被 aspect-fill 裁掉」區）：
            // 貼邊 chevron（指向出界方向）+ 呼吸。位置 = 映射 pt 夾進可視框。
            if !isLocked, let markerRawPt, !visibleRect.contains(markerRawPt) {
                let edge = CGPoint(
                    x: min(max(markerRawPt.x, visibleRect.minX), visibleRect.maxX),
                    y: min(max(markerRawPt.y, visibleRect.minY), visibleRect.maxY)
                )
                offscreenChevron(angle: chevronAngle(from: markerRawPt))
                    .position(edge)
                    .animation(.linear(duration: 0.05), value: edge)
            }

            // 鎖定慶祝：白圈自準星合體處爆開（結束後 opacity 0 不可見；解鎖即移除）。
            if isLocked {
                Circle()
                    .stroke(Tokens.fg, lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .scaleEffect(lockBurst ? 1.8 : 1)
                    .opacity(lockBurst ? 0 : 1)
                    .position(center)
                    .allowsHitTesting(false)
            }

            scoreReadout

            advicePill(isLocked: isLocked)

            tutorialCard(isLocked: isLocked)

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
                // 用戶已成功對準一次 → 教學不需再出現。
                if !tutorialShown {
                    withAnimation(Tokens.springAppear) {
                        tutorialShown = true
                    }
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
    /// 映射是線性（均勻縮放 + 平移），0…1 之外的點（未夾住的 marker）同樣成立。
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

    /// aimDistance → 0…1 靠近度（distance 0.25→0.05 映射 0→1；nil = 0）。
    private var aimCloseness: Double {
        guard let d = session.aimDistance else { return 0 }
        return min(max((0.25 - d) / 0.20, 0), 1)
    }

    /// 出界 chevron 指向 =「未夾取 marker 的映射 pt − container 中心」
    /// （pt 空間的精確視覺方向；aspect-fill 映射是線性，出界點照樣可映射）。
    /// 螢幕座標 x 右、y 下；SwiftUI rotationEffect 正角 = 順時針 →
    /// atan2(dy, dx) 直接可用；基底圖示 chevron.right 指向 +x。
    /// dx=dy=0 不可達（中心恆在可視框內，框外點必偏離中心）— 防禦回 .zero。
    private func chevronAngle(from markerPt: CGPoint) -> Angle {
        let dx = markerPt.x - containerSize.width / 2
        let dy = markerPt.y - containerSize.height / 2
        guard dx != 0 || dy != 0 else { return .zero }
        return .radians(Double(atan2(dy, dx)))
    }

    // MARK: - 固定準星

    /// 24pt 細圈（1pt 白）+ 內部 4 條 3pt 刻線（上下左右缺口 reticle 風格）。
    /// idle 60% 透明度；靠近（closeness）提高到 100%；鎖定滿版 + 白色柔光。
    /// 疊一層極淡黑影確保亮背景可見。
    private func reticle(closeness: Double, isLocked: Bool) -> some View {
        ReticleShape()
            .stroke(Tokens.fg, lineWidth: 1)
            .frame(width: 24, height: 24)
            .opacity(isLocked ? 1 : 0.6 + 0.4 * closeness)
            .shadow(color: Color.black.opacity(0.5), radius: 1)
            .shadow(
                color: .white.opacity(isLocked ? 0.9 : 0.5 * closeness),
                radius: isLocked ? 8 : 6 * CGFloat(closeness)
            )
            .animation(Tokens.animation, value: isLocked)
            .animation(.linear(duration: 0.1), value: closeness)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - 世界標記

    /// 36pt 外圈 + 10pt 實心白點（Measure 風格）。
    /// 靠近準星（closeness 0→1）外圈 1.5→3pt 變粗、白色柔光漸強；
    /// 黑描邊／黑影確保亮背景可見。
    private func marker(closeness: Double, isLocked: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(Tokens.fg, lineWidth: 1.5 + 1.5 * CGFloat(closeness))
                .frame(width: 36, height: 36)
            Circle()
                .fill(Tokens.fg)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
        }
        .shadow(color: Color.black.opacity(0.4), radius: 1)
        .shadow(color: .white.opacity(0.7 * closeness), radius: 8 * CGFloat(closeness))
        .animation(.linear(duration: 0.1), value: closeness)
        .animation(Tokens.animation, value: isLocked)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 出界 chevron

    /// 標記出界：貼邊（映射 pt 夾進 container 可視框，body 內處理）chevron
    /// 指向出界方向 + 呼吸。
    /// 呼吸 opacity 0.5↔1.0（單程 0.9s，TimelineView 驅動，免 repeatForever 殘留）。
    private func offscreenChevron(angle: Angle) -> some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // sin 週期 1.8s → 0.5 → 1.0 → 0.5，每方向 0.9s。
            let breathe = 0.5 + 0.5 * (sin(t * .pi / 0.9) + 1) / 2
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Tokens.fg)
                .shadow(color: Color.black.opacity(0.6), radius: 2)
                .rotationEffect(angle)
                .opacity(breathe)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 教學浮層（一次性）

    /// 首次進教練模式顯示：半透明玻璃卡「把標記點對進中央準星」+ 小圖示；
    /// 點擊消失（AppStorage 永久記住）；首次鎖定也視為已學會自動關閉。
    /// 位置放畫面下方 ~0.68 高度：不擋準星（中心）、建議膠囊（0.25）與分數（0.15）。
    @ViewBuilder
    private func tutorialCard(isLocked: Bool) -> some View {
        ZStack {
            if !tutorialShown && !isLocked {
                VStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Tokens.fg)
                    Text("把標記點對進中央準星")
                        .font(Tokens.label(15, weight: .semibold))
                        .foregroundStyle(Tokens.fg)
                    Text("朝標記方向轉動手機，標記會滑向準星")
                        .font(Tokens.label(12))
                        .foregroundStyle(Tokens.gray1.opacity(0.85))
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .dsGlass(cornerRadius: 4)
                .onTapGesture {
                    withAnimation(Tokens.springAppear) {
                        tutorialShown = true
                    }
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("教學：把標記點對進中央準星。點擊關閉")
            }
        }
        .animation(Tokens.springAppear, value: tutorialShown)
        .position(x: containerSize.width / 2, y: containerSize.height * 0.68)
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
        let distanceText = session.aimDistance.map { String(format: "%.3f", $0) } ?? "–"
        let offscreenText = session.aim?.isOffscreen == true ? " out" : ""
        return Text("\(Int(session.smoothedScore.rounded())) \(Self.glyph(for: lockState)) d=\(distanceText)\(offscreenText)")
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

// MARK: - 準星 Shape

/// 24pt reticle：外圈細圓 + 上下左右 4 條由圈緣向內 3pt 的刻線（中心留空）。
/// 單一 path 一次 stroke（1pt），黑白 UI 不需分層上色。
private struct ReticleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let tick: CGFloat = 3

        // 外圈。
        path.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        // 上刻線（圈緣向內 3pt；下同）。
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x, y: center.y - radius + tick))
        // 下刻線。
        path.move(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius - tick))
        // 左刻線。
        path.move(to: CGPoint(x: center.x - radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x - radius + tick, y: center.y))
        // 右刻線。
        path.move(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + radius - tick, y: center.y))

        return path
    }
}
