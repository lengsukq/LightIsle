import SwiftUI
import AppKit

/// Native second-level FRP configuration editor. It never sends frps secrets
/// to the Web API or remote Flutter clients.
struct FRPConfigEditorView: View {
    let path: String
    let isRunning: Bool
    let onBack: () -> Void
    let onOpenOriginal: () -> Void
    let onDirtyChange: (Bool) -> Void

    @State private var document: FRPConfigDocument?
    @State private var draft = FRPConfigDraft()
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var revealToken = false
    @State private var confirmDiscard = false

    private var hasChanges: Bool { document.map { draft != $0.draft } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(IsleTheme.errorText)
                    .textSelection(.enabled)
            }
            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(IsleTheme.successText)
            }
            if let document {
                serverFields
                proxyFields
                AppleSettingsGroup(title: "保存与生效", footer: "只修改这台 Mac 的配置文件；运行中的 frpc 不会自动重启。关闭此页不会自动保存。") {
                    AppleSettingsRow(title: "配置文件", subtitle: "本地独立文件，不上传账号、Token 或代理参数。", icon: "doc.text", iconTint: .gray) {
                        HStack(spacing: 10) {
                            Button("高级编辑 TOML") { onOpenOriginal() }
                                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            Button("在 Finder 中查看") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }.buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                        }
                    }
                    if isRunning {
                        AppleSettingsRow(title: "正在运行", subtitle: "保存后需要返回 FRP 页面，先停止再启动才能应用新配置。", icon: "arrow.clockwise", iconTint: .orange) {
                            Text("待重启生效").font(.caption).foregroundStyle(IsleTheme.warningText)
                        }
                    }
                    AppleSettingsRow(title: "保存设置", icon: "square.and.arrow.down", iconTint: .blue) {
                        HStack(spacing: 10) {
                            if hasChanges {
                                IsleStatusPill(text: "有未保存修改", tone: .warning, showDot: true)
                            }
                            Button("保存配置") { save(document: document) }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .keyboardShortcut("s", modifiers: .command)
                                .disabled(!hasChanges)
                            Button("放弃修改") { draft = document.draft; savedMessage = nil; errorMessage = nil }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(!hasChanges)
                        }
                    }
                }
            } else {
                AppleSettingsGroup(title: "无法读取配置", footer: "配置文件必须位于 LightIsle 的本机应用数据目录，且不能是软链接。") {
                    AppleSettingsRow(title: "重新载入", icon: "arrow.clockwise", iconTint: .orange) {
                        HStack(spacing: 10) {
                            Button("重试") { load() }.buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            Button("高级编辑原文件") { onOpenOriginal() }
                                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: hasChanges) { _, dirty in onDirtyChange(dirty) }
        .confirmationDialog("放弃尚未保存的 FRP 配置？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改并返回", role: .destructive) { onBack() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("已填写的服务端地址、代理与 Token 修改不会保存。") }
    }

    private var serverFields: some View {
        AppleSettingsGroup(
            title: "FRP 服务端",
            footer: "填写您已有的 frps 服务端信息。LightIsle 不会创建 frps 服务器，Token 仅保存在 Mac 本地配置文件中。"
        ) {
            AppleSettingsRow(title: "服务端地址", subtitle: "IP 或域名，不需要填写 http://", icon: "server.rack", iconTint: .blue) {
                TextField("frps.example.com", text: $draft.serverAddress)
                    .liquidInput().frame(width: 250)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "服务端端口", subtitle: "frps bindPort，通常为 7000。", icon: "network", iconTint: .cyan) {
                TextField("7000", text: $draft.serverPort)
                    .liquidInput().frame(width: 100)
            }
            IsleGroupSpacing(height: 4).padding(.leading, 14)
            AppleSettingsRow(title: "鉴权 Token", subtitle: "请填写与 frps 一致的 Token。", icon: "key.fill", iconTint: .indigo) {
                HStack(spacing: 8) {
                    Group {
                        if revealToken {
                            TextField("FRP Token", text: $draft.token)
                        } else {
                            SecureField("FRP Token", text: $draft.token)
                        }
                    }.liquidInput().frame(width: 250)
                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                    .help(revealToken ? "隐藏 Token" : "显示 Token")
                }
            }
        }
    }

    private var proxyFields: some View {
        AppleSettingsGroup(
            title: "代理规则",
            footer: "TCP / UDP 通过远程端口访问；HTTP / HTTPS 通过 frps 配置的虚拟主机端口及域名访问。任何映射到公网的服务都需要自行做好身份验证和加密。"
        ) {
            if draft.proxies.isEmpty {
                AppleSettingsRow(title: "暂无可视化代理规则", subtitle: "可以直接创建一条常用规则。", icon: "point.3.connected.trianglepath.dotted", iconTint: .gray) {
                    Text("未设置").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
            }
            ForEach($draft.proxies) { $proxy in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .foregroundStyle(IsleTheme.accent)
                        Text(proxy.name.isEmpty ? "新代理规则" : proxy.name).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("移除") {
                            draft.proxies.removeAll(where: { $0.id == proxy.id })
                            savedMessage = nil
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("名称").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            TextField("my-service", text: $proxy.name).liquidInput()
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("协议").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            Picker("协议", selection: $proxy.type) {
                                Text("TCP").tag("tcp")
                                Text("UDP").tag("udp")
                                Text("HTTP").tag("http")
                                Text("HTTPS").tag("https")
                            }.labelsHidden().frame(width: 125)
                        }
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("本地 IP").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            TextField("127.0.0.1", text: $proxy.localIP).liquidInput()
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("本地端口").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            TextField("16666", text: $proxy.localPort).liquidInput().frame(width: 120)
                        }
                    }
                    if proxy.isWeb {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("访问域名（多个用英文逗号分隔）").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            TextField("nas.example.com", text: $proxy.domains).liquidInput()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("远程端口（frps 侧）").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                            TextField("6000", text: $proxy.remotePort).liquidInput().frame(width: 120)
                        }
                    }
                }
                .padding(15)
                .modifier(IsleEmbossedSurface(cornerRadius: 14))
            }
            if draft.advancedProxyCount > 0 {
                AppleSettingsRow(
                    title: "高级代理规则",
                    subtitle: "另有 \(draft.advancedProxyCount) 条暂不支持可视化的规则，保存时原样保留。",
                    icon: "doc.text.magnifyingglass", iconTint: .orange
                ) {
                    Text("不会修改").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
            }
            AppleSettingsRow(title: "添加代理", icon: "plus.circle", iconTint: .teal) {
                Button("新增规则") {
                    draft.proxies.append(FRPProxyDraft())
                    savedMessage = nil
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }
        }
    }

    private func load() {
        do {
            let loaded = try FRPConfigFile.load(path: path)
            document = loaded
            draft = loaded.draft
            errorMessage = nil
            savedMessage = nil
            revealToken = false
        } catch {
            errorMessage = error.localizedDescription
            document = nil
        }
    }

    private func save(document: FRPConfigDocument) {
        do {
            try FRPConfigFile.save(path: path, document: document, draft: draft)
            let updated = try FRPConfigFile.load(path: path)
            self.document = updated
            self.draft = updated.draft
            errorMessage = nil
            savedMessage = isRunning ? "已保存。请返回 FRP 页面，停止并重新启动后生效。" : "配置已保存到 Mac 本地。"
            revealToken = false
        } catch {
            errorMessage = error.localizedDescription
            savedMessage = nil
        }
    }
}
