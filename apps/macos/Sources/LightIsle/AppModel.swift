import SwiftUI
import Foundation
import Darwin
import LocalAuthentication

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

@MainActor
extension AppModel {
    /// Only the verified native Mac owner can replace SQLite metadata.
    /// The backend is stopped and its data-directory lock is released before
    /// the bundled offline helper is launched. No Web endpoint can do this.
    func activateRestoredMetadata() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true,
              let fullPath = backupStatus?.restoredMetadata else { return }
        let selected = URL(fileURLWithPath: fullPath).standardizedFileURL
        guard selected.lastPathComponent.hasPrefix("LightIsle-RestoredMetadata-") else { return }

        let alert = NSAlert()
        alert.messageText = "应用已恢复的账号与系统配置？"
        alert.informativeText = "将验证 Mac 所有者身份、停止 Go Core、再次检查数据库并替换应用元数据。原数据库会保留在独立回滚目录；共享文件不会覆盖。当前 Web 登录将全部失效。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证身份并应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        activatingMetadata = true
        metadataActivationMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                metadataActivationMessage = "无法验证本机所有者，未修改任何数据。"
                activatingMetadata = false
                return
            }
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份，以离线恢复轻屿账号与设置数据库"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                let result = await Self.runOfflineRecovery(
                    operation: "activate",
                    dataDir: selected.deletingLastPathComponent().path,
                    stage: selected.lastPathComponent,
                    confirmation: "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT"
                )
                metadataActivationMessage = result
                launch()
            } catch {
                metadataActivationMessage = "用户验证取消或失败，现有数据库保持原样。"
            }
            activatingMetadata = false
        }
    }

    func recoverInterruptedMetadata() {
        guard !activatingMetadata, state != .online else { return }
        let alert = NSAlert()
        alert.messageText = "修复中断的离线数据库恢复？"
        alert.informativeText = "仅用于上次恢复过程中断的情况。将恢复之前的数据库，并把中途生成的新文件保存在隔离目录。需要 Mac 所有者认证。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证并回滚")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activatingMetadata = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份以修复中断的数据库恢复"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
                let dataDir = root?.appendingPathComponent("LightIsle").path ?? ""
                guard !dataDir.isEmpty else {
                    metadataActivationMessage = "无法确定应用数据库目录，已停止操作。"
                    activatingMetadata = false
                    return
                }
                metadataActivationMessage = await Self.runOfflineRecovery(
                    operation: "recover",
                    dataDir: dataDir,
                    stage: "",
                    confirmation: "RESTORE_PREVIOUS_METADATA"
                )
                launch()
            } catch {
                metadataActivationMessage = "本机验证取消或失败，未修改数据。"
            }
            activatingMetadata = false
        }
    }

    private static func runOfflineRecovery(operation: String, dataDir: String, stage: String, confirmation: String) async -> String {
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            return "内置离线恢复程序缺失，数据未更改。"
        }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--data-dir", dataDir, "--operation", operation,
                                 "--stage", stage, "--confirm", confirmation]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(4096), as: UTF8.self)
                if process.terminationStatus == 0 {
                    return "离线数据库操作成功：\(text)"
                }
                return "离线数据库操作未成功：\(text)。如提示恢复中断，请选择“修复中断的恢复”。"
            } catch {
                return "无法启动离线恢复工具：\(error.localizedDescription)"
            }
        }.value
    }

}

struct HostVolume: Decodable, Identifiable {
    let name: String
    let mount: String
    let device: String
    let filesystem: String
    let total: UInt64
    let free: UInt64
    let readOnly: Bool
    var id: String { mount }
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
    let restoredMetadata: String?
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
    let volumes: [HostVolume]?
    let networkDownBps: Double?
    let networkUpBps: Double?
    let corePid: Int?
    let coreRssBytes: UInt64?
}

