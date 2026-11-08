import SwiftUI
import AppKit

extension ContentView {
    var storageBackupContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppleSettingsGroup(title: "备份与恢复", footer: "默认只备份账号、权限、相册和应用设置，不包含原始照片、视频或文档。原始文件请通过 Time Machine 或其他独立备份工具保护。") {
                AppleSettingsRow(title: "应用配置", subtitle: "每周备份一次 · 保留最近 5 份 · 需要 Mac 应用保持运行", icon: "externaldrive", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        Button("设置每周配置备份…") { model.configureMetadataWeeklyBackup() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(model.state != .online || model.backupStatus?.running == true)
                        Button("关闭自动备份") { model.disableBackupSchedule() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.backupSchedule?.enabled != true)
                    }
                }
                AppleSettingsRow(title: "立即操作", icon: "clock.arrow.circlepath", iconTint: .orange) {
                    HStack(spacing: 8) {
                        Button("立即备份配置…") { model.startMetadataBackup() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(model.state != .online || model.backupStatus?.running == true)
                        Button("从备份恢复…") { model.restoreBackup() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.backupStatus?.running == true)
                        Button(model.backupInventoryLoading ? "读取清单…" : "查看备份…") { model.browseBackupInventory() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.backupInventoryLoading)
                    }
                }
                if let report = model.backupStatus {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    if report.running {
                        AppleSettingsRow(title: "备份进行中") {
                            HStack(spacing: 8) {
                                ProgressView("处理 \(report.files) 个文件").controlSize(.small)
                                Button("取消") { model.cancelBackup() }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            }
                        }
                    } else if let path = report.lastSnapshot {
                        AppleSettingsRow(title: "上次结果") {
                            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let lastError = report.lastError, !lastError.isEmpty {
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "上次备份任务失败", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                            Text(backupFailureDescription(lastError))
                                .font(.caption)
                                .foregroundStyle(IsleTheme.warningText)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
                if let warning = model.backupStatus?.retentionError, !warning.isEmpty {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "备份已完成，旧快照清理未完成", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backupFailureDescription(warning))
                            if let removed = model.backupStatus?.retentionRemoved, removed > 0 {
                                Text("已清理 \(removed) 个快照；其他目录请检查。")
                            }
                        }.font(.caption).foregroundStyle(IsleTheme.warningText).textSelection(.enabled)
                    }
                } else if let removed = model.backupStatus?.retentionRemoved, removed > 0 {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "本次计划清理") {
                        Text("已清理 \(removed) 个旧计划快照").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                if let inventory = model.backupInventory {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "备份清单", icon: "archivebox", iconTint: .blue) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(inventory.destination).font(.caption.monospaced()).textSelection(.enabled)
                            if inventory.snapshots.isEmpty {
                                Text("此目录未找到可识别的备份快照。")
                                    .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            }
                            ForEach(inventory.snapshots) { snapshot in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.name).font(.caption).textSelection(.enabled)
                                    if !snapshot.version.isEmpty {
                                        Text(snapshot.backupType == "metadata" ? "应用配置快照" : "旧整盘快照（不支持恢复）")
                                            .font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                                    }
                                    Text("\(snapshot.createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(snapshot.createdAt)).formatted() : "时间未知") · 清单容量 \(ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file))")
                                        .font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                                    Text(snapshot.integrity == "invalid" ? "清单异常，不能据此确认可恢复" : snapshot.integrity == "not_verified_limit" ? "超出本次检查上限，内容尚未校验" : "清单可读，内容 SHA-256 尚未校验")
                                        .font(.caption2).foregroundStyle(snapshot.integrity == "invalid" ? IsleTheme.warningText : IsleTheme.secondaryText)
                                }
                            }
                            if inventory.truncated {
                                Text("目录较大，本次仅展示扫描上限内的快照。可在访达中按目录分别查看。")
                                    .font(.caption).foregroundStyle(IsleTheme.warningText)
                            }
                        }
                    }
                }
                if let message = model.backupError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "备份操作提示", icon: "info.circle.fill", iconTint: .blue) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
                if let s = model.backupSchedule {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "自动备份状态", icon: "calendar.badge.clock", iconTint: .indigo) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(!s.enabled ? "未启用" : "仅应用配置 · 每周 · 保留最近 5 份")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            if s.enabled, s.nextRun > 0 {
                                Text("下次运行：\(Date(timeIntervalSince1970: TimeInterval(s.nextRun)).formatted())").font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                            }
                            if let destination = s.destination, !destination.isEmpty {
                                Text(destination).font(.caption2.monospaced()).foregroundStyle(IsleTheme.secondaryText).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                            if let error = s.lastError, !error.isEmpty {
                                Text(backupFailureDescription(error)).font(.caption2).foregroundStyle(IsleTheme.warningText)
                            }
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
            }

            upgradePreflightView
            metadataRollbackView
        }
    }
    var storageTimeMachineContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppleSettingsGroup(title: "macOS Time Machine 备份保护", footer: "只读读取系统配置，不会修改备份磁盘、排除项目或自动启动备份。显示为包含 ≠ 已成功备份；建议另外使用独立物理备份盘。") {
                AppleSettingsRow(title: "系统备份状态", icon: "clock.arrow.circlepath", iconTint: .teal) {
                    HStack(spacing: 8) {
                        Text(model.timeMachineDiagnostics?.summary ?? "尚未检查")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        Button(model.timeMachineChecking ? "检查中…" : "检查保护状态") {
                            model.refreshTimeMachineDiagnostics()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.timeMachineChecking)
                        Button("打开系统设置…") { model.openTimeMachineSettings() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                if let status = model.timeMachineDiagnostics {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "LightIsle 元数据目录") {
                        Text(status.metadataFolder.rawValue)
                            .font(.caption)
                            .foregroundStyle(status.metadataFolder == .excluded ? .orange : .secondary)
                    }
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "NAS 原始文件目录") {
                        Text(model.sharedFolderPath == nil ? "未选择共享目录" : status.sharedFolder.rawValue)
                            .font(.caption)
                            .foregroundStyle(status.sharedFolder == .excluded ? .orange : .secondary)
                    }
                    if status.destinationKnown && !status.destinationNames.isEmpty {
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "已配置目标") {
                            Text(status.destinationNames.joined(separator: "、"))
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                    }
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "最近可查询的系统备份") {
                        Text(status.latestBackupPath ?? "无法核实最近成功备份，请到 Time Machine 系统设置检查")
                            .font(.caption.monospaced())
                            .foregroundStyle(IsleTheme.secondaryText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if let detail = status.detail {
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "需要手动核查", icon: "exclamationmark.triangle", iconTint: .orange) {
                            Text(detail).font(.caption).foregroundStyle(IsleTheme.warningText)
                        }
                    }
                }
            }
            .onAppear {
                if model.timeMachineDiagnostics == nil { model.refreshTimeMachineDiagnostics() }
            }
        }
    }
    var storageTransfersContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppleSettingsGroup(title: "跨磁盘安全迁移与归档", footer: "安全复制支持文件/文件夹；日志化安全移动当前仅支持单文件。先校验目标并持久记录，再把源移入轻屿回收站。失败/中断可能留下两个副本，不自动销毁任何数据。") {
                AppleSettingsRow(title: "跨卷迁移归档", icon: "arrow.left.arrow.right", iconTint: .purple) {
                    HStack(spacing: 8) {
                        Button("选择源文件与目标磁盘…") {
                            model.exportToAnotherDisk()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(model.state != .online || model.exportRunning || model.sharedFolderPath == nil)

                        if model.exportRunning {
                            Button("取消") { model.cancelExport() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                        Button("查看迁移记录") { model.requestTransferHistory() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online)
                    }
                }
                if model.exportRunning {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "进度") {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = model.exportMessage {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "状态信息") {
                        Text(message).font(.caption).foregroundStyle(IsleTheme.secondaryText).textSelection(.enabled)
                    }
                }
                if !model.transferHistory.isEmpty {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("最近安全移动日志")
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(model.transferHistory.prefix(12)) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.source)
                                    .font(.system(size: 12, weight: .medium))
                                    .textSelection(.enabled)
                                Text("状态：" + item.statusDescription)
                                    .font(.caption)
                                    .foregroundStyle(item.phase == "source_in_trash" ? .green : .orange)
                                if let trashID = item.trashId {
                                    Text("回收站记录：" + trashID)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                                Text(item.destination)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .textSelection(.enabled)
                                if let reason = item.error, !reason.isEmpty {
                                    Text("错误：" + reason)
                                        .font(.caption)
                                        .foregroundStyle(IsleTheme.warningText)
                                }
                            }
                            .padding(.vertical, 5)
                            if item.id != model.transferHistory.prefix(12).last?.id {
                                IsleGroupSpacing(height: 4)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

        }
    }
    var upgradePreflightView: some View {
        AppleSettingsGroup(title: "Beta 升级前安全检查", footer: "只读检查当前账号及媒体 SQLite 数据库，不进行迁移、恢复或安装。检查通过不等于已有独立备份；正式升级前必须先退出旧版并核实备份。") {
            AppleSettingsRow(title: "数据库基础预检", icon: "checkmark.shield", iconTint: .teal) {
                Button(model.upgradePreflightChecking ? "检查中…" : "检查当前数据库") {
                    model.checkUpgradePreflight()
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(model.upgradePreflightChecking || model.activatingMetadata)
            }
            if let report = model.upgradePreflight {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "升级风险评估", icon: report.canProceedWithManualUpgrade ? "checkmark.circle" : "exclamationmark.triangle", iconTint: report.canProceedWithManualUpgrade ? .teal : .orange) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.summary).font(.caption).foregroundStyle(report.canProceedWithManualUpgrade ? IsleTheme.secondaryText : IsleTheme.warningText)
                        ForEach(report.databases, id: \.name) { database in
                            Text("\(database.name)：\(database.status)").font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                        }
                        ForEach(report.issues + report.warnings, id: \.self) { message in
                            Text("• " + message).font(.caption2).foregroundStyle(IsleTheme.warningText)
                        }
                    }
                }
            }
        }
    }

    var metadataRollbackView: some View {
        AppleSettingsGroup(title: "账号与配置回退", footer: "数据库恢复会保留旧版本供回退；共享原片不覆盖，原片与数据库不保证同一时间点。") {
            if let fullPath = model.backupStatus?.restoredMetadata {
                let stageName = URL(fileURLWithPath: fullPath).lastPathComponent
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "待应用的恢复数据库", icon: "externaldrive.badge.timemachine", iconTint: .blue) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("数据库已放入轻屿私有隔离区。先检查账号、授权、私人相册、收藏、手工资料和任务数量。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        Button(model.metadataPreviewLoading ? "正在检查影响…" : "检查恢复影响") {
                            model.previewRestoredMetadata()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online || model.metadataPreviewLoading || model.activatingMetadata || model.backupStatus?.running == true)
                    }
                }
                if let preview = model.metadataPreview,
                   model.metadataPreviewStageName == stageName,
                   preview.isReady {
                    AppleSettingsRow(title: "恢复影响预览", icon: "checkmark.shield", iconTint: .teal) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(metadataPreviewRows) { row in
                                let count = preview.counts[row.key]
                                Text("\(row.label)：当前 \(previewCount(count?.current)) → 恢复后 \(previewCount(count?.staged))，变化 \(previewDelta(count?.delta))")
                                    .font(.caption)
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            IsleGroupSpacing(height: 4)
                            ForEach(preview.warnings, id: \.self) { warning in
                                Text(previewWarning(warning))
                                    .font(.caption)
                                    .foregroundStyle(IsleTheme.warningText)
                            }
                            Button("验证身份并应用这些数据库…") { model.activateRestoredMetadata() }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(model.state != .online || model.activatingMetadata || model.backupStatus?.running == true)
                        }
                    }
                }
            }
            AppleSettingsRow(title: "恢复后重新扫描媒体", icon: "arrow.clockwise.circle", iconTint: .teal) {
                Button("重建图库与影视索引") { model.rebuildMediaIndexes() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.state != .online || model.activatingMetadata || model.backupStatus?.running == true)
            }
            if let status = model.reindexRequestMessage {
                AppleSettingsRow(title: "索引任务提示") {
                    Text(status).font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "可验证的恢复版本", icon: "arrow.uturn.backward", iconTint: .orange) {
                Button(model.metadataRollbacksLoading ? "正在检查…" : "查看回退版本") { model.refreshMetadataRollbacks() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.metadataRollbacksLoading || model.activatingMetadata)
            }
            if let inventory = model.metadataRollbacks {
                if inventory.transactions.isEmpty {
                    AppleSettingsRow(title: "尚无可验证的恢复记录") {
                        Text("完成一次新版数据库激活后才会生成回退凭据。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                ForEach(inventory.transactions) { transaction in
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: transaction.activatedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(transaction.activatedAt)).formatted() : "旧版恢复记录") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(transaction.fileCount) 个元数据文件 · \(transaction.id)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            if transaction.canRollback {
                                Button("验证身份并回退…") { model.rollbackMetadata(transaction) }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(model.state == .starting || model.state == .stopping || model.backupStatus?.running == true || model.activatingMetadata)
                            } else {
                                Text(transaction.state == "rolled_back" ? "此版本已回退，前后数据均已保留" : "暂不可回退：\(transaction.reason ?? "无法验证记录")")
                                    .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            }
                        }
                    }
                }
                if inventory.truncated {
                    AppleSettingsRow(title: "本次检查不完整") {
                        Text("恢复记录或校验数据较多，已达到本次安全检查上限。")
                            .font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
            }
            if let error = model.metadataRollbackError {
                AppleSettingsRow(title: "回退记录检查失败", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                    Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                }
            }
            if let message = model.metadataActivationMessage {
                AppleSettingsRow(title: "数据库操作结果") {
                    Text(message).font(.caption).foregroundStyle(IsleTheme.secondaryText).textSelection(.enabled)
                }
            }
        }
    }

    var metadataPreviewRows: [MetadataPreviewRow] {
        [
            MetadataPreviewRow(key: "accounts.users", label: "账号"),
            MetadataPreviewRow(key: "accounts.fileGrants", label: "旧目录授权"),
            MetadataPreviewRow(key: "accounts.rootFileGrants", label: "共享根授权"),
            MetadataPreviewRow(key: "accounts.rootFileShares", label: "临时目录分享"),
            MetadataPreviewRow(key: "gallery.privateAlbums", label: "私人相册"),
            MetadataPreviewRow(key: "gallery.privateAlbumItems", label: "私人相册项目"),
            MetadataPreviewRow(key: "gallery.favorites", label: "收藏"),
            MetadataPreviewRow(key: "gallery.manualAlbums", label: "手工相册"),
            MetadataPreviewRow(key: "gallery.indexedAssets", label: "图库索引项目"),
            MetadataPreviewRow(key: "cinema.manualTitles", label: "手工影视标题"),
            MetadataPreviewRow(key: "cinema.indexedFilms", label: "影视索引项目"),
            MetadataPreviewRow(key: "tasks.journal", label: "任务摘要"),
            MetadataPreviewRow(key: "tasks.history", label: "任务历史")
        ]
    }

    func previewCount(_ value: Int64?) -> String {
        value.map { $0.formatted() } ?? "未知"
    }

    func previewDelta(_ value: Int64?) -> String {
        guard let value else { return "未知" }
        return value > 0 ? "+\(value.formatted())" : value.formatted()
    }

    func previewWarning(_ code: String) -> String {
        switch code {
        case "previous_database_preserved": return "激活前的数据库会另行保留，可从回退记录恢复。"
        case "files_and_metadata_snapshot_time_may_differ": return "共享原片与数据库备份可能来自不同时间点。"
        case "source_files_not_replaced": return "本次只恢复应用数据库，不覆盖共享原片。"
        case "media_indexes_rebuildable": return "图库与影视索引可重建；恢复后可手动重新扫描。"
        case "sessions_and_file_shares_cleared": return "网页登录会失效，旧文件分享链接会清除。"
        case "some_counts_unknown_for_legacy_schema": return "旧版数据库或缺少表的项目显示为未知。"
        default: return "部分数据库统计未知，请结合恢复后的检查确认。"
        }
    }
}
