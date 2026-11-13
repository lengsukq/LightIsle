import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsPluginCenterView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Binding var selectedAppID: String?
    @State private var showingScaffoldSheet = false
    @State private var deletingApp: NativePublicApp?
    @State private var localNotice: String?
    @State private var selectedInstallLocationID = ""

    private static let memoryFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f
    }()

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
                VStack(alignment: .leading, spacing: 24) {
                    overviewSection
                    noticeBanners
                    AppStorageLocationsSection(appsCenter: appsCenter)
                    templatesSection
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
                Button("仅卸载应用代码（保留数据目录）", role: .destructive) {
                    if selectedAppID == app.id { selectedAppID = nil }
                    appsCenter.deleteApp(appID: app.id, deleteData: false)
                    deletingApp = nil
                }
                Button("彻底删除应用代码与数据", role: .destructive) {
                    if selectedAppID == app.id { selectedAppID = nil }
                    appsCenter.deleteApp(appID: app.id, deleteData: true)
                    deletingApp = nil
                }
            }
            Button("取消", role: .cancel) { deletingApp = nil }
        } message: {
            Text("卸载会停止正在运行的实例并移除应用代码目录。如未来仍需恢复数据，请先导出备份或选择保留数据。")
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
        let runningCount = appsCenter.apps.filter(\.isRunning).count
        return LiquidCard {
            HStack(alignment: .center, spacing: 18) {
                IsleHeaderIconBadge(
                    icon: "square.grid.2x2.fill",
                    tint: IsleFluidPalette.brandIndigo,
                    size: 52
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("家庭轻应用与插件")
                            .font(.system(size: 18, weight: .semibold))
                        IsleStatusPill(
                            text: "\(appsCenter.apps.count) 个已安装",
                            tone: .neutral
                        )
                        if runningCount > 0 {
                            IsleStatusPill(
                                text: "\(runningCount) 个运行中",
                                tone: .success,
                                showDot: true
                            )
                        }
                    }
                    Text("按需唤醒轻应用与定时助手，闲置自动休眠；支持本机与外置盘目录及 AI Agent (MCP) 开发。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button {
                        appsCenter.reloadApps()
                    } label: {
                        Label(appsCenter.busy ? "扫描中…" : "重新扫描", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                    .disabled(appsCenter.busy)

                    Button {
                        showingScaffoldSheet = true
                    } label: {
                        Label("新建轻应用…", systemImage: "plus")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                    .disabled(appsCenter.busy)

                    Menu {
                        Button {
                            appsCenter.openPluginDirectory()
                        } label: {
                            Label("打开应用代码目录", systemImage: "folder")
                        }
                        Button {
                            appsCenter.openPluginDataDirectory()
                        } label: {
                            Label("打开应用数据目录", systemImage: "externaldrive")
                        }
                        Divider()
                        Button {
                            appsCenter.workspaceSection = .mcp
                        } label: {
                            Label("打开 AI Agent (MCP) 配置与调试", systemImage: "cpu")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30, height: 30)
                    .help("目录入口与 AI Agent (MCP) 工具")
                }
            }
        }
    }

    @ViewBuilder
    private var noticeBanners: some View {
        if let err = appsCenter.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(IsleTheme.warningText)
                Text(err)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IsleTheme.warningText)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(14)
            .modifier(IsleEmbossedSurface())
        }
        if let msg = localNotice ?? appsCenter.message {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(IsleTheme.successText)
                Text(msg)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(14)
            .modifier(IsleEmbossedSurface())
        }
    }

    @ViewBuilder
    private var templatesSection: some View {
        let templates = appsCenter.templates
        if !templates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("精选家庭轻应用")
                        .font(.system(size: 15, weight: .semibold))
                    IsleStatusPill(text: "0 MB 纯静态 · 开箱即用", tone: .accent, icon: "sparkles")
                    Spacer()
                    if let locations = appsCenter.appStorage?.locations, locations.count > 1 {
                        HStack(spacing: 6) {
                            Text("安装到")
                                .font(.system(size: 12))
                                .foregroundStyle(IsleTheme.secondaryText)
                            Picker("安装位置", selection: $selectedInstallLocationID) {
                                Text("默认（\(locations.first(where: { $0.isDefault })?.name ?? "内置盘")）").tag("")
                                ForEach(locations) { loc in
                                    Text("\(loc.kind == "external" ? "其他盘" : "内置盘") · \(loc.name)\(loc.online ? "" : "（离线）")").tag(loc.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(templates) { tpl in
                        templateCard(tpl)
                    }
                }
            }
        }
    }

    private func templateCard(_ tpl: NativeOfficialAppTemplate) -> some View {
        let visual = templateVisual(for: tpl.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                IsleHeaderIconBadge(icon: visual.icon, tint: visual.tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tpl.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                    Text("v\(tpl.version) · 官方精选")
                        .font(.system(size: 11))
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer(minLength: 4)
                IsleStatusPill(
                    text: tpl.installed ? "已安装" : "零依赖",
                    tone: tpl.installed ? .success : .neutral,
                    showDot: tpl.installed
                )
            }

            Text(tpl.description)
                .font(.system(size: 12.5))
                .foregroundStyle(IsleTheme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(tpl.installed ? "已安装在列表中" : "一键安装") {
                    appsCenter.installTemplate(
                        id: tpl.id,
                        locationID: selectedInstallLocationID.isEmpty ? nil : selectedInstallLocationID
                    )
                }
                .buttonStyle(LiquidButtonStyle(variant: tpl.installed ? .secondary : .prominent, size: .small))
                .disabled(appsCenter.busy || tpl.installed)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleItemCardSurface(interactive: !tpl.installed))
    }

    @ViewBuilder
    private var appsListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("已安装的轻应用")
                    .font(.system(size: 15, weight: .semibold))
                IsleStatusPill(text: "\(appsCenter.apps.count) 个", tone: .neutral)
                Spacer()
            }

            if appsCenter.apps.isEmpty {
                LiquidCard {
                    VStack(spacing: 12) {
                        IsleHeaderIconBadge(icon: "puzzlepiece.extension", tint: IsleFluidPalette.brandIndigo, size: 48)
                        Text("还没有安装轻应用")
                            .font(.system(size: 15, weight: .semibold))
                        Text("可以先从上方一键安装精选家庭应用，或者新建空白轻应用并用 AI Agent (MCP) 生成功能。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(IsleTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("新建轻应用…") {
                            showingScaffoldSheet = true
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    ForEach(appsCenter.apps) { app in
                        appCard(app)
                    }
                }
            }
        }
    }

    private func appCard(_ app: NativePublicApp) -> some View {
        let visual = appVisual(for: app)
        let statusTone: IsleStatusTone = {
            if !app.valid || app.diagnostic != nil { return .warning }
            if app.pendingActivation { return .warning }
            if app.isRunning || app.web.status == "static" { return .success }
            return .neutral
        }()

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IsleHeaderIconBadge(icon: visual.icon, tint: visual.tint, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 15.5, weight: .semibold))
                            .lineLimit(1)
                        Text("v\(app.version)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                    Text("\(app.id) · \(accessPolicyText(app.access))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                IsleStatusPill(
                    text: app.statusLabel,
                    tone: statusTone,
                    showDot: statusTone == .success || statusTone == .warning
                )
            }

            if let desc = app.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12.5))
                    .foregroundStyle(IsleTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            appMetadataStrip(app)

            if app.pendingActivation {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .foregroundStyle(IsleTheme.warningText)
                    Text("由外部或 MCP 更新过入口，需确认安全后激活运行。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsleTheme.warningText)
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let diag = app.diagnostic {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(IsleTheme.warningText)
                    Text(diag.summary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(IsleTheme.warningText)
                        .lineLimit(2)
                    Spacer()
                    Button("代码目录") {
                        appsCenter.openPluginDirectory(appID: app.id)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let err = app.error ?? app.lastError ?? app.web.lastError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IsleTheme.warningText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Divider().opacity(0.45)

            HStack(spacing: 8) {
                if app.pendingActivation {
                    Button("确认激活") {
                        appsCenter.performAppAction(appID: app.id, action: "activate")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy)
                } else if app.web.enabled && app.valid {
                    Button {
                        appsCenter.openAppInBrowser(appID: app.id)
                    } label: {
                        Label("打开应用", systemImage: "safari")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy)
                }

                if !app.pendingActivation && app.web.enabled && app.web.mode != "static" && app.web.mode != "none" {
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
                        Button("唤醒") {
                            appsCenter.performAppAction(appID: app.id, action: "wake")
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(appsCenter.busy)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    appsCenter.loadLogs(appID: app.id)
                    selectedAppID = app.id
                } label: {
                    HStack(spacing: 4) {
                        Text("详情与设置")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleItemCardSurface(interactive: true))
    }

    private func appMetadataStrip(_ app: NativePublicApp) -> some View {
        HStack(spacing: 6) {
            compactMetaChip(
                icon: app.locationKind == "external" ? "externaldrive.fill" : "internaldrive.fill",
                text: app.locationName
            )
            if let runtime = app.web.runtime, !runtime.isEmpty {
                compactMetaChip(icon: "cpu", text: runtime)
            } else if app.web.enabled {
                compactMetaChip(icon: "globe", text: app.web.mode == "static" ? "静态" : app.web.mode)
            }
            if let port = app.web.port, port > 0 {
                compactMetaChip(icon: nil, text: ":\(port)")
            }
            if let rss = app.web.rssBytes, rss > 0 {
                compactMetaChip(icon: nil, text: Self.memoryFormatter.string(fromByteCount: rss))
            }
            if let cron = app.cron, cron.enabled {
                compactMetaChip(icon: "clock", text: cron.cron)
            }
            Spacer(minLength: 0)
        }
    }

    private func compactMetaChip(icon: String?, text: String) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(IsleTheme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private func templateVisual(for id: String) -> (icon: String, tint: Color) {
        if id.contains("ledger") || id.contains("bill") {
            return ("yensign.circle.fill", IsleFluidPalette.brandCyan)
        }
        if id.contains("calendar") || id.contains("duty") || id.contains("countdown") {
            return ("calendar.badge.clock", IsleFluidPalette.brandBlue)
        }
        if id.contains("recipe") || id.contains("meal") || id.contains("kitchen") {
            return ("fork.knife.circle.fill", .orange)
        }
        return ("sparkles", IsleFluidPalette.brandViolet)
    }

    private func appVisual(for app: NativePublicApp) -> (icon: String, tint: Color) {
        if !app.valid || app.diagnostic != nil {
            return ("exclamationmark.triangle.fill", .orange)
        }
        if app.pendingActivation {
            return ("shield.lefthalf.filled", .orange)
        }
        if app.web.mode == "static" {
            return ("safari.fill", IsleFluidPalette.brandCyan)
        }
        if app.cron != nil && !app.web.enabled {
            return ("clock.badge.checkmark.fill", IsleFluidPalette.brandViolet)
        }
        return (app.isRunning ? "bolt.horizontal.circle.fill" : "app.badge.fill", app.isRunning ? .green : IsleFluidPalette.brandIndigo)
    }

    private func accessPolicyText(_ access: NativeAppAccessConfig) -> String {
        switch access.policy {
        case "all_members":
            return "全体家庭成员"
        case "selected_members":
            return "指定 \(access.allowedUserIDs.count) 位成员"
        default:
            return "仅管理员"
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
