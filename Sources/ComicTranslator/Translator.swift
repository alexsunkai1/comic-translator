import Foundation
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 任务状态

enum TaskStage: String, Sendable {
    case idle = "就绪"
    case extracting = "解压中"
    case ocr = "OCR 识别"
    case translating = "翻译中"
    case rendering = "渲染中"
    case packing = "打包中"
    case completed = "已完成"
    case failed = "失败"
}

struct TaskProgress: Sendable {
    let stage: TaskStage
    let currentFile: Int
    let totalFiles: Int
    let fileName: String
    let message: String
}

// MARK: - 单文件任务状态（批量处理时每个文件一条）

enum FileTaskStatus: Sendable {
    case pending
    case processing
    case completed(URL)
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "等待中"
        case .processing: return "处理中"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }
}

struct FileTask: Identifiable, Sendable {
    let id: UUID
    let inputURL: URL
    var status: FileTaskStatus
    var progress: TaskProgress?
    var outputURL: URL?
    var errorMessage: String?

    init(inputURL: URL) {
        self.id = UUID()
        self.inputURL = inputURL
        self.status = .pending
    }
}

// MARK: - 日志条目

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: Sendable {
        case info, success, warning, error
    }
}

// MARK: - Translator（主协调器）

@MainActor
final class ComicTranslator: ObservableObject {
    @Published var isProcessing = false
    @Published var fileTasks: [FileTask] = []
    @Published var currentBatchIndex: Int = 0
    @Published var logs: [LogEntry] = []
    @Published var batchCompleted: Bool = false

    private let ocrEngine = OCREngine()
    private let cache = TranslationCache()
    private var currentTask: Task<Void, Never>?

    /// 整体进度：已处理文件 / 总文件
    var overallProgress: (current: Int, total: Int) {
        let total = fileTasks.count
        let done = fileTasks.reduce(0) { count, task in
            switch task.status {
            case .completed, .failed: return count + 1
            default: return count
            }
        }
        return (done, total)
    }

    /// 当前正在处理的文件（用于显示大进度条）
    var activeTask: FileTask? {
        fileTasks.first { if case .processing = $0.status { return true } else { return false } }
    }

    /// 最近一次完成的输出（用于"在 Finder 中显示"按钮）
    var lastCompletedOutput: URL? {
        fileTasks.reversed().first { if case .completed = $0.status { return true } else { return false } }
            .flatMap { if case .completed(let url) = $0.status { return url } else { return nil } }
    }

    var anyFailed: Bool {
        fileTasks.contains { if case .failed = $0.status { return true } else { return false } }
    }

    // MARK: - 任务管理

    func addFiles(_ urls: [URL]) {
        guard !isProcessing else { return }
        let existing = Set(fileTasks.map { $0.inputURL.path })
        for url in urls {
            if !existing.contains(url.path) {
                fileTasks.append(FileTask(inputURL: url))
            }
        }
        batchCompleted = false
    }

    func removeFile(id: UUID) {
        guard !isProcessing else { return }
        fileTasks.removeAll { $0.id == id }
    }

    func clearFiles() {
        guard !isProcessing else { return }
        fileTasks.removeAll()
        batchCompleted = false
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        addLog(.warning, "⚠️ 已取消")
    }

    // MARK: - 批量翻译

