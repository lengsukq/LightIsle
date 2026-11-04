import AppKit
import Foundation

@MainActor
extension AppModel {
    // MARK: - Core runtime

    private func decodeAdminUsername(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let username = String(data: data, encoding: .utf8),
              !username.isEmpty, username.utf8.count <= 32 else { return nil }
        return username
    }

    func launch() {
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

    /// Configuration IPC updates have one lifecycle and decode policy.
    /// Core's other status signals are handled separately in consume(_:).
    private func consumeSettingsIPC(_ line: String) -> Bool {
        guard let event = CoreIPCSettingsEvent.decode(line) else { return false }
        switch event {
        case .mapState(let configured):
            if let configured {
                mapKeyConfigured = configured
                mapCoreAcknowledged = true
                mapKeyBusy = false
                mapKeyError = nil
            }
        case .mapError:
            mapKeyBusy = false
            mapKeyError = "Core 未能接收天地图 Key，请重新保存或重启服务。"
        case .frpState(let state):
            if let state { frpState = state }
        case .frpVersions(let releases):
            frpVersionsLoading = false
            if let releases {
                let available = releases.filter(\.installable)
                frpVersions = available
                if !available.contains(where: { $0.version == selectedFRPVersion }) {
                    selectedFRPVersion = available.first(where: { !$0.prerelease })?.version ??
                        available.first?.version ?? ""
                }
                frpError = nil
            } else {
                frpError = "FRP 版本列表解析失败，请重试。"
            }
        case .frpError(let reason):
            frpVersionsLoading = false
            frpError = reason
        case .trashRetention(let retention):
            if let retention {
                trashDeadline?.cancel()
                trashRetentionBusy = false
                trashRetention = retention
                trashRetentionError = nil
            }
        case .trashRetentionError:
            trashDeadline?.cancel()
            trashRetentionBusy = false
            trashRetentionError = "保留策略无效：天数需在 1 至 365 之间，或关闭自动清理。"
        case .tmdbState(let state):
            if let state {
                tmdbTokenConfigured = state.configured
                tmdbCoreAcknowledged = true
                tmdbTokenBusy = false
                tmdbTokenError = nil
            }
        case .tmdbError(let code):
            tmdbTokenBusy = false
            tmdbTokenError = code == "invalid_tmdb_token"
                ? "Token 格式不正确：应为 TMDB v4 Read Access Token（长度 20 以上的连续字符串，不含空格换行）。"
                : "TMDB Token 命令失败，请重试。"
        }
        return true
    }

    /// Apply decoded status reports on the main actor. Unrecognized protocol
    /// commands are intentionally left to the specific lifecycle handlers.
    private func consumeReportIPC(_ line: String) -> Bool {
        guard let event = CoreIPCReportEvent.decode(line) else { return false }
        switch event {
        case .alerts(let alerts):
            if let alerts {
                activeAlerts = Array(alerts.filter(\.active).prefix(100))
                nativeAlertCoordinator.presentCoreAlerts(Array(alerts.prefix(100)), enabled: nativeAlertsEnabled)
            }
        case .backupInventory(let inventory):
            backupInventoryLoading = false
            if let inventory {
                backupInventory = inventory
            } else {
                backupError = "无法读取备份清单，请重试。"
            }
        case .disks(let disks):
            if let disks {
                managedDisks = disks
                diskManagementError = nil
            } else {
                diskManagementError = "无法解析磁盘状态，请刷新。"
            }
            diskOperationPending = false
            diskOperationDeadline?.cancel()
        case .diskHealth(let report):
            if let report { diskHealthReports[report.device] = report }
        case .storageThreshold(let threshold):
            if let threshold { storageThreshold = threshold }
        case .tunnel(let state):
            if let state { tunnelState = state }
        case .notify(let stats):
            if let stats {
                notifyStats = stats
                notifyConfigured = stats.configured
                notifyCoreAcknowledged = true
            }
        case .backupStatus(let report):
            if let report, backupStatus != report { backupStatus = report }
        case .backupSchedule(let schedule):
            if let schedule, backupSchedule != schedule { backupSchedule = schedule }
        case .hostMetrics(let reading):
            if let reading {
                nativeAlertCoordinator.checkLowDiskSpace(reading.volumes ?? [], enabled: nativeAlertsEnabled)
                if samplesManagementUI {
                    metrics = reading
                    lastMetricsAt = Date()
                    metricHistory.append(MetricHistoryPoint(
                        time: Date(), cpu: reading.cpuPercent ?? 0,
                        memory: Double(reading.memoryUsed) / Double(max(reading.memoryTotal, 1)) * 100,
                        download: reading.networkDownBps ?? 0,
                        upload: reading.networkUpBps ?? 0
                    ))
                    if metricHistory.count > 120 {
                        metricHistory.removeFirst(metricHistory.count - 120)
                    }
                }
            }
        }
        return true
    }

    private func consume(_ bytes: Data) {
        for line in coreOutputFramer.append(bytes) {
            if line.hasPrefix("LIGHTISLE_ROOTS ") {
                rootManagement.consume(String(line.dropFirst("LIGHTISLE_ROOTS ".count)))
                continue
            }
            if consumeSettingsIPC(line) {
                continue
            }
            if consumeReportIPC(line) {
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_ACCOUNT ") {
                let raw = String(line.dropFirst("LIGHTISLE_ADMIN_ACCOUNT ".count))
                if let username = decodeAdminUsername(raw) { firstAdminUsername = username }
                continue
            }
            if line == "LIGHTISLE_EXPORT_STARTED" {
                exportRunning = true
                exportMessage = activeExportMode == "move"
                    ? "正在跨盘安全移动，源文件会在完整发布之后进入回收站。"
                    : "跨磁盘复制正在执行，校验完成后才会显示目标文件。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_HISTORY ") {
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_HISTORY ".count))
                if let text = decodeExportResult(raw), let bytes = text.data(using: .utf8),
                   let items = try? JSONDecoder().decode([FileTransferReceipt].self, from: bytes) {
                    transferHistory = items
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_HISTORY_ERROR ") {
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_HISTORY_ERROR ".count))
                exportMessage = "无法读取迁移记录：" + (decodeExportResult(raw) ?? "未知错误")
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_OK ") {
                exportRunning = false
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_OK ".count))
                let location = decodeExportResult(raw) ?? "目标文件"
                exportMessage = activeExportMode == "move"
                    ? "安全移动已完成：\(location)。源文件位于轻屿回收站，可恢复；历史记录保留在本机。"
                    : "复制并校验完成：\(location)"
                requestTransferHistory()
                continue
            }
            if line.hasPrefix("LIGHTISLE_EXPORT_ERROR ") {
                exportRunning = false
                let raw = String(line.dropFirst("LIGHTISLE_EXPORT_ERROR ".count))
                let reason = decodeExportResult(raw) ?? "unknown_error"
                exportMessage = reason == "context canceled" ? "复制已取消，源文件保持不变。" : "跨磁盘复制未完成：\(reason)"
                continue
            }
            if line == "LIGHTISLE_ADMIN_VERIFIED" {
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
                continue
            }
            if line == "LIGHTISLE_BACKUP_CANCEL_REQUESTED" {
                backupError = "已请求取消任务，正在清理未完成的临时文件。"
                continue
            }
            if line == "LIGHTISLE_ADMIN_VERIFY_FAILED" {
                verifyingAdmin = false
                pendingAdminCredentials = nil
                vaultMessage = "当前轻屿管理员用户名或密码不正确。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_RESET_OK ") {
                resettingAdmin = false
                AdminCredentialVault.remove()
                unlockedAdminCredentials = nil
                pendingAdminCredentials = nil
                let raw = String(line.dropFirst("LIGHTISLE_ADMIN_RESET_OK ".count))
                if let username = decodeAdminUsername(raw) {
                    firstAdminUsername = username
                    administratorResetSucceeded = true
                    resetAdminMessage = "已重置管理员「\(username)」的密码。请使用该用户名和新密码登录当前 Web，旧登录会话已失效。"
                } else {
                    administratorResetSucceeded = true
                    resetAdminMessage = "密码已更新，但未能读取账号名称。请确认当前 Web 地址并重新登录。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_ADMIN_RESET_ERROR ") {
                resettingAdmin = false
                let code = String(line.dropFirst("LIGHTISLE_ADMIN_RESET_ERROR ".count))
                resetAdminMessage = code == "invalid_password" ? "新密码不符合长度或格式要求。" :
                    code == "admin_missing" ? "未找到可用的首任管理员。" : "修改管理员密码失败，请检查 Go 服务日志。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_DISKS_ERROR ") {
                diskOperationPending = false
                diskOperationDeadline?.cancel()
                diskManagementError = "磁盘操作未完成：\(line.dropFirst("LIGHTISLE_DISKS_ERROR ".count))。请刷新并核对硬盘状态。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_ALERTS_THRESHOLD_ERROR ") {
                let code = String(line.dropFirst("LIGHTISLE_ALERTS_THRESHOLD_ERROR ".count))
                if code == "invalid_storage_threshold" {
                    diskManagementError = "告警阈值无效：绝对剩余空间与百分比不能同时为 0。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_TUNNEL_API ") {
                let raw = String(line.dropFirst("LIGHTISLE_TUNNEL_API ".count))
                if let object = TunnelWireCodec.decodeAPI(raw) {
                    applyTunnelPayload(object)
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_TUNNEL_ERROR ") {
                let raw = String(line.dropFirst("LIGHTISLE_TUNNEL_ERROR ".count))
                if let message = TunnelWireCodec.decodeError(raw) {
                    tunnelAPIError = message
                }
                tunnelAPIBusy = false
                tunnelCredential.cancelPending()
                continue
            }
            if line == "LIGHTISLE_NOTIFY_ON" {
                notifyConfigured = true
                notifyCoreAcknowledged = true
                notifyBusy = false
                notifyError = nil
                refreshNotifyStatus()
                continue
            }
            if line == "LIGHTISLE_NOTIFY_OFF" {
                notifyConfigured = false
                notifyStats = nil
                notifyCoreAcknowledged = true
                notifyBusy = false
                notifyError = nil
                continue
            }
            if line == "LIGHTISLE_NOTIFY_TESTED" {
                notifyTestResult = "测试通知已发送，请在手机或目标服务上确认收到。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_NOTIFY_TEST_ERROR ") {
                let raw = String(line.dropFirst("LIGHTISLE_NOTIFY_TEST_ERROR ".count))
                notifyTestResult = "测试通知发送失败：\(Self.decodeBase64URLText(raw) ?? "未知错误")"
                continue
            }
            if line.hasPrefix("LIGHTISLE_NOTIFY_ERROR ") {
                let raw = String(line.dropFirst("LIGHTISLE_NOTIFY_ERROR ".count))
                notifyBusy = false
                let reason = Self.decodeBase64URLText(raw)
                switch reason {
                case "invalid_notify_config":
                    notifyError = "通知通道配置无效：Bark 服务器需为 http(s) 源（不带路径），Webhook 需为完整 http(s) 地址。"
                case "notify_private_target_rejected":
                    notifyError = "目标地址位于内网/本机回环。自建 Bark/Webhook 需勾选“允许内网目标”。"
                default:
                    notifyError = "通知通道配置失败：\(reason ?? "未知错误")"
                }
                continue
            }
            if line == "LIGHTISLE_BACKUP_SCHEDULE_CHANGED" {
                backupError = nil
                try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup schedule status\n".utf8))
                continue
            }
            if line == "LIGHTISLE_BACKUP_STARTED" {
                backupError = nil
                nativeAlertCoordinator.clear(key: "backup-failure")
                try? inputPipe?.fileHandleForWriting.write(contentsOf: Data("backup status\n".utf8))
                continue
            }
            if line.hasPrefix("LIGHTISLE_BACKUP_ERROR ") {
                backupInventoryLoading = false
                backupError = String(line.dropFirst("LIGHTISLE_BACKUP_ERROR ".count))
                notifyImportantEvent("backup-failure", title: "轻屿备份操作失败", message: "备份或恢复操作未完成，请在本机存储页面查看错误。")
                continue
            }
            if line == "LIGHTISLE_SMB_STATUS 1" {
                if smbListening != true { smbListening = true }
                continue
            }
            if line == "LIGHTISLE_SMB_STATUS 0" {
                if smbListening != false { smbListening = false }
                continue
            }
            if line == "LIGHTISLE_CONFIGURED 1" {
                isConfigured = true
                enablePreferredLANIfReady()
                continue
            }
            if line == "LIGHTISLE_CONFIGURED 0" {
                isConfigured = false
                continue
            }
            if line == "LIGHTISLE_INITIALIZED" {
                initializing = false
                isConfigured = true
                initializationError = nil
                enablePreferredLANIfReady()
                continue
            }
            if line.hasPrefix("LIGHTISLE_INIT_ERROR ") {
                initializing = false
                let code = String(line.dropFirst("LIGHTISLE_INIT_ERROR ".count))
                switch code {
                case "already_configured":
                    isConfigured = true
                    initializationError = "管理员已经初始化，请登录 Web 使用。"
                case "invalid_credentials":
                    initializationError = "用户名格式或密码长度不符合要求。"
                default:
                    initializationError = "初始化失败，请检查 Go 服务日志。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_REMOTE_ON ") {
                finishRemoteChange()
                let words = line.split(separator: " ")
                if words.count == 3 {
                    remoteAddress = String(words[1])
                    remoteFingerprint = words[2] == "-" ? nil : String(words[2])
                    remoteError = nil
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ON ") {
                sharedFolderName = String(line.dropFirst("LIGHTISLE_SHARE_ON ".count))
                sharedFolderError = nil
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_PATH ") {
                let raw = String(line.dropFirst("LIGHTISLE_SHARE_PATH ".count))
                var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let data = Data(base64Encoded: encoded), let path = String(data: data, encoding: .utf8), path.hasPrefix("/") {
                    if storageSelectionPending, let pendingStorageTarget,
                       URL(fileURLWithPath: pendingStorageTarget).resolvingSymlinksInPath().standardizedFileURL.path ==
                       URL(fileURLWithPath: path).standardizedFileURL.path {
                        let old = previousStorageRoot
                        let accessRevoked = legacyAccessRevokedForPendingRoot
                        clearPendingStorageSelection()
                        if let old {
                            if accessRevoked == true {
                                storageSelectionMessage = "已切换至 \(path)。旧目录 \(old) 内的文件仍保留；旧成员文件授权和公开分享链接已撤销，授权记录保存在本机，新目录仍需重新授权。用户、登录会话和 WebDAV 凭据保留。"
                            } else if accessRevoked == false {
                                storageSelectionMessage = "已重新连接同一物理目录：\(path)。目录授权保留，文件未搬迁。"
                            } else {
                                storageSelectionMessage = "已切换至 \(path)。旧目录文件未搬迁；授权状态未得到确认，请检查成员授权和分享链接后再使用。"
                            }
                        } else {
                            if accessRevoked == true {
                                storageSelectionMessage = "已启用 NAS 存储目录：\(path)。旧成员文件授权和公开分享链接已撤销，授权记录保存在本机；新目录需重新授权。"
                            } else if accessRevoked == nil {
                                storageSelectionMessage = "已启用 NAS 存储目录：\(path)。授权状态未得到确认，请检查成员授权和分享链接后再使用。"
                            } else {
                                storageSelectionMessage = "已启用 NAS 存储目录：\(path)"
                            }
                        }
                    }
                    cancelScheduledIndexRefresh()
                    sharedFolderPath = path
                    offlineSharedFolderPath = nil
                    if offlineCleanupMessage?.hasPrefix("已解除离线盘绑定") == true {
                        offlineCleanupMessage = "离线磁盘的本地媒体索引和旧共享权限已清理。现在使用本机存储目录 \(path)；原外接盘上的文件未删除。"
                    }
                    if timeMachineDiagnostics == nil { refreshTimeMachineDiagnostics() }
                    nativeAlertCoordinator.clear(key: "volume-unavailable")
                    directoryWatcher?.stop()
                    directoryWatcher = DirectoryChangeWatcher(path: path) { [weak self] paths, full in
                        self?.scheduleIndexRefresh(paths: paths, needsFull: full)
                    }
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ACCESS_REVOKED ") {
                guard storageSelectionPending else { continue }
                let state = String(line.dropFirst("LIGHTISLE_SHARE_ACCESS_REVOKED ".count))
                if state == "1" {
                    legacyAccessRevokedForPendingRoot = true
                } else if state == "0" {
                    legacyAccessRevokedForPendingRoot = false
                } else {
                    legacyAccessRevokedForPendingRoot = nil
                }
                continue
            }
            if line == "LIGHTISLE_SHARE_STATUS 0" {
                // Monitoring a disconnected volume must not keep displaying
                // the old path as live, or continue watching the old mount.
                // Reopening it is still an explicit, identity-checked action.
                if sharedFolderPath != nil || sharedFolderError == nil {
                    cancelScheduledIndexRefresh()
                    directoryWatcher?.stop()
                    directoryWatcher = nil
                    sharedFolderPath = nil
                    sharedFolderError = "原共享磁盘已离线或目录身份发生变化，请确认原磁盘后手动点击重新连接。"
                    notifyImportantEvent("volume-unavailable", title: "NAS 存储目录不可用",
                                         message: "轻屿已停止显示原共享目录为在线；不会自动改用同名磁盘。")
                }
                continue
            }
            if line == "LIGHTISLE_SHARE_STATUS 1" { continue }
            if line.hasPrefix("LIGHTISLE_SHARE_OFFLINE_PATH ") {
                let encoded = String(line.dropFirst("LIGHTISLE_SHARE_OFFLINE_PATH ".count))
                if let path = Self.decodeBase64URLText(encoded),
                   path.hasPrefix("/"), path.utf8.count <= 4096 {
                    offlineSharedFolderPath = path
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_FORGOT ") {
                offlineCleanupPending = false
                offlineSharedFolderPath = nil
                offlineCleanupMessage = "已解除离线盘绑定并撤销旧成员文件授权和公开分享链接，授权记录保存在本机但不会自动用于新目录。原盘文件未删除；旧路径的图库、影院记录正在清理，NAS 正切换到本机目录。新目录需重新授权。用户、登录会话和 WebDAV 凭据保留。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_FORGET_ERROR ") {
                offlineCleanupPending = false
                let error = String(line.dropFirst("LIGHTISLE_SHARE_FORGET_ERROR ".count))
                if error.contains("legacy_share_access_revoked_root_config_uncertain") {
                    offlineCleanupMessage = "旧成员文件授权和公开分享链接已撤销，但本机目录配置落盘结果不确定。请停止文件操作，完全退出并重启轻屿，核对当前共享目录后再继续。"
                } else if error.contains("legacy_share_access_revoked_root_switch_failed") {
                    offlineCleanupMessage = "旧成员文件授权和公开分享链接已撤销，但本机目录切换未能完成；旧离线绑定仍保留。请检查 Core 状态后再重试。"
                } else if error.contains("legacy_share_access_revocation_uncertain") {
                    offlineCleanupMessage = "旧授权撤销结果无法确认，目录切换未继续。请暂停共享并重启轻屿，检查成员授权和公开分享链接后再操作。"
                } else if error.contains("shared_directory_transition_busy") {
                    offlineCleanupMessage = "仍有旧目录请求或后台任务正在结束。原绑定保留，请稍后重试。"
                } else if error.contains("shared_directory_save_uncertain_restart_required") {
                    offlineCleanupMessage = "目录配置持久化结果不确定。请停止文件操作，完全退出后重启 LightIsle，并检查当前实际共享目录。"
                } else {
                    offlineCleanupMessage = "清理失败或当前存在进行中任务：\(error)。原绑定仍保留。"
                }
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_FORGET_WARNING ") {
                offlineCleanupMessage = "已切回本机目录，但有部分媒体索引未完成清理：\(line.dropFirst("LIGHTISLE_SHARE_FORGET_WARNING ".count))。请先备份并检查元数据。"
                continue
            }
            if line.hasPrefix("LIGHTISLE_SHARE_ERROR ") {
                if storageSelectionPending {
                    let error = String(line.dropFirst("LIGHTISLE_SHARE_ERROR ".count))
                    clearPendingStorageSelection()
                    if error.contains("shared_directory_save_uncertain_restart_required") {
                        storageSelectionMessage = "存储目录配置落盘结果不确定。请停止文件操作，完全退出并重新启动轻屿，检查当前共享路径和磁盘身份后再继续。"
                    } else if error.contains("legacy_share_access_revoked_root_config_uncertain") {
                        storageSelectionMessage = "旧成员文件授权和公开分享链接已撤销，但新目录配置落盘结果不确定。请停止文件操作，完全退出并重启轻屿，核对当前共享目录后再继续授权。"
                    } else if error.contains("legacy_share_access_revoked_root_switch_failed") {
                        storageSelectionMessage = "旧成员文件授权和公开分享链接已撤销，但新目录未能切换。原目录文件仍保留，请检查 Core 和当前路径后再重新授权。"
                    } else if error.contains("legacy_share_access_revocation_uncertain") {
                        storageSelectionMessage = "旧授权撤销结果无法确认，切换未继续。请暂停文件共享并重启轻屿，检查成员授权和分享链接后再操作。"
                    } else if error.contains("shared_directory_transition_busy") {
                        storageSelectionMessage = "仍有旧目录请求或后台任务正在结束。请稍后重试切换。"
                    } else if error.contains("shared_directory_busy") {
                        storageSelectionMessage = "当前目录还有未完成上传。请先完成上传，或在 Web 管理设置中取消未完成上传后，再切换存储目录。"
                    } else if error.contains("root_registry_overlap") {
                        storageSelectionMessage = "所选目录与已登记的其他 NAS 存储根相同或重叠。请选一个独立文件夹，或通过多硬盘管理使用已登记的目录；原目录未切换。"
                    } else if error.contains("drive_operation_busy") {
                        storageSelectionMessage = "正在执行磁盘操作、文件传输、备份或媒体扫描。请等待任务结束后再切换存储目录。"
                    } else {
                        storageSelectionMessage = "更改存储目录失败：\(error)。当前运行中的原目录未被切换。"
                    }
                    continue
                }
                cancelScheduledIndexRefresh()
                sharedFolderError = String(line.dropFirst("LIGHTISLE_SHARE_ERROR ".count))
                sharedFolderPath = nil
                notifyImportantEvent("volume-unavailable", title: "NAS 存储目录不可用", message: "共享目录可能已断开连接；LightIsle 不会自动改用其他同名目录。")
                directoryWatcher?.stop()
                directoryWatcher = nil
                continue
            }
            guard let signal = CoreLifecycleSignal.decode(line) else { continue }
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
            }
        }
    }

    /// Rebind all native-only services after the authenticated loopback Core
    /// reports READY. This is deliberately distinct from line decoding.
    private func handleCoreReady(_ url: URL) {
            endpoint = url
            cancelStartupDeadline()
            state = .online
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
            refreshTunnel()
            refreshFRP()
            rootManagement.onDefaultChanged = { [weak self] root in
                self?.applyRegisteredDefault(root)
            }
            rootManagement.connect { [weak self] command in
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
        tunnelSelectedID = nil
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
        resetCorePeripheralState()
        releaseCoreRuntime()
        // A late termination callback from a completed stop must not change
        // the app back to an error state.
        if !stopping {
            state = .error("Go Core 异常退出，退出码 \(status)")
            details = "后端已停止。可点击“重新启动”恢复服务。"
        }
    }

    func stop() async {
        cancelStartupDeadline()
        cancelScheduledIndexRefresh()
        endServicePolling()
        rootManagement.disconnect()
        guard let process = core else { return }
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
