//  GeminiDirectorService.swift
//  AICam — L3 導演層雲端先行版（MASTER-PLAN §4.4）。
//
//  現階段直連使用者自備的 Gemini API key（存 Keychain，設定頁貼入）；
//  上架前才換 Cloudflare Worker proxy。純 URLSession，不引入 SDK（D9）。
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
            case 429:
                return "請求太頻繁（HTTP 429）"
            default:
                return "伺服器回應 HTTP \(code)"
            }
        }
    }
}

/// Gemini 導演服務：送一張剛拍好的 JPEG，換一句下一步建議。
/// 無狀態、執行緒安全（只持有不可變的 URLSession 與 Logger）。
final class GeminiDirectorService: @unchecked Sendable {

    static let shared = GeminiDirectorService()

    private static let apiBase = "https://generativelanguage.googleapis.com/v1beta"
    private static let defaultModel = "gemini-2.5-flash"
    private static let keychainKey = "gemini-api-key"
    private static let modelDefaultsKey = "director.model"
    private static let minConfidence = 0.4

    private static let promptText =
        "你是頂尖人像攝影導演。看這張剛拍的照片，回一個 JSON 物件 {\"tip\": string, \"confidence\": number}：tip 是給攝影者的下一步具體建議，繁體中文、最多 14 字、立即可執行（走位/角度/光線/姿勢）；confidence 0到1。畫面裡有人就以拍好人為最優先。"

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

    /// 對一張剛拍的 JPEG 要一句導演建議。
    /// 任何錯誤（無 key、網路、解析、低置信度）一律回 nil，只記 debug log — 不打擾拍攝。
    func tip(jpeg: Data, hint: String?) async -> DirectorTip? {
        guard !jpeg.isEmpty else { return nil }
        guard let key = storedAPIKey() else {
            logger.debug("tip skipped: missing API key")
            return nil
        }
        let model = configuredModel()
        guard let url = endpointURL(path: "models/\(percentEncoded(model)):generateContent", key: key) else {
            logger.debug("tip failed: cannot build URL")
            return nil
        }

        var prompt = Self.promptText
        if let hint, !hint.isEmpty {
            prompt += "\n補充情境：\(hint)"
        }

        // gemini-2.5 flash 系列預設會先產生 thinking tokens，且 maxOutputTokens
        // 是「thinking + 最終答案」的總預算 — 預算太小會被想法吃光，回應
        // finishReason=MAX_TOKENS 且沒有任何 text part。因此：
        // 1) 對 flash 系列用 thinkingConfig.thinkingBudget=0 關掉 thinking
        //    （pro 系列不接受 0，故只在模型名含 "flash" 時附加）；
        // 2) maxOutputTokens 拉到 512 給小 JSON 足夠餘裕。
        var generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "maxOutputTokens": 512
        ]
        if model.contains("flash") {
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

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.debug("tip failed: HTTP \(code, privacy: .public)")
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
            return DirectorTip(text: text, confidence: confidence, date: Date())
        } catch {
            logger.debug("tip failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 設定頁「測試連線」：GET /v1beta/models 判 200。
    func healthCheck() async -> Result<Void, Error> {
        guard let key = storedAPIKey() else {
            return .failure(DirectorServiceError.missingKey)
        }
        guard let url = endpointURL(path: "models", key: key) else {
            return .failure(DirectorServiceError.invalidURL)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
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

    private func storedAPIKey() -> String? {
        guard let key = KeychainStore.get(forKey: Self.keychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty else { return nil }
        return key
    }

    private func configuredModel() -> String {
        let stored = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultModel
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