struct MetricHistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let cpu: Double
    let memory: Double
    let download: Double
    let upload: Double
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
    @Published private(set) var sharedFolderPath: String?
    @Published private(set) var sharedFolderError: String?
    @Published private(set) var exportRunning = false
    @Published private(set) var exportMessage: String?
    @Published private(set) var isConfigured: Bool?
    @Published private(set) var initializationError: String?
    @Published private(set) var initializing = false
    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var volumeHealth: [String: VolumeHealthStatus] = [:]
    @Published private(set) var metricHistory: [MetricHistoryPoint] = []
    private var volumeHealthRefreshAt = Date.distantPast
    private var volumeHealthRefreshPending = false
    private var lastHealthMounts: [String] = []

    private func refreshVolumeHealthIfNeeded(_ volumes: [HostVolume]) {
        let mounts = volumes.map(\.mount).sorted()
        guard !mounts.isEmpty, !volumeHealthRefreshPending else { return }
        guard mounts != lastHealthMounts || Date().timeIntervalSince(volumeHealthRefreshAt) >= 300 else { return }
        volumeHealthRefreshPending = true
        volumeHealthRefreshAt = Date()
        lastHealthMounts = mounts
        Task { @MainActor [weak self] in
            let results = await Task.detached(priority: .utility) {
                VolumeHealthReader.readAll(mounts)
            }.value
            self?.volumeHealth = results
            self?.volumeHealthRefreshPending = false
        }
    }
    @Published private(set) var backupStatus: NASBackupStatus?
    @Published private(set) var backupError: String?
    @Published private(set) var activatingMetadata = false
    @Published private(set) var metadataActivationMessage: String?
    @Published private(set) var smbListening: Bool?
    @Published private(set) var backupSchedule: NASBackupSchedule?
    @Published private(set) var portError: String?
    @Published private(set) var webOpenError: String?
    @Published private(set) var vaultMessage: String?
    @Published private(set) var unlockedAdminCredentials: AdminCredentials?
    @Published private(set) var verifyingAdmin = false
    @Published private(set) var resettingAdmin = false
    @Published private(set) var resetAdminMessage: String?
    @Published private(set) var firstAdminUsername: String?
    private var pendingAdminCredentials: AdminCredentials?
    private var directoryWatcher: DirectoryChangeWatcher?
    private var scanRefreshPending = false

    private func scheduleIndexRefresh() {
        guard state == .online, !scanRefreshPending else { return }
        scanRefreshPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.scanRefreshPending = false
            guard self.state == .online else { return }
            try? self.inputPipe?.fileHandleForWriting.write(contentsOf: Data("index scan\n".utf8))
        }
    }

    static let defaultLocalPort = 16666
    var preferredLocalPort: Int {
        let value = UserDefaults.standard.integer(forKey: "lightisle.localPort")
        return (1024...65535).contains(value) ? value : Self.defaultLocalPort
    }

    func saveLocalPort(_ text: String) -> Bool {
        guard let value = Int(text), (1024...65535).contains(value) else {
            portError = "端口必须是 1024–65535 之间的整数。"
            return false
        }
        UserDefaults.standard.set(value, forKey: "lightisle.localPort")
        portError = nil
        return true
    }

    private var core: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var readBuffer = ""
    private var stopping = false

    var hasChildProcess: Bool { core != nil }
    var isRemoteEnabled: Bool { remoteAddress != nil }

    func saveAdministratorWithTouchID(username: String, password: String) {
        guard state == .online, isConfigured == true, !verifyingAdmin else { return }
        guard AdminCredentialVault.available() else {
            vaultMessage = "此 Mac 尚未启用 Touch ID，请先在系统设置中录入指纹。"
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            vaultMessage = "请先输入已有管理员账号和正确密码。"
            return
        }
        let credentials = AdminCredentials(username: username, password: password)
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        pendingAdminCredentials = credentials
        verifyingAdmin = true
        vaultMessage = nil
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data(("admin verify " + payload + "\n").utf8))
    }

    func unlockAdministratorWithTouchID() {
        vaultMessage = nil
        unlockedAdminCredentials = nil
        Task {
            do {
                let result = try await Task.detached { try AdminCredentialVault.unlock() }.value
                unlockedAdminCredentials = result
                vaultMessage = "Touch ID 已解锁，凭据将在 30 秒后自动隐藏。"
                try? await Task.sleep(for: .seconds(30))
                unlockedAdminCredentials = nil
            } catch {
                vaultMessage = error.localizedDescription
            }
        }
    }

    func removeSavedAdministrator() {
        AdminCredentialVault.remove()
        pendingAdminCredentials = nil
        unlockedAdminCredentials = nil
        vaultMessage = "已删除本机钥匙串记录，不影响管理员账号。"
    }

    func resetAdministratorPassword(newPassword: String) {
        guard state == .online, isConfigured == true, !resettingAdmin else { return }
        guard newPassword.utf8.count >= 12, newPassword.utf8.count <= 256,
              newPassword.trimmingCharacters(in: .whitespacesAndNewlines) == newPassword else {
            resetAdminMessage = "新密码至少 12 位、最多 256 字节，且不能以空格开头或结尾。"
            return
        }
        resettingAdmin = true
        resetAdminMessage = nil
        Task {
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                resetAdminMessage = "macOS 无法执行设备所有者验证，请检查系统登录密码或 Touch ID 设置。"
                resettingAdmin = false
                return
            }
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 登录密码或 Touch ID，以重置轻屿管理员密码"
                )
                guard approved, state == .online, let pipe = inputPipe else {
                    resettingAdmin = false
                    resetAdminMessage = "认证已取消或本地服务不可用。"
                    return
                }
                let payload = try JSONSerialization.data(withJSONObject: ["password": newPassword])
                let encoded = payload.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                try pipe.fileHandleForWriting.write(contentsOf: Data(("admin reset " + encoded + "\n").utf8))
            } catch {
                resettingAdmin = false
                resetAdminMessage = "设备验证取消或失败，管理员密码未更改。"
            }
        }
    }

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

    func cancelBackup() {
        guard state == .online, backupStatus?.running == true else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup cancel\n".utf8))
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
        guard let target = endpoint, state == .online else {
            webOpenError = "Go 服务尚未准备好，请检查 LightIsle 状态。"
            return
        }
        webOpenError = nil
        Task {
            do {
                var request = URLRequest(url: target)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 5
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      String(decoding: data.prefix(4096), as: UTF8.self).contains("LightIsle"),
                      endpoint == target else {
                    webOpenError = "未找到 Web 首页资源，请检查安装包或重启应用。"
                    return
                }
                NSWorkspace.shared.open(target)
            } catch {
                webOpenError = "本机 Web 服务暂不可用，请确认端口未被占用。"
            }
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

    /// A cross-volume transfer is only requested from the native owner UI.
    /// Neither the selected source nor target is exposed to the Web API.
    func exportToAnotherDisk() {
        guard state == .online, !exportRunning, let base = sharedFolderPath else { return }
        let share = URL(fileURLWithPath: base, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()

        let sourcePanel = NSOpenPanel()
        sourcePanel.directoryURL = share
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = true
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.canCreateDirectories = false
        sourcePanel.prompt = "选择复制来源"
        sourcePanel.message = "选择共享目录内的文件或文件夹；源文件不会移动或删除。"
        guard sourcePanel.runModal() == .OK, let sourceURL = sourcePanel.url else { return }
        let selected = sourceURL.standardizedFileURL.path
        let prefix = share.path + "/"
        guard selected.hasPrefix(prefix) else {
            exportMessage = "只能复制当前共享目录里的文件或子文件夹。"
            return
        }
        let relative = String(selected.dropFirst(prefix.count))

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseDirectories = true
        destinationPanel.canChooseFiles = false
        destinationPanel.allowsMultipleSelection = false
        destinationPanel.canCreateDirectories = true
        destinationPanel.prompt = "复制到此目录"
        destinationPanel.message = "先复制并校验 SHA-256，再原子发布。目标同名文件不会被覆盖，不能选择共享目录内部。"
        guard destinationPanel.runModal() == .OK, let destination = destinationPanel.url else { return }

        struct ExportRequest: Encodable {
            let source: String
            let destination: String
        }
        guard let data = try? JSONEncoder().encode(ExportRequest(source: relative, destination: destination.path)) else {
            exportMessage = "无法创建复制请求。"
            return
        }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        exportRunning = true
        exportMessage = "正在复制并验证内容。源文件保持不变。"
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: Data(("export start " + encoded + "\n").utf8))
        } catch {
            exportRunning = false
            exportMessage = "无法发送复制任务：\(error.localizedDescription)"
        }
    }

    func cancelExport() {
        guard exportRunning, state == .online else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("export cancel\n".utf8))
        exportMessage = "正在请求取消跨磁盘复制，清理尚未发布的临时副本…"
    }

    private func decodeExportResult(_ raw: String) -> String? {
        guard raw.count <= 8192 else { return nil }
        var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private init() {}

    private func decodeAdminUsername(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let username = String(data: data, encoding: .utf8),
              !username.isEmpty, username.utf8.count <= 32 else { return nil }
        return username
    }

    func launch() {
        guard core == nil, !stopping else { return }
        directoryWatcher?.stop()
        directoryWatcher = nil
        sharedFolderPath = nil
        if exportRunning {
            exportMessage = "Go Core 已停止，跨磁盘复制已中断；原文件不会自动删除，请检查目标磁盘有无未发布的临时副本。"
        }
        exportRunning = false
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
        process.arguments = ["-port", String(preferredLocalPort), "-web-root", web?.path ?? ""]
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
            sharedFolderPath = nil
            exportRunning = false
            exportMessage = nil
            isConfigured = nil
            metrics = nil
            volumeHealth = [:]
            volumeHealthRefreshAt = .distantPast
            lastHealthMounts = []
            metricHistory = []
            initializing = false
            initializationError = nil
            backupStatus = nil
            backupError = nil
            smbListening = nil
            backupSchedule = nil
            firstAdminUsername = nil
            state = .starting
            details = "等待本机 Go Core 提供健康检查服务。"
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            state = .error("启动 Go Core 失败：\(error.localizedDescription)")
            details = "检查应用签名、端口是否被占用及内置的 Go Core。"
        }
    }

    private func consume(_ text: String) {
        readBuffer += text
        while let range = readBuffer.range(of: "\n") {
            let line = String(readBuffer[..<range.lowerBound])
            readBuffer.removeSubrange(..<range.upperBound)
            if line.hasPrefix("LIGHTISLE_ADMIN_ACCOUNT ") {
                let raw = String(line.dropFirst("LIGHTISLE_ADMIN_ACCOUNT ".count))
                if let username = decodeAdminUsername(raw) { firstAdminUsername = username }
                continue
            }
            if line == "LIGHTISLE_EXPORT_STARTED" {
                exportRunning = true
                exportMessage = "跨磁盘复制正在执行，校验完成后才会显示目标文件。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_OK ") {
                exportRunning = false
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_OK ".count))
                exportMessage = decodeExportResult(raw).map { "复制并校验完成：\($0)" } ?? "复制成功。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_ERROR ") {
                exportRunning = false
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_ERROR ".count))
                let reason = decodeExportResult(raw) ?? "unknown_error"
                exportMessage = reason == "context canceled" ? "复制已取消，源文件保持不变。" : "跨磁盘复制未完成：\(reason)"
                continue
            }
            if line == "LIGHTISLE_ADMIN_VERIFIED" {
                verifyingAdmin = false
                if let credentials = pendingAdminCredentials {
                    do {
                        try AdminCredentialVault.save(credentials)
                        vaultMessage = "管理员身份验证成功，凭据已保存到 Touch ID 保护的钥匙串。"
                    } catch {
                        vaultMessage = error.localizedDescription
                    }
                }
                pendingAdminCredentials = nil
                continue
            }
            if line == "LIGHTISLE_BACKUP_CANCEL_REQUESTED" {
                backupError = "已请求取消任务，正在清理未完成的临时文件。"
                continue
            }
            if line == "LIGHTISLE_ADMIN_VERIFY_FAILED" {
                verifyingAdmin = false
                pendingAdminCredentials = nil
                vaultMessage = "当前轻屿管理员用户名或密码不正确。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_RESET_OK ") {
                resettingAdmin = false
                AdminCredentialVault.remove()
                unlockedAdminCredentials = nil
                pendingAdminCredentials = nil
                let raw = String(line.dropFirst("LIGHTISLE_ADMIN_RESET_OK ".count))
                if let username = decodeAdminUsername(raw) {
                    firstAdminUsername = username
                    resetAdminMessage = "已重置管理员「\(username)」的密码。请使用该用户名和新密码登录当前 Web，旧登录会话已失效。"
                } else {
                    resetAdminMessage = "密码已更新，但未能读取账号名称。请确认当前 Web 地址并重新登录。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_RESET_ERROR ") {
                resettingAdmin = false
                let code = String(line.dropFirst("LIGHTISLE_ADMIN_RESET_ERROR ".count))
                resetAdminMessage = code == "invalid_password" ? "新密码不符合长度或格式要求。" :
                    code == "admin_missing" ? "未找到可用的首任管理员。" : "修改管理员密码失败，请检查 Go 服务日志。"
                continue
            }
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
                    refreshVolumeHealthIfNeeded(reading.volumes ?? [])
                    let point = MetricHistoryPoint(
                        time: Date(), cpu: reading.cpuPercent ?? 0,
                        memory: Double(reading.memoryUsed) / Double(max(reading.memoryTotal, 1)) * 100,
                        download: reading.networkDownBps ?? 0,
                        upload: reading.networkUpBps ?? 0
                    )
                    metricHistory.append(point)
                    if metricHistory.count > 120 { metricHistory.removeFirst(metricHistory.count - 120) }
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
            if line.hasPrefix("LIGHTISLE_SHARE_PATH ") {
                let raw = String(line.dropFirst("LIGHTISLE_SHARE_PATH ".count))
                var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let data = Data(base64Encoded: encoded), let path = String(data: data, encoding: .utf8), path.hasPrefix("/") {
                    sharedFolderPath = path
                    directoryWatcher?.stop()
                    directoryWatcher = DirectoryChangeWatcher(path: path) { [weak self] in
                        self?.scheduleIndexRefresh()
                    }
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ERROR ") {
                sharedFolderError = String(line.dropFirst("LIGHTISLE_SHARE_ERROR ".count))
                sharedFolderPath = nil
                directoryWatcher?.stop()
                directoryWatcher = nil
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
        directoryWatcher?.stop()
        directoryWatcher = nil
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
        directoryWatcher?.stop()
        directoryWatcher = nil
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

