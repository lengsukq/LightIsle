import AppKit
import Foundation

@MainActor
extension AppModel {
    // MARK: - Storage operations

    static func decodeBase64URLText(_ raw: String) -> String? {
        CoreIPCPayloadCodec.decodeText(raw)
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
        storageSelectionMessage = nil
        rootManagement.addFolder(onVolume: volume)
    }

    func selectPresetSharedFolder(path: String, name: String, confirmSwitch: Bool = false) {
        guard state == .online else {
            storageSelectionMessage = "NAS Core 尚未连接，暂时不能登记存储目录。"
            return
        }
        storageSelectionMessage = nil
        rootManagement.selectDefaultFolder(path: path, name: name, confirmSwitch: confirmSwitch)
    }

    func addPresetSharedFolder(path: String, name: String) {
        guard state == .online else {
            storageSelectionMessage = "NAS Core 尚未连接，暂时不能登记存储目录。"
            return
        }
        storageSelectionMessage = nil
        rootManagement.addPresetFolder(path: path, name: name)
    }
}
