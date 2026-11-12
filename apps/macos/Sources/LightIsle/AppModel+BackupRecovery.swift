import AppKit
import Foundation
import LocalAuthentication

private struct NASMetadataRollbackResult: Decodable {
    let schemaVersion: Int
    let status: String
    let preservedCurrent: String?
}

@MainActor
extension AppModel {
    // MARK: - Backup and metadata recovery

    func refreshMetrics() {
        guard state == .online else { return }
        // Keep alerts, disk warnings and share status alive without retaining
        // the dashboard sample every three seconds while the UI is unloaded.
        if !samplesManagementUI {
            if Date().timeIntervalSince(lastAlertPollAt) >= 60 {
                lastAlertPollAt = Date()
                sendCoreCommandLine("stats summary\nalerts status\n", context: "metrics.background.alerts")
            }
            if Date().timeIntervalSince(lastShareStatusPollAt) >= 60 {
                lastShareStatusPollAt = Date()
                sendCoreCommandLine("share status\n", context: "metrics.background.share")
                rootManagement.refresh()
            }
            return
        }
        sendCoreCommandLine(diagnosticsVisible ? "stats\n" : "stats summary\n", context: "metrics.stats")
        sendCoreCommandLine("backup status\nbackup schedule status\n", context: "metrics.backup")
        if Date().timeIntervalSince(lastAlertPollAt) >= 60 {
            lastAlertPollAt = Date()
            sendCoreCommandLine("alerts status\n", context: "metrics.alerts")
        }
        if Date().timeIntervalSince(lastShareStatusPollAt) >= 30 {
            lastShareStatusPollAt = Date()
            sendCoreCommandLine("share status\nsmb status\n", context: "metrics.shareAndSMB")
            rootManagement.refresh()
        }
    }

    private var timeMachineRoots: [TimeMachineDiagnostics.Root] {
        rootManagement.roots.map {
            .init(id: $0.rootID, generation: $0.generation, name: $0.name, path: $0.path, online: $0.online)
        }
    }

    func clearStaleTimeMachineCoverage() {
        if let report = timeMachineDiagnostics, report.roots.map(\.root) != timeMachineRoots {
            invalidateTimeMachineDiagnostics()
        }
    }

    func refreshTimeMachineDiagnostics() {
        guard !timeMachineChecking else { return }
        timeMachineChecking = true
        let currentRoot = sharedFolderPath
        let roots = timeMachineRoots
        let generation = timeMachineDiagnosticsGeneration
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                TimeMachineDiagnostics.read(sharedPath: currentRoot, roots: roots)
            }.value
            guard let self else { return }
            // Never publish the backup result for an old/remounted NAS root.
            guard self.timeMachineDiagnosticsGeneration == generation else { return }
            guard self.sharedFolderPath == currentRoot, self.timeMachineRoots == roots else {
                self.invalidateTimeMachineDiagnostics()
                return
            }
            self.timeMachineDiagnostics = result
            self.timeMachineChecking = false
        }
    }

    func openTimeMachineSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func disableBackupSchedule() {
        guard state == .online else { return }
        sendCoreCommandLine("backup schedule off\n", context: "backup.schedule.off")
    }

    func configureMetadataWeeklyBackup() {
        guard state == .online, !activatingMetadata else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "保存每周配置备份到此目录"
        panel.message = "每周备份一次账号、权限、相册和应用设置，仅保留本计划最近 5 份成功快照；不包含照片、影片和其他原始文件。建议选择独立备份磁盘。"
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        sendBackupCommand("backup schedule set 168 5 metadata", path: folder)
    }

    func startMetadataBackup() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "保存配置备份到此目录"
        panel.message = "只备份应用数据库及配置，不备份共享目录中的原始照片、视频和文件。"
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        sendBackupCommand("backup metadata start", path: folder)
    }

    func browseBackupInventory() {
        guard state == .online, !backupInventoryLoading else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "查看此目录的备份"
        panel.message = "选择保存配置快照的目录。只读取清单，不删除文件；旧整盘快照不支持在家庭版中恢复。"
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        backupInventory = nil
        backupInventoryLoading = true
        sendBackupCommand("backup inventory", path: chosen)
    }

    func cancelBackup() {
        guard state == .online, backupStatus?.running == true else { return }
        sendCoreCommandLine("backup cancel\n", context: "backup.cancel")
    }

    func restoreBackup() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "恢复应用配置"
        panel.message = "只接受应用配置快照，校验后先隔离暂存数据库，等待管理员确认；不会还原或覆盖照片、影片与其他原始文件。"
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }
        sendBackupCommand("backup restore", path: chosen)
    }

    private func sendBackupCommand(_ operation: String, path: String) {
        let encoded = Data(path.utf8).base64URLEncodedString
        backupError = nil
        sendCoreCommandLine(operation + " " + encoded + "\n", context: "backup.command")
    }
}

