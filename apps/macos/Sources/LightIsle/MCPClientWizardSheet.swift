import AppKit
import SwiftUI

struct MCPClientWizardSheet: View {
    @ObservedObject var appsCenter: NativeAppsModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case gemini = "Gemini 桌面端"
        case claude = "Claude Desktop"
        case cursor = "Cursor"
        case cloud = "局域网 / Cloud MCP"

        var id: String { rawValue }
    }

    private enum GeminiCopy {
        static let serverName = "轻屿 LightIsle"
        static let description = "管理轻屿私有空间的文件、时光相册、私人影院、下载任务与家庭轻应用"
        static let localCommand = "/Applications/LightIsle.app/Contents/Resources/core/lightisled mcp"
    }

    @State private var selectedTab: Tab = .gemini
    @State private var copiedKey: String?
    @State private var copyFeedback: String?

    private var snap: NativeMCPConfigSnapshot { appsCenter.mcp }

    private var effectiveCommand: String {
        let trimmed = snap.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? GeminiCopy.localCommand : trimmed
    }

    private var effectiveHttpUrl: String {
        if let lan = snap.lanHttpUrl, !lan.isEmpty { return lan }
        if !snap.localHttpUrl.isEmpty { return snap.localHttpUrl }
        return "http://127.0.0.1:16666/api/v2/mcp"
    }

    private var effectiveSseUrl: String {
        if let sse = snap.lanSseUrl, !sse.isEmpty { return sse }
        return effectiveHttpUrl + "/sse"
    }

    private var tokenPlaceholder: String {
        if let token = snap.mcpToken, !token.isEmpty { return token }
        return "<开启服务后自动生成 Token>"
    }

    private var claudeJSON: String {
        """
        {
          "mcpServers": {
            "lightisle": {
              "command": "/Applications/LightIsle.app/Contents/Resources/core/lightisled",
              "args": [
                "mcp"
              ]
            }
          }
        }
        """
    }

    private var cursorJSON: String {
        if snap.mcpLanEnabled {
            return """
            {
              "mcpServers": {
                "lightisle": {
                  "command": "/Applications/LightIsle.app/Contents/Resources/core/lightisled",
                  "args": [
                    "mcp"
                  ]
                },
                "lightisle-lan": {
                  "type": "streamable-http",
                  "url": "\(effectiveHttpUrl)",
                  "headers": {
                    "Authorization": "Bearer \(tokenPlaceholder)"
                  }
                }
              }
            }
            """
        }
        return claudeJSON
    }

    private var cloudJSON: String {
        """
        {
          "mcpServers": {
            "lightisle-cloud": {
              "type": "streamable-http",
              "url": "\(effectiveHttpUrl)",
              "headers": {
                "Authorization": "Bearer \(tokenPlaceholder)",
                "X-LightIsle-MCP-Token": "\(tokenPlaceholder)"
              }
            }
          }
        }
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            tabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBanner
                    switch selectedTab {
                    case .gemini:
                        geminiSection
                    case .claude:
                        codeSection(
                            title: "Claude Desktop 本机配置（claude_desktop_config.json）",
                            subtitle: "打开 Claude Desktop → Settings → Developer → Edit Config，将以下配置合并进 mcpServers。",
                            key: "claude-json",
                            code: claudeJSON,
                            notice: "已复制 Claude Desktop MCP 配置"
                        )
                    case .cursor:
                        codeSection(
                            title: "Cursor 配置（~/.cursor/mcp.json 或项目级 .cursor/mcp.json）",
                            subtitle: "本机开发推荐使用 stdio 直连；局域网内其他电脑可同时配置 lightisle-lan Streamable HTTP 端点。",
                            key: "cursor-json",
                            code: cursorJSON,
                            notice: "已复制 Cursor MCP 配置"
                        )
                    case .cloud:
                        cloudSection
                    }
                }
                .padding(20)
            }
            Divider()
            footerBar
        }
        .frame(width: 720, height: 610)
        .background(.background)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(IsleFluidPalette.brandViolet)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 客户端接入向导")
                    .font(.headline)
                Text("支持 Gemini 桌面端（本地 MCP / Cloud MCP）、Claude Desktop、Cursor 与标准 Streamable HTTP")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12.5, weight: selectedTab == tab ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selectedTab == tab ? IsleFluidPalette.brandViolet.opacity(0.16) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(selectedTab == tab ? IsleFluidPalette.brandViolet.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !snap.mcpEnabled {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("当前 AI Agent (MCP) 主开关尚未开启，客户端暂无法调用轻屿工具。")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button("立即开启主开关") {
                    appsCenter.setMCPConfig(mcpEnabled: true)
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                .disabled(appsCenter.busy)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        } else if (selectedTab == .gemini || selectedTab == .cloud) && !snap.mcpLanEnabled {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(IsleFluidPalette.brandBlue)
                Text("本机 stdio 已就绪；如需同一局域网或 Cloud MCP 远程连接，请开启「允许局域网 / Cloud MCP 访问」。")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button("开启局域网访问") {
                    appsCenter.setMCPConfig(mcpEnabled: true, mcpLanEnabled: true)
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(appsCenter.busy)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(IsleFluidPalette.brandBlue.opacity(0.09)))
        }
    }

    private var geminiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Gemini 桌面端「设置自定义的关联应用」1:1 填写清单")
                    .font(.subheadline.weight(.semibold))
                Text("在 Gemini 桌面端打开「关联应用 → 添加自定义关联应用」，按下列每一项依次点击复制并粘贴即可完成接入：")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }

            VStack(spacing: 10) {
                wizardCopyRow(
                    label: "选择设置方法",
                    value: "同机选「本地 MCP」，跨设备或远程选「Cloud MCP」",
                    copyValue: "本地 MCP",
                    key: "gemini-method",
                    notice: "已复制设置方法建议"
                )
                wizardCopyRow(
                    label: "服务器名称",
                    value: GeminiCopy.serverName,
                    copyValue: GeminiCopy.serverName,
                    key: "gemini-name",
                    notice: "已复制服务器名称"
                )
                wizardCopyRow(
                    label: "说明",
                    value: GeminiCopy.description,
                    copyValue: GeminiCopy.description,
                    key: "gemini-desc",
                    notice: "已复制服务器说明"
                )
                wizardCopyRow(
                    label: "命令",
                    value: effectiveCommand,
                    copyValue: effectiveCommand,
                    key: "gemini-cmd",
                    notice: "已复制本地 MCP 启动命令",
                    monospaced: true
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("沙盒设置避坑说明（必看）")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text("""
                1. Gemini 桌面端默认开启沙盒，仅放行关联目录、~/.cache 与 /tmp，可能拦截子进程直接读取 ~/Library/Application Support/LightIsle。
                2. 轻屿 Core 已内置 ~/.cache 与 /tmp 本机回环桥接通道：请保持轻屿桌面端/Core 处于运行状态，即可自动绕开目录权限拦截。
                3. 若仍提示无权读取数据目录，可在 Gemini 自定义关联应用的「沙盒设置」中改选受限更少模式，或改用下方的 Cloud MCP（/api/v2/mcp）。
                """)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("局域网 / Cloud MCP 端点与鉴权凭据")
                    .font(.subheadline.weight(.semibold))
                Text("适用于跨设备客户端或 Gemini Cloud MCP，支持 Streamable HTTP（推荐）与 SSE 传输。")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }

            VStack(spacing: 10) {
                wizardCopyRow(
                    label: "Streamable HTTP URL",
                    value: effectiveHttpUrl,
                    copyValue: effectiveHttpUrl,
                    key: "cloud-http",
                    notice: "已复制 Streamable HTTP URL",
                    monospaced: true
                )
                wizardCopyRow(
                    label: "SSE 兼容 URL",
                    value: effectiveSseUrl,
                    copyValue: effectiveSseUrl,
                    key: "cloud-sse",
                    notice: "已复制 SSE 端点 URL",
                    monospaced: true
                )
                wizardCopyRow(
                    label: "Bearer Token",
                    value: tokenPlaceholder,
                    copyValue: snap.mcpToken ?? "",
                    key: "cloud-token",
                    notice: "已复制 MCP Bearer Token",
                    monospaced: true,
                    copyDisabled: (snap.mcpToken ?? "").isEmpty
                )
            }

            codeSection(
                title: "标准 mcpServers（Streamable HTTP）配置片段",
                subtitle: "如通过公网反向代理、Tailscale 或 Cloudflare Tunnel 对外暴露，请确保启用 HTTPS 并妥善保管 Token。",
                key: "cloud-json",
                code: cloudJSON,
                notice: "已复制 Cloud MCP JSON 配置"
            )
        }
    }

    private func wizardCopyRow(
        label: String,
        value: String,
        copyValue: String,
        key: String,
        notice: String,
        monospaced: Bool = false,
        copyDisabled: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IsleTheme.secondaryText)
                Text(value)
                    .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(copiedKey == key ? "已复制" : "复制") {
                performCopy(key: key, text: copyValue, notice: notice)
            }
            .buttonStyle(LiquidButtonStyle(variant: copiedKey == key ? .prominent : .secondary, size: .small))
            .disabled(copyDisabled)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func codeSection(title: String, subtitle: String, key: String, code: String, notice: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
                Button(copiedKey == key ? "已复制" : "复制配置 JSON") {
                    performCopy(key: key, text: code, notice: notice)
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
            }

            ScrollView([.horizontal, .vertical]) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 160, maxHeight: 240)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private var footerBar: some View {
        HStack {
            if let copyFeedback {
                Label(copyFeedback, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.successText)
            } else {
                Text("所有字段可直接复制使用，更改开关会实时同步到轻屿 Core")
                    .font(.caption)
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            Spacer()
            if !snap.mcpPrompt.isEmpty {
                Button("复制接入提示词") {
                    performCopy(key: "prompt", text: snap.mcpLanEnabled && !snap.lanMcpPrompt.isEmpty ? snap.lanMcpPrompt : snap.mcpPrompt, notice: "已复制 MCP 接入提示词")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }
            Button("完成") { dismiss() }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func performCopy(key: String, text: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedKey = key
        copyFeedback = notice
    }
}
