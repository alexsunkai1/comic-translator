import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var translator = ComicTranslator()

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var apiStatus: APIStatus = .unknown
    @State private var isDropTargeted: Bool = false

    enum APIStatus {
        case unknown, connected, failed
    }

    var body: some View {
        HSplitView {
            // 左侧：设置
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    apiSection
                    languageSection
                    domainSection
                    advancedSection
                }
                .padding()
            }
            .frame(minWidth: 380)

            // 右侧：文件列表和日志
            VSplitView {
                fileListSection
                    .frame(minHeight: 240)

                logsView
                    .frame(minHeight: 160)
            }
            .frame(minWidth: 440)
        }
        .frame(minWidth: 840, minHeight: 620)
    }

    // MARK: - 文件列表区

    private var fileListSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("待翻译文件", systemImage: "doc.on.doc")
                    .font(.callout.bold())

                if !translator.fileTasks.isEmpty {
                    Text("(\(translator.overallProgress.current)/\(translator.overallProgress.total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        selectFiles()
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(translator.isProcessing)

                    if !translator.fileTasks.isEmpty {
                        Button {
                            translator.clearFiles()
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(translator.isProcessing)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // 文件列表
            if translator.fileTasks.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(translator.fileTasks) { task in
                            fileTaskRow(task)
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            // 底部操作栏
            actionBar
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding(4)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("拖拽压缩包到这里，或点击「添加」按钮")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("支持 ZIP / CBZ / RAR / CBR / 7z / tar.gz 等，可一次添加多个")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func fileTaskRow(_ task: FileTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon(for: task.status)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.inputURL.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let output = task.outputURL {
                        Text("→ " + output.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let err = task.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if case .processing = task.status, let p = task.progress {
                        Text("\(p.stage.rawValue) · \(p.message)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    } else {
                        Text(statusText(for: task.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 单个文件操作
                if case .completed(let url) = task.status {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中显示")
                }

                Button {
                    translator.removeFile(id: task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .disabled(translator.isProcessing)
                .help("移除")
            }

            // 处理中的小进度条
            if case .processing = task.status, let p = task.progress, p.totalFiles > 0 {
                ProgressView(value: Double(p.currentFile), total: Double(p.totalFiles))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor(for: task.status))
        )
    }

    @ViewBuilder
    private func statusIcon(for status: FileTaskStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .processing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func statusText(for status: FileTaskStatus) -> String {
        switch status {
        case .pending: return "等待中"
        case .processing: return "处理中"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }

    private func backgroundColor(for status: FileTaskStatus) -> Color {
        switch status {
        case .pending: return Color.secondary.opacity(0.04)
        case .processing: return Color.blue.opacity(0.08)
        case .completed: return Color.green.opacity(0.08)
        case .failed: return Color.red.opacity(0.08)
        }
    }

    // MARK: - 操作栏

    private var actionBar: some View {
        HStack {
            if translator.batchCompleted, let last = translator.lastCompletedOutput {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([last])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if translator.isProcessing {
                let prog = translator.overallProgress
                if prog.total > 0 {
                    ProgressView(value: Double(prog.current), total: Double(prog.total))
                        .frame(width: 120)
                }
                Text("\(prog.current)/\(prog.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if translator.isProcessing {
                Button("取消", role: .cancel) {
                    translator.cancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: .command)
            }

            Button {
                translator.translateBatch(settings: settings)
            } label: {
                if translator.isProcessing {
                    Label("处理中...", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("开始翻译 (\(translator.fileTasks.count))", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(translator.fileTasks.isEmpty || translator.isProcessing)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - API 配置

    private var apiSection: some View {
        GroupBox("翻译 API") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("API 类型")
                        .frame(width: 80, alignment: .trailing)
                    Picker("", selection: $settings.apiFormat) {
                        ForEach(APIFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.apiFormat) { _, newValue in
                        if settings.apiEndpoint.isEmpty {
                            settings.apiEndpoint = newValue.defaultEndpoint
                        }
                    }
                }

                HStack {
                    Text("Endpoint")
                        .frame(width: 80, alignment: .trailing)
                    TextField("API URL", text: $settings.apiEndpoint)
                        .textFieldStyle(.roundedBorder)
                    apiStatusIcon
                }

                if settings.apiFormat == .openaiCompatible {
                    HStack {
                        Text("API Key")
                            .frame(width: 80, alignment: .trailing)
                        SecureField("Bearer token", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Text("模型")
                        .frame(width: 80, alignment: .trailing)
                    if availableModels.isEmpty {
                        TextField("模型名称", text: $settings.modelID)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $settings.modelID) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            if !availableModels.contains(settings.modelID) {
                                Text(settings.modelID).tag(settings.modelID)
                            }
                        }
                        .labelsHidden()
                    }

                    Button {
                        refreshModels()
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("获取可用模型列表")
                }

                HStack {
                    Text("")
                        .frame(width: 80)
                    Button("测试连接") {
                        testAPIConnection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var apiStatusIcon: some View {
        switch apiStatus {
        case .unknown:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .help("未测试")
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("已连接")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("连接失败")
        }
    }

    // MARK: - 语言设置

    private var languageSection: some View {
        GroupBox("语言设置") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("源语言")
                        .frame(width: 80, alignment: .trailing)
                    Picker("", selection: $settings.sourceLang) {
                        ForEach(LanguageOption.sourceLanguages) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .labelsHidden()
                }

                HStack {
                    Text("目标语言")
                        .frame(width: 80, alignment: .trailing)
                    Picker("", selection: $settings.targetLang) {
                        ForEach(LanguageOption.allLanguages) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .labelsHidden()
                }

                HStack {
                    Text("输出格式")
                        .frame(width: 80, alignment: .trailing)
                    Picker("", selection: $settings.outputFormat) {
                        ForEach(OutputFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 领域优化

    private var domainSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("领域优化", systemImage: "target")
                        .font(.callout.bold())
                    Spacer()
                    Picker("", selection: $settings.domain) {
                        ForEach(TranslationDomain.allCases) { domain in
                            Label(domain.displayName, systemImage: domain.icon).tag(domain)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                if settings.domain != .general {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text(settings.domain.shortDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.06))
                    .cornerRadius(4)
                }

                if settings.domain == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自定义领域提示词")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $settings.customDomainPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 80)
                            .border(Color.secondary.opacity(0.3), width: 1)
                        Text("描述该领域的翻译要求，如术语表、风格偏好等")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 高级设置

    private var advancedSection: some View {
        DisclosureGroup("高级设置") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("并发数")
                        .frame(width: 80, alignment: .trailing)
                    Stepper(value: $settings.concurrency, in: 1...16) {
                        Text("\(settings.concurrency) 路并行")
                            .font(.callout)
                    }
                }

                HStack {
                    Text("温度")
                        .frame(width: 80, alignment: .trailing)
                    Slider(value: $settings.temperature, in: 0...1, step: 0.1)
                    Text(String(format: "%.1f", settings.temperature))
                        .font(.callout.monospacedDigit())
                        .frame(width: 30)
                }

                VStack(alignment: .leading) {
                    Text("自定义 Prompt 模板（可选）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $settings.customPromptTemplate)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .border(Color.secondary.opacity(0.3), width: 1)
                    Text("变量: {text} {source} {target} {domain}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - 日志

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("日志", systemImage: "list.bullet.rectangle")
                    .font(.callout.bold())
                Spacer()
                if !translator.logs.isEmpty {
                    Button {
                        translator.logs.removeAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("清空日志")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if translator.logs.isEmpty {
                            Text("暂无日志")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                                .padding()
                        } else {
                            ForEach(translator.logs) { log in
                                logRow(log)
                                    .id(log.id)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: translator.logs.count) { _, _ in
                    if let last = translator.logs.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ log: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(colorForLevel(log.level))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(log.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(textColorForLevel(log.level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func colorForLevel(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func textColorForLevel(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - 动作

    private func selectFiles() {
        let panel = NSOpenPanel()
        var types: [UTType] = []
        for ext in ["zip", "cbz", "rar", "cbr", "7z", "gz", "bz2", "xz", "tar", "tgz"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if types.isEmpty { types = [.data] }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true  // 启用多选
        panel.canChooseDirectories = false
        panel.message = "选择要翻译的压缩包（可多选）"

        if panel.runModal() == .OK {
            translator.addFiles(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urls.append(url)
            }
        }

        group.notify(queue: .main) {
            let filtered = urls.filter { ArchiveFormat.from(fileName: $0.lastPathComponent) != nil }
            if !filtered.isEmpty {
                self.translator.addFiles(filtered)
            }
        }
    }

    private func refreshModels() {
        isLoadingModels = true
        let config = TranslationConfig(
            endpoint: settings.apiEndpoint,
            apiKey: settings.apiKey,
            modelID: settings.modelID,
            temperature: settings.temperature,
            customPromptTemplate: settings.customPromptTemplate,
            domainInstruction: settings.domain.systemInstruction(customPrompt: settings.customDomainPrompt)
        )
        let api = makeTranslationAPI(format: settings.apiFormat, config: config)
        Task { @MainActor in
            let models = await api.listModels()
            self.availableModels = models
            self.isLoadingModels = false
        }
    }

    private func testAPIConnection() {
        apiStatus = .unknown
        let config = TranslationConfig(
            endpoint: settings.apiEndpoint,
            apiKey: settings.apiKey,
            modelID: settings.modelID,
            temperature: settings.temperature,
            customPromptTemplate: settings.customPromptTemplate,
            domainInstruction: settings.domain.systemInstruction(customPrompt: settings.customDomainPrompt)
        )
        let api = makeTranslationAPI(format: settings.apiFormat, config: config)
        Task { @MainActor in
            let ok = await api.testConnection()
            self.apiStatus = ok ? .connected : .failed
        }
    }
}
