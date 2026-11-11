import SwiftUI
import AppKit

extension ContentView {
    var storageView: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let detail = storageDetail {
                Group {
                    switch detail {
                    case .disks: storageDisksContent
                    case .locations: storageLocationsContent.disabled(model.isPresentationPreview)
                    case .capacity: storageCapacityContent.disabled(model.isPresentationPreview)
                    case .backup: storageBackupContent.disabled(model.isPresentationPreview)
                    case .timeMachine: storageTimeMachineContent.disabled(model.isPresentationPreview)
                    }
                }
            } else {
                storageSummary
                IsleDestinationGrid {
                    ForEach(Array(StorageDetail.allCases.enumerated()), id: \.element.id) { index, detail in
                        let status = storageBadge(for: detail)
                        IsleDestinationRow(
                            title: detail.rawValue,
                            subtitle: detail.subtitle,
                            icon: detail.icon,
                            badge: status.0,
                            badgeTone: status.1,
                            iconTint: storageIconTint(for: detail)
                        ) {
                            requestLocalNavigation { storageDetail = detail }
                        }.modifier(IsleCascade(index: index)).id(detail.id)
                    }
                }
            }
        }
    }
    private func storageIconTint(for detail: StorageDetail) -> Color {
        switch detail {
        case .disks: return IsleFluidPalette.brandBlue
        case .locations: return IsleFluidPalette.brandCyan
        case .capacity: return .orange
        case .backup: return IsleFluidPalette.brandIndigo
        case .timeMachine: return .teal
        }
    }
    private func storageBadge(for detail: StorageDetail) -> (String, IsleStatusTone) {
        switch detail {
        case .disks:
            let count = model.managedDisks.count
            return (count > 0 ? "\(count) 块外置盘" : "按需检测", count > 0 ? .accent : .neutral)
        case .locations:
            if model.rootManagement.defaultRoot?.online == true {
                let extra = model.rootManagement.additionalRoots.count
                return (extra > 1 ? "已登记 \(extra) 个目录" : "已就绪", .success)
            }
            if model.rootManagement.defaultRoot?.online == false { return ("存储离线", .warning) }
            if model.sharedFolderPath != nil { return (model.sharedFolderName, .success) }
            return ("待设置", .warning)
        case .capacity:
            if let t = model.storageThreshold { return ("低于 \(t.percent)% 提醒", .neutral) }
            return ("低空间提醒", .neutral)
        case .backup:
            if model.backupStatus?.running == true { return ("正在备份…", .accent) }
            if model.backupSchedule?.enabled == true { return ("每周自动备份", .success) }
            return ("手动备份", .neutral)
        case .timeMachine:
            if let summary = model.timeMachineDiagnostics?.summary { return (summary, .neutral) }
            return ("系统备份核查", .neutral)
        }
    }
    var storageSummary: some View {
        let root = model.rootManagement.defaultRoot
        let isOnline = root?.online ?? (model.sharedFolderPath != nil)
        let defaultPath = root?.path ?? model.sharedFolderPath
        let matchedVolume: HostVolume? = {
            guard let volumes = model.metrics?.volumes,
                  let mount = StorageVolumeSelection.matchingMount(for: defaultPath, mounts: volumes.map(\.mount)) else { return nil }
            return volumes.first(where: { $0.mount == mount })
        }()
        return LiquidCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    IsleHeaderIconBadge(icon: "externaldrive.fill", tint: IsleFluidPalette.brandCyan, size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(isOnline ? (root?.name ?? model.sharedFolderName) : "默认存储尚未就绪")
                                .font(.system(size: 17, weight: .semibold))
                            IsleStatusPill(
                                text: isOnline ? "在线" : (root?.online == false ? "已离线" : "未设置"),
                                tone: isOnline ? .success : .warning,
                                showDot: true
                            )
                        }
                        Text(defaultPath ?? "请登记专用文件夹并设为默认 NAS 存储")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if let path = defaultPath, isOnline {
                        Button("在访达中打开") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                    Button("管理存储位置") {
                        requestLocalNavigation { storageDetail = .locations }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: isOnline ? .secondary : .prominent, size: .small))
                    IsleDetailInfo(title: "存储位置", rows: storagePreviewRows)
                }
                if let volume = matchedVolume, volume.total > 0 {
                    let used = volume.total - min(volume.free, volume.total)
                    let ratio = Double(used) / Double(max(volume.total, 1))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("所在磁盘：\(volume.mount == "/" ? "Mac 系统盘" : volume.name)（\(volume.filesystem)）")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(IsleTheme.secondaryText)
                            Spacer()
                            Text("可用 \(formatBytes(volume.free)) / 共 \(formatBytes(volume.total))")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(IsleTheme.secondaryText)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.065))
                                Capsule()
                                    .fill(LinearGradient(colors: [IsleFluidPalette.brandCyan, IsleFluidPalette.brandBlue], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, min(proxy.size.width * CGFloat(max(0, min(1, ratio))), proxy.size.width)))
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if root?.online == false {
                    HStack(spacing: 10) {
                        Label("原存储离线。请检查磁盘供电、数据线和挂载状态；原有文件不会自动删除。", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12.5)).foregroundStyle(IsleTheme.warningText)
                        Spacer()
                        Button("查看连接与恢复操作") { storageDetail = .locations }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
            }
        }
    }
    var storagePreviewRows: [(String, String)] {
        let defaultPath = model.rootManagement.defaultRoot?.path
        var rows = [("完整路径", defaultPath ?? "尚未设置")]
        if let volumes = model.metrics?.volumes,
           let mount = StorageVolumeSelection.matchingMount(for: defaultPath, mounts: volumes.map(\.mount)),
           let volume = volumes.first(where: { $0.mount == mount }) {
            rows += [("所在卷", volume.name), ("可用容量", formatBytes(volume.free)), ("总容量", formatBytes(volume.total))]
        }
        rows.append(("身份保护", "离线时保留原登记；重新选择目录不会自动迁移文件"))
        return rows
    }
    var storageDisksContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppleSettingsGroup(title: "硬盘基础管理", footer: "硬盘操作由 Go Core 与管理员 Web 共用一套受控逻辑。系统盘和正在作为 NAS 存储使用的硬盘不能执行危险操作；不支持强制卸载或自动格式化。") {
                AppleSettingsRow(title: "外置磁盘设备", subtitle: "读取挂载状态、容量、文件系统与按需 SMART 健康报告", icon: "externaldrive", iconTint: .blue) {
                    Button("刷新设备列表") { model.refreshManagedDisks() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.isPresentationPreview || model.state != .online || model.diskOperationPending)
                }
                if model.diskOperationPending {
                    ProgressView("正在等待 macOS 完成磁盘操作…")
                        .controlSize(.small).padding(.horizontal, 16).padding(.bottom, 10)
                }
                if let error = model.diskManagementError {
                    Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                        .textSelection(.enabled).padding(.horizontal, 16).padding(.bottom, 10)
                }
                if let message = model.elevationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("✅") ? .green : IsleTheme.warningText)
                        .textSelection(.enabled).padding(.horizontal, 16).padding(.bottom, 10)
                }
                if model.managedDisks.isEmpty {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(
                        title: "尚未检测到可管理的外置磁盘",
                        subtitle: "连接 USB 或雷电外置硬盘后，点击右上角「刷新设备列表」即可查看与操作。",
                        icon: "externaldrive.badge.questionmark",
                        iconTint: .secondary
                    ) { EmptyView() }
                }
                ForEach(model.managedDisks) { disk in
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(disk.mounted ? IsleFluidPalette.brandBlue : IsleTheme.secondaryText)
                                .frame(width: 30, height: 30)
                                .background((disk.mounted ? IsleFluidPalette.brandBlue : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(disk.name).font(.system(size: 13.5, weight: .semibold))
                                Text("\(disk.id) · \(disk.filesystem.isEmpty ? "格式未知" : disk.filesystem) · \(disk.protocolName.isEmpty ? "连接方式未知" : disk.protocolName)")
                                    .font(.caption.monospaced()).foregroundStyle(IsleTheme.secondaryText)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            IsleStatusPill(
                                text: disk.mounted ? (disk.readOnly ? "只读挂载" : "已挂载") : "未挂载",
                                tone: disk.mounted ? (disk.readOnly ? .warning : .success) : .neutral,
                                showDot: disk.mounted
                            )
                            IsleDetailInfo(title: disk.name, rows: [("挂载路径", disk.mount), ("设备", disk.id), ("连接", disk.protocolName), ("容量", formatBytes(disk.total)), ("可用", disk.mounted ? formatBytes(disk.free) : "离线时无法读取"), ("SMART", disk.smart.isEmpty ? "未知" : disk.smart)])
                        }
                        Text("SMART：\(disk.smart.isEmpty ? "未知（设备可能不提供）" : disk.smart) · \(disk.total > 0 ? "总容量 \(formatBytes(disk.total))" : "容量未知")\(disk.mounted ? " · 可用 \(formatBytes(disk.free))" : "")")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        HStack(spacing: 8) {
                            if disk.mounted {
                                if !disk.readOnly && !disk.mount.isEmpty {
                                    Button("预授权读写权限") {
                                        model.preauthorizeVolumeReadWrite(mountPath: disk.mount, volumeName: disk.name)
                                    }
                                    .disabled(model.diskOperationPending || model.rootManagement.busy)
                                }
                                Button("重命名…") { model.manageDisk(disk, action: "rename") }
                                    .disabled(model.diskOperationPending || disk.identity.isEmpty)
                                Button("安全弹出…") { model.manageDisk(disk, action: "eject") }
                                    .disabled(model.diskOperationPending || disk.identity.isEmpty)
                            } else {
                                Button("挂载") { model.manageDisk(disk, action: "mount") }
                                    .disabled(model.diskOperationPending || disk.identity.isEmpty)
                            }
                            Button(expandedDiskHealth.contains(disk.id) ? "收起健康详情" : "健康详情…") {
                                if expandedDiskHealth.contains(disk.id) {
                                    expandedDiskHealth.remove(disk.id)
                                } else {
                                    expandedDiskHealth.insert(disk.id)
                                    model.refreshDiskHealth(disk)
                                }
                            }
                            if disk.identity.isEmpty {
                                Text("无法验证唯一身份，仅允许查看。").font(.caption)
                                    .foregroundStyle(IsleTheme.warningText)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        if expandedDiskHealth.contains(disk.id), let report = model.diskHealthReports[disk.parent] {
                            DiskHealthDetails(report: report, fallbackSMART: disk.smart)
                            if report.reason == "smartctl_permission_required" {
                                HStack(spacing: 8) {
                                    Button(model.elevatingDisks.contains(disk.id) ? "正在授权读取…" : "使用管理员权限读取…") {
                                        model.elevateDiskHealth(disk)
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                    .disabled(model.elevatingDisks.contains(disk.id) || model.state != .online)
                                    Button("sudoers 免密指引…") {
                                        sudoersGuideDevice = disk.parent
                                        presentingSudoersGuide = true
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    if model.elevatingDisks.contains(disk.id) {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .disabled(model.isPresentationPreview)
                }
            }
            .sheet(isPresented: $presentingSudoersGuide) {
                SudoersGuideView(device: sudoersGuideDevice)
            }
        }
    }
    var storageLocationsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.rootManagement.enabled {
            if model.sharedFolderPath == nil, let offlinePath = model.offlineSharedFolderPath {
                AppleSettingsGroup(title: "共享存储已离线", footer: "默认保留旧盘绑定和照片、影视等本地记录；只有你主动确认清理时才会放弃旧盘绑定。") {
                    VStack(alignment: .leading, spacing: 11) {
                        Label("请连接原来的存储磁盘，然后点击「重新连接」", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IsleTheme.warningText)
                        Text("原共享路径：\(offlinePath)")
                            .font(.caption.monospaced())
                            .foregroundStyle(IsleTheme.secondaryText)
                            .textSelection(.enabled)
                        Text("如果暂时不连接，可以保留所有绑定和媒体资料，待将来接回磁盘；也可以清理该盘在轻屿中的旧记录，并改用 Mac 本机存储。不会删除离线盘上的原始文件。")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        HStack(spacing: 10) {
                            Button("重新连接原磁盘") { model.retrySharedFolder() }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(model.state != .online || model.offlineCleanupPending)
                            Button("保留记录，稍后连接") { model.keepOfflineShare() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(model.offlineCleanupPending)
                            Button("清理离线盘的记录…") { model.forgetOfflineShare() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(!model.canForgetOfflineShare)
                        }
                        if model.offlineCleanupPending {
                            ProgressView("正在校验并清理离线记录…").controlSize(.small)
                        }
                        if let result = model.offlineCleanupMessage {
                            Text(result).font(.caption).textSelection(.enabled).foregroundStyle(IsleTheme.secondaryText)
                        }
                    }
                    .padding(14)
                }
            }
            AppleSettingsGroup(title: "当前 NAS 存储位置", footer: "此处管理当前共享目录；多目录登记在开发预览中按原开关开放。成员的分类存储分配在 Web 管理，切换不会自动迁移文件。") {
                AppleSettingsRow(title: "当前共享根目录", icon: "folder.fill", iconTint: .blue) {
                    HStack(spacing: 10) {
                        Text(model.sharedFolderName)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Spacer(minLength: 0)
                        if let path = model.sharedFolderPath {
                            Button("在访达中打开") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                        Button("选择其他文件夹…") {
                            model.selectSharedFolder()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(!model.canChangeSharedStorage)
                        Button("重新连接") {
                            model.retrySharedFolder()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online || model.storageSelectionPending)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "实际存储路径", icon: "externaldrive", iconTint: .teal) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.sharedFolderPath ?? "共享目录离线或尚未完成设置")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let volumes = model.metrics?.volumes,
                           let mount = StorageVolumeSelection.matchingMount(
                                for: model.sharedFolderPath, mounts: volumes.map(\.mount)
                           ),
                           let volume = volumes.first(where: { $0.mount == mount }) {
                            Text("所在磁盘：\(volume.name) · 可用 \(formatBytes(volume.free)) / 共 \(formatBytes(volume.total))")
                                .font(.caption)
                                .foregroundStyle(IsleTheme.secondaryText)
                        } else if model.sharedFolderPath != nil {
                            Text("尚未识别所属磁盘，请刷新服务指标并确认磁盘挂载状态。")
                                .font(.caption)
                                .foregroundStyle(IsleTheme.warningText)
                        }
                    }
                }
                if model.storageSelectionPending {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "正在切换", icon: "hourglass", iconTint: .blue) {
                        ProgressView("正在等待 NAS Core 验证磁盘身份…").controlSize(.small)
                    }
                }
                if let message = model.storageSelectionMessage {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "设置结果", icon: "info.circle", iconTint: .blue) {
                        Text(message).font(.caption).foregroundStyle(IsleTheme.secondaryText).textSelection(.enabled)
                    }
                }
                if let error = model.sharedFolderError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "目录异常", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.errorText)
                    }
                }
            }

            }
            if model.rootManagement.enabled {
                RootManagementView(model: model.rootManagement)
            }

            if let volumes = model.metrics?.volumes, !volumes.isEmpty {
                // Disk images (including our own LightIsle installer DMG) are
                // mounted volumes, not eligible NAS disks. Prefer the actual
                // diskutil protocol over volume names, since a real physical
                // disk can legitimately be named "LightIsle".
                let visibleVolumes = volumes.filter { volume in
                    !model.managedDisks.contains(where: { disk in
                        disk.mount == volume.mount &&
                            StorageVolumeSelection.isDiskImageProtocol(disk.protocolName)
                    })
                }
                AppleSettingsGroup(title: "可用磁盘与存储位置", footer: "选择可写外置磁盘中的专用文件夹作为 NAS 存储位置；不能直接把整块盘设为共享目录。外置硬盘接入或添加时将立即申请 macOS 与后台读写权限，确保离开 Mac 后也能远程使用。") {
                    if let message = model.elevationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(message.hasPrefix("✅") ? .green : IsleTheme.warningText)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                    }
                    ForEach(visibleVolumes) { volume in
                        let physicalDisk = model.managedDisks.first(where: { disk in
                            disk.mount == volume.mount && disk.external &&
                                !StorageVolumeSelection.isDiskImageProtocol(disk.protocolName)
                        })
                        let usedRatio = Double(volume.total - min(volume.free, volume.total)) / Double(max(volume.total, 1))
                        let tintColor: Color = volume.mount == "/" ? .blue : .teal
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(tintColor.opacity(0.14))
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(tintColor.opacity(0.22), lineWidth: 1)
                                        )
                                    Image(systemName: volume.mount == "/" ? "internaldrive.fill" : "externaldrive.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(tintColor)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(volume.mount == "/" ? "系统磁盘" : volume.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("\(volume.filesystem) · \(volume.mount)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(IsleTheme.secondaryText)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Text(volume.readOnly ? "只读" : "已挂载")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill((volume.readOnly ? Color.orange : Color.green).opacity(0.12)))
                                    .foregroundStyle(volume.readOnly ? .orange : .green)
                            }
                            HStack(spacing: 12) {
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.06))
                                            .frame(height: 6)
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [tintColor, tintColor.opacity(0.72)],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                            .frame(width: max(0, min(proxy.size.width * CGFloat(max(0, min(1, usedRatio))), proxy.size.width)), height: 6)
                                    }
                                }
                                .frame(height: 6)

                                Text("可用 \(formatBytes(volume.free)) / 共 \(formatBytes(volume.total))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            if let disk = model.managedDisks.first(where: { $0.mount == volume.mount }) {
                                let warning = ["failing", "failed", "failure"].contains(disk.smart.lowercased())
                                HStack(spacing: 6) {
                                    Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                                        .foregroundStyle(warning ? .red : .teal)
                                    Text("SMART: \(disk.smart.isEmpty ? "未知（设备未提供）" : disk.smart)")
                                        .foregroundStyle(warning ? .red : .secondary)
                                    Spacer()
                                    if !disk.protocolName.isEmpty {
                                        Text(disk.protocolName)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(IsleTheme.secondaryText)
                                    }
                                }
                                .font(.caption)
                            }
                            if let activity = diskActivity(for: volume.device) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.triangle.swap")
                                        .foregroundStyle(IsleTheme.secondaryText)
                                    Text(activity)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(IsleTheme.secondaryText)
                                    Spacer()
                                }
                            }
                            let isCurrentDisk = model.rootManagement.defaultRoot?.path != nil &&
                                StorageVolumeSelection.matchingMount(
                                    for: model.rootManagement.defaultRoot?.path,
                                    mounts: volumes.map(\.mount)
                                ) == volume.mount
                            HStack(spacing: 8) {
                                if isCurrentDisk {
                                    Label("当前 NAS 存储所在磁盘", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(IsleTheme.secondaryText)
                                } else if volume.readOnly {
                                    Text(volume.filesystem.lowercased().contains("ntfs")
                                         ? "NTFS：macOS 默认只能读取，无法直接写入。可以使用磁盘工具格式化为 APFS 或 exFAT。"
                                         : "只读磁盘，无法直接作为存储目标；请检查磁盘权限及文件系统。")
                                        .font(.caption)
                                        .foregroundStyle(IsleTheme.secondaryText)
                                } else if volume.mount == "/" {
                                    Text("系统磁盘：可通过上方「选择其他文件夹」使用主目录")
                                        .font(.caption)
                                        .foregroundStyle(IsleTheme.secondaryText)
                                }
                                Spacer(minLength: 0)
                                if StorageVolumeSelection.canChooseOnVolume(
                                    mount: volume.mount, readOnly: volume.readOnly
                                ) {
                                    if !isCurrentDisk {
                                        Button("设为主存储…") {
                                            model.rootManagement.selectFolderAndSwitch(onVolume: volume)
                                        }
                                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                        .disabled(!model.canAddOrSwitchStorageRoot)
                                    }
                                    Button("在此磁盘添加存储目录…") {
                                        model.selectSharedFolder(onVolume: volume)
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(!model.canAddOrSwitchStorageRoot)
                                    Button("预授权读写权限") {
                                        model.preauthorizeVolumeReadWrite(mountPath: volume.mount, volumeName: volume.name)
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(model.state != .online || model.rootManagement.busy)
                                }
                                if physicalDisk != nil && StorageVolumeSelection.canInspectExternalVolume(mount: volume.mount) {
                                    Button("格式化磁盘…") {
                                        model.openDiskFormattingGuide(for: volume)
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(isCurrentDisk || model.offlineCleanupPending)
                                }
                                if isCurrentDisk && physicalDisk != nil && StorageVolumeSelection.canInspectExternalVolume(mount: volume.mount) {
                                    Text("NAS 正在使用，切换存储目录后才可格式化")
                                        .font(.caption)
                                        .foregroundStyle(IsleTheme.secondaryText)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        if volume.id != visibleVolumes.last?.id {
                            IsleGroupSpacing(height: 4).padding(.leading, 14)
                        }
                    }
                }
            } else {
                AppleSettingsGroup(title: "可用磁盘与存储位置") {
                    AppleSettingsRow(title: "未取得磁盘列表", icon: "externaldrive", iconTint: .orange) {
                        HStack {
                            Text("请确认外置磁盘已挂载，然后刷新服务状态。")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            Button("刷新") { model.refreshMetrics() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(model.state != .online)
                        }
                    }
                }
            }

        }
    }
    var storageCapacityContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppleSettingsGroup(title: "低空间告警阈值", footer: "剩余空间低于绝对值或总容量的百分比之一时发出告警并通知；两个条件任一满足即触发。适用于 NAS 存储卷。") {
                AppleSettingsRow(title: "告警阈值", icon: "exclamationmark.triangle", iconTint: .orange) {
                    HStack(spacing: 8) {
                        TextField("剩余 GiB", text: $thresholdFreeMiBText)
                            .liquidInput()
                            .frame(width: 76)
                            .font(.system(size: 12, design: .monospaced))
                        Text("GiB 或")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        TextField("百分比", text: $thresholdPercentText)
                            .liquidInput()
                            .frame(width: 58)
                            .font(.system(size: 12, design: .monospaced))
                        Text("%")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        Button("保存") { applyThresholdDraft() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "当前生效阈值", subtitle: "留空表示保持该侧不变；两项同时为 0 会被拒绝。", icon: "scalemass", iconTint: .indigo) {
                    Text(thresholdSummary)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
            .task {
                model.refreshStorageThreshold()
                syncThresholdDraft()
            }
            .onChange(of: model.storageThreshold) { _, _ in syncThresholdDraft() }

            AppleSettingsGroup(title: "宿主 Mac 磁盘体征") {
                if let m = model.metrics {
                    AppleSettingsRow(title: "系统盘总容量", icon: "internaldrive", iconTint: .blue) {
                        Text(formatBytes(m.diskTotal)).font(.system(size: 12, design: .monospaced))
                    }
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "系统盘剩余可用", icon: "chart.pie.fill", iconTint: .teal) {
                        Text(formatBytes(m.diskFree))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(IsleTheme.successText)
                    }
                } else {
                    AppleSettingsRow(title: "系统盘信息", icon: "info.circle", iconTint: .indigo) {
                        Text("正在采样…").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }

        }
    }
}
