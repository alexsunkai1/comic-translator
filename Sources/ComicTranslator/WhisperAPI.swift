import Foundation
import AVFoundation

// MARK: - Whisper API 客户端（兼容 OpenAI / Groq / faster-whisper-server）

struct WhisperAPIConfig: Sendable {
    let endpoint: String      // e.g. "https://api.openai.com/v1" or "http://localhost:8000/v1"
    let apiKey: String
    let model: String         // e.g. "whisper-1", "whisper-large-v3", "large-v3-turbo"
    let language: String?     // BCP-47 简码，nil = 自动检测
}

struct WhisperAPI: Sendable {
    let config: WhisperAPIConfig

    /// 调用 /audio/transcriptions 端点，返回带时间戳的片段
    func transcribe(
        fileURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        // 1. 准备音频文件（如果是视频先提取音频）
        let audioURL: URL
        let tempFile: URL?
        let ext = fileURL.pathExtension.lowercased()

        if SpeechTranscriber.videoExtensions.contains(ext) {
            let extracted = try await SpeechTranscriber.extractAudio(from: fileURL)
            audioURL = extracted
            tempFile = extracted
        } else {
            audioURL = fileURL
            tempFile = nil
        }
        defer { if let t = tempFile { try? FileManager.default.removeItem(at: t) } }

        progress?(0.1)

        // 2. 读取音频数据
        let audioData = try Data(contentsOf: audioURL)

        // 文件大小限制检查（OpenAI 限制 25MB）
        let maxSize = 25 * 1024 * 1024
        guard audioData.count <= maxSize else {
            // 大文件分段处理
            return try await transcribeLargeFile(audioURL: audioURL, progress: progress)
        }

        progress?(0.2)

        // 3. 调用 API
        let segments = try await callWhisperAPI(audioData: audioData, fileName: audioURL.lastPathComponent)

        progress?(1.0)
        return segments
    }

    // MARK: - API 调用

