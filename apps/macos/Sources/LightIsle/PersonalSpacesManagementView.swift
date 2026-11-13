import AppKit
import SwiftUI

struct PersonalSpacesManagementView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var spaces: NativeSpacesModel
    @Environment(\.isleReduceMotion) private var reduceMotion

    @State private var showingCreateUserSheet = false
    @State private var showingSwitchRootSheet = false
    @State private var switchSourceRootID = ""
    @State private var switchSourceGeneration: UInt64 = 0
    @State private var switchCategories: Set<String> = []
    @State private var switchInitialTargetRootID = ""
    @State private var switchInitialMode = "migrate"
    @State private var switchInitialQuotaGiB = ""
    @State private var switchAutoStart = false

    @State private var allocRootID = ""
    @State var allocQuotaGiB = "100"
    @State private var allocFiles = true
    @State private var allocPhotos = true
    @State private var allocVideos = true
    @State var allocSubdirs = ""
    @State private var knownOnlineRootIDs: Set<String> = []
    @State var permissionChecking = false

    @State private var editingQuotaGiB: [String: String] = [:]

    var unregisteredExternalVolumes: [HostVolume] {
        guard let volumes = appModel.metrics?.volumes else { return [] }
        return volumes.filter { vol in
            guard StorageVolumeSelection.canChooseOnVolume(mount: vol.mount, readOnly: vol.readOnly) else { return false }
            let isDiskImage = appModel.managedDisks.contains { disk in
                disk.mount == vol.mount && StorageVolumeSelection.isDiskImageProtocol(disk.protocolName)
            }
            guard !isDiskImage else { return false }
            let mountPrefix = vol.mount.hasSuffix("/") ? vol.mount : vol.mount + "/"
            return !spaces.roots.contains { $0.path == vol.mount || $0.path.hasPrefix(mountPrefix) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dataArchitectureCard
            userManagementCard
            if let entry = spaces.selectedEntry {
                selectedUserDetailSection(for: entry)
            }
            IsleQuickJumpBar(items: [
                IsleQuickJumpItem("存储位置管理", icon: "folder.badge.gearshape", tint: IsleFluidPalette.brandCyan, help: "管理默认主目录、附加盘绑定与离线恢复") {
                    appModel.navigateToStorageDetail(.locations)
                },
                IsleQuickJumpItem("Mac 文件共享 (SMB)", icon: "externaldrive.connected.to.line.below", tint: .orange, help: "配置通过访达与播放器接入的 SMB 共享及隔离提醒") {
                    appModel.navigateToConnectionDetail(.sharing)
                },
                IsleQuickJumpItem("权限与初始化预检", icon: "checkmark.shield.fill", tint: .green, help: "检查整盘读写权限与系统隐私授权") {
                    appModel.navigateToSettingsDetail(.permissions)
                }
            ])
        }
        .onAppear {
            if spaces.connected {
                spaces.refresh()
            }
            syncDefaultAllocRoot()
        }
        .onChange(of: spaces.roots) { _, _ in
            syncDefaultAllocRoot()
        }
        .onChange(of: spaces.selectedUserID) { _, newID in
            if newID > 0, spaces.connected {
                spaces.readStorageSwitch(userID: newID, silentIfMissing: true)
            }
        }
        .sheet(isPresented: $showingCreateUserSheet) {
            CreateMemberSpaceSheet(
                spaces: spaces,
                onNavigateToStorage: {
                    appModel.navigateToStorageDetail(.locations)
                },
                onAddExternalRoot: {
                    appModel.rootManagement.addFolder(preferVolumes: true)
                }
            )
        }
        .sheet(isPresented: $showingSwitchRootSheet) {
            if let entry = spaces.selectedEntry {
                SwitchUserRootSheet(
                    spaces: spaces,
                    entry: entry,
                    sourceRootID: switchSourceRootID,
                    sourceGeneration: switchSourceGeneration,
                    initialCategories: switchCategories,
                    initialTargetRootID: switchInitialTargetRootID,
                    initialMode: switchInitialMode,
                    initialQuotaGiB: switchInitialQuotaGiB,
                    autoStartOnAppear: switchAutoStart,
                    onSelectExternalPrimary: {
                        appModel.rootManagement.selectFolderAndSwitch(preferVolumes: true)
                    },
                    onAddExternalRoot: {
                        appModel.rootManagement.addFolder(preferVolumes: true)
                    }
                )
            }
        }
    }

    private func syncDefaultAllocRoot() {
        let currentIDs = Set(spaces.onlineRoots.map(\.rootID))
        if let newlyAdded = spaces.onlineRoots.first(where: { !knownOnlineRootIDs.isEmpty && !knownOnlineRootIDs.contains($0.rootID) }) {
            allocRootID = newlyAdded.rootID
        } else if allocRootID.isEmpty || !currentIDs.contains(allocRootID) {
            allocRootID = spaces.onlineRoots.first(where: \.isDefault)?.rootID
                ?? spaces.onlineRoots.first?.rootID
                ?? ""
        }
        knownOnlineRootIDs = currentIDs
    }

    func openSwitchSheet(
        for entry: NativeSpaceUserEntry,
        sourceRootID: String,
        sourceGeneration: UInt64,
        categories: Set<String>,
        targetRootID: String = "",
        mode: String = "migrate",
        quotaGiB: String = "",
        autoStart: Bool = false
    ) {
        switchSourceRootID = sourceRootID
        switchSourceGeneration = sourceGeneration
        switchCategories = categories
        switchInitialTargetRootID = targetRootID
        switchInitialMode = mode
        switchInitialQuotaGiB = quotaGiB
        switchAutoStart = autoStart
        if spaces.lastTransferResult?.policy.userId != entry.user.id {
            spaces.lastTransferResult = nil
        }
        showingSwitchRootSheet = true
    }

    private var dataArchitectureCard: some View {
        AppleSettingsGroup(
            title: "1. 存储目录管理（默认主目录与多目录空间池）",
            footer: "互不嵌套的目录均可作为独立存储空间；添加或切换目录时直接校验整盘与目录读写权限，获取失败将视为添加失败。"
        ) {
            AppleSettingsRow(
                title: "已登记的存储目录与整盘权限",
                subtitle: "管理默认主目录与外置扩展目录，确保后续用户空间分配与跨目录迁移顺畅可靠。",
                icon: "externaldrive.fill.badge.checkmark",
                iconTint: IsleFluidPalette.brandCyan
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(
                        text: "在线目录 \(spaces.onlineRoots.count) 个",
                        tone: spaces.onlineRoots.isEmpty ? .warning : .success,
                        showDot: true
                    )
                    Button("+ 添加存储目录…") {
                        appModel.rootManagement.addFolder(preferVolumes: true)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(!appModel.canAddOrSwitchStorageRoot)
                    IsleIconButton(
                        icon: "arrow.triangle.swap",
                        help: "切换默认主目录…"
                    ) {
                        appModel.rootManagement.selectFolderAndSwitch(preferVolumes: true)
                    }
                    .disabled(!appModel.canAddOrSwitchStorageRoot)
                }
            }
            if !spaces.onlineRoots.isEmpty {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                PersonalSpacesPoolDistributionView(spaces: spaces)
            }
        }
    }

    private var userManagementCard: some View {
        AppleSettingsGroup(
            title: "2. 用户空间管理（目录分配、配额与旧目录迁移到新目录）",
            footer: "管理每位用户可使用的存储目录、独立配额，并支持将旧目录中的数据一键迁移到新目录。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Label("选择要管理的账号", systemImage: "person.2.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer()
                    if spaces.busy {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        showingCreateUserSheet = true
                    } label: {
                        Label("新建成员并分配空间…", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(!spaces.connected || spaces.busy)

                    IsleIconButton(
                        icon: "arrow.clockwise",
                        help: "刷新成员列表、存储目录归属与配额使用情况"
                    ) {
                        spaces.refresh()
                    }
                    .disabled(!spaces.connected || spaces.busy)
                }

                if spaces.users.isEmpty {
                    Text(spaces.connected ? "尚未创建任何用户，请先初始化管理员账号。" : "Go Core 未运行，启动服务后即可管理所有人的存储位置与配额。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(spaces.users) { entry in
                                userSelectorChip(entry)
                            }
                        }
                    }
                }

                if let err = spaces.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.warningText)
                        .textSelection(.enabled)
                } else if let msg = spaces.message {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
    }

    private func userSelectorChip(_ entry: NativeSpaceUserEntry) -> some View {
        let isSelected = entry.id == (spaces.selectedEntry?.id ?? 0)
        return Button {
            withAnimation(reduceMotion ? nil : IsleMotion.quick) {
                spaces.selectedUserID = entry.id
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.user.isAdmin ? "crown.fill" : "person.fill")
                    .foregroundStyle(entry.user.isAdmin ? .orange : IsleTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.user.username)
                            .font(.system(size: 13, weight: .semibold))
                        Text(entry.user.isAdmin ? "管理员 · 无限" : (entry.user.enabled ? "成员" : "成员 · 已停用"))
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(entry.user.isAdmin ? Color.orange.opacity(0.18) : (entry.user.enabled ? IsleTheme.accent.opacity(0.14) : Color.secondary.opacity(0.16)))
                            )
                    }
                    Text("已绑定 \(entry.policy.locations.count)/3 类目录 · 已用 \(formatBytes(entry.policy.accountedBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? IsleTheme.accent.opacity(0.15) : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? IsleTheme.accent : IsleFluidPalette.rim.opacity(0.6), lineWidth: isSelected ? 1.6 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(IslePressStyle())
    }

    @ViewBuilder
    private func selectedUserDetailSection(for entry: NativeSpaceUserEntry) -> some View {
        if !entry.user.isAdmin {
            PersonalSpacesMemberSecurityCard(appModel: appModel, spaces: spaces, entry: entry)
                .id(entry.id)
        }
        quotaCard(for: entry)
        categoryLocationsCard(for: entry)
        allocateOrAddCard(for: entry)
    }

    private func quotaCard(for entry: NativeSpaceUserEntry) -> some View {
        AppleSettingsGroup(
            title: "\(entry.user.username) · 磁盘配额与用量",
            footer: entry.policy.isUnlimited
                ? "管理员默认不设软件配额上限，所有写入仅受对应存储硬盘的实际剩余空间限制。"
                : "配额执行状态：\(SpaceCategoryPresentation.enforcementDescription(entry.policy.enforcement))（当前统计已接入配额账本的上传与写入通道，离线硬盘保留已有记录）。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if entry.policy.isUnlimited {
                    HStack(spacing: 10) {
                        IsleStatusPill(text: "管理员默认无限配额", tone: .success, icon: "infinity")
                        Text("已记录个人目录写入：\(formatBytes(entry.policy.accountedBytes))")
                            .font(.system(size: 12.5))
                            .foregroundStyle(IsleTheme.secondaryText)
                        Spacer()
                    }
                    PersonalSpacesAdminDiskSummaryView(spaces: spaces, preferredRootID: allocRootID)
                } else if entry.policy.rootQuotas.isEmpty {
                    Text("该成员尚未分配任何存储硬盘，请在下方选择硬盘并分配存储空间。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                } else {
                    ForEach(entry.policy.rootQuotas) { rq in
                        memberRootQuotaRow(user: entry.user, rq: rq, enforcement: entry.policy.enforcement)
                    }
                }
            }
            .padding(14)
        }
    }

    private func memberRootQuotaRow(user: NativeSpaceUserAccount, rq: NativeStorageRootQuota, enforcement: String) -> some View {
        let rootMeta = spaces.rootInfo(for: rq.rootID)
        let rootTitle = rootMeta?.name ?? "旧硬盘 (\(rq.rootID.prefix(8)))"
        let isRemoved = rootMeta == nil
        let key = "\(user.id)-\(rq.rootID)-\(rq.rootGeneration)"
        let savedGiB: Int64 = (rq.quotaBytes ?? 0) > 0 ? max(1, (rq.quotaBytes ?? 0) / QuotaInputValidator.bytesPerGiB) : 0
        let currentGiBString = editingQuotaGiB[key] ?? (savedGiB > 0 ? String(savedGiB) : "0")
        let usedBytes = rq.accountedBytes + rq.reservedBytes
        let validation = QuotaInputValidator.validateGiB(currentGiBString, currentUsedBytes: usedBytes)
        let hasUnsavedChange = editingQuotaGiB[key] != nil && validation.quotaBytes != (rq.quotaBytes ?? 0)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(rootTitle)
                    .font(.system(size: 13, weight: .semibold))
                if let rootMeta {
                    let available = rootMeta.isAvailable(for: rq.rootGeneration)
                    IsleStatusPill(
                        text: rootMeta.statusText(for: rq.rootGeneration),
                        tone: available ? .success : .warning,
                        showDot: true
                    )
                    if let avail = rootMeta.filesystemAvailableBytes {
                        Text("物理盘可用 \(formatBytes(Int64(avail)))")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                } else {
                    IsleStatusPill(text: "已移除登记", tone: .warning)
                }
                Spacer()
                let quotaLabel = (rq.quotaBytes ?? 0) > 0 ? formatBytes(rq.quotaBytes ?? 0) : "不限制"
                Text("已计入 \(formatBytes(rq.accountedBytes)) / 配额 \(quotaLabel)")
                    .font(.system(size: 12, weight: .medium))
            }
            if let quota = rq.quotaBytes, quota > 0 {
                PersonalSpacesMemberQuotaMeterView(
                    quotaBytes: quota,
                    accountedBytes: rq.accountedBytes,
                    reservedBytes: rq.reservedBytes,
                    enforcement: enforcement
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("调整该盘配额 (GiB)：")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                    ForEach([50, 100, 200, 500, 1024], id: \.self) { preset in
                        Button(preset >= 1024 ? "1 TB" : "\(preset) GB") {
                            editingQuotaGiB[key] = "\(preset)"
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(spaces.busy)
                    }
                }
                HStack(spacing: 8) {
                    TextField(
                        "GiB",
                        text: Binding(
                            get: { currentGiBString },
                            set: { editingQuotaGiB[key] = $0 }
                        )
                    )
                    .liquidInput()
                    .frame(width: 84)
                    Button(hasUnsavedChange ? "保存配额*" : "保存配额") {
                        guard let bytes = validation.quotaBytes else { return }
                        spaces.setRootQuota(
                            userID: user.id,
                            rootID: rq.rootID,
                            generation: rq.rootGeneration,
                            quotaBytes: bytes
                        )
                        editingQuotaGiB.removeValue(forKey: key)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(spaces.busy || !validation.isValid)

                    if let entry = spaces.selectedEntry {
                        let boundCats = Set(
                            entry.policy.locations
                                .filter { $0.rootID == rq.rootID && $0.rootGeneration == rq.rootGeneration }
                                .map(\.category)
                        )
                        Button("迁移到新目录…") {
                            openSwitchSheet(
                                for: entry,
                                sourceRootID: rq.rootID,
                                sourceGeneration: rq.rootGeneration,
                                categories: boundCats.isEmpty ? ["files", "photos", "videos"] : boundCats
                            )
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(spaces.busy)
                    }

                    if isRemoved {
                        Button("放弃该旧盘记录") {
                            spaces.abandonBinding(userID: user.id, rootID: rq.rootID, generation: rq.rootGeneration, category: nil)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                        .disabled(spaces.busy)
                    }
                }
            }
            if let err = validation.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(IsleTheme.warningText)
            } else if let warn = validation.warningMessage {
                Text(warn)
                    .font(.caption2)
                    .foregroundStyle(IsleTheme.warningText)
            } else if hasUnsavedChange {
                Text("已填入新配额草稿，点击「保存配额」后生效。")
                    .font(.caption2)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func categoryLocationsCard(for entry: NativeSpaceUserEntry) -> some View {
        AppleSettingsGroup(
            title: "\(entry.user.username) · 个人分类存储位置与跨盘数据迁移（文件 / 相册 / 影视）",
            footer: "所有个人文件、相册、影视的跨盘复制与迁移统一在此处发起。支持「复制并核验后回收源文件」「仅复制（保留两份原件）」「直接剪切」或「启用空白新目录」。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let primaryLoc = entry.policy.locations.first {
                    let sameDiskCats = Set(
                        entry.policy.locations
                            .filter { $0.rootID == primaryLoc.rootID && $0.rootGeneration == primaryLoc.rootGeneration }
                            .map(\.category)
                    )
                    HStack(spacing: 10) {
                        Label("支持将 Users/u\(entry.user.id) 下的个人文件、相册与影视专属目录跨盘迁移", systemImage: "externaldrive.connected.to.line.below")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        Spacer()
                        Button("查询换盘任务") {
                            spaces.readStorageSwitch(userID: entry.user.id)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(spaces.busy)
                        Button("设定新盘 / 迁移全部个人数据…") {
                            openSwitchSheet(
                                for: entry,
                                sourceRootID: primaryLoc.rootID,
                                sourceGeneration: primaryLoc.rootGeneration,
                                categories: sameDiskCats
                            )
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(spaces.busy)
                    }
                    .padding(.bottom, 2)
                }
                if let transfer = spaces.lastTransferResult,
                   transfer.policy.userId == entry.user.id,
                   transfer.phase != "completed" && transfer.phase != "cancelled" {
                    PersonalSpacesTransferBanner(spaces: spaces, entry: entry, transfer: transfer) { rootID, gen, cats in
                        openSwitchSheet(for: entry, sourceRootID: rootID, sourceGeneration: gen, categories: cats)
                    }
                }
                ForEach(["files", "photos", "videos"], id: \.self) { category in
                    categoryLocationRow(for: entry, category: category)
                }
                PersonalSpacesOtherRootsNotice(
                    userID: entry.user.id,
                    boundRootIDs: Set(entry.policy.locations.map(\.rootID)),
                    allRoots: spaces.roots
                )
            }
            .padding(14)
        }
    }

    private func categoryLocationRow(for entry: NativeSpaceUserEntry, category: String) -> some View {
        let loc = entry.policy.locations.first(where: { $0.category == category })
        let rootMeta = loc.flatMap { spaces.rootInfo(for: $0.rootID) }
        let title = SpaceCategoryPresentation.detailLabel(for: category)
        let icon = SpaceCategoryPresentation.icon(for: category)

        return HStack(alignment: .top, spacing: 12) {
            IsleHeaderIconBadge(icon: icon, tint: IsleTheme.accent, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    if let loc {
                        if let rootMeta {
                            let available = rootMeta.isAvailable(for: loc.rootGeneration)
                            IsleStatusPill(
                                text: rootMeta.statusText(for: loc.rootGeneration, includeName: true),
                                tone: available ? .success : .warning,
                                showDot: true
                            )
                        } else {
                            IsleStatusPill(text: "旧硬盘已移除登记", tone: .warning)
                        }
                        if loc.rootGeneration > 1 {
                            IsleStatusPill(text: "已重连更新", tone: .neutral)
                                .help("硬盘重连批次 #\(loc.rootGeneration)")
                        }
                    } else {
                        IsleStatusPill(text: "尚未分配", tone: .neutral)
                    }
                }
                if let loc {
                    let fullPath = rootMeta.map { "\($0.path)/\(loc.relativePath)" } ?? loc.relativePath
                    Text(fullPath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                } else {
                    Text("请在下方选择存储硬盘并勾选「\(title)」以创建专属目录。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
            Spacer()
            if let loc {
                HStack(spacing: 8) {
                    if let rootMeta, !rootMeta.isAvailable(for: loc.rootGeneration), rootMeta.online {
                        IsleIconButton(icon: "arrow.clockwise", help: "同步当前存储目录在线状态") {
                            spaces.refresh()
                        }
                        .disabled(spaces.busy)
                    }
                    if let rootMeta, rootMeta.online {
                        IsleIconButton(icon: "folder", help: "在访达中打开该分类专属目录") {
                            let targetURL = URL(fileURLWithPath: rootMeta.path).appendingPathComponent(loc.relativePath)
                            NSWorkspace.shared.open(targetURL)
                        }
                    }
                    if rootMeta == nil {
                        Button("放弃旧绑定") {
                            spaces.abandonBinding(
                                userID: entry.user.id,
                                rootID: loc.rootID,
                                generation: loc.rootGeneration,
                                category: category
                            )
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                        .disabled(spaces.busy)
                    }
                    Button("更换硬盘 / 迁移…") {
                        openSwitchSheet(
                            for: entry,
                            sourceRootID: loc.rootID,
                            sourceGeneration: loc.rootGeneration,
                            categories: [category]
                        )
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(spaces.busy)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func selectedAllocationCategories() -> [String] {
        var categories: [String] = []
        if allocFiles { categories.append("files") }
        if allocPhotos { categories.append("photos") }
        if allocVideos { categories.append("videos") }
        return categories
    }

    private func allocateOrAddCard(for entry: NativeSpaceUserEntry) -> some View {
        let selectedRoot = spaces.onlineRoots.first(where: { $0.rootID == allocRootID }) ?? spaces.onlineRoots.first
        let allocValidation = QuotaInputValidator.validateGiB(allocQuotaGiB)
        let checkedCats = selectedAllocationCategories()
        let boundOnOtherDisk = entry.policy.locations.filter { loc in
            checkedCats.contains(loc.category) &&
                (loc.rootID != selectedRoot?.rootID || loc.rootGeneration != selectedRoot?.generation)
        }

        return AppleSettingsGroup(
            title: "为「\(entry.user.username)」分配初始存储目录或新建子文件夹",
            footer: "接入新外置硬盘后可直接设为目标存储盘；如需把已有分类目录迁移到另一块硬盘，请点击上方「设定新盘 / 迁移全部个人数据…」统一在换盘向导中操作。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !unregisteredExternalVolumes.isEmpty {
                    unregisteredVolumesBanner
                }
                if spaces.onlineRoots.isEmpty {
                    emptyOnlineRootsNotice
                } else {
                    allocationFormContent(
                        for: entry,
                        selectedRoot: selectedRoot,
                        allocValidation: allocValidation,
                        checkedCats: checkedCats,
                        boundOnOtherDisk: boundOnOtherDisk
                    )
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func allocationFormContent(
        for entry: NativeSpaceUserEntry,
        selectedRoot: NativeSpaceRootInfo?,
        allocValidation: QuotaValidationResult,
        checkedCats: [String],
        boundOnOtherDisk: [NativeStorageLocation]
    ) -> some View {
        allocationRootPickerRow(for: entry)
        if let rootMsg = appModel.rootManagement.message, !rootMsg.isEmpty {
            Text(rootMsg).font(.caption2).foregroundStyle(IsleTheme.secondaryText)
        }
        if !entry.policy.isUnlimited, let err = allocValidation.errorMessage {
            Text(err).font(.caption2).foregroundStyle(IsleTheme.warningText)
        }
        HStack(spacing: 16) {
            Text("目标分类目录：").font(.caption).foregroundStyle(IsleTheme.secondaryText)
            Toggle(SpaceCategoryPresentation.detailLabel(for: "files"), isOn: $allocFiles).toggleStyle(.checkbox)
            Toggle(SpaceCategoryPresentation.detailLabel(for: "photos"), isOn: $allocPhotos).toggleStyle(.checkbox)
            Toggle(SpaceCategoryPresentation.detailLabel(for: "videos"), isOn: $allocVideos).toggleStyle(.checkbox)
        }
        HStack(spacing: 10) {
            Text("新建子目录（可选，逗号分隔）：").font(.caption).foregroundStyle(IsleTheme.secondaryText)
            TextField("例如：files/工作文档, photos/2026家庭相册, videos/电影", text: $allocSubdirs)
                .liquidInput()
        }
        if entry.policy.locations.isEmpty, spaces.roots.count > 1 {
            Text("提示：首次分配将在目标盘新建空白的 Users/u\(entry.user.id) 专属目录，不会自动搬移原存储目录根层或「图库 / PhonePhotos」中的既有照片与文件（原数据保留在原盘）。")
                .font(.caption2)
                .foregroundStyle(IsleTheme.secondaryText)
        }
        allocationSubmitRow(
            for: entry,
            selectedRoot: selectedRoot,
            allocValidation: allocValidation,
            checkedCats: checkedCats,
            boundOnOtherDisk: boundOnOtherDisk
        )
    }

    private func allocationRootPickerRow(for entry: NativeSpaceUserEntry) -> some View {
        HStack(spacing: 10) {
            Picker("目标存储硬盘", selection: $allocRootID) {
                ForEach(spaces.onlineRoots) { r in
                    Text("\(r.name)\(r.isDefault ? " · 默认主存储" : "")（\(r.path)）").tag(r.rootID)
                }
            }
            .frame(maxWidth: 400)

            Button("选择外置盘设为主存储…") { appModel.rootManagement.selectFolderAndSwitch(preferVolumes: true) }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                .disabled(!appModel.canAddOrSwitchStorageRoot)

            Button("+ 添加外置盘…") { appModel.rootManagement.addFolder(preferVolumes: true) }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(!appModel.canAddOrSwitchStorageRoot)

            if entry.policy.isUnlimited {
                IsleStatusPill(text: "配额：管理员默认无限", tone: .success)
            } else {
                HStack(spacing: 6) {
                    Text("该盘配额 (GiB)：").font(.caption)
                    TextField("100", text: $allocQuotaGiB).liquidInput().frame(width: 78)
                }
            }
            Spacer()
        }
    }
}
