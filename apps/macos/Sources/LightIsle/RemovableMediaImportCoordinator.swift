import AppKit
import Foundation

private struct MediaImportCancelResult: Decodable, Sendable {
    let cancelled: Bool
    let jobID: String?
}

private struct MediaImportEnvelopeHeader: Decodable {
    let schemaVersion: Int
    let operation: String
    let requestID: String?
    let error: String?
}

private struct MediaImportTypedEnvelope<Payload: Decodable>: Decodable {
    let schemaVersion: Int
    let operation: String
    let requestID: String?
    let result: Payload?
    let error: String?
}

private struct MediaImportRequestPayload: Encodable {
    var requestID: String
    var sourcePath: String?
    var rootID: String?
    var generation: UInt64?
    var userID: Int64?
    var category: String?
    var archiveMode: String?
    var subfolder: String?
    var jobID: String?
}

@MainActor
final class RemovableMediaImportCoordinator: ObservableObject {
    private static let mountSettleDelay: Duration = .milliseconds(700)
    private static let scanRequestTimeout: Duration = .seconds(50)
    private static let startRequestTimeout: Duration = .seconds(15)
    private static let requestIDLength = 24

    @Published private(set) var connected = false
    @Published private(set) var detectedVolumes: [DetectedRemovableMediaVolume] = []
    @Published private(set) var dismissedBannerMounts: Set<String> = []
    @Published var selectedMountPath: String = ""
    @Published private(set) var scanning = false
    @Published private(set) var starting = false
    @Published private(set) var scanResult: MediaImportScanResult?
    @Published private(set) var jobStatus: MediaImportJobStatus?
    @Published private(set) var errorMessage: String?
    @Published private(set) var infoMessage: String?

    @Published var selectedRootID: String = ""
    @Published var selectedUserID: Int64 = 0
    @Published var selectedCategory: MediaImportTargetCategory = .auto
    @Published var selectedArchiveMode: MediaImportArchiveMode = .ymd
    @Published var subfolder: String = ""

    private weak var appModel: AppModel?
    private var sender: ((String) throws -> Void)?
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?
    private var pendingScanRequestID: String?
    private var scanTimeoutTask: Task<Void, Never>?
    private var pendingStartRequestID: String?
    private var startTimeoutTask: Task<Void, Never>?

    var bannerVolumes: [DetectedRemovableMediaVolume] {
        detectedVolumes
            .filter { !dismissedBannerMounts.contains($0.mountPath) }
            .sorted { lhs, rhs in
                if lhs.hasCameraHints != rhs.hasCameraHints { return lhs.hasCameraHints }
                return lhs.detectedAt > rhs.detectedAt
            }
    }

    var isImporting: Bool { starting || jobStatus?.phase == "running" }

    var isCurrentResultTruncated: Bool {
        RemovableMediaImportPolicy.isTruncated(scan: scanResult, status: jobStatus)
    }

    var canSafeEjectSelectedVolume: Bool {
        RemovableMediaImportPolicy.canSafeEject(
            selectedMountPath: selectedMountPath,
            jobStatus: jobStatus,
            scanResult: scanResult,
            isImporting: isImporting
        )
    }

