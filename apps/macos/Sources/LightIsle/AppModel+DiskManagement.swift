import AppKit
import Foundation

@MainActor
extension AppModel {
    // MARK: - Disk management

    func refreshManagedDisks() {
        guard state == .online, !diskOperationPending else { return }
        diskManagementError = nil
        do {
            try coreCommands?.write(contentsOf: Data("disk list\n".utf8))
        } catch {
            diskManagementError = "无法读取磁盘状态：\(error.localizedDescription)"
        }
    }

    func refreshStorageAfterVolumeEvent() {
        guard state == .online else { return }
        sendCoreCommandLine("stats summary\ndisk list\nalerts status\n", context: "volume.refresh")
        rootManagement.refresh()
        personalSpaces.refresh()
    }

    func preauthorizeVolumeReadWrite(mountPath: String, volumeName: String) {
        let cleanURL = URL(fileURLWithPath: mountPath, isDirectory: true).resolvingSymlinksInPath()
        guard StorageVolumeSelection.canInspectExternalVolume(mount: cleanURL.path) else {
            elevationMessage = "请选择挂载在 /Volumes 下的外置硬盘后再执行读写预授权。"
            return
        }
        elevationMessage = "正在为「\(volumeName)」检测并申请 macOS 与后台服务持久读写权限…"
        Task { @MainActor [weak self] in
            let access = await StoragePermissionHelper.ensureDirectoryWritable(
                cleanURL,
                reason: "提前授予外置硬盘「\(volumeName)」的持久读写权限，确保后续离开 Mac 远程访问或跨盘迁移时无需在电脑前确认。"
            )
            guard let self else { return }
            guard access.ok else {
                self.elevationMessage = access.errorMessage ?? "未能完成「\(volumeName)」读写权限预授权。"
                return
            }
            let daemonVerify = await self.externalVolumeCoordinator.verifyDaemonAccessWhenIdle(path: cleanURL.path)
            if daemonVerify.ok {
                self.elevationMessage = "✅ 「\(volumeName)」已完成 macOS 与后台服务持久读写预授权，支持后续手机/网页远程无人值守访问。"
            } else {
                self.elevationMessage = daemonVerify.message ?? "已完成系统文件夹授权，但后台服务校验尚未确认，请刷新后再试。"
            }
        }
    }

    func manageDisk(_ disk: ManagedDisk, action: String) {
        guard state == .online, !diskOperationPending, disk.external,
              disk.identity.count == 64,
              managedDisks.contains(where: { $0.id == disk.id && $0.identity == disk.identity }),
              ["rename", "mount", "eject"].contains(action) else { return }
        let names = ["rename": "重命名", "mount": "挂载", "eject": "安全弹出"]
        let alert = NSAlert()
        alert.alertStyle = action == "eject" ? .warning : .informational
        alert.messageText = "\(names[action] ?? action)「\(disk.name)」？"
        alert.informativeText = """
        设备：\(disk.id) · \(disk.filesystem)
        \(disk.mount.isEmpty ? "未挂载" : disk.mount)

        操作会由 Mac 系统执行。NAS 正在使用或备份中的硬盘会被 Core 拒绝操作；不执行强制卸载，数据写入尚未结束时不应拔掉电源或数据线。
        """
        let field = NSTextField(string: disk.name)
        if action == "rename" {
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
            alert.accessoryView = field
        }
        alert.addButton(withTitle: names[action] ?? "确认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = action == "rename" ? field.stringValue : ""
        let payload: [String: String] = ["action": action, "id": disk.id, "identity": disk.identity, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let pipe = coreCommands else { return }
        diskOperationPending = true
        diskManagementError = nil
        do {
            try pipe.write(contentsOf: Data(("disk action " + data.base64URLEncodedString + "\n").utf8))
            diskOperationDeadline?.cancel()
            diskOperationDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self, self.diskOperationPending else { return }
                self.diskOperationPending = false
                self.diskManagementError = "未及时收到磁盘操作结果，请刷新磁盘状态后确认实际结果。"
            }
        } catch {
            diskOperationPending = false
            diskManagementError = "发送操作失败：\(error.localizedDescription)"
        }
    }

    func refreshDiskHealth(_ disk: ManagedDisk) {
        guard state == .online else { return }
        do {
            try coreCommands?.write(contentsOf: Data(("disk smart " + disk.id + "\n").utf8))
        } catch {
            diskManagementError = "无法读取健康信息：\(error.localizedDescription)"
        }
    }

    /// Collects the SMART report with a user-approved elevation (silent
    /// sudoers path first, then the system password dialog) and pushes the
    /// result into the Core cache so the Web admin sees it too.
    func elevateDiskHealth(_ disk: ManagedDisk) {
        guard state == .online, !elevatingDisks.contains(disk.id) else { return }
        guard SmartElevation.locateBinary() != nil else {
            elevationMessage = SmartElevation.ElevationError.binaryMissing.errorDescription
            return
        }
        elevatingDisks.insert(disk.id)
        elevationMessage = nil
        let parent = disk.parent
        let diskID = disk.id
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try SmartElevation.collect(device: parent)
                let object = try JSONSerialization.jsonObject(with: data)
                let payload = try JSONSerialization.data(withJSONObject: [
                    "device": parent, "report": object,
                ])
                await self?.deliverElevatedSmart(payload, for: diskID)
            } catch {
                await self?.finishElevatedSmartFailure(for: diskID, message: (error as? LocalizedError)?.errorDescription)
            }
        }
    }

    /// Actor-isolated completion avoids capturing a mutable weak reference in
    /// a nested concurrently executing MainActor.run closure (Swift 6).
    private func deliverElevatedSmart(_ payload: Data, for diskID: String) {
        defer { elevatingDisks.remove(diskID) }
        guard state == .online, let pipe = coreCommands else { return }
        do {
            try pipe.write(contentsOf: Data(("disk smart report " + payload.base64URLEncodedString + "\n").utf8))
        } catch {
            elevationMessage = "无法发送 SMART 结果：\(error.localizedDescription)"
        }
    }

    private func finishElevatedSmartFailure(for diskID: String, message: String?) {
        elevatingDisks.remove(diskID)
        if let message { elevationMessage = message }
    }

    func refreshStorageThreshold() {
        guard state == .online else { return }
        sendCoreCommandLine("alerts threshold\n", context: "alerts.threshold.read")
    }

    func applyStorageThreshold(_ threshold: StorageThreshold) {
        guard state == .online, threshold.freeMiB > 0 || threshold.percent > 0,
              let data = try? JSONEncoder().encode(threshold),
              let pipe = coreCommands else { return }
        do {
            try pipe.write(contentsOf: Data(("alerts threshold " + data.base64URLEncodedString + "\n").utf8))
        } catch {
            diskManagementError = "无法保存告警阈值：\(error.localizedDescription)"
        }
    }
}
