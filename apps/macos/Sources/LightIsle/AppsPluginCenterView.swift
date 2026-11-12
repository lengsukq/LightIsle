import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsPluginCenterView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Binding var selectedAppID: String?
    @State private var showingScaffoldSheet = false
    @State private var deletingApp: NativePublicApp?
    @State private var localNotice: String?

    private var selectedApp: NativePublicApp? {
        guard let selectedAppID else { return nil }
        return appsCenter.apps.first(where: { $0.id == selectedAppID })
    }

    var body: some View {
        Group {
            if let detailApp = selectedApp {
                AppPluginDetailView(
                    appsCenter: appsCenter,
                    app: detailApp,
                    onExportBackup: { exportBackup(for: $0) },
                    onRestoreBackup: { restoreBackup(for: $0) },
                    onRequestDelete: { deletingApp = $0 }
                )
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    overviewSection
                    if let err = appsCenter.errorMessage {
                        AppleSettingsGroup(title: "操作提示") {
                            AppleSettingsRow(title: "错误详情", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(IsleTheme.warningText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if let msg = localNotice ?? appsCenter.message {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(IsleTheme.successText)
                            .textSelection(.enabled)
                            .padding(.horizontal, 4)
                    }
                    appsListSection
                }
            }
        }
        .sheet(isPresented: $showingScaffoldSheet) {
            AppScaffoldSheetView(appsCenter: appsCenter, isPresented: $showingScaffoldSheet)
        }
        .confirmationDialog(
            "确认卸载轻应用「\(deletingApp?.name ?? "")」？",
            isPresented: Binding(
                get: { deletingApp != nil },
                set: { if !$0 { deletingApp = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let app = deletingApp {
                Button("仅卸载插件代码（保留 plugin-data 数据）", role: .destructive) {
                    if selectedAppID == app.id { selectedAppID = nil }
                    appsCenter.deleteApp(appID: app.id, deleteData: false)
                    deletingApp = nil
                }
                Button("彻底删除插件代码与 plugin-data 数据", role: .destructive) {
                    if selectedAppID == app.id { selectedAppID = nil }
                    appsCenter.deleteApp(appID: app.id, deleteData: true)
                    deletingApp = nil
                }
            }
            Button("取消", role: .cancel) { deletingApp = nil }
        } message: {
            Text("卸载会停止正在运行的插件实例并移除 plugins/<id> 目录。如未来仍需恢复数据，请先导出备份或选择保留 plugin-data。")
        }
        .onChange(of: appsCenter.apps) { _, list in
            if let currentID = selectedAppID, !list.contains(where: { $0.id == currentID }) {
                selectedAppID = nil
            }
        }
        .onAppear {
            if appsCenter.apps.isEmpty {
                appsCenter.refresh()
            }
        }
    }

    private var overviewSection: some View {
        AppleSettingsGroup(
            title: "轻应用与插件中心",
            footer: "所有插件存储在 plugins/<id>，持久化数据存储在 plugin-data/<id>。支持静态 HTML 与 Python / Node / Go / Rust / Java / Shell 按需唤醒或常驻服务，并可通过本机或局域网 MCP 交给 AI Agent 开发调试。"
        ) {
            AppleSettingsRow(
                title: "已安装插件",
                subtitle: "包含内置示例与通过本地目录或 MCP 创建的轻应用",
                icon: "square.grid.2x2.fill",
                iconTint: .blue
            ) {
                HStack(spacing: 8) {
                    let runningCount = appsCenter.apps.filter(\.isRunning).count
                    StatusBadge(
                        isOnline: !appsCenter.apps.isEmpty,
                        text: "\(appsCenter.apps.count) 个应用 · \(runningCount) 个运行中"
                    )
                    Button(appsCenter.busy ? "扫描中…" : "重新扫描") {
                        appsCenter.reloadApps()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                    Button("新建插件脚手架…") {
                        showingScaffoldSheet = true
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy)
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "目录与 MCP 快捷入口",
                subtitle: "在 Finder 中管理插件源码与数据，或切换到 MCP 调试台",
                icon: "folder.badge.gearshape",
                iconTint: .purple
            ) {
                HStack(spacing: 8) {
                    Button("打开 plugins 目录") {
                        appsCenter.openPluginDirectory()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("打开 plugin-data 目录") {
                        appsCenter.openPluginDataDirectory()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("打开 MCP 调试与局域网配置") {
                        appsCenter.workspaceSection = .mcp
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
        }
    }

    @ViewBuilder
    private var appsListSection: some View {
        if appsCenter.apps.isEmpty {
            AppleSettingsGroup(title: "应用列表") {
                AppleSettingsRow(
                    title: "暂无已安装的轻应用",
                    subtitle: "可点击上方「新建插件脚手架…」创建，或开启 MCP 后让 AI Agent 自动生成",
                    icon: "puzzlepiece.extension",
                    iconTint: .secondary
                ) {
                    Button("新建插件脚手架…") { showingScaffoldSheet = true }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                }
            }
        } else {
            ForEach(appsCenter.apps) { app in
                appCard(app)
            }
        }
    }

    private func appCard(_ app: NativePublicApp) -> some View {
        AppleSettingsGroup(
            title: "\(app.name) · \(app.id)",
            footer: app.description ?? "轻应用插件"
        ) {
            appStatusRow(app)
            if app.pendingActivation {
                appPendingActivationRow(app)
            }
            appDiagnosticOrErrorSection(app)
            appControlsRow(app)
        }
    }

    private func appStatusRow(_ app: NativePublicApp) -> some View {
        let subtitleParts = [
            "ID: \(app.id)",
            "v\(app.version)",
            app.web.enabled ? "Web: \(app.web.mode)" : "无 Web 界面",
            app.web.runtime.map { "Runtime: \($0)" } ?? nil,
            app.cron != nil ? "Cron: \(app.cron?.cron ?? "")" : nil
        ].compactMap { $0 }

        return AppleSettingsRow(
            title: "运行状态与访问策略",
            subtitle: subtitleParts.joined(separator: " · "),
            icon: app.isRunning ? "bolt.horizontal.circle.fill" : "app.badge.checkmark",
            iconTint: app.valid ? (app.isRunning ? .green : .blue) : .orange
        ) {
            HStack(spacing: 8) {
                StatusBadge(
                    isOnline: app.valid && !app.pendingActivation && (app.isRunning || app.web.status == "static"),
                    text: app.statusLabel
                )
                Text(accessPolicyText(app.access))
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
                if let rss = app.web.rssBytes, rss > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: rss, countStyle: .memory))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                if let port = app.web.port, port > 0 {
                    Text(":\(port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func appPendingActivationRow(_ app: NativePublicApp) -> some View {
        IsleGroupSpacing(height: 4).padding(.leading, 14)
        AppleSettingsRow(
            title: "等待管理员首次激活确认",
            subtitle: "该插件由外部或 MCP 新建/修改过可执行入口，确认安全后即可激活运行",
            icon: "shield.lefthalf.filled.badge.checkmark",
            iconTint: .orange
        ) {
            Button("确认激活") {
                appsCenter.performAppAction(appID: app.id, action: "activate")
            }
            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
            .disabled(appsCenter.busy)
        }
    }

    @ViewBuilder
    private func appDiagnosticOrErrorSection(_ app: NativePublicApp) -> some View {
        if let diag = app.diagnostic {
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(diag.summary)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(IsleTheme.warningText)
                    Spacer()
                    Button("打开代码目录") {
                        appsCenter.openPluginDirectory(appID: app.id)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                Text("原因：" + diag.reason)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
                if let excerpt = diag.logExcerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                if let check = diag.checks.first {
                    Text("排查：" + check)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                }
                if let fix = diag.solutions.first {
                    Text("解决：" + fix)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                }
                Text(diag.dataSafe)
                    .font(.caption2)
                    .foregroundStyle(IsleTheme.successText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else if let err = app.error ?? app.lastError ?? app.web.lastError, !err.isEmpty {
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "最近错误提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func appControlsRow(_ app: NativePublicApp) -> some View {
        IsleGroupSpacing(height: 4).padding(.leading, 14)
        AppleSettingsRow(
            title: "应用控制与管理",
            subtitle: "一键打开、启停，或进入二级页配置权限、查看日志与备份数据",
            icon: "slider.horizontal.3",
            iconTint: .teal
        ) {
            HStack(spacing: 8) {
                if app.web.enabled && app.valid {
                    Button("在浏览器打开") {
                        appsCenter.openAppInBrowser(appID: app.id)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy)
                }
                if app.web.enabled && app.web.mode != "static" && app.web.mode != "none" {
                    if app.isRunning {
                        Button("重启") {
                            appsCenter.performAppAction(appID: app.id, action: "restart")
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
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(appsCenter.busy)
                    }
                }
                Button {
                    appsCenter.loadLogs(appID: app.id)
                    selectedAppID = app.id
                } label: {
                    HStack(spacing: 4) {
                        Text("管理与日志")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }
        }
    }

    private func accessPolicyText(_ access: NativeAppAccessConfig) -> String {
        switch access.policy {
        case "all_members":
            return "全体家庭成员可见"
        case "selected_members":
            return "指定成员 (\(access.allowedUserIDs.count) 人)"
        default:
            return "仅管理员可见"
        }
    }

    private func exportBackup(for app: NativePublicApp) {
        let panel = NSSavePanel()
        panel.title = "导出「\(app.name)」数据备份"
        panel.nameFieldStringValue = "\(app.id)-data-backup.tar.gz"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            appsCenter.exportAppData(appID: app.id, to: url.path)
        }
    }

    private func restoreBackup(for app: NativePublicApp) {
        let panel = NSOpenPanel()
        panel.title = "选择「\(app.name)」的数据备份归档 (.tar.gz)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appsCenter.restoreAppData(appID: app.id, from: url.path)
        }
    }
}

struct AppDiagnosticDetailSection: View {
    @ObservedObject var appsCenter: NativeAppsModel
    let app: NativePublicApp
    let diag: NativeAppDiagnostic

    var body: some View {
        AppleSettingsGroup(
            title: "异常诊断与修复指引",
            footer: diag.dataSafe
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(diag.summary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IsleTheme.warningText)
                    Spacer()
                    Button("打开代码目录") {
                        appsCenter.openPluginDirectory(appID: app.id)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("重新扫描") {
                        appsCenter.reloadApps()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.busy)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("问题原因")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(diag.reason)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .textSelection(.enabled)
                }

                if let excerpt = diag.logExcerpt, !excerpt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近报错输出")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(excerpt)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                }

                if !diag.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("如何排查")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        ForEach(Array(diag.checks.enumerated()), id: \.offset) { idx, item in
                            Text("\(idx + 1). \(item)")
                                .font(.caption)
                                .foregroundStyle(IsleTheme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !diag.solutions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("解决办法")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        ForEach(Array(diag.solutions.enumerated()), id: \.offset) { idx, item in
                            Text("\(idx + 1). \(item)")
                                .font(.caption)
                                .foregroundStyle(IsleTheme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
