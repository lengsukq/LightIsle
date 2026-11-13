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
                let primaryDetails: [ConnectionDetail] = [.local, .lan, .sharing, .remote]
                let advancedDetails: [ConnectionDetail] = [.cloudflare, .frp]
                IsleDestinationGrid {
                    ForEach(Array(primaryDetails.enumerated()), id: \.element.id) { index, detail in
                        let status = connectionBadge(for: detail)
                        let rowTitle = detail == .remote ? "主推方案 · \(detail.rawValue) (Tailscale)" : detail.rawValue
                        IsleDestinationRow(
                            title: rowTitle,
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
                DisclosureGroup("高级穿透选项（Cloudflare Tunnel / FRP）") {
                    IsleDestinationGrid {
                        ForEach(Array(advancedDetails.enumerated()), id: \.element.id) { index, detail in
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
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(IsleTheme.secondaryText)
                .padding(.top, 4)
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
            let ts = TailscaleAndUPSDetector.detectTailscale()
            if ts.connected { return ("Tailscale 已组网 · \(ts.ipv4)", .success) }
            return (ts.installed ? "Tailscale 已安装" : "Tailscale / EasyTier", .neutral)
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
                                IsleIconButton(
                                    icon: "doc.on.doc",
                                    help: "复制本机访问地址"
                                ) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(endpoint, forType: .string)
                                    showNotice("已复制本机访问地址")
                                }
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
                                IsleIconButton(
                                    icon: "doc.on.doc",
                                    help: "复制局域网连接地址"
                                ) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(remote, forType: .string)
                                    showNotice("已复制局域网连接地址")
                                }
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
                IsleQuickJumpBar(items: [
                    IsleQuickJumpItem("Mac 文件共享 (SMB)", icon: "externaldrive.connected.to.line.below", tint: .orange, help: "在 Mac 访达「网络」与播放器直接挂载轻屿文件夹") {
                        requestLocalNavigation { connectionDetail = .sharing }
                    },
                    IsleQuickJumpItem("Tailscale 异地直连", icon: "network.badge.shield.half.filled", tint: .indigo, help: "出门在外免公网 IP 点对点加密访问") {
                        requestLocalNavigation { connectionDetail = .remote }
                    },
                    IsleQuickJumpItem("Cloudflare / FRP", icon: "cloud", tint: .cyan, help: "按需开启内网穿透绑定公网域名") {
                        requestLocalNavigation { connectionDetail = .cloudflare }
                    },
                    IsleQuickJumpItem("监听端口", icon: "slider.horizontal.3", tint: .blue, help: "修改本机与局域网共用的 HTTP/HTTPS 监听端口") {
                        model.navigateToSettingsDetail(.general)
                    }
                ])
            }
        }
    }
    var connectionLocalContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "服务状态", footer: "启动 LightIsle 后自动提供文件服务，退出应用后停止。") {
                AppleSettingsRow(title: "运行状态", icon: "waveform.path.ecg", iconTint: .green) {
                    HStack(spacing: 8) {
                        StatusBadge(isOnline: model.state == .online, text: model.state.label)
                        IsleIconButton(icon: "arrow.clockwise", help: "刷新核心服务与地址状态") {
                            model.refreshMetrics()
                        }
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
                            IsleIconButton(
                                icon: "doc.on.doc",
                                variant: .borderless,
                                help: "复制本机访问地址"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(endpoint.absoluteString, forType: .string)
                                showNotice("已复制访问地址")
                            }
                            IsleIconButton(
                                icon: "arrow.up.forward.app",
                                variant: .borderless,
                                help: "在浏览器中打开"
                            ) {
                                model.openUserWeb()
                            }
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
                AppleSettingsRow(title: "监听端口", subtitle: "本机与局域网共用统一端口，默认 16666。", icon: "network", iconTint: .orange) {
                    HStack(spacing: 8) {
                        IsleStatusPill(text: "端口 \(model.preferredLocalPort)", tone: .neutral)
                        IsleIconButton(
                            icon: "slider.horizontal.3",
                            help: "前往「设置 → 通用与关于」修改监听端口"
                        ) {
                            model.navigateToSettingsDetail(.general)
                        }
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
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(address)
                            ConnectionQRCodePopoverButton(urlString: address, label: "局域网扫码直连")
                            IsleIconButton(
                                icon: "doc.on.doc",
                                variant: .borderless,
                                help: "复制连接地址"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                                showNotice("已复制连接地址")
                            }

                            if let url = URL(string: address) {
                                IsleIconButton(
                                    icon: "arrow.up.forward.app",
                                    variant: .borderless,
                                    help: "在浏览器中打开连接地址"
                                ) {
                                    NSWorkspace.shared.open(url)
                                }
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
                                IsleIconButton(
                                    icon: "doc.on.doc",
                                    variant: .borderless,
                                    help: "复制连接验证信息"
                                ) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                    showNotice("已复制连接验证信息")
                                }
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

            IsleQuickJumpBar(items: [
                IsleQuickJumpItem("Tailscale 异地直连", icon: "network.badge.shield.half.filled", tint: .indigo, help: "在家庭网络之外通过 Tailscale 加密直连") {
                    requestLocalNavigation { connectionDetail = .remote }
                },
                IsleQuickJumpItem("Mac 文件共享 (SMB)", icon: "externaldrive.connected.to.line.below", tint: .orange, help: "配置通过访达与播放器直接访问的 SMB 共享") {
                    requestLocalNavigation { connectionDetail = .sharing }
                },
                IsleQuickJumpItem("Cloudflare / FRP", icon: "cloud", tint: .cyan, help: "配置公网域名内网穿透访问") {
                    requestLocalNavigation { connectionDetail = .cloudflare }
                },
                IsleQuickJumpItem("修改监听端口", icon: "slider.horizontal.3", tint: .blue, help: "前往通用设置调整 HTTP/HTTPS 服务端口") {
                    model.navigateToSettingsDetail(.general)
                }
            ])
        }
    }
    var connectionSharingContent: some View {
        SmbSharingSectionView(model: model, showNotice: showNotice)
    }
    var connectionRemoteContent: some View {
        let ts = TailscaleAndUPSDetector.detectTailscale()
        let tsDirect = ts.directURL(remoteAddress: model.remoteAddress, fallbackPort: model.preferredLocalPort)
        return VStack(alignment: .leading, spacing: 20) {
            AppleSettingsGroup(title: "零配置异地组网（Tailscale / EasyTier）", footer: "不在家时，让手机与本机登录同一 Tailscale 账号即可通过 100.64.0.0/10 虚拟组网接口加密直连，轻屿开启局域网连接后会自动双接口绑定（无需暴露公网端口）。") {
                AppleSettingsRow(
                    title: "Tailscale 本机实时探测",
                    subtitle: ts.connected ? "已识别虚拟组网接口 \(ts.interfaceName) · \(ts.ipv4)" : (ts.installed ? "已检测到 Tailscale 客户端，登录组网后即可自动直连。" : "尚未检测到 Tailscale，安装登录同一账号即可免公网 IP 异地直连。"),
                    icon: "point.3.connected.trianglepath.dotted",
                    iconTint: ts.connected ? .green : .indigo
                ) {
                    HStack(spacing: 8) {
                        if let direct = tsDirect {
                            Text(direct)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(IsleTheme.accent)
                                .textSelection(.enabled)
                            ConnectionQRCodePopoverButton(urlString: direct, label: "异地组网扫码直连")
                            IsleIconButton(
                                icon: "doc.on.doc",
                                help: "复制 Tailscale 异地直连地址"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(direct, forType: .string)
                                showNotice("已复制 Tailscale 直连地址")
                            }
                        } else {
                            IsleStatusPill(text: ts.connected ? "请先开启局域网连接" : (ts.installed ? "待连接" : "未安装"), tone: ts.connected ? .warning : .neutral)
                        }
                    }
                }
                IsleGroupSpacing(height: 4).padding(.leading, 14)
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

            IsleQuickJumpBar(items: [
                IsleQuickJumpItem("开启局域网监听", icon: "wifi", tint: .teal, help: "Tailscale 双接口绑定需要先开启「局域网连接」") {
                    requestLocalNavigation { connectionDetail = .lan }
                },
                IsleQuickJumpItem("Cloudflare Tunnel", icon: "cloud", tint: .cyan, help: "改用绑定自有公网域名的 Cloudflare 穿透") {
                    requestLocalNavigation { connectionDetail = .cloudflare }
                },
                IsleQuickJumpItem("FRP 穿透", icon: "point.topleft.down.curvedto.point.bottomright.up", tint: .purple, help: "使用自建 FRP 服务器进行公网映射") {
                    requestLocalNavigation { connectionDetail = .frp }
                }
            ])
        }
    }
}
