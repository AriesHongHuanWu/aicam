//  RootView.swift
//  AICam — 主畫面版面（A4：UI 整合擁有本檔）。
//
//  依賴其他模組（同一 module「AICam」，不需 import）：
//  - CameraController / LensOption / PreviewSource / PreviewLayerView（A2，Capture）
//  - CoachSession（A2，Coach）；CoachOverlayView（A3，Coach）
//  - DirectorCenter / DirectorTipBanner / SettingsView（A4，Director）
//  - MetalPreviewView（A3，Preview）；LookSuggester（A3，ColorLab）
//  - AIControlToast / AIControlCenter（A2，AI 代操）
//  - LookRecipe（AICamCore，A3 擁有定義）
//
//  v0.3.0「AI 全面接管」UI 整合：
//  - 預覽切換：look.livePreview 且 Metal 未失敗 → MetalPreviewView（即時 Look）；
//    否則 PreviewLayerView。Metal 失敗只影響本次（AppStorage 不動）。
//  - Look 選擇列（拍照＋教練模式，鏡頭列上方）：原色＋12 款膠囊 chips、
//    推薦前 3 名白點徽記；look.autoApply 開時每 5s 自動切 top-1
//    （手動選過後 30s 內不搶）。
//  - 教練 HUD：水平儀（|roll|<6° 顯示、<0.8° snap 白＋輕 haptic＋0.8s 後淡出）、
//    過曝章（highlightClippedFraction > 0.10）、AIControlToast。
//  - CoachSession facts → LookSuggester.ingest（每次 publish；hasFace 走同名參數）。
//  - v0.3.0 修正輪：tap 由 CameraController 擁有（camera.videoTap）；Metal 取景器
//    的帧流由 updatePreviewFrameFlow 依可見性開關（與教練需求在 camera 端仲裁）；
//    AIControlCenter.shared.camera 於 .task 接線。
//
//  v0.5.0「分割特效引擎」UI 整合：
//  - MetalPreviewView 改 renderProvider 契約簽名：同時回 (LookRecipe, EffectRecipe)；
//    effect.liveEnabled 關閉或選「無」→ 回 EffectRecipe.none（取景器零特效成本，
//    拍攝烘焙不受影響 — 烘焙管線自讀 effect.selected）。
//  - 特效列（EffectBar）：Look 列下方膠囊 chips（無/跳色/虛化/聚光/雙色調），
//    只在拍照/教練模式顯示；選非 none 且 MaskStore 連續 >2s 無 mask →
//    選中 chip 小警示點 + toast 一次「畫面中未偵測到人物」。
//  - 合照小標（GroupModeBadge）：≥2 臉（與 A3 群組構圖同判準）時取景器上緣灰字。
//
//  既有（v0.2.1，不可破壞）：快門白閃、細膩黑漸層、權限提示頁、教練接線、導演。

