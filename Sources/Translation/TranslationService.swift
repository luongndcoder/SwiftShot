import Foundation

/// Available translation backends.
enum TranslationProvider: String, CaseIterable, Identifiable, Codable {
    case google = "google"
    case openai = "openai"

    var displayName: String {
        switch self {
        case .google: return "Google Translate (Free)"
        case .openai: return "OpenAI API"
        }
    }

    var id: String { rawValue }
}

/// A target language option.
struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let defaultTarget = "vi"

    static let supported: [TranslationLanguage] = [
        TranslationLanguage(code: "vi", name: "Tiếng Việt"),
        TranslationLanguage(code: "en", name: "English"),
        TranslationLanguage(code: "zh-CN", name: "中文 (简体)"),
        TranslationLanguage(code: "zh-TW", name: "中文 (繁體)"),
        TranslationLanguage(code: "ja", name: "日本語"),
        TranslationLanguage(code: "ko", name: "한국어"),
        TranslationLanguage(code: "fr", name: "Français"),
        TranslationLanguage(code: "de", name: "Deutsch"),
        TranslationLanguage(code: "es", name: "Español"),
        TranslationLanguage(code: "ru", name: "Русский"),
        TranslationLanguage(code: "th", name: "ไทย")
    ]
}

/// A localized text block with spatial coordinates for in-place rendering.
struct TranslatedBlock: Identifiable, Sendable {
    let id: UUID
    let originalText: String
    let translatedText: String
    let normalizedRect: CGRect
    let pixelRect: CGRect
}

/// The complete translation response.
struct TranslationResult: Sendable {
    let originalFullText: String
    let translatedFullText: String
    let sourceLanguage: String
    let targetLanguage: String
    let provider: TranslationProvider
    let blocks: [TranslatedBlock]
}

/// Translation errors.
enum TranslationError: LocalizedError {
    case emptyText
    case missingAPIKey
    case networkError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text recognized in the selection."
        case .missingAPIKey:
            return "OpenAI API key is missing. Please configure it in Settings."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .invalidResponse:
            return "Could not parse translation response."
        }
    }
}

/// Orchestrates text translation via Google Translate (Free) or OpenAI API.
final class TranslationService: Sendable {
    static let shared = TranslationService()

    /// Translates an OCRResult into the requested target language.
    func translate(
        ocr: OCRResult,
        provider: TranslationProvider,
        targetLanguage: String,
        sourceLanguage: String = "auto",
        openaiApiKey: String = "",
        openaiBaseURL: String = "https://api.openai.com/v1",
        openaiModel: String = "gpt-4o-mini"
    ) async throws -> TranslationResult {
        guard !ocr.isEmpty else {
            throw TranslationError.emptyText
        }

        switch provider {
        case .google:
            return try await translateWithGoogle(
                ocr: ocr,
                sourceLang: sourceLanguage,
                targetLang: targetLanguage
            )
        case .openai:
            return try await translateWithOpenAI(
                ocr: ocr,
                apiKey: openaiApiKey,
                baseURL: openaiBaseURL,
                model: openaiModel,
                sourceLang: sourceLanguage,
                targetLang: targetLanguage
            )
        }
    }

    // MARK: - Google Translate (Free Public Endpoint)

    private func translateWithGoogle(
        ocr: OCRResult,
        sourceLang: String,
        targetLang: String
    ) async throws -> TranslationResult {
        let (fullTranslated, detectedLang) = try await callGoogleEndpoint(
            text: ocr.fullText,
            source: sourceLang,
            target: targetLang
        )

        // Translate blocks individually for exact in-place overlay positioning
        var translatedBlocks: [TranslatedBlock] = []
        for block in ocr.blocks {
            let blockText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !blockText.isEmpty else { continue }

            let blockTranslated: String
            if let (res, _) = try? await callGoogleEndpoint(text: blockText, source: sourceLang, target: targetLang) {
                blockTranslated = res
            } else {
                blockTranslated = blockText
            }

            translatedBlocks.append(TranslatedBlock(
                id: block.id,
                originalText: blockText,
                translatedText: blockTranslated,
                normalizedRect: block.normalizedRect,
                pixelRect: block.pixelRect
            ))
        }

        return TranslationResult(
            originalFullText: ocr.fullText,
            translatedFullText: fullTranslated,
            sourceLanguage: detectedLang ?? sourceLang,
            targetLanguage: targetLang,
            provider: .google,
            blocks: translatedBlocks
        )
    }

    private func callGoogleEndpoint(
        text: String,
        source: String,
        target: String
    ) async throws -> (translated: String, detectedLang: String?) {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]

        guard let url = components?.url else {
            throw TranslationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TranslationError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw TranslationError.invalidResponse
        }

        var translatedChunks: [String] = []
        if let sentences = json.first as? [[Any]] {
            for sentence in sentences {
                if let part = sentence.first as? String {
                    translatedChunks.append(part)
                }
            }
        }

        let detected = (json.count > 2 ? json[2] as? String : nil)
        let translatedString = translatedChunks.joined()
        return (translatedString, detected)
    }

    // MARK: - OpenAI API

    private func translateWithOpenAI(
        ocr: OCRResult,
        apiKey: String,
        baseURL: String,
        model: String,
        sourceLang: String,
        targetLang: String
    ) async throws -> TranslationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw TranslationError.missingAPIKey
        }

        var cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanBaseURL.hasSuffix("/") {
            cleanBaseURL.removeLast()
        }
        let endpointString = cleanBaseURL.hasSuffix("/chat/completions") ? cleanBaseURL : "\(cleanBaseURL)/chat/completions"
        guard let url = URL(string: endpointString) else {
            throw TranslationError.networkError("Invalid OpenAI Base URL: \(baseURL)")
        }

        let targetName = TranslationLanguage.supported.first(where: { $0.code == targetLang })?.name ?? targetLang
        let systemPrompt = """
        You are an expert translator. Translate the given text accurately and naturally into \(targetName).
        Maintain the original paragraph structure and line breaks.
        Return ONLY the raw translated text, without commentary, markdown backticks, or conversational filler.
        """

        let payload: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4o-mini" : model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": ocr.fullText]
            ],
            "temperature": 0.3
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranslationError.networkError("OpenAI API returned status \(httpResponse.statusCode): \(errorText)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.invalidResponse
        }

        let fullTranslated = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split by lines to map to blocks
        let translatedLines = fullTranslated.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var translatedBlocks: [TranslatedBlock] = []

        for (index, block) in ocr.blocks.enumerated() {
            let blockTrans = (index < translatedLines.count) ? translatedLines[index] : block.text
            translatedBlocks.append(TranslatedBlock(
                id: block.id,
                originalText: block.text,
                translatedText: blockTrans,
                normalizedRect: block.normalizedRect,
                pixelRect: block.pixelRect
            ))
        }

        return TranslationResult(
            originalFullText: ocr.fullText,
            translatedFullText: fullTranslated,
            sourceLanguage: sourceLang,
            targetLanguage: targetLang,
            provider: .openai,
            blocks: translatedBlocks
        )
    }
}
