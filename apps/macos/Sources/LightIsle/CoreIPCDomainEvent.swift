import Foundation

/// Strongly-typed, side-effect-free wire protocol decoder for Core stdout lines
/// not already handled by `CoreIPCSettingsEvent`, `CoreIPCReportEvent`, or
/// `CoreLifecycleSignal`. Centralizes string-prefix parsing and user-facing
/// error translations outside `AppModel`.
enum CoreIPCDomainEvent: Equatable {
    enum SubsystemChannel: Equatable {
        case roots(String)
        case spaces(String)
        case apps(String)
        case mediaImport(String)
    }

    enum ComputerFilesSignal: Equatable {
        case state(Bool)
        case error
    }

    enum AdminSignal: Equatable {
        case account(String)
        case verified
        case verifyFailed
        case resetSucceeded(String)
        case resetFailed(String)
    }

    enum TunnelSignal: Equatable {
        case api(String)
        case error(String)
    }

    enum NotifySignal: Equatable {
        case enabled
        case disabled
        case tested
        case testError(String)
        case configError(String)
    }

    enum BackupSignal: Equatable {
        case cancelRequested
        case scheduleChanged
        case started
        case error(String)
    }

    enum SMBSignal: Equatable {
        case listening(Bool)
        case state(String)
        case error(String)
    }

    enum SetupSignal: Equatable {
        case configured(Bool)
        case initialized
        case initError(String)
    }

    enum LegacyShareSignal: Equatable {
        case enabled(String)
        case path(String)
        case statusOnline(Bool)
        case offlinePath(String)
        case error(String)
    }

    case subsystem(SubsystemChannel)
    case computerFiles(ComputerFilesSignal)
    case admin(AdminSignal)
    case disksError(String)
    case alertsThresholdError(String)
    case tunnel(TunnelSignal)
    case notify(NotifySignal)
    case backup(BackupSignal)
    case smb(SMBSignal)
    case setup(SetupSignal)
    case remoteOn(address: String, fingerprint: String?)
    case legacyShare(LegacyShareSignal)

