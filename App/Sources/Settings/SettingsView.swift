//  SettingsView.swift
//  AICam — 設定頁（跨模組契約，A4 擁有；本輪 A3 依契約重排 + 實作模型選擇 UI）。
//
//  區塊：AI 導演（開關 / Gemini API Key / 模型選擇 / 測試連線）、
//        AI 智慧（構圖模型 / AI 代操曝光，v0.3.0）、
//        調色（即時濾鏡預覽 / AI 自動選 Look / 同時保留原圖，v0.3.0）、
//        教練（自動抓拍 / 導演即時建議，P2）、
//        拍攝（網格線 P0 佔位）、關於（版本）。
//  模型選擇（跨模組契約）：
//  - director.modelMode："auto"（推薦，預設）| "custom"
//  - auto：即時導演走 gemini-flash-lite-latest（低延遲）、拍後走 gemini-flash-latest（品質）
//    （官方別名，永遠指向最新 flash / flash-lite 版本；A4 讀 keys，此處只讀寫）。
//  - custom：director.model.live / director.model.post 兩欄自訂。
//  API Key 只存本機 Keychain（"gemini-api-key"），不進 UserDefaults；
//  全部繁體中文、§9 黑白 tokens（無彩色 accent，層次靠灰階 icon 磚 + Section 呼吸）。

import SwiftUI

