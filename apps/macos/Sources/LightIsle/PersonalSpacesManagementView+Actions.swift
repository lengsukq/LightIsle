import AppKit
import SwiftUI

extension PersonalSpacesManagementView {
    func allocationSubmitRow(
        for entry: NativeSpaceUserEntry,
        selectedRoot: NativeSpaceRootInfo?,
        allocValidation: QuotaValidationResult,
        checkedCats: [String],
        boundOnOtherDisk: [NativeStorageLocation]
    ) -> some View {
        let isSwitchingDisk = selectedRoot != nil && !boundOnOtherDisk.isEmpty
        return HStack(spacing: 10) {
            if isSwitchingDisk, let root = selectedRoot, let sourceLoc = boundOnOtherDisk.first {
                Button("所选分类已绑定其他盘 · 打开跨盘迁移向导…") {
                    let catsToSwitch = Set(
                        boundOnOtherDisk
                            .filter { $0.rootID == sourceLoc.rootID && $0.rootGeneration == sourceLoc.rootGeneration }
                            .map(\.category)
                    )
                    openSwitchSheet(
                        for: entry, sourceRootID: sourceLoc.rootID, sourceGeneration: sourceLoc.rootGeneration,
                        categories: catsToSwitch, targetRootID: root.rootID, mode: "migrate",
                        quotaGiB: entry.policy.isUnlimited ? "" : allocQuotaGiB
                    )
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                .disabled(spaces.busy || checkedCats.isEmpty)
            } else {
                Button("保存并创建目录") {
                    submitSpaceAllocation(for: entry, selectedRoot: selectedRoot, allocValidation: allocValidation, checkedCats: checkedCats)
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                .disabled(spaces.busy || permissionChecking || selectedRoot == nil || (!entry.policy.isUnlimited && !allocValidation.isValid))
            }
            Spacer()
        }
    }

    func submitSpaceAllocation(
        for entry: NativeSpaceUserEntry,
        selectedRoot: NativeSpaceRootInfo?,
        allocValidation: QuotaValidationResult,
        checkedCats: [String]
    ) {
        guard !permissionChecking, let root = selectedRoot else { return }
        if !entry.policy.isUnlimited, !allocValidation.isValid { return }
        let subdirs = allocSubdirs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let quotaBytes: Int64? = entry.policy.isUnlimited ? nil : allocValidation.quotaBytes
        permissionChecking = true
        Task { @MainActor in
            defer { permissionChecking = false }
            let access = await StoragePermissionHelper.ensureDirectoryWritable(
                URL(fileURLWithPath: root.path, isDirectory: true),
                reason: "在「\(root.name)」上为「\(entry.user.username)」创建个人分类目录需要该硬盘读写权限。"
            )
            guard access.ok else {
                spaces.errorMessage = access.errorMessage
                return
            }
            guard spaces.connected, !spaces.busy else { return }
            spaces.allocateSpace(
                userID: entry.user.id, rootID: root.rootID, generation: root.generation,
                quotaBytes: quotaBytes, categories: checkedCats, subdirectories: subdirs
            )
            allocSubdirs = ""
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        IsleFormatters.binarySize(bytes)
    }

    var unregisteredVolumesBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(unregisteredExternalVolumes) { vol in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        unregisteredVolumeHeader(vol)
                        Spacer()
                        unregisteredVolumeButtons(vol)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        unregisteredVolumeHeader(vol)
                        HStack(spacing: 8) {
                            unregisteredVolumeButtons(vol)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IsleFluidPalette.brandCyan.opacity(0.1)))
    }

    private func unregisteredVolumeHeader(_ vol: HostVolume) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill.badge.plus")
                .foregroundStyle(IsleFluidPalette.brandCyan)
            Text("检测到外置硬盘「\(vol.name)」（可用 \(formatBytes(Int64(vol.free)))）")
                .font(.system(size: 12.5, weight: .semibold))
        }
    }

    @ViewBuilder
    private func unregisteredVolumeButtons(_ vol: HostVolume) -> some View {
        Button("添加为目标盘（推荐）") {
            appModel.addPresetSharedFolder(
                path: "\(vol.mount)/LightIsle",
                name: "\(vol.name)-LightIsle"
            )
        }
        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
        .disabled(!appModel.canAddOrSwitchStorageRoot)
        Button("设为主存储…") {
            appModel.selectPresetSharedFolder(
                path: "\(vol.mount)/LightIsle",
                name: "\(vol.name)-LightIsle",
                confirmSwitch: true
            )
        }
        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
        .disabled(!appModel.canAddOrSwitchStorageRoot)
        Button("选择文件夹…") {
            appModel.selectSharedFolder(onVolume: vol)
        }
        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
        .disabled(!appModel.canAddOrSwitchStorageRoot)
    }

    var emptyOnlineRootsNotice: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text("当前没有在线的 NAS 存储硬盘，请接入外置硬盘或前往「存储位置」设置。")
                    .font(.caption).foregroundStyle(IsleTheme.warningText)
                Spacer()
                emptyOnlineRootsButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("当前没有在线的 NAS 存储硬盘，请接入外置硬盘或前往「存储位置」设置。")
                    .font(.caption).foregroundStyle(IsleTheme.warningText)
                HStack(spacing: 8) {
                    emptyOnlineRootsButtons
                }
            }
        }
    }

    @ViewBuilder
    private var emptyOnlineRootsButtons: some View {
        Button("选择外置盘设为主存储…") { appModel.rootManagement.selectFolderAndSwitch(preferVolumes: true) }
            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
            .disabled(!appModel.canAddOrSwitchStorageRoot)
        Button("前往存储位置…") { appModel.navigateToStorageDetail(.locations) }
            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
    }
}
