import SwiftUI
import AppKit

extension ContentView {
    var settingsView: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let detail = settingsDetail {
                IsleBackButton(title: "设置") { requestLocalNavigation { settingsDetail = nil; settingsTool = nil } }
                IsleSectionHeader(title: detail.title, subtitle: detail.subtitle)
                if detail == .tools {
                    if settingsTool == .diagnostics {
                        IsleBackButton(title: "工具") { settingsTool = nil }
                        diagnosticsView
                    } else {
                        IsleDestinationRow(title: "外部依赖", subtitle: "查看本机工具及安装状态", icon: "shippingbox") { requestNavigation(.dependencies) }
                        IsleDestinationRow(title: "高级诊断", subtitle: "应用资源、采样曲线与本机进程", icon: "waveform.path.ecg") { settingsTool = .diagnostics }
                    }
                } else {
                    settingsGroups
                        .environment(\.currentPreferencesSection, detail)
                        .disabled(model.isPresentationPreview)
                }
            } else {
                IsleDestinationGrid {
                    ForEach(Array(PreferencesSection.allCases.enumerated()), id: \.element.id) { index, detail in
                        IsleDestinationRow(title: detail.title, subtitle: detail.subtitle, icon: detail.icon) {
                            requestLocalNavigation { settingsDetail = detail; preferencesSection = detail }
                        }.modifier(IsleCascade(index: index))
                    }
                }
            }
        }
    }
    @ViewBuilder var settingsGroups: some View {
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
        if settingsDetail == .about { settingsGroup10 }
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
            AppleSettingsGroup(preferenceSection: .media, title: "TMDB 自动刮削", footer: "配置后服务器会自动为影片与剧集补全标题、海报与简介。Token 只保存在本机钥匙串并经私有通道下发给 Core（仅内存），不会写入服务器磁盘或出现在 Web/移动端。可在 themoviedb.org 免费申请 Read Access Token (v4)。") {
                AppleSettingsRow(title: "配置状态", icon: "film.stack", iconTint: .purple) {
                    HStack(spacing: 8) {
                        if model.tmdbTokenBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.tmdbTokenConfigured ? "已配置（Core 已接收）" : ((model.isPresentationPreview ? nil : TmdbSecretVault.load()) != nil ? "已保存在钥匙串，等待 Core 确认" : "未配置"))
                            .font(.caption)
                            .foregroundStyle(model.tmdbTokenConfigured ? .green : .secondary)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "TMDB Read Access Token", subtitle: "输入后点击保存；不会在界面上回显已保存的 Token。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        SecureField("粘贴 Token…", text: $tmdbTokenDraft)
                            .liquidInput()
                            .font(.system(size: 12, design: .monospaced))
                        Button("取消") { tmdbTokenDraft = "" }.buttonStyle(LiquidButtonStyle())
                        Button("保存") { saveMediaDraft(.tmdb) }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(tmdbTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.tmdbTokenConfigured || (model.isPresentationPreview ? nil : TmdbSecretVault.load()) != nil {
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
            AppleSettingsGroup(preferenceSection: .media, title: "天地图 · 照片地图底图", footer: "管理员统一配置后，手机和 Web 无需填写 Key。Key 只保存在本机钥匙串，并经私有通道交给 Core 代理地图瓦片请求；客户端不会获得 Key。请先从天地图开发者控制台申请 Key，使用需遵守其服务条款。") {
                AppleSettingsRow(title: "服务状态", icon: "map", iconTint: .blue) {
                    HStack(spacing: 8) {
                        if model.mapKeyBusy { ProgressView().controlSize(.small) }
                        Text(model.mapKeyConfigured ? "已配置（Core 已接收）" : ((model.isPresentationPreview ? nil : MapSecretVault.load()) != nil ? "钥匙串已保存，等待 Core 恢复" : "尚未配置"))
                            .font(.caption)
                            .foregroundStyle(model.mapKeyConfigured ? .green : .secondary)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "天地图 API Key", subtitle: "Key 不会回显，也不会传给移动端。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        SecureField("粘贴天地图 Key…", text: $tiandituKeyDraft)
                            .liquidInput()
                            .font(.system(size: 12, design: .monospaced))
                        Button("取消") { tiandituKeyDraft = "" }.buttonStyle(LiquidButtonStyle())
                        Button("保存") { saveMediaDraft(.map) }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(tiandituKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.mapKeyConfigured || (model.isPresentationPreview ? nil : MapSecretVault.load()) != nil {
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
    var settingsGroup5: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .notifications, title: "通知渠道（Bark、邮件、企业微信、钉钉）", footer: "磁盘、下载与自动化执行事件可按渠道外发。密钥只存 Mac 钥匙串，经私有 IPC 交给 Core 使用；Web 只显示已配置渠道，不返回凭据。") {
                AppleSettingsRow(title: "通道状态", icon: "bell.badge", iconTint: .red) {
                    HStack(spacing: 8) {
                        if model.notifyBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.notifyConfigured ? "已配置（Core 已接收）" : ((model.isPresentationPreview ? nil : NotifySecretVault.load()) != nil ? "已保存在钥匙串，等待 Core 确认" : "未配置"))
                            .font(.caption)
                            .foregroundStyle(model.notifyConfigured ? .green : .secondary)
                        if let stats = model.notifyStats, stats.configured {
                            Text(stats.backingOff
                                 ? "通道连续失败，已暂停 5 分钟"
                                 : "队列 \(stats.queued) · 累计丢弃 \(stats.dropped)")
                                .font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "Bark 服务器", subtitle: "留空使用 https://api.day.app；仅填源地址，不带路径。", icon: "iphone", iconTint: .orange) {
                    TextField("https://api.day.app", text: $notifyBarkServerDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "Bark 设备 Key", subtitle: "Bark App 内复制的 Key；不会在界面上回显已保存的值。", icon: "key.fill", iconTint: .indigo) {
                    SecureField("粘贴设备 Key…", text: $notifyBarkKeyDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "通用 Webhook", subtitle: "自建服务 POST JSON 接口。企业微信和钉钉请使用下方独立的机器人协议。", icon: "arrowshape.turn.up.right", iconTint: .blue) {
                    TextField("https://example.com/hook", text: $notifyWebhookDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "允许内网目标", subtitle: "自建 Bark/Webhook 部署在内网时勾选；默认拒绝内网与本机回环地址。", icon: "network.badge.shield.half.filled", iconTint: .gray) {
                    Toggle("", isOn: $notifyAllowPrivateDraft)
                        .labelsHidden()
                        .controlSize(.small)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "企业微信机器人", subtitle: "企业微信群机器人提供的完整 Webhook URL。", icon: "person.3", iconTint: .green) {
                    TextField("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…", text: $notifyWecomDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "钉钉机器人", subtitle: "钉钉群自定义机器人 Webhook URL。", icon: "bubble.left.and.bubble.right", iconTint: .blue) {
                    TextField("https://oapi.dingtalk.com/robot/send?access_token=…", text: $notifyDingtalkDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "钉钉加签密钥（可选）", subtitle: "留空保留已保存的加签密钥。", icon: "lock.shield", iconTint: .indigo) {
                    SecureField("SEC…", text: $notifyDingtalkSecretDraft)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "邮件服务器", subtitle: "SMTP 仅允许 465（TLS）或 587（STARTTLS），不支持明文连接。", icon: "envelope", iconTint: .orange) {
                    HStack(spacing: 8) {
                        TextField("smtp.example.com", text: $notifySMTPHostDraft)
                            .liquidInput()
                            .font(.system(size: 12, design: .monospaced))
                        TextField("465", text: $notifySMTPPortDraft)
                            .liquidInput()
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 68)
                    }
                    .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "SMTP 登录", subtitle: "账户及授权码。密码留空则沿用钥匙串中已有值。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        TextField("SMTP 用户名", text: $notifySMTPUserDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                        SecureField("SMTP 授权码", text: $notifySMTPPasswordDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                    }
                    .frame(width: settingsControlWidth)
                }
                AppleSettingsRow(title: "发件人与收件人", subtitle: "收件人可输入多个邮箱，以英文逗号分隔，最多 5 个。", icon: "envelope.badge", iconTint: .blue) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("发件邮箱", text: $notifySMTPFromDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                        TextField("收件邮箱，例如 a@example.com,b@example.com", text: $notifySMTPToDraft)
                            .liquidInput()
                            .font(.system(size: 12))
                    }
                    .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "保存与测试", icon: "paperplane", iconTint: .green) {
                    HStack(spacing: 8) {
                        Button("取消修改") { resetNotificationDraft() }.buttonStyle(LiquidButtonStyle())
                        Button("保存通道") {
                            saveNotificationDraft()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(notifyBarkKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyWebhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyWecomDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyDingtalkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifySMTPHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && !(model.notifyConfigured || (model.isPresentationPreview ? nil : NotifySecretVault.load()) != nil))
                        Button("发送测试") { model.testNotify() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(!model.notifyConfigured)
                        if model.notifyConfigured || (model.isPresentationPreview ? nil : NotifySecretVault.load()) != nil {
                            Button("清除") { model.clearNotify() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
                if let result = model.notifyTestResult {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "测试结果", icon: "checkmark.seal", iconTint: .green) {
                        Text(result).font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                if let error = model.notifyError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "配置失败", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.warningText)
                    }
                }
                if model.state != .online {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "Core 未连接", icon: "wifi.slash", iconTint: .orange) {
                        Text("通道配置已保存在本机钥匙串，Core 就绪后会自动下发。")
                            .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }
            .task {
                guard !notificationDraftLoaded else { return }
                notificationDraftLoaded = true
                model.refreshNotifyStatus()
                if let saved = (model.isPresentationPreview ? nil : NotifySecretVault.load()) {
                    notifyBarkServerDraft = saved.barkServer
                    notifyWebhookDraft = saved.webhookURL
                    notifyAllowPrivateDraft = saved.allowPrivateTargets
                    notifyWecomDraft = saved.wecomWebhook ?? ""
                    notifyDingtalkDraft = saved.dingtalkWebhook ?? ""
                    notifySMTPHostDraft = saved.smtpHost ?? ""
                    notifySMTPPortDraft = String(saved.smtpPort ?? 465)
                    notifySMTPUserDraft = saved.smtpUsername ?? ""
                    notifySMTPFromDraft = saved.smtpFrom ?? ""
                    notifySMTPToDraft = saved.smtpTo ?? ""
                }
                notificationBaseline = notificationFields
            }
            .onChange(of: model.state) { _, newState in
                if newState == .online { model.refreshNotifyStatus() }
            }

            // Group 1: 管理员身份与安全
        }
    }
    var settingsGroup6: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .security,
                title: "管理员身份与安全",
                footer: "首任管理员密码仅保存在本地 Mac，重置后旧登录会话立即失效。"
            ) {
                if let username = model.firstAdminUsername {
                    AppleSettingsRow(title: "当前管理员账号", icon: "person.badge.key.fill", iconTint: .blue) {
                        HStack(spacing: 8) {
                            Text(username)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(username, forType: .string)
                                showNotice("已复制管理员用户名")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制用户名")
                        }
                    }
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                }

                AppleSettingsRow(title: "新密码", icon: "key.horizontal.fill", iconTint: .indigo) {
                    SecureField("至少 12 位", text: $resetAdminPassword)
                        .liquidInput()
                        .frame(width: settingsControlWidth)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)

                AppleSettingsRow(title: "确认新密码", icon: "checkmark.shield.fill", iconTint: .teal) {
                    SecureField("再次输入", text: $resetAdminConfirmation)
                        .liquidInput()
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
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(target.absoluteString, forType: .string)
                                showNotice("已复制访问地址")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制访问地址")
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
                        Text(revealUnlockedPassword ? "\(saved.username) / \(saved.password)" : "\(saved.username) / ••••••••••••")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button(revealUnlockedPassword ? "隐藏密码" : "显示密码") { revealUnlockedPassword.toggle() }
                            .buttonStyle(LiquidButtonStyle())
                    }
                }
            }

            // Group 5: 关于
        }
    }
    var settingsGroup10: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(preferenceSection: .about, title: "关于轻屿") {
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
                }
            }        }
    }
}
