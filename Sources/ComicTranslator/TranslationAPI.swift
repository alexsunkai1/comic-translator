import Foundation

// MARK: - 翻译协议

protocol TranslationAPI: Sendable {
    func translate(text: String, from source: String, to target: String) async throws -> String
    func testConnection() async -> Bool
    func listModels() async -> [String]
}

// MARK: - 翻译配置

struct TranslationConfig: Sendable {
    let endpoint: String
    let apiKey: String
    let modelID: String
    let temperature: Double
    let customPromptTemplate: String
    let domainInstruction: String  // 领域指令（来自 TranslationDomain.systemInstruction）
}

enum TranslationAPIError: Error, LocalizedError {
    case invalidEndpoint
    case httpError(Int, String)
    case parseError(String)
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "无效的 API endpoint"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .parseError(let msg): return "响应解析失败: \(msg)"
        case .connectionFailed: return "连接失败"
        }
    }
}

// MARK: - 工厂方法

func makeTranslationAPI(format: APIFormat, config: TranslationConfig) -> TranslationAPI {
    switch format {
    case .ollama:
        return OllamaAPI(config: config)
    case .hyMT:
        return HYMTAPI(config: config)
    case .openaiCompatible:
        return OpenAICompatibleAPI(config: config)
    }
}

// MARK: - Ollama（通用本地模型）

struct OllamaAPI: TranslationAPI {
    let config: TranslationConfig

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let prompt = buildPrompt(text: text, source: source, target: target)

        let body: [String: Any] = [
            "model": config.modelID,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "options": [
                "temperature": config.temperature,
                "top_p": 0.6,
                "top_k": 20,
                "repeat_penalty": 1.05
            ]
        ]

        let data = try await postJSON(to: "\(config.endpoint)/api/chat", body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationAPIError.parseError("Ollama 响应格式错误")
        }

        return cleanResponse(content)
    }

    func testConnection() async -> Bool {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func listModels() async -> [String] {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        } catch {
            return []
        }
    }

    private func buildPrompt(text: String, source: String, target: String) -> String {
        if !config.customPromptTemplate.isEmpty {
            return applyTemplate(config.customPromptTemplate, text: text, source: source, target: target, domain: config.domainInstruction)
        }
        let targetName = LanguageOption.named(target)?.name ?? target
        var parts: [String] = []
        if !config.domainInstruction.isEmpty {
            parts.append(config.domainInstruction)
        }
        parts.append("将以下文本翻译为\(targetName)，不要添加任何解释，只输出译文：")
        parts.append(text)
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - HY-MT（腾讯混元翻译，使用 Ollama 后端）

struct HYMTAPI: TranslationAPI {
    let config: TranslationConfig

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let prompt = buildPrompt(text: text, source: source, target: target)

        let body: [String: Any] = [
            "model": config.modelID,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "options": [
                "temperature": config.temperature,
                "top_p": 0.6,
                "top_k": 20,
                "repeat_penalty": 1.05
            ]
        ]

        let data = try await postJSON(to: "\(config.endpoint)/api/chat", body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationAPIError.parseError("HY-MT 响应格式错误")
        }

        return cleanResponse(content)
    }

    func testConnection() async -> Bool {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func listModels() async -> [String] {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        } catch {
            return []
        }
    }

    private func buildPrompt(text: String, source: String, target: String) -> String {
        if !config.customPromptTemplate.isEmpty {
            return applyTemplate(config.customPromptTemplate, text: text, source: source, target: target, domain: config.domainInstruction)
        }
        // HY-MT 官方 prompt 模板 + 领域指令
        let isZhInvolved = source.hasPrefix("zh") || target.hasPrefix("zh")
        var parts: [String] = []
        if !config.domainInstruction.isEmpty {
            parts.append(config.domainInstruction)
        }
        if isZhInvolved {
            let targetName = LanguageOption.named(target)?.chineseName ?? target
            parts.append("将以下文本翻译为\(targetName)，注意只需要输出翻译后的结果，不要额外解释：")
        } else {
            let englishName = englishLanguageName(for: target)
            parts.append("Translate the following segment into \(englishName), without additional explanation.")
        }
        parts.append(text)
        return parts.joined(separator: "\n\n")
    }

    private func englishLanguageName(for code: String) -> String {
        let map: [String: String] = [
            "zh-Hans": "Chinese", "zh-Hant": "Traditional Chinese", "zh": "Chinese",
            "en": "English", "ja": "Japanese", "ko": "Korean",
            "it": "Italian", "fr": "French", "de": "German", "es": "Spanish",
            "pt": "Portuguese", "ru": "Russian", "ar": "Arabic"
        ]
        return map[code] ?? code
    }
}

// MARK: - OpenAI 兼容

struct OpenAICompatibleAPI: TranslationAPI {
    let config: TranslationConfig

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let prompt = buildPrompt(text: text, source: source, target: target)

        var systemContent = "You are a professional translator. Translate accurately without adding explanations."
        if !config.domainInstruction.isEmpty {
            systemContent += "\n\n" + config.domainInstruction
        }

