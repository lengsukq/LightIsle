import AppKit
import SwiftUI

struct MCPDeveloperCenterView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Environment(\.isleReduceMotion) private var reduceMotion
    @State private var revealToken = false
    @State private var copiedBanner: String?
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var showingClientWizard = false
    @State private var showCallTraceLogs = false

    // MCP Inspector State
    @State private var inspectorMode = "tools/call"
    @State private var selectedTool = ""
    @State private var selectedURI = ""
    @State private var toolArgsJSON = "{}"
    @State private var rawRPCJSON = """
    {
      "jsonrpc": "2.0",
      "id": 1,
      "method": "tools/list",
      "params": {}
    }
    """

    // Gateway Probe State
    @State private var probeAppID = ""
    @State private var probeMethod = "GET"
    @State private var probePath = "/"
    @State private var probeRole = "admin"
    @State private var probeBody = ""

    private var effectiveLocalCommand: String {
        let trimmed = appsCenter.mcp.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/Applications/LightIsle.app/Contents/Resources/core/lightisled mcp" : trimmed
    }

    private var effectiveLocalPrompt: String {
        let trimmed = appsCenter.mcp.mcpPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "请将 LightIsle（轻屿 NAS）添加为本机 MCP Server，启动命令：\(effectiveLocalCommand)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            mcpConfigSection
            if let notice = copiedBanner ?? appsCenter.message {
                HStack(spacing: 8) {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.successText)
                        .textSelection(.enabled)
                    Spacer()
                    IsleIconButton(
                        icon: "xmark",
                        variant: .borderless,
                        help: "关闭提示"
                    ) {
                        if copiedBanner != nil {
                            copiedResetTask?.cancel()
                            copiedBanner = nil
                        } else {
                            appsCenter.message = nil
                        }
                    }
                }
                .padding(.horizontal, 4)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if let err = appsCenter.errorMessage {
                HStack(spacing: 8) {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.warningText)
                        .textSelection(.enabled)
                    Spacer()
                    IsleIconButton(
                        icon: "xmark",
                        variant: .borderless,
                        help: "关闭错误提示"
                    ) {
                        appsCenter.errorMessage = nil
                    }
                }
                .padding(.horizontal, 4)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            mcpInspectorSection
            gatewayProbeSection
            IsleQuickJumpBar(items: [
                IsleQuickJumpItem("本机定时脚本", icon: "clock.badge.checkmark.fill", tint: IsleFluidPalette.brandViolet, help: "查看可由 MCP 列出与调起的 automation/scripts 脚本") {
                    appsCenter.workspaceSection = .automation
                },
                IsleQuickJumpItem("轻应用与插件", icon: "square.grid.2x2.fill", tint: IsleFluidPalette.brandIndigo, help: "查看轻应用源码、日志与网关探测目标") {
                    appsCenter.workspaceSection = .plugins
                },
                IsleQuickJumpItem("工具与高级诊断", icon: "wrench.and.screwdriver", tint: .teal, help: "查看系统资源采样、外部依赖与本地目录") {
                    AppModel.shared.navigateToSettingsDetail(.tools)
                }
            ])
        }
        .animation(reduceMotion ? nil : IsleMotion.quick, value: copiedBanner ?? appsCenter.message)
        .animation(reduceMotion ? nil : IsleMotion.quick, value: appsCenter.errorMessage)
        .sheet(isPresented: $showingClientWizard) {
            MCPClientWizardSheet(appsCenter: appsCenter)
        }
        .onAppear {
            if probeAppID.isEmpty, let first = appsCenter.apps.first?.id {
                probeAppID = first
            }
            syncSelectedCatalogItems()
            if appsCenter.connected && appsCenter.mcp.mcpEnabled && appsCenter.discoveredMCPTools.isEmpty {
                appsCenter.refreshMCPCatalog()
            }
        }
        .onChange(of: appsCenter.mcp.mcpEnabled) { _, enabled in
            if enabled && appsCenter.connected && appsCenter.discoveredMCPTools.isEmpty {
                appsCenter.refreshMCPCatalog()
            }
        }
        .onChange(of: appsCenter.discoveredMCPTools) { _, _ in
            syncSelectedCatalogItems()
        }
        .onChange(of: appsCenter.discoveredMCPResources) { _, _ in
            syncSelectedCatalogItems()
        }
        .onChange(of: appsCenter.apps) { _, list in
            if probeAppID.isEmpty, let first = list.first?.id {
                probeAppID = first
            }
        }
        .onChange(of: appsCenter.message) { _, next in
            if next != nil {
                copiedResetTask?.cancel()
                copiedBanner = nil
            }
        }
        .onDisappear {
            copiedResetTask?.cancel()
            copiedResetTask = nil
        }
    }

    private var mcpConfigSection: some View {
        let snap = appsCenter.mcp
        return AppleSettingsGroup(
            title: "AI Agent (MCP) 服务",
            footer: "关闭主开关将联动关闭本机桥接与局域网 / Cloud MCP 访问。全部调用实时写入 SQLite 审计日志；格式化磁盘、注销存储根、物理粉碎文件与密钥导出已物理隔离禁止。"
        ) {
            AppleSettingsRow(
                title: "开启 AI Agent (MCP) 服务",
                subtitle: "开启后默认启用本机免令牌直连（已内置 ~/.cache 与 /tmp 沙盒回环桥接），支持 Gemini 桌面端 / Claude Desktop / Cursor",
                icon: "cpu.fill",
                iconTint: .purple
            ) {
                HStack(spacing: 10) {
                    Button("客户端接入向导") {
                        showingClientWizard = true
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    IsleIconButton(
                        icon: "text.bubble",
                        help: "复制本机 MCP 接入提示词（可直接粘贴给外部 AI Agent）"
                    ) {
                        if !snap.mcpEnabled { appsCenter.setMCPConfig(mcpEnabled: true) }
                        copyText(effectiveLocalPrompt, notice: "已复制本机 MCP 接入提示词")
                    }
                    Toggle("", isOn: Binding(
                        get: { snap.mcpEnabled },
                        set: { enabled in
                            withAnimation(reduceMotion ? nil : IsleMotion.fluid) {
                                appsCenter.setMCPConfig(
                                    mcpEnabled: enabled,
                                    mcpLanEnabled: enabled ? nil : false
                                )
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(appsCenter.busy)
                }
            }

            if snap.mcpEnabled {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "本机命令",
                    subtitle: effectiveLocalCommand,
                    icon: "terminal",
                    iconTint: .teal
                ) {
                    IsleIconButton(
                        icon: "doc.on.doc",
                        help: "复制本机 Stdio MCP 启动命令"
                    ) {
                        copyText(
                            effectiveLocalCommand,
                            notice: "已复制本机 Stdio MCP 启动命令"
                        )
                    }
                }

                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "允许局域网 / Cloud MCP 访问",
                    subtitle: "开启后同一局域网设备或 Gemini Cloud MCP 可持鉴权 Token 连接 /api/v2/mcp",
                    icon: "network.badge.shield.half.filled",
                    iconTint: .blue
                ) {
                    Toggle("", isOn: Binding(
                        get: { snap.mcpLanEnabled },
                        set: { enabled in
                            withAnimation(reduceMotion ? nil : IsleMotion.fluid) {
                                appsCenter.setMCPConfig(mcpEnabled: true, mcpLanEnabled: enabled)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(appsCenter.busy)
                }

                if snap.mcpLanEnabled {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(
                        title: "远程端点（Streamable HTTP / SSE）",
                        subtitle: "HTTP: \(snap.lanHttpUrl ?? snap.localHttpUrl)  ·  SSE: \(snap.lanSseUrl ?? (snap.localHttpUrl + "/sse"))",
                        icon: "point.3.connected.trianglepath.dotted",
                        iconTint: .indigo
                    ) {
                        HStack(spacing: 6) {
                            IsleIconButton(
                                icon: "link",
                                help: "复制 MCP Streamable HTTP 端点 URL（/api/v2/mcp）"
                            ) {
                                copyText(snap.lanHttpUrl ?? snap.localHttpUrl, notice: "已复制 MCP HTTP 端点 URL")
                            }
                            IsleIconButton(
                                icon: "text.bubble",
                                variant: .prominent,
                                help: "复制局域网 MCP 接入提示词（含鉴权说明）"
                            ) {
                                copyText(snap.lanMcpPrompt, notice: "已复制局域网 MCP 接入提示词")
                            }
                            IsleIconButton(
                                icon: "curlybraces",
                                help: "复制 mcpServers JSON 配置"
                            ) {
                                copyText(snap.mcpConfigJson, notice: "已复制 mcpServers JSON 配置")
                            }
                        }
                    }

                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    let tokenText = snap.mcpToken ?? ""
                    let masked = tokenText.count > 12
                        ? "\(tokenText.prefix(6))••••••••••••\(tokenText.suffix(4))"
                        : (tokenText.isEmpty ? "未生成" : "••••••••")
                    AppleSettingsRow(
                        title: "鉴权 Token 管理",
                        subtitle: revealToken ? tokenText : masked,
                        icon: "key.horizontal.fill",
                        iconTint: .orange
                    ) {
                        HStack(spacing: 6) {
                            IsleIconButton(
                                icon: revealToken ? "eye.slash" : "eye",
                                help: revealToken ? "隐藏 MCP Bearer Token" : "显示完整 MCP Bearer Token"
                            ) {
                                revealToken.toggle()
                            }
                            IsleIconButton(
                                icon: "doc.on.doc",
                                help: "复制 MCP Bearer Token"
                            ) {
                                copyText(tokenText, notice: "已复制 MCP Bearer Token")
                            }
                            .disabled(tokenText.isEmpty)
                            IsleIconButton(
                                icon: "arrow.triangle.2.circlepath",
                                help: "轮换 MCP Bearer Token（旧令牌将立即失效）"
                            ) {
                                appsCenter.rotateMCPToken()
                            }
                            .disabled(appsCenter.busy)
                        }
                    }
                }

                IsleGroupSpacing(height: 4).padding(.leading, 14)
                mcpCallLogsDisclosure
            }
        }
    }

    private var mcpCallLogsDisclosure: some View {
        DisclosureGroup(isExpanded: $showCallTraceLogs) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("自动记录最近 50 次本机 / 局域网 / Cloud MCP 调用与耗时")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                    Spacer()
                    IsleIconButton(
                        icon: "arrow.clockwise",
                        help: "刷新 MCP 调用日志"
                    ) {
                        appsCenter.refresh()
                    }
                    IsleIconButton(
                        icon: "trash",
                        variant: .destructive,
                        help: "清空所有 MCP 调用记录"
                    ) {
                        appsCenter.clearMCPLogs()
                    }
                    .disabled(appsCenter.mcpLogs.isEmpty || appsCenter.busy)
                }
                if appsCenter.mcpLogs.isEmpty {
                    Text("暂无 MCP 调用记录，当 AI Agent 或调试器发起请求后会在此显示。")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                        .padding(.vertical, 4)
                } else {
                    ForEach(appsCenter.mcpLogs.prefix(20)) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(entry.isError ? .orange : .green)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.method)\(entry.target.map { " · \($0)" } ?? "")")
                                    .font(.caption.weight(.medium))
                                Text("[\(entry.transport)] \(entry.remoteAddr ?? "local") · \(entry.timestamp)")
                                    .font(.caption2)
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            Spacer()
                            Text("\(entry.durationMs) ms")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(entry.isError ? IsleTheme.warningText : IsleTheme.secondaryText)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(.orange)
                Text("调用日志（最近 \(appsCenter.mcpLogs.count) 条）")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var mcpInspectorSection: some View {
        let tools = appsCenter.discoveredMCPTools
        let resources = appsCenter.discoveredMCPResources
        let catalogReady = !tools.isEmpty || !resources.isEmpty

        return AppleSettingsGroup(
            title: "MCP 交互式调试器 (MCP Inspector)",
            footer: "工具与规范资源清单直接向本机 MCP 网关动态请求（tools/list 与 resources/list），与后端保持单一事实来源，无静态漂移。"
        ) {
            AppleSettingsRow(
                title: "动态工具与资源目录",
                subtitle: !appsCenter.connected
                    ? "轻屿核心服务未连接，请等待服务在线后刷新。"
                    : (!appsCenter.mcp.mcpEnabled
                        ? "请先开启上方「AI Agent (MCP) 服务」开关，再同步动态工具目录。"
                        : (catalogReady
                            ? "已从本机网关同步 \(tools.count) 项工具与 \(resources.count) 项资源"
                            : "尚未同步网关清单，请点击右侧刷新按钮拉取 tools/list 与 resources/list。")),
                icon: "arrow.triangle.2.circlepath.circle.fill",
                iconTint: catalogReady ? .green : .orange
            ) {
                HStack(spacing: 8) {
                    if appsCenter.mcpCatalogLoading {
                        ProgressView().controlSize(.small)
                    }
                    if appsCenter.connected && !appsCenter.mcp.mcpEnabled {
                        Button("开启服务并同步") {
                            appsCenter.setMCPConfig(mcpEnabled: true)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(appsCenter.busy)
                    } else {
                        Button(appsCenter.mcpCatalogLoading ? "同步中…" : "刷新目录") {
                            appsCenter.refreshMCPCatalog()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(!appsCenter.connected || appsCenter.busy || appsCenter.mcpCatalogLoading)
                    }
                }
            }
            if let catalogError = appsCenter.mcpCatalogError {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "目录同步提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                    Text(catalogError)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.warningText)
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "调用方式", icon: "play.rectangle.on.rectangle.fill", iconTint: .blue) {
                Picker("调用方式", selection: $inspectorMode) {
                    Text("调用工具 (tools/call)").tag("tools/call")
                    Text("读取资源 (resources/read)").tag("resources/read")
                    Text("列出工具 (tools/list)").tag("tools/list")
                    Text("列出资源 (resources/list)").tag("resources/list")
                    Text("原始 JSON-RPC 2.0").tag("raw")
                }
                .labelsHidden()
                .frame(minWidth: 0, idealWidth: 220, maxWidth: 280)
            }

            if inspectorMode == "tools/call" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "选择 MCP 工具", icon: "wrench.and.screwdriver.fill", iconTint: .purple) {
                    if tools.isEmpty {
                        Text("暂无已同步工具，请先开启 MCP 并点击「刷新目录」")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                    } else {
                        Picker("工具", selection: $selectedTool) {
                            ForEach(tools) { item in
                                Text(item.displayLabel).tag(item.id)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 0, idealWidth: 280, maxWidth: 360)
                        .onChange(of: selectedTool) { _, next in
                            if let found = tools.first(where: { $0.id == next }) {
                                toolArgsJSON = found.sampleArgsJSON
                            }
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "工具参数 (JSON)", icon: "curlybraces", iconTint: .teal) {
                    TextEditor(text: $toolArgsJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minWidth: 0, idealWidth: 320, maxWidth: .infinity)
                        .frame(height: 84)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                }
            } else if inspectorMode == "resources/read" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "选择 MCP 资源 URI", icon: "book.closed.fill", iconTint: .indigo) {
                    if resources.isEmpty {
                        Text("暂无已同步资源，请先开启 MCP 并点击「刷新目录」")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                    } else {
                        Picker("资源 URI", selection: $selectedURI) {
                            ForEach(resources) { res in
                                Text(res.displayLabel).tag(res.uri)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 0, idealWidth: 280, maxWidth: 360)
                    }
                }
            } else if inspectorMode == "raw" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "原始 JSON-RPC 报文", icon: "doc.text", iconTint: .orange) {
                    TextEditor(text: $rawRPCJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minWidth: 0, idealWidth: 320, maxWidth: .infinity)
                        .frame(height: 96)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                }
            }

            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "执行调试请求", icon: "paperplane.fill", iconTint: .green) {
                HStack(spacing: 8) {
                    if let res = appsCenter.lastMCPDebugResult {
                        StatusBadge(
                            isOnline: !res.isError,
                            text: "\(res.isError ? "错误" : "成功") · \(res.durationMs) ms"
                        )
                    }
                    Button(appsCenter.busy ? "执行中…" : "发送 MCP 请求") {
                        runMCPDebug()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy || (inspectorMode == "tools/call" && selectedTool.isEmpty) || (inspectorMode == "resources/read" && selectedURI.isEmpty))
                }
            }

            if let res = appsCenter.lastMCPDebugResult {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("响应 JSON 预览 (\(res.durationMs) ms)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IsleTheme.secondaryText)
                        Spacer()
                        Button("复制响应") {
                            copyText(res.responseJson, notice: "已复制 MCP 响应 JSON")
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(res.responseJson)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }

    private var gatewayProbeSection: some View {
        AppleSettingsGroup(
            title: "轻应用网关 HTTP 探针 (Gateway Probe)",
            footer: "向指定插件发送合成 HTTP 请求（自动唤醒按需实例并注入 X-LightIsle-Proxy-Secret 与测试身份头），用于排查插件 502、启动超时或路由错误。"
        ) {
            AppleSettingsRow(title: "目标插件与请求路径", icon: "waveform.path.ecg.rectangle", iconTint: .teal) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        probeAppPicker
                            .frame(minWidth: 100, idealWidth: 160, maxWidth: 220)
                        probeMethodPicker
                            .frame(width: 76)
                        probePathField
                            .frame(minWidth: 90, idealWidth: 130, maxWidth: 200)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            probeAppPicker
                                .frame(minWidth: 0, idealWidth: 180, maxWidth: .infinity)
                            probeMethodPicker
                                .frame(width: 76)
                        }
                        probePathField
                            .frame(minWidth: 0, maxWidth: .infinity)
                    }
                }
            }
            if probeMethod == "POST" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "POST 请求体", subtitle: "可选 JSON 或纯文本载荷，透传至插件网关", icon: "text.alignleft", iconTint: .blue) {
                    TextField("例如 {\"hello\":\"world\"}", text: $probeBody)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: 0, idealWidth: 280, maxWidth: .infinity)
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "模拟身份与探针执行", icon: "person.text.rectangle", iconTint: .indigo) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        probeRolePicker
                            .frame(width: 150)
                        probeStatusBadge
                        probeActionButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            probeRolePicker
                                .frame(minWidth: 0, idealWidth: 150, maxWidth: .infinity)
                            probeActionButton
                        }
                        probeStatusBadge
                    }
                }
            }

            if let probe = appsCenter.lastProbeResult {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("探针结果：\(probe.method) \(probe.targetPath) → HTTP \(probe.statusCode) (\(probe.durationMs) ms · 状态: \(probe.status))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IsleTheme.secondaryText)
                        if probe.truncated == true {
                            IsleStatusPill(text: "已截断预览", tone: .warning)
                        }
                    }
                    if let probeErr = probe.error, !probeErr.isEmpty {
                        Text("网关错误：\(probeErr)")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.warningText)
                            .textSelection(.enabled)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(probe.bodyPreview.isEmpty ? "（响应体为空）" : probe.bodyPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxHeight: 160)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }

    private var probeAppPicker: some View {
        Picker("插件", selection: $probeAppID) {
            if appsCenter.apps.isEmpty {
                Text("暂无插件").tag("")
            }
            ForEach(appsCenter.apps) { app in
                Text("\(app.name) (\(app.id))").tag(app.id)
            }
        }
        .labelsHidden()
    }

    private var probeMethodPicker: some View {
        Picker("方法", selection: $probeMethod) {
            Text("GET").tag("GET")
            Text("POST").tag("POST")
            Text("HEAD").tag("HEAD")
        }
        .labelsHidden()
    }

    private var probePathField: some View {
        TextField("/ 或 /api/health", text: $probePath)
            .liquidInput()
            .font(.system(size: 12, design: .monospaced))
    }

    private var probeRolePicker: some View {
        Picker("角色", selection: $probeRole) {
            Text("管理员 (admin)").tag("admin")
            Text("普通成员 (member)").tag("member")
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var probeStatusBadge: some View {
        if let probe = appsCenter.lastProbeResult {
            StatusBadge(
                isOnline: (200..<400).contains(probe.statusCode),
                text: "HTTP \(probe.statusCode) · \(probe.durationMs) ms"
            )
        }
    }

    private var probeActionButton: some View {
        Button(appsCenter.busy ? "探测中…" : "发送探针请求") {
            guard !probeAppID.isEmpty else { return }
            appsCenter.probeApp(
                appID: probeAppID,
                method: probeMethod,
                path: probePath,
                body: probeMethod == "POST" ? probeBody : "",
                role: probeRole
            )
        }
        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
        .disabled(appsCenter.busy || probeAppID.isEmpty)
    }

    private func syncSelectedCatalogItems() {
        let tools = appsCenter.discoveredMCPTools
        if !tools.isEmpty, !tools.contains(where: { $0.id == selectedTool }) {
            let first = tools[0]
            selectedTool = first.id
            toolArgsJSON = first.sampleArgsJSON
        }
        let resources = appsCenter.discoveredMCPResources
        if !resources.isEmpty, !resources.contains(where: { $0.uri == selectedURI }) {
            selectedURI = resources[0].uri
        }
    }

    private func runMCPDebug() {
        switch inspectorMode {
        case "tools/call":
            appsCenter.executeMCPDebug(
                method: "tools/call",
                tool: selectedTool,
                uri: "",
                argsJSON: toolArgsJSON,
                rawRPC: ""
            )
        case "resources/read":
            appsCenter.executeMCPDebug(
                method: "resources/read",
                tool: "",
                uri: selectedURI,
                argsJSON: "{}",
                rawRPC: ""
            )
        case "raw":
            appsCenter.executeMCPDebug(
                method: "",
                tool: "",
                uri: "",
                argsJSON: "{}",
                rawRPC: rawRPCJSON
            )
        default:
            appsCenter.executeMCPDebug(
                method: inspectorMode,
                tool: "",
                uri: "",
                argsJSON: "{}",
                rawRPC: ""
            )
        }
    }

    private func copyText(_ text: String, notice: String) {
        PasteboardHelper.copy(text)
        copiedBanner = notice
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if copiedBanner == notice { copiedBanner = nil }
        }
    }
}
