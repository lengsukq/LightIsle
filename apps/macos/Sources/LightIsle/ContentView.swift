import SwiftUI
import AppKit

private enum SidebarPage: String, CaseIterable, Hashable {
    case overview = "概览"
    case services = "服务管理"
    case storage = "存储"
    case settings = "设置"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .services: return "server.rack"
        case .storage: return "internaldrive"
        case .settings: return "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return .blue
        case .services: return .purple
        case .storage: return .teal
        case .settings: return .gray
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showingManualIntro = false
    @State private var selection: SidebarPage? = .overview
    @State private var firstUsername = ""
    @State private var firstPassword = ""
    @State private var confirmPassword = ""
    @State private var copiedNotice: String?

    var body: some View {
        Group {
            if showingManualIntro {
                IntroAnimationView {
                    showingManualIntro = false
                }
            } else if model.isConfigured == false {
                if !hasSeenIntro {
                    IntroAnimationView {
                        hasSeenIntro = true
                    }
                } else {
                    nativeSetupView
                }
            } else if model.isConfigured == nil {
                connectingView
            } else {
                managementShell
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.isConfigured)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: hasSeenIntro)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showingManualIntro)
        .task {
            while !Task.isCancelled {
                model.refreshMetrics()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Connecting View
    private var connectingView: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 90, height: 90)
                        .blur(radius: 12)
                    BrandMark(size: 78)
                    ProgressView()
                        .offset(y: 56)
                }

                VStack(spacing: 6) {
                    Text("正在连接本机服务")
                        .font(.title3.weight(.bold))
                    Text(model.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            .padding(40)
        }
    }

