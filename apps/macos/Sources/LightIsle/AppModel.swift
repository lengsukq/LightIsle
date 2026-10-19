import SwiftUI
import Foundation
import Darwin

enum CoreState: Equatable {
    case offline
    case starting
    case online
    case stopping
    case error(String)

    var label: String {
        switch self {
        case .offline: return "未运行"
        case .starting: return "正在启动"
        case .online: return "正在运行"
        case .stopping: return "正在停止"
        case .error: return "运行异常"
        }
    }
}
struct NASBackupSchedule: Decodable {
    let enabled: Bool
    let everyHours: Int
    let destination: String?
    let lastAttempt: Int64
    let nextRun: Int64
}

struct NASBackupStatus: Decodable {
    let running: Bool
    let operation: String
    let files: Int
    let bytes: Int64
    let lastError: String?
    let lastSnapshot: String?
    let lastDone: Int64?
}

struct HostMetrics: Decodable {
    let hostname: String
    let architecture: String
    let cpuCount: Int
    let cpuPercent: Double?
    let memoryTotal: UInt64
    let memoryUsed: UInt64
    let diskTotal: UInt64
    let diskFree: UInt64
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var state: CoreState = .offline
    @Published private(set) var endpoint: URL?
    @Published private(set) var details: String = "LightIsle 应用负责管理内置服务的完整生命周期。"
    @Published private(set) var remoteAddress: String?
    @Published private(set) var remoteFingerprint: String?
    @Published private(set) var remoteError: String?
    @Published private(set) var sharedFolderName: String = "SharedFiles"
    @Published private(set) var sharedFolderError: String?
    @Published private(set) var isConfigured: Bool?
    @Published private(set) var initializationError: String?
    @Published private(set) var initializing = false
    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var backupStatus: NASBackupStatus?
    @Published private(set) var backupError: String?
    @Published private(set) var smbListening: Bool?
    @Published private(set) var backupSchedule: NASBackupSchedule?

    private var core: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var readBuffer = ""
    private var stopping = false

    var hasChildProcess: Bool { core != nil }
    var isRemoteEnabled: Bool { remoteAddress != nil }

