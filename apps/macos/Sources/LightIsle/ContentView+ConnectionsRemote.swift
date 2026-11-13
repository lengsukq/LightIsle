import SwiftUI
import AppKit

extension ContentView {
    var connectionCloudflareContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(
                title: "Cloudflare Tunnel（可选）",
                footer: "使用本机已安装的 cloudflared 把 NAS 暴露到公网。免费模式每次启动生成随机临时域名，仅供测试；API Key 模式通过你自己的 Cloudflare 账号创建命名隧道并一键绑定域名。Token 只保存在本机钥匙串，不会写入日志。若系统代理拦截，需对 argotunnel.com 放行直连。"
            ) {
                AppleSettingsRow(title: "cloudflared 二进制", icon: "terminal", iconTint: .gray) {
                    Text(tunnelBinaryDescription)
                        .font(.caption)
                        .foregroundStyle(model.tunnelState?.binaryFound == true ? IsleTheme.secondaryText : IsleTheme.warningText)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "隧道状态",
                    subtitle: model.prefersTunnelMode.summaryLabel,
                    icon: "point.topleft.down.curvedto.point.bottomright.up",
                    iconTint: .teal
                ) {
                    HStack(spacing: 10) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(tunnelStatusDescription)
                                .font(.caption)
                                .foregroundStyle(tunnelStatusColor)
                            if let lastLine = model.tunnelState?.lastLine, !lastLine.isEmpty {
                                Text(lastLine)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .lineLimit(1)
                                    .help(lastLine)
                            }
                        }
                        if model.tunnelState?.status == "online" || model.tunnelState?.status == "starting" || model.prefersTunnelMode != .off {
                            Button("停止") {
                                model.stopTunnel()
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online)
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "免费快速隧道", subtitle: "无需 Cloudflare 账号；随机 trycloudflare.com 域名，每次重启都会变化。", icon: "bolt.fill", iconTint: .yellow) {
                    HStack(spacing: 8) {
                        Button(model.tunnelState?.mode == "quick" && model.tunnelState?.status != "stopped" ? "停止" : "启动") {
                            if model.tunnelState?.mode == "quick", model.tunnelState?.status != "stopped" {
                                model.stopTunnel()
                            } else {
                                model.startQuickTunnel()
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online)
                        if let url = model.tunnelState?.url, model.tunnelState?.mode == "quick" {
                            Text(url)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(IsleTheme.accent)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            IsleIconButton(
                                icon: "doc.on.doc",
                                variant: .borderless,
                                help: "复制临时域名"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                                showNotice("已复制临时域名")
                            }
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "API Key 模式", subtitle: "在二级页面填写 Cloudflare API Token、创建/删除隧道并一键绑定公共主机名（自动配置 DNS 与路由）。", icon: "key.fill", iconTint: .indigo) {
                    Button("管理隧道与域名") {
                        requestLocalNavigation { presentingTunnelManager = true }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    .disabled(model.state != .online)
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "高级：运行已有隧道 Token", subtitle: "已通过 Cloudflare 控制台创建的隧道，可直接粘贴其 Token 启动。", icon: "authenticator", iconTint: .purple) {
                    HStack(spacing: 8) {
                        SecureField("粘贴隧道 Token", text: $manualTunnelToken)
                            .liquidInput()
                            .frame(width: 210)
                            .font(.system(size: 11, design: .monospaced))
                        Button("启动") {
                            model.runTunnelWithToken(manualTunnelToken)
                            manualTunnelToken = ""
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(manualTunnelToken.trimmingCharacters(in: .whitespaces).count < 16 || model.state != .online)
                    }
                }
                if let error = model.tunnelState?.error, !error.isEmpty {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "隧道异常", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                        Text(tunnelErrorDescription(error))
                            .font(.caption)
                            .foregroundStyle(IsleTheme.errorText)
                            .textSelection(.enabled)
                    }
                }
            }
            .task { model.refreshTunnel() }

            IsleQuickJumpBar(items: [
                IsleQuickJumpItem("FRP 穿透", icon: "point.topleft.down.curvedto.point.bottomright.up", tint: .indigo, help: "切换查看或配置自建 FRP 内网穿透") {
                    requestLocalNavigation {
                        editingFRPConfig = false
                        presentingTunnelManager = false
                        connectionDetail = .frp
                    }
                },
                IsleQuickJumpItem("Tailscale 异地直连", icon: "network.badge.shield.half.filled", tint: .blue, help: "查看免公网域名点对点私人组网方式") {
                    requestLocalNavigation {
                        editingFRPConfig = false
                        presentingTunnelManager = false
                        connectionDetail = .remote
                    }
                },
                IsleQuickJumpItem("局域网连接", icon: "wifi", tint: .teal, help: "查看局域网加密验证与端口配置") {
                    requestLocalNavigation {
                        editingFRPConfig = false
                        presentingTunnelManager = false
                        connectionDetail = .lan
                    }
                }
            ])
        }
    }

    var connectionFrpContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(
                title: "FRP 穿透（可选）",
                footer: "LightIsle 不附带 FRP 程序。一键下载的是官方 frpc 客户端，不包含 frps 服务端。请先准备自己的 FRP 服务端，再通过可视化配置页填写连接和代理规则。FRP 不会自动连接公网；尤其不要把未加密的 HTTP 服务直接映射到公网。"
            ) {
                AppleSettingsRow(title: "FRP 客户端", subtitle: "官方 frpc · macOS Apple Silicon · SHA-256 校验后安装", icon: "arrow.down.circle", iconTint: .cyan) {
                    HStack(spacing: 8) {
                        Text(model.frpState?.installed == true
                             ? "已安装 \(model.frpState?.version.isEmpty == false ? "v\(model.frpState?.version ?? "")" : "（版本未知）")"
                             : "未安装")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        if model.frpState?.status == "installing" {
                            ProgressView().controlSize(.small)
                            Text("v\(model.frpState?.installingVersion ?? "")")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "可选版本", subtitle: "自动获取官方发行版本；切换版本不会修改 frpc.toml。", icon: "shippingbox", iconTint: .blue) {
                    HStack(spacing: 8) {
                        Picker("FRP 版本", selection: Binding(
                            get: { model.selectedFRPVersion },
                            set: { model.selectFRPVersion($0) }
                        )) {
                            Text("请选择版本").tag("")
                            ForEach(model.frpVersions) { release in
                                Text(release.displayName).tag(release.version)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 184)
                        .disabled(model.frpVersionsLoading || model.frpVersions.isEmpty ||
                                  model.frpState?.status == "installing")
                        if model.frpVersionsLoading {
                            ProgressView().controlSize(.small)
                        }
                        IsleIconButton(
                            icon: "arrow.clockwise",
                            variant: .borderless,
                            help: "获取并刷新可安装的 FRP 官方版本"
                        ) { model.refreshFRPVersions() }
                        .disabled(model.state != .online || model.frpVersionsLoading)
                        if let selected = model.frpVersions.first(where: { $0.version == model.selectedFRPVersion }) {
                            Button(model.frpState?.installed == true ? "更换版本" : "下载安装") {
                                model.installFRP()
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || !selected.installable ||
                                      model.frpState?.status == "running" ||
                                      model.frpState?.status == "restarting" ||
                                      model.frpState?.status == "installing")
                        }
                    }
                }
                if !model.frpVersions.isEmpty {
                    AppleSettingsRow(title: "发行信息", icon: "info.circle", iconTint: .gray) {
                        Text("共 \(model.frpVersions.count) 个可安装版本 · 默认选择最新稳定版")
                            .font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "连接配置", subtitle: "在二级页面设置 FRP 服务端、鉴权 Token 和代理规则；保存后需重启 frpc 生效。", icon: "doc.text", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        Button("配置连接与代理") { requestLocalNavigation {
                            frpEditorHasChanges = false
                            editingFRPConfig = true
                        } }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.frpState?.configPath == nil)
                        if let path = model.frpState?.configPath {
                            IsleIconButton(
                                icon: "folder",
                                variant: .borderless,
                                help: "在访达中显示 frpc.toml 配置文件"
                            ) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(
                    title: "FRP 连接",
                    subtitle: "保存开启或关闭的选择，重启后自动恢复。区分进程、服务端登录和代理注册；修改配置后需重新启动。",
                    icon: "network",
                    iconTint: .teal
                ) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.frpState?.connectionConfirmed == true ? Color.green :
                                  model.frpState?.status == "error" ? Color.red : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(model.frpState?.statusDescription ?? "等待 Core 就绪…")
                            .font(.caption)
                            .foregroundStyle(IsleTheme.secondaryText)
                        if let pid = model.frpState?.pid, pid > 0 {
                            Text("PID \(pid)").font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                        }
                        Toggle("启用 FRP 穿透", isOn: Binding(
                            get: {
                                model.frpState?.status == "running" ||
                                model.frpState?.status == "restarting" ||
                                (model.prefersFRPEnabled && !model.frpAutoRestoreAttempted && model.frpState == nil)
                            },
                            set: { model.setFRPEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.state != .online ||
                                  model.frpState?.installed != true ||
                                  model.frpState?.status == "installing")
                        if model.frpState?.status == "running" || model.frpState?.status == "restarting" {
                            Button(model.frpState?.status == "restarting" ? "取消重试" : "停止") { model.stopFRP() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        } else {
                            Button("启动") { model.startFRP() }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(model.state != .online ||
                                          model.frpState?.installed != true ||
                                          model.frpState?.status == "installing")
                        }
                        IsleIconButton(
                            icon: "arrow.clockwise",
                            help: "刷新 FRP 进程与代理注册状态"
                        ) { model.refreshFRP() }
                        .disabled(model.state != .online)
                    }
                }
                if let frp = model.frpState {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "连接诊断", icon: "waveform.path.ecg", iconTint: .blue) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(frp.connectionDescription)
                                .font(.caption)
                                .foregroundStyle(frp.connectionConfirmed ? IsleTheme.successText : IsleTheme.secondaryText)
                            if let event = frp.lastLine, !event.isEmpty {
                                Text(event).font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                            }
                            if !frp.installed {
                                Text("尚未安装 frpc。请先获取版本并下载安装，然后配置 frps 服务端与至少一条代理规则。")
                                    .font(.caption2).foregroundStyle(IsleTheme.warningText)
                            }
                        }
                    }
                }
                if let issue = model.frpError ?? model.frpState?.error {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "操作提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(frpErrorDescription(issue))
                            .font(.caption)
                            .foregroundStyle(IsleTheme.warningText)
                            .textSelection(.enabled)
                    }
                }
            }
            .task {
                model.refreshFRP()
            }

            IsleQuickJumpBar(items: [
                IsleQuickJumpItem("Cloudflare Tunnel", icon: "cloud", tint: .cyan, help: "对比或切换零公网服务器配置的内网穿透方案") {
                    requestLocalNavigation {
                        editingFRPConfig = false
                        presentingTunnelManager = false
                        connectionDetail = .cloudflare
                    }
                },
                IsleQuickJumpItem("局域网连接与 HTTPS", icon: "wifi", tint: .teal, help: "检查加密开关与当前监听端口") {
                    requestLocalNavigation {
                        editingFRPConfig = false
                        presentingTunnelManager = false
                        connectionDetail = .lan
                    }
                },
                IsleQuickJumpItem("Tailscale 异地直连", icon: "network.badge.shield.half.filled", tint: .indigo, help: "免公网端口的点对点加密私人组网") {
                    requestLocalNavigation {
                        editingFRPConfig = false
                        presentingTunnelManager = false
                        connectionDetail = .remote
                    }
                }
            ])
        }
    }
}