import AICamCore
import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @State private var camera = CameraController()
    /// P2 教練 session：init 需引用 camera，而 @State 初始器內拿不到另一個
    /// @State 的值，故延後到 .task 內 lazy 建立（optional）。
    @State private var coach: CoachSession?
    @AppStorage("mode") private var mode: CaptureMode = .photo
    @AppStorage("director.live") private var directorLive = false
    /// Metal 即時濾鏡預覽開關（跨模組契約 key；預設 true）。
    @AppStorage("look.livePreview") private var lookLivePreview = true
    /// 目前選中 Look 的 id（跨模組契約 key；"none" = 原色）。
    @AppStorage("look.selected") private var selectedLookID = "none"
    /// AI 自動選 Look（跨模組契約 key；預設 false）。
    @AppStorage("look.autoApply") private var lookAutoApply = false
    /// 目前選中特效的 id（v0.5.0 跨模組契約 key；"none" = 無特效）。
    @AppStorage("effect.selected") private var selectedEffectID = "none"
    @State private var isSettingsPresented = false
    /// 「畫面中未偵測到人物」toast 顯示中（EffectBar 無 mask 偵測觸發，一次性）。
    @State private var noSubjectToastVisible = false
    /// 快門擊發白閃疊層透明度。
    @State private var shutterFlashOpacity: Double = 0
    /// Metal 預覽本次啟動失敗 → fallback 到 PreviewLayerView。
    /// 只影響本次（look.livePreview 保持不動），重啟 app 會再試 Metal。
    @State private var metalFailed = false
    /// 用戶最近一次「手動」選 Look 的時刻；自動選 Look 30 秒內不搶。
    @State private var lastManualLookAt = Date.distantPast

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()

            // GeometryReader 取得 preview 實際 container 尺寸（full-bleed），
            // 供 CoachOverlayView 的 AspectFillMapper 映射用。
            GeometryReader { geo in
                ZStack {
                    // 預覽切換：Metal 即時 Look 預覽（失敗即本次退回 Layer）。
                    // 教練 overlay 疊在兩種 preview 上都要正常 → 同一 ZStack 內。
                    if lookLivePreview && !metalFailed {
                        MetalPreviewView(
                            tap: camera.videoTap,
                            renderProvider: {
                                (Self.currentPreviewRecipe(), Self.currentPreviewEffect())
                            },
                            onFailure: {
                                // 可能自渲染執行緒回呼 → hop 回 MainActor 再改 @State
                                Task { @MainActor in
                                    metalFailed = true
                                }
                            }
                        )
                    } else {
                        PreviewLayerView(source: camera.previewSource)
                    }
                    if mode == .coach, let coach {
                        CoachOverlayView(session: coach, containerSize: geo.size)
                    }
                }
            }
            .ignoresSafeArea()

            // 頂部細膩黑漸層（狀態列可讀性；不擋操作）。
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 130)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // 教練 HUD（水平儀＋過曝章）＋ Look 推薦餵料。
            // facts 只在教練模式發布 → 其他模式自動隱藏／不動作，不需 mode 判斷。
            if let coach {
                LookSuggestionFeeder(session: coach)
                CoachHUD(session: coach)
                    .allowsHitTesting(false)
                // 合照小標（v0.5.0）：≥2 臉時取景器上緣置中灰字。
                // facts 只在教練模式發布 → 其他模式自動隱藏，不需 mode 判斷。
                GroupModeBadge(session: coach)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 56)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                StatusStrip { isSettingsPresented = true }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                // 尚未開通的模式只顯示極淡模式名（教練已於 P2 開通，改由 overlay 呈現）。
                if mode == .pro || mode == .review {
                    Text(mode.displayName)
                        .font(Tokens.label(12, weight: .medium))
                        .foregroundStyle(Tokens.fg.opacity(0.3))
                        .padding(.top, 12)
                        .transition(.opacity)
                }

                Spacer()

                if camera.status == .failed {
                    Text("相機啟動失敗")
                        .font(Tokens.label(13))
                        .foregroundStyle(Tokens.gray2)
                    Spacer()
                }

                DirectorTipBanner()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)

                // AI 代操動作提示（疊在底部控制區上方；自身管理顯示/消失）。
                AIControlToast()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)

                // 特效無人物警示 toast（v0.5.0；showNoSubjectToast 觸發、自動淡出）。
                if noSubjectToastVisible {
                    Text("畫面中未偵測到人物")
                        .font(Tokens.label(13))
                        .foregroundStyle(Tokens.gray1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .dsGlassCapsule()
                        .padding(.bottom, 4)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                controls
            }

            // 快門白閃疊層（最上層、不擋觸控）。
            Color.white
                .ignoresSafeArea()
                .opacity(shutterFlashOpacity)
                .allowsHitTesting(false)

            if camera.status == .denied {
                deniedOverlay
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .task {
            camera.onPhotoCaptured = { data in
                Task { @MainActor in
                    DirectorCenter.shared.photoCaptured(jpeg: data)
                }
            }
            // 拍照處理背景 queue 呼叫：回目前選中 Look（原色 = nil 不套）。
            camera.captureLookProvider = { Self.currentCaptureLook() }
            // AI 代操曝光接線（A2 契約①）：CoachSession publish → evaluate 時
            // camera 必須已接上，否則規則永不動作。
            AIControlCenter.shared.camera = camera
            await camera.start()
            // 冪等：非教練模式也掛 tap，供 Metal 即時濾鏡預覽取帧（A2 契約）；
            // 並依 Metal 取景器可見性開出帧（教練模式外也要有帧流）。
            camera.attachVideoTapIfNeeded()
            updatePreviewFrameFlow()
            if coach == nil {
                coach = CoachSession(camera: camera)
            }
            updateCoachWiring()
        }
        // AI 自動選 Look：每 5s 檢查一次 top-1（開關切換即重啟/取消 loop）。
        .task(id: lookAutoApply) {
            guard lookAutoApply else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                autoApplyTopLook()
            }
        }
        .onChange(of: mode) { _, _ in
            updateCoachWiring()
        }
        .onChange(of: directorLive) { _, _ in
            updateCoachWiring()
        }
        .onChange(of: lookLivePreview) { _, _ in
            // 設定頁切換即時預覽：補掛 tap（冪等）並重算出帧需求。
            updatePreviewFrameFlow()
        }
        .onChange(of: metalFailed) { _, _ in
            // Metal 失敗 fallback 到 PreviewLayerView：預覽端不再需要帧流
            //（教練模式的需求由 CoachSession 自行表態，仲裁在 CameraController）。
            updatePreviewFrameFlow()
        }
    }

    /// Metal 即時濾鏡取景器的帧流開關（v0.3.0 修正輪）：
    /// 取景器可見（look.livePreview 開且 Metal 未失敗）→ 確保 tap 已掛 + 開出帧；
    /// 不可見 → 關「預覽端」出帧需求（教練模式的需求另行仲裁，不受影響）。
    /// 呼叫時機：.task 啟動後、look.livePreview 變更、metalFailed 變更。
    private func updatePreviewFrameFlow() {
        let metalVisible = lookLivePreview && !metalFailed
        if metalVisible {
            camera.attachVideoTapIfNeeded()
        }
        camera.setPreviewFramesEnabled(metalVisible)
    }

    // MARK: - 底部控制區

    private var controls: some View {
        VStack(spacing: 16) {
            // Look 選擇列＋特效列：拍照＋教練模式，鏡頭列上方（v0.3.0 / v0.5.0）。
            if mode == .photo || mode == .coach {
                VStack(spacing: 8) {
                    LookBar(selectedID: $selectedLookID) {
                        lastManualLookAt = Date()
                    }
                    EffectBar(
                        selectedID: $selectedEffectID,
                        // Metal 取景器可見才可能有即時 mask（FrameAnalyzer 分割
                        // 守門同判準）— 不可見時監測必須停，否則必然誤報。
                        masksExpected: lookLivePreview && !metalFailed
                    ) {
                        showNoSubjectToast()
                    }
                }
                .transition(.opacity)
            }

            LensBar(
                options: camera.lensOptions,
                selectedID: camera.currentLens?.id
            ) { camera.select(lens: $0) }

            HStack {
                ThumbnailButton(image: camera.lastThumbnail) {
                    openSystemPhotoAlbum()
                }
                Spacer()
                ShutterButton(score: coachScore) {
                    triggerShutterFlash()
                    Task { await camera.capturePhoto() }
                }
                .opacity(camera.isCapturing ? 0.4 : 1)
                .disabled(camera.isCapturing)
                Spacer()
                FlipButton {
                    Task { await camera.flipCamera() }
                }
            }
            .padding(.horizontal, 32)

            ModeCarousel(mode: $mode)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Look（v0.3.0）

    /// AppStorage "look.selected" 目前值（任意執行緒；UserDefaults 執行緒安全）。
    /// Metal renderProvider / captureLookProvider 可能在 view 外／背景 queue 呼叫 →
    /// 不經 @AppStorage wrapper（view 外讀取語意未定義），直讀 UserDefaults。
    nonisolated private static func selectedRecipeID() -> String {
        UserDefaults.standard.string(forKey: "look.selected") ?? LookRecipe.passthrough.id
    }

    /// 目前選中 recipe（查無 id 時回 passthrough，防呆）。Metal 預覽逐帧呼叫。
    nonisolated private static func currentPreviewRecipe() -> LookRecipe {
        let id = selectedRecipeID()
        return LookRecipe.all.first { $0.id == id } ?? .passthrough
    }

    /// captureLookProvider 用：原色（passthrough）回 nil = 拍照不套 Look（A2 契約）。
    nonisolated private static func currentCaptureLook() -> LookRecipe? {
        let recipe = currentPreviewRecipe()
        return recipe.id == LookRecipe.passthrough.id ? nil : recipe
    }

    // MARK: - 特效（v0.5.0）

    /// renderProvider 的 effect 端（任意執行緒；直讀 UserDefaults，理由同上）。
    /// effect.liveEnabled 關閉 → 取景器一律回 none（特效僅在拍攝成品套用；
    /// 烘焙管線自讀 effect.selected，不經本函式）。@AppStorage 宣告的預設值
    /// 不會寫入 UserDefaults → 以 object(forKey:) 判「無值」套預設 true。
    nonisolated private static func currentPreviewEffect() -> EffectRecipe {
        let liveEnabled =
            UserDefaults.standard.object(forKey: "effect.liveEnabled") as? Bool ?? true
        guard liveEnabled else { return EffectRecipe.none }
        let id = UserDefaults.standard.string(forKey: "effect.selected") ?? EffectRecipe.none.id
        return EffectRecipe.all.first { $0.id == id } ?? EffectRecipe.none
    }

    /// 顯示「畫面中未偵測到人物」toast（2.5s 後自動淡出；顯示中不重複觸發）。
    private func showNoSubjectToast() {
        guard !noSubjectToastVisible else { return }
        withAnimation(Tokens.springAppear) {
            noSubjectToastVisible = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(Tokens.springAppear) {
                noSubjectToastVisible = false
            }
        }
    }

    /// look.autoApply 開時每 5s 呼叫：自動切到推薦 top-1。
    /// 手動選過後 30s 內不搶；只在 Look 列可見的模式（拍照/教練）動作。
    private func autoApplyTopLook() {
        guard lookAutoApply, mode == .photo || mode == .coach else { return }
        guard Date().timeIntervalSince(lastManualLookAt) >= 30 else { return }
        guard let top = LookSuggester.shared.suggestedIDs.first,
              top != selectedLookID,
              LookRecipe.all.contains(where: { $0.id == top })
        else { return }
        withAnimation(Tokens.springAppear) {
            selectedLookID = top
        }
    }

    // MARK: - 快門白閃

    /// 擊發瞬間全螢幕白閃：立即亮起 → 停留 ~70ms → 快速淡出。
    /// haptic 已由 ShutterButton 觸發，這裡不重複。
    private func triggerShutterFlash() {
        shutterFlashOpacity = 0.9
        withAnimation(.easeOut(duration: 0.2).delay(0.07)) {
            shutterFlashOpacity = 0
        }
    }

    // MARK: - 權限未開啟

    private var deniedOverlay: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: "camera")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Tokens.fg)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Color(white: 0.08)))
                    .overlay(Circle().strokeBorder(Tokens.glassHairline, lineWidth: Tokens.hairline))
                    .padding(.bottom, 28)

                Text("相機權限未開啟")
                    .font(Tokens.label(20, weight: .semibold))
                    .foregroundStyle(Tokens.fg)

                Text("AICam 需要相機權限才能擔任你的攝影教練。\n請在「設定」中允許相機存取。")
                    .font(Tokens.label(14))
                    .foregroundStyle(Tokens.gray2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 10)
                    .padding(.horizontal, 40)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("前往設定")
                        .font(Tokens.label(15, weight: .semibold))
                        .foregroundStyle(Tokens.bg)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Tokens.fg))
                }
                .buttonStyle(DSPressScaleButtonStyle())
                .padding(.top, 28)
            }
        }
    }

    // MARK: - 教練接線

    /// 教練模式 = coach 分析啟動；配合 director.live 開關接上／斷開導演即時建議。
    /// 呼叫時機：.task（coach 建立後）、mode 變更、director.live 變更。
    /// stopLive() 在未 startLive 時呼叫視為 no-op（A4 契約）。
    private func updateCoachWiring() {
        let inCoach = mode == .coach
        coach?.setActive(inCoach)
        if inCoach, directorLive, let coach {
            DirectorCenter.shared.startLive(
                snapshot: { await coach.snapshotJPEGAsync(maxDimension: 512) },
                context: { Self.liveContext(for: coach) }
            )
        } else {
            DirectorCenter.shared.stopLive()
        }
    }

    /// 教練模式時快門外圈的構圖分數；其他模式 nil（素圈）。
    /// 讀 displayScore（Int，只在整數值變化時發布）而非 smoothedScore（Double，
    /// 每次分析必變）：避免整個 RootView body 以 ~10fps 重算 diff。
    private var coachScore: Int? {
        guard mode == .coach, let coach else { return nil }
        return coach.displayScore
    }

    /// 給導演即時建議的簡短繁中脈絡（主體位置／分數／目前建議）。
    private static func liveContext(for coach: CoachSession) -> String? {
        guard let result = coach.result else { return nil }
        var parts = ["構圖分數 \(result.score)"]
        // 主體判斷加臉 fallback：FrameAnalyzer 在「有臉但無可信關節」時刻意不造
        // subjectBox（誠實原則）、熱降級也會停 body pose — 只看 subjectBox 會對著
        // 人臉卻告訴 Gemini「未偵測到主體」，導演會被誤導成畫面沒人。
        let subjectBox = coach.facts.flatMap { facts in
            facts.subjectBox ?? CompositionRules.primaryFace(facts)?.box
        }
        if let box = subjectBox {
            let h = box.midX < 1.0 / 3.0 ? "左" : (box.midX > 2.0 / 3.0 ? "右" : "中")
            let v = box.midY < 1.0 / 3.0 ? "上" : (box.midY > 2.0 / 3.0 ? "下" : "中")
            let region: String
            if h == "中" && v == "中" {
                region = "中央"
            } else if v == "中" {
                region = h + "側"
            } else if h == "中" {
                region = "中" + v
            } else {
                region = h + v
            }
            parts.append("主體在畫面\(region)")
        } else {
            parts.append("未偵測到主體")
        }
        if let advice = coach.advice {
            parts.append("目前建議：\(advice.message)")
        }
        return parts.joined(separator: "，")
    }

    // MARK: - 動作

    /// 開系統相簿 app；開不了就無動作。
    private func openSystemPhotoAlbum() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:]) { _ in }
    }
}

