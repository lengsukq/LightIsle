import SwiftUI

// Switching the selected default and copying old data are intentionally
// separate owner actions: selecting a disk never starts a migration.
struct RootManagementView: View {
    @ObservedObject var model: NativeRootsModel

    var body: some View {
        AppleSettingsGroup(title: "NAS 存储空间",
                           footer: "统一由 RootRegistry 管理多硬盘。可直接选择文件夹切换默认目录，旧数据复制须单独预览并确认。") {
            AppleSettingsRow(
                title: "存储目录登记",
                subtitle: "可在左侧「个人空间」或 Flutter 管理员端分配每位成员与管理员的文件、照片和视频目录及配额。硬盘离线时先检查连接；无法修复时可移除旧登记并重新创建空白存储空间。",
                icon: "folder.badge.gearshape",
                iconTint: .blue
            ) {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("管理个人空间与配额…") { AppModel.shared.navigate(to: .spaces) }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("选择文件夹并切换…") { model.selectFolderAndSwitch() }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    Button("添加目录…") { model.addFolder() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("刷新") { model.refresh() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                .disabled(!model.connected || model.busy)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            VStack(alignment: .leading, spacing: 12) {
                if model.additionalRoots.isEmpty {
                    Text("暂未登记 NAS 存储目录，请点击上方「选择文件夹并切换」或「添加目录」。")
                        .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                } else {
                    HStack(spacing: 12) {
                        Picker("共享目录", selection: $model.selectedID) {
                            ForEach(model.additionalRoots) { root in
                                Text(root.name + (root.online ? "" : " · 离线")).tag(root.rootID)
                            }
                        }
                        .frame(maxWidth: 320)
                        .disabled(!model.connected || model.busy)
                        .onChange(of: model.selectedID) { _, _ in model.selectionChanged() }
                        if let selected = model.selected {
                            if selected.isDefault == true {
                                IsleStatusPill(text: "默认 NAS 存储", tone: .success, icon: "checkmark.circle.fill")
                            }
                            IsleStatusPill(
                                text: selected.online ? "在线" : "离线",
                                tone: selected.online ? .success : .warning,
                                showDot: true
                            )
                        }
                        Spacer()
                    }
                    if let selected = model.selected {
                        Text(selected.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .textSelection(.enabled)
                        if !selected.online {
                            Label("硬盘未连接。检查供电、数据线和访达挂载状态后刷新；LightIsle 不会自动清理旧文件。", systemImage: "externaldrive.badge.exclamationmark")
                                .font(.caption).foregroundStyle(IsleTheme.warningText)
                        } else if selected.pending {
                            Text("目录身份尚未确认，请重新连接原来的物理目录。")
                                .font(.caption).foregroundStyle(IsleTheme.warningText)
                        }
                        HStack(spacing: 8) {
                            Button("设为默认存储") { model.makeSelectedDefault() }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(!selected.online || selected.isDefault == true)
                            Button("重新连接原目录…") { model.reconnectSelected() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            Button("移除登记…") { model.removeSelected() }
                                .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                        }
                        .disabled(!model.connected || model.busy)
                    }
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(IsleTheme.secondaryText).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        AppleSettingsGroup(title: "旧数据迁移（复制）",
                           footer: "仅复制普通共享文件、照片及影视原文件；默认盘不会变化，原数据不会删除。Users 私人目录及账号权限、相册收藏、媒体索引等元数据暂不自动迁移。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Picker("来源目录", selection: $model.migrationSourceID) {
                        Text("请选择").tag("")
                        ForEach(model.additionalRoots) { root in
                            Text(root.name + (root.online ? "" : " · 离线")).tag(root.rootID)
                        }
                    }
                    .frame(maxWidth: 280)
                    Picker("目标目录", selection: $model.migrationTargetID) {
                        Text("请选择").tag("")
                        ForEach(model.additionalRoots) { root in
                            Text(root.name + (root.online ? "" : " · 离线")).tag(root.rootID)
                        }
                    }
                    .frame(maxWidth: 280)
                    Spacer()
                }
                .disabled(!model.connected || model.busy ||
                          model.migrationStatus?.phase == "running" ||
                          model.migrationStatus?.phase == "previewing")
                .onChange(of: model.migrationSourceID) { _, _ in model.migrationSelectionChanged() }
                .onChange(of: model.migrationTargetID) { _, _ in model.migrationSelectionChanged() }
                HStack(spacing: 10) {
                    Button("预览待迁移文件") { model.previewMigration() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(!model.connected || model.busy ||
                                  model.migrationStatus?.phase == "running" ||
                                  model.migrationStatus?.phase == "previewing" ||
                                  model.migrationSourceID.isEmpty || model.migrationTargetID.isEmpty ||
                                  model.migrationSourceID == model.migrationTargetID)
                    if model.migrationPreview != nil {
                        Button("开始复制…") { model.startMigration() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(!model.connected || model.busy ||
                                      model.migrationStatus?.phase == "running" ||
                                      model.migrationStatus?.phase == "previewing" ||
                                      model.migrationPreview?.hasEnoughSpace != true)
                    }
                    if model.migrationStatus?.phase == "running" ||
                       model.migrationStatus?.phase == "previewing" {
                        Button(model.migrationStatus?.phase == "previewing" ? "取消预览" : "取消复制") { model.cancelMigration() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.busy)
                    }
                    if model.busy {
                        ProgressView().controlSize(.small)
                    }
                }
                if let preview = model.migrationPreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("待复制 \(preview.filesToCopy) 个文件 · \(ByteCountFormatter.string(fromByteCount: preview.bytesToCopy, countStyle: .file))")
                            .font(.system(size: 12, weight: .medium))
                        Text("将新建 \(preview.directoriesToMake) 个目录 · 已存在/冲突 \(preview.conflicts) 项（不覆盖）")
                        Text("目标剩余 \(ByteCountFormatter.string(fromByteCount: preview.targetFreeBytes, countStyle: .file))")
                        if !preview.hasEnoughSpace {
                            Text("剩余空间不足：本次迁移需预留额外磁盘空间，无法开始。")
                                .foregroundStyle(IsleTheme.warningText)
                        }
                        if preview.protectedFolders > 0 || preview.unsupportedEntries > 0 {
                            Text("受保护私人目录 \(preview.protectedFolders) 处 · 跳过内部/不支持项目 \(preview.unsupportedEntries) 项")
                                .foregroundStyle(IsleTheme.warningText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
                }
                if let status = model.migrationStatus, status.phase != "idle" {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(status.phase == "previewing" ? "正在扫描旧目录（可取消）" :
                                 status.phase == "previewed" ? "预览完成" :
                                 status.phase == "running" ? "正在复制" :
                                 status.phase == "completed" ? "复制完成" :
                                 status.phase == "cancelled" ? "已取消" : "复制中断")
                            Spacer()
                            Text("\(status.copiedFiles) / \(status.preview.filesToCopy) 个文件")
                        }
                        if status.phase == "previewing" {
                            ProgressView().controlSize(.small)
                        } else {
                            ProgressView(value: Double(status.copiedBytes),
                                         total: Double(max(status.preview.bytesToCopy, 1)))
                        }
                        Text("已复制 \(ByteCountFormatter.string(fromByteCount: status.copiedBytes, countStyle: .file)) · 本次遇到 \(status.skippedFiles) 个新冲突")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        if let error = status.error {
                            Text(error == "migration_interrupted_by_restart"
                                 ? "Core 重启导致中断；重新预览后继续，不会覆盖目标现有文件。"
                                 : error)
                                .font(.caption).foregroundStyle(IsleTheme.warningText)
                        }
                    }
                }
                Text("复制完成后请检查目标目录与成员授权。移除旧目录登记也不会删除旧盘数据。")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            .padding(14)
        }
    }
}
