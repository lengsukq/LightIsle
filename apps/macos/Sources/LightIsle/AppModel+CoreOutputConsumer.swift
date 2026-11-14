import AppKit
import Foundation

@MainActor
extension AppModel {
    /// Configuration IPC updates have one lifecycle and decode policy.
    /// Core's other status signals are handled separately in consume(_:).
    func consumeSettingsIPC(_ line: String) -> Bool {
        guard let event = CoreIPCSettingsEvent.decode(line) else { return false }
        switch event {
        case .mapState(let configured):
            if let configured {
                if mapKeyConfigured != configured { mapKeyConfigured = configured }
                if !mapCoreAcknowledged { mapCoreAcknowledged = true }
                if mapKeyBusy { mapKeyBusy = false }
                if mapKeyError != nil { mapKeyError = nil }
            }
        case .mapError:
            if mapKeyBusy { mapKeyBusy = false }
            let message = "Core 未能接收天地图 Key，请重新保存或重启服务。"
            if mapKeyError != message { mapKeyError = message }
        case .frpState(let state):
            if let state {
                if frpState != state { frpState = state }
                autoRestoreFRPIfReady(state)
            }
        case .frpVersions(let releases):
            if frpVersionsLoading { frpVersionsLoading = false }
            if let releases {
                let available = releases.filter(\.installable)
                frpVersions = available
                if !available.contains(where: { $0.version == selectedFRPVersion }) {
                    selectedFRPVersion = available.first(where: { !$0.prerelease })?.version ??
                        available.first?.version ?? ""
                }
                if frpError != nil { frpError = nil }
            } else {
                frpError = "FRP 版本列表解析失败，请重试。"
            }
        case .frpError(let reason):
            if frpVersionsLoading { frpVersionsLoading = false }
            if frpError != reason { frpError = reason }
        case .tmdbState(let state):
            if let state {
                if tmdbTokenConfigured != state.configured { tmdbTokenConfigured = state.configured }
                if !tmdbCoreAcknowledged { tmdbCoreAcknowledged = true }
                if tmdbTokenBusy { tmdbTokenBusy = false }
                if tmdbTokenError != nil { tmdbTokenError = nil }
            }
        case .tmdbError(let code):
            if tmdbTokenBusy { tmdbTokenBusy = false }
            let message = code == "invalid_tmdb_token"
                ? "Token 格式不正确：应为 TMDB v4 Read Access Token（长度 20 以上的连续字符串，不含空格换行）。"
                : "TMDB Token 命令失败，请重试。"
            if tmdbTokenError != message { tmdbTokenError = message }
        }
        return true
    }

    /// Apply decoded status reports on the main actor. Unrecognized protocol
    /// commands are intentionally left to the specific lifecycle handlers.
    func consumeReportIPC(_ line: String) -> Bool {
        guard let event = CoreIPCReportEvent.decode(line) else { return false }
        switch event {
        case .alerts(let alerts):
            if let alerts {
                let nextActive = Array(alerts.filter(\.active).prefix(100))
                if activeAlerts != nextActive { activeAlerts = nextActive }
                nativeAlertCoordinator.presentCoreAlerts(Array(alerts.prefix(100)), enabled: nativeAlertsEnabled)
            }
        case .backupInventory(let inventory):
            if backupInventoryLoading { backupInventoryLoading = false }
            if let inventory {
                if backupInventory != inventory { backupInventory = inventory }
            } else {
                let message = "无法读取备份清单，请重试。"
                if backupError != message { backupError = message }
            }
        case .disks(let disks):
            if let disks {
                if managedDisks != disks { managedDisks = disks }
                let validDevices = Set(
                    disks.flatMap { [$0.id, $0.parent] }
                        .filter { !$0.isEmpty }
                        .flatMap { [$0, "/dev/\($0)", $0.replacingOccurrences(of: "/dev/", with: "")] }
                )
                let filteredHealth = diskHealthReports.filter { validDevices.contains($0.key) }
                if diskHealthReports != filteredHealth { diskHealthReports = filteredHealth }
                if diskManagementError != nil { diskManagementError = nil }
            } else {
                let message = "无法解析磁盘状态，请刷新。"
                if diskManagementError != message { diskManagementError = message }
            }
            if diskOperationPending { diskOperationPending = false }
            diskOperationDeadline?.cancel()
        case .diskHealth(let report):
            if let report, diskHealthReports[report.device] != report { diskHealthReports[report.device] = report }
        case .storageThreshold(let threshold):
            if let threshold, storageThreshold != threshold { storageThreshold = threshold }
        case .tunnel(let state):
            if let state {
                if tunnelState != state { tunnelState = state }
                autoRestoreTunnelIfReady()
            }
        case .notify(let stats):
            if let stats {
                if notifyStats != stats { notifyStats = stats }
                if notifyConfigured != stats.configured { notifyConfigured = stats.configured }
                if !notifyCoreAcknowledged { notifyCoreAcknowledged = true }
            }
        case .backupStatus(let report):
            if let report, backupStatus != report { backupStatus = report }
        case .backupSchedule(let schedule):
            if let schedule, backupSchedule != schedule { backupSchedule = schedule }
        case .hostMetrics(let reading):
            if let reading { applyHostMetricsReading(reading) }
        }
        return true
    }

