import AppKit
import Foundation

@MainActor
extension AppModel {
    // MARK: - Storage operations

    func clearPendingStorageSelection() {
        storageSelectionDeadline?.cancel()
        storageSelectionDeadline = nil
        storageSelectionPending = false
        pendingStorageTarget = nil
        previousStorageRoot = nil
        legacyAccessRevokedForPendingRoot = nil
    }

    static func decodeBase64URLJSON<T: Decodable>(_ type: T.Type, raw: String) -> T? {
        CoreIPCPayloadCodec.decodeJSON(type, raw: raw)
    }

    static func decodeBase64URLText(_ raw: String) -> String? {
        CoreIPCPayloadCodec.decodeText(raw)
    }

    func keepOfflineShare() {
        guard let path = offlineSharedFolderPath else { return }
        offlineCleanupMessage = "已保留原磁盘绑定和媒体记录（\(path)）。重新接上原磁盘后点击「重新连接」。"
    }

    func forgetOfflineShare() {
        guard canForgetOfflineShare, let oldPath = offlineSharedFolderPath else { return }
        let first = NSAlert()
        first.alertStyle = .critical
        first.messageText = "清除离线磁盘的 LightIsle 记录？"
        first.informativeText = """
        原共享路径：\(oldPath)

        只有本机应用的磁盘绑定和媒体记录会被清理，旧磁盘上的真实照片、影片、文件不会被访问或删除。此操作会丢失该目录在本地的照片收藏、相册关系和观看进度；旧目录的成员文件授权与公开分享链接会撤销，授权记录保留在本机但不会自动用于新目录。用户账号、登录会话和 WebDAV 凭据保留。NAS 存储将切换到 Mac 本机默认目录，旧磁盘日后重连需重新授权。建议先独立备份 LightIsle 的元数据目录。
        """
        first.addButton(withTitle: "继续核对")
        first.addButton(withTitle: "取消，保留记录")
        guard first.runModal() == .alertFirstButtonReturn else { return }

        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = "最后确认：请输入「清理」"
        second.informativeText = "确认只移除离线磁盘的本地记录。真实外置盘文件不受影响。"
        let confirmation = NSTextField(string: "")
        confirmation.placeholderString = "输入 清理"
        confirmation.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        second.accessoryView = confirmation
        second.addButton(withTitle: "清理离线记录")
        second.addButton(withTitle: "取消")
        guard second.runModal() == .alertFirstButtonReturn,
              confirmation.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == "清理" else { return }
        guard canForgetOfflineShare, offlineSharedFolderPath == oldPath,
              let pipe = coreCommands else { return }
        offlineCleanupPending = true
        offlineCleanupMessage = "已提交离线盘记录清理请求，等待 NAS Core 验证…"
        do {
            let encoded = Data(oldPath.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            try pipe.write(contentsOf: Data(("share forget " + encoded + "\n").utf8))
        } catch {
            offlineCleanupPending = false
            offlineCleanupMessage = "无法发送清理请求：\(error.localizedDescription)"
        }
    }

    func openDiskFormattingGuide(for volume: HostVolume) {
        guard StorageVolumeSelection.canInspectExternalVolume(mount: volume.mount),
              managedDisks.contains(where: { disk in
                  disk.mount == volume.mount && disk.external &&
                      !StorageVolumeSelection.isDiskImageProtocol(disk.protocolName)
              }),
              modelVolumeIsCurrent(volume) else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "使用 macOS 磁盘工具格式化「\(volume.name)」"
        alert.informativeText = """
        磁盘：\(volume.name)
        挂载点：\(volume.mount)
        设备：\(volume.device)
        格式：\(volume.filesystem)

        抹掉/格式化会删除选中磁盘上的全部现有文件，无法自动恢复。请先在另一块磁盘备份数据。

        推荐 APFS：仅在 Mac 上长期使用；如需 Mac 和 Windows 共用，选择 exFAT。系统磁盘工具中开启「显示所有设备」，确认容量及设备名称无误，再选择正确目标点击「抹掉」。LightIsle 不会自动格式化或提权。
        """
        alert.addButton(withTitle: "打开 macOS 磁盘工具")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let utility = URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")
        NSWorkspace.shared.open(utility)
    }

    private func modelVolumeIsCurrent(_ volume: HostVolume) -> Bool {
        metrics?.volumes?.contains(where: {
            $0.mount == volume.mount && $0.device == volume.device && $0.filesystem == volume.filesystem
        }) == true
    }

    func selectSharedFolder(onVolume volume: HostVolume? = nil) {
        guard state == .online else {
            storageSelectionMessage = "NAS Core 尚未连接，暂时不能登记存储目录。"
            return
        }
        rootManagement.addFolder(onVolume: volume)
    }

    func selectPresetSharedFolder(path: String, name: String) {
        guard state == .online else {
            storageSelectionMessage = "NAS Core 尚未连接，暂时不能登记存储目录。"
            return
        }
        rootManagement.selectDefaultFolder(path: path, name: name)
    }

    func retrySharedFolder() {
        guard state == .online, !storageSelectionPending, !offlineCleanupPending else { return }
        sharedFolderError = nil
        try? coreCommands?.write(contentsOf: Data("share retry\n".utf8))
    }

    /// A cross-volume transfer is only requested from the native owner UI.
    /// Neither the selected source nor target is exposed to the Web API.
    func exportToAnotherDisk() {
        guard state == .online, !exportRunning, let base = sharedFolderPath else { return }
        let choice = CrossDiskExportCoordinator.choose(sharedFolderPath: base)
        let plan: CrossDiskExportPlan
        switch choice {
        case .cancelled:
            return
        case .rejected(let message):
            exportMessage = message
            return
        case .selected(let selected):
            plan = selected
        }
        guard let ipcLine = plan.ipcLine else {
            exportMessage = "无法创建复制请求。"
            return
        }
        // Native dialogs can run their own event loop. The Core or selected
        // root may have changed while the user was choosing a destination.
        guard state == .online, !exportRunning, sharedFolderPath == base,
              let pipe = coreCommands else {
            exportMessage = "Core 或共享目录已变化，请重新选择复制来源和目标。"
            return
        }
        let mode = plan.mode
        exportRunning = true
        activeExportMode = mode
        exportMessage = mode == "move"
            ? "正在执行日志化安全移动：复制、校验、写入恢复日志，再把源文件移入回收站。"
            : "正在复制并验证内容。源文件保持不变。"
        do {
            try pipe.write(contentsOf: Data(ipcLine.utf8))
        } catch {
            exportRunning = false
            exportMessage = "无法发送复制任务：\(error.localizedDescription)"
        }
    }

    func cancelExport() {
        guard exportRunning, state == .online else { return }
        try? coreCommands?.write(contentsOf: Data("export cancel\n".utf8))
        exportMessage = "正在请求取消跨磁盘复制，清理尚未发布的临时副本…"
    }

    func requestTransferHistory() {
        guard state == .online else { return }
        try? coreCommands?.write(contentsOf: Data("export history\n".utf8))
    }

    func decodeExportResult(_ raw: String) -> String? {
        guard raw.count <= 8192 else { return nil }
        var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
