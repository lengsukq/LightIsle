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
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
