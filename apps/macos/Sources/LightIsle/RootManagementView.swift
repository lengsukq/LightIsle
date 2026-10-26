import AppKit
import SwiftUI

struct RootManagementView: View {
    @ObservedObject var model: NativeRootsModel

    var body: some View {
        AppleSettingsGroup(title: "多目录预览", footer: "此预览由开发环境显式开启。原共享目录沿用已有设置；额外目录的成员权限需在 Web 中分别授予。更换磁盘不会自动转移相册与分享。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("添加目录…") { model.addFolder() }
                    Button("刷新") { model.refresh() }
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(!model.connected || model.busy)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("旧单目录升级影响检查").font(.subheadline.weight(.semibold))
                            Text("只读预览旧账号权限、相册和观看记录；不会迁移、删除或自动授权。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("检查旧数据…") { model.previewLegacyMigration() }
                            .disabled(!model.connected || model.busy)
                        if model.legacyRoot?.pending == true {
                            Button("验证旧盘身份…") { model.verifyLegacyRoot() }
                                .disabled(!model.connected || model.busy)
                        }
                    }
                    if let preview = model.legacyMigrationPreview {
                        let counts = preview.counts
                        Text(preview.physicalRootVerified ? "原目录物理身份：已核实" : "原目录物理身份：未核实，请先确认旧盘连接")
                            .font(.caption).foregroundStyle(preview.physicalRootVerified ? Color.secondary : Color.orange)
                        Text("成员 \(counts.members) · 旧目录授权 \(counts.fileGrants) · 旧分享 \(counts.fileShares) · 多根授权 \(counts.rootGrants)")
                            .font(.caption).textSelection(.enabled)
                        Text("旧图库 \(counts.photos) · 共享相册 \(counts.sharedAlbums) · 私人相册 \(counts.privateAlbums)（包含 \(counts.privateAlbumItems) 条关联）· 个人收藏 \(counts.personalFavorites)")
                            .font(.caption).textSelection(.enabled)
                        Text("旧影视 \(counts.films) · 观看记录 \(counts.watchProgress)")
                            .font(.caption).textSelection(.enabled)
                        if preview.physicalRootVerified, let scoped = preview.scoped {
                            Text("确认属于当前旧盘：图片 \(scoped.photos) · 私人相册 \(scoped.privateAlbums) · 个人收藏 \(scoped.personalFavorites)")
                                .font(.caption).foregroundStyle(.primary)
                            Text("确认属于当前旧盘：视频 \(scoped.films) · 观看进度 \(scoped.watchProgress)")
                                .font(.caption).foregroundStyle(.primary)
                            if scoped.otherPhotos > 0 || scoped.otherFilms > 0 {
                                Text("另有 \(scoped.otherPhotos) 张照片和 \(scoped.otherFilms) 部影片来自其他历史共享路径：不会将这些记录算入当前硬盘的迁移范围。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text("上面的总数包含旧数据库的历史路径；只有经过物理身份验证、按当前目录筛选的数量才可用于规划。正式迁移尚未开放，不会自动复制权限或替换数据库。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
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
                            Button("从快照提取副本…") { model.stageRestore() }
                            if model.backupStatus?.running == true { Button("取消任务") { model.cancelBackup() } }
                        }
                        .disabled(!model.connected || model.busy || !selected.online)
                        if let status = model.backupStatus {
                            Text(status.running ? "已处理 \(status.files) 个文件" : "当前没有正在进行的任务")
                                .font(.caption).foregroundStyle(.secondary)
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
