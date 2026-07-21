//  DirectorCenter.swift
//  AICam — 導演層狀態中樞（跨模組契約，A4 擁有）。
//
//  CameraController.onPhotoCaptured 拍照成功後把 JPEG 餵進 photoCaptured(jpeg:)；
//  DirectorTipBanner 讀 latestTip 顯示。節流 ≥8 秒一次，tip 顯示 8 秒自動清空。

import Foundation
import Observation

/// 導演給的一句建議（跨模組契約型別）。
struct DirectorTip: Equatable {
    let text: String
    let confidence: Double
    let date: Date
}

@MainActor
@Observable
final class DirectorCenter {

    static let shared = DirectorCenter()

    /// 最新一條導演建議；nil = 不顯示。
    var latestTip: DirectorTip?

    /// 設定頁「導演建議」開關（@AppStorage "director.enabled"）。
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "director.enabled")
    }

    @ObservationIgnored private var lastRequestAt: Date = .distantPast
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    private init() {}

    /// 拍照成功後呼叫（~1280px JPEG）。
    /// 條件：功能開啟、Keychain 有 API key、距上次呼叫 ≥8 秒；不符合就靜默略過。
    func photoCaptured(jpeg: Data) {
        guard isEnabled else { return }
        guard let key = KeychainStore.get(forKey: "gemini-api-key"),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let now = Date()
        guard now.timeIntervalSince(lastRequestAt) >= 8 else { return }
        lastRequestAt = now

        Task { [weak self] in
            guard let tip = await GeminiDirectorService.shared.tip(jpeg: jpeg, hint: nil) else { return }
            self?.show(tip)
        }
    }

    // MARK: - Private

    private func show(_ tip: DirectorTip) {
        latestTip = tip
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.latestTip = nil
        }
    }
}