    private func callWhisperAPI(audioData: Data, fileName: String) async throws -> [TranscriptSegment] {
        let url = buildURL()
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 600  // 语音识别可能很慢

        // 构建 multipart body
        var body = Data()
        let mimeType = guessMIMEType(fileName: fileName)

        // file 字段
        body.appendMultipart(boundary: boundary, name: "file", fileName: fileName, mimeType: mimeType, data: audioData)
        // model 字段
        body.appendMultipart(boundary: boundary, name: "model", value: config.model)
        // response_format = verbose_json（获取时间戳）
        body.appendMultipart(boundary: boundary, name: "response_format", value: "verbose_json")
        // timestamp_granularities = segment
        body.appendMultipart(boundary: boundary, name: "timestamp_granularities[]", value: "segment")
        // language（可选）
        if let lang = config.language, !lang.isEmpty, lang != "auto" {
            let whisperLang = mapToWhisperLanguage(lang)
            body.appendMultipart(boundary: boundary, name: "language", value: whisperLang)
        }
        // 结束
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WhisperAPIError.connectionFailed
        }
        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw WhisperAPIError.httpError(http.statusCode, errorBody)
        }

        return try parseVerboseJSON(data)
    }

    // MARK: - 大文件分段（>25MB 时切分为多段）

    private func transcribeLargeFile(audioURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [TranscriptSegment] {
        // 用 AVAsset 获取时长，按 10 分钟一段切分
        let asset = AVURLAsset(url: audioURL)
        let duration: Double
        if #available(macOS 13.0, *) {
            duration = (try? await asset.load(.duration).seconds) ?? 0
        } else {
            duration = asset.duration.seconds
        }

        guard duration > 0 else {
            throw WhisperAPIError.invalidAudio
        }

        let chunkDuration: Double = 600  // 10 分钟
        let chunkCount = Int(ceil(duration / chunkDuration))
        var allSegments: [TranscriptSegment] = []

        for i in 0..<chunkCount {
            let startTime = Double(i) * chunkDuration
            let endTime = min(startTime + chunkDuration, duration)

            // 导出片段
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper_chunk_\(i)_\(UUID().uuidString).m4a")

            try await exportChunk(from: asset, start: startTime, end: endTime, to: chunkURL)
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            let chunkData = try Data(contentsOf: chunkURL)
            let segments = try await callWhisperAPI(audioData: chunkData, fileName: chunkURL.lastPathComponent)

            // 偏移时间戳
            let offsetSegments = segments.map { seg in
                TranscriptSegment(text: seg.text, start: seg.start + startTime, end: seg.end + startTime)
            }
            allSegments.append(contentsOf: offsetSegments)

            progress?(Double(i + 1) / Double(chunkCount))
        }

        return allSegments
    }

    private func exportChunk(from asset: AVAsset, start: Double, end: Double, to outputURL: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperAPIError.invalidAudio
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 44100),
            end: CMTime(seconds: end, preferredTimescale: 44100)
        )

        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .m4a)
        } else {
            await exporter.export()
            if exporter.status != .completed {
                throw WhisperAPIError.invalidAudio
            }
        }
    }

    // MARK: - 解析响应

    private func parseVerboseJSON(_ data: Data) throws -> [TranscriptSegment] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperAPIError.parseError("无法解析 JSON 响应")
        }

        // verbose_json 格式包含 segments 数组
        guard let segments = json["segments"] as? [[String: Any]] else {
            // 降级：只有 text 没有 segments
            if let text = json["text"] as? String, !text.isEmpty {
                return [TranscriptSegment(text: text.trimmingCharacters(in: .whitespacesAndNewlines), start: 0, end: 0)]
            }
            throw WhisperAPIError.parseError("响应中无 segments 字段")
        }

        return segments.compactMap { seg -> TranscriptSegment? in
            guard let text = seg["text"] as? String,
                  let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranscriptSegment(text: trimmed, start: start, end: end)
        }
    }

    // MARK: - 工具

    private func buildURL() -> URL {
        let base = config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = base.hasSuffix("/audio/transcriptions")
            ? base
            : "\(base)/audio/transcriptions"
        return URL(string: path)!
    }

    private func guessMIMEType(fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    /// 将 BCP-47 映射为 Whisper 的 ISO-639-1 语言码
    private func mapToWhisperLanguage(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh-Hant", "zh-HK", "zh": return "zh"
        case "ja": return "ja"
        case "ko": return "ko"
        case "en": return "en"
        case "it": return "it"
        case "fr": return "fr"
        case "de": return "de"
        case "es": return "es"
        case "pt": return "pt"
        case "ru": return "ru"
        case "ar": return "ar"
        case "tr": return "tr"
        case "th": return "th"
        case "vi": return "vi"
        case "pl": return "pl"
        case "nl": return "nl"
        default:
            // 取前两位
            let short = String(code.prefix(2))
            return short
        }
    }

    /// 测试连接（尝试发送一个极短的静音）
    func testConnection() async -> Bool {
        let url = buildURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        // 简单 HEAD 或 OPTIONS 不行，Whisper 端点只接受 POST with file
        // 改为检查 endpoint 是否可达
        let checkURL = URL(string: config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
        var checkReq = URLRequest(url: checkURL)
        checkReq.timeoutInterval = 10
        if !config.apiKey.isEmpty {
            checkReq.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: checkReq)
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                return code < 500  // 4xx 也算可达（可能是 auth 问题但服务在线）
            }
            return false
        } catch {
            return false
        }
    }
}

// MARK: - 错误

enum WhisperAPIError: Error, LocalizedError {
    case connectionFailed
    case httpError(Int, String)
    case parseError(String)
    case invalidAudio
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "无法连接到 Whisper API"
        case .httpError(let code, let body):
            let short = body.prefix(200)
            return "Whisper API 错误 HTTP \(code): \(short)"
        case .parseError(let msg): return "Whisper 响应解析失败: \(msg)"
        case .invalidAudio: return "无效的音频文件"
        case .fileTooLarge: return "音频文件过大"
        }
    }
}

// MARK: - Data multipart 扩展

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
