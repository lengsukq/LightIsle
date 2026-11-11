import AppKit
import SwiftUI
import UserNotifications

struct StoragePermissionAuditItem: Identifiable {
    enum Kind: String {
        case defaultRoot = "默认主目录"
        case registeredRoot = "已登记存储目录"
        case externalVolume = "外置挂载宗卷"
    }

    let id: String
    let name: String
    let path: String
    let mountRoot: String?
    let kind: Kind
    let isDefault: Bool
    let online: Bool
    let appProbe: StoragePermissionHelper.AccessProbeResult?
    let daemonVerified: Bool?
    let daemonMessage: String?

    var isHealthy: Bool {
        guard online else { return false }
        guard let appProbe, appProbe.isWritable else { return false }
        if let daemonVerified, !daemonVerified { return false }
        return true
    }

    var statusLabel: String {
        if !online { return "磁盘离线" }
        guard let appProbe else { return "等待检测" }
        if !appProbe.isWritable { return appProbe.statusSummary }
        if daemonVerified == false { return "后台服务无写权限" }
        if mountRoot != nil { return "整盘与目录可读写" }
        return "读写权限正常"
    }

    var statusTone: IsleStatusTone {
        if !online { return .warning }
        guard let appProbe else { return .neutral }
        if !appProbe.isWritable || daemonVerified == false { return .error }
        return .success
    }

    var errorExplanation: String? {
        if !online {
            return "该目录所在磁盘当前未挂载或已断开连接，请检查硬盘连接线或供电后重新插入。"
        }
        if let appProbe, !appProbe.isWritable {
            return appProbe.detailMessage
        }
        if daemonVerified == false {
            return daemonMessage ?? "macOS 界面已可访问，但后台核心服务 lightisled 无法写入该目录或外置整盘。请点击「获取/修复读写权限」同步授权。"
        }
        return nil
    }
}

struct PermissionsReadinessView: View {
    @ObservedObject var model: AppModel
    @State private var auditItems: [StoragePermissionAuditItem] = []
    @State private var isAuditing = false
    @State private var repairingItemID: String?
    @State private var actionFeedback: String?
    @State private var actionFeedbackIsError = false
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

    private var abnormalStorageItems: [StoragePermissionAuditItem] {
        auditItems.filter { !$0.isHealthy }
    }

    private var hasDefaultStorageReady: Bool {
        guard let defaultRoot = auditItems.first(where: { $0.isDefault || $0.kind == .defaultRoot }) else {
            return false
        }
        return defaultRoot.isHealthy
    }