// MARK: - Look 選擇列（A4；只在拍照/教練模式顯示）

/// 橫向 scroll 膠囊 chips：「原色」＋12 款 Look。
/// 選中＝白底黑字；LookSuggester 推薦前 3 名 chip 右上白點徽記（選中者不畫，
/// 白點在白底上不可見）。點選 → selection haptic ＋ 寫入 AppStorage；
/// 選中變化（含自動選 Look）時自動捲到可見位置。
@MainActor
private struct LookBar: View {
    @Binding var selectedID: String
    /// 用戶手動點選時回呼（RootView 記時刻，供自動選 Look 30s 禮讓）。
    let onManualSelect: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LookRecipe.all) { recipe in
                        chip(recipe)
                            .id(recipe.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedID) { _, newID in
                withAnimation(Tokens.springAppear) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func chip(_ recipe: LookRecipe) -> some View {
        let isSelected = recipe.id == selectedID
        let isSuggested = LookSuggester.shared.suggestedIDs.contains(recipe.id)
        return Button {
            guard !isSelected else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            onManualSelect()
            withAnimation(Tokens.springFast) {
                selectedID = recipe.id
            }
        } label: {
            Text(recipe.name)
                .font(Tokens.label(12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Tokens.bg : Tokens.fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Capsule().fill(Tokens.fg)
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    }
                }
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : Tokens.glassHairline,
                        lineWidth: Tokens.hairline
                    )
                )
                .overlay(alignment: .topTrailing) {
                    if isSuggested && !isSelected {
                        Circle()
                            .fill(Tokens.fg)
                            .frame(width: 5, height: 5)
                            .shadow(color: Tokens.softShadow, radius: 2)
                            .offset(x: 1, y: -1)
                    }
                }
                .shadow(color: Tokens.softShadow, radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .animation(Tokens.springFast, value: isSelected)
        .accessibilityLabel("濾鏡 \(recipe.name)")
    }
}

// MARK: - 特效選擇列（A4；v0.5.0；只在拍照/教練模式顯示）

/// 橫向膠囊 chips：「無」＋跳色/虛化/聚光/雙色調（EffectRecipe.all，名稱來自配方）。
/// 選中＝白底黑字＋selection haptic（與 LookBar 同視覺語言）。
/// 選非 none 且 MaskStore 連續 >2s 無 mask → 選中 chip 右上小警示點（白底上黑點）、
/// 並經 onNoSubject 回呼 toast 一次（每次選擇最多一次；mask 出現即清警示）。
@MainActor
private struct EffectBar: View {
    @Binding var selectedID: String
    /// Metal 取景器可見（look.livePreview 開且未失敗）→ 分割管線才會產 mask
    /// （v0.5.0 修正輪；RootView 傳入）。false 時無 mask 是設計而非「沒偵測到
    /// 人物」→ 監測停跑。
    let masksExpected: Bool
    /// 無 mask 警示回呼（RootView 顯示「畫面中未偵測到人物」toast）。
    let onNoSubject: () -> Void

    /// 即時特效預覽開關：關閉時 FrameAnalyzer 不產 mask（設計如此，非「沒偵測到
    /// 人物」）→ 監測必須一併停掉，否則必然誤報 toast。
    @AppStorage("effect.liveEnabled") private var effectLiveEnabled = true

    /// 無 mask 警示點顯示中。
    @State private var noMaskWarning = false
    /// 本次選擇是否已 toast 過（契約：toast 一次）。
    @State private var hasToasted = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EffectRecipe.all) { recipe in
                    chip(recipe)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        // 無 mask 監測：每 1s 輪詢 MaskStore（@MainActor，本 view 同 actor 直讀）。
        // 選「無」、即時特效預覽關閉、或 Metal 取景器不可見（masksExpected=false）
        // 時整個 task 直接 return — 零輪詢成本（守恆契約）且不誤報；
        // 離開拍照/教練模式（view 卸載）、換選擇或切開關時 task 自動取消重建。
        .task(id: "\(selectedID)|\(effectLiveEnabled)|\(masksExpected)") {
            noMaskWarning = false
            hasToasted = false
            guard selectedID != EffectRecipe.none.id, effectLiveEnabled, masksExpected else {
                return
            }
            // 以「最後一次看到 mask」為基準；選擇時刻起算 → 至少 2s 後才可能警示。
            var lastMaskSeen = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if MaskStore.shared.latestMask != nil {
                    lastMaskSeen = Date()
                }
                let noMask = Date().timeIntervalSince(lastMaskSeen) > 2
                if noMask != noMaskWarning {
                    withAnimation(Tokens.springAppear) {
                        noMaskWarning = noMask
                    }
                }
                if noMask, !hasToasted {
                    hasToasted = true
                    onNoSubject()
                }
            }
        }
    }

    private func chip(_ recipe: EffectRecipe) -> some View {
        let isSelected = recipe.id == selectedID
        return Button {
            guard !isSelected else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(Tokens.springFast) {
                selectedID = recipe.id
            }
        } label: {
            Text(recipe.name)
                .font(Tokens.label(12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Tokens.bg : Tokens.fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Capsule().fill(Tokens.fg)
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    }
                }
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : Tokens.glassHairline,
                        lineWidth: Tokens.hairline
                    )
                )
                .overlay(alignment: .topTrailing) {
                    // 無 mask 警示點：只畫在選中的非 none chip 上；
                    // 白底 → 黑點內縮才可見（懸出邊界的部分會沒入黑背景）。
                    if isSelected, noMaskWarning, recipe.id != EffectRecipe.none.id {
                        Circle()
                            .fill(Tokens.bg)
                            .frame(width: 5, height: 5)
                            .offset(x: -3, y: 3)
                            .transition(.opacity)
                    }
                }
                .shadow(color: Tokens.softShadow, radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .animation(Tokens.springFast, value: isSelected)
        .accessibilityLabel("特效 \(recipe.name)")
    }
}

