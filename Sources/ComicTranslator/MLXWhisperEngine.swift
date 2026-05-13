import Foundation
import AVFoundation

// MARK: - MLX Whisper 本地引擎（通过 Python subprocess 调用 mlx-whisper）

struct MLXWhisperEngine: Sendable {
    let model: String  // e.g. "mlx-community/whisper-large-v3-turbo"

    /// 转写音频/视频文件，返回带时间戳的片段
    func transcribe(
        fileURL: URL,
        language: String?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        // 1. 如果是视频，先提取音频
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

        // 2. 找到 Python
        let pythonPath = findPython()
        guard let python = pythonPath else {
            throw MLXWhisperError.pythonNotFound
        }

        // 3. 生成临时 Python 脚本
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx_whisper_transcribe_\(UUID().uuidString).py")
        let outputJSON = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx_whisper_output_\(UUID().uuidString).json")

        let langArg = (language != nil && language != "auto") ? "\"\(mapToWhisperLang(language!))\"" : "None"

        let script = """
        import json
        import sys
        import os

        try:
            import mlx_whisper
        except ImportError:
            print("ERROR:mlx-whisper not installed", file=sys.stderr)
            sys.exit(1)

        model_path = "\(model)"

        # 如果是本地路径直接用
        if os.path.isdir(model_path):
            print(f"Using local path: {model_path}", file=sys.stderr)
        else:
            # 尝试从 HuggingFace 缓存中查找
            cache_home = os.path.expanduser("~/.cache/huggingface/hub")
            # HF 缓存目录命名规则: models--{org}--{name}
            safe_name = "models--" + model_path.replace("/", "--")
            cached_snapshot_dir = os.path.join(cache_home, safe_name, "snapshots")

            local_found = False
            if os.path.isdir(cached_snapshot_dir):
                # 取第一个 snapshot
                for snap in os.listdir(cached_snapshot_dir):
                    snap_path = os.path.join(cached_snapshot_dir, snap)
                    if os.path.isdir(snap_path):
                        # 确认文件齐全
                        required = ["config.json", "weights.safetensors"]
                        missing = [f for f in required if not os.path.exists(os.path.join(snap_path, f))]
                        if not missing:
                            model_path = snap_path
                            local_found = True
                            print(f"Using cached model: {model_path}", file=sys.stderr)
                            break

            if not local_found:
                # 走 HuggingFace 下载（可能失败）
                try:
                    from huggingface_hub import snapshot_download
                    model_path = snapshot_download(repo_id=model_path, repo_type="model")
                except Exception as e:
                    print(f"ERROR:Cannot load model: {e}", file=sys.stderr)
                    sys.exit(1)

        result = mlx_whisper.transcribe(
            "\(audioURL.path.replacingOccurrences(of: "\"", with: "\\\""))",
            path_or_hf_repo=model_path,
            language=\(langArg),
            word_timestamps=False,
            verbose=False
        )

        segments = []
        for seg in result.get("segments", []):
            segments.append({
                "text": seg.get("text", "").strip(),
                "start": seg.get("start", 0),
                "end": seg.get("end", 0)
            })

        with open("\(outputJSON.path.replacingOccurrences(of: "\"", with: "\\\""))", "w", encoding="utf-8") as f:
            json.dump({"segments": segments, "text": result.get("text", "")}, f, ensure_ascii=False)

        print("OK")
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: outputJSON)
        }

        progress?(0.2)

        // 4. 执行 Python 脚本
        let (exitCode, stderr) = try await Self.runProcess(executable: python, args: [scriptURL.path])

        progress?(0.9)

        if exitCode != 0 {
            if stderr.contains("mlx-whisper not installed") || stderr.contains("No module named") {
                throw MLXWhisperError.mlxWhisperNotInstalled
            }
            throw MLXWhisperError.executionFailed(stderr)
        }

        // 5. 读取输出 JSON
        guard FileManager.default.fileExists(atPath: outputJSON.path) else {
            throw MLXWhisperError.noOutput
        }

        let data = try Data(contentsOf: outputJSON)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]] else {
            throw MLXWhisperError.parseError
        }

        progress?(1.0)

        return segments.compactMap { seg -> TranscriptSegment? in
            guard let text = seg["text"] as? String,
                  let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranscriptSegment(text: trimmed, start: start, end: end)
        }
    }

    /// 检查 mlx-whisper 是否已安装
    static func checkInstallation() async -> (installed: Bool, pythonPath: String?) {
        guard let python = findPython() else {
            return (false, nil)
        }
        let (code, _) = (try? await runProcess(executable: python, args: ["-c", "import mlx_whisper; print('ok')"])) ?? (1, "")
        return (code == 0, python)
    }

    // MARK: - 工具

    private static func findPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // which python3
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty { return path }
            }
        } catch {}
        return nil
    }

    private func findPython() -> String? {
        Self.findPython()
    }

    private static func runProcess(executable: String, args: [String]) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                // 继承 PATH 以便 mlx-whisper 能找到依赖
                var env = ProcessInfo.processInfo.environment
                let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
                let currentPath = env["PATH"] ?? "/usr/bin"
                env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
                // HuggingFace 镜像（解决国内网络问题）
                if env["HF_ENDPOINT"] == nil {
                    env["HF_ENDPOINT"] = "https://hf-mirror.com"
                }
                process.environment = env

                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                process.standardOutput = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(returning: (process.terminationStatus, stderr))
                } catch {
                    continuation.resume(throwing: MLXWhisperError.executionFailed(error.localizedDescription))
                }
            }
        }
    }

    private func mapToWhisperLang(_ code: String) -> String {
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
        default: return String(code.prefix(2))
        }
    }
}

// MARK: - 错误

enum MLXWhisperError: Error, LocalizedError {
    case pythonNotFound
    case mlxWhisperNotInstalled
    case executionFailed(String)
    case noOutput
    case parseError

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "未找到 Python3。请安装: brew install python3"
        case .mlxWhisperNotInstalled:
            return "mlx-whisper 未安装。请运行: pip3 install mlx-whisper"
        case .executionFailed(let msg):
            let short = msg.prefix(300)
            return "MLX Whisper 执行失败: \(short)"
        case .noOutput:
            return "MLX Whisper 未生成输出"
        case .parseError:
            return "MLX Whisper 输出解析失败"
        }
    }
}
