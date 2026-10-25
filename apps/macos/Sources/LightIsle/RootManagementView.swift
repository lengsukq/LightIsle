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