    func startMonitoring(appModel: AppModel) {
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
                guard let self else { return }
                if let path = url?.resolvingSymlinksInPath().standardizedFileURL.path {
                    self.dismissedBannerMounts.remove(path)
                }
                // Wait briefly so Core's roots & managedDisks snapshots settle first.
                try? await Task.sleep(for: Self.mountSettleDelay)
                self.refreshDetectedVolumes()
            }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let url = Self.extractVolumeURL(from: notification)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let path = url?.standardizedFileURL.path {
                    self.handleVolumeUnmounted(at: path)
                }
                self.refreshDetectedVolumes()
            }
        }
        refreshDetectedVolumes()
    }

    private func handleVolumeUnmounted(at path: String) {
        dismissedBannerMounts.remove(path)
        detectedVolumes.removeAll { RemovableMediaDetector.pathOverlaps($0.mountPath, path) }
        if !isImporting {
            if let statusPath = jobStatus?.sourcePath,
               RemovableMediaDetector.pathOverlaps(statusPath, path) {
                jobStatus = nil
            }
            if let scanPath = scanResult?.sourcePath,
               RemovableMediaDetector.pathOverlaps(scanPath, path) {
                scanResult = nil
            }
        }
        if !selectedMountPath.isEmpty &&
            RemovableMediaDetector.pathOverlaps(selectedMountPath, path) {
            cancelPendingScan()
            selectedMountPath = detectedVolumes.first?.mountPath ?? ""
            clearNonRunningState()
        }
    }

    private nonisolated static func extractVolumeURL(from notification: Notification) -> URL? {
        if let url = notification.userInfo?["NSWorkspaceVolumeURLKey"] as? URL { return url }
        if let path = notification.userInfo?["NSDevicePath"] as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    func connect(send: @escaping (String) throws -> Void) {
        sender = send
        connected = true
        refreshDetectedVolumes()
    }

    func disconnect() {
        let wasImporting = isImporting
        cancelPendingScan()
        clearPendingStart()
        sender = nil
        connected = false
        if wasImporting {
            errorMessage = "核心服务已断开连接，导入任务已中断；存储卡原件未受影响。"
            jobStatus = nil
        }
    }

    func refreshDetectedVolumes() {
        let registeredPaths = appModel?.rootManagement.roots.map(\.path) ?? []
        let diskImageMounts = Set(
            (appModel?.managedDisks ?? [])
                .filter { StorageVolumeSelection.isDiskImageProtocol($0.protocolName) }
                .map(\.mount)
        )
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [DetectedRemovableMediaVolume] in
                let urls = FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: [
                        .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsBrowsableKey,
                        .volumeIsReadOnlyKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                    ],
                    options: [.skipHiddenVolumes]
                ) ?? []
                return urls.compactMap {
                    RemovableMediaDetector.inspectVolume(
                        at: $0,
                        registeredRootPaths: registeredPaths,
                        diskImageMounts: diskImageMounts
                    )
                }
            }.value
            guard let self else { return }
            let previousByMount = Dictionary(uniqueKeysWithValues: self.detectedVolumes.map { ($0.mountPath, $0) })
            self.detectedVolumes = found.map { vol in
                if let prev = previousByMount[vol.mountPath] {
                    return DetectedRemovableMediaVolume(
                        mountPath: vol.mountPath,
                        volumeName: vol.volumeName,
                        detectedHints: vol.detectedHints,
                        totalBytes: vol.totalBytes,
                        freeBytes: vol.freeBytes,
                        isReadOnly: vol.isReadOnly,
                        detectedAt: prev.detectedAt
                    )
                }
                return vol
            }
            let previousSelected = self.selectedMountPath
            if self.selectedMountPath.isEmpty ||
                !self.selectedMountPath.hasPrefix("/Volumes/") ||
                !FileManager.default.fileExists(atPath: self.selectedMountPath) {
                let nextSelected = self.detectedVolumes.first?.mountPath ?? ""
                if nextSelected != previousSelected {
                    self.cancelPendingScan()
                    self.selectedMountPath = nextSelected
                    self.clearNonRunningState()
                }
            }
        }
    }

    func dismissBanner(for mountPath: String) {
        dismissedBannerMounts.insert(mountPath)
    }

    func selectSourcePath(_ path: String, triggerScan: Bool = true) {
        guard !isImporting else { return }
        let normalized = RemovableMediaImportPolicy.normalizedPath(path)
        cancelPendingScan()
        selectedMountPath = normalized
        clearNonRunningState()
        if triggerScan && connected && !normalized.isEmpty {
            scanSelectedVolume()
        }
    }

    func openImport(for mountPath: String, appModel: AppModel) {
        if !isImporting {
            selectSourcePath(mountPath, triggerScan: false)
        }
        syncDefaults(from: appModel)
        appModel.navigateToStorageDetail(.mediaImport)
        if connected && !isImporting && !selectedMountPath.isEmpty {
            scanSelectedVolume()
        }
    }

    func syncDefaults(from appModel: AppModel) {
        let onlineRoots = appModel.personalSpaces.roots.filter(\.online)
        if !onlineRoots.contains(where: { $0.rootID == selectedRootID }) {
            selectedRootID = onlineRoots.first(where: \.isDefault)?.rootID ?? onlineRoots.first?.rootID ?? ""
        }
        let eligible = eligibleUsers(in: appModel.personalSpaces.users, for: selectedRootID, roots: onlineRoots)
        if !eligible.contains(where: { $0.id == selectedUserID }) {
            selectedUserID = eligible.first?.id ?? 0
        }
        let categories = allocatedCategories(
            for: selectedUserID,
            in: appModel.personalSpaces.users,
            rootID: selectedRootID,
            roots: onlineRoots
        )
        let validated = RemovableMediaImportPolicy.validatedCategory(
            selectedCategory,
            allocatedLocationCategories: categories
        )
        if selectedCategory != validated {
            selectedCategory = validated
        }
    }

    func eligibleUsers(
        in users: [NativeSpaceUserEntry],
        for rootID: String,
        roots: [NativeSpaceRootInfo]
    ) -> [NativeSpaceUserEntry] {
        guard let root = roots.first(where: { $0.rootID == rootID && $0.online }) else { return [] }
        return users.filter { entry in
            entry.user.enabled && entry.policy.locations.contains(where: {
                $0.rootID == root.rootID && $0.rootGeneration == root.generation
            })
        }
    }

    func allocatedCategories(
        for userID: Int64,
        in users: [NativeSpaceUserEntry],
        rootID: String,
        roots: [NativeSpaceRootInfo]
    ) -> Set<String> {
        guard let root = roots.first(where: { $0.rootID == rootID && $0.online }),
              let user = users.first(where: { $0.id == userID && $0.user.enabled }) else {
            return []
        }
        return Set(user.policy.locations.compactMap { loc in
            (loc.rootID == root.rootID && loc.rootGeneration == root.generation) ? loc.category : nil
        })
    }

    func pickCustomSourceFolder() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = "选择媒体目录"
        panel.message = "请选择位于 /Volumes/ 下的外置存储卡或读卡器目录（仅只读扫描，绝不修改原件）。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pickedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        selectSourcePath(pickedPath, triggerScan: true)
    }

    func scanSelectedVolume() {
        guard connected, !selectedMountPath.isEmpty, !isImporting else { return }
        let requestID = Self.makeRequestID()
        pendingScanRequestID = requestID
        scanning = true
        errorMessage = nil
        infoMessage = nil
        guard send(operation: "scan", payload: MediaImportRequestPayload(
            requestID: requestID,
            sourcePath: selectedMountPath
        )) else {
            cancelPendingScan()
            return
        }
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.scanRequestTimeout) } catch { return }
            guard let self, self.scanning, self.pendingScanRequestID == requestID else { return }
            self.scanning = false
            self.pendingScanRequestID = nil
            self.errorMessage = "扫描存储卡超时，请确认读卡器连接稳定后重试。"
        }
    }

    func startImport(roots: [NativeSpaceRootInfo], users: [NativeSpaceUserEntry]) {
        guard connected, !starting, !isImporting, !selectedMountPath.isEmpty else { return }
        guard let root = roots.first(where: { $0.rootID == selectedRootID && $0.online }) else {
            errorMessage = "请先选择一个在线的目标 NAS 存储盘。"
            return
        }
        guard eligibleUsers(in: users, for: root.rootID, roots: roots).contains(where: { $0.id == selectedUserID }) else {
            errorMessage = "所选成员在该硬盘尚未分配照片或视频空间，请先在「个人空间」完成分配。"
            return
        }
        let requestID = Self.makeRequestID()
        starting = true
        pendingStartRequestID = requestID
        jobStatus = nil
        errorMessage = nil
        infoMessage = nil
        guard send(operation: "start", payload: MediaImportRequestPayload(
            requestID: requestID,
            sourcePath: selectedMountPath,
            rootID: root.rootID,
            generation: root.generation,
            userID: selectedUserID,
            category: selectedCategory.rawValue,
            archiveMode: selectedArchiveMode.rawValue,
            subfolder: subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        )) else {
            clearPendingStart()
            return
        }
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.startRequestTimeout) } catch { return }
            guard let self, self.starting, self.pendingStartRequestID == requestID else { return }
            self.clearPendingStart()
            self.errorMessage = "启动导入超时，请确认后台服务正常后重试；存储卡原件未受影响。"
        }
    }

    func cancelImport() {
        guard connected, let jobID = jobStatus?.jobID, jobStatus?.phase == "running" else { return }
        let requestID = Self.makeRequestID()
        _ = send(operation: "cancel", payload: MediaImportRequestPayload(requestID: requestID, jobID: jobID))
        infoMessage = "已请求取消导入，正在安全收尾当前文件…"
    }

    func consume(_ encoded: String) {
        guard let data = Data(base64URLEncoded: encoded),
              let header = try? JSONDecoder().decode(MediaImportEnvelopeHeader.self, from: data) else {
            return
        }
        switch header.operation {
        case "scan":
            guard let expectedID = pendingScanRequestID, header.requestID == expectedID else { return }
            cancelPendingScan()
            if let err = header.error, !err.isEmpty {
                scanResult = nil
                errorMessage = RemovableMediaDetector.userFacingError(for: err)
            } else if let env = try? JSONDecoder().decode(MediaImportTypedEnvelope<MediaImportScanResult>.self, from: data),
                      let result = env.result {
                guard RemovableMediaImportPolicy.pathsMatch(result.sourcePath, selectedMountPath) else { return }
                scanResult = result
                errorMessage = nil
                if result.totalFiles == 0 {
                    infoMessage = "未在该目录中发现可导入的照片、RAW 或视频文件。"
                }
            }
        case "start", "progress", "complete":
            clearPendingStart()
            if let env = try? JSONDecoder().decode(MediaImportTypedEnvelope<MediaImportJobStatus>.self, from: data),
               let status = env.result {
                jobStatus = status
                if let err = header.error, !err.isEmpty {
                    errorMessage = RemovableMediaDetector.userFacingError(for: err)
                } else if let lastErr = status.lastError, !lastErr.isEmpty, status.phase != "running" {
                    errorMessage = RemovableMediaDetector.userFacingError(for: lastErr)
                } else if header.operation == "complete" {
                    errorMessage = nil
                }
                if header.operation == "complete" {
                    handleImportCompleted(status)
                }
            } else if let err = header.error, !err.isEmpty {
                errorMessage = RemovableMediaDetector.userFacingError(for: err)
            }
        case "cancel":
            if let env = try? JSONDecoder().decode(MediaImportTypedEnvelope<MediaImportCancelResult>.self, from: data),
               env.result?.cancelled == true {
                infoMessage = "正在中止导入，存储卡原件不会被修改。"
            }
        default:
            break
        }
    }

    private func handleImportCompleted(_ status: MediaImportJobStatus) {
        if status.importedFiles > 0 {
            appModel?.personalSpaces.refresh()
        }
        appModel?.refreshManagedDisks()
        let truncated = RemovableMediaImportPolicy.isTruncated(scan: scanResult, status: status)
        if status.phase == "cancelled" {
            infoMessage = "导入已取消（已入库 \(status.importedFiles) 项，跳过 \(status.skippedFiles) 项），存储卡原件未受影响。"
        } else if RemovableMediaImportPolicy.hasPartialErrors(status) {
            infoMessage = nil
            if errorMessage == nil {
                errorMessage = "部分文件导入未完成（失败 \(status.failedFiles) 项，已入库 \(status.importedFiles) 项，跳过 \(status.skippedFiles) 项），存储卡原件未被删除，请检查原因后重试。"
            }
        } else if status.allVerified && !truncated {
            infoMessage = "全部 \(status.totalFiles) 项媒体已核验入库（新导入 \(status.importedFiles) 项，跳过已存在 \(status.skippedFiles) 项），存储卡原件未被修改。"
        } else if status.allVerified && truncated {
            infoMessage = "前 \(status.totalFiles) 项媒体已入库（新导入 \(status.importedFiles) 项，跳过已存在 \(status.skippedFiles) 项）；因超出 \(RemovableMediaImportPolicy.maxScanFilesDisplay) 项上限仍有未扫描文件，存储卡原件未被修改，暂不标记为可安全弹出。"
        }
    }

    private func clearNonRunningState() {
        scanResult = nil
        if !isImporting {
            jobStatus = nil
        }
        errorMessage = nil
        infoMessage = nil
    }

    private func cancelPendingScan() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        pendingScanRequestID = nil
        scanning = false
    }

    private func clearPendingStart() {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        pendingStartRequestID = nil
        starting = false
    }

    private static func makeRequestID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(requestIDLength))
    }

    @discardableResult
    private func send(operation: String, payload: MediaImportRequestPayload) -> Bool {
        guard let sender, let data = try? JSONEncoder().encode(payload) else {
            errorMessage = UserFacingErrorMapper.coreIPCCommandError(action: "存储卡导入指令")
            return false
        }
        do {
            try sender("media-import \(operation) \(data.base64URLEncodedString)\n")
            return true
        } catch {
            errorMessage = UserFacingErrorMapper.coreIPCCommandError(action: "存储卡导入指令")
            return false
        }
    }
}
