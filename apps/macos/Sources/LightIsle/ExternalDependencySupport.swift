import AppKit
import Foundation

/// Deliberately fixed allowlist. Never accept a shell command, URL, formula
/// name or path supplied by a browser or user-editable configuration.
enum ExternalDependency: String, CaseIterable, Identifiable {
    case ffmpeg
    case aria2
    case smartmontools
    case cloudflared

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .aria2: return "aria2"
        case .smartmontools: return "smartmontools"
        case .cloudflared: return "cloudflared"
        }
    }
    var executable: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .aria2: return "aria2c"
        case .smartmontools: return "smartctl"
        case .cloudflared: return "cloudflared"
        }
    }
    var purpose: String {
        switch self {
        case .ffmpeg: return "媒体探测与按需转码。原片播放不强制依赖它。"
        case .aria2: return "下载中心的 HTTP、FTP 与磁力下载任务。"
        case .smartmontools: return "读取外置硬盘 SMART 详情，部分设备仍需授权。"
        case .cloudflared: return "Cloudflare Tunnel 外网连接；安装不代表隧道已配置或启动。"
        }
    }
    var symbol: String {
        switch self {
        case .ffmpeg: return "film.stack"
        case .aria2: return "arrow.down.circle"
        case .smartmontools: return "externaldrive"
        case .cloudflared: return "cloud"
        }
    }
}

enum DependencyInstallFailure: LocalizedError {
    case unableToCreateLog
    case unableToLaunch(String)
    case brewFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .unableToCreateLog:
            return "无法创建临时安装日志。请检查 Mac 的临时目录权限与剩余容量。"
        case .unableToLaunch:
            return "无法启动 Homebrew。请确认安装未损坏并检查 macOS 权限。"
        case .brewFailed(let exitCode, _):
            return "Homebrew 安装未完成（退出码 \(exitCode)）。请查看下方日志，检查网络、磁盘空间或 Homebrew 权限后重试。"
        }
    }
    var detail: String {
        switch self {
        case .brewFailed(_, let output): return output
        case .unableToLaunch(let message): return message
        default: return ""
        }
    }
}

enum ExternalDependencyInstaller {
    // Copied verbatim from https://brew.sh/, 2026-10-27.
    // Display/copy only: never execute this remote bootstrap script in-app.
    static let officialBrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    static let appleSiliconShellenvCommand =
        #"eval "$(/opt/homebrew/bin/brew shellenv)""#

    // Homebrew is discovered only from fixed installation prefixes; no
    // untrusted PATH entry can replace the package manager executable.
    static let trustedBrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private static let binDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/usr/sbin"
    ]

    static func homebrewPath() -> String? {
        trustedBrewPaths.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func installedPath(for dependency: ExternalDependency) -> String? {
        binDirectories.map { $0 + "/" + dependency.executable }
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func command(for dependency: ExternalDependency, brewPath: String) -> [String] {
        // No sh/zsh/bash -c and no externally supplied arguments.
        [brewPath, "install", dependency.rawValue]
    }

    static func install(_ dependency: ExternalDependency, brewPath: String) throws -> String {
        guard trustedBrewPaths.contains(brewPath),
              FileManager.default.isExecutableFile(atPath: brewPath) else {
            throw DependencyInstallFailure.unableToLaunch("未找到可信任的 Homebrew 安装路径。")
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightisle-dependency-\(UUID().uuidString).log")
        guard FileManager.default.createFile(
            atPath: logURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw DependencyInstallFailure.unableToCreateLog }
        defer { try? FileManager.default.removeItem(at: logURL) }

        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = Array(command(for: dependency, brewPath: brewPath).dropFirst())
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = logHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = binDirectories.joined(separator: ":")
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        process.environment = environment
        do {
            try process.run()
        } catch {
            throw DependencyInstallFailure.unableToLaunch(error.localizedDescription)
        }
        process.waitUntilExit()
        try? logHandle.synchronize()
        let log = (try? logTail(at: logURL)) ?? ""
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            throw DependencyInstallFailure.brewFailed(process.terminationStatus, log)
        }
        return log
    }

    /// Avoid loading arbitrarily large Homebrew logs into memory.
    private static func logTail(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let raw = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        // Do not render terminal control sequences in a native text view.
        let withoutANSI = raw.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression
        )
        return String(withoutANSI.suffix(8_000))
    }
}

@MainActor
final class ExternalDependencyStore: ObservableObject {
    @Published private(set) var brewPath: String?
    @Published private(set) var installed: [ExternalDependency: String] = [:]
    @Published private(set) var installing: ExternalDependency?
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var lastLog: String = ""

    func refresh() {
        brewPath = ExternalDependencyInstaller.homebrewPath()
        installed = Dictionary(uniqueKeysWithValues:
            ExternalDependency.allCases.compactMap { dependency in
                ExternalDependencyInstaller.installedPath(for: dependency)
                    .map { (dependency, $0) }
            })
    }

    func install(_ dependency: ExternalDependency) {
        guard installing == nil else { return }
        refresh()
        guard installed[dependency] == nil else { return }
        guard let brewPath else {
            error = "尚未安装 Homebrew。请先从 brew.sh 安装 Homebrew，再返回此页刷新。"
            return
        }
        installing = dependency
        message = nil
        error = nil
        lastLog = ""
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try ExternalDependencyInstaller.install(dependency, brewPath: brewPath) }
            }.value
            refresh()
            installing = nil
            switch result {
            case .success(let output):
                lastLog = output
                if installed[dependency] != nil {
                    message = "\(dependency.title) 安装完成，已经检测到命令行工具。需要时请刷新对应功能状态。"
                } else {
                    error = "Homebrew 已执行完成，但暂未在常用目录找到 \(dependency.executable)。请检查安装日志或重新打开此页。"
                }
            case .failure(let failure):
                error = failure.localizedDescription
                lastLog = (failure as? DependencyInstallFailure)?.detail ?? ""
            }
        }
    }
}