    func refreshMetrics() {
        guard state == .online else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("stats\n".utf8))
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup status\nbackup schedule status\nsmb status\n".utf8))
    }
    func configureBackupSchedule(hours: Int) {
        guard state == .online, hours == 24 || hours == 168 else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择自动备份目录"
        panel.message = "定时备份只有 LightIsle.app 正在运行时才会执行，不会创建后台守护进程。"
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        sendBackupCommand("backup schedule set \(hours)", path: folder)
    }
    func disableBackupSchedule() {
        guard state == .online else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup schedule off\n".utf8))
    }

    func startBackup() {
        guard state == .online, backupStatus?.running != true else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "备份到此文件夹"
        panel.message = "在所选目录下创建新的 LightIsle-Backup 快照。请选择与共享目录不同的磁盘或独立文件夹。操作不会删除原文件。"
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        sendBackupCommand("backup start", path: chosen)
    }

    func restoreBackup() {
        guard state == .online, backupStatus?.running != true else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "从此备份恢复"
        panel.message = "选择 LightIsle-Backup-... 文件夹。将校验 SHA-256，并恢复到共享目录中新的 LightIsle-Restored-... 文件夹，不会覆盖现有文件。"
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        sendBackupCommand("backup restore", path: chosen)
    }

    private func sendBackupCommand(_ operation: String, path: String) {
        let encoded = Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        backupError = nil
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data((operation + " " + encoded + "\n").utf8))
    }

    func initializeAdministrator(username: String, password: String) {
        guard isConfigured == false, !initializing, state == .online else { return }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[A-Za-z0-9_.-]{3,32}$", options: .regularExpression) != nil,
              password.utf8.count >= 12, password.utf8.count <= 256 else {
            initializationError = "用户名需为 3–32 位英数字或 . _ -；密码至少 12 位。"
            return
        }
        let payload = ["username": trimmed, "password": password]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            initializationError = "初始化参数无效"
            return
        }
        let command = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        initializationError = nil
        initializing = true
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data(("admin init " + command + "\n").utf8))
    }

    func openUserWeb() {
        // User business features always open in a normal browser; Mac's
        // native window never embeds a duplicate file or gallery UI.
        if let target = endpoint {
            NSWorkspace.shared.open(target)
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        guard state == .online, let pipe = inputPipe else { return }
        remoteError = nil
        let command = enabled ? "remote on\n" : "remote off\n"
        try? pipe.fileHandleForWriting.write(contentsOf: Data(command.utf8))
    }

    func selectSharedFolder() {
        guard state == .online else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此目录"
        panel.message = "已登录用户将能浏览和修改此目录中的文件，请勿选择包含私人密钥的目录。"
        guard panel.runModal() == .OK, let selected = panel.url?.path else { return }
        let code = Data(selected.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        sharedFolderError = nil
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data(("share set " + code + "\n").utf8))
    }

    func retrySharedFolder() {
        guard state == .online else { return }
        sharedFolderError = nil
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("share retry\n".utf8))
    }

    private init() {}

    func launch() {
        guard core == nil, !stopping else { return }
        let exe = ProcessInfo.processInfo.environment["LIGHTISLE_CORE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("core/lightisled")

        guard let exe, FileManager.default.isExecutableFile(atPath: exe.path) else {
            state = .error("未找到内置的 Go Core。请使用 scripts/build-macos.sh 构建应用。")
            return
        }

        let web = ProcessInfo.processInfo.environment["LIGHTISLE_WEB_ROOT"]
            .map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("web")

        let process = Process()
        process.executableURL = exe
        process.arguments = ["-port", "0", "-web-root", web?.path ?? ""]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            let data = String(decoding: bytes, as: UTF8.self)
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in self?.childDidExit(status: status) }
        }

        do {
            try process.run()
            core = process
            inputPipe = input
            outputPipe = output
            endpoint = nil
            remoteAddress = nil
            remoteFingerprint = nil
            remoteError = nil
            isConfigured = nil
            metrics = nil
            initializing = false
            initializationError = nil
            backupStatus = nil
            backupError = nil
            smbListening = nil
            backupSchedule = nil
            state = .starting
            details = "等待本机 Go Core 提供健康检查服务。"
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            state = .error("启动 Go Core 失败：\(error.localizedDescription)")
            details = "检查应用签名与内置 lightisled 可执行文件。"
        }
    }

    private func consume(_ text: String) {
        readBuffer += text
        while let range = readBuffer.range(of: "\n") {
            let line = String(readBuffer[..<range.lowerBound])
            readBuffer.removeSubrange(..<range.upperBound)
            if line.hasPrefix("LIGHTISLE_BACKUP_STATUS ") {
                let raw = String(line.dropFirst("LIGHTISLE_BACKUP_STATUS ".count))
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                if let data = Data(base64Encoded: normalized),
                   let report = try? JSONDecoder().decode(NASBackupStatus.self, from: data) {
                    backupStatus = report
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_BACKUP_SCHEDULE ") {
                let raw = String(line.dropFirst("LIGHTISLE_BACKUP_SCHEDULE ".count))
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                if let data = Data(base64Encoded: normalized),
                   let report = try? JSONDecoder().decode(NASBackupSchedule.self, from: data) {
                    backupSchedule = report
                }
                continue
            }
            if line == "LIGHTISLE_BACKUP_SCHEDULE_CHANGED" {
                backupError = nil
                try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup schedule status\n".utf8))
                continue
            }
            if line == "LIGHTISLE_BACKUP_STARTED" {
                backupError = nil
                try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup status\n".utf8))
                continue
            }
            if line.hasPrefix("LIGHTISLE_BACKUP_ERROR ") {
                backupError = String(line.dropFirst("LIGHTISLE_BACKUP_ERROR ".count))
                continue
            }
            if line == "LIGHTISLE_SMB_STATUS 1" {
                smbListening = true
                continue
            }
            if line == "LIGHTISLE_SMB_STATUS 0" {
                smbListening = false
                continue
            }
            if line == "LIGHTISLE_CONFIGURED 1" {
                isConfigured = true
                continue
            }
            if line == "LIGHTISLE_CONFIGURED 0" {
                isConfigured = false
                continue
            }
            if line == "LIGHTISLE_INITIALIZED" {
                initializing = false
                isConfigured = true
                initializationError = nil
                continue
            }
            if line.hasPrefix("LIGHTISLE_INIT_ERROR ") {
                initializing = false
                let code = String(line.dropFirst("LIGHTISLE_INIT_ERROR ".count))
                switch code {
                case "already_configured":
                    isConfigured = true
                    initializationError = "管理员已经初始化，请登录 Web 使用。"
                case "invalid_credentials":
                    initializationError = "用户名格式或密码长度不符合要求。"
                default:
                    initializationError = "初始化失败，请检查 Go 服务日志。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_STATS ") {
                let raw = String(line.dropFirst("LIGHTISLE_STATS ".count))
                var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let data = Data(base64Encoded: encoded),
                   let reading = try? JSONDecoder().decode(HostMetrics.self, from: data) {
                    metrics = reading
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_REMOTE_ON ") {
                let words = line.split(separator: " ")
                if words.count == 3 {
                    remoteAddress = String(words[1])
                    remoteFingerprint = String(words[2])
                    remoteError = nil
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ON ") {
                sharedFolderName = String(line.dropFirst("LIGHTISLE_SHARE_ON ".count))
                sharedFolderError = nil
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ERROR ") {
                sharedFolderError = String(line.dropFirst("LIGHTISLE_SHARE_ERROR ".count))
                continue
            }
            if line == "LIGHTISLE_REMOTE_OFF" {
                remoteAddress = nil
                remoteFingerprint = nil
                continue
            }
            if line.hasPrefix("LIGHTISLE_REMOTE_ERROR ") {
                remoteError = String(line.dropFirst("LIGHTISLE_REMOTE_ERROR ".count))
                continue
            }
            guard line.hasPrefix("LIGHTISLE_READY ") else { continue }
            let raw = String(line.dropFirst("LIGHTISLE_READY ".count))
            guard let url = URL(string: raw),
                  url.scheme == "http", url.host == "127.0.0.1" else { continue }
            endpoint = url
            state = .online
            details = "本机 Go Core 已就绪；如尚未初始化，将显示原生管理员设置页面。"
        }
    }

    private func childDidExit(status: Int32) {
        // A late termination callback from a completed stop must not change
        // the app back to an error state.
        guard core != nil else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        inputPipe = nil
        core = nil
        endpoint = nil
        metrics = nil
        remoteAddress = nil
        remoteFingerprint = nil
        isConfigured = nil
        metrics = nil
        initializing = false
        backupStatus = nil
        backupError = nil
        smbListening = nil
        remoteAddress = nil
        remoteFingerprint = nil
        if !stopping {
            state = .error("Go Core 异常退出，退出码 \(status)")
            details = "后端已停止。可点击“重新启动”恢复服务。"
        }
    }

    func stop() async {
        guard let process = core else { return }
        stopping = true
        state = .stopping
        endpoint = nil
        if let input = inputPipe?.fileHandleForWriting {
            // Child might already have exited; a broken pipe is not fatal.
            try? input.write(contentsOf: Data("shutdown\n".utf8))
            input.closeFile()
        }
        // The HTTP server must finish requests and close its listener first.
        for _ in 0..<40 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<15 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        inputPipe = nil
        core = nil
        stopping = false
        state = .offline
    }
}