    private func applyHostMetricsReading(_ reading: HostMetrics) {
        nativeAlertCoordinator.checkLowDiskSpace(reading.volumes ?? [], enabled: nativeAlertsEnabled)
        guard samplesManagementUI else { return }
        if metrics != reading { metrics = reading }
        lastMetricsAt = Date()
        metricHistory.append(MetricHistoryPoint(
            time: Date(),
            cpu: reading.cpuPercent ?? 0,
            memory: Double(reading.memoryUsed) / Double(max(reading.memoryTotal, 1)) * 100,
            download: reading.networkDownBps ?? 0,
            upload: reading.networkUpBps ?? 0
        ))
        if metricHistory.count > 120 {
            metricHistory.removeFirst(metricHistory.count - 120)
        }
    }

    func consume(_ bytes: Data) {
        for line in coreOutputFramer.append(bytes) {
            if consumeSettingsIPC(line) || consumeReportIPC(line) || consumeDomainIPC(line) {
                continue
            }
            consumeLifecycleSignal(line)
        }
    }

    func consumeDomainIPC(_ line: String) -> Bool {
        guard let event = CoreIPCDomainEvent.decode(line) else { return false }
        switch event {
        case .subsystem(let channel):
            applySubsystemIPC(channel)
        case .computerFiles(let signal):
            applyComputerFilesIPC(signal)
        case .export:
            break
        case .admin(let signal):
            applyAdminIPC(signal)
        case .disksError(let raw):
            diskOperationPending = false
            diskOperationDeadline?.cancel()
            diskManagementError = "磁盘操作未完成：\(raw)。请刷新并核对硬盘状态。"
        case .alertsThresholdError(let code):
            if code == "invalid_storage_threshold" {
                diskManagementError = "告警阈值无效：绝对剩余空间与百分比不能同时为 0。"
            }
        case .tunnel(let signal):
            applyTunnelIPC(signal)
        case .notify(let signal):
            applyNotifyIPC(signal)
        case .backup(let signal):
            applyBackupIPC(signal)
        case .smb(let signal):
            applySMBIPC(signal)
        case .setup(let signal):
            applySetupIPC(signal)
        case .remoteOn(let address, let fingerprint):
            finishRemoteChange()
            if !address.isEmpty {
                remoteAddress = address
                remoteFingerprint = fingerprint
                remoteError = nil
            }
        case .legacyShare(let signal):
            applyLegacyShareIPC(signal)
        }
        return true
    }

    private func applySubsystemIPC(_ channel: CoreIPCDomainEvent.SubsystemChannel) {
        switch channel {
        case .roots(let payload):
            rootManagement.consume(payload)
        case .spaces(let payload):
            personalSpaces.consume(payload)
        case .apps(let payload):
            appsCenter.consume(payload)
        }
    }