    private static func payload(in line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    static func decode(_ line: String) -> Self? {
        if let sub = decodeSubsystemOrComputerFiles(line) { return sub }
        if let admin = decodeAdminOrDiskErrors(line) { return admin }
        if let net = decodeTunnelNotifyBackupSMB(line) { return net }
        if let share = decodeSetupRemoteOrShare(line) { return share }
        return nil
    }

    private static func decodeSubsystemOrComputerFiles(_ line: String) -> Self? {
        if line == "LIGHTISLE_COMPUTER_FILES 1" { return .computerFiles(.state(true)) }
        if line == "LIGHTISLE_COMPUTER_FILES 0" { return .computerFiles(.state(false)) }
        if line == "LIGHTISLE_COMPUTER_FILES_ERROR" { return .computerFiles(.error) }
        if let raw = payload(in: line, after: "LIGHTISLE_ROOTS ") { return .subsystem(.roots(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SPACES ") { return .subsystem(.spaces(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_APPS ") { return .subsystem(.apps(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_MEDIA_IMPORT ") { return .subsystem(.mediaImport(raw)) }
        return nil
    }

    private static func decodeAdminOrDiskErrors(_ line: String) -> Self? {
        if let raw = payload(in: line, after: "LIGHTISLE_ADMIN_ACCOUNT ") { return .admin(.account(raw)) }
        if line == "LIGHTISLE_ADMIN_VERIFIED" { return .admin(.verified) }
        if line == "LIGHTISLE_ADMIN_VERIFY_FAILED" { return .admin(.verifyFailed) }
        if let raw = payload(in: line, after: "LIGHTISLE_ADMIN_RESET_OK ") { return .admin(.resetSucceeded(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_ADMIN_RESET_ERROR ") { return .admin(.resetFailed(raw)) }

        if let raw = payload(in: line, after: "LIGHTISLE_DISKS_ERROR ") { return .disksError(raw) }
        if let raw = payload(in: line, after: "LIGHTISLE_ALERTS_THRESHOLD_ERROR ") { return .alertsThresholdError(raw) }
        return nil
    }

    private static func decodeTunnelNotifyBackupSMB(_ line: String) -> Self? {
        if let raw = payload(in: line, after: "LIGHTISLE_TUNNEL_API ") { return .tunnel(.api(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_TUNNEL_ERROR ") { return .tunnel(.error(raw)) }

        if line == "LIGHTISLE_NOTIFY_ON" { return .notify(.enabled) }
        if line == "LIGHTISLE_NOTIFY_OFF" { return .notify(.disabled) }
        if line == "LIGHTISLE_NOTIFY_TESTED" { return .notify(.tested) }
        if let raw = payload(in: line, after: "LIGHTISLE_NOTIFY_TEST_ERROR ") { return .notify(.testError(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_NOTIFY_ERROR ") { return .notify(.configError(raw)) }

        if line == "LIGHTISLE_BACKUP_CANCEL_REQUESTED" { return .backup(.cancelRequested) }
        if line == "LIGHTISLE_BACKUP_SCHEDULE_CHANGED" { return .backup(.scheduleChanged) }
        if line == "LIGHTISLE_BACKUP_STARTED" { return .backup(.started) }
        if let raw = payload(in: line, after: "LIGHTISLE_BACKUP_ERROR ") { return .backup(.error(raw)) }

        if line == "LIGHTISLE_SMB_STATUS 1" { return .smb(.listening(true)) }
        if line == "LIGHTISLE_SMB_STATUS 0" { return .smb(.listening(false)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SMB_STATE ") { return .smb(.state(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SMB_ERROR ") { return .smb(.error(raw)) }
        return nil
    }

    private static func decodeSetupRemoteOrShare(_ line: String) -> Self? {
        if line == "LIGHTISLE_CONFIGURED 1" { return .setup(.configured(true)) }
        if line == "LIGHTISLE_CONFIGURED 0" { return .setup(.configured(false)) }
        if line == "LIGHTISLE_INITIALIZED" { return .setup(.initialized) }
        if let raw = payload(in: line, after: "LIGHTISLE_INIT_ERROR ") { return .setup(.initError(raw)) }

        if line.hasPrefix("LIGHTISLE_REMOTE_ON ") {
            let words = line.split(separator: " ")
            if words.count == 3 {
                let fp = words[2] == "-" ? nil : String(words[2])
                return .remoteOn(address: String(words[1]), fingerprint: fp)
            }
            return .remoteOn(address: "", fingerprint: nil)
        }

        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_ON ") { return .legacyShare(.enabled(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_PATH ") { return .legacyShare(.path(raw)) }
        if line == "LIGHTISLE_SHARE_STATUS 0" { return .legacyShare(.statusOnline(false)) }
        if line == "LIGHTISLE_SHARE_STATUS 1" { return .legacyShare(.statusOnline(true)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_OFFLINE_PATH ") { return .legacyShare(.offlinePath(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_ERROR ") { return .legacyShare(.error(raw)) }
        return nil
    }
}

/// Pure user-facing message builders for admin, init, and notify
/// IPC error codes, extracted from `AppModel+CoreOutputConsumer` for testability.
enum CoreIPCDomainMessages {
    static func adminResetError(for code: String) -> String {
        switch code {
        case "invalid_password":
            return "新密码不符合长度或格式要求，原管理员密码未更改。请输入至少 12 位有效密码后重试。"
        case "admin_missing":
            return "未找到可重置的首任管理员账号，现有数据未受影响。请先完成初始化或重新启动轻屿后重试。"
        default:
            return "管理员密码未能更新，原有账号与数据未受影响。请确认轻屿服务正在运行后重试。"
        }
    }

    static func notifyConfigError(for reason: String?) -> String {
        switch reason {
        case "invalid_notify_config":
            return "通知通道配置无效，原有设置未受影响。请确认 Bark 服务器为 http(s) 源（不带路径）、Webhook 为完整 http(s) 地址后重试。"
        case "notify_private_target_rejected":
            return "目标地址位于内网或本机回环，未保存新配置。若使用自建 Bark/Webhook，请先勾选“允许内网目标”后重试。"
        default:
            return "通知通道配置未能生效，现有数据未受影响。请检查渠道地址与凭据格式后重试。"
        }
    }

    static func initError(for code: String) -> (alreadyConfigured: Bool, message: String) {
        switch code {
        case "already_configured":
            return (true, "管理员账号已完成初始化，无需重复创建。请直接打开 Web 空间登录使用。")
        case "invalid_credentials":
            return (false, "用户名格式或密码长度不符合要求，未创建账号。请按提示调整后重试。")
        default:
            return (false, "管理员初始化未能完成，本机数据未受影响。请确认轻屿核心服务已就绪后重试，必要时可重启应用。")
        }
    }
}