@MainActor
extension AppModel {
    /// The native owner reviews a count-only preview before authorizing an
    /// offline database activation. The read-only helper can run while Core
    /// owns the data-directory lock.
    func previewRestoredMetadata() {
        guard state == .online, !activatingMetadata, !metadataPreviewLoading,
              backupStatus?.running != true,
              let fullPath = backupStatus?.restoredMetadata,
              let dataDir = NativeMetadataRecovery.privateMetadataDirectory else { return }
        let selected = URL(fileURLWithPath: fullPath).standardizedFileURL
        let privateRoot = URL(fileURLWithPath: dataDir).standardizedFileURL
        guard selected.lastPathComponent.hasPrefix("LightIsle-RestoredMetadata-"),
              selected.deletingLastPathComponent().standardizedFileURL == privateRoot else {
            metadataActivationMessage = "恢复目录不在轻屿的私有数据区域，未读取或修改数据。"
            return
        }

        metadataPreview = nil
        metadataPreviewStageName = nil
        metadataPreviewLoading = true
        metadataActivationMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                metadataActivationMessage = "无法验证本机所有者，未读取或修改数据。"
                metadataPreviewLoading = false
                return
            }
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份，以检查待恢复数据库的影响"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                let preview = await NativeMetadataRecovery.runPreview(dataDir: privateRoot.path, stage: selected.lastPathComponent)
                guard preview.isReady else {
                    metadataActivationMessage = preview.error?.message ?? "无法验证恢复预览，当前数据库未修改。"
                    metadataPreviewLoading = false
                    return
                }
                metadataPreview = preview
                metadataPreviewStageName = selected.lastPathComponent
            } catch {
                metadataActivationMessage = "本机验证取消或失败，未读取或修改数据。"
            }
            metadataPreviewLoading = false
        }
    }

    /// The backend is stopped only after the owner has reviewed the same
    /// manifest whose digest was returned by the preview helper.
    func activateRestoredMetadata() {
        guard state == .online, !activatingMetadata, backupStatus?.running != true,
              let fullPath = backupStatus?.restoredMetadata,
              let preview = metadataPreview, preview.isReady,
              let previewStageName = metadataPreviewStageName else { return }
        let selected = URL(fileURLWithPath: fullPath).standardizedFileURL
        guard selected.lastPathComponent == previewStageName,
              selected.lastPathComponent.hasPrefix("LightIsle-RestoredMetadata-"),
              let dataDir = NativeMetadataRecovery.privateMetadataDirectory,
              selected.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: dataDir).standardizedFileURL else {
            metadataActivationMessage = "恢复目录已变化，请重新检查影响预览。"
            metadataPreview = nil
            metadataPreviewStageName = nil
            return
        }

        let alert = NSAlert()
        alert.messageText = "应用已恢复的数据库？"
        alert.informativeText = NativeMetadataRecovery.previewConfirmation(preview) +
            "\n\nMac 所有者验证后会停止 Go Core 并替换数据库。原数据库会作为可回退版本保留；共享原片不会覆盖，原片与数据库快照不保证来自同一时间点。图库与影视索引可在恢复后手动重扫。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证身份并应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        activatingMetadata = true
        metadataActivationMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            var policyError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
                metadataActivationMessage = "无法验证本机所有者，未修改任何数据。"
                activatingMetadata = false
                return
            }
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份，以离线恢复轻屿数据库"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                metadataActivationMessage = await NativeMetadataRecovery.runOperation(
                    operation: "activate",
                    dataDir: dataDir,
                    stage: selected.lastPathComponent,
                    confirmation: "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT",
                    expectedManifestSHA256: preview.manifestSHA256
                )
                metadataPreview = nil
                metadataPreviewStageName = nil
                launch()
            } catch {
                metadataActivationMessage = "用户验证取消或失败，现有数据库保持原样。"
            }
            activatingMetadata = false
        }
    }

    func recoverInterruptedMetadata() {
        guard !activatingMetadata, state != .online else { return }
        let alert = NSAlert()
        alert.messageText = "修复中断的离线数据库恢复？"
        alert.informativeText = "仅用于上次恢复过程中断的情况。将恢复之前的数据库，并把中途生成的新文件保存在隔离目录。需要 Mac 所有者认证。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证并回滚")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activatingMetadata = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = LAContext()
            do {
                let approved = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份以修复中断的数据库恢复"
                )
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
                let dataDir = root?.appendingPathComponent("LightIsle").path ?? ""
                guard !dataDir.isEmpty else {
                    metadataActivationMessage = "无法确定应用数据库目录，已停止操作。"
                    activatingMetadata = false
                    return
                }
                metadataActivationMessage = await NativeMetadataRecovery.runOperation(
                    operation: "recover",
                    dataDir: dataDir,
                    stage: "",
                    confirmation: "RESTORE_PREVIOUS_METADATA"
                )
                launch()
            } catch {
                metadataActivationMessage = "本机验证取消或失败，未修改数据。"
            }
            activatingMetadata = false
        }
    }

    func refreshMetadataRollbacks() {
        guard !activatingMetadata, !metadataRollbacksLoading,
              let dataDir = NativeMetadataRecovery.privateMetadataDirectory,
              let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery") else { return }
        metadataRollbacksLoading = true
        metadataRollbackError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await OfflineRecoveryRunner.run(binary: binary, arguments: [
                "--data-dir", dataDir, "--operation", "list", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
            ], timeout: 30)
            if result.exitCode == 0, !result.truncated, !result.timedOut,
               let inventory = try? JSONDecoder().decode(NASMetadataRollbackInventory.self, from: result.output),
               inventory.schemaVersion == 1, inventory.operation == "list" {
                metadataRollbacks = inventory
            } else {
                metadataRollbackError = result.timedOut ? "读取回退版本超时，请重试。" : "无法读取可验证的回退版本，请检查本机恢复日志后重试。"
            }
            metadataRollbacksLoading = false
        }
    }

    func rollbackMetadata(_ transaction: NASMetadataRollbackTransaction) {
        guard state != .starting, state != .stopping, !activatingMetadata, !metadataRollbacksLoading,
              backupStatus?.running != true, transaction.canRollback,
              metadataRollbacks?.transactions.contains(where: { $0.id == transaction.id && $0.canRollback }) == true,
              let dataDir = NativeMetadataRecovery.privateMetadataDirectory,
              let binary = Bundle.main.resourceURL?.appendingPathComponent("core/lightisle-recovery") else { return }
        let alert = NSAlert()
        alert.messageText = "回退到这次恢复之前的账号与配置？"
        alert.informativeText = "将验证 Mac 所有者身份并停止服务。当前数据库及之后的变更会保存在独立目录，再恢复经校验的上一版本；共享文件不会被替换。所有 Web 会话需重新登录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "验证身份并回退")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        activatingMetadata = true
        metadataActivationMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = LAContext()
                let approved = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "验证 Mac 所有者身份，以离线回退轻屿账号与配置")
                guard approved else { throw NSError(domain: "LightIsle", code: 1) }
                await stop()
                let result = await OfflineRecoveryRunner.run(binary: binary, arguments: [
                    "--data-dir", dataDir, "--operation", "rollback", "--transaction-id", transaction.id,
                    "--confirm", "ROLLBACK_OFFLINE_METADATA", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
                ])
                if result.exitCode == 0, !result.truncated, !result.timedOut,
                   let response = try? JSONDecoder().decode(NASMetadataRollbackResult.self, from: result.output),
                   response.schemaVersion == 1, response.status == "rolled_back" {
                    metadataActivationMessage = "已回退账号与配置。回退前的数据保存在：\(response.preservedCurrent ?? "私有回退目录")。请重新登录 Web。"
                    AdminCredentialVault.remove()
                    unlockedAdminCredentials = nil
                    pendingAdminCredentials = nil
                } else {
                    metadataActivationMessage = "回退未能完成；数据版本将保留。如服务提示恢复中断，请使用“修复中断的恢复”。"
                }
                metadataRollbacks = nil
                launch()
            } catch {
                metadataActivationMessage = "本机验证取消或失败，未开始回退。"
            }
            activatingMetadata = false
        }
    }

}