    private var totalIssueCount: Int {
        var issues = abnormalStorageItems.count
        if !hasDefaultStorageReady && abnormalStorageItems.isEmpty {
            issues += 1
        }
        if model.isConfigured != true {
            issues += 1
        }
        if model.state != .online {
            issues += 1
        }
        if model.nativeAlertsEnabled && notificationAuthStatus == .denied {
            issues += 1
        }
        return issues
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            summaryBannerCard
            storagePermissionsGroup
            essentialSetupGroup
            systemProtectionGroup
        }
        .task {
            await runFullAudit()
        }
        .onChange(of: model.rootManagement.roots) { _, _ in
            Task { await runFullAudit() }
        }
        .onChange(of: model.sharedFolderPath) { _, _ in
            Task { await runFullAudit() }
        }
    }

    // MARK: - Top Summary Banner

    private var summaryBannerCard: some View {
        let allReady = totalIssueCount == 0
        let tint: Color = allReady ? IsleTheme.successText : IsleTheme.warningText
        return LiquidCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    IsleHeaderIconBadge(
                        icon: allReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                        tint: tint,
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(allReady
                                 ? "全部核心权限与必备初始化项已就绪"
                                 : "检测到 \(totalIssueCount) 项权限或初始化异常，请立即处理")
                                .font(.system(size: 16, weight: .semibold))
                            IsleStatusPill(
                                text: allReady ? "运行就绪" : "需要修复",
                                tone: allReady ? .success : .warning,
                                showDot: true
                            )
                        }
                        Text("轻屿在添加目录和启动时会同时校验 macOS 应用与后台服务（lightisled）对目标目录及外置硬盘整盘的真实读写权限。任何无权限或未初始化状态都会在此明确报错，避免后续跨盘迁移或远程上传失败。")
                            .font(.system(size: 12))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Button {
                            StoragePermissionHelper.openSystemPrivacySettings()
                        } label: {
                            Label("系统隐私设置", systemImage: "gearshape.2")
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))

                        Button {
                            Task { await runFullAudit(verifyDaemon: true) }
                        } label: {
                            HStack(spacing: 6) {
                                if isAuditing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(isAuditing ? "正在体检…" : "重新全面体检")
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(isAuditing)
                    }
                }

                if let feedback = actionFeedback {
                    HStack(spacing: 8) {
                        Image(systemName: actionFeedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(actionFeedbackIsError ? IsleTheme.errorText : IsleTheme.successText)
                        Text(feedback)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(actionFeedbackIsError ? IsleTheme.errorText : IsleTheme.successText)
                            .textSelection(.enabled)
                        Spacer()
                        Button("收起") { actionFeedback = nil }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                    }
                    .padding(10)
                    .background(
                        (actionFeedbackIsError ? IsleTheme.errorText : IsleTheme.successText).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }
        }
    }

    // MARK: - Group 1: Storage & Whole-Disk Permissions

    private var storagePermissionsGroup: some View {
        AppleSettingsGroup(
            title: "1. 存储目录与外置整盘读写权限",
            footer: "添加外置硬盘目录时，必须同时具备该外置宗卷根目录（/Volumes/盘名）与目标目录树的读写权限；若权限不足，将无法添加目录或执行跨目录数据迁移。"
        ) {
            if auditItems.isEmpty {
                AppleSettingsRow(
                    title: "暂无已登记的存储目录",
                    subtitle: "请先在下方设置默认主存储目录。",
                    icon: "externaldrive.badge.questionmark",
                    iconTint: .orange
                ) {
                    Button("选择默认存储目录…") {
                        model.selectSharedFolder()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                }
            } else {
                ForEach(Array(auditItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        IsleGroupSpacing(height: 2).padding(.leading, 14)
                    }
                    storagePermissionRow(item)
                }
            }
        }
    }

    private func storagePermissionRow(_ item: StoragePermissionAuditItem) -> some View {
        let isRepairing = repairingItemID == item.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.mountRoot != nil ? "externaldrive.fill.badge.checkmark" : "folder.fill.badge.gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.isHealthy ? IsleTheme.successText : IsleTheme.errorText)
                    .frame(width: 28, height: 28)
                    .background(
                        (item.isHealthy ? IsleTheme.successText : IsleTheme.errorText).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                        IsleStatusPill(
                            text: item.isDefault ? "默认主目录" : item.kind.rawValue,
                            tone: item.isDefault ? .accent : .neutral
                        )
                        IsleStatusPill(
                            text: item.statusLabel,
                            tone: item.statusTone,
                            showDot: true
                        )
                    }

                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)

                    if let mountRoot = item.mountRoot {
                        Text("所属外置整盘挂载点：\(mountRoot)（已纳入整盘读写探测）")
                            .font(.system(size: 11))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }

                    if let explanation = item.errorExplanation {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .font(.system(size: 11))
                                .padding(.top, 2)
                            Text(explanation)
                                .font(.system(size: 11, weight: .medium))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(IsleTheme.errorText)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            IsleTheme.errorText.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                }

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    if item.online {
                        Button {
                            Task { await authorizeOrRepair(item) }
                        } label: {
                            HStack(spacing: 4) {
                                if isRepairing {
                                    ProgressView().controlSize(.small)
                                }
                                Text(item.isHealthy ? "重新校验读写" : "一键获取/修复读写权限")
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(
                            variant: item.isHealthy ? .secondary : .prominent,
                            size: .small
                        ))
                        .disabled(isRepairing || isAuditing)
                    }

                    if !item.isHealthy && item.online {
                        Button("复制修复命令") {
                            let cmd = StoragePermissionHelper.manualRepairCommand(forPath: item.path)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                            actionFeedbackIsError = false
                            actionFeedback = "已复制「\(item.name)」的终端赋权命令，可在系统终端粘贴执行。"
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }

                    if item.online {
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .help("在访达中打开此目录")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IsleFluidPalette.rim.opacity(0.38))
                .frame(height: 0.75)
                .padding(.leading, 55)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Group 2: Essential Initialization Checks

    private var essentialSetupGroup: some View {
        AppleSettingsGroup(
            title: "2. 必备初始化设置与核心状态",
            footer: "确保默认主存储目录已指定且可读写、管理员账号已创建、本机核心服务正常运行。"
        ) {
            AppleSettingsRow(
                title: "默认主存储目录（新用户默认空间）",
                subtitle: model.sharedFolderPath ?? "尚未设置默认主存储目录",
                icon: "externaldrive.badge.checkmark",
                iconTint: hasDefaultStorageReady ? .green : .orange
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(
                        text: hasDefaultStorageReady ? "已就绪且可读写" : "需检查权限或重新指定",
                        tone: hasDefaultStorageReady ? .success : .warning,
                        showDot: true
                    )
                    Button("切换默认目录…") {
                        model.selectSharedFolder()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.state != .online || model.rootManagement.busy)

                    Button("管理全部目录") {
                        model.navigateToStorageDetail(.locations)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }

            IsleGroupSpacing(height: 4).padding(.leading, 14)

            AppleSettingsRow(
                title: "首任管理员账号",
                subtitle: model.isConfigured == true
                    ? "当前管理员账号：\(model.firstAdminUsername ?? "已创建")（用于目录迁移及高危操作二次确认）"
                    : "尚未完成首次管理员创建，请先完成初始化设置。",
                icon: "person.badge.key.fill",
                iconTint: model.isConfigured == true ? .teal : .orange
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(
                        text: model.isConfigured == true ? "已初始化" : "未初始化",
                        tone: model.isConfigured == true ? .success : .warning,
                        showDot: true
                    )
                    if model.isConfigured == true {
                        Button("账号与安全") {
                            model.navigateToSettingsDetail(.security)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
            }

            IsleGroupSpacing(height: 4).padding(.leading, 14)

            AppleSettingsRow(
                title: "本机核心服务（lightisled）与监听端口",
                subtitle: model.state == .online
                    ? "正在运行 · 本机端口 :\(model.preferredLocalPort)"
                    : "服务状态异常：\(model.details)",
                icon: "server.rack",
                iconTint: model.state == .online ? .blue : .red
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(
                        text: model.state.label,
                        tone: model.state == .online ? .success : .error,
                        showDot: true
                    )
                    if model.state != .online {
                        Button("重新启动服务") {
                            model.launch()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    }
                }
            }
        }
    }

    // MARK: - Group 3: System Notification & Anti-Sleep Protection

    private var systemProtectionGroup: some View {
        AppleSettingsGroup(
            title: "3. 系统通知权限与防中断保护",
            footer: "开启系统通知可在硬盘意外离线、权限丢失或空间不足时立即收到提醒；开启防止空闲睡眠可避免大目录迁移或远程上传被休眠中断。"
        ) {
            AppleSettingsRow(
                title: "macOS 系统故障通知权限",
                subtitle: notificationPermissionSubtitle,
                icon: "bell.badge.fill",
                iconTint: notificationAuthStatus == .denied ? .red : .orange
            ) {
                HStack(spacing: 8) {
                    IsleStatusPill(
                        text: notificationStatusLabel,
                        tone: notificationStatusTone
                    )
                    Toggle("启用故障通知", isOn: Binding(
                        get: { model.nativeAlertsEnabled },
                        set: { newValue in
                            model.setNativeAlertsEnabled(newValue)
                            Task {
                                try? await Task.sleep(for: .milliseconds(400))
                                await refreshNotificationPermission()
                            }
                        }
                    ))
                    .toggleStyle(.switch)

                    if notificationAuthStatus == .denied {
                        Button("系统通知设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
            }

            if let alertError = model.nativeAlertError {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "通知权限异常说明", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                    Text(alertError)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.errorText)
                }
            }

            IsleGroupSpacing(height: 4).padding(.leading, 14)

            AppleSettingsRow(
                title: "提供服务时防止 Mac 空闲睡眠",
                subtitle: "建议开启，防止跨盘迁移数据或家庭成员远程传输时因系统自动休眠而中断。",
                icon: "moon.zzz.fill",
                iconTint: .indigo
            ) {
                Toggle("", isOn: Binding(
                    get: { model.keepAwakeWhileServing },
                    set: { model.setKeepAwakeWhileServing($0) }
                ))
                .toggleStyle(.switch)
            }

            IsleGroupSpacing(height: 4).padding(.leading, 14)

            AppleSettingsRow(
                title: "登录 Mac 时自动启动轻屿",
                subtitle: model.loginItemError ?? "进入桌面后自动拉起轻屿核心服务与已登记存储目录。",
                icon: "person.crop.circle.badge.checkmark",
                iconTint: .blue
            ) {
                Toggle("", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
            }
        }
    }

    private var notificationStatusLabel: String {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral:
            return model.nativeAlertsEnabled ? "已授权并开启" : "系统已授权（开关未开）"
        case .denied:
            return "系统已拒绝通知权限"
        case .notDetermined:
            return "尚未请求系统授权"
        @unknown default:
            return "未知状态"
        }
    }

    private var notificationStatusTone: IsleStatusTone {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral:
            return model.nativeAlertsEnabled ? .success : .neutral
        case .denied:
            return .error
        case .notDetermined:
            return .neutral
        @unknown default:
            return .neutral
        }
    }

    private var notificationPermissionSubtitle: String {
        if notificationAuthStatus == .denied {
            return "当前 macOS 系统设置已禁止轻屿发送通知，请点击右侧「系统通知设置」手动允许。"
        }
        return "当外置存储离线、读写权限失效或核心服务异常时，通过 macOS 通知中心立即报错提醒。"
    }

    // MARK: - Actions & Probing

    private func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthStatus = settings.authorizationStatus
    }

    private func runFullAudit(verifyDaemon: Bool = false) async {
        guard !isAuditing else { return }
        isAuditing = true
        defer { isAuditing = false }

        await refreshNotificationPermission()

        var items: [StoragePermissionAuditItem] = []
        var seenPaths: Set<String> = []

        // 1. Registered roots
        let roots = model.rootManagement.roots
        for root in roots {
            let cleanPath = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
            seenPaths.insert(cleanPath)
            let mountRoot = StoragePermissionHelper.externalVolumeMountPath(forPath: cleanPath)
            var probe: StoragePermissionHelper.AccessProbeResult?
            var daemonOK: Bool?
            var daemonMsg: String?

            if root.online {
                probe = StoragePermissionHelper.probeDirectoryReadWrite(
                    at: URL(fileURLWithPath: cleanPath, isDirectory: true)
                )
                if verifyDaemon, probe?.isWritable == true {
                    let result = await model.externalVolumeCoordinator.verifyDaemonAccessWhenIdle(path: cleanPath)
                    daemonOK = result.ok
                    daemonMsg = result.message
                }
            }

            items.append(StoragePermissionAuditItem(
                id: "root-\(root.rootID)",
                name: root.name,
                path: cleanPath,
                mountRoot: mountRoot,
                kind: root.isDefault == true ? .defaultRoot : .registeredRoot,
                isDefault: root.isDefault == true,
                online: root.online,
                appProbe: probe,
                daemonVerified: daemonOK,
                daemonMessage: daemonMsg
            ))
        }

        // 2. Fallback default sharedFolderPath if not in registered roots
        if let sharedPath = model.sharedFolderPath, !sharedPath.isEmpty {
            let cleanPath = URL(fileURLWithPath: sharedPath, isDirectory: true).standardizedFileURL.path
            if !seenPaths.contains(cleanPath) {
                seenPaths.insert(cleanPath)
                let exists = FileManager.default.fileExists(atPath: cleanPath)
                let mountRoot = StoragePermissionHelper.externalVolumeMountPath(forPath: cleanPath)
                let probe = exists
                    ? StoragePermissionHelper.probeDirectoryReadWrite(at: URL(fileURLWithPath: cleanPath, isDirectory: true))
                    : nil
                items.insert(StoragePermissionAuditItem(
                    id: "default-shared",
                    name: model.sharedFolderName.isEmpty ? "默认共享目录" : model.sharedFolderName,
                    path: cleanPath,
                    mountRoot: mountRoot,
                    kind: .defaultRoot,
                    isDefault: true,
                    online: exists,
                    appProbe: probe,
                    daemonVerified: nil,
                    daemonMessage: nil
                ), at: 0)
            }
        }

        // 3. Mounted external disks not yet added as a root (so user can pre-check whole-disk permission)
        for disk in model.managedDisks where disk.mounted && disk.external && disk.mount.hasPrefix("/Volumes/") {
            let cleanMount = URL(fileURLWithPath: disk.mount, isDirectory: true).standardizedFileURL.path
            let alreadyCovered = seenPaths.contains { $0 == cleanMount || $0.hasPrefix(cleanMount + "/") }
            guard !alreadyCovered else { continue }
            seenPaths.insert(cleanMount)
            let probe = StoragePermissionHelper.probeDirectoryReadWrite(
                at: URL(fileURLWithPath: cleanMount, isDirectory: true)
            )
            items.append(StoragePermissionAuditItem(
                id: "ext-\(disk.id)",
                name: disk.name.isEmpty ? URL(fileURLWithPath: cleanMount).lastPathComponent : disk.name,
                path: cleanMount,
                mountRoot: cleanMount,
                kind: .externalVolume,
                isDefault: false,
                online: true,
                appProbe: probe,
                daemonVerified: nil,
                daemonMessage: nil
            ))
        }

        auditItems = items
    }

    private func authorizeOrRepair(_ item: StoragePermissionAuditItem) async {
        repairingItemID = item.id
        defer { repairingItemID = nil }

        let targetURL = URL(fileURLWithPath: item.path, isDirectory: true)
        let initialProbe = StoragePermissionHelper.probeDirectoryReadWrite(at: targetURL)
        let access = await StoragePermissionHelper.requestReadWriteAccess(
            forPath: item.path,
            reason: "需要获取并验证「\(item.name)」及其所属整盘的读写权限，以确保目录添加、用户空间分配和跨目录数据迁移不会因权限不足而失败。",
            initialProbe: initialProbe
        )
        guard access.ok else {
            actionFeedbackIsError = true
            actionFeedback = access.errorMessage ?? "未能获取「\(item.name)」的整盘与目录读写权限。"
            await runFullAudit()
            return
        }

        if item.kind != .externalVolume {
            let daemonResult = await model.externalVolumeCoordinator.verifyDaemonAccessWhenIdle(path: item.path)
            if !daemonResult.ok {
                actionFeedbackIsError = true
                actionFeedback = daemonResult.message ?? "后台服务（lightisled）仍无法写入「\(item.name)」，请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中勾选 LightIsle。"
                await runFullAudit(verifyDaemon: true)
                return
            }
        }

        actionFeedbackIsError = false
        actionFeedback = "「\(item.name)」的整盘与目录读写权限已验证通过。"
        await runFullAudit(verifyDaemon: true)
    }
}
