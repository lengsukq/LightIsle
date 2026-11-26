import AppKit
import SwiftUI

/// Non-intrusive banner surfaced on Overview and Storage Disks when a non-NAS
/// removable volume (SD card, camera, drone, dashcam) is mounted.
struct RemovableMediaBannerView: View {
    @ObservedObject var coordinator: RemovableMediaImportCoordinator
    @ObservedObject var model: AppModel

    var body: some View {
        if model.state == .online, let volume = coordinator.bannerVolumes.first {
            let extraCount = coordinator.bannerVolumes.count - 1
            HStack(alignment: .center, spacing: 12) {
                IsleHeaderIconBadge(icon: "sdcard.fill", tint: IsleFluidPalette.brandCyan, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("发现可移动存储介质「\(volume.volumeName)」")
                            .font(.system(size: 13.5, weight: .semibold))
                        IsleStatusPill(
                            text: volume.summaryHints,
                            tone: volume.hasCameraHints ? .accent : .neutral
                        )
                        if extraCount > 0 {
                            IsleStatusPill(text: "另有 \(extraCount) 张存储卡", tone: .neutral)
                        }
                    }
                    Text("仅只读扫描照片、RAW 与视频并增量归档至 NAS，绝不删除或格式化存储卡原件。")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("忽略") {
                    coordinator.dismissBanner(for: volume.mountPath)
                }
                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                Button("一键扫描导入") {
                    coordinator.openImport(for: volume.mountPath, appModel: model)
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
            }
            .padding(14)
            .modifier(IsleEmbossedSurface())
        }
    }
}

/// Secondary view for Mac host USB/SD card one-click incremental media import.
struct RemovableMediaImportView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: RemovableMediaImportCoordinator

    private var onlineRoots: [NativeSpaceRootInfo] {
        model.personalSpaces.roots.filter(\.online)
    }

    private var eligibleUsers: [NativeSpaceUserEntry] {
        coordinator.eligibleUsers(
            in: model.personalSpaces.users,
            for: coordinator.selectedRootID,
            roots: onlineRoots
        )
    }

    private var selectedUserLocations: Set<String> {
        guard let root = onlineRoots.first(where: { $0.rootID == coordinator.selectedRootID }),
              let user = eligibleUsers.first(where: { $0.id == coordinator.selectedUserID }) else {
            return []
        }
        return Set(user.policy.locations.compactMap { loc in
            (loc.rootID == root.rootID && loc.rootGeneration == root.generation) ? loc.category : nil
        })
    }

