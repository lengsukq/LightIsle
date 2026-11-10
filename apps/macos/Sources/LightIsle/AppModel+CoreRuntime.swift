import AppKit
import Foundation

@MainActor
extension AppModel {
    // MARK: - Core runtime

    func decodeAdminUsername(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let username = String(data: data, encoding: .utf8),
              !username.isEmpty, username.utf8.count <= 32 else { return nil }
        return username
    }

    func launch() {
        guard core == nil, !stopping else { return }
        coreRestartTask?.cancel()
        coreRestartTask = nil
        coreRestartAttempts = 0
        startCoreProcess()
    }

    private func startCoreProcess() {
        #if DEBUG
        if isPresentationPreview { preparePresentationPreview(); return }
        #endif
        guard core == nil, !stopping else { return }
        diskOperationDeadline?.cancel()
        diskOperationPending = false
        managedDisks = []
        offlineCleanupPending = false
        offlineSharedFolderPath = nil
        clearPendingStorageSelection()
        cancelStartupDeadline()
        finishRemoteChange()
        coreOutputFramer.reset()
        lastShareStatusPollAt = .distantPast
        cancelScheduledIndexRefresh()
        rootManagement.disconnect()
        personalSpaces.disconnect()
        endServicePolling()
        directoryWatcher?.stop()
        directoryWatcher = nil
        sharedFolderPath = nil
        if exportRunning {
            exportMessage = "Go Core 已停止，跨磁盘复制已中断；原文件不会自动删除，请检查目标磁盘有无未发布的临时副本。"
        }
        exportRunning = false
        guard let bootstrap = CoreProcessBootstrap.make(
            port: preferredLocalPort,
            thumbnailCacheMiB: preferredThumbnailCacheMiB
        ) else {
            state = .error("未找到内置的 Go Core。请使用 scripts/build-macos.sh 构建应用。")
            return
        }
        let process = bootstrap.process
        let generation = bootstrap.generation
        let input = bootstrap.input
        let output = bootstrap.output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.coreGeneration == generation else { return }
                self.consume(bytes)
            }
        }
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in self?.childDidExit(status: status, generation: generation) }
        }

        do {
            try process.run()
            core = process
            coreGeneration = generation
            inputPipe = input
            outputPipe = output
            resetCoreRuntimeSnapshot()
            // A new Core must replay the remembered LAN choice. Never carry
            // an old process's pending command into the new generation.
            finishRemoteChange()
            lastAutomaticLANAttemptAt = .distantPast
            frpAutoRestoreAttempted = false
            tunnelAutoRestoreAttempted = false
            prefersFRPEnabled = FRPPersistencePolicy.isPreferred()
            prefersTunnelMode = TunnelPersistencePolicy.preferredMode()
            remoteError = nil
            sharedFolderPath = nil
            exportRunning = false
            exportMessage = nil
            metricHistory = []
            initializing = false
            initializationError = nil
            backupSchedule = nil
            firstAdminUsername = nil
            state = .starting
            details = "等待本机 Go Core 提供健康检查服务。"
            beginServicePolling()
            startStartupDeadline(generation: generation)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            state = .error("启动 Go Core 失败：\(error.localizedDescription)")
            details = "检查应用签名、端口是否被占用及内置的 Go Core。"
        }
    }

    /// Rebind all native-only services after the authenticated loopback Core
    /// reports READY. This is deliberately distinct from line decoding.
    func handleCoreReady(_ url: URL) {
            endpoint = url
            cancelStartupDeadline()
            state = .online
            coreReadyUptime = ProcessInfo.processInfo.systemUptime
            details = "本机 Go Core 已就绪；如尚未初始化，将显示原生管理员设置页面。"
            // READY and CONFIGURED are separate IPC lines; either may arrive
            // first, so both paths attempt the idempotent default activation.
            enablePreferredLANIfReady()
            // The fresh Core knows nothing about the tunnel API token; the
            // Keychain copy is re-validated once so the UI stays usable.
            if TunnelSecretVault.load() != nil {
                loadTunnelSecretAndResend()
            }
            // Same for the TMDB token; when none is stored just sync the
            // configured flag so the settings row reflects Core reality.
            loadTmdbSecretAndResend()
            loadMapSecretAndResend()
            // Outbound notification channels follow the identical lifecycle.
            loadNotifySecretAndResend()
            refreshTrashRetention()
            if tunnelSelectedID == nil {
                tunnelSelectedID = TunnelPersistencePolicy.selectedTunnelID()
            }
            refreshTunnel()
            refreshFRP()
            refreshSMBState()
            rootManagement.onDefaultChanged = { [weak self] root in
                self?.applyRegisteredDefault(root)
            }
            rootManagement.onRootsChanged = { [weak self] roots in
                self?.updateAdditionalDirectoryWatchers(roots)
                self?.personalSpaces.refresh()
            }
            rootManagement.connect { [weak self] command in
                guard let self, self.state == .online, let pipe = self.inputPipe else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try pipe.fileHandleForWriting.write(contentsOf: Data(command.utf8))
            }
            personalSpaces.connect { [weak self] command in
                guard let self, self.state == .online, let pipe = self.inputPipe else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try pipe.fileHandleForWriting.write(contentsOf: Data(command.utf8))
            }
    }

    /// The old share-status IPC is retained for launch compatibility only.
    /// The live directory path and watcher follow the verified RootRegistry
    /// default; switching roots stops the previous FSEvents source.
    private func applyRegisteredDefault(_ root: NativeSharedRoot?) {
        let onlinePath = root?.online == true ? root?.path : nil
        let offlinePath = root?.online == false ? root?.path : nil
        guard sharedFolderPath != onlinePath || offlineSharedFolderPath != offlinePath else { return }
        cancelScheduledIndexRefresh()
        directoryWatcher?.stop()
        directoryWatcher = nil
        sharedFolderPath = onlinePath
        offlineSharedFolderPath = offlinePath
        if let onlinePath {
            sharedFolderError = nil
            directoryWatcher = DirectoryChangeWatcher(path: onlinePath) { [weak self] paths, full in
                self?.scheduleIndexRefresh(paths: paths, needsFull: full)
            }
        } else {
            sharedFolderError = root == nil
                ? "尚未设置默认 NAS 存储，请在存储管理中选择已登记的目录。"
                : "默认存储目录已离线或物理身份变化，请连接原硬盘后重新验证。"
        }
    }

    /// Core runtime snapshot is invalid when the child exits or a fresh
    /// generation begins. Centralizing this reset avoids accidentally showing
    /// one disk's stale metrics or a previous generation's LAN address.
    private func resetCoreRuntimeSnapshot() {
        endpoint = nil
        remoteAddress = nil
        remoteFingerprint = nil
        isConfigured = nil
        metrics = nil
        backupStatus = nil
        backupError = nil
        backupInventoryLoading = false
        backupInventory = nil
        smbListening = nil
        smbState = nil
        smbBusy = false
        smbError = nil
        smbNotice = nil
    }

    /// In-memory credentials, disk operation results and tunnel state must not
    /// survive an old child generation. This applies to both abnormal exits
    /// and an explicit Stop; neither path may leave stale UI authorization.
    private func resetCorePeripheralState() {
        diskOperationDeadline?.cancel()
        if diskOperationPending { diskManagementError = "Core 已退出，磁盘操作结果未知，请重新启动并刷新。" }
        diskOperationPending = false
        managedDisks = []
        tunnelState = nil
        frpState = nil
        frpError = nil
        frpAutoRestoreAttempted = false
        tunnelAutoRestoreAttempted = false
        frpVersions = []
        frpVersionsLoading = false
        selectedFRPVersion = ""
        tunnelAPIBusy = false
        tunnelCredential.cancelPending()
        // Core credentials are memory-only. A new Core process must revalidate
        // the saved Keychain token; retaining the old configured flag would
        // suppress the resend and make tunnel management silently unusable.
        tunnelAPITokenConfigured = false
        tunnelAccounts = []
        tunnelZones = []
        tunnelList = []
        tunnelIngress = []
        tunnelSelectedID = TunnelPersistencePolicy.selectedTunnelID()
        if offlineCleanupPending {
            offlineCleanupMessage = "Core 中断，无法确认离线盘清理状态。重启后检查当前共享路径及元数据。"
        }
        offlineCleanupPending = false
        if storageSelectionPending {
            storageSelectionMessage = "Core 已退出，无法确认存储切换结果；请重新启动并检查当前目录。"
        }
        clearPendingStorageSelection()
    }

    /// Release process-owned watchers, IPC pipes and metrics as a single
    /// lifecycle boundary. The user's settings and Keychain are unaffected.
    private func releaseCoreRuntime() {
        cancelStartupDeadline()
        coreOutputFramer.reset()
        cancelScheduledIndexRefresh()
        endServicePolling()
        rootManagement.disconnect()
        personalSpaces.disconnect()
        // A late termination callback from a completed stop must not change
        // the app back to an error state.
        directoryWatcher?.stop()
        directoryWatcher = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        inputPipe = nil
        core = nil
        coreGeneration = nil
        resetCoreRuntimeSnapshot()
        initializing = false
    }

    private func childDidExit(status: Int32, generation: UUID) {
        guard core != nil, coreGeneration == generation else { return }
        let readyUptime = coreReadyUptime
        coreReadyUptime = nil
        resetCorePeripheralState()
        releaseCoreRuntime()
        // A late termination callback from a completed stop must not change
        // the app back to an error state.
        guard !stopping else { return }
        state = .error("Go Core 异常退出，退出码 \(status)")
        details = "后端已停止。可点击“重新启动”恢复服务。"
        guard let readyUptime else { return }
        if ProcessInfo.processInfo.systemUptime - readyUptime >= 300 {
            coreRestartAttempts = 0
        }
        let delays = [2, 10, 30]
        guard coreRestartAttempts < delays.count else { return }
        let delay = delays[coreRestartAttempts]
        coreRestartAttempts += 1
        details = "后端意外停止，将在 \(delay) 秒后尝试恢复。"
        coreRestartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.core == nil, !self.stopping else { return }
            self.coreRestartTask = nil
            self.startCoreProcess()
        }
    }

    func stop() async {
        coreRestartTask?.cancel()
        coreRestartTask = nil
        coreRestartAttempts = 0
        coreReadyUptime = nil
        cancelStartupDeadline()
        cancelScheduledIndexRefresh()
        endServicePolling()
        rootManagement.disconnect()
        guard let process = core else { state = .offline; return }
        directoryWatcher?.stop()
        directoryWatcher = nil
        stopping = true
        state = .stopping
        endpoint = nil
        await CoreProcessBootstrap.stop(
            process: process, input: inputPipe, output: outputPipe)
        resetCorePeripheralState()
        releaseCoreRuntime()
        stopping = false
        state = .offline
    }
}