    private func applyComputerFilesIPC(_ signal: CoreIPCDomainEvent.ComputerFilesSignal) {
        switch signal {
        case .state(let enabled):
            if computerFilesEnabled != enabled { computerFilesEnabled = enabled }
            if computerFilesError != nil { computerFilesError = nil }
        case .error:
            let message = "无法保存设置，请检查轻屿服务后重试。"
            if computerFilesError != message { computerFilesError = message }
        }
    }

    private func applyAdminIPC(_ signal: CoreIPCDomainEvent.AdminSignal) {
        switch signal {
        case .account(let raw):
            if let username = decodeAdminUsername(raw) { firstAdminUsername = username }
        case .verified:
            verifyingAdmin = false
            if let credentials = pendingAdminCredentials {
                do {
                    try AdminCredentialVault.save(credentials)
                    administratorSaveSucceeded = true
                    vaultMessage = "管理员身份验证成功，凭据已保存到 Touch ID 保护的钥匙串。"
                } catch {
                    vaultMessage = error.localizedDescription
                }
            }
            pendingAdminCredentials = nil
        case .verifyFailed:
            verifyingAdmin = false
            pendingAdminCredentials = nil
            vaultMessage = "当前轻屿管理员用户名或密码不正确。"
        case .resetSucceeded(let raw):
            resettingAdmin = false
            AdminCredentialVault.remove()
            unlockedAdminCredentials = nil
            pendingAdminCredentials = nil
            if let username = decodeAdminUsername(raw) {
                firstAdminUsername = username
                administratorResetSucceeded = true
                resetAdminMessage = "已重置管理员「\(username)」的密码。请使用该用户名和新密码登录当前 Web，旧登录会话已失效。"
            } else {
                administratorResetSucceeded = true
                resetAdminMessage = "密码已更新，但未能读取账号名称。请确认当前 Web 地址并重新登录。"
            }
        case .resetFailed(let code):
            resettingAdmin = false
            resetAdminMessage = CoreIPCDomainMessages.adminResetError(for: code)
        }
    }

    private func applyTunnelIPC(_ signal: CoreIPCDomainEvent.TunnelSignal) {
        switch signal {
        case .api(let raw):
            if let object = TunnelWireCodec.decodeAPI(raw) {
                applyTunnelPayload(object)
            }
        case .error(let raw):
            if let message = TunnelWireCodec.decodeError(raw) {
                tunnelAPIError = message
            }
            tunnelAPIBusy = false
            tunnelCredential.cancelPending()
        }
    }

    private func applyNotifyIPC(_ signal: CoreIPCDomainEvent.NotifySignal) {
        switch signal {
        case .enabled:
            notifyConfigured = true
            notifyCoreAcknowledged = true
            notifyBusy = false
            notifyError = nil
            refreshNotifyStatus()
        case .disabled:
            notifyConfigured = false
            notifyStats = nil
            notifyCoreAcknowledged = true
            notifyBusy = false
            notifyError = nil
        case .tested:
            notifyTestResult = "测试通知已发送，请在手机或目标服务上确认收到。"
        case .testError(let raw):
            notifyTestResult = "测试通知发送失败：\(Self.decodeBase64URLText(raw) ?? "未知错误")"
        case .configError(let raw):
            notifyBusy = false
            notifyError = CoreIPCDomainMessages.notifyConfigError(for: Self.decodeBase64URLText(raw))
        }
    }

    private func applyBackupIPC(_ signal: CoreIPCDomainEvent.BackupSignal) {
        switch signal {
        case .cancelRequested:
            backupError = "已请求取消任务，正在清理未完成的临时文件。"
        case .scheduleChanged:
            backupError = nil
            sendCoreCommandLine("backup schedule status\n", context: "backup.schedule.status")
        case .started:
            backupError = nil
            nativeAlertCoordinator.clear(key: "backup-failure")
            sendCoreCommandLine("backup status\n", context: "backup.status")
        case .error(let raw):
            backupInventoryLoading = false
            backupError = raw
            notifyImportantEvent("backup-failure", title: "轻屿备份操作失败", message: "备份或恢复操作未完成，请在本机存储页面查看错误。")
        }
    }

