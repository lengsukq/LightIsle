import AppKit
import SwiftUI

struct PersonalSpacesManagementView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var spaces: NativeSpacesModel

    @State private var showingCreateUserSheet = false
    @State private var showingSwitchRootSheet = false
    @State private var switchSourceRootID = ""
    @State private var switchSourceGeneration: UInt64 = 0
    @State private var switchCategories: Set<String> = []

    @State private var allocRootID = ""
    @State private var allocQuotaGiB = "100"
    @State private var allocFiles = true
    @State private var allocPhotos = true
    @State private var allocVideos = true
    @State private var allocSubdirs = ""

    @State private var editingQuotaGiB: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dataArchitectureCard
            userManagementCard
            if let entry = spaces.selectedEntry {
                selectedUserDetailSection(for: entry)
            }
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
        .sheet(isPresented: $showingCreateUserSheet) {
            CreateMemberSpaceSheet(
                spaces: spaces,
                onNavigateToStorage: {
                    appModel.selectedSidebarPage = .storage
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
                    initialCategories: switchCategories
                )
            }
        }
    }

    private func syncDefaultAllocRoot() {
        if allocRootID.isEmpty || !spaces.onlineRoots.contains(where: { $0.rootID == allocRootID }) {
            allocRootID = spaces.onlineRoots.first(where: \.isDefault)?.rootID
                ?? spaces.onlineRoots.first?.rootID
                ?? ""
        }
    }

    private var dataArchitectureCard: some View {
        AppleSettingsGroup(
            title: "数据存放位置说明",
            footer: "账号与权限配置固定保存在 Mac 系统盘；图片、视频、文件及相册缩略图缓存均存放在所选存储硬盘（支持内置目录或外置移动硬盘）。"
        ) {
            AppleSettingsRow(
                title: "账号与系统配置（Mac 系统盘）",
                subtitle: spaces.systemAppDataPath,
                icon: "person.badge.shield.checkmark.fill",
                iconTint: .blue
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(text: "系统盘保留", tone: .accent)
                    Button("在访达中查看") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: spaces.systemAppDataPath))
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "个人文件、照片、影视与应用衍生缓存（所选存储硬盘）",
                subtitle: "每位成员的独立文件夹（文件、相册、影视）与缩略图缓存均存放在指定的存储硬盘上，支持外置硬盘。",
                icon: "externaldrive.fill.badge.checkmark",
                iconTint: IsleFluidPalette.brandCyan
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(
                        text: "在线硬盘 \(spaces.onlineRoots.count) 块",
                        tone: spaces.onlineRoots.isEmpty ? .warning : .success,
                        showDot: true
                    )
                    Button("管理存储硬盘登记…") {
                        appModel.selectedSidebarPage = .storage
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
        }
    }

    private var userManagementCard: some View {
        AppleSettingsGroup(
            title: "全员个人空间与配额管理",
            footer: "管理员默认享有无限配额（仅受磁盘实际可用容量限制）；普通成员按所分配的每块物理硬盘独立计算配额。"
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

                    Button("刷新") {
                        spaces.refresh()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
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
            spaces.selectedUserID = entry.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.user.isAdmin ? "crown.fill" : "person.fill")
                    .foregroundStyle(entry.user.isAdmin ? .orange : IsleTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.user.username)
                            .font(.system(size: 13, weight: .semibold))
                        Text(entry.user.isAdmin ? "管理员 · 无限" : "成员")
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(entry.user.isAdmin ? Color.orange.opacity(0.18) : IsleTheme.accent.opacity(0.14))
                            )
                    }
                    Text("已绑定 \(entry.policy.locations.count)/3 类目录 · 已计费 \(formatBytes(entry.policy.accountedBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? IsleTheme.accent.opacity(0.15) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? IsleTheme.accent : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectedUserDetailSection(for entry: NativeSpaceUserEntry) -> some View {
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
                } else if entry.policy.rootQuotas.isEmpty {
                    Text("该成员尚未分配任何存储硬盘，请在下方选择硬盘并分配存储空间。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                } else {
                    ForEach(entry.policy.rootQuotas, id: \.rootID) { rq in
                        memberRootQuotaRow(user: entry.user, rq: rq)
                    }
                }
            }
            .padding(14)
        }
    }

    private func memberRootQuotaRow(user: NativeSpaceUserAccount, rq: NativeStorageRootQuota) -> some View {
        let rootMeta = spaces.rootInfo(for: rq.rootID)
        let rootTitle = rootMeta?.name ?? "旧硬盘 (\(rq.rootID.prefix(8)))"
        let isRemoved = rootMeta == nil
        let key = "\(user.id)-\(rq.rootID)-\(rq.rootGeneration)"
        let savedGiB: Int64 = (rq.quotaBytes ?? 0) > 0 ? max(1, (rq.quotaBytes ?? 0) / QuotaInputValidator.bytesPerGiB) : 0
        let currentGiBString = editingQuotaGiB[key] ?? (savedGiB > 0 ? String(savedGiB) : "0")
        let usedBytes = rq.accountedBytes + rq.reservedBytes
        let validation = QuotaInputValidator.validateGiB(currentGiBString, currentUsedBytes: usedBytes)
        let limitBytes = max(rq.quotaBytes ?? (100 << 30), 1)
        let usedRatio = (rq.quotaBytes ?? 0) > 0 ? min(1.0, Double(usedBytes) / Double(limitBytes)) : 0
        let hasUnsavedChange = editingQuotaGiB[key] != nil && validation.quotaBytes != (rq.quotaBytes ?? 0)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(rootTitle)
                    .font(.system(size: 13, weight: .semibold))
                if let rootMeta {
                    IsleStatusPill(
                        text: rootMeta.online ? "在线" : "离线",
                        tone: rootMeta.online ? .success : .warning,
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
            if (rq.quotaBytes ?? 0) > 0 {
                ProgressView(value: usedRatio)
                    .tint(usedRatio > 0.85 ? .orange : IsleTheme.accent)
            }
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
                TextField(
                    "GiB",
                    text: Binding(
                        get: { currentGiBString },
                        set: { editingQuotaGiB[key] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
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

                if isRemoved {
                    Button("放弃该旧盘记录") {
                        spaces.abandonBinding(userID: user.id, rootID: rq.rootID, generation: rq.rootGeneration, category: nil)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                    .disabled(spaces.busy)
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
            title: "\(entry.user.username) · 个人分类存储位置（文件 / 相册 / 影视）",
            footer: "切换存储硬盘时支持选择「复制并核验后回收源文件」「仅复制（保留两份原件）」或「启用空白新目录」。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["files", "photos", "videos"], id: \.self) { category in
                    categoryLocationRow(for: entry, category: category)
                }
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
                            IsleStatusPill(
                                text: "\(rootMeta.name) · \(rootMeta.online ? "在线" : "离线")",
                                tone: rootMeta.online ? .success : .warning,
                                showDot: true
                            )
                        } else {
                            IsleStatusPill(text: "旧硬盘已移除登记", tone: .warning)
                        }
                        if loc.rootGeneration > 1 {
                            Text("重连批次 #\(loc.rootGeneration)")
                                .font(.caption2)
                                .foregroundStyle(IsleTheme.secondaryText)
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
                    if let rootMeta, rootMeta.online {
                        Button("在访达中打开") {
                            let targetURL = URL(fileURLWithPath: rootMeta.path).appendingPathComponent(loc.relativePath)
                            NSWorkspace.shared.open(targetURL)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
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
                    if spaces.onlineRoots.contains(where: { $0.rootID != loc.rootID }) {
                        Button("更换硬盘…") {
                            switchSourceRootID = loc.rootID
                            switchSourceGeneration = loc.rootGeneration
                            switchCategories = [category]
                            spaces.lastTransferResult = nil
                            showingSwitchRootSheet = true
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(spaces.busy)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func allocateOrAddCard(for entry: NativeSpaceUserEntry) -> some View {
        let selectedRoot = spaces.onlineRoots.first(where: { $0.rootID == allocRootID }) ?? spaces.onlineRoots.first
        let allocValidation = QuotaInputValidator.validateGiB(allocQuotaGiB)
        return AppleSettingsGroup(
            title: "为「\(entry.user.username)」分配存储目录或新建子目录",
            footer: "可在任意已登记的在线硬盘（包括外置移动硬盘）上开通分类目录，或在该用户的分类目录下批量创建子文件夹。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if spaces.onlineRoots.isEmpty {
                    HStack {
                        Text("当前没有在线的 NAS 存储硬盘，请先前往「存储位置」添加或连接硬盘。")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.warningText)
                        Spacer()
                        Button("前往存储位置…") {
                            appModel.selectedSidebarPage = .storage
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    }
                } else {
                    HStack(spacing: 14) {
                        Picker("目标存储硬盘", selection: $allocRootID) {
                            ForEach(spaces.onlineRoots) { r in
                                Text("\(r.name)（\(r.path)）").tag(r.rootID)
                            }
                        }
                        .frame(maxWidth: 420)

                        if entry.policy.isUnlimited {
                            IsleStatusPill(text: "配额：管理员默认无限", tone: .success)
                        } else {
                            HStack(spacing: 6) {
                                Text("该盘配额 (GiB)：").font(.caption)
                                TextField("100", text: $allocQuotaGiB)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                            }
                        }
                        Spacer()
                    }
                    if !entry.policy.isUnlimited, let err = allocValidation.errorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(IsleTheme.warningText)
                    }

                    HStack(spacing: 16) {
                        Text("开通/更新分类：").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        Toggle(SpaceCategoryPresentation.detailLabel(for: "files"), isOn: $allocFiles).toggleStyle(.checkbox)
                        Toggle(SpaceCategoryPresentation.detailLabel(for: "photos"), isOn: $allocPhotos).toggleStyle(.checkbox)
                        Toggle(SpaceCategoryPresentation.detailLabel(for: "videos"), isOn: $allocVideos).toggleStyle(.checkbox)
                    }

                    HStack(spacing: 10) {
                        Text("新建子目录（可选，逗号分隔）：")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        TextField("例如：files/工作文档, photos/2026家庭相册, videos/电影", text: $allocSubdirs)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("保存并创建目录") {
                            guard let root = selectedRoot else { return }
                            if !entry.policy.isUnlimited, !allocValidation.isValid {
                                return
                            }
                            var cats: [String] = []
                            if allocFiles { cats.append("files") }
                            if allocPhotos { cats.append("photos") }
                            if allocVideos { cats.append("videos") }
                            let subdirs = allocSubdirs
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            let quotaBytes: Int64? = entry.policy.isUnlimited ? nil : allocValidation.quotaBytes
                            spaces.allocateSpace(
                                userID: entry.user.id,
                                rootID: root.rootID,
                                generation: root.generation,
                                quotaBytes: quotaBytes,
                                categories: cats,
                                subdirectories: subdirs
                            )
                            allocSubdirs = ""
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                        .disabled(spaces.busy || selectedRoot == nil || (!entry.policy.isUnlimited && !allocValidation.isValid))
                        Spacer()
                    }
                }
            }
            .padding(14)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