#if DEBUG
@MainActor
extension AppModel {
/// Local QA fixtures never spawn Core, access real NAS paths or advertise
    /// services. Release builds do not expose this entry point.
    private func preparePresentationPreview() {
        guard isPresentationPreview else { return }
        let scenario = Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignScenario") as? String ?? "ready"
        state = scenario == "failure" ? .error("无法连接本机核心服务，请检查后重新启动。") : .online
        isConfigured = scenario == "setup" ? false : scenario == "loading" || scenario == "failure" ? nil : true
        details = "正在连接本机服务；原始文件保持在存储目录中。"
        endpoint = URL(string: "http://127.0.0.1:16666")
        remoteAddress = "http://192.168.1.20:16666"
        remoteFingerprint = nil
        sharedFolderName = "家庭资料"
        sharedFolderPath = scenario == "offline" || scenario == "empty" ? nil : "/Volumes/家庭资料/LightIsle"
        offlineSharedFolderPath = scenario == "offline" ? "/Volumes/家庭资料/LightIsle" : nil
        firstAdminUsername = "管理员"
        metrics = scenario == "loading" || scenario == "empty" ? nil : HostMetrics(
            hostname: "家里的 Mac", architecture: "arm64", cpuCount: 12, cpuPercent: 8.4,
            memoryTotal: 51_539_607_552, memoryUsed: 18_253_611_008,
            diskTotal: 1_000_000_000_000, diskFree: 622_000_000_000,
            volumes: [HostVolume(name: "Macintosh HD", mount: "/", device: "disk1s1", filesystem: "APFS", total: 1_000_000_000_000, free: 622_000_000_000, readOnly: false),
                      HostVolume(name: "家庭资料", mount: "/Volumes/家庭资料", device: "disk9s1", filesystem: "APFS", total: 4_000_000_000_000, free: 2_400_000_000_000, readOnly: false)],
            networkDownBps: 245_000, networkUpBps: 83_000, diskIo: nil, corePid: nil, coreRssBytes: 26_214_400,
            processes: nil, processesAvailable: false)
        lastMetricsAt = metrics == nil ? nil : Date()
        storageThreshold = StorageThreshold(freeMiB: 2048, percent: 5)
        managedDisks = scenario == "empty" ? [] : [ManagedDisk(id: "preview-disk", name: "家庭资料", mount: "/Volumes/家庭资料", parent: "preview", filesystem: "APFS", protocolName: "USB", smart: "未知（设计预览）", total: 4_000_000_000_000, free: 2_400_000_000_000, readOnly: false, mounted: scenario != "offline", external: true, identity: "")]
        activeAlerts = scenario == "offline" ? [CorePersistentAlert(code: "storage_offline", severity: "warning", message: "家庭资料磁盘未连接。请检查供电与数据线，然后重新连接原目录。", active: true, acknowledged: false)] : []
    }
}
#endif