// MARK: - 合照小標（v0.5.0；≥2 臉 = 群組構圖，取景器上緣灰字）

/// 「合照」灰字小標：session.isGroupMode（CoachSession 專為本 view 發布的
/// 低頻 surface — 只在值變化時寫入，判準 = facts.faces.count >= 2、與 A3 群組
/// 構圖單一來源；v0.5.0 修正輪：原直讀 facts 逐帧 diff ~15fps，白付效能且
/// 判準重複兩處）。isGroupMode 只在教練模式發布（setActive(false) 清 false）
/// → 其他模式自動隱藏。
@MainActor
private struct GroupModeBadge: View {
    let session: CoachSession

    var body: some View {
        let isGroup = session.isGroupMode
        ZStack {
            if isGroup {
                Text("合照")
                    .font(Tokens.label(11, weight: .medium))
                    .foregroundStyle(Tokens.gray2)
                    .shadow(color: Color.black.opacity(0.5), radius: 2)
                    .transition(.opacity)
            }
        }
        .animation(Tokens.springAppear, value: isGroup)
    }
}

// MARK: - LookSuggester 餵料（零尺寸 view，隔離 15fps facts 觀察）

/// CoachSession 每次 publish（facts 變化）→ LookSuggester.ingest。
/// 獨立小 view：facts ~15fps 逐帧變，觀察範圍只限這裡，不讓 RootView 大 body 逐帧 diff。
/// hasFace 走 LookSuggester.ingest 的同名參數（v0.3.0 修正輪：舊版附加 "face"
/// sceneTags tag，但 suggester 的關鍵字表沒有 "face" → 人像優先規則從未觸發）。
@MainActor
private struct LookSuggestionFeeder: View {
    let session: CoachSession

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: session.facts) { _, newFacts in
                guard let facts = newFacts else { return }
                LookSuggester.shared.ingest(
                    sceneTags: facts.sceneTags,
                    histogram: facts.histogram,
                    hasFace: !facts.faces.isEmpty
                )
            }
    }
}

