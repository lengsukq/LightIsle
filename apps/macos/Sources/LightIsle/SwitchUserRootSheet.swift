import AppKit
import SwiftUI

struct SwitchUserRootSheet: View {
    @ObservedObject var spaces: NativeSpacesModel
    let entry: NativeSpaceUserEntry
    let sourceRootID: String
    let sourceGeneration: UInt64
    let initialCategories: Set<String>
    var initialTargetRootID: String = ""
    var initialMode: String = "migrate"
    var initialQuotaGiB: String = ""
    var autoStartOnAppear: Bool = false
    var onSelectExternalPrimary: (() -> Void)? = nil
    var onAddExternalRoot: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategories: Set<String> = []
    @State private var targetRootID = ""
    @State private var mode = "migrate"
    @State private var targetQuotaGiB = ""
    @State private var permissionChecking = false

    private var availableTargetRoots: [NativeSpaceRootInfo] {
        spaces.onlineRoots.filter { $0.rootID != sourceRootID || $0.generation != sourceGeneration }
    }

    private var sourceOnline: Bool {
        spaces.onlineRoots.contains { $0.rootID == sourceRootID && $0.generation == sourceGeneration }
    }

    private var transfer: NativeStorageSwitchResult? {
        guard spaces.lastTransferResult?.policy.userId == entry.user.id else { return nil }
        return spaces.lastTransferResult
    }

    private var sourceCategoriesOnDisk: [NativeStorageLocation] {
        entry.policy.locations.filter { $0.rootID == sourceRootID && $0.rootGeneration == sourceGeneration }
    }

