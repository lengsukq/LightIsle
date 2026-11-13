import AppKit
import SwiftUI

struct AutomationScriptsCenterView: View {
    @ObservedObject var appsCenter: NativeAppsModel

    @State private var editingTask: NativeAutomationTask?
    @State private var viewingRunsTask: NativeAutomationTask?
    @State private var deletingTask: NativeAutomationTask?
    @State private var copiedPromptNotice = false
    @State private var delayedRunRefresh: Task<Void, Never>?

    private var enabledCount: Int {
        appsCenter.automationTasks.filter(\.enabled).count
    }

    private var runningCount: Int {
        appsCenter.automationTasks.filter(\.isRunning).count
    }

    private var errorCount: Int {
        appsCenter.automationTasks.filter { !($0.lastError ?? "").isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            overviewSection
            bannerSection
            if appsCenter.automationTasks.isEmpty {
                emptyStateSection
            } else {
                tasksGridSection
            }
            footerSecurityNote
        }
        .sheet(item: $editingTask) { task in
            AutomationTaskEditorSheet(appsCenter: appsCenter, task: task)
        }
        .sheet(item: $viewingRunsTask) { task in
            AutomationTaskRunsSheet(appsCenter: appsCenter, task: task)
        }
        .confirmationDialog(
            "确认删除定时脚本「\(deletingTask?.name ?? "")」？",
            isPresented: Binding(
                get: { deletingTask != nil },
                set: { if !$0 { deletingTask = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let task = deletingTask {
                Button("永久删除脚本目录", role: .destructive) {
                    appsCenter.deleteAutomationTask(taskID: task.id)
                    deletingTask = nil
                }
            }
            Button("取消", role: .cancel) { deletingTask = nil }
        } message: {
            if let task = deletingTask {
                Text("将永久删除 Mac 上 automation/scripts/\(task.id)/ 中的 task.json、脚本源码、env.json 及本地邮件模板。")
            }
        }
        .onAppear {
            if appsCenter.connected && appsCenter.automationScriptsDir.isEmpty {
                appsCenter.refresh()
            }
        }
        .onDisappear {
            delayedRunRefresh?.cancel()
            delayedRunRefresh = nil
        }
    }

    private var overviewSection: some View {
        LiquidCard {
            HStack(alignment: .center, spacing: 18) {
                IsleHeaderIconBadge(
                    icon: "clock.badge.checkmark.fill",
                    tint: IsleFluidPalette.brandViolet,
                    size: 52
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("本机定时脚本")
                            .font(.system(size: 18, weight: .semibold))
                        IsleStatusPill(
                            text: "\(appsCenter.automationTasks.count) 个脚本",
                            tone: .neutral
                        )
                        if enabledCount > 0 {
                            IsleStatusPill(
                                text: "\(enabledCount) 个已启用",
                                tone: .success,
                                showDot: true
                            )
                        }
                        if runningCount > 0 {
                            IsleStatusPill(
                                text: "\(runningCount) 个运行中",
                                tone: .warning,
                                showDot: true
                            )
                        }
                        if errorCount > 0 {
                            IsleStatusPill(
                                text: "\(errorCount) 个配置异常",
                                tone: .warning
                            )
                        }
                    }
                    Text("按 Cron 表达式定时调度本机独立可执行脚本；轻应用自带的 Cron 请在「轻应用与插件」卡片中管理。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !appsCenter.automationScriptsDir.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 10.5))
                            Text(appsCenter.automationScriptsDir)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button {
                        appsCenter.reloadAutomationScripts()
                    } label: {
                        Label(appsCenter.busy ? "扫描中…" : "刷新脚本", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                    .disabled(appsCenter.busy)

                    Button {
                        appsCenter.openAutomationScriptsDirectory()
                    } label: {
                        Label("打开脚本目录", systemImage: "folder")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))

                    Button {
                        copyAgentSpecification()
                    } label: {
                        Label(copiedPromptNotice ? "已复制规范" : "复制 Agent 规范", systemImage: copiedPromptNotice ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                }
            }
        }
    }

    @ViewBuilder
    private var bannerSection: some View {
        if let err = appsCenter.errorMessage, !err.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(IsleTheme.warningText)
                Text(err)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IsleTheme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("忽略") { appsCenter.errorMessage = nil }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }
            .padding(14)
            .modifier(IsleItemCardSurface())
        } else if let msg = appsCenter.message, !msg.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(IsleTheme.successText)
                Text(msg)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("关闭") { appsCenter.message = nil }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }
            .padding(14)
            .modifier(IsleItemCardSurface())
        }
    }

    private var emptyStateSection: some View {
        LiquidCard {
            VStack(spacing: 12) {
                IsleHeaderIconBadge(
                    icon: "terminal.fill",
                    tint: IsleFluidPalette.brandViolet,
                    size: 48
                )
                Text("暂无本机定时脚本")
                    .font(.system(size: 15, weight: .semibold))
                Text("你可以点击右上角「复制 Agent 规范」，让本地外部 AI Agent 在 automation/scripts/<任务ID>/ 下生成 task.json 与可执行脚本，再点击「刷新脚本」加载。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                HStack(spacing: 10) {
                    Button {
                        copyAgentSpecification()
                    } label: {
                        Label("复制 Agent 规范", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))

                    Button {
                        appsCenter.openAutomationScriptsDirectory()
                    } label: {
                        Label("打开 automation/scripts", systemImage: "folder")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    private var tasksGridSection: some View {
        let columns = [GridItem(.adaptive(minimum: 420), spacing: 16, alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(appsCenter.automationTasks) { task in
                taskCard(task)
            }
        }
    }

    private func taskCard(_ task: NativeAutomationTask) -> some View {
        let hasError = !(task.lastError ?? "").isEmpty
        let status: (String, IsleStatusTone) = {
            if hasError { return ("配置异常", .warning) }
            if task.isRunning { return ("运行中", .warning) }
            if task.enabled { return ("已启用", .success) }
            return ("已暂停", .neutral)
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IsleHeaderIconBadge(
                    icon: hasError ? "exclamationmark.triangle.fill" : (task.isRunning ? "bolt.horizontal.circle.fill" : "clock.badge.checkmark.fill"),
                    tint: hasError ? .orange : (task.enabled ? IsleFluidPalette.brandViolet : .secondary),
                    size: 40
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text("\(task.id) · \(task.entry)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                IsleStatusPill(
                    text: status.0,
                    tone: status.1,
                    showDot: task.isRunning || (task.enabled && !hasError)
                )
            }

            if let desc = task.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = task.lastError, !err.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(IsleTheme.warningText)
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsleTheme.warningText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            metadataStrip(for: task)

            Spacer(minLength: 0)
            Divider().opacity(0.45)

            HStack(spacing: 8) {
                Button(task.enabled ? "暂停" : "启用") {
                    appsCenter.updateAutomationTask(
                        taskID: task.id,
                        enabled: !task.enabled,
                        cron: task.schedule.cron,
                        timezone: task.schedule.timezone,
                        events: task.notification?.events ?? ["failure", "timeout"],
                        channels: task.notification?.channels ?? [],
                        revision: task.revision
                    )
                }
                .buttonStyle(LiquidButtonStyle(variant: task.enabled ? .secondary : .prominent, size: .small))
                .disabled(appsCenter.busy || hasError)

                Button {
                    triggerRunAndRefresh(task.id)
                } label: {
                    Label("立即运行", systemImage: "play.fill")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy || task.isRunning || hasError)

                Button {
                    editingTask = task
                } label: {
                    Label("Cron 与通知", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy || hasError)

                Button {
                    appsCenter.loadAutomationRuns(taskID: task.id)
                    viewingRunsTask = task
                } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)

                Spacer(minLength: 4)

                Menu {
                    Button {
                        appsCenter.openAutomationScriptsDirectory(taskID: task.id)
                    } label: {
                        Label("在 Finder 中打开任务目录", systemImage: "folder")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deletingTask = task
                    } label: {
                        Label("删除任务目录…", systemImage: "trash")
                    }
                    .disabled(task.isRunning)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleItemCardSurface(interactive: true))
    }

    private func metadataStrip(for task: NativeAutomationTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                metaChip(icon: "clock", text: task.schedule.cron.isEmpty ? "无 Cron" : task.schedule.cron, monospaced: true)
                metaChip(icon: "globe", text: task.schedule.timezone.isEmpty ? "未设时区" : task.schedule.timezone)
                if let channels = task.notification?.channels, !channels.isEmpty {
                    metaChip(icon: "bell.fill", text: "\(channels.count) 个通知渠道")
                }
                Spacer(minLength: 0)
            }
            if let nextRun = task.nextRun, nextRun > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                    Text("下次执行：\(Self.formatTimestamp(nextRun))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
            if let lastRun = task.lastRun {
                HStack(spacing: 6) {
                    Image(systemName: lastRun.state == "success" ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(lastRun.state == "success" ? IsleTheme.successText : IsleTheme.warningText)
                    Text("上次结果：\(Self.runStateLabel(lastRun.state)) · \(Self.formatTimestamp(lastRun.finishedAt))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
        }
    }

    private func metaChip(icon: String, text: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(monospaced ? .system(size: 10.5, weight: .medium, design: .monospaced) : .system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(IsleTheme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private var footerSecurityNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(IsleTheme.secondaryText)
            Text("本机定时脚本以当前 Mac 用户权限执行，LightIsle 不内嵌脚本编辑器也不保存脚本里的第三方凭据；通知渠道凭据统一保存在 Mac 钥匙串。")
                .font(.system(size: 11.5))
                .foregroundStyle(IsleTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func triggerRunAndRefresh(_ taskID: String) {
        appsCenter.runAutomationTaskNow(taskID: taskID)
        delayedRunRefresh?.cancel()
        delayedRunRefresh = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            appsCenter.refresh()
        }
    }

    private func copyAgentSpecification() {
        let dirHint = appsCenter.automationScriptsDir.isEmpty
            ? "<LightIsle 数据目录>/automation/scripts"
            : appsCenter.automationScriptsDir
        let spec = """
        请在当前 Mac 上为 LightIsle 创建或更新本机定时脚本。
        脚本根目录：\(dirHint)
        每个任务为一个子目录 <task-id>/，其中 task.json（schemaVersion 1）格式如下：
        {"schemaVersion":1,"id":"daily-report","name":"日报","enabled":false,"entry":"run.sh","args":[],"envFile":"env.json","schedule":{"cron":"0 8 * * *","timezone":"Asia/Shanghai"},"timeoutSeconds":600,"notification":{"events":["failure","timeout"],"channels":["email"],"email":{"mode":"content","file":"email.html","subject":"轻屿自动化报告"}}}
        要求：
        1. 脚本首行写正确 Shebang 并 chmod 700；env.json 请 chmod 600，切勿把 LightIsle 通知（SMTP/Bark/企业微信/钉钉/Webhook）密钥写入 task.json。
        2. 邮件 mode 支持 builtin、content（自定义 HTML 片段替换内置边框中间内容）和 custom（完整 HTML），引用同目录 file；安全占位符只有 {{task.name}}、{{task.id}}、{{run.state}}、{{run.message}}、{{run.finishedAt}}、{{run.exitCode}}。
        3. 创建或修改完成后，提醒用户在 LightIsle Mac 端「应用与容器 → 本机定时脚本」点击「刷新脚本」并按需启用。
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(spec, forType: .string)
        copiedPromptNotice = true
        appsCenter.message = "已复制本机定时脚本与邮件模板规范到剪贴板。"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedPromptNotice = false
        }
    }

    static func formatTimestamp(_ unixSeconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds)).formatted(date: .abbreviated, time: .shortened)
    }

    static func runStateLabel(_ state: String) -> String {
        switch state {
        case "running": return "运行中"
        case "success": return "成功"
        case "failure": return "失败"
        case "timeout": return "超时"
        case "interrupted": return "已中断"
        case "skipped": return "已跳过"
        default: return state
        }
    }
}

private struct AutomationTaskEditorSheet: View {
    @ObservedObject var appsCenter: NativeAppsModel
    let task: NativeAutomationTask
    @Environment(\.dismiss) private var dismiss

    @State private var cron: String
    @State private var timezone: String
    @State private var enabled: Bool
    @State private var selectedEvents: Set<String>
    @State private var selectedChannels: Set<String>

    private let eventOptions: [(id: String, label: String)] = [
        ("failure", "执行失败"),
        ("timeout", "执行超时"),
        ("success", "执行成功")
    ]
    private let channelOptions: [(id: String, label: String)] = [
        ("bark", "Bark"),
        ("webhook", "Webhook"),
        ("email", "邮件"),
        ("wecom", "企业微信"),
        ("dingtalk", "钉钉")
    ]

    init(appsCenter: NativeAppsModel, task: NativeAutomationTask) {
        self.appsCenter = appsCenter
        self.task = task
        _cron = State(initialValue: task.schedule.cron)
        _timezone = State(initialValue: task.schedule.timezone.isEmpty ? "Asia/Shanghai" : task.schedule.timezone)
        _enabled = State(initialValue: task.enabled)
        _selectedEvents = State(initialValue: Set(task.notification?.events ?? ["failure", "timeout"]))
        _selectedChannels = State(initialValue: Set(task.notification?.channels ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑定时调度 · \(task.name)")
                        .font(.system(size: 16, weight: .semibold))
                    Text("仅修改启停、五段 Cron 调度与通知设置；脚本源码、env.json 及脚本内置邮件模板不会被改动。")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
            }

            Divider()

            Toggle("启用该定时任务", isOn: $enabled)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("五段 Cron 表达式")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IsleTheme.secondaryText)
                    TextField("例如：0 8 * * *", text: $cron)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("调度时区")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IsleTheme.secondaryText)
                    TextField("例如：Asia/Shanghai", text: $timezone)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("通知触发事件")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IsleTheme.secondaryText)
                HStack(spacing: 14) {
                    ForEach(eventOptions, id: \.id) { option in
                        Toggle(option.label, isOn: binding(for: option.id, in: $selectedEvents))
                            .toggleStyle(.checkbox)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("外发通知渠道（可在「设置 → 通知与告警」配置凭据）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IsleTheme.secondaryText)
                HStack(spacing: 14) {
                    ForEach(channelOptions, id: \.id) { channel in
                        let configured = appsCenter.configuredChannels.contains(channel.id)
                        Toggle(
                            configured ? channel.label : "\(channel.label)（未配置）",
                            isOn: binding(for: channel.id, in: $selectedChannels)
                        )
                        .toggleStyle(.checkbox)
                        .disabled(!configured)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                Button("保存设置") {
                    appsCenter.updateAutomationTask(
                        taskID: task.id,
                        enabled: enabled,
                        cron: cron,
                        timezone: timezone,
                        events: eventOptions.map(\.id).filter { selectedEvents.contains($0) },
                        channels: channelOptions.map(\.id).filter { selectedChannels.contains($0) },
                        revision: task.revision
                    )
                    dismiss()
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                .disabled(cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func binding(for value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { isOn in
                if isOn {
                    set.wrappedValue.insert(value)
                } else {
                    set.wrappedValue.remove(value)
                }
            }
        )
    }
}

private struct AutomationTaskRunsSheet: View {
    @ObservedObject var appsCenter: NativeAppsModel
    let task: NativeAutomationTask
    @Environment(\.dismiss) private var dismiss

    private var runs: [NativeAppCronRun] {
        guard let result = appsCenter.currentAutomationRuns, result.taskId == task.id else {
            return []
        }
        return result.runs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("执行日志 · \(task.name)")
                        .font(.system(size: 16, weight: .semibold))
                    Text("仅展示最近 30 次执行输出、退出码及通知投递状态。")
                        .font(.system(size: 12))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
                Button {
                    appsCenter.loadAutomationRuns(taskID: task.id)
                } label: {
                    Label("刷新日志", systemImage: "arrow.clockwise")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
            }

            Divider()

            if runs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundStyle(IsleTheme.secondaryText)
                    Text("暂无执行记录；手动运行或 Cron 触发后会在此保留输出日志。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(runs) { run in
                            runRow(run)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private func runRow(_ run: NativeAppCronRun) -> some View {
        let state = run.state ?? "unknown"
        let tone: IsleStatusTone = {
            if state == "success" { return .success }
            if state == "running" || state == "skipped" { return .warning }
            return .warning
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IsleStatusPill(
                    text: AutomationScriptsCenterView.runStateLabel(state),
                    tone: tone,
                    showDot: state == "running"
                )
                if let started = run.startedAt, !started.isEmpty {
                    Text(started)
                        .font(.system(size: 12, weight: .medium))
                }
                if let code = run.exitCode, code >= 0 {
                    Text("退出码 \(code)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
            }

            let outText = (run.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            Text(outText.isEmpty ? "（没有标准输出）" : outText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(IsleTheme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let deliveries = run.deliveries, !deliveries.isEmpty {
                HStack(spacing: 8) {
                    ForEach(deliveries.keys.sorted(), id: \.self) { ch in
                        let status = deliveries[ch] ?? ""
                        Text("\(channelDisplayName(ch)) · \(deliveryStatusLabel(status))")
                            .font(.system(size: 11))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }
        }
        .padding(12)
        .modifier(IsleItemCardSurface())
    }

    private func channelDisplayName(_ id: String) -> String {
        switch id {
        case "bark": return "Bark"
        case "webhook": return "Webhook"
        case "email": return "邮件"
        case "wecom": return "企业微信"
        case "dingtalk": return "钉钉"
        default: return id
        }
    }

    private func deliveryStatusLabel(_ status: String) -> String {
        switch status {
        case "queued": return "等待发送"
        case "sent": return "已发送"
        case "not_configured": return "渠道未配置"
        case "backoff": return "渠道退避中"
        case "queue_full": return "发送队列已满"
        case "interrupted": return "发送结果未确认"
        case "authentication_failed": return "认证失败"
        case "tls_failed": return "加密连接失败"
        case "connection_failed": return "连接失败"
        case "delivery_failed": return "发送失败"
        default: return status
        }
    }
}
