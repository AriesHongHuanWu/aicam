//  GeminiDirectorService.swift
//  AICam — L3 導演層雲端先行版（MASTER-PLAN §4.4）。
//
//  現階段直連使用者自備的 Gemini API key（存 Keychain，設定頁貼入）；
//  上架前才換 Cloudflare Worker proxy。純 URLSession，不引入 SDK（D9）。
//
//  模型選擇（2026-07 起雙模型，resolvedModel(for:)）：
//  - auto（預設，director.modelMode）：live 用 gemini-flash-lite-latest（低延遲）、
//    拍後用 gemini-flash-latest（品質）— 官方 *-latest 別名永遠指向最新版 flash 系列。
//  - custom：讀 director.model.live / director.model.post；空值 fallback 回 auto 值。
//  舊單一 "director.model" key 已不再讀取（直接切換，不做 migration）。
//
//  Gemini REST 慣例注意：請求 body 的 inline_data / mime_type 用 snake_case，
//  但 generationConfig 內欄位（responseMimeType / maxOutputTokens）用 camelCase —
//  這是 Google API 的實際混用格式，不要「統一」它。

import Foundation
import os

/// 導演服務錯誤（healthCheck 對用戶顯示用，訊息繁中）。
enum DirectorServiceError: LocalizedError {
    case missingKey
    case invalidURL
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "尚未設定 API Key"
        case .invalidURL:
            return "無法組成請求網址"
        case .badStatus(let code):
            switch code {
            case 400, 401, 403:
                return "API Key 無效（HTTP \(code)）"
            case 404:
                return "找不到模型（HTTP 404）"
            case 429:
                return "請求太頻繁（HTTP 429）"
            case 503:
                return "服務暫時過載（HTTP 503）"
            default:
                return "伺服器回應 HTTP \(code)"
            }
        }
    }
}

/// Gemini 導演服務：送一張 JPEG（取景器即時畫面或剛拍好的成品），換一句下一步建議。
/// 無狀態、執行緒安全（只持有不可變的 URLSession 與 Logger）。
final class GeminiDirectorService: @unchecked Sendable {

    static let shared = GeminiDirectorService()

    private static let apiBase = "https://generativelanguage.googleapis.com/v1beta"

    /// auto 模式模型（2026-07 現況：官方別名永遠指向最新版）。
    /// live = 取景中即時建議，選 lite 求低延遲；post = 拍後建議，選完整版求品質。
    static let autoLiveModel = "gemini-flash-lite-latest"
    static let autoPostModel = "gemini-flash-latest"

    private static let keychainKey = "gemini-api-key"
    private static let modelModeKey = "director.modelMode"
    private static let liveModelKey = "director.model.live"
    private static let postModelKey = "director.model.post"
    private static let minConfidence = 0.4

    /// 共通導演指令（live / 拍後皆用）。
    private static let systemPrompt = """
    你是世界頂尖的人像攝影導演與構圖教練。規則：
    1. 只回一個 JSON 物件 {"tip": string, "confidence": number}，不要任何其他文字。
    2. tip 用繁體中文、最多 14 字、動作立即可執行，具體到方位或身體指令，例如「往左兩步拍側光」「請她下巴微收」「蹲低從腰部高度拍」。
    3. 若「現場資訊」裡已有「目前建議」，不要重複同一件事，改給下一個最有價值的改進。
    4. 構圖已經很好時，先稱讚，再給一個進階變化（換角度、換焦段或換姿勢）。
    5. confidence 為 0 到 1；畫面裡有人就以拍好人為最優先。
    """

    /// live 模式補充句：一句、立即可做、指向下一步最有價值的改變。
    private static let livePromptLine =
        "這是目前取景器的即時畫面。只給一句話，必須是攝影者現在立刻做得到的動作，並且指向當下最有價值的下一步改變。"

    /// 拍後補充句：先肯定再給下一張的改進。
    private static let postCapturePromptLine =
        "這是剛拍下的成品，先一句肯定再給下一張的改進。"

