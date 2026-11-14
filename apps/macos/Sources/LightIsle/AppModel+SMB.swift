import AppKit
import Foundation

@MainActor
extension AppModel {
    func refreshSMBState() {
        guard state == .online else { return }
        smbError = nil
        sendCoreCommandLine("smb state\n", context: "smb.state")
    }

    func setSMBServiceEnabled(_ enabled: Bool) {
        sendSMBAction([
            "action": "service",
            "enabled": enabled,
        ])
    }

    @discardableResult
    func addSMBShare(rootID: String, subpath: String, smbName: String, guestAccess: Bool, readOnly: Bool, sealed: Bool) -> Bool {
        let components = subpath.split(separator: "/")
        let personal = components.isEmpty || components.first?.lowercased() == "users"
        guard !personal || confirmPersonalSMBShare(subpath.isEmpty ? "整块存储根" : subpath, guest: guestAccess) else { return false }
        return sendSMBAction([
            "action": "add",
            "rootId": rootID,
            "subpath": subpath,
            "smbName": smbName.trimmingCharacters(in: .whitespacesAndNewlines),
            "guestAccess": guestAccess,
            "readOnly": readOnly,
            "sealed": sealed,
            "confirmPersonal": personal,
        ])
    }

    @discardableResult
    func selectCustomFolderForSMBShare(smbName: String, guestAccess: Bool, readOnly: Bool, sealed: Bool) -> Bool {
        guard state == .online, !smbBusy else { return false }
        let panel = NSOpenPanel()
        panel.title = "选择要通过 Mac 文件共享 (SMB) 分享的文件夹"
        panel.prompt = "添加到 SMB 共享"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let resolved = url.resolvingSymlinksInPath().path
        let lowerPath = resolved.lowercased()
        let containsUsers = FileManager.default.fileExists(atPath: (resolved as NSString).appendingPathComponent("Users"))
        let personal = containsUsers || url.lastPathComponent.lowercased() == "users" ||
            (smbState?.candidateRoots ?? []).contains { root in
                let users = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().appendingPathComponent("Users").path.lowercased()
                return lowerPath == users || lowerPath.hasPrefix(users + "/") || users.hasPrefix(lowerPath + "/")
            }
        guard !personal || confirmPersonalSMBShare(resolved, guest: guestAccess) else { return false }
        let finalName = smbName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? url.lastPathComponent
            : smbName.trimmingCharacters(in: .whitespacesAndNewlines)
        return sendSMBAction([
            "action": "add",
            "path": resolved,
            "smbName": finalName,
            "guestAccess": guestAccess,
            "readOnly": readOnly,
            "sealed": sealed,
            "confirmPersonal": personal,
        ])
    }

    func updateSMBShare(_ share: NativeSMBSharePoint, smbName: String? = nil, shared: Bool? = nil, guestAccess: Bool? = nil, readOnly: Bool? = nil, sealed: Bool? = nil) {
        let personal = share.exposesPersonalDirs && (shared ?? share.shared)
        guard !personal || confirmPersonalSMBShare(share.path, guest: guestAccess ?? share.guestAccess) else { return }
        sendSMBAction([
            "action": "update",
            "recordName": share.recordName,
            "smbName": (smbName ?? share.smbName).trimmingCharacters(in: .whitespacesAndNewlines),
            "shared": shared ?? share.shared,
            "guestAccess": guestAccess ?? share.guestAccess,
            "readOnly": readOnly ?? share.readOnly,
            "sealed": sealed ?? share.sealed,
            "confirmPersonal": personal,
        ])
    }

    private func confirmPersonalSMBShare(_ path: String, guest: Bool) -> Bool {
        if guest {
            smbError = "此共享覆盖成员私人目录。请关闭访客访问后再试。"
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "通过 Mac 文件共享开放成员私人目录？"
        alert.informativeText = "\(path)\n\n请先核对 macOS 账号和文件夹权限。SMB 使用系统权限，写入不计入轻屿的成员额度。"
        alert.addButton(withTitle: "确认系统权限并共享")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func removeSMBShare(_ share: NativeSMBSharePoint) {
        guard state == .online, !smbBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移除 SMB 共享「\(share.smbName)」？"
        alert.informativeText = "路径：\(share.path)\n\n仅从 macOS 文件共享列表中取消共享，绝不会删除或修改硬盘上的任何原始文件。"
        alert.addButton(withTitle: "移除共享")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sendSMBAction([
            "action": "remove",
            "recordName": share.recordName,
        ])
    }

    func openSystemFileSharingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_PersonalFileSharing",
            "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.sharing?Services_PersonalFileSharing",
            "x-apple.systempreferences:com.apple.preferences.sharing",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func installSMBSudoersAuthorization() {
        guard !smbBusy else { return }
        smbBusy = true
        smbError = nil
        smbNotice = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try SmbElevation.installSudoers()
                await self?.finishSMBElevation(installed: true, error: nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                await self?.finishSMBElevation(installed: false, error: message)
            }
        }
    }

    func revokeSMBSudoersAuthorization() {
        guard !smbBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "撤销三端免密管理授权？"
        alert.informativeText = "将移除 /etc/sudoers.d/lightisle-smb。撤销后 Web 与手机客户端无法直接修改 Mac 文件共享配置，可随时重新开启。"
        alert.addButton(withTitle: "撤销授权")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        smbBusy = true
        smbError = nil
        smbNotice = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try SmbElevation.revokeSudoers()
                await self?.finishSMBElevation(installed: false, error: nil, revoked: true)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                await self?.finishSMBElevation(installed: false, error: message)
            }
        }
    }

    private func finishSMBElevation(installed: Bool, error: String?, revoked: Bool = false) {
        smbBusy = false
        if let error {
            smbError = error
        } else if installed {
            smbNotice = "已开启三端免密管理授权，现在可在 Mac、Web 和手机客户端直接控制 SMB 共享。"
        } else if revoked {
            smbNotice = "已撤销三端免密管理授权。"
        }
        refreshSMBState()
    }

    @discardableResult
    private func sendSMBAction(_ payload: [String: Any]) -> Bool {
        guard state == .online, !smbBusy,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let pipe = coreCommands else { return false }
        smbBusy = true
        smbError = nil
        smbNotice = nil
        do {
            try pipe.write(contentsOf: Data(("smb action " + data.base64URLEncodedString + "\n").utf8))
            return true
        } catch {
            smbBusy = false
            smbError = "无法发送文件共享指令：\(error.localizedDescription)"
            return false
        }
    }
}
