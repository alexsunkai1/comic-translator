import Foundation

// MARK: - 压缩格式

enum ArchiveFormat: String, CaseIterable {
    case zip, cbz, rar, cbr, sevenZip, tar, tarGz, tarBz2, tarXz

    static func from(fileName: String) -> ArchiveFormat? {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGz }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tbz") { return .tarBz2 }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return .tarXz }
        if lower.hasSuffix(".tar") { return .tar }

        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "zip": return .zip
        case "cbz": return .cbz
        case "rar": return .rar
        case "cbr": return .cbr
        case "7z": return .sevenZip
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .cbz: return "cbz"
        case .rar: return "rar"
        case .cbr: return "cbr"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        }
    }

    var requiresExternalTool: Bool {
        switch self {
        case .rar, .cbr: return true
        case .sevenZip: return true
        default: return false
        }
    }
}

// MARK: - 压缩包操作

enum ArchiveHandler {

    static func extract(_ archiveURL: URL, format: ArchiveFormat, to directory: URL) throws {
        switch format {
        case .zip, .cbz:
            try runDitto(args: ["-xk", archiveURL.path, directory.path])
        case .rar, .cbr:
            guard let unrar = findExecutable("unrar") else {
                throw NSError(domain: "Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 unrar，请安装: brew install unrar"])
            }
            try runProcess(executable: unrar, args: ["x", "-o+", "-y", archiveURL.path, directory.path + "/"])
        case .sevenZip:
            guard let sevenZ = findExecutable("7z") ?? findExecutable("7zz") else {
                throw NSError(domain: "Archive", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到 7z，请安装: brew install p7zip"])
            }
            try runProcess(executable: sevenZ, args: ["x", "-o\(directory.path)", "-y", archiveURL.path])
        case .tar:
            try runProcess(executable: "/usr/bin/tar", args: ["-xf", archiveURL.path, "-C", directory.path])
        case .tarGz:
            try runProcess(executable: "/usr/bin/tar", args: ["-xzf", archiveURL.path, "-C", directory.path])
        case .tarBz2:
            try runProcess(executable: "/usr/bin/tar", args: ["-xjf", archiveURL.path, "-C", directory.path])
        case .tarXz:
            try runProcess(executable: "/usr/bin/tar", args: ["-xJf", archiveURL.path, "-C", directory.path])
        }
    }

    static func create(from directory: URL, to outputURL: URL, format: ArchiveFormat) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        switch format {
        case .zip, .cbz:
            try runDitto(args: ["-ck", "--sequesterRsrc", directory.path, outputURL.path])
        case .rar, .cbr:
            // RAR 无法创建，降级为 ZIP/CBZ
            try runDitto(args: ["-ck", "--sequesterRsrc", directory.path, outputURL.path])
        case .sevenZip:
            guard let sevenZ = findExecutable("7z") ?? findExecutable("7zz") else {
                try runDitto(args: ["-ck", "--sequesterRsrc", directory.path, outputURL.path])
                return
            }
            try runProcess(executable: sevenZ, args: ["a", outputURL.path, "\(directory.path)/*"])
        case .tar:
            try runProcess(executable: "/usr/bin/tar", args: ["-cf", outputURL.path, "-C", directory.path, "."])
        case .tarGz:
            try runProcess(executable: "/usr/bin/tar", args: ["-czf", outputURL.path, "-C", directory.path, "."])
        case .tarBz2:
            try runProcess(executable: "/usr/bin/tar", args: ["-cjf", outputURL.path, "-C", directory.path, "."])
        case .tarXz:
            try runProcess(executable: "/usr/bin/tar", args: ["-cJf", outputURL.path, "-C", directory.path, "."])
        }
    }

    // MARK: - 工具查找

    static func findExecutable(_ name: String) -> String? {
        let searchPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/local/bin/\(name)"
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {}
        return nil
    }

    static func checkToolAvailability() -> [String: Bool] {
        [
            "unrar": findExecutable("unrar") != nil,
            "7z": findExecutable("7z") != nil || findExecutable("7zz") != nil
        ]
    }

    // MARK: - 进程执行

    private static func runDitto(args: [String]) throws {
        try runProcess(executable: "/usr/bin/ditto", args: args)
    }

    private static func runProcess(executable: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "Archive", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
