import SwiftUI
import AppKit

extension ContentView {
    var servicesView: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let detail = connectionDetail {
                if detail == .frp && editingFRPConfig {
                    FRPConfigEditorView(
                        path: model.frpState?.configPath ?? "",
                        isRunning: model.frpState?.status == "running",
                        onBack: { editingFRPConfig = false; frpEditorHasChanges = false },
                        onOpenOriginal: { model.openFRPConfig() },
                        onDirtyChange: { frpEditorHasChanges = $0 }
                    )
                    .disabled(model.isPresentationPreview)
                } else if detail == .cloudflare && presentingTunnelManager {
                    TunnelManagementView(model: model)
                        .disabled(model.isPresentationPreview)
                } else {
                    Group {
                        switch detail {
                        case .local: connectionLocalContent
                        case .lan: connectionLanContent
                        case .sharing: connectionSharingContent
                        case .remote: connectionRemoteContent
                        case .cloudflare: connectionCloudflareContent
                        case .frp: connectionFrpContent
                        }
                    }.disabled(model.isPresentationPreview)
                }
            } else {
                connectionWorkbenchCard
                IsleDestinationGrid {
                    ForEach(Array(ConnectionDetail.allCases.enumerated()), id: \.element.id) { index, detail in
                        let status = connectionBadge(for: detail)
                        IsleDestinationRow(
                            title: detail.rawValue,
                            subtitle: detail.subtitle,
                            icon: detail.icon,
                            badge: status.0,
                            badgeTone: status.1,
                            iconTint: connectionIconTint(for: detail)
                        ) {
                            requestLocalNavigation { connectionDetail = detail }
                        }.modifier(IsleCascade(index: index))
                    }
                }
            }
        }
    }
    private func connectionIconTint(for detail: ConnectionDetail) -> Color {
        switch detail {
        case .local: return IsleFluidPalette.brandBlue
        case .lan: return IsleFluidPalette.brandIndigo
        case .sharing: return .orange
        case .remote: return IsleFluidPalette.brandViolet
        case .cloudflare: return IsleFluidPalette.brandCyan
        case .frp: return .teal
        }
    }
    private func connectionBadge(for detail: ConnectionDetail) -> (String, IsleStatusTone) {
        switch detail {
        case .local:
            return (model.state == .online ? "正在运行" : model.state.label, model.state == .online ? .success : .warning)
        case .lan:
            if model.remoteBusy { return ("连接中…", .neutral) }
            if model.isRemoteEnabled {
                return (model.remoteAddress?.hasPrefix("https://") == true ? "已启用 · HTTPS" : "已启用 · HTTP", .success)
            }
            if model.remoteError != nil { return ("连接异常", .error) }
            return ("未启用", .neutral)
        case .sharing:
            let smbOn = model.smbState?.serviceEnabled ?? (model.smbListening == true)
            let count = model.smbState?.shares.count ?? 0
            if smbOn { return (count > 0 ? "已开启 · \(count) 个共享" : "已开启", .success) }
            return ("未开启", .neutral)
        case .remote:
            return ("Tailscale / EasyTier", .neutral)
        case .cloudflare:
            if model.tunnelState?.status == "online" { return ("运行中", .success) }
            if model.tunnelState?.status == "starting" { return ("启动中…", .warning) }
            if let err = model.tunnelState?.error, !err.isEmpty { return ("隧道异常", .error) }
            if model.tunnelAPITokenConfigured { return ("已配置 Token", .accent) }
            return ("按需开启", .neutral)
        case .frp:
            if model.frpState?.connectionConfirmed == true { return ("已连接", .success) }
            if model.frpState?.status == "running" || model.frpState?.status == "restarting" { return ("连接中…", .warning) }
            if model.frpState?.status == "error" { return ("连接异常", .error) }
            if model.frpState?.installed == true { return ("已安装", .neutral) }
            return ("未安装", .neutral)
        }
    }
    var connectionWorkbenchCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Label("连接地址与快速控制", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.88))
                    IsleStatusPill(
                        text: model.state.label,
                        tone: model.state == .online ? .success : .warning,
                        showDot: true
                    )
                    Spacer()
                    IsleDetailInfo(
                        title: "访问地址",
                        rows: [
                            ("本机", model.endpoint?.absoluteString ?? "未运行"),
                            ("局域网", model.remoteAddress ?? "未启用"),
                            ("验证信息", model.remoteAddress?.hasPrefix("http://") == true ? "HTTP 不使用证书" : model.remoteFingerprint ?? "未取得")
                        ]
                    )
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("本机访问", systemImage: "desktopcomputer")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IsleFluidPalette.brandBlue)
                            Spacer()
                            IsleStatusPill(text: "端口 \(model.endpoint?.port ?? model.preferredLocalPort)", tone: .neutral)
                        }
                        HStack(spacing: 8) {
                            Text(model.endpoint?.absoluteString ?? "等待核心服务就绪")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            if let endpoint = model.endpoint?.absoluteString {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(endpoint, forType: .string)
                                    showNotice("已复制本机访问地址")
                                } label: {
                                    Label("复制", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .help("复制本机访问地址")
                            }
                        }
                        Text("在这台 Mac 上直接打开或通过回环地址访问服务。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(IsleFluidPalette.rim.opacity(0.55), lineWidth: 0.8)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Label("其他设备（局域网）", systemImage: "wifi")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IsleFluidPalette.brandIndigo)
                            Spacer()
                            if model.remoteBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                IsleStatusPill(
                                    text: model.isRemoteEnabled
                                        ? (model.remoteAddress?.hasPrefix("https://") == true ? "HTTPS 加密" : "HTTP 直连")
                                        : "未开启",
                                    tone: model.isRemoteEnabled ? .success : .neutral,
                                    showDot: model.isRemoteEnabled
                                )
                            }
                            Toggle("允许其他设备连接", isOn: Binding(
                                get: { model.prefersRemoteAccess },
                                set: { model.setRemoteEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(model.state != .online || model.remoteBusy || model.isPresentationPreview)
                        }
                        HStack(spacing: 8) {
                            Text(model.remoteAddress ?? "开启后同一 Wi‑Fi 下的手机、平板和电视可直接连接")
                                .font(.system(size: model.remoteAddress != nil ? 14 : 12.5, weight: model.remoteAddress != nil ? .semibold : .regular, design: model.remoteAddress != nil ? .monospaced : .default))
                                .foregroundStyle(model.remoteAddress != nil ? .primary : IsleTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            if let remote = model.remoteAddress {
                                ConnectionQRCodePopoverButton(urlString: remote, label: "局域网扫码直连")
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(remote, forType: .string)
                                    showNotice("已复制局域网连接地址")
                                } label: {
                                    Label("复制", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .help("复制其他设备的连接地址")
                            }
                        }
                        Text(model.remoteAddress != nil
                             ? "在手机端或浏览器输入上方地址即可登录访问。"
                             : "开关选择会自动记住，重启应用后保持不变。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(IsleFluidPalette.rim.opacity(0.55), lineWidth: 0.8)
                    }
                }
                if let error = model.remoteError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(IsleTheme.warningText)
                        Text(error).font(.system(size: 12)).foregroundStyle(IsleTheme.warningText).textSelection(.enabled)
                        Spacer()
                        Button("局域网设置") { requestLocalNavigation { connectionDetail = .lan } }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
            }
        }
    }
    var connectionLocalContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "服务状态", footer: "启动 LightIsle 后自动提供文件服务，退出应用后停止。") {
                AppleSettingsRow(title: "运行状态", icon: "waveform.path.ecg", iconTint: .green) {
                    HStack(spacing: 8) {
                        StatusBadge(isOnline: model.state == .online, text: model.state.label)
                        Button("刷新状态") { model.refreshMetrics() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "在本机打开", icon: "desktopcomputer", iconTint: .blue) {
                    HStack(spacing: 8) {
                        Text(model.endpoint?.absoluteString ?? "未启动")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                        if let endpoint = model.endpoint {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(endpoint.absoluteString, forType: .string)
                                showNotice("已复制访问地址")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制访问地址")

                            Button {
                                model.openUserWeb()
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("在浏览器中打开")
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "监听端口", subtitle: "本机与局域网共用统一端口，默认 16666。", icon: "network", iconTint: .orange) {
                    HStack(spacing: 8) {
                        IsleStatusPill(text: "端口 \(model.preferredLocalPort)", tone: .neutral)
                        Button("前往修改端口…") {
                            requestLocalNavigation {
                                connectionDetail = nil
                                model.selectedSidebarPage = .settings
                                settingsDetail = .general
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
            }

        }
    }
    var connectionLanContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "连接其他设备", footer: "管理员初始化后默认开启局域网，使用统一端口 16666（或自定义端口）。开关和 HTTP/HTTPS 选择会记住并在重启后恢复；实际连接状态取决于本机网络及端口是否可用。请勿将 HTTP 端口映射公网。") {
                AppleSettingsRow(title: "允许其他设备连接", subtitle: "保存开启或关闭的选择，重启后保持不变。右侧状态反映实际监听情况。", icon: "wifi", iconTint: .indigo) {
                    HStack(spacing: 10) {
                        if model.remoteBusy {
                            ProgressView().controlSize(.small)
                            Text("连接中").font(.caption).foregroundStyle(.secondary)
                        } else if model.isRemoteEnabled {
                            Text("已启用").font(.caption).foregroundStyle(.green)
                        } else if model.remoteError != nil {
                            Text(model.prefersRemoteAccess ? "启用失败" : "关闭失败")
                                .font(.caption).foregroundStyle(IsleTheme.errorText)
                        } else if model.prefersRemoteAccess && model.state == .online {
                            Text("等待网络就绪").font(.caption).foregroundStyle(.secondary)
                        } else if model.state != .online {
                            Text("核心未就绪").font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("允许其他设备连接", isOn: Binding(
                            get: { model.prefersRemoteAccess },
                            set: { model.setRemoteEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.state != .online || model.remoteBusy)
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "连接协议", subtitle: "家庭内网默认 HTTP，方便直接连接。HTTPS 可加密传输；HTTP 请勿映射公网或用于公共 Wi-Fi。", icon: "lock.shield", iconTint: .orange) {
                    HStack(spacing: 8) {
                        Button("HTTPS（加密）") { model.setRemoteEnabled(true, allowHTTP: false) }
                            .disabled(model.state != .online || model.remoteBusy || model.remoteAddress?.hasPrefix("https://") == true)
                        Button("HTTP（局域网默认）") { confirmPlainHTTP = true }
                            .disabled(model.state != .online || model.remoteBusy || model.remoteAddress?.hasPrefix("http://") == true)
                            .confirmationDialog(
                                "确定改为不加密连接吗？",
                                isPresented: $confirmPlainHTTP,
                                titleVisibility: .visible
                            ) {
                                Button("仅在可信家庭网络使用", role: .destructive) {
                                    model.setRemoteEnabled(true, allowHTTP: true)
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("同一网络的其他设备可能看到你的密码、登录信息和文件。请勿在公共 Wi-Fi 使用，也不要把端口映射到公网。")
                            }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                if let address = model.remoteAddress {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "其他设备的连接地址", icon: "globe", iconTint: .cyan) {
                        HStack(spacing: 8) {
                            Text(address)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(IsleTheme.accent)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                                showNotice("已复制连接地址")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制连接地址")

                            if let url = URL(string: address) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                                .help("在浏览器中打开连接地址")
                            }
                        }
                    }
                    if let fingerprint = model.remoteFingerprint {
                        IsleGroupSpacing(height: 4).padding(.leading, 14)
                        AppleSettingsRow(title: "连接验证信息", subtitle: "首次用手机加密连接时，可复制此信息进行核对。", icon: "lock.shield", iconTint: .teal) {
                            HStack(spacing: 8) {
                                Text(fingerprint)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                    showNotice("已复制连接验证信息")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                                .help("复制连接验证信息")
                            }
                        }
                    }
                }
                if let error = model.remoteError {
                    IsleGroupSpacing(height: 4).padding(.leading, 14)
                    AppleSettingsRow(title: "连接异常", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                        HStack(spacing: 10) {
                            Text(error).font(.caption).foregroundStyle(IsleTheme.errorText)
                            Button(model.prefersRemoteAccess ? "重试连接" : "重试关闭") {
                                model.setRemoteEnabled(model.prefersRemoteAccess, rememberChoice: false)
                            }
                                .disabled(model.state != .online || model.remoteBusy)
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
            }

        }
    }
    var connectionSharingContent: some View {
        SmbSharingSectionView(model: model, showNotice: showNotice)
    }
    var connectionRemoteContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "在外面访问（可选）", footer: "不在家时，可让自己的设备先加入同一个私人网络，再连接 LightIsle。不会自动开放公网端口或修改路由器。") {
                AppleSettingsRow(
                    title: "在家庭网络之外访问",
                    subtitle: "先开启加密连接，再让手机和 Mac 加入同一个私人网络。首次连接时请核对验证信息。",
                    icon: "network.badge.shield.half.filled",
                    iconTint: .indigo
                ) {
                    HStack(spacing: 8) {
                        Button("Tailscale 配置指南") {
                            if let url = URL(string: "https://tailscale.com/kb/1017/install") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Button("EasyTier 使用说明") {
                            if let url = URL(string: "https://github.com/EasyTier/EasyTier") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
            }

        }
    }
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
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                                showNotice("已复制临时域名")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制临时域名")
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "API Key 模式", subtitle: "在二级页面填写 Cloudflare API Token、创建/删除隧道并一键绑定公共主机名（自动配置 DNS 与路由）。", icon: "key.fill", iconTint: .indigo) {
                    Button("管理隧道与域名") {
                        requestLocalNavigation { presentingTunnelManager = true }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
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
                        Button("获取版本") { model.refreshFRPVersions() }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
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
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("在 Finder 中显示")
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
                        Button("刷新") { model.refreshFRP() }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
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
        }
    }
}
