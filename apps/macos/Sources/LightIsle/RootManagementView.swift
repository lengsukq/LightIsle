import SwiftUI

// Keep the Mac administration surface focused on disk registration and simple
// recovery. Per-root full backups, legacy migration and plan state are gone.
struct RootManagementView: View {
    @ObservedObject var model: NativeRootsModel

    var body: some View {
        AppleSettingsGroup(title: "家庭存储空间（开发预览）",
                           footer: "只管理磁盘登记。应用配置在“备份”设置中单独保存；LightIsle 不提供整盘备份或还原。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("添加目录…") { model.addFolder() }
                    Button("刷新") { model.refresh() }
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(!model.connected || model.busy)
                Text("在 Web → 成员存储空间分配每位成员的文件、照片和视频目录。硬盘离线时先检查连接；无法修复时可移除旧登记并重新创建空白存储空间。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.additionalRoots.isEmpty {
                    Text("暂未添加其他共享目录。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("共享目录", selection: $model.selectedID) {
                        ForEach(model.additionalRoots) { root in
                            Text(root.name + (root.online ? "" : " · 离线")).tag(root.rootID)
                        }
                    }
                    .disabled(!model.connected || model.busy)
                    .onChange(of: model.selectedID) { _, _ in model.selectionChanged() }
                    if let selected = model.selected {
                        Text(selected.path).font(.caption.monospaced()).textSelection(.enabled)
                        if !selected.online {
                            Label("硬盘未连接。检查供电、数据线和访达挂载状态后刷新；LightIsle 不会自动清理旧文件。", systemImage: "externaldrive.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.orange)
                        } else if selected.pending {
                            Text("目录身份尚未确认，请重新连接原来的物理目录。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("重新连接原目录…") { model.reconnectSelected() }
                            Button("移除登记…") { model.removeSelected() }
                        }
                        .disabled(!model.connected || model.busy)
                    }
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(14)
        }
    }
}
