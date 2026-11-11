import AppKit
import SwiftUI

struct AppScaffoldSheetView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Binding var isPresented: Bool

    @State private var idText = ""
    @State private var nameText = ""
    @State private var descriptionText = ""
    @State private var category = "utility"
    @State private var mode = "on-demand"
    @State private var runtime = "python"
    @State private var hasCron = false
    @State private var cronExpr = "0 * * * *"
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("新建轻应用插件脚手架")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }

            AppleSettingsGroup(
                title: "基本信息与运行模式",
                footer: "将自动在 plugins/<id> 下生成 plugin.json、icon.svg、env.json 与对应语言的可执行入口脚本。"
            ) {
                AppleSettingsRow(title: "插件 ID", subtitle: "小写字母与数字短横线，例如 family-board", icon: "tag", iconTint: .blue) {
                    TextField("family-board", text: $idText)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 240)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "显示名称", icon: "textformat", iconTint: .indigo) {
                    TextField("家庭留言板", text: $nameText)
                        .liquidInput()
                        .frame(width: 240)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "简介说明", icon: "doc.plaintext", iconTint: .teal) {
                    TextField("可选简介…", text: $descriptionText)
                        .liquidInput()
                        .frame(width: 240)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "Web 模式", icon: "globe", iconTint: .purple) {
                    Picker("Web 模式", selection: $mode) {
                        Text("按需唤醒 (on-demand)").tag("on-demand")
                        Text("常驻后台 (persistent)").tag("persistent")
                        Text("纯静态网页 (static)").tag("static")
                        Text("仅定时任务 (none)").tag("none")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: mode) { _, next in
                        if next == "static" { runtime = "static" }
                        else if runtime == "static" { runtime = "python" }
                        if next == "none" { hasCron = true }
                    }
                }
                if mode != "static" {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "脚本运行环境", icon: "terminal", iconTint: .orange) {
                        Picker("Runtime", selection: $runtime) {
                            Text("Python 3").tag("python")
                            Text("Node.js").tag("node")
                            Text("Go").tag("go")
                            Text("Shell").tag("shell")
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "包含定时任务 (Cron)", icon: "clock.arrow.2.circlepath", iconTint: .green) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $hasCron)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(mode == "none")
                        if hasCron {
                            TextField("0 * * * *", text: $cronExpr)
                                .liquidInput()
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 150)
                        }
                    }
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
            }

            HStack {
                Spacer()
                Button("创建并激活插件") {
                    createScaffold()
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                .disabled(appsCenter.busy)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func createScaffold() {
        let trimmedID = idText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedName.isEmpty else {
            validationError = "请填写插件 ID 与显示名称。"
            return
        }
        validationError = nil
        appsCenter.scaffoldApp(NativeAppScaffoldPayload(
            id: trimmedID,
            name: trimmedName,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            mode: mode,
            runtime: mode == "static" ? "static" : runtime,
            hasCron: hasCron || mode == "none",
            cron: cronExpr.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        isPresented = false
    }
}

struct AppConfigSheetView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    let app: NativePublicApp
    let onClose: () -> Void

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

    init(appsCenter: NativeAppsModel, app: NativePublicApp, onClose: @escaping () -> Void) {
        self.appsCenter = appsCenter
        self.app = app
        self.onClose = onClose
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("权限与运行配置 · \(app.name)")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppleSettingsGroup(title: "家庭成员访问权限") {
                        AppleSettingsRow(title: "可见范围", icon: "person.2.badge.key.fill", iconTint: .blue) {
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

                    if app.web.mode != "none" {
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
                                    .frame(width: 200)
                                }
                                if webMode == "on-demand" {
                                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                                    AppleSettingsRow(title: "空闲自动休眠秒数", subtitle: "范围 30 ~ 86400 秒", icon: "moon.zzz", iconTint: .orange) {
                                        TextField("300", text: $idleTimeoutText)
                                            .liquidInput()
                                            .font(.system(size: 12, design: .monospaced))
                                            .frame(width: 110)
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

                    if app.cron != nil {
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
                                    .frame(width: 110)
                            }
                            IsleGroupSpacing(height: 4).padding(.leading, 14)
                            AppleSettingsRow(title: "触发通知事件", icon: "bell", iconTint: .red) {
                                HStack(spacing: 12) {
                                    Toggle("成功", isOn: $notifySuccess).toggleStyle(.checkbox)
                                    Toggle("失败", isOn: $notifyFailure).toggleStyle(.checkbox)
                                    Toggle("超时", isOn: $notifyTimeout).toggleStyle(.checkbox)
                                }
                            }
                            if !appsCenter.configuredChannels.isEmpty {
                                IsleGroupSpacing(height: 4).padding(.leading, 14)
                                AppleSettingsRow(title: "发送通知渠道", icon: "paperplane", iconTint: .indigo) {
                                    HStack(spacing: 10) {
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
                }
            }

            HStack {
                Spacer()
                Button("保存配置") {
                    saveChanges()
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                .disabled(appsCenter.busy)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 460)
    }

    private func saveChanges() {
        let access = NativeAppAccessConfig(
            policy: policy,
            allowedUserIDs: Array(selectedMembers).sorted()
        )
        var webPayload: NativeAppWebUpdatePayload?
        if app.web.mode != "none" {
            let idle = Int(idleTimeoutText.trimmingCharacters(in: .whitespaces))
            webPayload = NativeAppWebUpdatePayload(
                enabled: webEnabled,
                mode: app.web.mode == "static" ? nil : webMode,
                idleTimeoutSeconds: idle,
                autoRestart: app.web.mode == "static" ? nil : autoRestart
            )
        }
        var cronPayload: NativeAppCronUpdatePayload?
        if app.cron != nil {
            var evs: [String] = []
            if notifySuccess { evs.append("success") }
            if notifyFailure { evs.append("failure") }
            if notifyTimeout { evs.append("timeout") }
            cronPayload = NativeAppCronUpdatePayload(
                enabled: cronEnabled,
                cron: cronExpr.trimmingCharacters(in: .whitespacesAndNewlines),
                timeoutSeconds: Int(cronTimeoutText.trimmingCharacters(in: .whitespaces)),
                notification: NativeAppCronNotification(
                    events: evs,
                    channels: Array(selectedChannels).sorted()
                )
            )
        }
        appsCenter.updateApp(
            appID: app.id,
            update: NativeAppUpdatePayload(
                access: access,
                web: webPayload,
                cron: cronPayload,
                revision: app.revision
            )
        )
        onClose()
    }
}

struct AppLogsSheetView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    let app: NativePublicApp
    let onClose: () -> Void

    var body: some View {
        let logs = appsCenter.currentLogs?.appId == app.id ? appsCenter.currentLogs : nil
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("运行日志与定时记录 · \(app.name)")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("刷新日志") {
                    appsCenter.loadLogs(appID: app.id)
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                Button("复制日志") {
                    let text = logs?.webOutput ?? ""
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                Button("关闭") { onClose() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }

            Text("Web 进程输出 (stdout / stderr 最近 64 KiB)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(IsleTheme.secondaryText)

            ScrollView([.horizontal, .vertical]) {
                Text((logs?.webOutput.isEmpty == false) ? (logs?.webOutput ?? "") : "暂无 Web 进程控制台输出")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            if let runs = logs?.cronRuns, !runs.isEmpty {
                Text("最近 Cron 执行记录 (\(runs.count) 条)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IsleTheme.secondaryText)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(runs) { run in
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
                .frame(maxHeight: 180)
            }
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 500)
    }
}
