import AppKit
import SwiftUI

struct RootManagementView: View {
    @ObservedObject var model: NativeRootsModel

    var body: some View {
        AppleSettingsGroup(title: "多根存储（开发预览）", footer: "每个用户可拥有固定的文件、照片、视频目录，三类目录可以分配到不同硬盘。新增成员默认规划 100 GiB 总额度，管理员不限额；真实写入配额校验仍需后端闭环。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("添加目录…") { model.addFolder() }
                    Button("刷新") { model.refresh() }
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(!model.connected || model.busy)
                Text("新增硬盘后，请在 Web → 账号与安全 → 成员存储空间中为每位用户选择分类存储位置。选择后会自动创建专属目录并配置成员目录授权；旧数据迁移不作为新安装版本的开发范围。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.additionalRoots.isEmpty {
                    Text("尚未添加额外目录。原共享目录继续可用。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("额外共享目录", selection: $model.selectedID) {
                        ForEach(model.additionalRoots) { root in
                            Text(root.name + (root.online ? "" : " · 离线")).tag(root.rootID)
                        }
                    }
                    .disabled(!model.connected || model.busy)
                    .onChange(of: model.selectedID) { _, _ in model.selectionChanged() }
                    if let selected = model.selected {
                        Text(selected.path).font(.caption.monospaced()).textSelection(.enabled)
                        rootBackupPlanSection(selected)
                        if let scan = selected.maintenance {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("图库与影视自动检查：\(maintenanceLabel(scan.status))")
                                    .font(.caption).foregroundStyle(scan.status == "failed" || scan.status == "offline" ? Color.orange : Color.secondary)
                                if scan.lastSuccess > 0 {
                                    Text("最近完整检查：\(Date(timeIntervalSince1970: TimeInterval(scan.lastSuccess)).formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Text("开发预览中每 15 分钟依次检查额外目录；离线或被任务占用会重试。状态仅在刷新目录时更新，不会自动备份文件。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("重新选择目录…") { model.reconnectSelected() }
                            Button("移除登记…") { model.removeSelected() }
                            Spacer()
                        }
                        .disabled(!model.connected || model.busy || model.backupStatus?.running == true)
                        HStack {
                            Button("备份此目录…") { model.startBackup() }
                                .disabled(!model.connected || model.busy || !selected.online)
                            Button("从快照提取副本…") { model.stageRestore() }
                                .disabled(!model.connected || model.busy || !selected.online)
                            if let status = model.backupStatus, status.running {
                                Button(status.operation == "restore" ? "取消本次提取" : "取消本次备份") { model.cancelBackup() }
                                    .disabled(!model.connected || model.busy)
                            }
                        }
                        if let status = model.backupStatus {
                            if status.running {
                                let processedBytes = ByteCountFormatter.string(fromByteCount: max(0, status.bytes), countStyle: .file)
                                Text("正在\(status.operation == "restore" ? "提取" : "备份")：已处理 \(status.files) 个文件 · \(processedBytes)")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("当前没有正在进行的任务")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let path = status.lastSnapshot, !path.isEmpty {
                                Button("在访达中查看备份") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                            }
                            if let path = status.restoredMetadata, !path.isEmpty {
                                Text("数据库副本已提取，请先在访达中保留并核对。此预览不会自动应用。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func rootBackupPlanSection(_ root: NativeSharedRoot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("此目录的定时备份").font(.subheadline.weight(.semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if let plan = model.backupPlan {
                    Text(plan.enabled ? "已启用" : (needsPlanRepair(plan) ? "需检查" : (plan.destination?.isEmpty == false ? "已停用" : "尚未设置")))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(plan.enabled ? Color.green : (needsPlanRepair(plan) ? Color.orange : Color.secondary))
                }
            }
            Text("仅备份这个共享根的文件快照。快照中的元数据只能隔离提取；此计划不承诺单独恢复完整 NAS。")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("保留快照", selection: Binding(
                    get: { min(30, max(0, model.backupPlanRetentionDraft ?? model.backupPlan?.retentionCount ?? 0)) },
                    set: { model.backupPlanRetentionDraft = $0 }
                )) {
                    Text("保留所有（不自动清理）").tag(0)
                    ForEach(1...30, id: \.self) { count in
                        Text("最近 \(count) 个").tag(count)
                    }
                }
                .frame(width: 205)
                .disabled(!model.connected || model.busy || !root.online || root.pending)
                Spacer()
            }

            HStack(spacing: 8) {
                Button("每天…") { model.configureBackupPlan(everyHours: 24) }
                    .buttonStyle(LiquidButtonStyle(variant: model.backupPlan?.enabled == true && model.backupPlan?.everyHours == 24 ? .prominent : .secondary, size: .small))
                    .disabled(!model.connected || model.busy || !root.online || root.pending)
                Button("每周…") { model.configureBackupPlan(everyHours: 168) }
                    .buttonStyle(LiquidButtonStyle(variant: model.backupPlan?.enabled == true && model.backupPlan?.everyHours == 168 ? .prominent : .secondary, size: .small))
                    .disabled(!model.connected || model.busy || !root.online || root.pending)
                Button("停用") { model.disableBackupPlan() }
                    .buttonStyle(LiquidButtonStyle(variant: model.backupPlan?.enabled == false && model.backupPlan?.destination?.isEmpty == false ? .prominent : .secondary, size: .small))
                    .disabled(!model.connected || model.busy || root.pending || model.backupPlan?.enabled != true)
                Spacer()
                if !root.online {
                    Text(model.backupPlan?.enabled == true ? "来源离线：可停用，重连后按计划继续" : "来源离线：计划状态仍可读取")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if model.backupStatus?.running == true {
                Text(model.backupStatus?.operation == "backup"
                     ? "本次备份仍在进行；停用只停止后续计划。要结束本次备份，请点“取消本次备份”。"
                     : "当前任务仍在进行；停用只停止后续计划。要结束本次任务，请点“取消当前任务”。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if model.backupPlan?.enabled == true {
                Text("停用只停止后续计划；已开始的本次任务会继续完成。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let plan = model.backupPlan {
                let hasSavedPlan = plan.destination?.isEmpty == false
                if plan.enabled, plan.nextRun > 0 {
                    Text("下次运行：\(Date(timeIntervalSince1970: TimeInterval(plan.nextRun)).formatted(date: .abbreviated, time: .shortened)) · 每 \(plan.everyHours) 小时")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if hasSavedPlan, let destination = plan.destination {
                    Text("目的地：\(destination)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Text(plan.retentionCount == 0 ? "保留所有计划快照，不自动清理" : "保留最近 \(plan.retentionCount) 个计划快照")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !plan.enabled {
                    Text("尚未为此目录设置计划备份。选择周期后再指定一个独立目的地。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if plan.lastAttempt > 0 {
                    Text("最近尝试：\(Date(timeIntervalSince1970: TimeInterval(plan.lastAttempt)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let lastError = plan.lastError, !lastError.isEmpty {
                    Text("\(needsPlanRepair(plan) ? "计划状态异常" : "上次尝试失败")：\(rootBackupPlanFailureDescription(lastError))")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    if needsPlanRepair(plan), let detail = plan.lastErrorDetail,
                       !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(detail)
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else if model.connected && !model.busy {
                Text("尚未读取计划状态，请刷新目录列表重试。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func rootBackupPlanFailureDescription(_ code: String) -> String {
        if let description = NativeRootBackupPlanPresentation.failureDescription(code, detail: model.backupPlan?.lastErrorDetail) {
            return description
        }
        switch code {
        case "backup_root_binding_changed": return "共享目录身份或代际已变化，已停止此旧计划；请刷新并为当前目录重新设置。"
        case "root_backup_plan_unavailable": return "本机计划备份服务暂不可用，请检查 Core 服务状态后重试。"
        case "invalid_backup_location_or_manifest": return "备份目的地无效，已跳过本次计划任务。"
        case "root_registry_pending": return "此共享目录身份尚未核实，不能配置或运行计划备份。"
        case "backup_destination_overlaps_registered_root": return "备份目的地与共享目录重叠，已跳过本次计划任务。"
        case "backup_destination_overlaps_private_data": return "备份目的地位于轻屿应用数据目录中，已跳过本次计划任务。"
        case "backup_retention_invalid": return "保留数量无效，未清理任何快照。"
        default: return backupFailureDescription(code)
        }
    }

    private func needsPlanRepair(_ plan: NativeRootBackupPlan) -> Bool {
        guard let code = plan.lastError else { return false }
        return code == "root_backup_plan_config_invalid" || code == "root_backup_plan_config_unsafe" ||
            code == "root_backup_plan_archive_failed"
    }

    private func maintenanceLabel(_ status: String) -> String {
        switch status {
        case "ok": return "上次扫描完成"
        case "running": return "正在扫描"
        case "offline": return "目录离线，等待重试"
        case "busy": return "正在运行其他扫描，等待重试"
        case "failed": return "扫描未完成，请查看任务记录"
        case "interrupted": return "上次扫描被应用退出中断，等待重试"
        default: return "尚未完成首次检查"
        }
    }
}
