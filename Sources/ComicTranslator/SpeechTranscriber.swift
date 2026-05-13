import Foundation
import Speech
import AVFoundation

// MARK: - 转写片段（带时间戳，用于生成字幕）

struct TranscriptSegment: Sendable {
    let text: String
    let start: TimeInterval   // 秒
    let end: TimeInterval
}

// MARK: - 错误

enum SpeechTranscribeError: Error, LocalizedError {
    case notAuthorized
    case dictationDisabled
    case recognizerUnavailable(String)
    case unsupportedLocale(String)
    case audioExtractionFailed
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "未授权使用语音识别。请到「系统设置 → 隐私与安全性 → 语音识别」允许本应用"
        case .dictationDisabled:
            return "系统听写未启用。请到「系统设置 → 键盘 → 听写」打开听写开关（首次会下载语言包）"
        case .recognizerUnavailable(let lang):
            return "语音识别器不可用（语言：\(lang)），请先在系统设置的听写中下载对应语言"
        case .unsupportedLocale(let lang):
            return "当前系统不支持识别语言：\(lang)"
        case .audioExtractionFailed:
            return "无法从视频中提取音频"
        case .recognitionFailed(let msg):
            return "语音识别失败：\(msg)"
        }
    }
}

// MARK: - 转写引擎

actor SpeechTranscriber {
    /// 请求用户授权使用语音识别
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    /// 从音频/视频文件转写，返回带时间戳的片段列表
    /// - Parameter languageCode: BCP-47，如 "ja-JP"、"en-US"、"auto"（自动按文件名启发）
    func transcribe(
        fileURL: URL,
        languageCode: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        // 1. 授权
        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            throw SpeechTranscribeError.notAuthorized
        }

        // 2. 若是视频，先抽取音频到临时 m4a
        let audioURL: URL
        let tempAudio: URL?
        let isVideo = Self.videoExtensions.contains(fileURL.pathExtension.lowercased())
        if isVideo {
            let extracted = try await Self.extractAudio(from: fileURL)
            audioURL = extracted
            tempAudio = extracted
        } else {
            audioURL = fileURL
            tempAudio = nil
        }

        defer {
            if let t = tempAudio { try? FileManager.default.removeItem(at: t) }
        }

        // 3. 选择识别器
        let locale = Self.resolveLocale(code: languageCode, fileName: fileURL.lastPathComponent)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechTranscribeError.unsupportedLocale(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw SpeechTranscribeError.recognizerUnavailable(locale.identifier)
        }
        // 请求设备本地识别（不上传苹果服务器），macOS 支持性因语言而异
        recognizer.defaultTaskHint = .dictation

        // 4. 发起识别
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        // 尝试强制本地（如果可用）
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // 获取音频总时长用于进度
        let asset = AVURLAsset(url: audioURL)
        let totalSeconds: Double
        if #available(macOS 13.0, *) {
            totalSeconds = (try? await asset.load(.duration).seconds) ?? 0
        } else {
            totalSeconds = asset.duration.seconds
        }

        // 5. 收集结果（Speech API 是回调式，用 continuation 包装）
        return try await withCheckedThrowingContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    let ns = error as NSError
                    let message = error.localizedDescription
                    // 某些空音频或结束时 API 返回 "no speech detected" 不应视作失败
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                        continuation.resume(returning: [])
                        return
                    }
                    // 听写被禁用 → 清晰提示
                    if message.localizedCaseInsensitiveContains("siri") && message.localizedCaseInsensitiveContains("dictation") {
                        continuation.resume(throwing: SpeechTranscribeError.dictationDisabled)
                        return
                    }
                    if message.localizedCaseInsensitiveContains("dictation") {
                        continuation.resume(throwing: SpeechTranscribeError.dictationDisabled)
                        return
                    }
                    continuation.resume(throwing: SpeechTranscribeError.recognitionFailed(message))
                    return
                }
                guard let result = result else { return }

                // 更新进度（按最后一个分段的结束时间）
                if let last = result.bestTranscription.segments.last, totalSeconds > 0 {
                    let p = min(1.0, (last.timestamp + last.duration) / totalSeconds)
                    progress?(p)
                }

                // 只在最终结果处返回
                guard result.isFinal else { return }

                let segments = Self.buildSegments(from: result.bestTranscription)
                progress?(1.0)
                continuation.resume(returning: segments)
            }
            _ = task
        }
    }

    // MARK: - 片段合并

    /// 把 SF 的细粒度 word 级 segment 合并为句子级（便于字幕）
    nonisolated static func buildSegments(from transcription: SFTranscription) -> [TranscriptSegment] {
        let words = transcription.segments
        guard !words.isEmpty else { return [] }

        var result: [TranscriptSegment] = []
        var buffer: [SFTranscriptionSegment] = []
        let maxDuration: TimeInterval = 6.0      // 单条字幕最多 6 秒
        let maxGap: TimeInterval = 0.8           // 停顿 > 0.8 秒切分
        let maxChars = 45                        // 单条字幕最多约 45 字符

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer.map(\.substring).joined(separator: " ")
            let start = buffer.first!.timestamp
            let last = buffer.last!
            let end = last.timestamp + last.duration
            result.append(TranscriptSegment(text: text.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end))
            buffer.removeAll()
        }

        for (i, seg) in words.enumerated() {
            if buffer.isEmpty {
                buffer.append(seg)
                continue
            }
            let prev = buffer.last!
            let gap = seg.timestamp - (prev.timestamp + prev.duration)
            let currentLength = buffer.map(\.substring).joined(separator: " ").count
            let currentDuration = (prev.timestamp + prev.duration) - buffer.first!.timestamp

            let shouldBreak = gap > maxGap
                || currentDuration > maxDuration
                || currentLength > maxChars
                || isSentenceEnd(prev.substring)

            if shouldBreak {
                flush()
            }
            buffer.append(seg)

            // 最后一个 word 结束时强制 flush
            if i == words.count - 1 {
                flush()
            }
        }
        return result
    }

    nonisolated static func isSentenceEnd(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return ".!?。！？".contains(last)
    }

    // MARK: - 视频 → 音频

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "flac", "aiff", "aif", "caf", "ogg"]

    /// 从视频中提取音频，输出 m4a（AAC）到临时目录
    nonisolated static func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct_audio_\(UUID().uuidString).m4a")

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechTranscribeError.audioExtractionFailed
        }
        exporter.outputURL = outURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        if #available(macOS 15.0, *) {
            try await exporter.export(to: outURL, as: .m4a)
        } else {
            await exporter.export()
            if exporter.status != .completed {
                throw SpeechTranscribeError.audioExtractionFailed
            }
        }

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw SpeechTranscribeError.audioExtractionFailed
        }
        return outURL
    }

    // MARK: - Locale 解析

    nonisolated static func resolveLocale(code: String, fileName: String) -> Locale {
        let langCode = code == "auto" ? autoDetectLanguage(fileName: fileName) : code
        return Locale(identifier: bcp47(from: langCode))
    }

    /// 从文件名启发式识别语言
    nonisolated static func autoDetectLanguage(fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.contains("粤语") || lower.contains("广东话") || lower.contains("cantonese") || lower.contains("[hk]") {
            return "zh-HK"
        }
        if lower.contains("japanese") || lower.contains("日本語") || lower.contains("日文") || lower.contains("日语")
            || lower.contains("[jp]") || lower.contains("[ja]") || lower.contains("(jp)") {
            return "ja"
        }
        if lower.contains("korean") || lower.contains("한국어") || lower.contains("韩文") || lower.contains("韩语") {
            return "ko"
        }
        if lower.contains("english") || lower.contains("英文") || lower.contains("[en]") || lower.contains("(en)") {
            return "en"
        }
        if lower.contains("中文") || lower.contains("chinese") || lower.contains("[zh]") || lower.contains("普通话") || lower.contains("国语") {
            return "zh-Hans"
        }
        if lower.contains("italian") || lower.contains("イタリア") || lower.contains("意大利") {
            return "it"
        }
        if lower.contains("french") || lower.contains("法语") { return "fr" }
        if lower.contains("german") || lower.contains("deutsch") || lower.contains("德语") { return "de" }
        if lower.contains("spanish") || lower.contains("español") || lower.contains("西班牙") { return "es" }
        return "en"  // 默认英语
    }

    /// 简单语言码 → BCP-47 Speech locale
    nonisolated static func bcp47(from code: String) -> String {
        switch code {
        case "zh-Hans", "zh": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "zh-HK": return "zh-HK"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "en": return "en-US"
        case "it": return "it-IT"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        case "ar": return "ar-SA"
        case "tr": return "tr-TR"
        case "th": return "th-TH"
        case "vi": return "vi-VN"
        case "pl": return "pl-PL"
        case "nl": return "nl-NL"
        default: return code.contains("-") ? code : "\(code)-\(code.uppercased())"
        }
    }

    /// 列出当前机器支持的识别语言
    nonisolated static func supportedLocales() -> [Locale] {
        Array(SFSpeechRecognizer.supportedLocales()).sorted { $0.identifier < $1.identifier }
    }
}