    // MARK: - Native Setup (First Run)
    private var nativeSetupView: some View {
        ZStack {
            // Ambient subtle background
            Color(nsColor: .windowBackgroundColor)
            Circle()
                .fill(Color.blue.opacity(0.08))
                .frame(width: 500, height: 500)
                .offset(x: -160, y: -140)
                .blur(radius: 80)
            Circle()
                .fill(Color.purple.opacity(0.06))
                .frame(width: 450, height: 450)
                .offset(x: 180, y: 160)
                .blur(radius: 80)

            VStack(spacing: 24) {
                // Top brand mark
                VStack(spacing: 12) {
                    BrandMark(size: 76)
                        .shadow(color: Color.blue.opacity(0.18), radius: 18, x: 0, y: 8)

                    Text("初始化轻屿管理员")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("首次启动需在本机创建最高管理账号。数据仅保留在 Mac 本地，不向公网开放自助注册。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                // Frosted Card Form
                LiquidCard(cornerRadius: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("管理员账号")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("3–32 位英文字母、数字或 . _ -", text: $firstUsername)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("登录密码")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !firstPassword.isEmpty {
                                    Text(firstPassword.count >= 12 ? "长度合规" : "至少需 12 位（当前 \(firstPassword.count)）")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(firstPassword.count >= 12 ? .green : .orange)
                                }
                            }
                            SecureField("至少 12 位密码", text: $firstPassword)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("确认密码")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !confirmPassword.isEmpty {
                                    if firstPassword == confirmPassword {
                                        Text("密码一致")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("两次密码不一致")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                            SecureField("请再次输入相同密码", text: $confirmPassword)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }

                        if let error = model.initializationError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                Text(error)
                                    .font(.caption)
                            }
                            .foregroundStyle(.red)
                            .padding(.vertical, 4)
                        }

                        Button {
                            model.initializeAdministrator(username: firstUsername, password: firstPassword)
                            firstPassword = ""
                            confirmPassword = ""
                        } label: {
                            HStack(spacing: 8) {
                                if model.initializing {
                                    ProgressView().controlSize(.small)
                                }
                                Text(model.initializing ? "正在创建管理员…" : "完成配置并进入")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: isFormValid ? [Color.blue, Color(red: 0.1, green: 0.45, blue: 0.95)] : [Color.gray.opacity(0.4), Color.gray.opacity(0.4)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: isFormValid ? Color.blue.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isFormValid || model.initializing || model.state != .online)
                    }
                    .padding(8)
                }
                .frame(width: 440)

                // Replay intro link
                Button {
                    showingManualIntro = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.circle")
                        Text("重新播放开场动画")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(32)
        }
    }

    private var isFormValid: Bool {
        !firstUsername.isEmpty &&
        firstPassword.count >= 12 &&
        firstPassword == confirmPassword
    }

    // MARK: - Management Shell
    private var managementShell: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // Brand Header
                HStack(spacing: 12) {
                    BrandMark(size: 38)
                        .shadow(color: Color.blue.opacity(0.2), radius: 8, x: 0, y: 3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("轻屿")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("LightIsle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 20)

                // Sidebar Navigation Items
                VStack(spacing: 4) {
                    ForEach(SidebarPage.allCases, id: \.self) { item in
                        let isSelected = selection == item
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                selection = item
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSelected ? item.tint.opacity(0.2) : Color.primary.opacity(0.04))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: item.icon)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(isSelected ? item.tint : .secondary)
                                }

                                Text(item.rawValue)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? Color.primary.opacity(0.07) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)

                Spacer()

                // Sidebar Bottom Status & Web Link
                VStack(spacing: 12) {
                    HStack {
                        StatusBadge(isOnline: model.state == .online, text: model.state.label)
                        Spacer()
                    }

                    Button {
                        model.openUserWeb()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "safari.fill")
                                .font(.system(size: 14))
                            Text("打开 Web 用户端")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.blue.opacity(0.25), lineWidth: 0.8)
                        )
                        .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.endpoint == nil)
                }
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
            .background(.ultraThinMaterial)
        } detail: {
            VStack(spacing: 0) {
                // Translucent Detail Header
                HStack(spacing: 12) {
                    Text(selection?.rawValue ?? "概览")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()

                    StatusBadge(isOnline: model.state == .online, text: model.state.label)

                    Button {
                        if case .error = model.state { model.launch() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("重新启动后端服务")
                    .disabled({ if case .error = model.state { return false }; return true }())
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1),
                    alignment: .bottom
                )

                // Detail View Content
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                        .ignoresSafeArea()

                    switch selection ?? .overview {
                    case .overview:
                        overviewView
                    case .services:
                        servicesView
                    case .storage:
                        storageView
                    case .settings:
                        settingsView
                    }
                }
            }
        }
    }

    // MARK: - Overview (Bento Grid)
    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Host Welcome Banner
                LiquidCard {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.2), Color.purple.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 52, height: 52)
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 24))
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(model.metrics?.hostname ?? "本地 Mac")
                                    .font(.system(size: 16, weight: .bold))
                                Text(model.metrics?.architecture ?? "arm64")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.blue.opacity(0.1)))
                                    .foregroundStyle(.blue)
                            }
                            Text(model.details)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button {
                            model.openUserWeb()
                        } label: {
                            HStack(spacing: 6) {
                                Text("进入 Web 端")
                                    .fontWeight(.medium)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.endpoint == nil)
                    }
                }

                // Bento Grid Metrics
                Text("系统与硬件性能")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    let m = model.metrics
                    let cpuP = (m?.cpuPercent ?? 0) / 100.0
                    BentoStatCard(
                        title: "处理器利用率",
                        value: m?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "采样中…",
                        subtitle: "\(m?.cpuCount ?? 0) 个高效计算核心",
                        icon: "cpu",
                        tint: .blue,
                        progress: m?.cpuPercent != nil ? cpuP : nil
                    )

                    let memUsed = m?.memoryUsed ?? 0
                    let memTotal = max(m?.memoryTotal ?? 1, 1)
                    let memP = Double(memUsed) / Double(memTotal)
                    BentoStatCard(
                        title: "统一内存占用",
                        value: formatBytes(memUsed),
                        subtitle: "总容量 \(formatBytes(memTotal))",
                        icon: "memorychip",
                        tint: .purple,
                        progress: m != nil ? memP : nil
                    )

                    let diskFree = m?.diskFree ?? 0
                    let diskTotal = max(m?.diskTotal ?? 1, 1)
                    let diskUsed = diskTotal - diskFree
                    let diskP = Double(diskUsed) / Double(diskTotal)
                    BentoStatCard(
                        title: "系统盘占用",
                        value: formatBytes(diskUsed),
                        subtitle: "剩余可用空间 \(formatBytes(diskFree))",
                        icon: "internaldrive",
                        tint: .teal,
                        progress: m != nil ? diskP : nil
                    )

                    BentoStatCard(
                        title: "Go Core 状态",
                        value: model.state.label,
                        subtitle: model.endpoint?.absoluteString ?? "等待服务就绪",
                        icon: "server.rack",
                        tint: model.state == .online ? .green : .orange
                    )
                }

                // Quick Navigation Bento
                Text("私人空间快捷入口")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    quickActionCard(
                        title: "共享文件",
                        desc: "浏览与上传个人文件",
                        icon: "folder.fill",
                        tint: .blue
                    )
                    quickActionCard(
                        title: "私人图库",
                        desc: "智能索引与回忆相册",
                        icon: "photo.stack.fill",
                        tint: .pink
                    )
                    quickActionCard(
                        title: "私人影院",
                        desc: "原画串流与断点续播",
                        icon: "film.stack.fill",
                        tint: .orange
                    )
                }
            }
            .padding(28)
        }
    }

    private func quickActionCard(title: String, desc: String, icon: String, tint: Color) -> some View {
        Button {
            model.openUserWeb()
        } label: {
            LiquidCard {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(tint.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: icon)
                            .font(.system(size: 18))
                            .foregroundStyle(tint)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.endpoint == nil)
    }

    // MARK: - Services View
    private var servicesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("核心后端服务")
                        .font(.system(size: 16, weight: .bold))
                    Text("Go Core 随 LightIsle.app 启动，退出应用时自动释放所有子进程与端口。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                LiquidGroupCard {
                    VStack(spacing: 0) {
                        serviceRow(
                            label: "运行状态",
                            valueView: AnyView(StatusBadge(isOnline: model.state == .online, text: model.state.label))
                        )
                        Divider().padding(.leading, 18)
                        serviceRow(
                            label: "本机 API 地址",
                            valueView: AnyView(Text(model.endpoint?.absoluteString ?? "未启动").font(.system(size: 13, design: .monospaced)))
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("局域网 HTTPS 访问")
                        .font(.system(size: 16, weight: .bold))
                    Text("开启后可通过同一局域网下的浏览器或设备访问，使用自签名安全证书。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                LiquidGroupCard {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("局域网远程连接")
                                    .font(.system(size: 13, weight: .medium))
                                Text(model.isRemoteEnabled ? "已监听局域网连接" : "仅允许本机 127.0.0.1 访问")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { model.isRemoteEnabled },
                                set: { model.setRemoteEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                            .disabled(model.state != .online)
                        }
                        .padding(16)

                        if let address = model.remoteAddress {
                            Divider().padding(.leading, 18)
                            serviceRow(
                                label: "远程访问地址",
                                valueView: AnyView(Text(address).font(.system(size: 13, design: .monospaced)).foregroundStyle(.blue))
                            )

                            if let fingerprint = model.remoteFingerprint {
                                Divider().padding(.leading, 18)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("证书 SHA-256 指纹")
                                            .font(.system(size: 13, weight: .medium))
                                        Spacer()
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString("\(address)\nSHA256: \(fingerprint)", forType: .string)
                                            withAnimation {
                                                copiedNotice = "已复制地址与证书指纹"
                                            }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                withAnimation { copiedNotice = nil }
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "doc.on.doc")
                                                Text(copiedNotice ?? "复制完整凭据")
                                            }
                                            .font(.system(size: 11, weight: .medium))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                                            .foregroundStyle(.blue)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    Text(fingerprint)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .padding(16)
                            }
                        }

                        if let error = model.remoteError {
                            Divider().padding(.leading, 18)
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                            }
                            .padding(16)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("SMB 文件共享诊断").font(.system(size: 16, weight: .bold))
                    Text("只检测本机 TCP 445 端口，不代表已配置共享账号，也不修改 macOS 设置。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                LiquidGroupCard {
                    HStack {
                        Label("SMB 端口状态", systemImage: "network")
                        Spacer()
                        Text(model.smbListening.map { $0 ? "正在监听" : "未监听" } ?? "检测中")
                            .foregroundStyle(model.smbListening == true ? .green : .secondary)
                        Button("系统共享设置…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }.buttonStyle(.bordered)
                    }
                    .padding(16)
                }
            }
            .padding(28)
        }
    }

    private func serviceRow(label: String, valueView: AnyView) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            valueView
        }
        .padding(16)
    }

    // MARK: - Storage View
    private var storageView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("文件共享目录")
                        .font(.system(size: 16, weight: .bold))
                    Text("Mac 授权的专用存储目录，已登录用户在 Web 端浏览与管理的所有文件均保存在此。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                LiquidGroupCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.teal.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "folder.badge.gearshape")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.teal)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("当前共享目录")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(model.sharedFolderName)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            HStack(spacing: 8) {
                                Button("重选目录…") {
                                    model.selectSharedFolder()
                                }
                                .disabled(model.state != .online)

                                Button("重新挂载外置盘") {
                                    model.retrySharedFolder()
                                }
                                .disabled(model.state != .online)
                            }
                        }
                        .padding(18)

                        if let error = model.sharedFolderError {
                            Divider().padding(.leading, 18)
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                            }
                            .padding(16)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("物理磁盘容量")
                        .font(.system(size: 16, weight: .bold))
                    Text("宿主 Mac 系统盘剩余与使用情况。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                LiquidGroupCard {
                    if let m = model.metrics {
                        VStack(spacing: 0) {
                            serviceRow(
                                label: "系统盘总容量",
                                valueView: AnyView(Text(formatBytes(m.diskTotal)).font(.system(size: 13, weight: .semibold)))
                            )
                            Divider().padding(.leading, 18)
                            serviceRow(
                                label: "系统盘剩余可用",
                                valueView: AnyView(Text(formatBytes(m.diskFree)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.green))
                            )
                        }
                    } else {
                        Text("正在读取磁盘信息…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(18)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("备份与恢复").font(.system(size: 16, weight: .bold))
                    Text("复制当前授权共享目录并逐文件校验 SHA-256；恢复到独立目录，不覆盖现有数据。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                LiquidGroupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("立即备份…") { model.startBackup() }
                            Button("从备份恢复…") { model.restoreBackup() }
                        }
                        .disabled(model.state != .online || model.backupStatus?.running == true)
                        if let report = model.backupStatus {
                            if report.running {
                                ProgressView("正在处理 \(report.files) 个文件")
                            } else if let path = report.lastSnapshot {
                                Text("上次结果：\(path)").textSelection(.enabled)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let reason = report.lastError {
                                Text("备份失败：\(reason)").foregroundStyle(.red)
                            }
                        }
                        if let message = model.backupError {
                            Text("任务错误：\(message)").foregroundStyle(.red)
                        }
                        Divider()
                        Text("自动备份（仅 Mac App 运行时）").font(.headline)
                        HStack {
                            Button("每天备份…") { model.configureBackupSchedule(hours: 24) }
                            Button("每周备份…") { model.configureBackupSchedule(hours: 168) }
                            Button("关闭计划") { model.disableBackupSchedule() }
                                .disabled(model.backupSchedule?.enabled != true)
                        }
                        .disabled(model.state != .online)
                        if let schedule = model.backupSchedule, schedule.enabled {
                            Text("每 \(schedule.everyHours) 小时 · 下次：\(Date(timeIntervalSince1970: TimeInterval(schedule.nextRun)).formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(schedule.destination ?? "").font(.caption).textSelection(.enabled)
                        } else {
                            Text("计划未启用；退出 App 不执行任何后台任务。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(18)
                }
            }
            .padding(28)
        }
    }

    // MARK: - Settings View
    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("应用偏好与关于")
                        .font(.system(size: 16, weight: .bold))
                    Text("LightIsle macOS 原生管理宿主。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                LiquidGroupCard {
                    VStack(spacing: 0) {
                        serviceRow(
                            label: "应用版本",
                            valueView: AnyView(
                                Text("0.1.0-dev (M1)")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            )
                        )
                        Divider().padding(.leading, 18)
                        serviceRow(
                            label: "首任管理员状态",
                            valueView: AnyView(
                                Text(model.isConfigured == true ? "已配置" : "未完成")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(model.isConfigured == true ? .green : .orange)
                            )
                        )
                        Divider().padding(.leading, 18)
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("开场视效体验")
                                    .font(.system(size: 13, weight: .medium))
                                Text("重温极具沉浸感的 Apple 风格开场动画与罗盘展开展现。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("重新播放动画") {
                                showingManualIntro = true
                            }
                        }
                        .padding(16)
                    }
                }

                LiquidCard {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: "globe")
                                .font(.system(size: 20))
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Web 业务管理端")
                                .font(.system(size: 14, weight: .semibold))
                            Text("浏览文件、图库、私人影院和新增普通成员账号均在独立浏览器中完成。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button("立即在浏览器打开") {
                            model.openUserWeb()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.endpoint == nil)
                    }
                }
            }
            .padding(28)
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
