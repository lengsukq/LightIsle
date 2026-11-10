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
            CreateMemberSpaceSheet(spaces: spaces)
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
                subtitle: "每个人的 Users/u<ID>/{files,photos,videos} 与 .lightisle-appdata 缩略图缓存均存放在指定的存储硬盘上，支持外置硬盘。",
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
                : "状态：enforcement=\(entry.policy.enforcement)（仅统计已接入配额账本的写入通道，离线硬盘保留已有账本）。"
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
        let currentGiBString = editingQuotaGiB[key] ?? String(max(1, (rq.quotaBytes ?? (100 << 30)) / (1 << 30)))
        let limitBytes = max(rq.quotaBytes ?? (100 << 30), 1)
        let usedRatio = min(1.0, Double(rq.accountedBytes + rq.reservedBytes) / Double(limitBytes))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(rootTitle)（代次 #\(rq.rootGeneration)）")
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
                Text("已计费 \(formatBytes(rq.accountedBytes)) / 配额 \(formatBytes(rq.quotaBytes ?? 0))")
                    .font(.system(size: 12, weight: .medium))
            }
            ProgressView(value: usedRatio)
                .tint(usedRatio > 0.85 ? .orange : IsleTheme.accent)
            HStack(spacing: 8) {
                Text("调整该盘配额 (GiB)：")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
                ForEach([50, 100, 200, 500, 1024], id: \.self) { preset in
                    Button("\(preset >= 1024 ? "1 TB" : "\(preset) GB")") {
                        editingQuotaGiB[key] = "\(preset)"
                        spaces.setRootQuota(
                            userID: user.id,
                            rootID: rq.rootID,
                            generation: rq.rootGeneration,
                            quotaBytes: Int64(preset) * (1 << 30)
                        )
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
                Button("保存配额") {
                    if let gib = Int64(editingQuotaGiB[key] ?? currentGiBString), gib >= 0 {
                        spaces.setRootQuota(
                            userID: user.id,
                            rootID: rq.rootID,
                            generation: rq.rootGeneration,
                            quotaBytes: gib * (1 << 30)
                        )
                    }
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                .disabled(spaces.busy)

                if isRemoved {
                    Button("放弃该旧盘记录") {
                        spaces.abandonBinding(userID: user.id, rootID: rq.rootID, generation: rq.rootGeneration, category: nil)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                    .disabled(spaces.busy)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func categoryLocationsCard(for entry: NativeSpaceUserEntry) -> some View {
        AppleSettingsGroup(
            title: "\(entry.user.username) · 个人分类存储位置（文件 / 相册 / 影院）",
            footer: "切换存储硬盘时支持选择「仅复制（不删除源盘文件）」或「迁移（先复制并核验 SHA-256，确认无误后再清理源盘目录）」。"
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
        let title = categoryTitle(category)
        let icon = categoryIcon(category)

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
                        Text("代次 #\(loc.rootGeneration)")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
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

                    HStack(spacing: 16) {
                        Text("开通/更新分类：").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        Toggle("个人文件 (files)", isOn: $allocFiles).toggleStyle(.checkbox)
                        Toggle("时光相册 (photos)", isOn: $allocPhotos).toggleStyle(.checkbox)
                        Toggle("私人影院 (videos)", isOn: $allocVideos).toggleStyle(.checkbox)
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
                            var cats: [String] = []
                            if allocFiles { cats.append("files") }
                            if allocPhotos { cats.append("photos") }
                            if allocVideos { cats.append("videos") }
                            let subdirs = allocSubdirs
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            let quotaBytes: Int64? = entry.policy.isUnlimited
                                ? nil
                                : (Int64(allocQuotaGiB).map { $0 * (1 << 30) })
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
                        .disabled(spaces.busy || selectedRoot == nil)
                        Spacer()
                    }
                }
            }
            .padding(14)
        }
    }

    private func categoryTitle(_ category: String) -> String {
        switch category {
        case "files": return "个人文件 (files)"
        case "photos": return "时光相册 (photos)"
        case "videos": return "私人影院 (videos)"
        default: return category
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "files": return "folder.fill"
        case "photos": return "photo.stack.fill"
        case "videos": return "film.stack.fill"
        default: return "folder"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

struct CreateMemberSpaceSheet: View {
    @ObservedObject var spaces: NativeSpacesModel
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var selectedRootID = ""
    @State private var quotaGiB = "100"
    @State private var bindFiles = true
    @State private var bindPhotos = true
    @State private var bindVideos = true
    @State private var subdirectories = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建家庭成员并分配存储空间")
                .font(.system(size: 16, weight: .semibold))
            Text("账号凭据保存在系统盘 accounts.sqlite；成员的文件、照片和视频将存放在所选的存储硬盘上。")
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)

            Form {
                TextField("用户名（3-32 位字母/数字/下划线）", text: $username)
                SecureField("登录密码（至少 12 位）", text: $password)
                if !spaces.onlineRoots.isEmpty {
                    Picker("存放硬盘", selection: $selectedRootID) {
                        ForEach(spaces.onlineRoots) { r in
                            Text("\(r.name)（\(r.path)）").tag(r.rootID)
                        }
                    }
                    TextField("该盘配额上限 (GiB)", text: $quotaGiB)
                    Toggle("开通个人文件 (files)", isOn: $bindFiles)
                    Toggle("开通时光相册 (photos)", isOn: $bindPhotos)
                    Toggle("开通私人影院 (videos)", isOn: $bindVideos)
                    TextField("初始子目录（可选，如 files/文档, photos/旅行）", text: $subdirectories)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary))
                Button("创建成员并分配空间") {
                    let root = spaces.onlineRoots.first(where: { $0.rootID == selectedRootID }) ?? spaces.onlineRoots.first
                    var cats: [String] = []
                    if bindFiles { cats.append("files") }
                    if bindPhotos { cats.append("photos") }
                    if bindVideos { cats.append("videos") }
                    let subdirs = subdirectories
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let quota = Int64(quotaGiB).map { $0 * (1 << 30) }
                    spaces.createUser(
                        username: username.trimmingCharacters(in: .whitespaces),
                        password: password,
                        rootID: root?.rootID,
                        generation: root?.generation,
                        quotaBytes: quota,
                        categories: cats,
                        subdirectories: subdirs
                    )
                    dismiss()
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent))
                .disabled(username.trimmingCharacters(in: .whitespaces).count < 3 || password.count < 12)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            selectedRootID = spaces.onlineRoots.first(where: \.isDefault)?.rootID ?? spaces.onlineRoots.first?.rootID ?? ""
        }
    }
}

struct SwitchUserRootSheet: View {
    @ObservedObject var spaces: NativeSpacesModel
    let entry: NativeSpaceUserEntry
    let sourceRootID: String
    let sourceGeneration: UInt64
    let initialCategories: Set<String>
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategories: Set<String> = []
    @State private var targetRootID = ""
    @State private var mode = "migrate"
    @State private var targetQuotaGiB = ""

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更换「\(entry.user.username)」的存储硬盘")
                .font(.system(size: 16, weight: .semibold))
            Text("核验后删除与直接剪切会将源文件移入可恢复回收站。启用空白目录会保留旧盘原件。收藏、私人相册和观看进度保留在原盘记录中。")
                .font(.caption)
                .foregroundStyle(IsleTheme.secondaryText)

            VStack(alignment: .leading, spacing: 10) {
                Text("1. 选择要切换的分类目录：").font(.system(size: 13, weight: .medium))
                HStack(spacing: 14) {
                    ForEach(sourceCategoriesOnDisk, id: \.category) { loc in
                        Toggle(loc.category, isOn: Binding(
                            get: { selectedCategories.contains(loc.category) },
                            set: { checked in
                                if checked { selectedCategories.insert(loc.category) }
                                else { selectedCategories.remove(loc.category) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }

                Picker("2. 目标在线硬盘：", selection: $targetRootID) {
                    ForEach(availableTargetRoots) { r in
                        Text("\(r.name)（\(r.path)）").tag(r.rootID)
                    }
                }

                if !entry.policy.isUnlimited {
                    HStack(spacing: 8) {
                        Text("目标盘配额上限 (GiB，留空保持默认)：").font(.caption)
                        TextField("100", text: $targetQuotaGiB)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }

                Picker("3. 切换方式：", selection: $mode) {
                    if sourceOnline {
                        Text("复制并核验后删除").tag("migrate")
                        Text("直接剪切并切换").tag("move")
                    }
                    Text("启用空白新目录").tag("empty")
                }
                .pickerStyle(.radioGroup)
            }

            if let message = spaces.message, transfer != nil {
                Text(message).font(.caption).foregroundStyle(IsleTheme.secondaryText)
            }
            if let transfer, transfer.phase == "verified" {
                VStack(alignment: .leading, spacing: 6) {
                    Label("第一步已完成：共复制并 SHA-256 核验 \(transfer.verifiedFiles) 个文件（\(ByteCountFormatter.string(fromByteCount: transfer.copiedBytes, countStyle: .binary))）", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("确认后切换绑定，并将源文件移入旧盘的可恢复回收站。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
            }

            if let err = spaces.errorMessage {
                Text(err).font(.caption).foregroundStyle(IsleTheme.warningText)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary))
                Button("最近换盘任务") {
                    spaces.readStorageSwitch(userID: entry.user.id)
                }
                .disabled(spaces.busy)
                if let transfer, transfer.phase == "verified" {
                    Button("取消任务") {
                        spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "cancel")
                    }
                    .disabled(spaces.busy)
                    Button("确认切换并回收源文件") {
                        spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "confirm_cleanup")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .destructive))
                    .disabled(spaces.busy)
                } else if let transfer, transfer.phase == "source_pending" {
                    Button("重新核验并回收源文件") {
                        spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "recover_source")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .destructive))
                    .disabled(spaces.busy)
                } else {
                    if let transfer, transfer.phase == "copying" || transfer.phase == "queued" {
                        Button("取消任务") {
                            spaces.readStorageSwitch(userID: entry.user.id, taskID: transfer.taskID, phase: "cancel")
                        }
                        .disabled(spaces.busy)
                    }
                    Button(mode == "migrate" ? "开始复制并核验" : "确认切换") {
                        triggerSwitch(phase: "copy_and_verify")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent))
                    .disabled(spaces.busy || transfer?.isRunning == true || selectedCategories.isEmpty || targetRootID.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            selectedCategories = initialCategories.isEmpty
                ? Set(sourceCategoriesOnDisk.map(\.category))
                : initialCategories
            targetRootID = availableTargetRoots.first?.rootID ?? ""
            if !sourceOnline { mode = "empty" }
        }
        .onChange(of: spaces.lastTransferResult) { _, newValue in
            if let res = newValue, res.phase == "completed" {
                dismiss()
            }
        }
    }

    private func triggerSwitch(phase: String) {
        guard let targetRoot = availableTargetRoots.first(where: { $0.rootID == targetRootID }) else { return }
        var quota: Int64?
        if !entry.policy.isUnlimited, !targetQuotaGiB.isEmpty {
            guard let value = Int64(targetQuotaGiB), (0...1_048_576).contains(value) else {
                spaces.errorMessage = "请输入 0–1048576 GiB 的有效配额。"
                return
            }
            quota = value << 30
        }
        spaces.switchRoot(
            userID: entry.user.id,
            categories: Array(selectedCategories).sorted(),
            sourceRootID: sourceRootID,
            sourceGeneration: sourceGeneration,
            targetRootID: targetRoot.rootID,
            targetGeneration: targetRoot.generation,
            targetQuotaBytes: quota,
            mode: mode,
            phase: phase
        )
    }
}