// MARK: - 教練 HUD（取景器內、克制；facts 只在教練模式發布 → 其他模式自動隱藏）

@MainActor
private struct CoachHUD: View {
    let session: CoachSession

    var body: some View {
        ZStack {
            HorizonLevelHUD(session: session)
            OverexposureBadge(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 56)
                .padding(.trailing, 16)
        }
    }
}

/// 水平儀：|roll| < 6° 且未水平時顯示中央短橫線（旋轉 roll 角、gray2）；
/// |roll| < 0.8° 時 snap 成白色＋輕 haptic（每次進入水平只觸發一次）、
/// 0.8s 後淡出。離開水平（1.0° 遲滯）重置，可再次觸發。
@MainActor
private struct HorizonLevelHUD: View {
    let session: CoachSession

    /// 已進入水平狀態（白線＋haptic 已觸發、淡出已排程）。
    @State private var leveled = false
    /// 淡出旗標（leveled 後延遲 0.8s 淡出）。
    @State private var fadedOut = false

    var body: some View {
        let roll = session.facts?.horizonRollDeg
        ZStack {
            if let roll, abs(roll) < 6 {
                Capsule()
                    .fill(leveled ? Tokens.fg : Tokens.gray2)
                    .frame(width: 72, height: 1.5)
                    .shadow(color: Color.black.opacity(0.5), radius: 1)
                    .rotationEffect(.degrees(roll))
                    .animation(Tokens.tween, value: roll)
                    .opacity(fadedOut ? 0 : 1)
            }
        }
        // facts 消失（離開教練模式）以 .infinity 代入 → 走重置分支。
        .onChange(of: roll ?? .infinity) { _, newValue in
            update(roll: newValue)
        }
    }

