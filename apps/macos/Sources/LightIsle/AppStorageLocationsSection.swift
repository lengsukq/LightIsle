import AppKit
import SwiftUI

struct AppStorageLocationsSection: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @State private var confirmRemoveExternal = false

    private var storage: NativeAppStorageSnapshot? {
        appsCenter.appStorage
    }

    private var internalLocation: NativeAppStorageLocation? {
        storage?.locations.first(where: { $0.kind == "internal" })
    }

    private var externalLocation: NativeAppStorageLocation? {
        storage?.locations.first(where: { $0.kind == "external" })
    }

    var body: some View {
        if let storage {
            AppleSettingsGroup(
                title: "应用数据存储位置（\(storage.locations.count)/\(storage.maxLocations)：1 内置盘 + 1 其他盘）",
                footer: "支持选择 1 个 Mac 内置盘目录与最多 1 个其他盘目录（/Volumes/…）。每个轻应用的源码（plugins）与业务数据（plugin-data）会存放在所选位置下；移除其他盘登记时仅停止运行实例，绝不删除磁盘上的已有文件。"
            ) {
                if let internalLoc = internalLocation {
                    internalRow(internalLoc)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                if let externalLoc = externalLocation {
                    externalConfiguredRow(externalLoc)
                } else {
                    externalEmptyRow(storage.availableVolumes)
                }
            }
            .confirmationDialog(
                "确认从应用中心移除其他盘登记？",
                isPresented: $confirmRemoveExternal,
                titleVisibility: .visible
            ) {
                Button("移除其他盘登记（保留硬盘文件）", role: .destructive) {
                    appsCenter.mutateAppStorage(action: "remove_external")
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("系统将先停止来自该其他盘位置的轻应用实例，仅解除登记关系，不会删除磁盘上的 plugins 与 plugin-data 数据。")
            }
        }
    }

    private func internalRow(_ loc: NativeAppStorageLocation) -> some View {
        let meta = [
            "已装 \(loc.appCount) 个应用",
            formatFreeSpace(loc),
            loc.isCustomPath ? "自定义内置目录" : "系统默认目录"
        ].compactMap { $0 }.joined(separator: " · ")

        return AppleSettingsRow(
            title: "\(loc.name) · 内置盘 1/1",
            subtitle: "\(loc.path)\n\(meta)",
            icon: "internaldrive.fill",
            iconTint: .blue
        ) {
            HStack(spacing: 8) {
                if loc.isDefault {
                    Text("默认位置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                } else {
                    Button("设为默认") {
                        appsCenter.mutateAppStorage(action: "set_default", defaultLocationID: "internal")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                }
                Button("选择目录…") {
                    chooseFolder(kind: "internal", action: "set")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
                if loc.isCustomPath {
                    Button("恢复默认") {
                        appsCenter.mutateAppStorage(action: "reset_internal")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                }
            }
        }
    }

    private func externalConfiguredRow(_ loc: NativeAppStorageLocation) -> some View {
        let statusText = loc.online ? (loc.writable ? "在线可写" : "只读") : "已离线"
        let meta = [
            "已装 \(loc.appCount) 个应用",
            formatFreeSpace(loc),
            statusText,
            loc.error
        ].compactMap { $0 }.joined(separator: " · ")

        return AppleSettingsRow(
            title: "\(loc.name) · 其他盘 1/1",
            subtitle: "\(loc.path)\n\(meta)",
            icon: "externaldrive.fill",
            iconTint: loc.online && loc.writable ? .teal : .orange
        ) {
            HStack(spacing: 8) {
                StatusBadge(isOnline: loc.online && loc.writable, text: statusText)
                if loc.isDefault {
                    Text("默认位置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                } else {
                    Button("设为默认") {
                        appsCenter.mutateAppStorage(action: "set_default", defaultLocationID: "external")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy || !loc.online || !loc.writable)
                }
                Button("更换目录…") {
                    chooseFolder(kind: "external", action: "set")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
                Button("移除登记", role: .destructive) {
                    confirmRemoveExternal = true
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
            }
        }
    }

    private func externalEmptyRow(_ volumes: [NativeAppStorageVolumeOption]) -> some View {
        AppleSettingsRow(
            title: "外置 / 其他盘位置（可选 · 0/1）",
            subtitle: "最多可额外添加 1 个外置磁盘位置（/Volumes/磁盘名/LightIsleApps），添加后可在安装或创建插件时自由选择",
            icon: "externaldrive.badge.plus",
            iconTint: .purple
        ) {
            HStack(spacing: 8) {
                ForEach(volumes.filter { !$0.readOnly }.prefix(2)) { vol in
                    Button("使用「\(vol.name)」") {
                        appsCenter.setAppStorageWithPermission(
                            action: "add",
                            kind: "external",
                            path: vol.suggestedPath,
                            name: vol.name
                        )
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                }
                Button("选择其他盘目录…") {
                    chooseFolder(kind: "external", action: "add")
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                .disabled(appsCenter.busy)
            }
        }
    }

    private func formatFreeSpace(_ loc: NativeAppStorageLocation) -> String? {
        guard let free = loc.freeBytes, free > 0 else { return nil }
        let freeText = ByteCountFormatter.string(fromByteCount: Int64(min(free, UInt64(Int64.max))), countStyle: .file)
        if let total = loc.totalBytes, total > 0 {
            let totalText = ByteCountFormatter.string(fromByteCount: Int64(min(total, UInt64(Int64.max))), countStyle: .file)
            return "余 \(freeText) / \(totalText)"
        }
        return "余 \(freeText)"
    }

    private func chooseFolder(kind: String, action: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = kind == "external" ? "选择其他盘应用存储目录" : "选择 Mac 内置盘应用存储目录"
        panel.message = kind == "external"
            ? "请选择位于 /Volumes/ 下的外置或非系统磁盘文件夹（推荐新建 LightIsleApps 子目录）"
            : "请选择 Mac 内置磁盘上的文件夹"
        if kind == "external", let volURL = URL(string: "file:///Volumes") {
            panel.directoryURL = volURL
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                appsCenter.setAppStorageWithPermission(
                    action: action,
                    kind: kind,
                    path: url.path
                )
            }
        }
    }
}
