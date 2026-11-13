import AppKit
import SwiftUI

/// Full-width secondary detail page for a single LightIsle plugin:
/// combines runtime controls, stdout/stderr & Cron logs, member access ACL,
/// Web/Cron lifecycle settings, and plugin-data backup/uninstall actions.
struct AppPluginDetailView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @EnvironmentObject private var edits: ManagementEdits
    let app: NativePublicApp
    let onExportBackup: (NativePublicApp) -> Void
    let onRestoreBackup: (NativePublicApp) -> Void
    let onRequestDelete: (NativePublicApp) -> Void

    @State private var loadedRevision: String?
    @State private var policy: String
    @State private var selectedMembers: Set<Int64>
    @State private var webEnabled: Bool
    @State private var webMode: String
    @State private var idleTimeoutText: String
    @State private var autoRestart: Bool
    @State private var cronEnabled: Bool
    @State private var cronExpr: String
    @State private var cronTimeoutText: String
    @State private var notifySuccess: Bool
    @State private var notifyFailure: Bool
    @State private var notifyTimeout: Bool
    @State private var selectedChannels: Set<String>
    @State private var copiedLogBanner = false

    init(
        appsCenter: NativeAppsModel,
        app: NativePublicApp,
        onExportBackup: @escaping (NativePublicApp) -> Void,
        onRestoreBackup: @escaping (NativePublicApp) -> Void,
        onRequestDelete: @escaping (NativePublicApp) -> Void
    ) {
        self.appsCenter = appsCenter
        self.app = app
        self.onExportBackup = onExportBackup
        self.onRestoreBackup = onRestoreBackup
        self.onRequestDelete = onRequestDelete
        _loadedRevision = State(initialValue: app.revision)
        _policy = State(initialValue: app.access.policy)
        _selectedMembers = State(initialValue: Set(app.access.allowedUserIDs))
        _webEnabled = State(initialValue: app.web.enabled)
        _webMode = State(initialValue: app.web.mode)
        _idleTimeoutText = State(initialValue: String(app.web.idleTimeoutSeconds ?? 300))
        _autoRestart = State(initialValue: app.web.autoRestart ?? false)
        _cronEnabled = State(initialValue: app.cron?.enabled ?? false)
        _cronExpr = State(initialValue: app.cron?.cron ?? "0 * * * *")
        _cronTimeoutText = State(initialValue: String(app.cron?.timeoutSeconds ?? 300))
        let events = Set(app.cron?.notification.events ?? ["failure", "timeout"])
        _notifySuccess = State(initialValue: events.contains("success"))
        _notifyFailure = State(initialValue: events.contains("failure"))
        _notifyTimeout = State(initialValue: events.contains("timeout"))
        _selectedChannels = State(initialValue: Set(app.cron?.notification.channels ?? []))
    }

    private var draftFingerprint: [String] {
        var evs: [String] = []
        if notifySuccess { evs.append("success") }
        if notifyFailure { evs.append("failure") }
        if notifyTimeout { evs.append("timeout") }
        return [
            policy,
            selectedMembers.sorted().map(String.init).joined(separator: ","),
            String(webEnabled),
            webMode,
            idleTimeoutText.trimmingCharacters(in: .whitespaces),
            String(autoRestart),
            String(cronEnabled),
            cronExpr.trimmingCharacters(in: .whitespacesAndNewlines),
            cronTimeoutText.trimmingCharacters(in: .whitespaces),
            evs.sorted().joined(separator: ","),
            selectedChannels.sorted().joined(separator: ",")
        ]
    }

    private var baselineFingerprint: [String] {
        let events = Set(app.cron?.notification.events ?? ["failure", "timeout"])
        var evs: [String] = []
        if events.contains("success") { evs.append("success") }
        if events.contains("failure") { evs.append("failure") }
        if events.contains("timeout") { evs.append("timeout") }
        return [
            app.access.policy,
            app.access.allowedUserIDs.sorted().map(String.init).joined(separator: ","),
            String(app.web.enabled),
            app.web.mode,
            String(app.web.idleTimeoutSeconds ?? 300),
            String(app.web.autoRestart ?? false),
            String(app.cron?.enabled ?? false),
            (app.cron?.cron ?? "0 * * * *").trimmingCharacters(in: .whitespacesAndNewlines),
            String(app.cron?.timeoutSeconds ?? 300),
            evs.sorted().joined(separator: ","),
            (app.cron?.notification.channels ?? []).sorted().joined(separator: ",")
        ]
    }

    private var isDirty: Bool {
        draftFingerprint != baselineFingerprint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let diag = app.diagnostic {
                AppDiagnosticDetailSection(appsCenter: appsCenter, app: app, diag: diag)
            } else if let err = appsCenter.errorMessage {
                AppleSettingsGroup(title: "操作提示") {
                    AppleSettingsRow(title: "错误详情", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                        HStack(spacing: 8) {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(IsleTheme.warningText)
                                .textSelection(.enabled)
                            IsleIconButton(icon: "xmark", variant: .borderless, help: "关闭错误提示") {
                                appsCenter.errorMessage = nil
                            }
                        }
                    }
                }
            }
            if let msg = appsCenter.message {
                HStack(spacing: 8) {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.successText)
                        .textSelection(.enabled)
                    Spacer()
                    IsleIconButton(icon: "xmark", variant: .borderless, help: "关闭提示") {
                        appsCenter.message = nil
                    }
                }
                .padding(.horizontal, 4)
            }

            runtimeControlSection
            logsSection
            accessSection
            if app.web.mode != "none" {
                webLifecycleSection
            }
            if app.cron != nil {
                cronSection
            }
            saveSection
            dataAndDangerSection
        }
        .onAppear {
            if appsCenter.currentLogs?.appId != app.id {
                appsCenter.loadLogs(appID: app.id)
            }
            syncEdits()
        }
        .onDisappear {
            edits.reset()
        }
        .onChange(of: draftFingerprint) { _, _ in
            syncEdits()
        }
        .onChange(of: appsCenter.busy) { _, busy in
            edits.busy = busy
            if !busy {
                edits.error = appsCenter.errorMessage
            }
        }
        .onChange(of: app.revision) { _, nextRev in
            if nextRev != loadedRevision {
                resetDraft(from: app)
                loadedRevision = nextRev
            }
        }
    }

    private var runtimeControlSection: some View {
        let statusTone: IsleStatusTone = {
            if !app.valid || app.diagnostic != nil { return .warning }
            if app.pendingActivation { return .warning }
            if app.isRunning || app.web.status == "static" { return .success }
            return .neutral
        }()
        let metaParts = [
            "ID: \(app.id)",
            "v\(app.version)",
            app.locationKind == "external" ? "其他盘 · \(app.locationName)" : "内置盘 · \(app.locationName)",
            app.web.enabled ? "Web: \(app.web.mode)" : "无 Web 界面",
            app.web.runtime.map { "Runtime: \($0)" } ?? nil,
            app.cron != nil ? "Cron: \(app.cron?.cron ?? "")" : nil
        ].compactMap { $0 }

        return LiquidCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    IsleHeaderIconBadge(
                        icon: app.isRunning ? "bolt.horizontal.circle.fill" : (app.web.mode == "static" ? "safari.fill" : "app.badge.fill"),
                        tint: app.valid ? (app.isRunning ? .green : IsleFluidPalette.brandIndigo) : .orange,
                        size: 48
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(app.name)
                                .font(.system(size: 18, weight: .semibold))
                            IsleStatusPill(
                                text: app.statusLabel,
                                tone: statusTone,
                                showDot: statusTone == .success || statusTone == .warning
                            )
                            if let rss = app.web.rssBytes, rss > 0 {
                                IsleStatusPill(
                                    text: IsleFormatters.memorySize(rss),
                                    tone: .neutral
                                )
                            }
                            if let port = app.web.port, port > 0 {
                                IsleStatusPill(text: "127.0.0.1:\(port)", tone: .neutral)
                            }
                        }
                        Text(app.description ?? "轻应用插件")
                            .font(.system(size: 12.5))
                            .foregroundStyle(IsleTheme.secondaryText)
                        Text(metaParts.joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(IsleTheme.secondaryText.opacity(0.85))
                    }
                    Spacer(minLength: 8)
                }

                if app.pendingActivation {
                    HStack(spacing: 10) {
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .foregroundStyle(IsleTheme.warningText)
                        Text("该插件由外部或 MCP 新建/修改过可执行入口，确认安全后即可激活运行。")
                            .font(.system(size: 12))
                            .foregroundStyle(IsleTheme.warningText)
                        Spacer()
                        Button("确认激活") {
                            appsCenter.performAppAction(appID: app.id, action: "activate")
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(appsCenter.busy)
                    }
                    .padding(11)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if app.diagnostic == nil, let err = app.error ?? app.lastError ?? app.web.lastError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.warningText)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Divider().opacity(0.45)

                HStack(spacing: 8) {
                    if app.web.enabled && app.valid {
                        Button {
                            appsCenter.openAppInBrowser(appID: app.id)
                        } label: {
                            Label("在浏览器打开", systemImage: "safari")
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(appsCenter.busy)
                    }
                    if app.web.enabled && app.web.mode != "static" && app.web.mode != "none" {
                        if app.isRunning {
                            Button("重启") {
                                appsCenter.performAppAction(appID: app.id, action: "restart")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    appsCenter.loadLogs(appID: app.id)
                                }
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(appsCenter.busy)
                            Button("停止") {
                                appsCenter.performAppAction(appID: app.id, action: "stop")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(appsCenter.busy)
                        } else {
                            Button("唤醒启动") {
                                appsCenter.performAppAction(appID: app.id, action: "wake")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    appsCenter.loadLogs(appID: app.id)
                                }
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(appsCenter.busy)
                        }
                    }
                    if app.cron != nil {
                        Button("立即执行 Cron") {
                            appsCenter.performAppAction(appID: app.id, action: "run_cron")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                appsCenter.loadLogs(appID: app.id)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(appsCenter.busy)
                    }
                    Spacer()
                }
            }
        }
    }

    private var logsSection: some View {
        let logs = appsCenter.currentLogs?.appId == app.id ? appsCenter.currentLogs : nil
        return AppleSettingsGroup(
            title: "运行日志与定时记录",
            footer: "展示 Web 进程最近 64 KiB 标准输出/错误流以及定时脚本最近执行记录。"
        ) {
            AppleSettingsRow(
                title: "控制台日志输出",
                subtitle: copiedLogBanner ? "已复制控制台日志到剪贴板" : "Web 子进程 stdout / stderr 环形缓冲",
                icon: "doc.text.magnifyingglass",
                iconTint: .indigo
            ) {
                HStack(spacing: 8) {
                    Button("刷新日志") {
                        appsCenter.loadLogs(appID: app.id)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button(copiedLogBanner ? "已复制" : "复制日志") {
                        let text = logs?.webOutput ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copiedLogBanner = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedLogBanner = false
                        }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ScrollView([.horizontal, .vertical]) {
                    Text((logs?.webOutput.isEmpty == false) ? (logs?.webOutput ?? "") : "暂无 Web 进程控制台输出")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(minHeight: 150, maxHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

                if let runs = logs?.cronRuns, !runs.isEmpty {
                    Text("最近 Cron 执行记录 (\(runs.count) 条)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IsleTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(runs.prefix(10)) { run in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    StatusBadge(
                                        isOnline: run.state == "success",
                                        text: "\(run.state ?? "unknown") · exit \(run.exitCode ?? 0)"
                                    )
                                    Text(run.startedAt ?? "")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(IsleTheme.secondaryText)
                                    Spacer()
                                }
                                if let out = run.output, !out.isEmpty {
                                    Text(out)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var accessSection: some View {
        AppleSettingsGroup(title: "家庭成员访问权限") {
            AppleSettingsRow(title: "可见范围", subtitle: "控制 Web 与移动端应用中心对普通成员的展示与网关授权；管理员始终可访问全部应用", icon: "person.2.badge.key.fill", iconTint: .blue) {
                Picker("可见范围", selection: $policy) {
                    Text("仅管理员可见 (admin_only)").tag("admin_only")
                    Text("全体成员可见 (all_members)").tag("all_members")
                    Text("指定家庭成员 (selected_members)").tag("selected_members")
                }
                .labelsHidden()
                .frame(width: 240)
            }
            if policy == "selected_members" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                let nonAdminMembers = appsCenter.members.filter { $0.role != "admin" }
                if nonAdminMembers.isEmpty {
                    AppleSettingsRow(title: "普通成员列表", icon: "person.crop.circle.badge.exclamationmark", iconTint: .orange) {
                        Text("当前暂无已启用的普通家庭成员账号")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                } else {
                    ForEach(nonAdminMembers) { member in
                        AppleSettingsRow(title: member.username, subtitle: "成员 ID #\(member.id)", icon: "person.fill", iconTint: .teal) {
                            Toggle("", isOn: Binding(
                                get: { selectedMembers.contains(member.id) },
                                set: { checked in
                                    if checked { selectedMembers.insert(member.id) }
                                    else { selectedMembers.remove(member.id) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }

    private var webLifecycleSection: some View {
        AppleSettingsGroup(title: "Web 服务与生命周期") {
            AppleSettingsRow(title: "启用 Web 访问", icon: "globe", iconTint: .purple) {
                Toggle("", isOn: $webEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if app.web.mode != "static" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "生命周期模式", icon: "bolt.horizontal", iconTint: .indigo) {
                    Picker("模式", selection: $webMode) {
                        Text("按需唤醒 (on-demand)").tag("on-demand")
                        Text("常驻运行 (persistent)").tag("persistent")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if webMode == "on-demand" {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "空闲自动休眠秒数", subtitle: "范围 30 ~ 86400 秒，无活跃连接超时后自动退出释放内存", icon: "moon.zzz", iconTint: .orange) {
                        TextField("300", text: $idleTimeoutText)
                            .liquidInput()
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 120)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "异常退出自动重启", icon: "arrow.clockwise.circle", iconTint: .green) {
                    Toggle("", isOn: $autoRestart)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var cronSection: some View {
        AppleSettingsGroup(title: "定时任务 (Cron) 与通知", footer: "邮件模板模式与主题遵循插件脚本自带配置，保存此处不会覆盖邮件模板设置。") {
            AppleSettingsRow(title: "启用定时调度", icon: "clock.badge.checkmark", iconTint: .green) {
                Toggle("", isOn: $cronEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "Cron 表达式", subtitle: "标准 5 段式，例如 */15 * * * *", icon: "calendar.badge.clock", iconTint: .blue) {
                TextField("0 * * * *", text: $cronExpr)
                    .liquidInput()
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 180)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "超时秒数", icon: "timer", iconTint: .orange) {
                TextField("300", text: $cronTimeoutText)
                    .liquidInput()
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 120)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "触发通知事件", icon: "bell", iconTint: .red) {
                HStack(spacing: 14) {
                    Toggle("成功", isOn: $notifySuccess).toggleStyle(.checkbox)
                    Toggle("失败", isOn: $notifyFailure).toggleStyle(.checkbox)
                    Toggle("超时", isOn: $notifyTimeout).toggleStyle(.checkbox)
                }
            }
            if !appsCenter.configuredChannels.isEmpty {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "发送通知渠道", icon: "paperplane", iconTint: .indigo) {
                    HStack(spacing: 12) {
                        ForEach(appsCenter.configuredChannels, id: \.self) { ch in
                            Toggle(ch, isOn: Binding(
                                get: { selectedChannels.contains(ch) },
                                set: { on in
                                    if on { selectedChannels.insert(ch) }
                                    else { selectedChannels.remove(ch) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }

    private var saveSection: some View {
        AppleSettingsGroup(title: "配置保存") {
            AppleSettingsRow(
                title: isDirty ? "有尚未保存的配置修改" : "权限与运行配置已同步",
                subtitle: "点击保存后写入本地 plugin.json 并自动重载生效",
                icon: isDirty ? "pencil.circle.fill" : "checkmark.circle.fill",
                iconTint: isDirty ? .orange : .green
            ) {
                HStack(spacing: 8) {
                    if isDirty {
                        Button("放弃修改") {
                            resetDraft(from: app)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(appsCenter.busy)
                    }
                    Button("保存配置") {
                        saveChanges()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                    .disabled(!isDirty || appsCenter.busy)
                }
            }
        }
    }

    private var dataAndDangerSection: some View {
        AppleSettingsGroup(
            title: "目录、数据备份与卸载",
            footer: "导出备份会对 SQLite 数据库执行一致性快照并生成带 SHA-256 清单的归档；仅卸载插件代码时，plugin-data/<id> 会安全保留。"
        ) {
            AppleSettingsRow(
                title: "本地代码与数据目录",
                subtitle: "在 Finder 中查看 plugins/\(app.id) 或 plugin-data/\(app.id)",
                icon: "folder.fill",
                iconTint: .blue
            ) {
                HStack(spacing: 8) {
                    Button("打开代码目录") {
                        appsCenter.openPluginDirectory(appID: app.id)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("打开数据目录") {
                        appsCenter.openPluginDataDirectory(appID: app.id)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "业务数据一致性备份",
                subtitle: "导出或从归档恢复 plugin-data/\(app.id) 数据",
                icon: "externaldrive.badge.timemachine",
                iconTint: .indigo
            ) {
                HStack(spacing: 8) {
                    Button("导出数据…") {
                        onExportBackup(app)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                    Button("恢复数据…") {
                        onRestoreBackup(app)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "卸载此插件",
                subtitle: "停止运行实例并移除 plugins/\(app.id) 目录（可选保留或一并删除数据）",
                icon: "trash.fill",
                iconTint: .red
            ) {
                Button("卸载…") {
                    onRequestDelete(app)
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
            }
        }
    }

    private func resetDraft(from source: NativePublicApp) {
        policy = source.access.policy
        selectedMembers = Set(source.access.allowedUserIDs)
        webEnabled = source.web.enabled
        webMode = source.web.mode
        idleTimeoutText = String(source.web.idleTimeoutSeconds ?? 300)
        autoRestart = source.web.autoRestart ?? false
        cronEnabled = source.cron?.enabled ?? false
        cronExpr = source.cron?.cron ?? "0 * * * *"
        cronTimeoutText = String(source.cron?.timeoutSeconds ?? 300)
        let events = Set(source.cron?.notification.events ?? ["failure", "timeout"])
        notifySuccess = events.contains("success")
        notifyFailure = events.contains("failure")
        notifyTimeout = events.contains("timeout")
        selectedChannels = Set(source.cron?.notification.channels ?? [])
        edits.dirty = false
        edits.error = nil
    }

    private func syncEdits() {
        edits.dirty = isDirty
        edits.save = {
            saveChanges()
        }
        edits.discard = {
            resetDraft(from: app)
        }
    }

    private func saveChanges() {
        let access = NativeAppAccessConfig(
            policy: policy,
            allowedUserIDs: Array(selectedMembers).sorted()
        )
        var webPayload: NativeAppWebUpdatePayload?
        if app.web.mode != "none" {
            var idle: Int?
            if app.web.mode != "static" && webMode == "on-demand" {
                guard let parsed = Int(idleTimeoutText.trimmingCharacters(in: .whitespaces)),
                      (30...86400).contains(parsed) else {
                    edits.error = "空闲自动休眠秒数须为 30 ~ 86400 之间的整数。"
                    return
                }
                idle = parsed
            } else {
                idle = Int(idleTimeoutText.trimmingCharacters(in: .whitespaces))
            }
            webPayload = NativeAppWebUpdatePayload(
                enabled: webEnabled,
                mode: app.web.mode == "static" ? nil : webMode,
                idleTimeoutSeconds: idle,
                autoRestart: app.web.mode == "static" ? nil : autoRestart
            )
        }
        var cronPayload: NativeAppCronUpdatePayload?
        if app.cron != nil {
            let trimmedCron = cronExpr.trimmingCharacters(in: .whitespacesAndNewlines)
            if cronEnabled && trimmedCron.split(whereSeparator: \.isWhitespace).count != 5 {
                edits.error = "Cron 表达式须为 5 段（分 时 日 月 周），例如 */15 * * * *。"
                return
            }
            guard let timeoutSec = Int(cronTimeoutText.trimmingCharacters(in: .whitespaces)),
                  (10...86400).contains(timeoutSec) else {
                edits.error = "定时任务超时秒数须为 10 ~ 86400 之间的整数。"
                return
            }
            var evs: [String] = []
            if notifySuccess { evs.append("success") }
            if notifyFailure { evs.append("failure") }
            if notifyTimeout { evs.append("timeout") }
            cronPayload = NativeAppCronUpdatePayload(
                enabled: cronEnabled,
                cron: trimmedCron,
                timeoutSeconds: timeoutSec,
                notification: NativeAppCronNotification(
                    events: evs,
                    channels: Array(selectedChannels).sorted()
                )
            )
        }
        edits.error = nil
        edits.busy = true
        appsCenter.updateApp(
            appID: app.id,
            update: NativeAppUpdatePayload(
                access: access,
                web: webPayload,
                cron: cronPayload,
                revision: app.revision
            )
        )
    }
}
