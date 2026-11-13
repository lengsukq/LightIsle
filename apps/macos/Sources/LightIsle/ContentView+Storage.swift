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
            if let summary = model.timeMachineDiagnostics?.summary { return (summary, .neutral) }
            return ("配置与 Time Machine", .neutral)
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
                        IsleIconButton(
                            icon: "folder",
                            help: "在访达中打开默认存储目录"
                        ) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
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
                    let slices = IsleStorageChartBuilder.volumeSlices(
                        total: volume.total,
                        free: volume.free,
                        rootID: root?.rootID,
                        rootGeneration: root?.generation,
                        users: model.personalSpaces.users
                    )
                    HStack(alignment: .center, spacing: 14) {
                        IsleDonutGauge(
                            progress: ratio,
                            centerText: "\(Int(round(ratio * 100)))%",
                            centerSubtext: "已用",
                            tint: ratio > 0.88 ? .orange : IsleFluidPalette.brandCyan,
                            size: 56,
                            lineWidth: 6,
                            accessibilityLabel: "默认存储所在磁盘占用比例"
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("所在磁盘：\(volume.mount == "/" ? "Mac 系统盘" : volume.name)（\(volume.filesystem)）")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(IsleTheme.secondaryText)
                                Spacer()
                                Text("可用 \(formatBytes(volume.free)) / 共 \(formatBytes(volume.total))")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            IsleSegmentedBar(
                                slices: slices,
                                total: Double(volume.total),
                                barHeight: 10,
                                showsLegend: true,
                                legendMinimumWidth: 138,
                                accessibilityTitle: "默认存储磁盘与成员空间构成"
                            )
                        }
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
                IsleQuickJumpBar(items: [
                    IsleQuickJumpItem("个人空间与配额", icon: "person.2.fill", tint: .purple, help: "管理成员、可用空间限额与存储目录归属") {
                        model.navigate(to: .spaces)
                    },
                    IsleQuickJumpItem("Mac 文件共享 (SMB)", icon: "externaldrive.connected.to.line.below", tint: .teal, help: "通过 macOS SMB 在访达挂载轻屿共享目录") {
                        model.navigateToConnectionDetail(.sharing)
                    },
                    IsleQuickJumpItem("权限预检", icon: "checkmark.shield.fill", tint: .green, help: "检查外置盘整盘读写权限与隐私授权") {
                        model.navigateToSettingsDetail(.permissions)
                    }
                ])
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
                    IsleIconButton(
                        icon: "arrow.clockwise",
                        help: "刷新外置磁盘与挂载状态"
                    ) { model.refreshManagedDisks() }
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
                            Button {
                                withAnimation(reduceMotion ? nil : IsleMotion.standard) {
                                    if expandedDiskHealth.contains(disk.id) {
                                        expandedDiskHealth.remove(disk.id)
                                    } else {
                                        expandedDiskHealth.insert(disk.id)
                                        model.refreshDiskHealth(disk)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(expandedDiskHealth.contains(disk.id) ? "收起健康详情" : "健康详情…")
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .rotationEffect(.degrees(expandedDiskHealth.contains(disk.id) ? 180 : 0))
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
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
            if let message = model.storageSelectionMessage {
                AppleSettingsGroup(title: "存储选择提示") {
                    AppleSettingsRow(title: "结果与说明", icon: "info.circle", iconTint: .orange) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(IsleTheme.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("知道了") {
                                withAnimation(reduceMotion ? nil : IsleMotion.quick) {
                                    model.storageSelectionMessage = nil
                                }
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
                            let matchingRoot = model.personalSpaces.roots.first(where: { root in
                                StorageVolumeSelection.matchingMount(for: root.path, mounts: volumes.map(\.mount)) == volume.mount
                            })
                            let volumeSlices = IsleStorageChartBuilder.volumeSlices(
                                total: volume.total,
                                free: volume.free,
                                rootID: matchingRoot?.rootID,
                                rootGeneration: matchingRoot?.generation,
                                users: model.personalSpaces.users
                            )
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("占比 \(Int(round(max(0, min(1, usedRatio)) * 100)))%")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(IsleTheme.secondaryText)
                                    Spacer()
                                    Text("可用 \(formatBytes(volume.free)) / 共 \(formatBytes(volume.total))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(IsleTheme.secondaryText)
                                }
                                IsleSegmentedBar(
                                    slices: volumeSlices,
                                    total: Double(volume.total),
                                    barHeight: 9,
                                    showsLegend: matchingRoot != nil,
                                    legendMinimumWidth: 135,
                                    accessibilityTitle: "\(volume.mount == "/" ? "系统磁盘" : volume.name)空间构成"
                                )
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
                                    .disabled(isCurrentDisk)
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
                            IsleIconButton(icon: "arrow.clockwise", help: "刷新磁盘列表与主机状态") { model.refreshMetrics() }
                                .disabled(model.state != .online)
                        }
                    }
                }
            }

            IsleQuickJumpBar(items: [
                IsleQuickJumpItem("个人空间与配额", icon: "person.2.fill", tint: .purple, help: "查看或调整成员专属目录及配额") {
                    model.navigate(to: .spaces)
                },
                IsleQuickJumpItem("Mac 文件共享 (SMB)", icon: "externaldrive.connected.to.line.below", tint: .teal, help: "查看当前通过 SMB 共享的存储目录") {
                    model.navigateToConnectionDetail(.sharing)
                },
                IsleQuickJumpItem("磁盘设备", icon: "externaldrive", tint: .blue, help: "查看物理磁盘挂载状态与 SMART 健康度") {
                    storageDetail = .disks
                },
                IsleQuickJumpItem("权限预检", icon: "checkmark.shield.fill", tint: .green, help: "检查 macOS 隐私与外置卷读写授权") {
                    model.navigateToSettingsDetail(.permissions)
                }
            ])

        }
        .animation(reduceMotion ? nil : IsleMotion.quick, value: model.storageSelectionMessage)
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
                if let m = model.metrics, m.diskTotal > 0 {
                    let clampedFree = min(m.diskFree, m.diskTotal)
                    let used = m.diskTotal - clampedFree
                    let ratio = Double(used) / Double(m.diskTotal)
                    let systemSlices = IsleStorageChartBuilder.volumeSlices(total: m.diskTotal, free: clampedFree)
                    AppleSettingsRow(
                        title: "系统盘空间构成",
                        subtitle: "总容量 \(formatBytes(m.diskTotal)) · 剩余 \(formatBytes(clampedFree))",
                        icon: "chart.pie.fill",
                        iconTint: ratio > 0.88 ? .orange : .teal
                    ) {
                        IsleDonutGauge(
                            progress: ratio,
                            centerText: "\(Int(round(ratio * 100)))%",
                            centerSubtext: "已用",
                            tint: ratio > 0.88 ? .orange : .teal,
                            size: 52,
                            lineWidth: 5.5,
                            accessibilityLabel: "宿主系统盘占用比例"
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        IsleSegmentedBar(
                            slices: systemSlices,
                            total: Double(m.diskTotal),
                            barHeight: 10,
                            showsLegend: true,
                            accessibilityTitle: "宿主 Mac 系统盘空间构成"
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                } else {
                    AppleSettingsRow(title: "系统盘信息", icon: "info.circle", iconTint: .indigo) {
                        Text("正在采样…").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }

        }
    }
}
