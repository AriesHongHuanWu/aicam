//  DirectorCenter.swift
//  AICam — 導演層狀態中樞（跨模組契約，A4 擁有）。
//
//  兩條路徑共用同一個 ≥8 秒節流（lastRequestAt）：
//  1. 拍後：CameraController.onPhotoCaptured 拍照成功後把 JPEG 餵進 photoCaptured(jpeg:)。
//  2. 現場（live）：startLive(snapshot:context:) 啟動 Task loop —
//     進入 2 秒先打第一發（讓用戶立刻有感），之後每 10 秒一發；stopLive() 取消。
//  DirectorTipBanner 讀 latestTip 顯示；tip 顯示 8 秒自動清空。

import Foundation
import Observation

/// 導演給的一句建議（跨模組契約型別）。
struct DirectorTip: Equatable {

    /// 建議來源：live = 取景中即時建議；postCapture = 拍後建議。
    enum Source {
        case live
        case postCapture
    }

    let text: String
    let confidence: Double
    let date: Date
    let source: Source

    init(text: String, confidence: Double, date: Date, source: Source = .postCapture) {
        self.text = text
        self.confidence = confidence
        self.date = date
        self.source = source
    }
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

    /// 設定頁「現場導演」開關（@AppStorage "director.live"，預設 false）。
    var isLiveEnabled: Bool {
        UserDefaults.standard.bool(forKey: "director.live")
    }

    /// 拍後與 live 兩條路徑共用的節流時間戳（≥8 秒一次）。
    @ObservationIgnored private var lastRequestAt: Date = .distantPast
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    private init() {}

    /// 拍照成功後呼叫（~1280px JPEG）。
    /// 條件：功能開啟、Keychain 有 API key、距上次呼叫 ≥8 秒；不符合就靜默略過。
    func photoCaptured(jpeg: Data) {
        guard isEnabled, hasAPIKey else { return }

        let now = Date()
        guard now.timeIntervalSince(lastRequestAt) >= 8 else { return }
        lastRequestAt = now

        Task { [weak self] in
            guard let tip = await GeminiDirectorService.shared.tip(
                jpeg: jpeg, context: nil, source: .postCapture
            ) else { return }
            self?.show(tip)
        }
    }

    /// 啟動現場導演 loop（進入教練/拍照畫面時呼叫；重複呼叫會先取消舊 loop 重新起算）。
    /// - Parameters:
    ///   - snapshot: 回傳目前取景器縮圖 JPEG；回 nil = 該輪略過（不消耗節流）。
    ///     async：JPEG 縮放/編碼在背景執行，避免每 10 秒卡主執行緒一次（取景微卡帧）。
    ///   - context: 回傳現場結構化資訊（主體位置/構圖分數/光位/目前規則建議），組進 prompt。
    func startLive(
        snapshot: @escaping @MainActor () async -> Data?,
        context: @escaping @MainActor () -> String?
    ) {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            // 第一發提早到進入後 2 秒，之後固定 10 秒一輪。
            // Task.sleep 被取消時直接丟出 → try? 吞掉 → while 條件看到 isCancelled 收工。
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self else { return }
                await self.requestLiveTip(snapshot: snapshot, context: context)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// 停止現場導演 loop（離開畫面或關閉開關時呼叫）。
    /// 在途的 URLSession 請求會隨結構化取消一併中止（service 回 nil）。
    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
    }

    // MARK: - Private

    private var hasAPIKey: Bool {
        guard let key = KeychainStore.get(forKey: "gemini-api-key") else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// live loop 的單輪：閘門（開關/key/節流）→ 取快照 → 要建議 → 顯示。
    private func requestLiveTip(
        snapshot: @MainActor () async -> Data?,
        context: @MainActor () -> String?
    ) async {
        guard isEnabled, isLiveEnabled, hasAPIKey else { return }

        let now = Date()
        guard now.timeIntervalSince(lastRequestAt) >= 8 else { return }
        // 先拿快照（編碼在背景），拿不到（相機未就緒等）不消耗節流。
        guard let jpeg = await snapshot() else { return }
        lastRequestAt = now

        guard let tip = await GeminiDirectorService.shared.tip(
            jpeg: jpeg, context: context(), source: .live
        ) else { return }
        // stopLive 後回來的結果不再顯示。
        guard !Task.isCancelled else { return }
        show(tip)
    }

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