    private var quotaValidation: QuotaValidationResult {
        QuotaInputValidator.validateGiB(targetQuotaGiB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("更换「\(entry.user.username)」的存储硬盘")
                    .font(.system(size: 16, weight: .semibold))
                Text("支持跨硬盘复制并校验 SHA-256、直接剪切或在新硬盘启用空白目录。源文件清理默认进入旧盘可恢复回收站。")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    configurationSection
                    impactDisclosureSection
                    if let transfer {
                        progressSection(for: transfer)
                    }
                    if let err = spaces.errorMessage {
                        errorDiagnosticSection(message: err)
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()
            footerActions
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 620, minHeight: 420, idealHeight: 490, maxHeight: 550)
        .onAppear {
            selectedCategories = initialCategories.isEmpty
                ? Set(sourceCategoriesOnDisk.map(\.category))
                : initialCategories
            if !initialTargetRootID.isEmpty, availableTargetRoots.contains(where: { $0.rootID == initialTargetRootID }) {
                targetRootID = initialTargetRootID
            } else {
                targetRootID = availableTargetRoots.first?.rootID ?? ""
            }
            if !initialQuotaGiB.isEmpty {
                targetQuotaGiB = initialQuotaGiB
            }
            mode = sourceOnline ? initialMode : "empty"
            if autoStartOnAppear, !targetRootID.isEmpty, !selectedCategories.isEmpty {
                triggerSwitch(phase: "copy_and_verify")
            } else {
                spaces.readStorageSwitch(userID: entry.user.id, silentIfMissing: true)
            }
        }
        .onChange(of: spaces.roots) { oldRoots, newRoots in
            let oldIDs = Set(oldRoots.map(\.rootID))
            if let added = newRoots.first(where: { $0.online && !oldIDs.contains($0.rootID) && ($0.rootID != sourceRootID || $0.generation != sourceGeneration) }) {
                targetRootID = added.rootID
            } else if targetRootID.isEmpty || !availableTargetRoots.contains(where: { $0.rootID == targetRootID }) {
                targetRootID = availableTargetRoots.first?.rootID ?? ""
            }
        }
        .onChange(of: spaces.lastTransferResult) { _, newValue in
            if let res = newValue, res.phase == "completed" {
                dismiss()
            }
        }
    }

    private var configurationSection: some View {
        let controlsDisabled = transfer?.isRunning == true || spaces.busy || permissionChecking
        return VStack(alignment: .leading, spacing: 10) {
            Text("1. 选择要切换的分类目录：").font(.system(size: 13, weight: .medium))
            HStack(spacing: 16) {
                ForEach(sourceCategoriesOnDisk, id: \.category) { loc in
                    Toggle(SpaceCategoryPresentation.detailLabel(for: loc.category), isOn: Binding(
                        get: { selectedCategories.contains(loc.category) },
                        set: { if $0 { selectedCategories.insert(loc.category) } else { selectedCategories.remove(loc.category) } }
                    )).toggleStyle(.checkbox)
                }
            }
            .disabled(controlsDisabled)

            if availableTargetRoots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("2. 尚未登记目标外置硬盘：请先选择外置硬盘文件夹（若直接选整块外置盘，将自动创建 LightIsle 专用目录）", systemImage: "externaldrive.badge.plus")
                        .font(.caption).foregroundStyle(IsleTheme.warningText)
                    HStack(spacing: 8) {
                        if let onSelectExternalPrimary {
                            Button("选择外置硬盘并设为主存储…", action: onSelectExternalPrimary)
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(controlsDisabled)
                        }
                        if let onAddExternalRoot {
                            Button("+ 添加外置盘目录…", action: onAddExternalRoot)
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(controlsDisabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            } else {
                HStack(spacing: 8) {
                    Picker("2. 目标在线硬盘：", selection: $targetRootID) {
                        ForEach(availableTargetRoots) { r in
                            Text("\(r.name)\(r.isDefault ? " · 主存储" : "")（\(r.path)）").tag(r.rootID)
                        }
                    }
                    .disabled(controlsDisabled)
                    if let onAddExternalRoot {
                        Button("+ 选择其他外置硬盘…", action: onAddExternalRoot)
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(controlsDisabled)
                    }
                }
            }

            if !entry.policy.isUnlimited {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("目标盘配额上限 (GiB，留空保持默认)：").font(.caption)
                        TextField("100", text: $targetQuotaGiB)
                            .liquidInput()
                            .frame(width: 90)
                            .disabled(controlsDisabled)
                    }
                    if let err = quotaValidation.errorMessage {
                        Text(err).font(.caption2).foregroundStyle(IsleTheme.warningText)
                    }
                }
            }

            Picker("3. 切换方式：", selection: $mode) {
                if sourceOnline {
                    Text("复制并核验后回收源文件（两步确认，推荐）").tag("migrate")
                    Text("直接复制核验并切换（保留两份原件）").tag("copy")
                    Text("直接剪切并切换（源文件移入旧盘回收站）").tag("move")
                }
                Text("启用空白新目录（旧盘原件保留不动）").tag("empty")
            }
            .pickerStyle(.radioGroup)
            .disabled(controlsDisabled)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }

    private var impactDisclosureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("媒体记录与分享影响说明", systemImage: "info.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(IsleTheme.accent)
            Text(StorageSwitchStagePresentation.mediaAndShareImpactNote(for: mode))
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(IsleTheme.accent.opacity(0.08)))
    }

    private func progressSection(for transfer: NativeStorageSwitchResult) -> some View {
        let stage = StorageSwitchStagePresentation.describe(
            phase: transfer.phase,
            mode: transfer.mode,
            copiedBytes: transfer.copiedBytes,
            totalBytes: transfer.totalBytes,
            verifiedFiles: transfer.verifiedFiles,
            totalFiles: transfer.totalFiles,
            deletedSourceFiles: transfer.deletedSourceFiles
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stage.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("阶段 \(stage.stepIndex)/\(stage.totalSteps)")
                    .font(.caption2)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            if let fraction = stage.fraction {
                ProgressView(value: fraction)
                    .tint(transfer.phase == "verified" ? .green : IsleTheme.accent)
            }
            Text(stage.subtitle)
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)
            if let errCode = transfer.error, !errCode.isEmpty {
                Text(spaces.humanizeSpacesError(errCode, detail: transfer.errorDetail, reviewPath: transfer.reviewPath))
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
                    .textSelection(.enabled)
            }
            if let reviewPath = transfer.reviewPath, !reviewPath.isEmpty {
                HStack(spacing: 8) {
                    Text("当前核对目录：\(reviewPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                    if let targetRoot = availableTargetRoots.first(where: { $0.rootID == targetRootID }) {
                        Button("在访达中检查") {
                            let url = URL(fileURLWithPath: targetRoot.path).appendingPathComponent(reviewPath)
                            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: targetRoot.path))
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
            }
            if transfer.phase == "verified" {
                Label("源盘文件尚未删除。确认无误后点击下方「确认切换并回收源文件」完成切换。", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let items = transfer.affectedShareItems, !items.isEmpty {
                DisclosureGroup("受影响的共享相册与公开分享链接（\(transfer.affectedShares) 项）") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            Text("• \(item.description)")
                        }
                        if transfer.affectedShares > items.count {
                            Text("另有 \(transfer.affectedShares - items.count) 项。")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func errorDiagnosticSection(message: String) -> some View {
        let isPermissionError = spaces.lastErrorCode == "storage_permission_os_denied"
            || transfer?.error == "storage_permission_os_denied"
        let isBusyError = spaces.lastErrorCode == "storage_switch_busy"
            || spaces.lastErrorCode == "shared_directory_busy"
        let busy = spaces.busy || permissionChecking
        return VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(IsleTheme.warningText).textSelection(.enabled)
            HStack(spacing: 8) {
                if isPermissionError {
                    Button("立即申请目录读写权限并重试…") { requestPermissionAndRetry() }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small)).disabled(busy)
                }
                if isBusyError {
                    Button("加载当前任务状态") { spaces.readStorageSwitch(userID: entry.user.id) }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small)).disabled(busy)
                }
                if let targetRoot = availableTargetRoots.first(where: { $0.rootID == targetRootID }) {
                    Button("终端命令修复引导…") {
                        let res = StoragePermissionHelper.presentManualCommandGuide(
                            forPath: targetRoot.path,
                            reason: "迁移「\(entry.user.username)」的个人数据到「\(targetRoot.name)」",
                            failureDetail: nil
                        )
                        if res.ok { triggerSwitch(phase: "copy_and_verify") }
                        else if let msg = res.errorMessage { spaces.errorMessage = msg }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small)).disabled(busy)
                    Button("在访达中检查目标目录") { NSWorkspace.shared.open(URL(fileURLWithPath: targetRoot.path)) }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var footerActions: some View {
        let busy = spaces.busy || permissionChecking
        return HStack {
            Button("查看最近任务") { spaces.readStorageSwitch(userID: entry.user.id) }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small)).disabled(busy)

            Spacer()
            Button("关闭") { dismiss() }
                .buttonStyle(LiquidButtonStyle(variant: .secondary))
                .keyboardShortcut(.cancelAction)

            if let transfer, transfer.phase == "verified" {
                Button("取消任务") {
                    spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "cancel")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary))
                .disabled(busy)
                Button("确认切换并回收源文件") {
                    spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "confirm_cleanup")
                }
                .buttonStyle(LiquidButtonStyle(variant: .destructive)).disabled(busy)
            } else if let transfer, transfer.phase == "interrupted", (transfer.canResume == true || transfer.canCancel == true) {
                if transfer.canCancel == true {
                    Button("取消中断任务") {
                        spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "cancel")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary))
                    .disabled(busy)
                }
                if transfer.canResume == true {
                    Button("重新核验并继续切换") {
                        spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "resume_publish")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent)).disabled(busy)
                }
            } else if let transfer, transfer.phase == "source_pending" {
                Button("恢复源盘清理") {
                    spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "recover_source")
                }
                .buttonStyle(LiquidButtonStyle(variant: .destructive)).disabled(busy)
            } else {
                if let transfer, transfer.phase == "copying" || transfer.phase == "queued" {
                    Button("取消任务") {
                        spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "cancel")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary))
                    .disabled(busy)
                }
                Button(mode == "migrate" ? "开始复制并核验" : "确认切换") {
                    triggerSwitch(phase: "copy_and_verify")
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent))
                .disabled(
                    busy || transfer?.isRunning == true || selectedCategories.isEmpty ||
                    targetRootID.isEmpty || (!entry.policy.isUnlimited && !quotaValidation.isValid)
                )
            }
        }
    }

    private func requestPermissionAndRetry() {
        guard !permissionChecking, let targetRoot = availableTargetRoots.first(where: { $0.rootID == targetRootID }) else { return }
        permissionChecking = true
        Task { @MainActor in
            let access = await StoragePermissionHelper.requestReadWriteAccess(
                forPath: targetRoot.path,
                reason: "迁移「\(entry.user.username)」的个人文件、相册或影视到「\(targetRoot.name)」需要该目录的读写权限。"
            )
            permissionChecking = false
            guard access.ok else {
                spaces.errorMessage = access.errorMessage
                return
            }
            triggerSwitch(phase: "copy_and_verify")
        }
    }

    private func triggerSwitch(phase: String) {
        guard !permissionChecking, let targetRoot = availableTargetRoots.first(where: { $0.rootID == targetRootID }) else { return }
        var quota: Int64?
        if !entry.policy.isUnlimited {
            guard quotaValidation.isValid else {
                spaces.errorMessage = quotaValidation.errorMessage
                return
            }
            if !targetQuotaGiB.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                quota = quotaValidation.quotaBytes
            }
        }
        let capturedCategories = Array(selectedCategories).sorted()
        let capturedMode = mode
        let sourceRoot = spaces.onlineRoots.first(where: { $0.rootID == sourceRootID && $0.generation == sourceGeneration })
        permissionChecking = true
        Task { @MainActor in
            defer { permissionChecking = false }
            let targetAccess = await StoragePermissionHelper.ensureDirectoryWritable(
                URL(fileURLWithPath: targetRoot.path, isDirectory: true),
                reason: "迁移「\(entry.user.username)」的个人数据到「\(targetRoot.name)」需要目标目录读写权限。"
            )
            guard targetAccess.ok else {
                spaces.errorMessage = targetAccess.errorMessage
                return
            }
            if capturedMode != "empty", let sourceRoot {
                let sourceAccess = await StoragePermissionHelper.ensureDirectoryWritable(
                    URL(fileURLWithPath: sourceRoot.path, isDirectory: true),
                    reason: "从「\(sourceRoot.name)」读取或回收源文件需要来源目录读写权限。"
                )
                guard sourceAccess.ok else {
                    spaces.errorMessage = sourceAccess.errorMessage
                    return
                }
            }
            guard spaces.connected, !spaces.busy else { return }
            spaces.switchRoot(
                userID: entry.user.id,
                categories: capturedCategories,
                sourceRootID: sourceRootID,
                sourceGeneration: sourceGeneration,
                targetRootID: targetRoot.rootID,
                targetGeneration: targetRoot.generation,
                targetQuotaBytes: quota,
                mode: capturedMode,
                phase: phase
            )
        }
    }
}