    private func update(roll: Double) {
        let magnitude = abs(roll)
        if leveled {
            // 離開水平（1.0° 遲滯，避免 0.8° 臨界抖動反覆觸發 haptic）→ 重置
            if magnitude > 1.0 {
                leveled = false
                fadedOut = false
            }
        } else if magnitude < 0.8 {
            leveled = true          // 顏色 snap 成白（無動畫補間）
            fadedOut = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.25).delay(0.8)) {
                fadedOut = true     // 停留 0.8s 後 0.25s 淡出
            }
        }
    }
}

/// 過曝章：histogram highlightClippedFraction > 0.10 顯示右上「過曝」小章。
/// 遲滯（>10% 顯示、<8% 隱藏）避免臨界值閃爍。
@MainActor
private struct OverexposureBadge: View {
    let session: CoachSession

    @State private var visible = false

    var body: some View {
        let fraction = session.facts?.histogram?.highlightClippedFraction ?? 0
        ZStack {
            if visible {
                Text("過曝")
                    .font(Tokens.label(11, weight: .medium))
                    .foregroundStyle(Tokens.gray1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .dsGlassCapsule()
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(Tokens.springAppear, value: visible)
        .onChange(of: fraction) { _, newValue in
            if !visible, newValue > 0.10 {
                visible = true
            } else if visible, newValue < 0.08 {
                visible = false
            }
        }
    }
}
