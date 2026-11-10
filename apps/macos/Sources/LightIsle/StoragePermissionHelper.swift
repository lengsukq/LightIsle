import AppKit
import Foundation

@MainActor
enum StoragePermissionHelper {
    /// Generates the exact terminal command a user can run to grant directory ownership and read/write permissions.
    static func manualRepairCommand(forPath targetPath: String) -> String {
        let cleanPath = URL(fileURLWithPath: targetPath, isDirectory: true).resolvingSymlinksInPath().path
        let quoted = SmbElevation.shellSingleQuoted(cleanPath)
        return "sudo mkdir -p \(quoted) && sudo chown -R $(id -u):$(id -g) \(quoted) && sudo chmod -R u+rwX \(quoted)"
    }

    /// Ensures a directory exists and is writable by the current macOS user.
    /// If macOS TCC or POSIX directory permissions block access, proactively prompts
    /// the user to grant folder access, repair via admin privileges, or run the terminal command manually.
    static func ensureDirectoryWritable(
        _ url: URL,
        reason: String = "轻屿需要该存储目录的读写权限以创建空间或迁移数据。"
    ) -> (ok: Bool, errorMessage: String?) {
        let canonical = url.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
            if FileManager.default.isWritableFile(atPath: canonical.path) {
                return (true, nil)
            }
        } catch {
            // Fall through to interactive permission acquisition.
        }
        return requestReadWriteAccess(forPath: canonical.path, reason: reason)
    }

    /// Interactive multi-tier permission flow:
    /// 1) Opens NSOpenPanel at the folder/volume so macOS TCC grants removable volume / folder access.
    /// 2) If POSIX permissions still forbid writing, offers macOS administrator privilege repair,
    ///    manual Terminal command execution with "Continue after running", or System Settings.
    static func requestReadWriteAccess(
        forPath targetPath: String,
        reason: String = "轻屿需要该存储目录的读写权限以完成空间分配或数据迁移。"
    ) -> (ok: Bool, errorMessage: String?) {
        let cleanPath = URL(fileURLWithPath: targetPath, isDirectory: true).resolvingSymlinksInPath().path
        if cleanPath.isEmpty || cleanPath == "/" || cleanPath == "/Volumes" {
            return (false, "请选择具体硬盘或专用文件夹，不能直接授权系统根目录。")
        }

        let existingDir = closestExistingDirectory(forPath: cleanPath)
        let panel = NSOpenPanel()
        panel.title = "申请存储目录读写权限"
        panel.prompt = "授权读写此目录"
        panel.message = "\(reason)\n请确认选择「\(existingDir.path)」以授予 macOS 文件夹访问权限。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = existingDir

        if panel.runModal() == .OK, let grantedURL = panel.url {
            _ = grantedURL.startAccessingSecurityScopedResource()
            defer { grantedURL.stopAccessingSecurityScopedResource() }
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: cleanPath, isDirectory: true),
                withIntermediateDirectories: true
            )
            if FileManager.default.isWritableFile(atPath: cleanPath) {
                return (true, nil)
            }
        }

        let command = manualRepairCommand(forPath: cleanPath)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "该存储目录仍无写入权限，请选择修复方式"
        alert.informativeText = """
        目标目录：\(cleanPath)
        原因：\(reason)

        原有文件未受影响。你可以：
        1. 点击「使用管理员权限自动修复」由系统弹窗直接授权；
        2. 点击「复制终端命令手动执行…」在终端运行下方命令后继续下一步：
        \(command)
        """
        alert.addButton(withTitle: "使用管理员权限自动修复")
        alert.addButton(withTitle: "复制终端命令手动执行…")
        alert.addButton(withTitle: "打开系统「隐私与安全性」设置")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try runAdminPermissionRepair(forPath: cleanPath)
                if FileManager.default.isWritableFile(atPath: cleanPath) {
                    return (true, nil)
                }
                return presentManualCommandGuide(
                    forPath: cleanPath,
                    reason: reason,
                    failureDetail: "自动修复已执行，但该目录仍不可写。请在终端执行下方命令并查看终端报错（或确认磁盘未以 NTFS 只读挂载）。"
                )
            } catch {
                return presentManualCommandGuide(
                    forPath: cleanPath,
                    reason: reason,
                    failureDetail: "自动提权未完成（\(error.localizedDescription)）。你可以直接在终端运行下方命令，执行成功后点击「我已执行完成，立即继续」。"
                )
            }
        } else if response == .alertSecondButtonReturn {
            return presentManualCommandGuide(forPath: cleanPath, reason: reason, failureDetail: nil)
        } else if response == .alertThirdButtonReturn {
            openSystemPrivacySettings()
            return (false, "已打开系统「隐私与安全性」设置。授予权限后可重试，或在终端执行：\(command)")
        }

        return (false, "未授予目录读写权限（可在终端执行：\(command)），原有数据未受影响。")
    }

    /// Fallback manual command guide: copies the command / opens Terminal, and lets the user click
    /// "我已执行完成，立即继续" once they run it so the workflow proceeds immediately.
    static func presentManualCommandGuide(
        forPath targetPath: String,
        reason: String,
        failureDetail: String?
    ) -> (ok: Bool, errorMessage: String?) {
        let cleanPath = URL(fileURLWithPath: targetPath, isDirectory: true).resolvingSymlinksInPath().path
        let command = manualRepairCommand(forPath: cleanPath)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "在终端执行权限修复命令（已复制到剪贴板）"
            var info = ""
            if let failureDetail, !failureDetail.isEmpty {
                info += "\(failureDetail)\n\n"
            }
            info += """
            请在 macOS「终端 (Terminal)」中粘贴并执行以下命令：

            \(command)

            执行成功后，点击「我已执行完成，立即继续」即可直接完成后续操作。
            """
            alert.informativeText = info
            let cmdField = NSTextField(string: command)
            cmdField.isEditable = false
            cmdField.isSelectable = true
            cmdField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            cmdField.frame = NSRect(x: 0, y: 0, width: 460, height: 44)
            alert.accessoryView = cmdField

            alert.addButton(withTitle: "我已执行完成，立即继续")
            alert.addButton(withTitle: "复制命令并打开终端")
            alert.addButton(withTitle: "取消")

            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: cleanPath, isDirectory: true),
                    withIntermediateDirectories: true
                )
                if FileManager.default.isWritableFile(atPath: cleanPath) {
                    return (true, nil)
                }
                let recheck = NSAlert()
                recheck.alertStyle = .warning
                recheck.messageText = "检测到目录仍无写入权限"
                recheck.informativeText = """
                目标目录：\(cleanPath)

                系统检测该目录当前仍不可写。请确认终端命令已执行成功，且系统「设置 → 隐私与安全性 → 文件和文件夹 / 完全磁盘访问权限」未拦截轻屿。
                若确认已在终端处理完毕，也可点击「强制继续尝试」直接交给后台服务执行。
                """
                recheck.addButton(withTitle: "返回重新复制/执行命令")
                recheck.addButton(withTitle: "强制继续尝试")
                recheck.addButton(withTitle: "取消")
                let subChoice = recheck.runModal()
                if subChoice == .alertFirstButtonReturn {
                    continue
                } else if subChoice == .alertSecondButtonReturn {
                    return (true, nil)
                } else {
                    return (false, "目录仍无写入权限（可在终端执行：\(command)），原有文件未受影响。")
                }
            } else if choice == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                continue
            } else {
                return (false, "已取消权限修复（如需手动处理，可在终端执行：\(command)）。")
            }
        }
    }

    static func openSystemPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static func closestExistingDirectory(forPath path: String) -> URL {
        var current = URL(fileURLWithPath: path, isDirectory: true)
        while !FileManager.default.fileExists(atPath: current.path) && current.path != "/" {
            current.deleteLastPathComponent()
        }
        return current
    }

    private static func runAdminPermissionRepair(forPath path: String) throws {
        let uid = getuid()
        let gid = getgid()
        let quotedPath = SmbElevation.shellSingleQuoted(path)
        let quotedUsers = SmbElevation.shellSingleQuoted(
            URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Users", isDirectory: true).path
        )
        let cmd = "/bin/mkdir -p \(quotedPath) && /usr/sbin/chown \(uid):\(gid) \(quotedPath) && /bin/chmod u+rwx \(quotedPath) && if [ -d \(quotedUsers) ]; then /usr/sbin/chown -R \(uid):\(gid) \(quotedUsers) && /bin/chmod -R u+rwX \(quotedUsers); fi"
        let script = "do shell script \(SmbElevation.appleScriptQuoted(cmd)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return
        }
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errData, encoding: .utf8) ?? ""
        if message.contains("User canceled") || message.contains("user canceled") ||
            message.contains("(-128)") || message.contains("(-6002)") {
            throw SmbElevation.ElevationError.cancelled
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SmbElevation.ElevationError.failed(trimmed.isEmpty ? "退出码 \(process.terminationStatus)" : String(trimmed.prefix(200)))
    }
}