        let body: [String: Any] = [
            "model": config.modelID,
            "messages": [
                ["role": "system", "content": systemContent],
                ["role": "user", "content": prompt]
            ],
            "temperature": config.temperature,
            "max_tokens": 2048
        ]

        let url = chatCompletionsURL()
        let data = try await postJSON(to: url, body: body, apiKey: config.apiKey)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationAPIError.parseError("OpenAI 响应格式错误")
        }

        return cleanResponse(content)
    }

    func testConnection() async -> Bool {
        do {
            _ = try await translate(text: "hello", from: "en", to: "zh-Hans")
            return true
        } catch {
            return false
        }
    }

    func listModels() async -> [String] {
        guard let url = URL(string: "\(config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models") else { return [] }
        var request = URLRequest(url: url)
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["id"] as? String }
        } catch {
            return []
        }
    }

    private func chatCompletionsURL() -> String {
        let trimmed = config.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/chat/completions") {
            return trimmed
        }
        return "\(trimmed)/chat/completions"
    }

    private func buildPrompt(text: String, source: String, target: String) -> String {
        if !config.customPromptTemplate.isEmpty {
            return applyTemplate(config.customPromptTemplate, text: text, source: source, target: target, domain: config.domainInstruction)
        }
        let targetName = LanguageOption.named(target)?.name ?? target
        let sourceName = LanguageOption.named(source)?.name ?? source
        return "请将以下\(sourceName)文本翻译为\(targetName)，直接输出译文，不要添加任何说明：\n\n\(text)"
    }
}

// MARK: - 公共工具

private func postJSON(to urlString: String, body: [String: Any], apiKey: String = "") async throws -> Data {
    guard let url = URL(string: urlString) else {
        throw TranslationAPIError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 120

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw TranslationAPIError.connectionFailed
    }
    guard http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw TranslationAPIError.httpError(http.statusCode, body)
    }
    return data
}

private func cleanResponse(_ content: String) -> String {
    var result = content.trimmingCharacters(in: .whitespacesAndNewlines)
    // 移除可能的 <target></target> 标签
    if result.hasPrefix("<target>") && result.hasSuffix("</target>") {
        result = String(result.dropFirst(8).dropLast(9))
    }
    // 移除可能的引号
    if (result.hasPrefix("\"") && result.hasSuffix("\"")) ||
       (result.hasPrefix("「") && result.hasSuffix("」")) {
        result = String(result.dropFirst().dropLast())
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func applyTemplate(_ template: String, text: String, source: String, target: String, domain: String = "") -> String {
    let targetName = LanguageOption.named(target)?.name ?? target
    let sourceName = LanguageOption.named(source)?.name ?? source
    return template
        .replacingOccurrences(of: "{text}", with: text)
        .replacingOccurrences(of: "{source}", with: sourceName)
        .replacingOccurrences(of: "{target}", with: targetName)
        .replacingOccurrences(of: "{source_code}", with: source)
        .replacingOccurrences(of: "{target_code}", with: target)
        .replacingOccurrences(of: "{domain}", with: domain)
}

// MARK: - 翻译缓存 + 并发

actor TranslationCache {
    private var cache: [String: String] = [:]

    func get(_ text: String, _ src: String, _ tgt: String, _ domain: String = "") -> String? {
        cache["\(src)|\(tgt)|\(domain.hashValue)|\(text)"]
    }

    func set(_ text: String, _ src: String, _ tgt: String, _ result: String, _ domain: String = "") {
        cache["\(src)|\(tgt)|\(domain.hashValue)|\(text)"] = result
    }
}

actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.available = value }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            available += 1
        }
    }
}

/// 带缓存和并发控制的批量翻译
func translateTextsBatch(
    texts: [String],
    from source: String,
    to target: String,
    api: TranslationAPI,
    cache: TranslationCache,
    concurrency: Int,
    domainKey: String = ""
) async -> [String] {
    guard !texts.isEmpty else { return [] }

    var results = [String](repeating: "", count: texts.count)
    var uncachedIndices: [Int] = []
    var uncachedTexts: [String] = []

    for (i, text) in texts.enumerated() {
        if let cached = await cache.get(text, source, target, domainKey) {
            results[i] = cached
        } else {
            uncachedIndices.append(i)
            uncachedTexts.append(text)
        }
    }

    guard !uncachedTexts.isEmpty else { return results }

    let semaphore = AsyncSemaphore(value: max(1, concurrency))

    let translated: [(Int, String)] = await withTaskGroup(of: (Int, String).self) { group in
        for (idx, text) in uncachedTexts.enumerated() {
            group.addTask {
                await semaphore.wait()
                defer { Task { await semaphore.signal() } }
                do {
                    let t = try await api.translate(text: text, from: source, to: target)
                    return (idx, t)
                } catch {
                    return (idx, "")
                }
            }
        }
        var arr: [(Int, String)] = []
        for await item in group { arr.append(item) }
        return arr
    }

    for (idx, t) in translated {
        let originalIdx = uncachedIndices[idx]
        results[originalIdx] = t
        await cache.set(uncachedTexts[idx], source, target, t, domainKey)
    }

    return results
}