    private func applySMBIPC(_ signal: CoreIPCDomainEvent.SMBSignal) {
        switch signal {
        case .listening(let enabled):
            if smbListening != enabled { smbListening = enabled }
        case .state(let encoded):
            smbBusy = false
            if let decoded = SmbElevation.decodeStatus(base64URL: encoded) {
                smbError = nil
                if smbState != decoded { smbState = decoded }
                if smbListening != decoded.serviceEnabled { smbListening = decoded.serviceEnabled }
            }
        case .error(let code):
            smbBusy = false
            smbError = SmbElevation.userFacingError(for: code)
        }
    }

    private func applySetupIPC(_ signal: CoreIPCDomainEvent.SetupSignal) {
        switch signal {
        case .configured(let ready):
            isConfigured = ready
            if ready { enablePreferredLANIfReady() }
        case .initialized:
            initializing = false
            isConfigured = true
            initializationError = nil
            enablePreferredLANIfReady()
        case .initError(let code):
            initializing = false
            let outcome = CoreIPCDomainMessages.initError(for: code)
            if outcome.alreadyConfigured { isConfigured = true }
            initializationError = outcome.message
        }
    }

    private func applyLegacyShareIPC(_ signal: CoreIPCDomainEvent.LegacyShareSignal) {
        switch signal {
        case .enabled(let name):
            sharedFolderName = name
            sharedFolderError = nil
        case .path(let raw):
            applyLegacySharePath(raw)
        case .statusOnline(let online):
            guard !online else { return }
            if sharedFolderPath != nil || sharedFolderError == nil {
                sharedFolderPath = nil
                sharedFolderError = "原共享磁盘已离线或目录身份发生变化，请确认原磁盘后手动点击重新连接。"
                notifyImportantEvent("volume-unavailable", title: "NAS 存储目录不可用",
                                     message: "轻屿已停止显示原共享目录为在线；不会自动改用同名磁盘。")
            }
        case .offlinePath(let encoded):
            if let path = Self.decodeBase64URLText(encoded),
               path.hasPrefix("/"), path.utf8.count <= 4096 {
                offlineSharedFolderPath = path
            }
        case .accessRevoked, .forgot, .forgetError, .forgetWarning:
            break
        case .error(let error):
            sharedFolderError = error
            sharedFolderPath = nil
            notifyImportantEvent("volume-unavailable", title: "NAS 存储目录不可用", message: "共享目录可能已断开连接；LightIsle 不会自动改用其他同名目录。")
        }
    }

    private func applyLegacySharePath(_ raw: String) {
        guard let data = Data(base64URLEncoded: raw),
              let path = String(data: data, encoding: .utf8),
              path.hasPrefix("/") else { return }
        sharedFolderPath = path
        offlineSharedFolderPath = nil
        if timeMachineDiagnostics == nil { refreshTimeMachineDiagnostics() }
        nativeAlertCoordinator.clear(key: "volume-unavailable")
    }

    private func consumeLifecycleSignal(_ line: String) {
        guard let signal = CoreLifecycleSignal.decode(line) else { return }
        switch signal {
        case .remoteOff:
            finishRemoteChange()
            remoteAddress = nil
            remoteFingerprint = nil
        case .remoteError(let message):
            finishRemoteChange()
            remoteError = message
        case .ready(let url):
            handleCoreReady(url)
        case .serviceWarning(let warning):
            if !coreServiceWarnings.contains(warning) { coreServiceWarnings.append(warning) }
        }
    }

    func sendCoreCommandLine(_ command: String, context: String) {
        guard let writer = coreCommands else { return }
        do {
            try writer.write(contentsOf: Data(command.utf8))
        } catch {
            NSLog("LightIsle Core IPC write failed (%@): %@", context, error.localizedDescription)
        }
    }
}
