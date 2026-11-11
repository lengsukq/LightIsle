import AppKit
import SwiftUI

// Switching the selected default and copying old data are intentionally
// separate owner actions: selecting a disk never starts a migration.
struct RootManagementView: View {
    @ObservedObject var model: NativeRootsModel

    var body: some View {
        AppleSettingsGroup(
            title: "1. 存储目录管理（默认主目录与多目录空间池）",
            footer: "互不嵌套的目录均可作为独立存储空间；添加或切换目录时直接校验整盘与目录读写权限，获取失败将自动回滚。要为用户分配目录或将旧目录数据迁移到新目录，请点击「用户空间与目录迁移…」。"
        ) {
            AppleSettingsRow(
                title: "已登记的存储目录",
                subtitle: "包含初始化设定的默认主目录与后续扩展的外置硬盘/独立目录。",
                icon: "folder.badge.gearshape",
                iconTint: .blue
            ) {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("权限与初始化预检…") {
                        AppModel.shared.navigateToSettingsDetail(.permissions)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))

                    Button("用户空间与目录迁移…") {
                        AppModel.shared.navigate(to: .spaces)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))

                    Button("切换默认主目录…") { model.selectFolderAndSwitch() }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    Button("+ 添加存储目录…") { model.addFolder() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("刷新") { model.refresh() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                .disabled(!model.connected || model.busy)
            }

            IsleGroupSpacing(height: 4).padding(.leading, 14)

            VStack(alignment: .leading, spacing: 10) {
                if model.additionalRoots.isEmpty {
                    Text("暂未登记存储目录，请点击上方「切换默认主目录」或「+ 添加存储目录」。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                } else {
                    ForEach(model.additionalRoots) { root in
                        registeredRootRow(root)
                    }
                }

                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func registeredRootRow(_ root: NativeSharedRoot) -> some View {
        let probe = root.online
            ? StoragePermissionHelper.probeDirectoryReadWrite(at: URL(fileURLWithPath: root.path, isDirectory: true))
            : nil
        let isWritable = probe?.isWritable == true

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: root.path.hasPrefix("/Volumes/") ? "externaldrive.fill" : "folder.fill")
                    .foregroundStyle(root.online && isWritable ? IsleTheme.accent : .orange)
                Text(root.name)
                    .font(.system(size: 13, weight: .semibold))

                if root.isDefault == true {
                    IsleStatusPill(text: "默认主目录", tone: .accent, icon: "checkmark.circle.fill")
                }

                IsleStatusPill(
                    text: root.online ? "在线" : "离线",
                    tone: root.online ? .success : .warning,
                    showDot: true
                )

                if root.online, let probe {
                    IsleStatusPill(
                        text: probe.isWritable ? "整盘与目录可读写" : probe.statusSummary,
                        tone: probe.isWritable ? .success : .error,
                        showDot: true
                    )
                }

                Spacer()

                HStack(spacing: 6) {
                    if root.online && root.isDefault != true {
                        Button("设为默认") {
                            model.selectedID = root.rootID
                            model.makeSelectedDefault()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }

                    if root.online {
                        Button(isWritable ? "校验读写" : "获取读写权限…") {
                            Task { @MainActor in
                                let access = await StoragePermissionHelper.requestReadWriteAccess(
                                    forPath: root.path,
                                    reason: "需要获取并验证「\(root.name)」及其所属整盘的读写权限，以确保数据读写与跨目录迁移正常执行。",
                                    initialProbe: probe
                                )
                                guard access.ok else {
                                    model.message = access.errorMessage
                                    return
                                }
                                model.verifyAccess(path: root.path, autoRepairOnDenied: true)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: isWritable ? .secondary : .prominent, size: .small))
                    }

                    Button("迁移此目录数据…") {
                        AppModel.shared.navigate(to: .spaces)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))

                    if !root.online || root.pending {
                        Button("重新连接…") {
                            model.selectedID = root.rootID
                            model.reconnectSelected()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }

                    Button("移除登记…") {
                        model.selectedID = root.rootID
                        model.removeSelected()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                }
                .disabled(!model.connected || model.busy)
            }

            Text(root.path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(IsleTheme.secondaryText)
                .textSelection(.enabled)

            if !root.online {
                Label("硬盘未连接。请检查供电、数据线和访达挂载状态后刷新；轻屿不会自动删除旧目录文件。", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
            } else if root.pending {
                Text("目录身份尚未确认，请重新连接原来的物理目录。")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
            } else if let probe, !probe.isWritable, let detail = probe.detailMessage {
                Label(detail, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.errorText)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}
