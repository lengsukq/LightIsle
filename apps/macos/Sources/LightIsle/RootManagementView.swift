import SwiftUI

// Switching the selected default and copying old data are intentionally
// separate owner actions: selecting a disk never starts a migration.
struct RootManagementView: View {
    @ObservedObject var model: NativeRootsModel

    var body: some View {
        AppleSettingsGroup(title: "NAS 存储空间",
                           footer: "统一由 RootRegistry 管理多块存储硬盘登记。如需更换个人文件、相册或影视所在的硬盘并迁移数据，请前往「个人空间」统一操作。") {
            AppleSettingsRow(
                title: "存储目录登记",
                subtitle: "登记外置硬盘或专用目录作为可用存储池。成员与管理员的文件、相册、影视分类绑定、配额与跨盘数据迁移统一在左侧「个人空间」管理。",
                icon: "folder.badge.gearshape",
                iconTint: .blue
            ) {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("前往个人空间管理与迁移…") { AppModel.shared.navigate(to: .spaces) }
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
    }
}
