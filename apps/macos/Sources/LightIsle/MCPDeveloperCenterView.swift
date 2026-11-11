import AppKit
import SwiftUI

struct MCPDeveloperCenterView: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @State private var revealToken = false
    @State private var copiedBanner: String?

    // MCP Inspector State
    @State private var inspectorMode = "tools/call"
    @State private var selectedTool = "lightisle_get_environment"
    @State private var selectedURI = "lightisle://specs/plugin-v2"
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

    private static let allTools: [(id: String, label: String, sampleArgs: String)] = [
        ("lightisle_get_health", "[系统] lightisle_get_health · 服务状态与版本", "{}"),
        ("lightisle_get_system", "[系统] lightisle_get_system · Mac CPU/内存实时状态", "{}"),
        ("lightisle_get_network_info", "[系统] lightisle_get_network_info · 本机网络与网关", "{}"),
        ("lightisle_clear_cache", "[系统] lightisle_clear_cache · 清理缩略图与瓦片缓存", "{\n  \"categories\": [\"all\"]\n}"),
        ("lightisle_get_audit_history", "[审计] lightisle_get_audit_history · 查询操作与 MCP 审计", "{\n  \"limit\": 20\n}"),
        ("lightisle_list_disks", "[磁盘] lightisle_list_disks · 物理磁盘与挂载状态", "{}"),
        ("lightisle_list_roots", "[存储] lightisle_list_roots · 存储根与 generation", "{}"),
        ("lightisle_get_my_storage", "[存储] lightisle_get_my_storage · 当前账号存储配额", "{}"),
        ("lightisle_list_files", "[文件] lightisle_list_files · 分页列出目录条目", "{\n  \"rootId\": \"main\",\n  \"path\": \".\",\n  \"limit\": 50\n}"),
        ("lightisle_create_folder", "[文件] lightisle_create_folder · 新建文件夹", "{\n  \"rootId\": \"main\",\n  \"generation\": 1,\n  \"path\": \"AgentFolder\"\n}"),
        ("lightisle_move_to_trash", "[文件] lightisle_move_to_trash · 安全移入回收站", "{\n  \"rootId\": \"main\",\n  \"generation\": 1,\n  \"path\": \"AgentFolder/old.txt\"\n}"),
        ("lightisle_list_trash", "[文件] lightisle_list_trash · 查看回收站条目", "{\n  \"rootId\": \"main\"\n}"),
        ("lightisle_get_photo_status", "[相册] lightisle_get_photo_status · 照片索引状态", "{\n  \"rootId\": \"main\"\n}"),
        ("lightisle_get_cinema_status", "[影视] lightisle_get_cinema_status · 影视索引状态", "{\n  \"rootId\": \"main\"\n}"),
        ("lightisle_list_downloads", "[下载] lightisle_list_downloads · 下载任务列表", "{}"),
        ("lightisle_list_members", "[成员] lightisle_list_members · 家庭成员列表", "{}"),
        ("lightisle_list_automation_tasks", "[自动化] lightisle_list_automation_tasks · 本机脚本列表", "{}"),
        ("lightisle_trigger_automation_task", "[自动化] lightisle_trigger_automation_task · 立即运行脚本", "{\n  \"taskId\": \"daily-report\"\n}"),
        ("lightisle_list_tasks", "[任务] lightisle_list_tasks · 后台任务进度", "{}"),
        ("lightisle_list_alerts", "[告警] lightisle_list_alerts · 活跃系统告警", "{}"),
        ("lightisle_get_environment", "[插件] lightisle_get_environment · 读取运行环境", "{}"),
        ("lightisle_list_managed_apps", "[应用] lightisle_list_managed_apps · 轻应用状态列表", "{}"),
        ("lightisle_control_managed_app", "[应用] lightisle_control_managed_app · 启停/唤醒/重启", "{\n  \"appId\": \"network-pulse\",\n  \"action\": \"restart\"\n}"),
        ("lightisle_list_apps", "[插件] lightisle_list_apps · 列出已安装插件", "{}"),
        ("lightisle_scaffold_app", "[插件] lightisle_scaffold_app · 创建插件脚手架", "{\n  \"id\": \"demo-tool\",\n  \"name\": \"调试示例插件\",\n  \"mode\": \"static\"\n}"),
        ("lightisle_validate_and_reload", "[插件] lightisle_validate_and_reload · 校验并热重载", "{\n  \"id\": \"network-pulse\"\n}"),
        ("lightisle_read_plugin_file", "[插件] lightisle_read_plugin_file · 读取插件文件", "{\n  \"id\": \"network-pulse\",\n  \"path\": \"plugin.json\"\n}"),
        ("lightisle_write_plugin_file", "[插件] lightisle_write_plugin_file · 写入插件文件", "{\n  \"id\": \"demo-tool\",\n  \"path\": \"ui/index.html\",\n  \"content\": \"<!doctype html><html><body>Hello MCP</body></html>\"\n}"),
        ("lightisle_app_action", "[插件] lightisle_app_action · 启停/唤醒/执行Cron", "{\n  \"id\": \"network-pulse\",\n  \"action\": \"reload\"\n}"),
        ("lightisle_get_app_logs", "[插件] lightisle_get_app_logs · 获取插件日志与状态", "{\n  \"id\": \"network-pulse\",\n  \"limit\": 10\n}"),
        ("lightisle_probe_app", "[插件] lightisle_probe_app · 发送网关 HTTP 探针", "{\n  \"id\": \"network-pulse\",\n  \"method\": \"GET\",\n  \"path\": \"/\"\n}")
    ]

    private static let allResources: [(uri: String, label: String)] = [
        ("lightisle://specs/mcp-security", "lightisle://specs/mcp-security · 管理控制与安全审计规范"),
        ("lightisle://specs/plugin-v2", "lightisle://specs/plugin-v2 · 多语言轻应用规范"),
        ("lightisle://specs/ui-theme", "lightisle://specs/ui-theme · Liquid Glass 视觉规范"),
        ("lightisle://specs/automation-v1", "lightisle://specs/automation-v1 · 定时脚本与邮件规范")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            mcpConfigSection
            if let notice = copiedBanner ?? appsCenter.message {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(IsleTheme.successText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }
            if let err = appsCenter.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(IsleTheme.warningText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }
            mcpInspectorSection
            gatewayProbeSection
            callTraceSection
        }
        .onAppear {
            if probeAppID.isEmpty, let first = appsCenter.apps.first?.id {
                probeAppID = first
            }
        }
        .onChange(of: appsCenter.apps) { _, list in
            if probeAppID.isEmpty, let first = list.first?.id {
                probeAppID = first
            }
        }
    }

    private var mcpConfigSection: some View {
        let snap = appsCenter.mcp
        return AppleSettingsGroup(
            title: "全功能管理与开发 MCP 服务（本机 Stdio 与局域网 HTTP/SSE）",
            footer: "本机 AI Agent 可通过 stdio (lightisled mcp) 桥接后台守护进程，局域网设备可通过 Streamable HTTP (/api/v2/mcp) 或 SSE (/api/v2/mcp/sse) 持 Bearer Token 接入，全面读取并管理磁盘存储、文件与安全回收站、相册影视、下载、家庭成员、定时脚本与轻应用。全部调用实时写入 SQLite 审计日志；格式化磁盘、注销存储根、物理粉碎文件与密钥导出已物理隔离禁止。"
        ) {
            AppleSettingsRow(
                title: "允许本机 AI Agent (Stdio MCP) 接入",
                subtitle: "开启后允许本机 Claude Code / Antigravity / Codex / Cursor 调用 lightisled mcp",
                icon: "cpu.fill",
                iconTint: .purple
            ) {
                Toggle("", isOn: Binding(
                    get: { snap.mcpEnabled },
                    set: { appsCenter.setMCPConfig(mcpEnabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(appsCenter.busy)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "允许局域网远程 MCP (HTTP / SSE) 接入",
                subtitle: "允许同一局域网 (192.168/10/172.16) 开发机持 Bearer Token 连接 /api/v2/mcp（需同时开启局域网监听）",
                icon: "network.badge.shield.half.filled",
                iconTint: .blue
            ) {
                Toggle("", isOn: Binding(
                    get: { snap.mcpLanEnabled },
                    set: { appsCenter.setMCPConfig(mcpLanEnabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(appsCenter.busy)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "本机 Stdio 命令",
                subtitle: snap.command.isEmpty ? "lightisled mcp" : snap.command,
                icon: "terminal",
                iconTint: .teal
            ) {
                HStack(spacing: 6) {
                    Button("复制命令") {
                        copyText(snap.command, notice: "已复制本机 Stdio MCP 启动命令")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("复制本机接入提示词") {
                        if !snap.mcpEnabled { appsCenter.setMCPConfig(mcpEnabled: true) }
                        copyText(snap.mcpPrompt, notice: "已复制本机 MCP 接入提示词")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(
                title: "局域网 MCP 端点",
                subtitle: "HTTP: \(snap.lanHttpUrl ?? snap.localHttpUrl)  ·  SSE: \(snap.lanSseUrl ?? (snap.localHttpUrl + "/sse"))",
                icon: "point.3.connected.trianglepath.dotted",
                iconTint: .indigo
            ) {
                HStack(spacing: 6) {
                    Button("复制 HTTP URL") {
                        copyText(snap.lanHttpUrl ?? snap.localHttpUrl, notice: "已复制 MCP HTTP 端点 URL")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("复制局域网接入提示词") {
                        if !snap.mcpLanEnabled { appsCenter.setMCPConfig(mcpEnabled: true, mcpLanEnabled: true) }
                        copyText(snap.lanMcpPrompt, notice: "已复制局域网 MCP 接入提示词")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    Button("复制 mcpServers JSON") {
                        copyText(snap.mcpConfigJson, notice: "已复制 mcpServers JSON 配置")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
            }
            if snap.mcpEnabled {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                let tokenText = snap.mcpToken ?? ""
                let masked = tokenText.count > 12
                    ? "\(tokenText.prefix(6))••••••••••••\(tokenText.suffix(4))"
                    : (tokenText.isEmpty ? "未生成" : "••••••••")
                AppleSettingsRow(
                    title: "MCP Bearer 鉴权 Token",
                    subtitle: revealToken ? tokenText : masked,
                    icon: "key.horizontal.fill",
                    iconTint: .orange
                ) {
                    HStack(spacing: 6) {
                        Button(revealToken ? "隐藏" : "显示") {
                            revealToken.toggle()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("复制 Token") {
                            copyText(tokenText, notice: "已复制 MCP Bearer Token")
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(tokenText.isEmpty)
                        Button("轮换 Token") {
                            appsCenter.rotateMCPToken()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(appsCenter.busy)
                    }
                }
            }
        }
    }

    private var mcpInspectorSection: some View {
        AppleSettingsGroup(
            title: "MCP 交互式调试器 (MCP Inspector)",
            footer: "直接在轻屿内向 MCP Server 发送 JSON-RPC 2.0 请求，验证 9 项内置工具与 3 项规范资源的返回结果与耗时。"
        ) {
            AppleSettingsRow(title: "调用方式", icon: "play.rectangle.on.rectangle.fill", iconTint: .blue) {
                Picker("调用方式", selection: $inspectorMode) {
                    Text("调用工具 (tools/call)").tag("tools/call")
                    Text("读取资源 (resources/read)").tag("resources/read")
                    Text("列出工具 (tools/list)").tag("tools/list")
                    Text("列出资源 (resources/list)").tag("resources/list")
                    Text("原始 JSON-RPC 2.0").tag("raw")
                }
                .labelsHidden()
                .frame(width: 240)
            }

            if inspectorMode == "tools/call" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "选择 MCP 工具", icon: "wrench.and.screwdriver.fill", iconTint: .purple) {
                    Picker("工具", selection: $selectedTool) {
                        ForEach(Self.allTools, id: \.id) { item in
                            Text(item.label).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                    .onChange(of: selectedTool) { _, next in
                        if let found = Self.allTools.first(where: { $0.id == next }) {
                            toolArgsJSON = found.sampleArgs
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "工具参数 (JSON)", icon: "curlybraces", iconTint: .teal) {
                    TextEditor(text: $toolArgsJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 380, height: 84)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                }
            } else if inspectorMode == "resources/read" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "选择 MCP 资源 URI", icon: "book.closed.fill", iconTint: .indigo) {
                    Picker("资源 URI", selection: $selectedURI) {
                        ForEach(Self.allResources, id: \.uri) { res in
                            Text(res.label).tag(res.uri)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                }
            } else if inspectorMode == "raw" {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "原始 JSON-RPC 报文", icon: "doc.text", iconTint: .orange) {
                    TextEditor(text: $rawRPCJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 380, height: 96)
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
                    .disabled(appsCenter.busy)
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
                HStack(spacing: 8) {
                    Picker("插件", selection: $probeAppID) {
                        if appsCenter.apps.isEmpty {
                            Text("暂无插件").tag("")
                        }
                        ForEach(appsCenter.apps) { app in
                            Text("\(app.name) (\(app.id))").tag(app.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    Picker("方法", selection: $probeMethod) {
                        Text("GET").tag("GET")
                        Text("POST").tag("POST")
                        Text("HEAD").tag("HEAD")
                    }
                    .labelsHidden()
                    .frame(width: 80)

                    TextField("/ 或 /api/health", text: $probePath)
                        .liquidInput()
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140)
                }
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "模拟身份与探针执行", icon: "person.text.rectangle", iconTint: .indigo) {
                HStack(spacing: 8) {
                    Picker("角色", selection: $probeRole) {
                        Text("管理员 (admin)").tag("admin")
                        Text("普通成员 (member)").tag("member")
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    if let probe = appsCenter.lastProbeResult {
                        StatusBadge(
                            isOnline: (200..<400).contains(probe.statusCode),
                            text: "HTTP \(probe.statusCode) · \(probe.durationMs) ms"
                        )
                    }

                    Button(appsCenter.busy ? "探测中…" : "发送探针请求") {
                        guard !probeAppID.isEmpty else { return }
                        appsCenter.probeApp(
                            appID: probeAppID,
                            method: probeMethod,
                            path: probePath,
                            body: probeBody,
                            role: probeRole
                        )
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(appsCenter.busy || probeAppID.isEmpty)
                }
            }

            if let probe = appsCenter.lastProbeResult {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                VStack(alignment: .leading, spacing: 6) {
                    Text("探针结果：\(probe.method) \(probe.targetPath) → HTTP \(probe.statusCode) (\(probe.durationMs) ms · 状态: \(probe.status))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IsleTheme.secondaryText)
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

    private var callTraceSection: some View {
        AppleSettingsGroup(
            title: "MCP 实时调用追踪日志 (最近 \(appsCenter.mcpLogs.count) 条)",
            footer: "自动记录本机 stdio、局域网 lan-http / lan-sse 以及上方调试器的最近 50 次 MCP 请求耗时与结果摘要。"
        ) {
            AppleSettingsRow(title: "追踪记录控制", icon: "list.bullet.rectangle.portrait", iconTint: .orange) {
                HStack(spacing: 8) {
                    Button("刷新记录") {
                        appsCenter.refresh()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    Button("清空记录") {
                        appsCenter.clearMCPLogs()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(appsCenter.mcpLogs.isEmpty || appsCenter.busy)
                }
            }

            if appsCenter.mcpLogs.isEmpty {
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "暂无 MCP 调用记录", icon: "tray", iconTint: .secondary) {
                    Text("当 AI Agent 或调试器发起 MCP 请求后会在此实时显示")
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                }
            } else {
                ForEach(appsCenter.mcpLogs.prefix(20)) { entry in
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(
                        title: "\(entry.method)\(entry.target.map { " · \($0)" } ?? "")",
                        subtitle: "[\(entry.transport)] \(entry.remoteAddr ?? "local") · \(entry.timestamp)",
                        icon: entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill",
                        iconTint: entry.isError ? .orange : .green
                    ) {
                        Text("\(entry.durationMs) ms")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(entry.isError ? IsleTheme.warningText : IsleTheme.secondaryText)
                    }
                }
            }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedBanner = notice
    }
}