// MARK: - SRT 字幕生成

enum SubtitleWriter {

    /// 原文 + 译文双语 SRT（原文在上，译文在下）
    static func writeBilingualSRT(
        segments: [TranscriptSegment],
        translations: [String],
        to url: URL
    ) throws {
        var lines: [String] = []
        for (i, seg) in segments.enumerated() {
            let translated = i < translations.count ? translations[i] : ""
            let text = translated.isEmpty
                ? seg.text
                : "\(seg.text)\n\(translated)"
            lines.append("\(i + 1)")
            lines.append("\(formatTime(seg.start)) --> \(formatTime(seg.end))")
            lines.append(text)
            lines.append("")
        }
        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 仅译文 SRT
    static func writeTranslationSRT(
        segments: [TranscriptSegment],
        translations: [String],
        to url: URL
    ) throws {
        var lines: [String] = []
        for (i, seg) in segments.enumerated() {
            let translated = i < translations.count ? translations[i] : seg.text
            lines.append("\(i + 1)")
            lines.append("\(formatTime(seg.start)) --> \(formatTime(seg.end))")
            lines.append(translated.isEmpty ? seg.text : translated)
            lines.append("")
        }
        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// TXT 纯文本转录
    static func writeTXT(
        segments: [TranscriptSegment],
        translations: [String],
        to url: URL,
        bilingual: Bool = true
    ) throws {
        var lines: [String] = []
        for (i, seg) in segments.enumerated() {
            let translated = i < translations.count ? translations[i] : ""
            if bilingual && !translated.isEmpty {
                lines.append("[\(formatTimeShort(seg.start))] \(seg.text)")
                lines.append("           \(translated)")
            } else {
                lines.append("[\(formatTimeShort(seg.start))] \(translated.isEmpty ? seg.text : translated)")
            }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// HH:MM:SS,mmm
    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    /// MM:SS
    private static func formatTimeShort(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
