import Foundation

struct NativeSMBStatus: Decodable, Equatable {
    let serviceEnabled: Bool
    let listening: Bool
    let remoteManageReady: Bool
    let computerName: String
    let localHostName: String
    let bonjourUrl: String?
    let lanUrl: String?
    let shares: [NativeSMBSharePoint]
    let candidateRoots: [NativeSMBCandidateRoot]
}

struct NativeSMBSharePoint: Decodable, Equatable, Identifiable {
    let recordName: String
    let smbName: String
    let path: String
    let shared: Bool
    let guestAccess: Bool
    let readOnly: Bool
    let sealed: Bool
    let rootId: String?
    let rootName: String?
    let exposesPersonalDirs: Bool
    let pathExists: Bool

    var id: String { recordName }
}

struct NativeSMBCandidateRoot: Decodable, Equatable, Identifiable {
    let rootId: String
    let name: String
    let path: String
    let online: Bool
    let subdirectories: [String]

    var id: String { rootId }
}

enum SmbElevation {
    static let sudoersPath = "/etc/sudoers.d/lightisle-smb"
    static let smbdPlistPath = "/System/Library/LaunchDaemons/com.apple.smbd.plist"

    enum ElevationError: LocalizedError, Equatable {
        case invalidUsername
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidUsername:
                return "当前 Mac 用户名包含不支持的字符，无法自动生成 sudoers 规则。"
            case .cancelled:
                return nil
            case .failed(let reason):
                return "系统文件共享授权操作失败：\(reason)"
            }
        }
    }

    static func isValidUsername(_ username: String) -> Bool {
        guard !username.isEmpty, username.count <= 64 else { return false }
        return username.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == ".")
        }
    }

    static func sudoersRule(for username: String) throws -> String {
        guard isValidUsername(username) else {
            throw ElevationError.invalidUsername
        }
        return """
        # LightIsle macOS File Sharing (SMB) management
        \(username) ALL=(root) NOPASSWD: /usr/sbin/sharing *, /bin/launchctl load -w \(smbdPlistPath), /bin/launchctl unload -w \(smbdPlistPath)
        """
    }

    static func decodeStatus(base64URL encoded: String) -> NativeSMBStatus? {
        var padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return try? JSONDecoder().decode(NativeSMBStatus.self, from: data)
    }

    static func userFacingError(for code: String) -> String {
        switch code {
        case "invalid_smb_request":
            return "共享名称或目录参数无效（不能包含 /、\\、: 等特殊字符）。"
        case "smb_share_not_found":
            return "未找到该共享目录，请刷新列表后重试。"
        case "smb_share_already_exists":
            return "该目录或同名共享点已存在，请勿重复添加。"
        case "smb_elevation_required":
            return "尚未开启三端免密管理授权。请先在本页点击「开启免密管理授权」并验证一次 Mac 密码。"
        case "smb_protected_path_rejected":
            return "安全保护已拦截：不允许共享 .lightisle-* 内部元数据目录、符号链接或系统根目录。"
        case "smb_root_offline":
            return "所选 NAS 存储盘当前处于离线状态，请先检查硬盘连接。"
        default:
            return "macOS 文件共享操作未完成（\(code)），请检查系统共享设置或权限。"
        }
    }

    static func installSudoers(username: String = NSUserName()) throws {
        let rule = try sudoersRule(for: username) + "\n"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightisle-smb-\(UUID().uuidString).sudoers")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try Data(rule.utf8).write(to: tempURL, options: .atomic)
        } catch {
            throw ElevationError.failed(error.localizedDescription)
        }
        let quotedTemp = shellSingleQuoted(tempURL.path)
        let quotedTarget = shellSingleQuoted(sudoersPath)
        let shellCmd = "/usr/sbin/visudo -cf \(quotedTemp) && /usr/bin/install -o root -g wheel -m 0440 \(quotedTemp) \(quotedTarget)"
        try runAdminShellScript(shellCmd)
    }

    static func revokeSudoers() throws {
        let quotedTarget = shellSingleQuoted(sudoersPath)
        try runAdminShellScript("/bin/rm -f \(quotedTarget)")
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func runAdminShellScript(_ shellCommand: String) throws {
        let script = "do shell script \(appleScriptQuoted(shellCommand)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ElevationError.failed(error.localizedDescription)
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return
        }
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errData, encoding: .utf8) ?? ""
        if message.contains("User canceled") || message.contains("user canceled") ||
            message.contains("(-128)") || message.contains("(-6002)") {
            throw ElevationError.cancelled
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        throw ElevationError.failed(trimmed.isEmpty ? "退出码 \(process.terminationStatus)" : String(trimmed.prefix(200)))
    }
}
