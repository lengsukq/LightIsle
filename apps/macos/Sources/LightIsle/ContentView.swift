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

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .services: return "2"
        case .storage: return "3"
        case .settings: return "4"
        }
    }

    var eyebrow: String {
        switch self {
        case .overview: return "YOUR SPACE / 01"
        case .services: return "CONTROL / 02"
        case .storage: return "DATA / 03"
        case .settings: return "PREFERENCES / 04"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "一眼掌握这台 Mac 与私人空间的运行状态"
        case .services: return "管理内置服务、连接方式与本机共享"
        case .storage: return "维护共享目录、磁盘容量与数据备份"
        case .settings: return "管理员安全、本机访问和个性化设置"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showingManualIntro = false
    @State private var selection: SidebarPage? = .overview
    @State private var navigationDirection: CGFloat = 1
    @Namespace private var navigationNamespace
    @State private var firstUsername = ""
    @State private var firstPassword = ""
    @State private var confirmPassword = ""
    @State private var copiedNotice: String?
    @State private var localPortText = ""
    @State private var vaultUsername = ""
    @State private var vaultPassword = ""
    @State private var resetAdminPassword = ""
    @State private var resetAdminConfirmation = ""

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
        .animation(reduceMotion ? nil : IsleMotion.reveal, value: model.isConfigured)
        .animation(reduceMotion ? nil : IsleMotion.reveal, value: hasSeenIntro)
        .animation(reduceMotion ? nil : IsleMotion.reveal, value: showingManualIntro)
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
            IsleBackdrop()
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
                    Text(model.state.label)
                        .font(.title3.weight(.bold))
                    Text(model.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                if case .error = model.state {
                    Button("重新启动 Go Core") { model.launch() }
                        .buttonStyle(IsleActionButtonStyle())
                    Button("修复上次中断的数据库恢复…") { model.recoverInterruptedMetadata() }
                        .buttonStyle(IsleActionButtonStyle(destructive: true))
                        .disabled(model.activatingMetadata)
                }
                if let message = model.metadataActivationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 500)
                }
            }
            .padding(40)
        }
    }

    // MARK: - Native Setup (First Run)
    private var nativeSetupView: some View {
        ZStack {
            IsleBackdrop()

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
                                .modifier(IsleTextFieldSurface())
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
                                .modifier(IsleTextFieldSurface())
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
                                .modifier(IsleTextFieldSurface())
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
                        .buttonStyle(IslePressStyle())
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
                HStack(spacing: 12) {
                    BrandMark(size: 42)
                        .shadow(color: IsleTheme.accent.opacity(0.16), radius: 12, x: 0, y: 5)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("轻屿")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("LIGHTISLE  /  MAC")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 30)

                Text("WORKSPACE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 11)

                VStack(spacing: 7) {
                    ForEach(SidebarPage.allCases, id: \.self) { item in
                        let isSelected = selection == item
                        Button {
                            navigate(to: item)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? IsleTheme.accent.opacity(0.14) : Color.primary.opacity(0.035))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: item.icon)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(isSelected ? IsleTheme.accent : .secondary)
                                        .symbolEffect(.bounce, value: isSelected && !reduceMotion)
                                }

                                Text(item.rawValue)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(IsleTheme.accent)
                                        .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(IsleTheme.accent.opacity(0.10))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                                .strokeBorder(IsleTheme.accent.opacity(0.15), lineWidth: 1)
                                        }
                                        .matchedGeometryEffect(id: "active-page", in: navigationNamespace)
                                }
                            }
                        }
                        .buttonStyle(IslePressStyle())
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        .keyboardShortcut(item.shortcut, modifiers: [.command])
                    }
                }
                .padding(.horizontal, 12)

                Spacer()

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
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(IsleTheme.accent.opacity(0.105)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(IsleTheme.accent.opacity(0.19), lineWidth: 1)
                        )
                        .foregroundStyle(IsleTheme.accent)
                    }
                    .buttonStyle(IslePressStyle())
                    .disabled(model.endpoint == nil)
                }
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
            .background(.regularMaterial)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text((selection ?? .overview).eyebrow)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(2)
                            .foregroundStyle(IsleTheme.accent)
                        Text((selection ?? .overview).rawValue)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .contentTransition(.interpolate)
                        Text((selection ?? .overview).subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    StatusBadge(isOnline: model.state == .online, text: model.state.label)

                    Button {
                        if case .error = model.state { model.launch() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.055))
                            )
                    }
                    .buttonStyle(IslePressStyle())
                    .accessibilityLabel("重新启动后端服务")
                    .help("重新启动后端服务")
                    .disabled({ if case .error = model.state { return false }; return true }())
                }
                .padding(.horizontal, IsleTheme.contentPadding)
                .padding(.vertical, 19)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.87))
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 1),
                    alignment: .bottom
                )

                ZStack {
                    IsleBackdrop()

                    Group {
                        switch selection ?? .overview {
                        case .overview: overviewView
                        case .services: servicesView
                        case .storage: storageView
                        case .settings: settingsView
                        }
                    }
                    .id(selection)
                    .transition(pageTransition)
                }
                .clipped()
                .animation(reduceMotion ? nil : IsleMotion.navigation, value: selection)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice = copiedNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
                    .padding(24)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onAppear { localPortText = String(model.preferredLocalPort) }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: navigationDirection * 20).combined(with: .opacity),
            removal: .offset(x: -navigationDirection * 12).combined(with: .opacity)
        )
    }

    private func navigate(to page: SidebarPage) {
        guard selection != page else { return }
        let pages = SidebarPage.allCases
        let currentIndex = pages.firstIndex(of: selection ?? .overview) ?? 0
        let nextIndex = pages.firstIndex(of: page) ?? 0
        navigationDirection = nextIndex >= currentIndex ? 1 : -1
        withAnimation(reduceMotion ? nil : IsleMotion.navigation) { selection = page }
    }

    private func showNotice(_ message: String) {
        withAnimation(reduceMotion ? nil : IsleMotion.quick) { copiedNotice = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if copiedNotice == message {
                withAnimation(reduceMotion ? nil : IsleMotion.quick) { copiedNotice = nil }
            }
        }
    }

    // MARK: - Overview (Bento Grid)
    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Host Welcome Banner
                LiquidCard(cornerRadius: 24) {
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
                        .buttonStyle(IslePressStyle())
                        .disabled(model.endpoint == nil)
                    }
                }

                // Bento Grid Metrics
                Text("系统与硬件性能")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
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

                    BentoStatCard(
                        title: "网络下载速率",
                        value: m?.networkDownBps.map { "\(formatBytes(UInt64(max(0, $0))))/s" } ?? "采样中…",
                        subtitle: "物理网络接口实时接收速率",
                        icon: "arrow.down.circle",
                        tint: .teal
                    )

                    BentoStatCard(
                        title: "网络上传速率",
                        value: m?.networkUpBps.map { "\(formatBytes(UInt64(max(0, $0))))/s" } ?? "采样中…",
                        subtitle: "物理网络接口实时发送速率",
                        icon: "arrow.up.circle",
                        tint: .indigo
                    )
                }

                if let coreRSS = model.metrics?.coreRssBytes, let pid = model.metrics?.corePid {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal.fill").foregroundStyle(IsleTheme.accent)
                        Text("Go Core PID \(pid) · 当前常驻内存 \(formatBytes(coreRSS))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 5)
                }

                IsleSectionHeader(title: "实时性能趋势", subtitle: "仅在 App 打开期间保留最近 120 次指标采样，不记录到数据库。")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    IsleHistoryGraph(title: "处理器使用率 (%)", values: model.metricHistory.map(\.cpu), maximum: 100, tint: .blue)
                    IsleHistoryGraph(title: "内存使用率 (%)", values: model.metricHistory.map(\.memory), maximum: 100, tint: .purple)
                    IsleHistoryGraph(title: "网络下载速率 (B/s)", values: model.metricHistory.map(\.download), maximum: max(model.metricHistory.map(\.download).max() ?? 1, 1), tint: .teal)
                    IsleHistoryGraph(title: "网络上传速率 (B/s)", values: model.metricHistory.map(\.upload), maximum: max(model.metricHistory.map(\.upload).max() ?? 1, 1), tint: .indigo)
                }

                // Quick Navigation Bento
                Text("私人空间快捷入口")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
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
            .padding(IsleTheme.contentPadding)
        }
        .onAppear { localPortText = String(model.preferredLocalPort) }
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
        .buttonStyle(IslePressStyle())
        .disabled(model.endpoint == nil)
    }

    // MARK: - Services View
    private var servicesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                IsleSectionHeader(title: "核心后端服务", subtitle: "Go Core 随 LightIsle.app 启动，退出应用时自动释放所有子进程与端口。")

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

                IsleSectionHeader(title: "局域网 HTTPS 访问", subtitle: "开启后可通过同一局域网下的浏览器或设备访问，使用自签名安全证书。")

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
                                            showNotice("已复制地址与证书指纹")
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
                                        .buttonStyle(IslePressStyle())
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
                IsleSectionHeader(title: "SMB 文件共享诊断", subtitle: "只检测本机 TCP 445 端口，不代表已配置共享账号，也不修改 macOS 设置。")
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
                        }.buttonStyle(IsleActionButtonStyle())
                    }
                    .padding(16)
                }
            }
            .padding(IsleTheme.contentPadding)
        }
        .onAppear { localPortText = String(model.preferredLocalPort) }
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
                IsleSectionHeader(title: "文件共享目录", subtitle: "Mac 授权的专用存储目录，已登录用户在 Web 端浏览与管理的所有文件均保存在此。")

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
                            .buttonStyle(IsleActionButtonStyle())
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

                IsleSectionHeader(
                    title: "跨磁盘安全复制",
                    subtitle: "从共享目录中选择文件或子文件夹，复制到另一块磁盘或 Mac 指定目录。完成 SHA-256 校验前不会公布目标，绝不覆盖同名数据。"
                )
                LiquidGroupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button("选择源文件和目标磁盘…") { model.exportToAnotherDisk() }
                                .disabled(model.state != .online || model.exportRunning || model.sharedFolderPath == nil)
                            if model.exportRunning {
                                Button("取消复制") { model.cancelExport() }
                                    .buttonStyle(IsleActionButtonStyle(destructive: true))
                            }
                        }
                        .buttonStyle(IsleActionButtonStyle())
                        if model.exportRunning {
                            ProgressView("正在复制并核对文件完整性")
                        }
                        if let message = model.exportMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("这项操作仅从 Mac App 发起。原文件不会删除；跨卷移动及异常断电后的自动续传仍需单独实现。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                }

                IsleSectionHeader(title: "物理磁盘容量", subtitle: "宿主 Mac 系统盘剩余与使用情况。")

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
                IsleSectionHeader(title: "已挂载存储卷与硬盘健康", subtitle: "容量及只读状态来自 macOS；SMART 读取失败或未提供时显示未知，不会标记为健康。")
                LiquidGroupCard {
                    if let volumes = model.metrics?.volumes, !volumes.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(volumes) { volume in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Label(volume.mount == "/" ? "系统磁盘" : volume.name, systemImage: volume.mount == "/" ? "internaldrive" : "externaldrive")
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text(volume.readOnly ? "只读" : "已挂载")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(volume.filesystem) · \(volume.mount)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Text("总计 \(formatBytes(volume.total)) · 可用 \(formatBytes(volume.free))")
                                        .font(.caption)
                                    ProgressView(value: Double(volume.total - min(volume.free, volume.total)) / Double(max(volume.total, 1)))
                                        .tint(IsleTheme.accent)
                                    if let health = model.volumeHealth[volume.mount] {
                                        HStack {
                                            Image(systemName: health.warning ? "exclamationmark.triangle.fill" : "heart.text.square")
                                                .foregroundStyle(health.warning ? .red : .secondary)
                                            Text("SMART：\(health.status)")
                                                .foregroundStyle(health.warning ? .red : .secondary)
                                            Spacer()
                                            if let protocolName = health.protocolName {
                                                Text(protocolName).foregroundStyle(.secondary)
                                            }
                                        }
                                        .font(.caption)
                                    } else {
                                        Text("SMART：读取中或设备不支持").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(17)
                                if volume.id != volumes.last?.id { Divider().padding(.horizontal, 16) }
                            }
                        }
                    } else {
                        Text("正在读取挂载卷信息…").foregroundStyle(.secondary).padding(18)
                    }
                }
                IsleSectionHeader(title: "备份与恢复", subtitle: "复制当前授权共享目录并逐文件校验 SHA-256；恢复到独立目录，不覆盖现有数据。")
                LiquidGroupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("立即备份…") { model.startBackup() }
                            Button("从备份恢复…") { model.restoreBackup() }
                        }
                        .buttonStyle(IsleActionButtonStyle())
                        .disabled(model.state != .online || model.backupStatus?.running == true)
                        if let report = model.backupStatus {
                            if report.running {
                                ProgressView("正在处理 \(report.files) 个文件")
                                Button("取消当前任务") { model.cancelBackup() }
                                    .buttonStyle(IsleActionButtonStyle(destructive: true))
                            } else if let path = report.lastSnapshot {
                                Text("上次结果：\(path)").textSelection(.enabled)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let metadata = report.restoredMetadata {
                                Text("应用数据库已校验并独立恢复到：\(metadata)。不会覆盖运行中的账号与设置数据库。")
                                    .textSelection(.enabled)
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("验证 Mac 所有者身份并离线应用数据库…") {
                                    model.activateRestoredMetadata()
                                }
                                .buttonStyle(IsleActionButtonStyle(destructive: true))
                                .disabled(model.activatingMetadata || model.state != .online)
                                Text("仅切换已校验的账号、设置和索引数据库；恢复的共享文件仍在独立目录，必须手动检查。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let reason = report.lastError {
                                Text("备份失败：\(reason)").foregroundStyle(.red)
                            }
                        }
                        if model.activatingMetadata {
                            ProgressView("正在验证本机身份并离线切换数据库，请勿关闭应用")
                        }
                        if let message = model.metadataActivationMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                        .buttonStyle(IsleActionButtonStyle())
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
            .padding(IsleTheme.contentPadding)
        }
    }

    // MARK: - Settings View
    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                IsleSectionHeader(title: "管理员安全", subtitle: "忘记轻屿管理员密码时，在 Mac 本机验证 Touch ID 或系统登录密码后重新设置。")
                LiquidGroupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("重置管理员密码")
                            .font(.system(size: 15, weight: .semibold))
                        if let username = model.firstAdminUsername {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("当前首任管理员用户名")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(username)
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("复制用户名") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(username, forType: .string)
                                }
                                .buttonStyle(IsleActionButtonStyle())
                            }
                        }
                        SecureField("新密码，至少 12 位", text: $resetAdminPassword)
                            .textContentType(.newPassword)
                            .modifier(IsleTextFieldSurface())
                        SecureField("再次输入新密码", text: $resetAdminConfirmation)
                            .textContentType(.newPassword)
                            .modifier(IsleTextFieldSurface())
                        if !resetAdminConfirmation.isEmpty && resetAdminPassword != resetAdminConfirmation {
                            Text("两次输入的密码不一致").font(.caption).foregroundStyle(.red)
                        }
                        Button(model.resettingAdmin ? "正在等待系统验证…" : "验证 Mac 身份并重置密码") {
                            let password = resetAdminPassword
                            resetAdminPassword = ""
                            resetAdminConfirmation = ""
                            model.resetAdministratorPassword(newPassword: password)
                        }
                        .buttonStyle(IsleActionButtonStyle(prominent: true))
                        .disabled(model.state != .online || model.isConfigured != true ||
                            model.resettingAdmin || resetAdminPassword.utf8.count < 12 ||
                            resetAdminPassword != resetAdminConfirmation)
                        if let status = model.resetAdminMessage {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("打开当前 Web 登录页面") { model.openUserWeb() }
                            .buttonStyle(IsleActionButtonStyle())
                            .disabled(model.endpoint == nil)
                        Text("请使用上方显示的管理员用户名，手动输入新密码。留意浏览器密码管理器是否自动填入了旧密码。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("仅重置首任管理员密码。旧管理员登录会话立即失效，其他用户不受影响；无需输入旧轻屿密码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18)
                }

                IsleSectionHeader(title: "本机 Web 端口", subtitle: "默认 16666。保存后完全退出并重新打开 LightIsle 生效。")
                LiquidGroupCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text("127.0.0.1 :").font(.system(.body, design: .monospaced))
                            TextField("16666", text: $localPortText)
                                .frame(width: 110)
                                .modifier(IsleTextFieldSurface())
                                .onSubmit { _ = model.saveLocalPort(localPortText) }
                            Button("保存端口") {
                                if model.saveLocalPort(localPortText) {
                                    showNotice("端口已保存，重启应用后生效")
                                }
                            }
                            .buttonStyle(IsleActionButtonStyle())
                        }
                        if let portError = model.portError {
                            Text(portError).font(.caption).foregroundStyle(.red)
                        }
                        if let target = model.endpoint {
                            Text("当前访问地址：\(target.absoluteString)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if let error = model.webOpenError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(18)
                }

                IsleSectionHeader(title: "Touch ID · 管理员凭据", subtitle: "首次需输入现有轻屿管理员密码并验证后，才能将凭据保存到受 Touch ID 保护的 Mac 钥匙串。")
                LiquidGroupCard {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("轻屿管理员用户名", text: $vaultUsername)
                            .textContentType(.username)
                            .modifier(IsleTextFieldSurface())
                        SecureField("当前轻屿管理员密码", text: $vaultPassword)
                            .textContentType(.password)
                            .modifier(IsleTextFieldSurface())
                        HStack(spacing: 12) {
                            Button(model.verifyingAdmin ? "验证中…" : "验证并保存到钥匙串") {
                                model.saveAdministratorWithTouchID(username: vaultUsername, password: vaultPassword)
                                vaultPassword = ""
                            }
                            .disabled(model.state != .online || model.verifyingAdmin ||
                                vaultUsername.isEmpty || vaultPassword.isEmpty)
                            Button("Touch ID 解锁查看") { model.unlockAdministratorWithTouchID() }
                            Button("删除已存凭据") { model.removeSavedAdministrator() }
                                .buttonStyle(IsleActionButtonStyle(destructive: true))
                        }
                        .buttonStyle(IsleActionButtonStyle())
                        if let saved = model.unlockedAdminCredentials {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("管理员：\(saved.username)")
                                Text("已解锁密码：\(saved.password)").textSelection(.enabled)
                            }
                            .font(.system(.caption, design: .monospaced))
                        }
                        if let message = model.vaultMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("这不会读取 macOS 登录密码，也不会绕过 Web 登录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18)
                }

                IsleSectionHeader(title: "应用偏好与关于", subtitle: "LightIsle macOS 原生管理宿主。")

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
                            .buttonStyle(IsleActionButtonStyle())
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
                        .buttonStyle(IsleActionButtonStyle(prominent: true))
                        .disabled(model.endpoint == nil)
                    }
                }
            }
            .padding(IsleTheme.contentPadding)
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
