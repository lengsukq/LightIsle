import AppKit
import SwiftUI

struct AppStorageLocationsSection: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @State private var confirmRemoveExternal = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("应用数据存储位置")
                        .font(.system(size: 15, weight: .semibold))
                    IsleStatusPill(
                        text: "\(storage.locations.count)/\(storage.maxLocations) 位置",
                        tone: .neutral
                    )
                    Spacer()
                    Text("最多 1 个内置盘 + 1 个其他盘 · 移除仅解绑，不删文件")
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    if let internalLoc = internalLocation {
                        internalCard(internalLoc)
                    }
                    if let externalLoc = externalLocation {
                        externalConfiguredCard(externalLoc)
                    } else {
                        externalEmptyCard(storage.availableVolumes)
                    }
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

    private func internalCard(_ loc: NativeAppStorageLocation) -> some View {
        let meta = [
            "已装 \(loc.appCount) 个应用",
            formatFreeSpace(loc),
            loc.isCustomPath ? "自定义内置目录" : "系统默认目录"
        ].compactMap { $0 }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IsleHeaderIconBadge(icon: "internaldrive.fill", tint: IsleFluidPalette.brandBlue, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(loc.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        IsleStatusPill(text: "内置盘", tone: .neutral)
                        if loc.isDefault {
                            IsleStatusPill(text: "默认安装盘", tone: .accent)
                        }
                    }
                    Text(loc.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(loc.path)
                }
                Spacer(minLength: 0)
            }

            Text(meta)
                .font(.system(size: 12))
                .foregroundStyle(IsleTheme.secondaryText)
                .lineLimit(1)

            Divider().opacity(0.45)

            HStack(spacing: 8) {
                if !loc.isDefault {
                    Button("设为默认") {
                        appsCenter.mutateAppStorage(action: "set_default", defaultLocationID: "internal")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                }
                Button("更改目录…") {
                    chooseFolder(kind: "internal", action: "set")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
                if loc.isCustomPath {
                    Button("恢复默认") {
                        appsCenter.mutateAppStorage(action: "reset_internal")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                    .disabled(appsCenter.busy)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleEmbossedSurface())
    }

    private func externalConfiguredCard(_ loc: NativeAppStorageLocation) -> some View {
        let healthy = loc.online && loc.writable
        let statusText = loc.online ? (loc.writable ? "在线可写" : "只读") : "已离线"
        let meta = [
            "已装 \(loc.appCount) 个应用",
            formatFreeSpace(loc),
            loc.error
        ].compactMap { $0 }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IsleHeaderIconBadge(
                    icon: "externaldrive.fill",
                    tint: healthy ? IsleFluidPalette.brandCyan : .orange,
                    size: 38
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(loc.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        IsleStatusPill(
                            text: statusText,
                            tone: healthy ? .success : .warning,
                            showDot: true
                        )
                        if loc.isDefault {
                            IsleStatusPill(text: "默认安装盘", tone: .accent)
                        }
                    }
                    Text(loc.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(loc.path)
                }
                Spacer(minLength: 0)
            }

            Text(meta.isEmpty ? "外置磁盘已绑定到应用中心" : meta)
                .font(.system(size: 12))
                .foregroundStyle(loc.error == nil ? IsleTheme.secondaryText : IsleTheme.warningText)
                .lineLimit(2)

            Divider().opacity(0.45)

            HStack(spacing: 8) {
                if !loc.isDefault {
                    Button("设为默认") {
                        appsCenter.mutateAppStorage(action: "set_default", defaultLocationID: "external")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy || !healthy)
                }
                Button("更换目录…") {
                    chooseFolder(kind: "external", action: "set")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
                Spacer(minLength: 4)
                Button("移除登记", role: .destructive) {
                    confirmRemoveExternal = true
                }
                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                .disabled(appsCenter.busy)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleEmbossedSurface())
    }

    private func externalEmptyCard(_ volumes: [NativeAppStorageVolumeOption]) -> some View {
        let writableVolumes = volumes.filter { !$0.readOnly }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IsleHeaderIconBadge(icon: "externaldrive.badge.plus", tint: IsleFluidPalette.brandViolet, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("添加其他盘存储位置")
                            .font(.system(size: 14.5, weight: .semibold))
                        IsleStatusPill(text: "可选 · 0/1", tone: .neutral)
                    }
                    Text("将应用与数据放到外置高速磁盘（/Volumes/…），安装和新建时自由挑选。")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                ForEach(writableVolumes.prefix(2)) { vol in
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
                Button("选择其他盘…") {
                    chooseFolder(kind: "external", action: "add")
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                .disabled(appsCenter.busy)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleEmbossedSurface())
    }

    private func formatFreeSpace(_ loc: NativeAppStorageLocation) -> String? {
        guard let free = loc.freeBytes, free > 0 else { return nil }
        let freeText = Self.byteFormatter.string(fromByteCount: Int64(min(free, UInt64(Int64.max))))
        if let total = loc.totalBytes, total > 0 {
            let totalText = Self.byteFormatter.string(fromByteCount: Int64(min(total, UInt64(Int64.max))))
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