    private var matchingEjectDisk: ManagedDisk? {
        let mount = coordinator.selectedMountPath
        guard !mount.isEmpty else { return nil }
        return model.managedDisks.first(where: { disk in
            disk.external && disk.mounted && !disk.mount.isEmpty &&
                (disk.mount == mount || mount.hasPrefix(disk.mount + "/"))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sourceSection
            scanSummarySection
            destinationSection
            if coordinator.jobStatus != nil || coordinator.errorMessage != nil || coordinator.infoMessage != nil {
                progressAndResultSection
            }
        }
        .onAppear {
            coordinator.refreshDetectedVolumes()
            model.personalSpaces.refresh()
            model.refreshManagedDisks()
            coordinator.syncDefaults(from: model)
            if !coordinator.selectedMountPath.isEmpty && coordinator.scanResult == nil && !coordinator.scanning && !coordinator.isImporting {
                coordinator.scanSelectedVolume()
            }
        }
        .onChange(of: model.personalSpaces.roots) { _, _ in
            coordinator.syncDefaults(from: model)
        }
        .onChange(of: model.personalSpaces.users) { _, _ in
            coordinator.syncDefaults(from: model)
        }
        .onChange(of: coordinator.selectedRootID) { _, _ in
            coordinator.syncDefaults(from: model)
        }
    }

    private var sourceSection: some View {
        AppleSettingsGroup(
            title: "来源存储卡 / 读卡器",
            footer: "仅支持 /Volumes/ 下的外置介质，自动拒绝已登记的 NAS 磁盘以防自导自。全过程只读扫描，绝不删除或格式化存储卡原件。"
        ) {
            AppleSettingsRow(
                title: "已检测到的外置介质",
                subtitle: coordinator.selectedMountPath.isEmpty
                    ? "插入相机 SD 卡、无人机存储卡或外置读卡器后自动出现。"
                    : coordinator.selectedMountPath,
                icon: "sdcard.fill",
                iconTint: IsleFluidPalette.brandCyan
            ) {
                HStack(spacing: 8) {
                    if !coordinator.detectedVolumes.isEmpty {
                        LiquidMenuPicker(
                            title: "选择存储卡",
                            selection: Binding(
                                get: { coordinator.selectedMountPath },
                                set: { next in
                                    coordinator.selectedMountPath = next
                                    coordinator.scanSelectedVolume()
                                }
                            ),
                            options: coordinator.detectedVolumes.map { vol in
                                LiquidMenuOption(
                                    value: vol.mountPath,
                                    label: "\(vol.volumeName)（\(vol.summaryHints)）"
                                )
                            },
                            minWidth: 210
                        )
                        .disabled(coordinator.isImporting)
                    }
                    Button("手动选择…") {
                        coordinator.pickCustomSourceFolder()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(coordinator.isImporting)
                    IsleIconButton(icon: "arrow.clockwise", help: "刷新外置存储卡与重新扫描") {
                        coordinator.refreshDetectedVolumes()
                        if !coordinator.selectedMountPath.isEmpty {
                            coordinator.scanSelectedVolume()
                        }
                    }
                    .disabled(coordinator.isImporting || coordinator.scanning)
                }
            }
        }
    }

    @ViewBuilder
    private var scanSummarySection: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IsleHeaderIconBadge(icon: "photo.stack.fill", tint: IsleFluidPalette.brandBlue, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("媒体扫描预览")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("自动识别常见照片、RAW 原图、实况伴侣 .mov 与视频，跳过隐藏系统文件与符号链接。")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                    Spacer()
                    if coordinator.scanning {
                        ProgressView().controlSize(.small)
                        Text("正在扫描…")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                    } else {
                        Button("重新扫描") {
                            coordinator.scanSelectedVolume()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(coordinator.selectedMountPath.isEmpty || coordinator.isImporting || !coordinator.connected)
                    }
                }

                if let scan = coordinator.scanResult {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                        metricTile(title: "媒体总计", value: "\(scan.totalFiles) 项", detail: ByteCountFormatter.string(fromByteCount: max(scan.totalBytes, 0), countStyle: .file))
                        metricTile(title: "照片", value: "\(scan.photoCount) 张", detail: "JPG / HEIC / PNG")
                        metricTile(title: "RAW 原图", value: "\(scan.rawCount) 张", detail: "CR3 / ARW / NEF / DNG")
                        metricTile(title: "视频与实况", value: "\(scan.videoCount + scan.livePhotoCount) 段", detail: scan.livePhotoCount > 0 ? "含 \(scan.livePhotoCount) 个实况伴侣" : "MP4 / MOV / MTS")
                    }
                    if let samples = scan.sampleFiles, !samples.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("预览示例（前 \(samples.count) 项）")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(IsleTheme.secondaryText)
                            ForEach(samples.prefix(5), id: \.self) { sample in
                                Text(sample)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                } else if !coordinator.scanning {
                    Text(coordinator.selectedMountPath.isEmpty
                         ? "尚未选择来源存储卡。请插入读卡器或点击上方「手动选择…」。"
                         : "点击「重新扫描」预览存储卡内可导入的照片与视频。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(IsleTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var destinationSection: some View {
        AppleSettingsGroup(
            title: "目标存储与归档方式",
            footer: "导入前会核验目标 NAS 硬盘物理身份与成员配额，比对同名文件大小与 SHA-256 自动跳过已导入项；完成后自动触发相册与影院刷新。"
        ) {
            AppleSettingsRow(
                title: "目标在线 NAS 硬盘",
                subtitle: onlineRoots.isEmpty ? "当前没有在线的 NAS 存储根，请先连接目标硬盘。" : "仅展示在线并已验证物理身份的存储目录",
                icon: "externaldrive.fill",
                iconTint: .blue
            ) {
                if onlineRoots.isEmpty {
                    Button("前往存储位置") { model.navigateToStorageDetail(.locations) }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                } else {
                    LiquidMenuPicker(
                        title: "目标存储根",
                        selection: $coordinator.selectedRootID,
                        options: onlineRoots.map { root in
                            let suffix = root.isDefault ? " · 默认" : ""
                            return LiquidMenuOption(value: root.rootID, label: "\(root.name)\(suffix)")
                        },
                        minWidth: 210
                    )
                    .disabled(coordinator.isImporting)
                }
            }

            IsleGroupSpacing(height: 4).padding(.leading, 44)

            AppleSettingsRow(
                title: "归属成员空间",
                subtitle: eligibleUsers.isEmpty
                    ? "该硬盘暂无已分配空间的成员，请先在「个人空间」分配目录。"
                    : "导入字节严格计入该成员的个人存储配额账本",
                icon: "person.fill",
                iconTint: .purple
            ) {
                if eligibleUsers.isEmpty {
                    Button("管理个人空间") { model.navigate(to: .spaces) }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                } else {
                    LiquidMenuPicker(
                        title: "目标成员",
                        selection: $coordinator.selectedUserID,
                        options: eligibleUsers.map { entry in
                            LiquidMenuOption(
                                value: entry.id,
                                label: entry.user.username + (entry.user.isAdmin ? "（管理员）" : "")
                            )
                        },
                        minWidth: 210
                    )
                    .disabled(coordinator.isImporting)
                }
            }

            IsleGroupSpacing(height: 4).padding(.leading, 44)

            AppleSettingsRow(
                title: "目标目录分类",
                subtitle: "自动分流将照片/RAW/实况存入照片目录，视频存入视频目录",
                icon: "folder.badge.plus",
                iconTint: .indigo
            ) {
                let allowedCategories = MediaImportTargetCategory.allCases.filter { cat in
                    switch cat {
                    case .auto: return true
                    case .photos: return selectedUserLocations.contains("photos")
                    case .videos: return selectedUserLocations.contains("videos")
                    }
                }
                LiquidMenuPicker(
                    title: "目录分类",
                    selection: $coordinator.selectedCategory,
                    options: (allowedCategories.isEmpty ? [.auto] : allowedCategories).map {
                        LiquidMenuOption(value: $0, label: $0.label)
                    },
                    minWidth: 230
                )
                .disabled(coordinator.isImporting)
            }

            IsleGroupSpacing(height: 4).padding(.leading, 44)

            AppleSettingsRow(
                title: "日期归档规则",
                subtitle: "按文件拍摄/修改时间自动建立归档子目录，或保留卡内原始层级",
                icon: "calendar",
                iconTint: .teal
            ) {
                LiquidMenuPicker(
                    title: "归档规则",
                    selection: $coordinator.selectedArchiveMode,
                    options: MediaImportArchiveMode.allCases.map {
                        LiquidMenuOption(value: $0, label: $0.label)
                    },
                    minWidth: 230
                )
                .disabled(coordinator.isImporting)
            }

            IsleGroupSpacing(height: 4).padding(.leading, 44)

            AppleSettingsRow(
                title: "可选归档子目录",
                subtitle: "例如「日本旅行」或「相机导入」，留空则直接归档在所选目录内",
                icon: "tag",
                iconTint: .orange
            ) {
                TextField("留空直接归档", text: $coordinator.subfolder)
                    .liquidInput()
                    .frame(width: 220)
                    .disabled(coordinator.isImporting)
            }

            IsleGroupSpacing(height: 4).padding(.leading, 14)

            HStack(spacing: 10) {
                Spacer()
                if coordinator.isImporting {
                    Button("取消导入") {
                        coordinator.cancelImport()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .regular))
                } else {
                    let canStart = coordinator.connected &&
                        !coordinator.selectedMountPath.isEmpty &&
                        !coordinator.scanning &&
                        (coordinator.scanResult?.totalFiles ?? 0) > 0 &&
                        !onlineRoots.isEmpty &&
                        !eligibleUsers.isEmpty
                    Button("开始增量导入") {
                        coordinator.startImport(
                            roots: onlineRoots,
                            users: model.personalSpaces.users
                        )
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                    .disabled(!canStart)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var progressAndResultSection: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                if let status = coordinator.jobStatus {
                    HStack(spacing: 10) {
                        Text(phaseTitle(status.phase))
                            .font(.system(size: 14, weight: .semibold))
                        IsleStatusPill(
                            text: "\(status.processedFiles) / \(status.totalFiles)",
                            tone: status.allVerified ? .success : (status.phase == "failed" ? .warning : .accent),
                            showDot: status.phase == "running"
                        )
                        Spacer()
                        Text("新导入 \(status.importedFiles) · 跳过重复 \(status.skippedFiles) · 失败 \(status.failedFiles)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(IsleTheme.secondaryText)
                    }

                    if status.totalFiles > 0 {
                        ProgressView(
                            value: Double(min(status.processedFiles, status.totalFiles)),
                            total: Double(status.totalFiles)
                        )
                    }

                    if let current = status.currentFile, !current.isEmpty, status.phase == "running" {
                        Text("正在处理：\(current)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if coordinator.canSafeEjectSelectedVolume {
                        HStack(spacing: 10) {
                            Label("全部文件已核验入库，存储卡原件未被删除，现在可以安全弹出。", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(IsleTheme.successText)
                            Spacer()
                            if let disk = matchingEjectDisk {
                                Button("安全弹出此存储卡") {
                                    model.manageDisk(disk, action: "eject")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(model.diskOperationPending || disk.identity.isEmpty)
                            } else {
                                Button("刷新可弹出设备") {
                                    model.refreshManagedDisks()
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            }
                        }
                        .padding(12)
                        .background(IsleTheme.successText.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if let info = coordinator.infoMessage {
                    Label(info, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.successText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = coordinator.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "running": return "正在增量导入存储卡媒体…"
        case "completed": return "导入与核验已完成"
        case "cancelled": return "导入已取消"
        default: return "导入中断"
        }
    }
}