    /// URL 中 key / model 的保守允許字元（RFC 3986 unreserved）。
    private static let unreservedCharacters =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.arieswu.aicam", category: "GeminiDirector")

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        urlSession = URLSession(configuration: config)
    }

    // MARK: - Public

    /// 依用途解析實際要用的模型名。
    /// auto（預設）→ live 用 autoLiveModel、post 用 autoPostModel；
    /// custom → 讀對應 defaults key，空字串 fallback 回 auto 值。
    func resolvedModel(for source: DirectorTip.Source) -> String {
        let autoModel: String
        let customKey: String
        switch source {
        case .live:
            autoModel = Self.autoLiveModel
            customKey = Self.liveModelKey
        case .postCapture:
            autoModel = Self.autoPostModel
            customKey = Self.postModelKey
        }

        let mode = UserDefaults.standard.string(forKey: Self.modelModeKey) ?? "auto"
        guard mode == "custom" else { return autoModel }

        let custom = UserDefaults.standard.string(forKey: customKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? autoModel : custom
    }

    /// 對一張 JPEG 要一句導演建議（live = 取景器即時畫面；postCapture = 剛拍下的成品）。
    /// model = 呼叫端用 resolvedModel(for:) 解析後傳入的模型名。
    /// context = 現場結構化資訊（主體位置/構圖分數/光位/目前規則建議），組進「現場資訊：」段。
    /// 任何錯誤（無 key、網路、解析、低置信度）一律回 nil，只記 debug log — 不打擾拍攝。
    func tip(
        jpeg: Data,
        context: String?,
        source: DirectorTip.Source,
        model: String
    ) async -> DirectorTip? {
        guard !jpeg.isEmpty else { return nil }
        guard let key = storedAPIKey() else {
            logger.debug("tip skipped: missing API key")
            return nil
        }
        guard let url = endpointURL(path: "models/\(percentEncoded(model)):generateContent", key: key) else {
            logger.debug("tip failed: cannot build URL")
            return nil
        }

        var prompt = Self.systemPrompt
        switch source {
        case .live:
            prompt += "\n\(Self.livePromptLine)"
        case .postCapture:
            prompt += "\n\(Self.postCapturePromptLine)"
        }
        if let context, !context.isEmpty {
            prompt += "\n現場資訊：\(context)"
        }

        do {
            // flash 系列預設附 thinkingConfig（見 postGenerateContent 內註解）。
            let attachThinking = model.contains("flash")
            var (data, status) = try await postGenerateContent(
                url: url, prompt: prompt, jpeg: jpeg, disableThinking: attachThinking
            )

            // 韌性：有些模型不接受 thinkingConfig — HTTP 400 且錯誤內文提到
            // thinking 時，去掉 thinkingConfig 重試一次。
            // 429/503（節流/過載）不重試、靜默回 nil：節流下一輪自然再試。
            if status == 400, attachThinking,
               let bodyText = String(data: data, encoding: .utf8),
               bodyText.lowercased().contains("thinking") {
                logger.debug("tip: \(model, privacy: .public) rejected thinkingConfig, retrying without it")
                (data, status) = try await postGenerateContent(
                    url: url, prompt: prompt, jpeg: jpeg, disableThinking: false
                )
            }

            guard status == 200 else {
                logger.debug("tip failed: HTTP \(status, privacy: .public) model \(model, privacy: .public)")
                return nil
            }

            let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
            guard let rawText = decoded.candidates?.first?.content?.parts?
                .compactMap({ $0.text })
                .first else {
                logger.debug("tip failed: no text in candidates")
                return nil
            }
            guard let payloadData = stripCodeFence(rawText).data(using: .utf8) else {
                logger.debug("tip failed: text not utf8")
                return nil
            }
            let payload = try JSONDecoder().decode(TipPayload.self, from: payloadData)

            let text = payload.tip.trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = min(max(payload.confidence, 0), 1)
            guard !text.isEmpty, confidence >= Self.minConfidence else {
                logger.debug("tip dropped: confidence \(confidence, privacy: .public)")
                return nil
            }
            return DirectorTip(text: text, confidence: confidence, date: Date(), source: source)
        } catch {
            logger.debug("tip failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 設定頁「測試連線」：對 auto 拍後模型（gemini-flash-latest）送一個最小
    /// generateContent 請求 — 直接驗證「這把 key 能用最新 flash 生成」，
    /// 比 GET /models 更貼近實際使用路徑。不帶 thinkingConfig（避免相容性干擾）；
    /// 就算回應被 thinking 預算吃光也是 HTTP 200，只看狀態碼即可。
    func healthCheck() async -> Result<Void, Error> {
        guard let key = storedAPIKey() else {
            return .failure(DirectorServiceError.missingKey)
        }
        let model = Self.autoPostModel
        guard let url = endpointURL(path: "models/\(percentEncoded(model)):generateContent", key: key) else {
            return .failure(DirectorServiceError.invalidURL)
        }
        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": "回覆 OK"]]]
            ],
            "generationConfig": ["maxOutputTokens": 16]
        ]
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(DirectorServiceError.badStatus(-1))
            }
            guard http.statusCode == 200 else {
                return .failure(DirectorServiceError.badStatus(http.statusCode))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Private

    /// 組 body 並送出 generateContent；回（回應資料, HTTP 狀態碼）。
    /// 只丟傳輸層錯誤（網路/編碼），HTTP 錯誤交由呼叫端看狀態碼決定。
    private func postGenerateContent(
        url: URL,
        prompt: String,
        jpeg: Data,
        disableThinking: Bool
    ) async throws -> (Data, Int) {
        // gemini flash 系列預設會先產生 thinking tokens，且 maxOutputTokens
        // 是「thinking + 最終答案」的總預算 — 預算太小會被想法吃光，回應
        // finishReason=MAX_TOKENS 且沒有任何 text part。因此：
        // 1) 對 flash 系列用 thinkingConfig.thinkingBudget=0 關掉 thinking
        //    （pro 系列不接受 0，故只在模型名含 "flash" 時附加）；
        // 2) maxOutputTokens 拉到 512 給小 JSON 足夠餘裕。
        var generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "maxOutputTokens": 512
        ]
        if disableThinking {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": jpeg.base64EncodedString()
                            ]
                        ],
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": generationConfig
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }

    private func storedAPIKey() -> String? {
        guard let key = KeychainStore.get(forKey: Self.keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty else { return nil }
        return key
    }

    private func endpointURL(path: String, key: String) -> URL? {
        URL(string: "\(Self.apiBase)/\(path)?key=\(percentEncoded(key))")
    }

    private func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters) ?? value
    }

    /// 保險：模型偶爾仍會包 ```json 圍欄，剝掉再解析。
    private func stripCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Response 解析用私有型別

private struct GenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

private struct TipPayload: Decodable {
    let tip: String
    let confidence: Double
}