    func translateBatch(settings: AppSettings) {
        guard !isProcessing, !fileTasks.isEmpty else { return }

        isProcessing = true
        batchCompleted = false
        logs.removeAll()

        // 重置所有任务状态
        for i in fileTasks.indices {
            fileTasks[i].status = .pending
            fileTasks[i].progress = nil
            fileTasks[i].outputURL = nil
            fileTasks[i].errorMessage = nil
        }

        currentTask = Task { @MainActor in
            defer {
                self.isProcessing = false
                self.batchCompleted = true
            }

            let total = self.fileTasks.count
            self.addLog(.info, "🚀 开始批量翻译 \(total) 个文件")

            // 预先测试 API 连接（只测一次）
            let apiConfig = TranslationConfig(
                endpoint: settings.apiEndpoint,
                apiKey: settings.apiKey,
                modelID: settings.modelID,
                temperature: settings.temperature,
                customPromptTemplate: settings.customPromptTemplate,
                domainInstruction: settings.domain.systemInstruction(customPrompt: settings.customDomainPrompt)
            )
            let api = makeTranslationAPI(format: settings.apiFormat, config: apiConfig)

            guard await api.testConnection() else {
                self.addLog(.error, "❌ 无法连接到翻译 API: \(settings.apiEndpoint)")
                for i in self.fileTasks.indices {
                    self.fileTasks[i].status = .failed("API 连接失败")
                    self.fileTasks[i].errorMessage = "API 连接失败"
                }
                return
            }
            self.addLog(.success, "✅ API 连接成功 (\(settings.apiFormat.displayName))")

            if settings.domain != .general {
                self.addLog(.info, "🎯 领域优化: \(settings.domain.displayName)")
            }

            self.addLog(.info, "═════════════════════════════════════")

            // 逐文件处理
            for idx in 0..<total {
                guard !Task.isCancelled else { break }

                let fileTask = self.fileTasks[idx]
                self.currentBatchIndex = idx
                self.fileTasks[idx].status = .processing
                self.addLog(.info, "📂 [\(idx + 1)/\(total)] \(fileTask.inputURL.lastPathComponent)")

                do {
                    let output = try await self.processArchive(
                        inputURL: fileTask.inputURL,
                        settings: settings,
                        api: api,
                        progressUpdate: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                self?.fileTasks[idx].progress = progress
                            }
                        }
                    )
                    self.fileTasks[idx].status = .completed(output)
                    self.fileTasks[idx].outputURL = output
                    self.addLog(.success, "✅ [\(idx + 1)/\(total)] \(output.lastPathComponent)")
                } catch {
                    if Task.isCancelled {
                        self.fileTasks[idx].status = .failed("已取消")
                        break
                    }
                    let msg = error.localizedDescription
                    self.fileTasks[idx].status = .failed(msg)
                    self.fileTasks[idx].errorMessage = msg
                    self.addLog(.error, "❌ [\(idx + 1)/\(total)] \(msg)")
                }
            }

