//  SettingsView.swift
//  AICam — 設定頁（跨模組契約，A4 擁有；RootView 以 sheet 呈現）。
//
//  區塊：AI 導演（開關 / Gemini API Key / 模型 / 測試連線）、
//        拍攝（網格線 P0 佔位）、關於（版本）。
//  API Key 只存本機 Keychain（"gemini-api-key"），不進 UserDefaults；
//  全部繁體中文、§9 黑白 tokens（無彩色 accent）。

import SwiftUI

@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    // MARK: - 持久化設定

    @AppStorage("director.enabled") private var directorEnabled = false
    @AppStorage("director.model") private var directorModel = "gemini-2.5-flash"
    @AppStorage("grid.enabled") private var gridEnabled = false

    // MARK: - 畫面狀態

    @State private var apiKey = ""
    @State private var hasLoadedKey = false
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

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                directorSection
                captureSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.bg.ignoresSafeArea())
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(Tokens.fg)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.fg)
        .onAppear {
            guard !hasLoadedKey else { return }
            hasLoadedKey = true
            apiKey = KeychainStore.get(forKey: Self.keychainKey) ?? ""
        }
    }

    // MARK: - AI 導演

    private var directorSection: some View {
        Section {
            Toggle("導演建議", isOn: $directorEnabled)
                .tint(Tokens.gray2)

            SecureField("Gemini API Key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .foregroundStyle(Tokens.gray1)
                .onChange(of: apiKey) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        KeychainStore.delete(forKey: Self.keychainKey)
                    } else {
                        KeychainStore.set(trimmed, forKey: Self.keychainKey)
                    }
                    if connectionTest != .testing {
                        connectionTest = .idle
                    }
                }

            HStack(spacing: 12) {
                Text("模型")
                TextField("gemini-2.5-flash", text: $directorModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .foregroundStyle(Tokens.gray1)
            }

            Button {
                runConnectionTest()
            } label: {
                HStack(spacing: 12) {
                    Text("測試連線")
                        .foregroundStyle(Tokens.fg)
                    Spacer(minLength: 8)
                    switch connectionTest {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .tint(Tokens.gray2)
                    case .success:
                        Text("✓ 連線成功")
                            .font(Tokens.label(13))
                            .foregroundStyle(Tokens.fg)
                    case .failure(let reason):
                        Text("✗ \(reason)")
                            .font(Tokens.label(13))
                            .foregroundStyle(Tokens.gray2)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .disabled(connectionTest == .testing)
        } header: {
            sectionHeader("AI 導演")
        } footer: {
            Text("拍照後由 Gemini 給一句下一步建議；API Key 只儲存在本機 Keychain。")
                .font(Tokens.label(12))
                .foregroundStyle(Tokens.gray2)
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    // MARK: - 拍攝

    private var captureSection: some View {
        Section {
            Toggle("網格線", isOn: $gridEnabled)
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
            HStack {
                Text("版本")
                Spacer()
                Text(appVersion)
                    .font(Tokens.mono(15))
                    .foregroundStyle(Tokens.gray2)
            }
        } header: {
            sectionHeader("關於")
        }
        .listRowBackground(Self.rowBackground)
        .listRowSeparatorTint(Tokens.hairlineColor)
    }

    // MARK: - 動作與輔助

    private func runConnectionTest() {
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Tokens.label(12, weight: .medium))
            .foregroundStyle(Tokens.gray2)
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
