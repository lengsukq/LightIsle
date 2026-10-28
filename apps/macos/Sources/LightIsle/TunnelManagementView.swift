import SwiftUI

/// Full-screen management sheet for the Cloudflare Tunnel API-key mode:
/// token onboarding, tunnel CRUD, and one-click public hostname binding
/// (DNS CNAME + remotely-managed ingress rule).
struct TunnelManagementView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingLeaveConfirmation = false
    @State private var savingToken = false
    @State private var pendingTunnelName: String?
    @State private var pendingHostname: String?
    private var hasDrafts: Bool { !tokenDraft.isEmpty || !newTunnelName.isEmpty || !hostnameDraft.isEmpty }
    @State private var tokenDraft = ""
    @State private var newTunnelName = ""
    @State private var hostnameDraft = ""
    @State private var serviceDraft = "http://127.0.0.1:16666"
    @State private var selectedZoneID = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloudflare Tunnel 管理").font(.system(size: 16, weight: .semibold))
                    Text("通过 Cloudflare API 创建隧道、绑定域名并一键接入")
                        .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
                Button("完成") { if hasDrafts { showingLeaveConfirmation = true } else { dismiss() } }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }
            .padding(20)

            IsleGroupSpacing(height: 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.tunnelAPIError {
                        Text(error).font(.caption).foregroundStyle(IsleTheme.errorText).textSelection(.enabled)
                    }
                    if !model.tunnelAPITokenConfigured {
                        tokenOnboarding
                    } else {
                        accountSection
                        tunnelsSection
                        if model.tunnelSelectedID != nil {
                            hostnameSection
                        }
                        tokenSection
                    }
                    if model.tunnelAPIBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在与 Cloudflare 通信…").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 600)
        .background(IsleFluidPalette.canvasTop)
        .interactiveDismissDisabled(hasDrafts || model.tunnelAPIBusy)
        .confirmationDialog("有尚未保存或执行的输入", isPresented: $showingLeaveConfirmation, titleVisibility: .visible) {
            if !tokenDraft.isEmpty {
                Button("验证并保存 Token") { savingToken = true; model.configureTunnelAPIToken(tokenDraft) }
            }
            Button("放弃输入并关闭", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .onChange(of: model.tunnelAPIBusy) { _, busy in
            guard !busy, model.tunnelAPIError == nil else { return }
            if savingToken && model.tunnelAPITokenConfigured { tokenDraft = ""; savingToken = false }
            if let name = pendingTunnelName, model.tunnelList.contains(where: { $0.name == name }) { newTunnelName = ""; pendingTunnelName = nil }
            if let hostname = pendingHostname, model.tunnelIngress.contains(where: { $0.hostname == hostname }) { hostnameDraft = ""; pendingHostname = nil }
        }
        .task {
            if model.tunnelAPITokenConfigured {
                model.requestTunnelList()
                model.requestTunnelZones()
            }
        }
    }

    private var tokenOnboarding: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("填写 Cloudflare API Token").font(.system(size: 13, weight: .semibold))
                SecureField("Cloudflare API Token", text: $tokenDraft)
                    .liquidInput()
                Text("在 Cloudflare 控制台创建 Token，勾选权限：Account · Account Settings:Read、Account · Cloudflare Tunnel:Edit、Zone · Zone:Read、Zone · DNS:Edit。Token 保存在本机钥匙串，可随时撤销。")
                    .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                Button("验证并保存") {
                    savingToken = true
                    model.configureTunnelAPIToken(tokenDraft)
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).count < 16 || model.tunnelAPIBusy)
            }
            .padding(8)
        }
    }

    private var accountSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.tunnelAccounts) { account in
                    HStack {
                        Image(systemName: "building.2").foregroundStyle(IsleTheme.secondaryText)
                        Text(account.name).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("账号已连接").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                    }
                }
            }
            .padding(8)
        }
    }

    private var tunnelsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("隧道").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        model.requestTunnelList()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                }
                HStack(spacing: 8) {
                    TextField("新隧道名称（如：lightisle-nas）", text: $newTunnelName)
                        .liquidInput()
                    Button("创建") {
                        let name = newTunnelName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        pendingTunnelName = name
                        model.createTunnel(named: name)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(newTunnelName.trimmingCharacters(in: .whitespaces).isEmpty || model.tunnelAPIBusy)
                }
                if model.tunnelList.isEmpty {
                    Text("还没有隧道；创建一个或填写上方 Token。").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
                ForEach(model.tunnelList) { entry in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(entry.status == "healthy" ? Color.green : (entry.status == "down" ? Color.orange : Color.gray))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.system(size: 13, weight: .medium))
                            Text("\(entry.status) · \(entry.connections) 条连接 · \(entry.remoteConfig ? "远程配置" : "本地配置")")
                                .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                        Spacer()
                        if model.tunnelSelectedID == entry.id {
                            Text("已选择").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                        }
                        Button("选择") { model.selectTunnel(entry.id) }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.tunnelSelectedID == entry.id || !entry.remoteConfig)
                        if entry.remoteConfig {
                            Button("删除…") {
                                let alert = NSAlert()
                                alert.alertStyle = .warning
                                alert.messageText = "删除隧道「\(entry.name)」？"
                                alert.informativeText = "隧道上的所有公共主机名将立即失效。此操作通过 Cloudflare API 执行，不可撤销。"
                                alert.addButton(withTitle: "删除")
                                alert.addButton(withTitle: "取消")
                                if alert.runModal() == .alertFirstButtonReturn {
                                    model.deleteTunnel(entry.id)
                                }
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                        }
                    }
                }
                if let selected = model.tunnelSelectedID {
                    HStack {
                        Button("启动此隧道") { model.startSelectedTunnel() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(model.tunnelAPIBusy)
                        Button("停止隧道") { model.stopTunnel() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Spacer()
                        if let state = model.tunnelState, state.tunnelId == selected {
                            Text("本地状态：\(state.statusDescription)")
                                .font(.caption)
                                .foregroundStyle(state.status == "online" ? IsleTheme.successText : IsleTheme.secondaryText)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var hostnameSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("公共主机名（一键绑定域名 + 路由）").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Picker("", selection: $selectedZoneID) {
                        Text("选择域名").tag("")
                        ForEach(model.tunnelZones) { zone in
                            Text(zone.name).tag(zone.id)
                        }
                    }
                    .frame(width: 170)
                    TextField("nas.example.com", text: $hostnameDraft)
                        .liquidInput()
                    TextField("http://127.0.0.1:16666", text: $serviceDraft)
                        .liquidInput()
                    Button("绑定") {
                        guard let zone = model.tunnelZones.first(where: { $0.id == selectedZoneID }) else { return }
                        let zoneName = zone.name
                        let host = hostnameDraft.trimmingCharacters(in: .whitespaces)
                        let fullHostname = host.contains(".") ? host : "\(host).\(zoneName)"
                        pendingHostname = fullHostname
                        model.bindHostname(fullHostname, zoneID: selectedZoneID, service: serviceDraft)
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(selectedZoneID.isEmpty || hostnameDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.tunnelAPIBusy)
                }
                Text("绑定会自动创建指向隧道的 CNAME 记录并更新 Ingress 规则；其他主机名规则不会被修改。")
                    .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                if model.tunnelIngress.isEmpty {
                    Text("暂无路由规则。").font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
                ForEach(model.tunnelIngress) { rule in
                    HStack {
                        Text(rule.isCatchAll ? "（其余请求）" : rule.hostname ?? "")
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(rule.service).font(.system(size: 12, design: .monospaced)).foregroundStyle(IsleTheme.secondaryText)
                        if !rule.isCatchAll, let hostname = rule.hostname, let zoneID = selectedZoneRecordID(hostname) {
                            Button("移除") {
                                let alert = NSAlert()
                                alert.alertStyle = .warning
                                alert.messageText = "移除主机名 \(hostname)？"
                                alert.informativeText = "将删除 Ingress 规则，并尝试删除由 LightIsle 创建的 CNAME 记录（不影响手动创建的其他记录）。"
                                alert.addButton(withTitle: "移除")
                                alert.addButton(withTitle: "取消")
                                if alert.runModal() == .alertFirstButtonReturn {
                                    model.unbindHostname(hostname, zoneID: zoneID)
                                }
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var tokenSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API Token").font(.system(size: 13, weight: .semibold))
                    Text("保存在本机钥匙串（dev.lightisle.tunnel）。")
                        .font(.caption).foregroundStyle(IsleTheme.secondaryText)
                }
                Spacer()
                Button("移除保存的 Token…") {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "移除保存的 Cloudflare API Token？"
                    alert.informativeText = "之后将无法在应用内管理隧道，需要重新填写。正在运行的本地隧道不受影响。"
                    alert.addButton(withTitle: "移除")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        model.forgetTunnelAPIToken()
                    }
                }
                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
            }
            .padding(8)
        }
    }

    /// Match an ingress hostname back to the configured zone by suffix.
    private func selectedZoneRecordID(_ hostname: String) -> String? {
        let lower = hostname.lowercased()
        for zone in model.tunnelZones where lower == zone.name || lower.hasSuffix("." + zone.name) {
            return zone.id
        }
        return model.tunnelZones.first?.id
    }
}