            self.addLog(.info, "═════════════════════════════════════")
            let successCount = self.fileTasks.filter { if case .completed = $0.status { return true } else { return false } }.count
            let failCount = self.fileTasks.filter { if case .failed = $0.status { return true } else { return false } }.count
            self.addLog(.info, "📊 批量完成: \(successCount) 成功, \(failCount) 失败")
        }
    }

    private func processArchive(
        inputURL: URL,
        settings: AppSettings,
        api: TranslationAPI,
        progressUpdate: @escaping (TaskProgress) -> Void
    ) async throws -> URL {
        // 1. 识别输入格式
        guard let format = ArchiveFormat.from(fileName: inputURL.lastPathComponent) else {
            throw NSError(domain: "Translator", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的格式: \(inputURL.pathExtension)"])
        }

        // 2. 输出路径
        let outputFormat = resolveOutputFormat(settings: settings, inputFormat: format)
        let outputURL = generateOutputURL(from: inputURL, outputFormat: outputFormat)

        // 3. 临时目录
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicTranslator_\(UUID().uuidString)", isDirectory: true)
        let extractDir = tempDir.appendingPathComponent("in")
        let outputDir = tempDir.appendingPathComponent("out")

        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 4. 解压
        progressUpdate(TaskProgress(stage: .extracting, currentFile: 0, totalFiles: 1, fileName: inputURL.lastPathComponent, message: "解压中..."))
        try ArchiveHandler.extract(inputURL, format: format, to: extractDir)

        try Task.checkCancellation()

        // 5. 收集图片
        let imageExts = Set(["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "webp", "heic"])
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: extractDir.path) else {
            throw NSError(domain: "Translator", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法遍历"])
        }

        var imageFiles: [String] = []
        while let file = enumerator.nextObject() as? String {
            let ext = (file as NSString).pathExtension.lowercased()
            if imageExts.contains(ext) { imageFiles.append(file) }
        }
        imageFiles.sort()

        guard !imageFiles.isEmpty else {
            throw NSError(domain: "Translator", code: 4, userInfo: [NSLocalizedDescriptionKey: "无图片文件"])
        }

        // 6. 源语言 OCR
        let sourceLangOpt = LanguageOption.named(settings.sourceLang) ?? LanguageOption.auto
        let ocrLangs = sourceLangOpt.ocrLanguages

        // 7. 逐图处理
        var translated = 0
        var skipped = 0
        var failed = 0

        for (index, relativePath) in imageFiles.enumerated() {
            try Task.checkCancellation()

            let inputPath = extractDir.appendingPathComponent(relativePath).path
            let outputPath = outputDir.appendingPathComponent(relativePath).path
            let outputParent = (outputPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: outputParent, withIntermediateDirectories: true)

            progressUpdate(TaskProgress(
                stage: .ocr, currentFile: index + 1, totalFiles: imageFiles.count,
                fileName: relativePath, message: "OCR 识别"
            ))

            guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                try? fm.copyItem(atPath: inputPath, toPath: outputPath)
                failed += 1
                continue
            }

            let ocrResults: [OCRResult]
            do {
                ocrResults = try await ocrEngine.recognize(image: cgImage, languages: ocrLangs)
            } catch {
                try? fm.copyItem(atPath: inputPath, toPath: outputPath)
                failed += 1
                continue
            }

            if ocrResults.isEmpty {
                try? fm.copyItem(atPath: inputPath, toPath: outputPath)
                skipped += 1
                continue
            }

            progressUpdate(TaskProgress(
                stage: .translating, currentFile: index + 1, totalFiles: imageFiles.count,
                fileName: relativePath, message: "翻译 \(ocrResults.count) 个文本块"
            ))

            let texts = ocrResults.map(\.text)
            let translations = await translateTextsBatch(
                texts: texts,
                from: settings.sourceLang,
                to: settings.targetLang,
                api: api,
                cache: cache,
                concurrency: settings.concurrency,
                domainKey: settings.domain.rawValue
            )

            progressUpdate(TaskProgress(
                stage: .rendering, currentFile: index + 1, totalFiles: imageFiles.count,
                fileName: relativePath, message: "渲染"
            ))

            guard let rendered = ImageRenderer.renderTranslated(
                original: cgImage,
                ocrResults: ocrResults,
                translations: translations
            ) else {
                try? fm.copyItem(atPath: inputPath, toPath: outputPath)
                failed += 1
                continue
            }

            let outUrl = URL(fileURLWithPath: outputPath)
            let imgFormat = ImageRenderer.imageFormat(for: outUrl)

            do {
                try ImageRenderer.saveImage(rendered, to: outUrl, format: imgFormat)
                translated += 1
            } catch {
                try? fm.copyItem(atPath: inputPath, toPath: outputPath)
                failed += 1
            }
        }

        // 8. 复制非图片文件
        if let enumerator2 = fm.enumerator(atPath: extractDir.path) {
            while let file = enumerator2.nextObject() as? String {
                let ext = (file as NSString).pathExtension.lowercased()
                if !imageExts.contains(ext) {
                    let src = extractDir.appendingPathComponent(file).path
                    let dst = outputDir.appendingPathComponent(file).path
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: src, isDirectory: &isDir), !isDir.boolValue {
                        let dstParent = (dst as NSString).deletingLastPathComponent
                        try? fm.createDirectory(atPath: dstParent, withIntermediateDirectories: true)
                        try? fm.copyItem(atPath: src, toPath: dst)
                    }
                }
            }
        }

        // 9. 打包
        progressUpdate(TaskProgress(
            stage: .packing, currentFile: imageFiles.count, totalFiles: imageFiles.count,
            fileName: outputURL.lastPathComponent, message: "打包"
        ))
        try ArchiveHandler.create(from: outputDir, to: outputURL, format: outputFormat)

        addLog(.info, "   📊 \(translated) 已翻译, \(skipped) 无文字, \(failed) 失败")

        return outputURL
    }

    func addLog(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logs.append(entry)
        if logs.count > 1000 {
            logs.removeFirst(logs.count - 1000)
        }
    }

    private func resolveOutputFormat(settings: AppSettings, inputFormat: ArchiveFormat) -> ArchiveFormat {
        switch settings.outputFormat {
        case .sameAsInput:
            switch inputFormat {
            case .rar: return .zip
            case .cbr: return .cbz
            default: return inputFormat
            }
        case .zip: return .zip
        case .cbz: return .cbz
        }
    }

    private func generateOutputURL(from inputURL: URL, outputFormat: ArchiveFormat) -> URL {
        let dir = inputURL.deletingLastPathComponent()
        let fileName = inputURL.lastPathComponent
        let lower = fileName.lowercased()

        let baseName: String
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar.xz") {
            let withoutLast = (fileName as NSString).deletingPathExtension
            baseName = (withoutLast as NSString).deletingPathExtension
        } else {
            baseName = (fileName as NSString).deletingPathExtension
        }

        let patterns = [
            "日文", "日语", "Japanese", "japanese", "JP", "jp", "JA", "ja",
            "イタリア翻訳", "イタリア語", "Italian", "italian",
            "英文", "英语", "English", "english",
            "韩文", "韩语", "Korean", "korean",
            "French", "french", "Deutsch", "deutsch", "German", "german"
        ]
        var outputName = baseName
        var replaced = false
        for p in patterns {
            if baseName.contains(p) {
                outputName = baseName.replacingOccurrences(of: p, with: "中文")
                replaced = true
                break
            }
        }
        if !replaced {
            outputName = baseName + "-中文"
        }

        // 避免覆盖已存在的文件
        var finalURL = dir.appendingPathComponent(outputName + "." + outputFormat.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = dir.appendingPathComponent("\(outputName)-\(counter).\(outputFormat.fileExtension)")
            counter += 1
        }
        return finalURL
    }
}