@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    // MARK: - 持久化設定

    @AppStorage("director.enabled") private var directorEnabled = false
    /// 模型選擇模式："auto"（推薦）| "custom"（跨模組契約 key）。
    @AppStorage("director.modelMode") private var directorModelMode = "auto"
    /// 自訂時的即時導演模型（低延遲場景）。
    @AppStorage("director.model.live") private var directorModelLive = "gemini-flash-lite-latest"
    /// 自訂時的拍後建議模型（品質場景）。
    @AppStorage("director.model.post") private var directorModelPost = "gemini-flash-latest"
    @AppStorage("director.live") private var directorLive = false
    @AppStorage("coach.autoCapture") private var coachAutoCapture = false
    @AppStorage("grid.enabled") private var gridEnabled = false
    /// v0.3.0 AI 智慧（跨模組契約 keys；預設皆 true）。
    @AppStorage("coach.model.enabled") private var coachModelEnabled = true
    @AppStorage("ai.control.enabled") private var aiControlEnabled = true
    /// v0.3.0 調色（跨模組契約 keys）。
    @AppStorage("look.livePreview") private var lookLivePreview = true
    @AppStorage("look.autoApply") private var lookAutoApply = false
    @AppStorage("look.keepOriginal") private var lookKeepOriginal = false

    // MARK: - 畫面狀態

    @State private var apiKey = ""
    @State private var hasLoadedKey = false
    /// Keychain 目前已持久化的值（trim 後）。persistAPIKey 據此跳過相同值 —
    /// 不做逐鍵 Keychain round-trip，也不把打到一半的 key 片段持久化。
    @State private var savedKey = ""
    @State private var connectionTest: ConnectionTestState = .idle

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private static let keychainKey = "gemini-api-key"
    /// Form 列底色（深灰階，維持純黑白 UI）。
    private static let rowBackground = Color(white: 0.09)
    /// icon 磚底色。
    private static let iconTileBackground = Color(white: 0.17)

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                directorSection
                aiSection
                lookSection
                coachSection
                captureSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.bg.ignoresSafeArea())
            .animation(Tokens.springAppear, value: directorModelMode)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        persistAPIKey()
                        dismiss()
                    }
                    .font(Tokens.label(15, weight: .semibold))
                    .foregroundStyle(Tokens.fg)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.fg)
        .onAppear {
            guard !hasLoadedKey else { return }
            hasLoadedKey = true
            let stored = KeychainStore.get(forKey: Self.keychainKey) ?? ""
            savedKey = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKey = stored
        }
        // sheet 下滑關閉等未經「完成」的離開路徑也要落盤。
        .onDisappear {
            persistAPIKey()
        }
    }

    // MARK: - AI 導演

    private var directorSection: some View {
        Section {
            Toggle(isOn: $directorEnabled) {
                settingLabel("導演建議", icon: "wand.and.stars")
            }
            .tint(Tokens.gray2)

            HStack(spacing: 12) {
                iconTile("key")
                SecureField("Gemini API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .foregroundStyle(Tokens.gray1)
                    // 逐鍵只清測試狀態；Keychain 寫入延到 onSubmit / 測試連線前 /
                    // 離開頁面（persistAPIKey）一次落盤 — 不做逐鍵 Keychain I/O。
                    .onChange(of: apiKey) { _, _ in
                        if connectionTest != .testing {
                            connectionTest = .idle
                        }
                    }
                    .onSubmit {
                        persistAPIKey()
                    }
            }

            VStack(alignment: .leading, spacing: 12) {
                settingLabel("模型", icon: "cpu")
                Picker("模型選擇", selection: $directorModelMode) {
                    Text("自動（推薦）").tag("auto")
                    Text("自訂").tag("custom")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 2)

            if directorModelMode == "custom" {
                HStack(spacing: 12) {
                    Text("即時模型")
                        .foregroundStyle(Tokens.fg)
                    TextField("gemini-flash-lite-latest", text: $directorModelLive)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .font(Tokens.mono(14))
                        .foregroundStyle(Tokens.gray1)
                }
                HStack(spacing: 12) {
                    Text("拍後模型")
                        .foregroundStyle(Tokens.fg)
                    TextField("gemini-flash-latest", text: $directorModelPost)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .font(Tokens.mono(14))
                        .foregroundStyle(Tokens.gray1)
                }
            }

            Button {
                runConnectionTest()
            } label: {
                HStack(spacing: 12) {
                    settingLabel("測試連線", icon: "antenna.radiowaves.left.and.right")
                    Spacer(minLength: 8)
                    connectionTestStatus
                }
            }
            .disabled(connectionTest == .testing)
        } header: {
            sectionHeader("AI 導演")
        } footer: {
            Text("拍照後由 Gemini 給一句下一步建議；API Key 只儲存在本機 Keychain。自動模式：即時建議走 flash-lite（低延遲）、拍後建議走 flash（品質），永遠指向 Google 最新版本。")
                .font(Tokens.label(12))
                .foregroundStyle(Tokens.gray2)
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    /// 測試連線右側狀態（轉圈 / 結果 pop）。
    @ViewBuilder
    private var connectionTestStatus: some View {
        ZStack {
            switch connectionTest {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .tint(Tokens.gray2)
                    .transition(.opacity)
            case .success:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("連線成功")
                        .font(Tokens.label(13, weight: .medium))
                }
                .foregroundStyle(Tokens.fg)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .failure(let reason):
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(reason)
                        .font(Tokens.label(13))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .foregroundStyle(Tokens.gray2)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Tokens.springAppear, value: connectionTest)
    }

    // MARK: - AI 智慧（v0.3.0）

    private var aiSection: some View {
        Section {
            Toggle(isOn: $coachModelEnabled) {
                HStack(spacing: 12) {
                    iconTile("sparkles")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 構圖模型")
                        Text("教練模式以本機模型輔助構圖評分")
                            .font(Tokens.label(12))
                            .foregroundStyle(Tokens.gray2)
                    }
                }
            }
            .tint(Tokens.gray2)

            Toggle(isOn: $aiControlEnabled) {
                HStack(spacing: 12) {
                    iconTile("sun.max")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 代操曝光")
                        Text("逆光、過曝時自動微調，可隨時復原")
                            .font(Tokens.label(12))
                            .foregroundStyle(Tokens.gray2)
                    }
                }
            }
            .tint(Tokens.gray2)
        } header: {
            sectionHeader("AI 智慧")
        } footer: {
            Text("構圖模型全程在本機執行（驗證集 0.865）；模型分數是相對排序參考、非絕對品質。AI 代操的每個動作都會在取景器顯示提示，並可一鍵復原。")
                .font(Tokens.label(12))
                .foregroundStyle(Tokens.gray2)
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    // MARK: - 調色（v0.3.0）

    private var lookSection: some View {
        Section {
            Toggle(isOn: $lookLivePreview) {
                settingLabel("即時濾鏡預覽", icon: "camera.filters")
            }
            .tint(Tokens.gray2)

            Toggle(isOn: $lookAutoApply) {
                HStack(spacing: 12) {
                    iconTile("wand.and.rays")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 自動選 Look")
                        Text("依場景自動切換推薦 Look")
                            .font(Tokens.label(12))
                            .foregroundStyle(Tokens.gray2)
                    }
                }
            }
            .tint(Tokens.gray2)

            Toggle(isOn: $lookKeepOriginal) {
                settingLabel("同時保留原圖", icon: "square.on.square")
            }
            .tint(Tokens.gray2)
        } header: {
            sectionHeader("調色")
        } footer: {
            Text("即時濾鏡預覽在取景器直接呈現選中 Look，關閉可省電。同時保留原圖會在套用 Look 時額外儲存一張未調色的原始照片。")
                .font(Tokens.label(12))
                .foregroundStyle(Tokens.gray2)
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    // MARK: - 教練

    private var coachSection: some View {
        Section {
            Toggle(isOn: $coachAutoCapture) {
                HStack(spacing: 12) {
                    iconTile("camera.viewfinder")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動抓拍")
                        Text("對齊鎖定且表情到位時自動拍攝")
                            .font(Tokens.label(12))
                            .foregroundStyle(Tokens.gray2)
                    }
                }
            }
            .tint(Tokens.gray2)

            Toggle(isOn: $directorLive) {
                HStack(spacing: 12) {
                    iconTile("bubble.left.and.bubble.right")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("導演即時建議")
                        Text("教練模式下每 10 秒給一句現場建議（需 API Key）")
                            .font(Tokens.label(12))
                            .foregroundStyle(Tokens.gray2)
                    }
                }
            }
            .tint(Tokens.gray2)
        } header: {
            sectionHeader("教練")
        } footer: {
            Text("教練模式的目標環與分數環永遠在本機即時計算，不需網路。")
                .font(Tokens.label(12))
                .foregroundStyle(Tokens.gray2)
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    // MARK: - 拍攝

    private var captureSection: some View {
        Section {
            Toggle(isOn: $gridEnabled) {
                settingLabel("網格線", icon: "grid")
            }
            .tint(Tokens.gray2)
        } header: {
            sectionHeader("拍攝")
        } footer: {
            Text("RAW 與手動控制將在 P1 開通")
                .font(Tokens.label(12))
                .foregroundStyle(Tokens.gray2)
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    // MARK: - 關於

    private var aboutSection: some View {
        Section {
            HStack(spacing: 12) {
                iconTile("info")
                Text("版本")
                Spacer()
                Text(appVersion)
                    .font(Tokens.mono(15))
                    .foregroundStyle(Tokens.gray2)
            }
        } header: {
            sectionHeader("關於")
        } footer: {
            Text("AICam — AI 攝影教練相機")
                .font(Tokens.label(12))
                .foregroundStyle(Tokens.gray2)
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    // MARK: - 動作與輔助

    /// 把輸入的 API Key 一次寫入 Keychain（trim 後與現值相同則跳過；
    /// 空值 = 刪除項目）。onSubmit / 測試連線前 / 完成 / 離開頁面時呼叫。
    private func persistAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedKey else { return }
        if trimmed.isEmpty {
            KeychainStore.delete(forKey: Self.keychainKey)
        } else {
            KeychainStore.set(trimmed, forKey: Self.keychainKey)
        }
        savedKey = trimmed
    }

    private func runConnectionTest() {
        // healthCheck 從 Keychain 讀 key → 測試前先落盤，否則測到的是舊 key。
        persistAPIKey()
        connectionTest = .testing
        Task {
            let result = await GeminiDirectorService.shared.healthCheck()
            switch result {
            case .success:
                connectionTest = .success
            case .failure(let error):
                connectionTest = .failure(failureReason(for: error))
            }
        }
    }

    /// 錯誤 → 一句對用戶顯示的原因（DirectorServiceError 已是繁中；其餘用系統描述）。
    private func failureReason(for error: Error) -> String {
        if let serviceError = error as? DirectorServiceError,
           let description = serviceError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// 灰階 icon 磚（26pt 圓角方塊 + SF Symbol），設定列統一視覺。
    private func iconTile(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Tokens.fg)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.iconTileBackground)
            )
    }

    /// icon 磚 + 標題（設定列標準版型）。
    private func settingLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            iconTile(icon)
            Text(title)
                .foregroundStyle(Tokens.fg)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Tokens.label(12, weight: .medium))
            .foregroundStyle(Tokens.gray2)
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
