import SwiftUI
import AppKit

extension ContentView {
    var settingsView: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let detail = settingsDetail {
                if detail == .tools {
                    if settingsTool == .diagnostics {
                        diagnosticsView
                    } else {
                        mcpToolsSettingsGroup
                            .environment(\.currentPreferencesSection, .tools)
                            .disabled(model.isPresentationPreview)
                    }
                } else {
                    settingsGroups
                        .environment(\.currentPreferencesSection, detail)
                        .disabled(model.isPresentationPreview)
                }
            } else {
                IsleDestinationGrid {
                    ForEach(Array(PreferencesSection.allCases.enumerated()), id: \.element.id) { index, detail in
                        let badgeInfo = settingsBadge(for: detail)
                        IsleDestinationRow(
                            title: detail.title,
                            subtitle: detail.subtitle,
                            icon: detail.icon,
                            badge: badgeInfo.text,
                            badgeTone: badgeInfo.tone,
                            iconTint: settingsIconTint(for: detail)
                        ) {
                            requestLocalNavigation { settingsDetail = detail; preferencesSection = detail }
                        }.modifier(IsleCascade(index: index))
                    }
                }
                .task(id: model.sharedFolderPath ?? "") {
                    guard !model.isPresentationPreview else {
                        settingsPermissionWritableCache = true
                        return
                    }
                    let currentPath = model.sharedFolderPath ?? ""
                    guard !currentPath.isEmpty else {
                        settingsPermissionWritableCache = true
                        return
                    }
                    let writable = await Task.detached(priority: .utility) {
                        StoragePermissionHelper.probeDirectoryReadWrite(at: URL(fileURLWithPath: currentPath, isDirectory: true)).isWritable
                    }.value
                    settingsPermissionWritableCache = writable
                }
            }
        }
    }

    private func settingsBadge(for detail: PreferencesSection) -> (text: String, tone: IsleStatusTone) {
        switch detail {
        case .permissions:
            let hasOfflineOrError = model.sharedFolderError != nil || model.rootManagement.roots.contains(where: { !$0.online })
            if hasOfflineOrError {
                return ("需检查权限", .warning)
            }
            if !settingsPermissionWritableCache {
                return ("无读写权限", .error)
            }
            return ("权限就绪", .success)
        case .general:
            return (":\(model.preferredLocalPort)", .accent)
        case .media:
            let count = (model.tmdbTokenConfigured ? 1 : 0) + (model.mapKeyConfigured ? 1 : 0)
            return count > 0 ? ("\(count)/2 已配置", .success) : ("按需配置", .neutral)
        case .notifications:
            if model.notifyConfigured || model.nativeAlertsEnabled {
                return ("已开启", .success)
            }
            return ("未开启", .neutral)
        case .security:
            return (model.firstAdminUsername ?? "本机保护", .accent)
        case .tools:
            return ("4 项工具", .neutral)
        }
    }

    private func settingsIconTint(for detail: PreferencesSection) -> Color {
        switch detail {
        case .permissions: return .green
        case .general: return .blue
        case .media: return .purple
        case .notifications: return .orange
        case .security: return .teal
        case .tools: return .indigo
        }
    }
    @ViewBuilder var settingsGroups: some View {
        if settingsDetail == .permissions { PermissionsReadinessView(model: model) }
        if settingsDetail == .general { settingsGroup0 }
        if settingsDetail == .general { settingsGroup1 }
        if settingsDetail == .notifications { settingsGroup2 }
        if settingsDetail == .media { settingsGroup3 }
        if settingsDetail == .media { settingsGroup4 }
        if settingsDetail == .notifications { settingsGroup5 }
        if settingsDetail == .security { settingsGroup6 }
        if settingsDetail == .general { settingsGroup7 }
        if settingsDetail == .media { settingsGroup8 }
        if settingsDetail == .security { settingsGroup9 }
        if settingsDetail == .general { settingsGroup10 }
    }
    var settingsGroup0: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .general, title: "NAS 常驻与系统登录", footer: "关闭最后一个窗口只收起管理界面，Go Core 继续运行；只有 ⌘Q 或菜单栏退出才停止 NAS。登录项需 macOS 已登录，空闲防睡眠不阻止主动睡眠、断电或 FileVault 解锁。") {
                AppleSettingsRow(title: "登录 Mac 时自动打开轻屿", icon: "person.crop.circle.badge.checkmark", iconTint: .blue) {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "提供服务时防止空闲睡眠", icon: "moon.zzz", iconTint: .orange) {
                    Toggle("", isOn: Binding(
                        get: { model.keepAwakeWhileServing },
                        set: { model.setKeepAwakeWhileServing($0) }
                    ))
                    .toggleStyle(.switch)
                }
                if let error = model.loginItemError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "登录项提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
            }

        }
    }
    var settingsGroup1: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .general, title: "轻量模式", footer: "轻量模式会关闭管理窗口、释放页面与图表缓存，并减少状态查询；NAS、远程访问及后台任务继续运行。点击菜单栏的轻屿图标可恢复正常模式。锁屏自动切换仅在轻屿已运行时生效，解锁后不会自行弹出窗口。") {
                AppleSettingsRow(title: "锁屏时自动进入轻量模式", subtitle: "默认开启；关闭后仍可从菜单栏手动切换。", icon: "lock.display", iconTint: .indigo) {
                    Toggle("", isOn: Binding(
                        get: { model.autoLightweightOnLock },
                        set: { model.setAutoLightweightOnLock($0) }
                    ))
                    .toggleStyle(.switch)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "当前模式", icon: "leaf", iconTint: .green) {
                    HStack(spacing: 10) {
                        Text(model.isLightweightMode ? "轻量模式" : "正常模式")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        Button("立即进入轻量模式") { model.enterLightweightMode() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.isLightweightMode)
                    }
                }
            }

        }
    }
    var settingsGroup2: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .notifications, title: "macOS 故障通知", footer: "默认关闭，开启后需经系统授权。仅发送 NAS 核心异常、备份操作失败、共享目录离线等事件；同类事件会限频，不上传任何文件信息。") {
                AppleSettingsRow(title: "重要事件系统通知", icon: "bell.badge", iconTint: .orange) {
                    Toggle("", isOn: Binding(
                        get: { model.nativeAlertsEnabled },
                        set: { model.setNativeAlertsEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                }
                if let error = model.nativeAlertError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "通知权限提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
            }

        }
    }
    var settingsGroup3: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .media, title: "TMDB 自动刮削", footer: "配置后服务器会自动为影片与剧集补全标题、海报与简介。Token 只保存在本机钥匙串并经私有通道下发给 Core（仅内存），不会写入服务器磁盘或出现在 Web/移动端。可在 [themoviedb.org](https://www.themoviedb.org/settings/api) 免费申请 Read Access Token (v4)。") {
                AppleSettingsRow(title: "配置状态", icon: "film.stack", iconTint: .purple) {
                    HStack(spacing: 10) {
                        if model.tmdbTokenBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.tmdbTokenConfigured ? "已配置（Core 已接收）" : (model.hasSavedTmdbToken ? "已保存在钥匙串，等待 Core 确认" : "未配置"))
                            .font(.caption).foregroundStyle(model.tmdbTokenConfigured ? .green : .secondary)
                        Button {
                            if let url = URL(string: "https://www.themoviedb.org/settings/api") { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 4) { Text("申请 Token"); Image(systemName: "arrow.up.forward.app").font(.system(size: 10)) }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .help("在浏览器中打开 themoviedb.org 申请 Read Access Token (v4)")
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "TMDB Read Access Token", subtitle: "输入后点击保存；不会在界面上回显已保存的 Token。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        SecureField("粘贴 Token…", text: $tmdbTokenDraft).liquidInput().font(.system(size: 12, design: .monospaced))
                        Button("取消") { tmdbTokenDraft = "" }.buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("保存") { saveMediaDraft(.tmdb) }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(tmdbTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.tmdbTokenConfigured || model.hasSavedTmdbToken {
                            Button("清除") { model.clearTmdbToken() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                    .frame(width: settingsControlWidth)
                }
                if let error = model.tmdbTokenError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "保存失败", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
                if model.state != .online {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "Core 未连接", icon: "wifi.slash", iconTint: .orange) {
                        Text("Token 已保存在本机钥匙串，Core 就绪后会自动下发。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }
            .task { model.refreshTmdbStatus() }
            .onChange(of: model.state) { _, newState in
                if newState == .online { model.refreshTmdbStatus() }
            }

        }
    }
    var settingsGroup4: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .media, title: "天地图 · 照片地图底图", footer: "管理员统一配置后，手机和 Web 无需填写 Key。Key 只保存在本机钥匙串，并经私有通道交给 Core 代理地图瓦片请求；客户端不会获得 Key。请先从[天地图开发者控制台](https://console.tianditu.gov.cn/api/key)申请 Key，使用需遵守其服务条款。") {
                AppleSettingsRow(title: "服务状态", icon: "map", iconTint: .blue) {
                    HStack(spacing: 10) {
                        if model.mapKeyBusy { ProgressView().controlSize(.small) }
                        Text(model.mapKeyConfigured ? "已配置（Core 已接收）" : (model.hasSavedMapKey ? "钥匙串已保存，等待 Core 恢复" : "尚未配置"))
                            .font(.caption).foregroundStyle(model.mapKeyConfigured ? .green : .secondary)
                        Button {
                            if let url = URL(string: "https://console.tianditu.gov.cn/api/key") { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 4) { Text("申请 Key"); Image(systemName: "arrow.up.forward.app").font(.system(size: 10)) }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .help("在浏览器中打开天地图开发者控制台申请 Key")
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "天地图 API Key", subtitle: "Key 不会回显，也不会传给移动端。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        SecureField("粘贴天地图 Key…", text: $tiandituKeyDraft).liquidInput().font(.system(size: 12, design: .monospaced))
                        Button("取消") { tiandituKeyDraft = "" }.buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("保存") { saveMediaDraft(.map) }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(tiandituKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.mapKeyConfigured || model.hasSavedMapKey {
                            Button("清除") { model.clearMapKey() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                    .frame(width: settingsControlWidth)
                }
                if let error = model.mapKeyError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "地图配置错误", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
                if model.state != .online {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "Core 未连接", icon: "wifi.slash", iconTint: .orange) {
                        Text("Key 可以先保存，待 Core 启动后自动启用地图底图服务。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }
            .task { model.refreshMapKeyStatus() }
            .onChange(of: model.state) { _, newState in
                if newState == .online { model.refreshMapKeyStatus() }
            }

        }
    }
    var mcpToolsSettingsGroup: some View {
        let mcpSnap = model.appsCenter.mcp
        let statusText: String = {
            if !mcpSnap.mcpEnabled { return "未开启" }
            return mcpSnap.mcpLanEnabled ? "已开启 · 本机与局域网/Cloud" : "已开启 · 仅本机免令牌直连"
        }()
        return VStack(alignment: .leading, spacing: 18) {
            AppleSettingsGroup(
                preferenceSection: .tools,
                title: "系统诊断与扩展工具",
                footer: "AI Agent (MCP) 接入与本机定时脚本统一收口于「Docker 与应用」工作台，此处提供直达入口与本机目录。"
            ) {
                AppleSettingsRow(
                    title: "高级诊断（资源与进程）",
                    subtitle: "查看 CPU / 内存采样曲线、并发指标与 Go Core 进程状态",
                    icon: "waveform.path.ecg",
                    iconTint: .purple
                ) {
                    Button("打开高级诊断") { settingsTool = .diagnostics }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "外部依赖（Homebrew 组件）",
                    subtitle: "查看 Smartmontools、FFmpeg 等系统级组件安装状态",
                    icon: "shippingbox",
                    iconTint: .orange
                ) {
                    Button("查看外部依赖") { requestNavigation(.dependencies) }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "AI Agent (MCP) 服务",
                    subtitle: "当前状态：\(statusText)（含接入向导、令牌与调试台）",
                    icon: "cpu.fill",
                    iconTint: mcpSnap.mcpEnabled ? .purple : .secondary
                ) {
                    Button("打开 MCP 面板") {
                        model.navigateToAppsSection(.mcp)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.isPresentationPreview)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "本机定时脚本与扩展目录",
                    subtitle: "管理 automation/scripts 定时任务或打开本机脚本与轻应用目录",
                    icon: "folder.badge.gearshape",
                    iconTint: .blue
                ) {
                    HStack(spacing: 8) {
                        Button("管理定时脚本") {
                            model.navigateToAppsSection(.automation)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.isPresentationPreview)
                        IsleIconButton(
                            icon: "folder",
                            help: "在访达中打开本机自动化脚本目录（automation/scripts）"
                        ) {
                            model.openAutomationScripts()
                        }
                        .disabled(model.isPresentationPreview)
                        IsleIconButton(
                            icon: "puzzlepiece.extension",
                            help: "在访达中打开本机轻应用与插件目录"
                        ) {
                            model.appsCenter.openPluginDirectory()
                        }
                        .disabled(model.isPresentationPreview)
                    }
                }
                if let msg = model.appsCenter.errorMessage ?? model.appsCenter.message {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    let hasError = model.appsCenter.errorMessage != nil
                    AppleSettingsRow(title: "扩展状态", icon: hasError ? "exclamationmark.triangle" : "checkmark.circle", iconTint: hasError ? .orange : .green) {
                        Text(msg).font(.caption).foregroundStyle(hasError ? IsleTheme.warningText : IsleTheme.secondaryText)
                    }
                }
            }
        }
        .onAppear {
            if model.appsCenter.connected { model.appsCenter.refresh() }
        }
    }

    var settingsGroup6: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .security, title: "电脑文件只读访问", footer: "开启后管理员可在轻屿中浏览和下载 Mac 当前允许读取的文件，也可授权其他成员。整机授权可能包含私人文件；系统隐私权限仍然生效。关闭后成员授权会保留但暂停。") {
                AppleSettingsRow(title: "允许访问电脑文件", subtitle: "此开关只能在 Mac 上更改", icon: "desktopcomputer", iconTint: .blue) {
                    Toggle("", isOn: Binding(
                        get: { model.computerFilesEnabled == true },
                        set: { value in
                            guard model.state == .online, let commands = model.coreCommands else { return }
                            do {
                                try commands.write(contentsOf: Data("computer-files \(value ? "on" : "off")\n".utf8))
                            } catch {
                                model.computerFilesError = "无法连接轻屿服务，请重试。"
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.state != .online || model.computerFilesEnabled == nil)
                }
                AppleSettingsRow(title: "成员访问范围", subtitle: "在网页中选择成员及可访问的文件夹", icon: "person.2", iconTint: .teal) {
                    Button("管理成员权限") { model.openUserWeb(page: "computer") }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online || model.computerFilesEnabled != true)
                }
                AppleSettingsRow(title: "macOS 隐私权限", subtitle: "部分位置需要在系统设置中授权轻屿及其核心进程", icon: "hand.raised", iconTint: .orange) {
                    Button("打开系统隐私设置") { StoragePermissionHelper.openSystemPrivacySettings() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                if let error = model.computerFilesError {
                    AppleSettingsRow(title: "设置未保存", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
            }
            AppleSettingsGroup(preferenceSection: .security,
                title: "管理员身份与安全",
                footer: "首任管理员密码仅保存在本地 Mac，重置后旧登录会话立即失效。"
            ) {
                if let username = model.firstAdminUsername {
                    AppleSettingsRow(title: "当前管理员账号", icon: "person.badge.key.fill", iconTint: .blue) {
                        HStack(spacing: 8) {
                            Text(username)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            IsleIconButton(
                                icon: "doc.on.doc",
                                variant: .borderless,
                                help: "复制管理员用户名"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(username, forType: .string)
                                showNotice("已复制管理员用户名")
                            }
                        }
                    }
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                }

                AppleSettingsRow(title: "新密码", icon: "key.horizontal.fill", iconTint: .indigo) {
                    LiquidSecureField(prompt: "至少 12 位", text: $resetAdminPassword)
                        .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)

                AppleSettingsRow(title: "确认新密码", icon: "checkmark.shield.fill", iconTint: .teal) {
                    LiquidSecureField(prompt: "再次输入", text: $resetAdminConfirmation) {
                        if model.state == .online, model.isConfigured == true,
                           !model.resettingAdmin, resetAdminPassword.utf8.count >= 12,
                           resetAdminPassword == resetAdminConfirmation {
                            savePasswordDraft()
                        }
                    }
                    .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)

                AppleSettingsRow(title: "重置管理员密码") {
                    HStack(spacing: 10) {
                        if !resetAdminConfirmation.isEmpty && resetAdminPassword != resetAdminConfirmation {
                            Text("两次密码不一致")
                                .font(.caption)
                                .foregroundStyle(IsleTheme.errorText)
                        }
                        Button(model.resettingAdmin ? "验证中…" : "验证 Mac 身份并重置") {
                            savePasswordDraft()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(model.state != .online || model.isConfigured != true ||
                            model.resettingAdmin || resetAdminPassword.utf8.count < 12 ||
                            resetAdminPassword != resetAdminConfirmation)
                    }
                }
            }

            // Group 2: 本机服务端口
        }
    }
    var settingsGroup7: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(
                preferenceSection: .general,
                title: "网络与端口",
                footer: "手机、浏览器和 Mac 共用一个端口，默认 16666。通常无需修改；更改后完全退出并重新打开 LightIsle 才会生效。"
            ) {
                AppleSettingsRow(title: "访问端口", subtitle: "默认 16666，本机和其他设备使用相同端口。", icon: "network", iconTint: .orange) {
                    HStack(spacing: 8) {
                        TextField("16666", text: $localPortText)
                            .liquidInput()
                            .frame(width: 90)
                            .onSubmit { _ = model.saveLocalPort(localPortText) }
                        Button("保存") {
                            if model.saveLocalPort(localPortText) {
                                showNotice("已保存。重新打开 LightIsle 后，所有设备会使用新端口")
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                if let error = model.portError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "端口设置提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
                if let target = model.endpoint {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "当前本机访问地址", icon: "link", iconTint: .blue) {
                        HStack(spacing: 8) {
                            Text(target.absoluteString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(IsleTheme.secondaryText)
                            IsleIconButton(
                                icon: "doc.on.doc",
                                variant: .borderless,
                                help: "复制本机访问地址"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(target.absoluteString, forType: .string)
                                showNotice("已复制访问地址")
                            }
                        }
                    }
                }
            }
            .onAppear {
                if localPortText.isEmpty { localPortText = String(model.preferredLocalPort) }
            }

            // Group 3: 相册智能缓存
        }
    }
    var settingsGroup8: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(
                preferenceSection: .media,
                title: "相册智能缓存",
                footer: "按 LRU 机制淘汰旧缩略图以加快相册加载，不修改共享目录中的原图。完全退出后生效。"
            ) {
                AppleSettingsRow(
                    title: "缩略图缓存上限",
                    subtitle: "本地高速 JPEG 缓存配额，可随时调整",
                    icon: "photo.stack",
                    iconTint: .pink
                ) {
                    LiquidMenuPicker(
                        title: "缩略图缓存上限",
                        selection: $thumbnailCacheMiB,
                        options: AppModel.thumbnailCacheOptions.map { option in
                            LiquidMenuOption(
                                value: option,
                                label: option >= 1024 ? "\(option / 1024) GiB" : "\(option) MiB"
                            )
                        },
                        minWidth: 112
                    )
                    .onAppear {
                        let preferred = model.preferredThumbnailCacheMiB
                        if thumbnailCacheMiB != preferred {
                            thumbnailCacheMiB = preferred
                        }
                    }
                    .onChange(of: thumbnailCacheMiB) { _, value in
                        _ = model.saveThumbnailCacheMiB(value)
                    }
                }
            }

            // Group 4: Touch ID 凭据保护
        }
    }
    var settingsGroup9: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(
                preferenceSection: .security,
                title: "Touch ID 钥匙串保护",
                footer: "将轻屿管理员凭据安全保存在受 Secure Enclave 和 Touch ID 硬件保护的 Mac 钥匙串中。"
            ) {
                AppleSettingsRow(title: "管理员账号", icon: "person.crop.circle", iconTint: .blue) {
                    TextField("用户名", text: $vaultUsername)
                        .liquidInput()
                        .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "当前密码", icon: "lock.shield.fill", iconTint: .indigo) {
                    SecureField("密码", text: $vaultPassword)
                        .liquidInput()
                        .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "钥匙串操作", icon: "touchid", iconTint: .cyan) {
                    HStack(spacing: 8) {
                        Button(model.verifyingAdmin ? "验证中…" : "保存到钥匙串") {
                            saveCredentialDraft()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(model.state != .online || model.verifyingAdmin ||
                            vaultUsername.isEmpty || vaultPassword.isEmpty)

                        Button("Touch ID 查看") { model.unlockAdministratorWithTouchID() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))

                        Button("删除凭据") { model.removeSavedAdministrator() }
                            .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                    }
                }
                if let saved = model.unlockedAdminCredentials {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "已解锁凭据", icon: "key.fill", iconTint: .teal) {
                        HStack(spacing: 8) {
                            Text(revealUnlockedPassword ? "\(saved.username) / \(saved.password)" : "\(saved.username) / ••••••••••••")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Button(revealUnlockedPassword ? "隐藏密码" : "显示密码") { revealUnlockedPassword.toggle() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
            }

            // Group 5: 关于
        }
    }
    var settingsGroup10: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .general, title: "关于轻屿") {
                AppleSettingsRow(title: "应用版本", icon: "info.circle.fill", iconTint: .blue) {
                    Text("0.1.0-dev (Apple Silicon)")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "开场视效体验", icon: "sparkles", iconTint: .purple) {
                    Button("重新播放动画") {
                        showingManualIntro = true
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "Web 数字生活空间", icon: "safari.fill", iconTint: .cyan) {
                    Button("在浏览器打开 ↗") {
                        model.openUserWeb()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(model.state != .online)
                }
            }        }
    }
}
