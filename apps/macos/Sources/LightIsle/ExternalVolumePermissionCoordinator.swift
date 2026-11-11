import AppKit
import Foundation

@MainActor
final class ExternalVolumePermissionCoordinator {
    private struct VolumeDescriptor {
        let mountPath: String
        let volumeName: String
        let volumeKey: String
        let isEligibleExternalWritable: Bool
    }

    private static let mutedKeysDefaultsKey = "lightisle.mutedExternalVolumePromptKeys"

    private weak var appModel: AppModel?
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?
    private var sessionIgnoredMounts: Set<String> = []
    private var activeMountPrompts: Set<String> = []
    private var auditedOnlineRootIDs: Set<String> = []
    private var pendingAuditQueue: [NativeSharedRoot] = []
    private var auditWorkerRunning = false

    func start(appModel: AppModel) {
        guard mountObserver == nil else { return }
        self.appModel = appModel
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let url = Self.extractVolumeURL(from: notification)
            Task { @MainActor [weak self] in
                guard let self, let url else { return }
                await self.handleVolumeMounted(url)
            }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let url = Self.extractVolumeURL(from: notification)
            Task { @MainActor [weak self] in
                guard let self, let url else { return }
                self.handleVolumeUnmounted(url)
            }
        }
    }

    private nonisolated static func extractVolumeURL(from notification: Notification) -> URL? {
        if let url = notification.userInfo?["NSWorkspaceVolumeURLKey"] as? URL {
            return url
        }
        if let path = notification.userInfo?["NSDevicePath"] as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    func auditOnlineExternalRootsIfNeeded(_ roots: [NativeSharedRoot]) {
        let onlineIDs = Set(roots.filter(\.online).map(\.rootID))
        auditedOnlineRootIDs.formIntersection(onlineIDs)

        for root in roots where root.online && root.path.hasPrefix("/Volumes/") {
            guard !auditedOnlineRootIDs.contains(root.rootID) else { continue }
            auditedOnlineRootIDs.insert(root.rootID)
            if !pendingAuditQueue.contains(where: { $0.rootID == root.rootID }) {
                pendingAuditQueue.append(root)
            }
        }
        drainAuditQueueIfNeeded()
    }

    private func drainAuditQueueIfNeeded() {
        guard !auditWorkerRunning, !pendingAuditQueue.isEmpty else { return }
        auditWorkerRunning = true
        Task { @MainActor [weak self] in
            defer { self?.auditWorkerRunning = false }
            while let self, !self.pendingAuditQueue.isEmpty {
                let root = self.pendingAuditQueue.removeFirst()
                guard let appModel = self.appModel, appModel.state == .online else { continue }
                let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
                let probe = StoragePermissionHelper.probeDirectoryReadWrite(at: rootURL)
                if !probe.isWritable {
                    let access = await StoragePermissionHelper.requestReadWriteAccess(
                        forPath: root.path,
                        reason: "检测到已登记的外置存储目录「\(root.name)」缺少持久读写权限。请现在完成授权，以确保后续手机或网页远程访问正常可用。",
                        initialProbe: probe
                    )
                    guard access.ok else {
                        appModel.storageSelectionMessage = access.errorMessage
                        continue
                    }
                }
                _ = await self.verifyDaemonAccessWhenIdle(path: root.path)
            }
        }
    }

    private func handleVolumeUnmounted(_ volumeURL: URL) {
        let mountPath = volumeURL.standardizedFileURL.path
        sessionIgnoredMounts.remove(mountPath)
        appModel?.refreshStorageAfterVolumeEvent()
    }

    private func handleVolumeMounted(_ volumeURL: URL) async {
        let mountPath = volumeURL.resolvingSymlinksInPath().path
        appModel?.refreshStorageAfterVolumeEvent()

        guard StorageVolumeSelection.canInspectExternalVolume(mount: mountPath),
              !activeMountPrompts.contains(mountPath) else { return }

        let descriptor = await Self.inspectVolume(at: volumeURL, mountPath: mountPath)
        guard descriptor.isEligibleExternalWritable else { return }

        // Allow Core's `roots list` and `disk list` to reflect the newly mounted volume first.
        try? await Task.sleep(for: .milliseconds(650))
        guard let appModel,
              appModel.state == .online,
              FileManager.default.fileExists(atPath: mountPath) else { return }

        if appModel.managedDisks.contains(where: {
            $0.mount == mountPath && StorageVolumeSelection.isDiskImageProtocol($0.protocolName)
        }) {
            return
        }

        let matchingRoots = appModel.rootManagement.roots.filter {
            $0.path == mountPath || $0.path.hasPrefix(mountPath + "/")
        }
        if !matchingRoots.isEmpty {
            auditOnlineExternalRootsIfNeeded(appModel.rootManagement.roots)
            return
        }

        guard appModel.isConfigured == true,
              !sessionIgnoredMounts.contains(mountPath),
              !isMuted(volumeKey: descriptor.volumeKey),
              !activeMountPrompts.contains(mountPath) else { return }

        activeMountPrompts.insert(mountPath)
        defer { activeMountPrompts.remove(mountPath) }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "检测到外置硬盘「\(descriptor.volumeName)」，是否立即完成读写授权？"
        alert.informativeText = """
        挂载路径：\(mountPath)

        建议趁你当前在 Mac 旁立即完成 macOS「可移除宗卷」及后台服务读写预授权。授权后，后续离开电脑通过手机 App 或网页端远程上传照片、管理文件或跨盘迁移时，不会再被系统权限弹窗拦截。
        """
        alert.addButton(withTitle: "接入轻屿并立即授权读写（推荐）")
        alert.addButton(withTitle: "仅预授权此盘读写权限（暂不添加目录）")
        alert.addButton(withTitle: "本次忽略")
        alert.addButton(withTitle: "不再提醒此硬盘")
        NSApp.activate(ignoringOtherApps: true)

        let choice = alert.runModal()
        switch choice {
        case .alertFirstButtonReturn:
            sessionIgnoredMounts.insert(mountPath)
            let suggestedPath = URL(fileURLWithPath: mountPath, isDirectory: true)
                .appendingPathComponent("LightIsle", isDirectory: true).path
            appModel.addPresetSharedFolder(
                path: suggestedPath,
                name: "\(descriptor.volumeName)-LightIsle"
            )
        case .alertSecondButtonReturn:
            sessionIgnoredMounts.insert(mountPath)
            appModel.preauthorizeVolumeReadWrite(
                mountPath: mountPath,
                volumeName: descriptor.volumeName
            )
        case .alertThirdButtonReturn:
            sessionIgnoredMounts.insert(mountPath)
        default:
            mute(volumeKey: descriptor.volumeKey)
            sessionIgnoredMounts.insert(mountPath)
        }
    }

    func verifyDaemonAccessWhenIdle(path: String) async -> (ok: Bool, message: String?) {
        guard let appModel else { return (false, nil) }
        for _ in 0..<40 {
            if !appModel.rootManagement.busy { break }
            try? await Task.sleep(for: .milliseconds(75))
        }
        guard appModel.state == .online,
              appModel.rootManagement.connected,
              !appModel.rootManagement.busy else {
            return (false, "后台目录状态正在同步，请稍候重试。")
        }
        return await withCheckedContinuation { continuation in
            appModel.rootManagement.verifyAccess(path: path, autoRepairOnDenied: true) { ok, msg in
                continuation.resume(returning: (ok, msg))
            }
        }
    }

    private func isMuted(volumeKey: String) -> Bool {
        let keys = UserDefaults.standard.stringArray(forKey: Self.mutedKeysDefaultsKey) ?? []
        return keys.contains(volumeKey)
    }

    private func mute(volumeKey: String) {
        var keys = UserDefaults.standard.stringArray(forKey: Self.mutedKeysDefaultsKey) ?? []
        if !keys.contains(volumeKey) {
            keys.append(volumeKey)
            if keys.count > 64 {
                keys.removeFirst(keys.count - 64)
            }
            UserDefaults.standard.set(keys, forKey: Self.mutedKeysDefaultsKey)
        }
    }

    private nonisolated static func inspectVolume(at volumeURL: URL, mountPath: String) async -> VolumeDescriptor {
        await Task.detached(priority: .utility) {
            let fallbackName = URL(fileURLWithPath: mountPath).lastPathComponent
            let keys: Set<URLResourceKey> = [
                .volumeNameKey,
                .volumeUUIDStringKey,
                .volumeIsInternalKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsReadOnlyKey,
                .volumeIsLocalKey,
                .volumeIsBrowsableKey,
            ]
            let values = try? volumeURL.resourceValues(forKeys: keys)
            let volumeName = values?.volumeName ?? fallbackName
            var volumeKey = values?.volumeUUIDString ?? mountPath

            if values?.volumeIsBrowsable == false || values?.volumeIsLocal == false || values?.volumeIsReadOnly == true {
                return VolumeDescriptor(mountPath: mountPath, volumeName: volumeName, volumeKey: volumeKey, isEligibleExternalWritable: false)
            }

            let systemPartitionNames: Set<String> = ["efi", "recovery", "preboot", "update", "vm", "xarts", "iscpreboot", "hardware"]
            let lowerName = volumeName.lowercased()
            if systemPartitionNames.contains(lowerName) || lowerName.contains("time machine") {
                return VolumeDescriptor(mountPath: mountPath, volumeName: volumeName, volumeKey: volumeKey, isEligibleExternalWritable: false)
            }

            var isExternalOrRemovable = (values?.volumeIsInternal == false) ||
                (values?.volumeIsRemovable == true) ||
                (values?.volumeIsEjectable == true)

            // Query diskutil plist without touching user files on the mounted volume (so we do not
            // prematurely trigger TCC before showing LightIsle's explanation alert).
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["info", "-plist", mountPath]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0,
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    if let proto = plist["Protocol"] as? String,
                       StorageVolumeSelection.isDiskImageProtocol(proto) {
                        return VolumeDescriptor(mountPath: mountPath, volumeName: volumeName, volumeKey: volumeKey, isEligibleExternalWritable: false)
                    }
                    if let writable = (plist["WritableVolume"] as? Bool) ?? (plist["Writable"] as? Bool), !writable {
                        return VolumeDescriptor(mountPath: mountPath, volumeName: volumeName, volumeKey: volumeKey, isEligibleExternalWritable: false)
                    }
                    if let internalDisk = plist["Internal"] as? Bool {
                        let removable = (plist["RemovableMedia"] as? Bool == true) || (plist["Ejectable"] as? Bool == true)
                        if internalDisk && !removable {
                            isExternalOrRemovable = false
                        } else if !internalDisk {
                            isExternalOrRemovable = true
                        }
                    }
                    if let uuid = (plist["VolumeUUID"] as? String) ?? (plist["DiskUUID"] as? String), !uuid.isEmpty {
                        volumeKey = uuid
                    }
                }
            }

            return VolumeDescriptor(
                mountPath: mountPath,
                volumeName: volumeName,
                volumeKey: volumeKey,
                isEligibleExternalWritable: isExternalOrRemovable
            )
        }.value
    }
}
