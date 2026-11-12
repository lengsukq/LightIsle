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
    }

    enum ComputerFilesSignal: Equatable {
        case state(Bool)
        case error
    }

    enum ExportSignal: Equatable {
        case started
        case history(String)
        case historyError(String)
        case succeeded(String)
        case failed(String)
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
        case accessRevoked(Bool?)
        case statusOnline(Bool)
        case offlinePath(String)
        case forgot(String)
        case forgetError(String)
        case forgetWarning(String)
        case error(String)
    }

    case subsystem(SubsystemChannel)
    case computerFiles(ComputerFilesSignal)
    case export(ExportSignal)
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
        if let exp = decodeExportOrAdmin(line) { return exp }
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
        return nil
    }

    private static func decodeExportOrAdmin(_ line: String) -> Self? {
        if line == "LIGHTISLE_EXPORT_STARTED" { return .export(.started) }
        if let raw = payload(in: line, after: "LIGHTISLE_EXPORT_HISTORY ") { return .export(.history(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_EXPORT_HISTORY_ERROR ") { return .export(.historyError(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_EXPORT_OK ") { return .export(.succeeded(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_EXPORT_ERROR ") { return .export(.failed(raw)) }

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
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_ACCESS_REVOKED ") {
            let revoked: Bool? = raw == "1" ? true : (raw == "0" ? false : nil)
            return .legacyShare(.accessRevoked(revoked))
        }
        if line == "LIGHTISLE_SHARE_STATUS 0" { return .legacyShare(.statusOnline(false)) }
        if line == "LIGHTISLE_SHARE_STATUS 1" { return .legacyShare(.statusOnline(true)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_OFFLINE_PATH ") { return .legacyShare(.offlinePath(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_FORGOT ") { return .legacyShare(.forgot(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_FORGET_ERROR ") { return .legacyShare(.forgetError(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_FORGET_WARNING ") { return .legacyShare(.forgetWarning(raw)) }
        if let raw = payload(in: line, after: "LIGHTISLE_SHARE_ERROR ") { return .legacyShare(.error(raw)) }
        return nil
    }
}

/// Pure user-facing message builders for legacy share, admin, init, and notify
/// IPC error codes, extracted from `AppModel+CoreOutputConsumer` for testability.
enum CoreIPCDomainMessages {
    static func adminResetError(for code: String) -> String {
        switch code {
        case "invalid_password":
            return "新密码不符合长度或格式要求。"
        case "admin_missing":
            return "未找到可用的首任管理员。"
        default:
            return "修改管理员密码失败，请检查 Go 服务日志。"
        }
    }

    static func notifyConfigError(for reason: String?) -> String {
        switch reason {
        case "invalid_notify_config":
            return "通知通道配置无效：Bark 服务器需为 http(s) 源（不带路径），Webhook 需为完整 http(s) 地址。"
        case "notify_private_target_rejected":
            return "目标地址位于内网/本机回环。自建 Bark/Webhook 需勾选“允许内网目标”。"
        default:
            return "通知通道配置失败：\(reason ?? "未知错误")"
        }
    }

    static func initError(for code: String) -> (alreadyConfigured: Bool, message: String) {
        switch code {
        case "already_configured":
            return (true, "管理员已经初始化，请登录 Web 使用。")
        case "invalid_credentials":
            return (false, "用户名格式或密码长度不符合要求。")
        default:
            return (false, "初始化失败，请检查 Go 服务日志。")
        }
    }

    static func storageSelectionTransitionMessage(
        newPath: String,
        previousRoot: String?,
        accessRevoked: Bool?
    ) -> String {
        if let old = previousRoot {
            switch accessRevoked {
            case true:
                return "已切换至 \(newPath)。旧目录 \(old) 内的文件仍保留；旧成员文件授权和公开分享链接已撤销，授权记录保存在本机，新目录仍需重新授权。用户、登录会话和 WebDAV 凭据保留。"
            case false:
                return "已重新连接同一物理目录：\(newPath)。目录授权保留，文件未搬迁。"
            case nil:
                return "已切换至 \(newPath)。旧目录文件未搬迁；授权状态未得到确认，请检查成员授权和分享链接后再使用。"
            }
        }
        switch accessRevoked {
        case true:
            return "已启用 NAS 存储目录：\(newPath)。旧成员文件授权和公开分享链接已撤销，授权记录保存在本机；新目录需重新授权。"
        case nil:
            return "已启用 NAS 存储目录：\(newPath)。授权状态未得到确认，请检查成员授权和分享链接后再使用。"
        case false:
            return "已启用 NAS 存储目录：\(newPath)"
        }
    }

    static func shareForgetErrorMessage(for error: String) -> String {
        if error.contains("legacy_share_access_revoked_root_config_uncertain") {
            return "旧成员文件授权和公开分享链接已撤销，但本机目录配置落盘结果不确定。请停止文件操作，完全退出并重启轻屿，核对当前共享目录后再继续。"
        }
        if error.contains("legacy_share_access_revoked_root_switch_failed") {
            return "旧成员文件授权和公开分享链接已撤销，但本机目录切换未能完成；旧离线绑定仍保留。请检查 Core 状态后再重试。"
        }
        if error.contains("legacy_share_access_revocation_uncertain") {
            return "旧授权撤销结果无法确认，目录切换未继续。请暂停共享并重启轻屿，检查成员授权和公开分享链接后再操作。"
        }
        if error.contains("shared_directory_transition_busy") {
            return "仍有旧目录请求或后台任务正在结束。原绑定保留，请稍后重试。"
        }
        if error.contains("shared_directory_save_uncertain_restart_required") {
            return "目录配置持久化结果不确定。请停止文件操作，完全退出后重启 LightIsle，并检查当前实际共享目录。"
        }
        return "清理失败或当前存在进行中任务：\(error)。原绑定仍保留。"
    }

    static func pendingStorageSelectionErrorMessage(for error: String) -> String {
        if error.contains("shared_directory_save_uncertain_restart_required") {
            return "存储目录配置落盘结果不确定。请停止文件操作，完全退出并重新启动轻屿，检查当前共享路径和磁盘身份后再继续。"
        }
        if error.contains("legacy_share_access_revoked_root_config_uncertain") {
            return "旧成员文件授权和公开分享链接已撤销，但新目录配置落盘结果不确定。请停止文件操作，完全退出并重启轻屿，核对当前共享目录后再继续授权。"
        }
        if error.contains("legacy_share_access_revoked_root_switch_failed") {
            return "旧成员文件授权和公开分享链接已撤销，但新目录未能切换。原目录文件仍保留，请检查 Core 和当前路径后再重新授权。"
        }
        if error.contains("legacy_share_access_revocation_uncertain") {
            return "旧授权撤销结果无法确认，切换未继续。请暂停文件共享并重启轻屿，检查成员授权和分享链接后再操作。"
        }
        if error.contains("shared_directory_transition_busy") {
            return "仍有旧目录请求或后台任务正在结束。请稍后重试切换。"
        }
        if error.contains("shared_directory_busy") {
            return "当前目录还有未完成上传。请先完成上传，或在 Web 管理设置中取消未完成上传后，再切换存储目录。"
        }
        if error.contains("root_registry_overlap") {
            return "所选目录与已登记的其他 NAS 存储根相同或重叠。请选一个独立文件夹，或通过多硬盘管理使用已登记的目录；原目录未切换。"
        }
        if error.contains("drive_operation_busy") {
            return "正在执行磁盘操作、文件传输、备份或媒体扫描。请等待任务结束后再切换存储目录。"
        }
        return "更改存储目录失败：\(error)。当前运行中的原目录未被切换。"
    }
}
