import AppKit
import Darwin
import Foundation

@MainActor
enum StoragePermissionHelper {
    enum AccessProbeResult: Equatable, Sendable {
        case writable
        case readOnlyVolume
        case tccOrSandboxBlocked(String)
        case posixPermissionDenied(String)

        var isWritable: Bool {
            if case .writable = self { return true }
            return false
        }

        var statusSummary: String {
            switch self {
            case .writable:
                return "整盘与目录读写正常"
            case .readOnlyVolume:
                return "只读文件系统（如 NTFS）"
            case .tccOrSandboxBlocked:
                return "缺少 macOS 可移除宗卷隐私权限"
            case .posixPermissionDenied:
                return "目录所有权或写入权限受限"
            }
        }

        var detailMessage: String? {
            switch self {
            case .writable:
                return nil
            case .readOnlyVolume:
                return "该硬盘以只读模式挂载（常见于 Windows NTFS 格式），macOS 无法写入，请使用 APFS 或 ExFAT 格式。"
            case .tccOrSandboxBlocked(let detail):
                return detail
            case .posixPermissionDenied(let detail):
                return detail
            }
        }
    }

    private enum RepairError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return nil
            case .failed(let reason):
                return "目录权限自动修复未完成：\(reason)"
            }
        }
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

    /// Extracts `/Volumes/<VolumeName>` if the path resides on an external mounted volume.
    nonisolated static func externalVolumeMountPath(forPath path: String) -> String? {
        let clean = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
        let components = URL(fileURLWithPath: clean, isDirectory: true).pathComponents
        guard components.count >= 3, components[1] == "Volumes", !components[2].isEmpty else {
            return nil
        }
        return "/Volumes/" + components[2]
    }

    /// Generates the exact terminal command a user can run to grant whole-volume + directory ownership and read/write permissions.
    static func manualRepairCommand(forPath targetPath: String) -> String {
        let cleanPath = URL(fileURLWithPath: targetPath, isDirectory: true).resolvingSymlinksInPath().path
        let quoted = shellSingleQuoted(cleanPath)
        if let mountPath = externalVolumeMountPath(forPath: cleanPath), mountPath != cleanPath {
            let quotedMount = shellSingleQuoted(mountPath)
            return "sudo chflags nouchg \(quotedMount) 2>/dev/null; sudo chown $(id -u):$(id -g) \(quotedMount) && sudo chmod u+rwx \(quotedMount) && sudo mkdir -p \(quoted) && sudo chflags -R nouchg \(quoted) 2>/dev/null; sudo chown -R $(id -u):$(id -g) \(quoted) && sudo chmod -R u+rwX \(quoted)"
        }
        return "sudo mkdir -p \(quoted) && sudo chflags -R nouchg \(quoted) 2>/dev/null; sudo chown -R $(id -u):$(id -g) \(quoted) && sudo chmod -R u+rwX \(quoted)"
    }

    /// Performs a real OS-level whole-volume + directory enumeration + file create/write/fsync/unlink probe
    /// outside any transient NSOpenPanel security scope.
    /// On `/Volumes/...`, probing the volume root immediately triggers macOS TCC
    /// (`NSRemovableVolumesUsageDescription`) and verifies whole-disk write access while the user is at the Mac,
    /// ensuring persistent background access for `lightisled` when accessed or migrated later.
    nonisolated static func probeDirectoryReadWrite(at directoryURL: URL) -> AccessProbeResult {
        let canonical = directoryURL.resolvingSymlinksInPath()
        let ancestor = closestExistingDirectory(forPath: canonical.path)
        if let values = try? ancestor.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return .readOnlyVolume
        }

        if let mountPath = externalVolumeMountPath(forPath: canonical.path) {
            let volumeProbe = probeSingleDirectoryReadWrite(mountPath)
            if !volumeProbe.isWritable {
                return volumeProbe
            }
        }

        do {
            try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        } catch {
            return classifyError(error, detail: "无法创建存储目录 \(canonical.path)")
        }

        let rootProbe = probeSingleDirectoryReadWrite(canonical.path)
        if !rootProbe.isWritable {
            return rootProbe
        }

        for sub in ["Users", ".lightisle-trash", ".lightisle-parts", ".lightisle-uploads", ".lightisle-appdata"] {
            let subPath = canonical.appendingPathComponent(sub, isDirectory: true).path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue {
                let subProbe = probeSingleDirectoryReadWrite(subPath)
                if !subProbe.isWritable {
                    return subProbe
                }
                if sub == "Users" {
                    let nestedResult = probeNestedUserDirectories(at: subPath)
                    if !nestedResult.isWritable {
                        return nestedResult
                    }
                }
            }
        }

        return .writable
    }

    nonisolated private static func probeNestedUserDirectories(at usersPath: String) -> AccessProbeResult {
        guard let userEntries = try? FileManager.default.contentsOfDirectory(atPath: usersPath) else {
            return .posixPermissionDenied("无法读取用户空间目录 \(usersPath)")
        }
        for entry in userEntries {
            let userDir = (usersPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: userDir, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let userProbe = probeSingleDirectoryReadWrite(userDir)
            if !userProbe.isWritable {
                return userProbe
            }
            if let catEntries = try? FileManager.default.contentsOfDirectory(atPath: userDir) {
                for cat in catEntries {
                    let catDir = (userDir as NSString).appendingPathComponent(cat)
                    var isCatDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: catDir, isDirectory: &isCatDir), isCatDir.boolValue {
                        let catProbe = probeSingleDirectoryReadWrite(catDir)
                        if !catProbe.isWritable {
                            return catProbe
                        }
                    }
                }
            }
        }
        return .writable
    }

    /// Ensures a directory exists and has persistent OS + POSIX read/write access for both the Mac app
    /// and the background `lightisled` service before registering or using it.
    static func ensureDirectoryWritable(
        _ url: URL,
        reason: String = "轻屿需要该存储目录的持久读写权限，以确保后续手机或网页远程访问时无需在 Mac 旁手动确认。"
    ) async -> (ok: Bool, errorMessage: String?) {
        let canonical = url.resolvingSymlinksInPath()
        let probe = probeDirectoryReadWrite(at: canonical)
        if probe.isWritable {
            return (true, nil)
        }
        return await requestReadWriteAccess(
            forPath: canonical.path,
            reason: reason,
            initialProbe: probe
        )
    }

    /// Interactive multi-tier permission acquisition & repair flow while the user is at the Mac.
    static func requestReadWriteAccess(
        forPath targetPath: String,
        reason: String = "轻屿需要该存储目录的持久读写权限，以确保后续远程访问或迁移数据时不被 macOS 拦截。",
        initialProbe: AccessProbeResult? = nil
    ) async -> (ok: Bool, errorMessage: String?) {
        let cleanURL = URL(fileURLWithPath: targetPath, isDirectory: true).resolvingSymlinksInPath()
        let cleanPath = cleanURL.path
        if cleanPath.isEmpty || cleanPath == "/" || cleanPath == "/Volumes" {
            return (false, "请选择具体硬盘或专用文件夹，不能直接授权系统根目录。")
        }

        var probe = initialProbe ?? probeDirectoryReadWrite(at: cleanURL)
        if case .readOnlyVolume = probe {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "该外置硬盘当前为「只读挂载」，无法写入数据"
            alert.informativeText = """
            目标位置：\(cleanPath)

            macOS 检测到该宗卷为只读文件系统（常见于 Windows NTFS 格式硬盘或开启了硬件写保护）。
            原有文件未受影响。请先备份盘内重要文件后，在「磁盘工具」中格式化为 APFS 或 ExFAT，或使用支持可写挂载的驱动后再接入轻屿。
            """
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            _ = alert.runModal()
            return (false, "该外置硬盘以只读方式挂载（如 NTFS 格式），macOS 无法写入，请更换为 APFS 或 ExFAT 格式。")
        }

        if case .tccOrSandboxBlocked = probe {
            let tccResult = await presentTCCPrivacyGuide(forURL: cleanURL, reason: reason)
            if tccResult.ok {
                return (true, nil)
            }
            if let stopMessage = tccResult.errorMessage {
                return (false, stopMessage)
            }
            probe = probeDirectoryReadWrite(at: cleanURL)
            if probe.isWritable {
                return (true, nil)
            }
        }

        // Also allow folder selection via NSOpenPanel if directory creation requires user confirmation,
        // preferring the external volume root so whole-disk read/write access is granted upfront,
        // then strictly re-verify persistent access AFTER releasing the temporary security-scoped token.
        let mountPath = externalVolumeMountPath(forPath: cleanPath)
        let targetPanelDir = mountPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? closestExistingDirectory(forPath: cleanPath)
        let panel = NSOpenPanel()
        panel.title = mountPath != nil ? "授权外置硬盘整盘与目录持久读写权限" : "授权存储目录持久读写权限"
        panel.prompt = mountPath != nil ? "授权整盘读写" : "授权读写此目录"
        panel.message = "\(reason)\n请确认选择「\(targetPanelDir.path)」以授予整盘及存储目录的持久读写权限。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = targetPanelDir
        NSApp.activate(ignoringOtherApps: true)

        if panel.runModal() == .OK, let grantedURL = panel.url {
            let scoped = grantedURL.startAccessingSecurityScopedResource()
            try? FileManager.default.createDirectory(at: cleanURL, withIntermediateDirectories: true)
            if scoped {
                grantedURL.stopAccessingSecurityScopedResource()
            }
            let postPanelProbe = probeDirectoryReadWrite(at: cleanURL)
            if postPanelProbe.isWritable {
                return (true, nil)
            }
            if case .tccOrSandboxBlocked = postPanelProbe {
                let tccResult = await presentTCCPrivacyGuide(forURL: cleanURL, reason: reason)
                if tccResult.ok { return (true, nil) }
                if let msg = tccResult.errorMessage { return (false, msg) }
            }
        }

        let command = manualRepairCommand(forPath: cleanPath)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "该存储目录或所在硬盘尚无持久读写权限，请选择修复方式"
        alert.informativeText = """
        目标目录：\(cleanPath)
        原因：\(reason)

        若未获得整盘与目录的持久读写权限，本次目录添加将视为失败（以避免后续跨目录数据迁移或远程上传失败）。原有文件未受影响：
        1. 点击「使用管理员权限自动修复」一键修复整盘挂载点与目录所有权；
        2. 点击「打开系统隐私与安全性设置」开启「文件和文件夹 → 可移除宗卷」权限；
        3. 点击「复制终端命令手动执行…」在终端运行：
        \(command)
        """
        alert.addButton(withTitle: "使用管理员权限自动修复")
        alert.addButton(withTitle: "打开系统「隐私与安全性」设置")
        alert.addButton(withTitle: "复制终端命令手动执行…")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try await runAdminPermissionRepair(forPath: cleanPath)
                if probeDirectoryReadWrite(at: cleanURL).isWritable {
                    return (true, nil)
                }
                return presentManualCommandGuide(
                    forPath: cleanPath,
                    reason: reason,
                    failureDetail: "管理员所有权修复已执行，但整盘与目录持久读写检测仍未通过。请检查「系统设置 → 隐私与安全性 → 文件和文件夹（或完全磁盘访问权限）」是否已允许 LightIsle 访问可移除宗卷，或在终端执行下方命令。"
                )
            } catch {
                return presentManualCommandGuide(
                    forPath: cleanPath,
                    reason: reason,
                    failureDetail: "自动提权未完成（\(error.localizedDescription)）。你可以在终端运行下方命令，执行成功后点击「我已执行完成，重新检测」。"
                )
            }
        } else if response == .alertSecondButtonReturn {
            let tccResult = await presentTCCPrivacyGuide(forURL: cleanURL, reason: reason, openImmediately: true)
            if tccResult.ok { return (true, nil) }
            return (false, tccResult.errorMessage ?? "未开启系统「隐私与安全性」可移除宗卷读写权限，添加目录失败。")
        } else if response == .alertThirdButtonReturn {
            return presentManualCommandGuide(forPath: cleanPath, reason: reason, failureDetail: nil)
        }

        return (false, "未获取整盘与目录持久读写权限，已中止添加目录（可在终端执行：\(command)）。原有数据未受影响。")
    }

    /// Guides the user to enable macOS TCC Removable Volumes / Full Disk Access and re-verifies immediately.
    private static func presentTCCPrivacyGuide(
        forURL cleanURL: URL,
        reason: String,
        openImmediately: Bool = false
    ) async -> (ok: Bool, errorMessage: String?) {
        if openImmediately {
            openSystemPrivacySettings()
        }
        while true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "需要开启 macOS「可移除宗卷」隐私权限"
            alert.informativeText = """
            目标目录：\(cleanURL.path)
            原因：\(reason)

            macOS 隐私保护当前拦截了对该外置硬盘的后台持久访问。若不在此刻放行，后续你不在 Mac 旁时，手机端和网页端将无法读写此硬盘。

            请在「系统设置 → 隐私与安全性 → 文件和文件夹」中找到「LightIsle（轻屿）」并开启「可移除宗卷」（或在「完全磁盘访问权限」中开启轻屿），然后点击「我已开启权限，立即重新检测」。
            """
            alert.addButton(withTitle: openImmediately ? "我已开启权限，立即重新检测" : "打开系统「隐私与安全性」设置")
            alert.addButton(withTitle: openImmediately ? "再次打开系统设置" : "我已开启权限，立即重新检测")
            alert.addButton(withTitle: "尝试管理员目录权限修复…")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)

            let choice = alert.runModal()
            let shouldOpenSettings = openImmediately ? (choice == .alertSecondButtonReturn) : (choice == .alertFirstButtonReturn)
            let shouldRecheck = openImmediately ? (choice == .alertFirstButtonReturn) : (choice == .alertSecondButtonReturn)

            if shouldOpenSettings {
                openSystemPrivacySettings()
                return await presentTCCPrivacyGuide(forURL: cleanURL, reason: reason, openImmediately: true)
            } else if shouldRecheck {
                if probeDirectoryReadWrite(at: cleanURL).isWritable {
                    return (true, nil)
                }
                continue
            } else if choice == .alertThirdButtonReturn {
                try? await runAdminPermissionRepair(forPath: cleanURL.path)
                if probeDirectoryReadWrite(at: cleanURL).isWritable {
                    return (true, nil)
                }
                return (false, nil) // Fall through to manual repair options in caller.
            } else {
                return (false, "尚未开启 macOS「可移除宗卷」隐私权限，已取消本次操作，原有数据未受影响。")
            }
        }
    }

    /// Fallback manual command guide: copies the command / opens Terminal, and lets the user click
    /// "我已执行完成，立即继续" once they run it so the workflow proceeds immediately.
    static func presentManualCommandGuide(
        forPath targetPath: String,
        reason: String,
        failureDetail: String?
    ) -> (ok: Bool, errorMessage: String?) {
        let cleanURL = URL(fileURLWithPath: targetPath, isDirectory: true).resolvingSymlinksInPath()
        let cleanPath = cleanURL.path
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
            NSApp.activate(ignoringOtherApps: true)

            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                if probeDirectoryReadWrite(at: cleanURL).isWritable {
                    return (true, nil)
                }
                let recheck = NSAlert()
                recheck.alertStyle = .warning
                recheck.messageText = "整盘与目录持久读写检测仍未通过"
                recheck.informativeText = """
                目标目录：\(cleanPath)

                系统真实读写测试仍未通过。请确认终端命令已执行成功，且「系统设置 → 隐私与安全性 → 文件和文件夹 / 完全磁盘访问权限」已允许轻屿访问该外置硬盘。
                为防止后续迁移数据半途失败，未通过读写检测时将不会添加该目录。
                """
                recheck.addButton(withTitle: "返回重新执行并检测")
                recheck.addButton(withTitle: "打开系统「隐私与安全性」")
                recheck.addButton(withTitle: "取消添加")
                let subChoice = recheck.runModal()
                if subChoice == .alertFirstButtonReturn {
                    continue
                } else if subChoice == .alertSecondButtonReturn {
                    openSystemPrivacySettings()
                    continue
                } else {
                    return (false, "未获得整盘与目录读写权限，添加目录失败（可在终端执行：\(command)），原有文件未受影响。")
                }
            } else if choice == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                continue
            } else {
                return (false, "未完成整盘与目录读写授权，添加目录已中止（可在终端执行：\(command)）。")
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

    nonisolated private static func probeSingleDirectoryReadWrite(_ dirPath: String) -> AccessProbeResult {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: dirPath)
        } catch {
            return classifyError(error, detail: "无法读取目录 \(dirPath)")
        }
        let probeFile = URL(fileURLWithPath: dirPath, isDirectory: true)
            .appendingPathComponent(".lightisle-permcheck-\(UUID().uuidString.lowercased())")
            .path
        let fd = Darwin.open(probeFile, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        if fd < 0 {
            return classifyErrno(errno, detail: "无法在 \(dirPath) 创建读写测试文件")
        }
        defer { _ = Darwin.unlink(probeFile) }
        var byte: UInt8 = 0x6F
        let written = withUnsafePointer(to: &byte) { ptr in
            Darwin.write(fd, ptr, 1)
        }
        if written < 0 {
            let err = errno
            _ = Darwin.close(fd)
            return classifyErrno(err, detail: "无法写入 \(dirPath)")
        }
        _ = Darwin.fsync(fd)
        _ = Darwin.close(fd)
        return .writable
    }

    nonisolated private static func classifyError(_ error: Error, detail: String) -> AccessProbeResult {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteVolumeReadOnlyError {
            return .readOnlyVolume
        }
        if let posixCode = extractPOSIXErrno(from: nsError) {
            return classifyErrno(posixCode, detail: detail)
        }
        return .posixPermissionDenied("\(detail)（\(nsError.localizedDescription)）")
    }

    nonisolated private static func extractPOSIXErrno(from error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain {
            return Int32(error.code)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return extractPOSIXErrno(from: underlying)
        }
        return nil
    }

    nonisolated private static func classifyErrno(_ code: Int32, detail: String) -> AccessProbeResult {
        switch code {
        case EROFS:
            return .readOnlyVolume
        case EPERM:
            return .tccOrSandboxBlocked("\(detail)（macOS 隐私保护拦截 EPERM）")
        default:
            let msg = String(cString: strerror(code))
            return .posixPermissionDenied("\(detail)（\(msg)）")
        }
    }

    nonisolated private static func closestExistingDirectory(forPath path: String) -> URL {
        var current = URL(fileURLWithPath: path, isDirectory: true)
        while !FileManager.default.fileExists(atPath: current.path) && current.path != "/" {
            current.deleteLastPathComponent()
        }
        return current
    }

    private static func runAdminPermissionRepair(forPath path: String) async throws {
        let uid = getuid()
        let gid = getgid()
        let quotedPath = shellSingleQuoted(path)
        let mountPrefix: String = {
            if let mountPath = externalVolumeMountPath(forPath: path), mountPath != path {
                let quotedMount = shellSingleQuoted(mountPath)
                return "(/usr/bin/chflags nouchg \(quotedMount) 2>/dev/null || true) && /usr/sbin/chown \(uid):\(gid) \(quotedMount) && /bin/chmod u+rwx \(quotedMount) && "
            }
            return ""
        }()
        let subdirs = ["Users", ".lightisle-trash", ".lightisle-parts", ".lightisle-uploads", ".lightisle-appdata"]
            .map {
                shellSingleQuoted(
                    URL(fileURLWithPath: path, isDirectory: true)
                        .appendingPathComponent($0, isDirectory: true).path
                )
            }
            .joined(separator: " ")
        let cmd = "\(mountPrefix)/bin/mkdir -p \(quotedPath) && (/usr/bin/chflags nouchg \(quotedPath) 2>/dev/null || true) && /usr/sbin/chown \(uid):\(gid) \(quotedPath) && /bin/chmod u+rwx \(quotedPath) && for d in \(subdirs); do if [ -e \"$d\" ]; then (/usr/bin/chflags -R nouchg \"$d\" 2>/dev/null || true) && /usr/sbin/chown -R \(uid):\(gid) \"$d\" && /bin/chmod -R u+rwX \"$d\"; fi; done"
        let script = "do shell script \(appleScriptQuoted(cmd)) with administrator privileges"
        let (status, errData) = try await Task.detached(priority: .userInitiated) { () throws -> (Int32, Data) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let stderr = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            let errHandle = stderr.fileHandleForReading
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                throw error
            }
            let data = errHandle.readDataToEndOfFile()
            process.waitUntilExit()
            process.terminationHandler = nil
            return (process.terminationStatus, Data(data.prefix(8192)))
        }.value
        if status == 0 {
            return
        }
        let message = String(data: errData, encoding: .utf8) ?? ""
        if message.contains("User canceled") || message.contains("user canceled") ||
            message.contains("(-128)") || message.contains("(-6002)") {
            throw RepairError.cancelled
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        throw RepairError.failed(trimmed.isEmpty ? "退出码 \(status)" : String(trimmed.prefix(200)))
    }
}
