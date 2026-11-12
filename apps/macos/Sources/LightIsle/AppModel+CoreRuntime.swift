import AppKit
import Foundation
import OSLog

private let supervisorLog = Logger(subsystem: "top.lengsu.lightisle", category: "CoreSupervisor")

@MainActor
extension AppModel {
    // MARK: - Core runtime

    func decodeAdminUsername(_ raw: String) -> String? {
        guard let data = Data(base64URLEncoded: raw),
              let username = String(data: data, encoding: .utf8),
              !username.isEmpty, username.utf8.count <= 32 else { return nil }
        return username
    }

    func launchInitiallyIfNeeded() {
        guard !initialCoreLaunchAttempted else { return }
        initialCoreLaunchAttempted = true
        launch()
    }

    func launch() {
        guard !stopping, !corePortRecoveryBusy else { return }
        if core != nil {
            guard case .error = state else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stop()
                if self.core == nil { self.launch() }
            }
            return
        }
        coreRestartTask?.cancel()
        coreRestartTask = nil
        coreSupervisor = CoreSupervisorPolicy()
        coreDesiredRunning = true
        startCoreProcess()
    }

    private func startCoreProcess() {
        #if DEBUG
        if isPresentationPreview { preparePresentationPreview(); return }
        #endif
        guard coreDesiredRunning, core == nil, !stopping else { return }
        recordBetaLifecycle(.coreStarting)
        if corePortConflict != nil { portError = nil }
        corePortConflict = nil
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
        rootManagement.disconnect()
        rootWatchersInitialized = false
        personalSpaces.disconnect()
        appsCenter.disconnect()
        endServicePolling()
        sharedFolderPath = nil
        if exportRunning {
            exportMessage = "Go Core 已停止，跨磁盘复制已中断；原文件不会自动删除，请检查目标磁盘有无未发布的临时副本。"
        }
        exportRunning = false
        let port = preferredLocalPort
        guard let bootstrap = CoreProcessBootstrap.make(
            port: port,
            thumbnailCacheMiB: preferredThumbnailCacheMiB
        ) else {
            handleCoreFailure("未找到内置的核心服务，请重新安装轻屿。", startupBlocked: true)
            return
        }
        let process = bootstrap.process
        let generation = bootstrap.generation
        let input = bootstrap.input
        let output = bootstrap.output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in
                guard let self, self.coreGeneration == generation, !self.stopping else { return }
                self.consume(bytes)
            }
        }
        process.terminationHandler = { [weak self] child in
            child.terminationHandler = nil
            let status = child.terminationStatus
            let signaled = child.terminationReason == .uncaughtSignal
            Task { @MainActor [weak self] in
                self?.childDidExit(status: status, signaled: signaled, generation: generation, port: port)
            }
        }

        do {
            let commands = try CoreCommandWriter(input.fileHandleForWriting) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.coreGeneration == generation, !self.stopping else { return }
                    self.coreCommandWarning = true
                    supervisorLog.warning("Core command pipe saturated or disconnected")
                }
            }
            try process.run()
            core = process
            coreGeneration = generation
            coreCommands = commands
            coreCommandWarning = false
            coreServiceWarnings = []
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
            process.terminationHandler = nil
            output.fileHandleForReading.readabilityHandler = nil
            handleCoreFailure("无法启动核心服务。请检查轻屿是否完整安装。", startupBlocked: true)
        }
    }

    /// Rebind all native-only services after the authenticated loopback Core
    /// reports READY. This is deliberately distinct from line decoding.
    func handleCoreReady(_ url: URL) {
            guard state == .starting, let generation = coreGeneration, !stopping else { return }
            try? coreCommands?.write(contentsOf: Data("computer-files status\n".utf8))
            endpoint = url
            cancelStartupDeadline()
            state = .online
            recordBetaLifecycle(.coreReady)
            coreSupervisor.markReady(at: ProcessInfo.processInfo.systemUptime)
            startCoreHealthMonitor(endpoint: url, generation: generation)
            if coreSupervisor.attempts > 0 {
                supervisorLog.notice("Core recovered after \(self.coreSupervisor.attempts) attempt(s)")
            }
            details = "本机 Go Core 已就绪；如尚未初始化，将显示原生管理员设置页面。"
            // READY and CONFIGURED are separate IPC lines; either may arrive
            // first, so both paths attempt the idempotent default activation.
            enablePreferredLANIfReady()
            if tunnelSelectedID == nil {
                tunnelSelectedID = TunnelPersistencePolicy.selectedTunnelID()
            }
            // Query local supervisor states before outbound API token validation
            // so tunnelState and frpState are populated immediately.
            refreshTunnel()
            refreshFRP()
            refreshSMBState()
            refreshTrashRetention()
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
            rootManagement.onDefaultChanged = { [weak self] root in
                self?.applyRegisteredDefault(root)
            }
            rootManagement.onRootsChanged = { [weak self] roots in
                self?.updateRootDirectoryWatchers(roots)
                self?.clearStaleTimeMachineCoverage()
                self?.personalSpaces.refresh()
                self?.externalVolumeCoordinator.auditOnlineExternalRootsIfNeeded(roots)
            }
            rootManagement.connect { [weak self] command in
                guard let self, self.state == .online, let pipe = self.coreCommands else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try pipe.write(contentsOf: Data(command.utf8))
            }
            personalSpaces.connect { [weak self] command in
                guard let self, self.state == .online, let pipe = self.coreCommands else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try pipe.write(contentsOf: Data(command.utf8))
            }
            appsCenter.connect { [weak self] command in
                guard let self, self.state == .online, let pipe = self.coreCommands else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try pipe.write(contentsOf: Data(command.utf8))
            }
    }

    /// Display the default binding while the root-bound watchers handle
    /// changes for all verified online roots.
    private func applyRegisteredDefault(_ root: NativeSharedRoot?) {
        let onlinePath = root?.online == true ? root?.path : nil
        let offlinePath = root?.online == false ? root?.path : nil
        guard sharedFolderPath != onlinePath || offlineSharedFolderPath != offlinePath else { return }
        sharedFolderPath = onlinePath
        offlineSharedFolderPath = offlinePath
        if onlinePath != nil {
            sharedFolderError = nil
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
        diskHealthReports = [:]
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
        tmdbCoreAcknowledged = false
        tmdbTokenConfigured = false
        tmdbTokenBusy = false
        mapCoreAcknowledged = false
        mapKeyConfigured = false
        mapKeyBusy = false
        notifyCoreAcknowledged = false
        notifyConfigured = false
        notifyBusy = false
        notifyStats = nil
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
        computerFilesEnabled = nil
        cancelStartupDeadline()
        coreHealthTask?.cancel()
        coreHealthTask = nil
        coreOutputFramer.reset()
        endServicePolling()
        rootManagement.disconnect()
        rootWatchersInitialized = false
        personalSpaces.disconnect()
        appsCenter.disconnect()
        // A late termination callback from a completed stop must not change
        // the app back to an error state.
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        coreCommands?.close()
        coreCommands = nil
        core?.terminationHandler = nil
        core = nil
        coreGeneration = nil
        resetCoreRuntimeSnapshot()
        initializing = false
    }

    private func startCoreHealthMonitor(endpoint: URL, generation: UUID) {
        coreHealthTask?.cancel()
        coreHealthTask = Task { @MainActor [weak self] in
            let probe = CoreHealthProbe()
            defer { probe.close() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(CoreSupervisorPolicy.probeInterval)) }
                catch { return }
                let healthy = await probe.check(endpoint)
                guard let self, !Task.isCancelled, self.coreGeneration == generation,
                      self.state == .online, !self.stopping else { return }
                if self.coreSupervisor.recordProbe(healthy: healthy) {
                    self.recoverUnresponsiveCore(generation: generation, expected: .online, message: "核心服务连续三次未响应本机健康检查。")
                    return
                }
            }
        }
    }

    func recoverUnresponsiveCore(generation: UUID, expected: CoreState, message: String) {
        // The task that detects the timeout must not cancel its own shutdown waits.
        Task { @MainActor [weak self] in
            guard let self, self.coreGeneration == generation, self.state == expected,
                  !self.stopping, self.coreDesiredRunning else { return }
            self.details = message + " 正在停止旧进程。"
            if await self.terminateCurrentCore() {
                self.handleCoreFailure(message)
            }
        }
    }

    private func childDidExit(status: Int32, signaled: Bool, generation: UUID, port: Int) {
        guard core != nil, coreGeneration == generation, !stopping else { return }
        let blocker = !signaled && state == .starting ? CoreSupervisorPolicy.startupBlocker(exitCode: status) : nil
        resetCorePeripheralState()
        releaseCoreRuntime()
        guard coreDesiredRunning else {
            if case .error = state {
                details = "旧核心进程已经退出，可以手动重新启动。"
            } else {
                state = .offline
            }
            return
        }
        let code = signaled ? "信号" : "退出码"
        handleCoreFailure(blocker ?? "核心服务意外结束（\(code) \(status)）。", startupBlocked: blocker != nil)
        if blocker != nil, status == CoreSupervisorPolicy.portInUseExitCode {
            corePortConflict = port
            details = "可以换一个端口启动，或查看当前占用者。"
        }
    }

    private func handleCoreFailure(_ message: String, startupBlocked: Bool = false) {
        guard coreDesiredRunning else { state = .offline; return }
        coreLastIncident = message
        recordBetaLifecycle(startupBlocked ? .coreStartupBlocked : .coreFailed)
        supervisorLog.error("\(message, privacy: .private)")
        state = .error(message)
        let delay = coreSupervisor.nextRetry(at: ProcessInfo.processInfo.systemUptime, startupBlocked: startupBlocked)
        guard let delay else {
            details = coreSupervisor.attempts >= CoreSupervisorPolicy.delays.count && !startupBlocked
                ? "已尝试自动恢复 3 次。请检查问题后手动重试。"
                : "请检查上述问题，然后手动重试。"
            return
        }
        let attempt = coreSupervisor.attempts
        details = "\(delay) 秒后自动恢复（第 \(attempt)/\(CoreSupervisorPolicy.delays.count) 次）。"
        supervisorLog.notice("Scheduling Core recovery attempt \(attempt) in \(delay) seconds")
        coreRestartTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !Task.isCancelled, self.coreDesiredRunning, self.core == nil, !self.stopping else { return }
            self.coreRestartTask = nil
            self.startCoreProcess()
        }
    }

    func stop() async {
        coreDesiredRunning = false
        corePortConflict = nil
        coreRestartTask?.cancel()
        coreRestartTask = nil
        coreSupervisor = CoreSupervisorPolicy()
        if stopping {
            while stopping && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        if await terminateCurrentCore() {
            state = .offline
            recordBetaLifecycle(.coreStopped)
            details = "轻屿服务已停止。"
        }
    }

    private func terminateCurrentCore() async -> Bool {
        cancelStartupDeadline()
        coreHealthTask?.cancel()
        coreHealthTask = nil
        endServicePolling()
        rootManagement.disconnect()
        rootWatchersInitialized = false
        guard let process = core else { return true }
        stopping = true
        state = .stopping
        endpoint = nil
        coreCommands?.close()
        let stopped = await Task.detached { await CoreProcessBootstrap.stop(process: process) }.value
        stopping = false
        guard stopped else {
            coreDesiredRunning = false
            let message = "旧核心进程尚未退出。请检查 Mac 的磁盘或系统状态，再手动重试。"
            coreLastIncident = message
            state = .error(message)
            details = "轻屿会等旧进程结束后再启动服务。"
            supervisorLog.error("Core remained alive after stop escalation")
            return false
        }
        resetCorePeripheralState()
        releaseCoreRuntime()
        return true
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
