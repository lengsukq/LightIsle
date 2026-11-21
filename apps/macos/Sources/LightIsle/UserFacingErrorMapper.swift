import Foundation
import Security

/// Translates raw backend codes, Keychain OSStatus codes, and Cocoa/POSIX errors
/// into honest, family-friendly Chinese messages following AGENTS.md #2:
/// (1) what went wrong, (2) whether user data is safe, (3) what to do next.
enum UserFacingErrorMapper {
    static func keychainErrorDescription(for status: OSStatus) -> String {
        switch status {
        case errSecAuthFailed, errSecUserCanceled:
            return "你取消或拒绝了钥匙串授权，现有数据与凭据未受影响。如需保存或清除，请重试并在弹窗中允许访问。"
        case errSecInteractionNotAllowed:
            return "macOS 钥匙串当前处于锁定状态，现有数据未受影响。请解锁本机或打开「钥匙串访问」解锁登录钥匙串后重试。"
        case errSecItemNotFound:
            return "钥匙串中未找到对应凭据，不影响你的文件与服务数据。如需使用请重新填写并保存。"
        case errSecDuplicateItem:
            return "钥匙串中已存在同名凭据记录，未覆盖原有数据。请稍后重试或先移除旧凭据后再保存。"
        default:
            return "无法访问 macOS 登录钥匙串，原有文件与配置未受影响。请确认当前登录钥匙串已解锁后重试。"
        }
    }

    static func coreIPCCommandError(action: String, dataSafeNote: String = "现有数据未受影响") -> String {
        "\(action)未能发送到本地服务，\(dataSafeNote)。请确认轻屿核心服务处于运行状态后重试。"
    }

    static func diskError(from raw: String) -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code.contains("busy") || code.contains("in_use") {
            return "硬盘当前正有文件读写、备份或任务在进行，原硬盘数据未受影响。请等待当前操作结束后再重试。"
        }
        if code.contains("not_found") || code.contains("offline") || code.contains("missing") {
            return "未检测到该外置硬盘，原硬盘数据未被修改。请检查数据线和电源连接后点击刷新。"
        }
        if code.contains("permission") || code.contains("denied") {
            return "系统缺少访问该硬盘的权限，原有文件未受影响。请先完成磁盘读写授权后再重试。"
        }
        if code.contains("invalid") || code.contains("name") {
            return "磁盘名称或操作参数不符合要求，原有数据未受影响。请检查输入后重试。"
        }
        return "磁盘操作未能完成，原有文件未受影响。请检查硬盘连接状态，刷新磁盘列表后再试。"
    }

    static func backupError(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("busy") || lower.contains("running") || lower.contains("in_progress") {
            return "当前已有备份或恢复任务正在进行，现有数据未受影响。请等待当前任务结束或先取消后再试。"
        }
        if lower.contains("no space") || lower.contains("enospc") || lower.contains("space") {
            return "目标备份目录可用空间不足，当前 NAS 数据未受影响。请清理目标磁盘空间或更换其他硬盘后重试。"
        }
        if lower.contains("permission") || lower.contains("denied") || lower.contains("read-only") || lower.contains("erofs") {
            return "无法写入所选备份目录，原有数据未受影响。请确认目标硬盘可写并授予读写权限后重试。"
        }
        if lower.contains("invalid") || lower.contains("corrupt") || lower.contains("checksum") || lower.contains("manifest") || lower.contains("legacy") {
            return "所选目录不是有效的家庭版配置快照（或快照文件不完整），当前数据库与文件均未修改。请选择完整的配置快照目录重试。"
        }
        if lower.contains("not found") || lower.contains("no such file") || lower.contains("missing") {
            return "未找到目标备份目录或快照文件，现有数据未受影响。请检查备份硬盘是否已连接并重新选择目录。"
        }
        if lower.contains("cancel") {
            return "备份任务已取消，原有配置与文件均未受影响。"
        }
        // If backend already returned a clear Chinese sentence without raw internal error codes, keep it with reassurance.
        if trimmed.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) && !trimmed.contains("exit status") {
            return trimmed
        }
        return "备份或恢复未能完成，原有配置与文件均未受影响。请检查备份硬盘连接和目录权限后重试。"
    }

    static func dockerOperationError(action: String, error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
           localized.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            return "\(action)未完成：\(localized)"
        }
        let raw = error.localizedDescription.lowercased()
        if raw.contains("cannot connect") || raw.contains("daemon") || raw.contains("socket") || raw.contains("not running") {
            return "\(action)未完成，本地容器数据未受影响。请先启动 Docker Desktop 或 Colima 引擎后再刷新重试。"
        }
        if raw.contains("timeout") || raw.contains("timed out") {
            return "\(action)超时，原有容器与文件未受影响。请检查网络连接或镜像源设置后重试。"
        }
        if raw.contains("permission") || raw.contains("denied") {
            return "\(action)缺少本机访问权限，现有数据未受影响。请检查 Docker 引擎状态与目录权限后重试。"
        }
        if raw.contains("not found") || raw.contains("no such") {
            return "\(action)未找到目标容器、镜像或配置文件，原有数据未受影响。请刷新列表后重新确认。"
        }
        return "\(action)未能完成，原有容器与 NAS 文件未受影响。请确认本地 Docker 引擎运行正常后重试。"
    }

    static func directoryOpenError(label: String) -> String {
        "无法创建或打开「\(label)」目录，现有数据未受影响。请检查磁盘空间与文件夹写入权限后重试。"
    }
}
