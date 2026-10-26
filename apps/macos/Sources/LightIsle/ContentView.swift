import SwiftUI
import AppKit

enum SidebarPage: String, CaseIterable, Hashable {
    case overview = "主页"
    case files = "私人文件"
    case photos = "时光相册"
    case cinema = "私人影院"
    case containers = "Docker 与应用"
    case services = "网络与连接"
    case storage = "数据与存储"
    case settings = "偏好与安全"

    var icon: String {
        switch self {
        case .overview: return "house.fill"
        case .files: return "folder.fill"
        case .photos: return "photo.stack.fill"
        case .cinema: return "film.stack.fill"
        case .containers: return "shippingbox.fill"
        case .services: return "network"
        case .storage: return "externaldrive.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .files: return "2"
        case .photos: return "3"
        case .cinema: return "4"
        case .containers: return "8"
        case .services: return "5"
        case .storage: return "6"
        case .settings: return "7"
        }
    }

    var squircleColor: Color {
        switch self {
        case .overview: return .blue
        case .files: return .cyan
        case .photos: return .pink
        case .cinema: return .orange
        case .containers: return .indigo
        case .services: return .green
        case .storage: return .teal
        case .settings: return .purple
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "轻屿功能入口与 Mac 服务状态概览"
        case .files: return "浏览和管理已授权的共享文件目录"
        case .photos: return "浏览共享目录中的照片和视频，并查看媒体预览"
        case .cinema: return "浏览媒体库并播放当前设备支持的视频"
        case .containers: return "管理本机 Docker/Colima 容器与镜像加速源"
        case .services: return "查看本机服务、网络连接和文件共享设置"
        case .storage: return "查看存储用量、共享目录以及备份与恢复状态"
        case .settings: return "管理管理员账户、安全选项和应用偏好"
        }
    }

}

private struct MetadataPreviewRow: Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showingManualIntro = false
    @State private var confirmPlainHTTP = false
    @State private var firstUsername = ""
    @State private var firstPassword = ""
    @State private var confirmPassword = ""
    @State private var copiedNotice: String?
    @State private var backupRetentionDraft: Int?
    @State private var showingRollbackRecovery = false
    @State private var localPortText = ""
    @State private var thumbnailCacheMiB = AppModel.defaultThumbnailCacheMiB
    @State private var vaultUsername = ""
    @State private var vaultPassword = ""
    @State private var resetAdminPassword = ""
    @State private var resetAdminConfirmation = ""
    @State private var processSortByMemory = false
    @State private var showAdvancedDiagnostics = false
    @State private var isSidebarVisible = true
    @State private var expandedDiskHealth: Set<String> = []
    @State private var thresholdFreeMiBText = ""
    @State private var thresholdPercentText = ""
    @State private var presentingTunnelManager = false
    @State private var tmdbTokenDraft = ""
    @State private var notifyBarkServerDraft = ""
    @State private var notifyBarkKeyDraft = ""
    @State private var notifyWebhookDraft = ""
    @State private var notifyAllowPrivateDraft = false
    @State private var notifyWecomDraft = ""
    @State private var notifyDingtalkDraft = ""
    @State private var notifyDingtalkSecretDraft = ""
    @State private var notifySMTPHostDraft = ""
    @State private var notifySMTPPortDraft = "465"
    @State private var notifySMTPUserDraft = ""
    @State private var notifySMTPPasswordDraft = ""
    @State private var notifySMTPFromDraft = ""
    @State private var notifySMTPToDraft = ""
    @State private var trashRetentionDaysText = "30"
    @State private var trashRetentionEnabled = false
    @State private var preferencesSection: PreferencesSection = .general
    @State private var manualTunnelToken = ""
    @State private var presentingSudoersGuide = false
    @State private var sudoersGuideDevice = "disk0"

    var body: some View {
        Group {
            if showingManualIntro {
                IntroAnimationView {
                    showingManualIntro = false
                }
                AppleSettingsRow(title: "企业微信机器人", subtitle: "企业微信群机器人提供的完整 Webhook URL。", icon: "person.3", iconTint: .green) {
                    TextField("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…", text: $notifyWecomDraft)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 350)
                }
                AppleSettingsRow(title: "钉钉机器人", subtitle: "钉钉群自定义机器人 Webhook URL。", icon: "bubble.left.and.bubble.right", iconTint: .blue) {
                    TextField("https://oapi.dingtalk.com/robot/send?access_token=…", text: $notifyDingtalkDraft)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 350)
                }
                AppleSettingsRow(title: "钉钉加签密钥（可选）", subtitle: "留空保留已保存的加签密钥。", icon: "lock.shield", iconTint: .indigo) {
                    SecureField("SEC…", text: $notifyDingtalkSecretDraft)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                }
                Divider().padding(.leading,14)
                AppleSettingsRow(title: "邮件服务器", subtitle: "SMTP 仅允许 465（TLS）或 587（STARTTLS），不支持明文连接。", icon: "envelope", iconTint: .orange) {
                    HStack {
                        TextField("smtp.example.com", text: $notifySMTPHostDraft)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 225)
                        TextField("465", text: $notifySMTPPortDraft)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                }
                AppleSettingsRow(title: "SMTP 登录", subtitle: "账户及授权码。密码留空则沿用钥匙串中已有值。", icon: "key.fill", iconTint: .indigo) {
                    HStack {
                        TextField("SMTP 用户名", text: $notifySMTPUserDraft)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        SecureField("SMTP 授权码", text: $notifySMTPPasswordDraft)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    }
                }
                AppleSettingsRow(title: "发件人与收件人", subtitle: "收件人可输入多个邮箱，以英文逗号分隔，最多 5 个。", icon: "envelope.badge", iconTint: .blue) {
                    VStack(alignment: .leading,spacing: 7) {
                        TextField("发件邮箱", text: $notifySMTPFromDraft).textFieldStyle(.roundedBorder)
                        TextField("收件邮箱，例如 a@example.com,b@example.com", text: $notifySMTPToDraft).textFieldStyle(.roundedBorder)
                    }.frame(maxWidth: 390)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "连接协议", subtitle: "HTTPS 为默认选择；需要无证书连接时可以关闭强制 HTTPS。", icon: "lock.shield", iconTint: .orange) {
                    HStack(spacing: 8) {
                        Button("HTTPS（推荐）") { model.setRemoteEnabled(true, allowHTTP: false) }
                            .disabled(model.state != .online || model.remoteAddress?.hasPrefix("https://") == true)
                        Button("HTTP（不加密）") { confirmPlainHTTP = true }
                            .disabled(model.state != .online || model.remoteAddress?.hasPrefix("http://") == true)
                            .confirmationDialog(
                                "确定允许局域网 HTTP 吗？",
                                isPresented: $confirmPlainHTTP,
                                titleVisibility: .visible
                            ) {
                                Button("仅在可信局域网启用 HTTP", role: .destructive) {
                                    model.setRemoteEnabled(true, allowHTTP: true)
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("HTTP 会明文传输账号密码、登录会话及文件。不会为你开放公网端口；请勿在公共 Wi-Fi 使用。")
                            }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
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
        .sheet(isPresented: $showingRollbackRecovery) {
            VStack(spacing: 16) {
                ScrollView(showsIndicators: false) { metadataRollbackView.padding(20) }
                    .scrollIndicators(.never)
                Button("关闭") { showingRollbackRecovery = false }
                    .disabled(model.activatingMetadata)
                    .padding(.bottom, 16)
            }
            .frame(width: 680, height: 500)
            .interactiveDismissDisabled(model.activatingMetadata)
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
                    Button("重新启动轻屿服务") { model.launch() }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))
                    Button("修复上次中断的数据库恢复…") { model.recoverInterruptedMetadata() }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
                        .disabled(model.activatingMetadata)
                    Button("查看可回退的数据库版本…") {
                        showingRollbackRecovery = true
                        model.refreshMetadataRollbacks()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
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

            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        BrandMark(size: 70)
                            .shadow(color: Color.blue.opacity(0.18), radius: 14, x: 0, y: 6)

                        Text("创建首任管理员")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("轻屿管理本机服务和已授权的共享目录，不提供公网注册。请在当前设备上创建首位管理员账号。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }

                    AppleSettingsGroup {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label("共享数据目录", systemImage: "externaldrive.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Button("选择数据文件夹…") {
                                        model.selectSharedFolder()
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(model.state != .online)
                                }

                                Text("首次安装默认位置")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(defaultSharedFolderPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let currentPath = model.sharedFolderPath {
                                    Text(currentPath == defaultSharedFolderPath
                                         ? "当前正在使用此默认目录"
                                         : "当前共享目录：\(currentPath)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let error = model.sharedFolderError {
                                    Text("当前目录不可用：\(error)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                Text("可现在选择容量足够的内部或外置磁盘，也可之后在“数据与存储”中更改。只有确认选择后才会更改共享目录；现有文件不会自动迁移，也不会更改管理员账号。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Divider()

                            VStack(alignment: .leading, spacing: 5) {
                                Text("管理员账号")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                TextField("3–32 位英文字母、数字或 . _ -", text: $firstUsername)
                                    .liquidInput()
                            }

                            VStack(alignment: .leading, spacing: 5) {
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
                                    .liquidInput()
                            }

                            VStack(alignment: .leading, spacing: 5) {
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
                                    .liquidInput()
                            }

                            if let error = model.initializationError {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                    Text(error)
                                        .font(.caption)
                                }
                                .foregroundStyle(.red)
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
                                    Text(model.initializing ? "正在创建管理员…" : "创建管理员并进入轻屿")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .large))
                            .disabled(!isFormValid || model.initializing || model.state != .online)
                        }
                        .padding(18)
                    }
                    .frame(width: 420)

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
                    .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }

    private var isFormValid: Bool {
        !firstUsername.isEmpty &&
        firstPassword.count >= 12 &&
        firstPassword == confirmPassword
    }

    private var defaultSharedFolderPath: String {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return supportURL
            .appendingPathComponent("LightIsle", isDirectory: true)
            .appendingPathComponent("SharedFiles", isDirectory: true)
            .path
    }

    // MARK: - Management Shell (Unified Liquid Glass Canvas)
    private var managementShell: some View {
        ZStack {
            IsleFluidBackdrop()

            HStack(alignment: .top, spacing: 0) {
                if isSidebarVisible {
                    sidebarView
                        .frame(width: 256)
                        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let initial = ProcessInfo.processInfo.environment["LIGHTISLE_INITIAL_PAGE"],
               let matched = SidebarPage.allCases.first(where: { $0.rawValue == initial || String(describing: $0) == initial }) {
                model.selectedSidebarPage = matched
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(reduceMotion ? nil : IsleMotion.navigation) {
                        isSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(isSidebarVisible ? "隐藏边栏" : "显示边栏")
            }
            ToolbarItem(placement: .primaryAction) {
                StatusBadge(isOnline: model.state == .online, text: model.state.label)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if case .error = model.state { model.launch() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled({ if case .error = model.state { return false }; return true }())
                .help("重新启动核心服务")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.openUserWeb()
                } label: {
                    Label("打开 Web 空间", systemImage: "arrow.up.forward.app")
                }
                .help("在浏览器中打开 Web 空间")
                .disabled(model.endpoint == nil)
            }
        }
        .background(WindowConfigurator())
        .overlay(alignment: .bottomTrailing) {
            if let notice = copiedNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .padding(20)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Sidebar (Fluid Liquid Glass Navigation)
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Brand Crest Header — aligned with Detail Page Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.blue.opacity(0.32), Color.cyan.opacity(0.12), .clear],
                                center: .center, startRadius: 4, endRadius: 24
                            )
                        )
                        .frame(width: 44, height: 44)
                    BrandMark(size: 36)
                        .shadow(color: Color.blue.opacity(0.28), radius: 8, y: 3)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("轻屿")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("v0.1")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                            .foregroundStyle(.blue)
                    }
                    Text("LightIsle for Mac")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 54, alignment: .center)

            // Sectioned Fluid Navigation inside matching Frosted Glass Group Cards
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    sidebarGlassSection(
                        title: "生活空间",
                        items: [.overview, .files, .photos, .cinema]
                    )

                    sidebarGlassSection(
                        title: "系统管理",
                        items: [.containers, .services, .storage, .settings]
                    )
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 12)

            // Bottom Sanctuary Quick Dock — matching AppleSettingsGroup material
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((model.state == .online ? Color.green : Color.orange).opacity(0.14))
                            .frame(width: 24, height: 24)
                        Circle()
                            .fill(model.state == .online ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                            .shadow(color: (model.state == .online ? Color.green : Color.orange).opacity(0.45), radius: 4)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("宿主状态")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(model.state.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    }

                    Spacer(minLength: 6)

                    Button {
                        model.openUserWeb()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Web 空间")
                            Image(systemName: "arrow.up.forward.app")
                        }
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.endpoint == nil)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.04), radius: 16, y: 6)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private func sidebarGlassSection(title: String, items: [SidebarPage]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    sidebarItemRow(item)
                    if index < items.count - 1 {
                        let nextItem = items[index + 1]
                        let hideDivider = (model.selectedSidebarPage == item || model.selectedSidebarPage == nextItem)
                        Divider()
                            .opacity(hideDivider ? 0 : 0.45)
                            .padding(.leading, 42)
                            .padding(.trailing, 8)
                    }
                }
            }
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.04), radius: 16, y: 6)
        }
    }

    private func sidebarItemRow(_ item: SidebarPage) -> some View {
        SidebarNavigationRow(
            item: item,
            isSelected: (model.selectedSidebarPage == item),
            action: { model.selectedSidebarPage = item }
        )
    }

    private struct SidebarNavigationRow: View {
        let item: SidebarPage
        let isSelected: Bool
        let action: () -> Void

        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button(action: action) {
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(
                                isSelected
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [item.squircleColor, item.squircleColor.opacity(0.82)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(item.squircleColor.opacity(hovered ? 0.20 : 0.14))
                            )
                            .frame(width: 24, height: 24)
                            .shadow(
                                color: isSelected ? item.squircleColor.opacity(0.28) : .clear,
                                radius: 5,
                                y: 2
                            )
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : item.squircleColor)
                    }

                    Text(item.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Color.primary.opacity(isSelected || hovered ? 1.0 : 0.82))

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? IsleTheme.accent.opacity(0.75) : Color.secondary.opacity(hovered ? 0.45 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isSelected {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        IsleFluidPalette.cardItemTop.opacity(0.88),
                                        IsleTheme.accent.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                shape.strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.80), IsleTheme.accent.opacity(0.22)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                            )
                            .shadow(color: IsleFluidPalette.shadow.opacity(0.05), radius: 6, y: 2)
                    } else {
                        shape
                            .fill(hovered ? Color.primary.opacity(0.045) : Color.clear)
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { isHovered in
                if !reduceMotion {
                    withAnimation(IsleMotion.quick) { hovered = isHovered }
                } else {
                    hovered = isHovered
                }
            }
        }
    }

    // MARK: - Detail View
    private var detailView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selectedSidebarPage.rawValue)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(model.selectedSidebarPage.subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 54, alignment: .center)

                    Group {
                        switch model.selectedSidebarPage {
                        case .overview:
                            overviewView
                        case .files:
                            filesSpaceView
                        case .photos:
                            photosSpaceView
                        case .cinema:
                            cinemaSpaceView
                        case .containers:
                            DockerManagementView()
                        case .services:
                            servicesView
                        case .storage:
                            storageView
                                .onAppear { model.refreshManagedDisks() }
                        case .settings:
                            settingsView
                        }
                    }

                    Color.clear.frame(height: 1).id("detail-bottom")
                }
                .padding(.leading, 20)
                .padding(.trailing, 32)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.never)
            .onAppear {
                if ProcessInfo.processInfo.environment["LIGHTISLE_SCROLL_BOTTOM"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        proxy.scrollTo("detail-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func showNotice(_ message: String) {
        withAnimation(reduceMotion ? nil : IsleMotion.quick) { copiedNotice = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if copiedNotice == message {
                withAnimation(reduceMotion ? nil : IsleMotion.quick) { copiedNotice = nil }
            }
        }
    }

    // MARK: - Overview (Home Sanctuary)
    private var backupNeedsAttention: Bool {
        guard let backup = model.timeMachineDiagnostics else { return true }
        return !backup.destinationKnown || backup.destinationNames.isEmpty ||
            backup.sharedFolder != .included || backup.metadataFolder != .included ||
            backup.latestBackupPath == nil
    }

    private var overviewView: some View {
        VStack(spacing: 24) {
            // Hero: Living Sanctuary Hall Card
            LiquidGlassCard(cornerRadius: 24, padding: 22) {
                VStack(spacing: 18) {
                    HStack(alignment: .center, spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [Color.blue.opacity(0.35), Color.cyan.opacity(0.12), .clear],
                                        center: .center, startRadius: 10, endRadius: 36
                                    )
                                )
                                .frame(width: 68, height: 68)
                            BrandMark(size: 52)
                                .shadow(color: Color.blue.opacity(0.28), radius: 12, y: 4)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(model.metrics?.hostname ?? "本地 Mac")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))

                                Text("Apple Silicon · Beta 2")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                                    .foregroundStyle(.blue)

                                Spacer()

                                StatusBadge(isOnline: model.state == .online, text: model.state.label)
                            }

                            Text("正在本地安全守护你的私人文件、时光相册与家庭影院。")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Bottom action row & storage pulse
                    HStack(spacing: 12) {
                        // Quick storage health summary
                        let m = model.metrics
                        let hasDiskSample = (m?.diskTotal ?? 0) > 0
                        let diskTotal = max(m?.diskTotal ?? 0, 1)
                        let diskFree = min(m?.diskFree ?? 0, diskTotal)
                        let diskUsed = diskTotal - diskFree
                        let diskP = Double(diskUsed) / Double(diskTotal)

                        HStack(spacing: 8) {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.teal)
                            Text("存储剩余")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(hasDiskSample ? formatBytes(diskFree) : "等待采样")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)

                            // Mini segmented storage bar
                            GeometryReader { p in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5)
                                    Capsule()
                                        .fill(LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: hasDiskSample ? max(0, min(p.size.width, p.size.width * CGFloat(diskP))) : 0, height: 5)
                                }
                            }
                            .frame(width: 80, height: 5)

                            Text(hasDiskSample ? "共 \(formatBytes(diskTotal))" : "尚未取得容量")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.primary.opacity(0.04)))

                        Spacer()

                        if let path = model.sharedFolderPath {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "folder")
                                    Text("在访达中定位")
                                }
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }

                        Button {
                            model.openUserWeb()
                        } label: {
                            HStack(spacing: 6) {
                                Text("进入 Web 空间")
                                Image(systemName: "arrow.up.forward.app")
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(model.endpoint == nil)
                    }
                }
            }

            if model.sharedFolderPath != nil {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text(backupNeedsAttention
                         ? "尚未确认 NAS 文件和账号资料有可用的独立备份；请检查备份目标、排除规则及最近备份。"
                         : "Time Machine 已显示备份配置，但无法据此证明 NAS 外置源卷确实备份成功；仍须人工核对实际备份内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("检查备份") { model.selectedSidebarPage = .storage }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                .padding(14)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }

            // Section 1: The Three Digital Sanctuaries (3D Tactile Cards)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("我的内容")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("通过 Web 或客户端访问")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    LiquidSanctuaryTile(
                        title: "私人文件",
                        subtitle: "共享目录 / 全格式即时存取",
                        detail: "\(model.sharedFolderName) · 仅授权账号可访问",
                        icon: "folder.fill",
                        gradientColors: [Color.cyan, Color.blue],
                        badgeText: "本地共享",
                        action: { model.openUserWeb(page: "files") }
                    )

                    LiquidSanctuaryTile(
                        title: "时光相册",
                        subtitle: "时间线浏览 / 本地媒体索引",
                        detail: "\(thumbnailCacheMiB >= 1024 ? "\(thumbnailCacheMiB / 1024) GiB" : "\(thumbnailCacheMiB) MiB") 缩略图缓存",
                        icon: "photo.stack.fill",
                        gradientColors: [Color(red: 0.95, green: 0.35, blue: 0.6), Color.purple],
                        badgeText: "原片留在本机",
                        action: { model.openUserWeb(page: "photos") }
                    )

                    LiquidSanctuaryTile(
                        title: "私人影院",
                        subtitle: "支持的格式原画直放",
                        detail: "家庭影音库 · 播放能力取决于设备与编码",
                        icon: "film.stack.fill",
                        gradientColors: [Color.orange, Color(red: 0.95, green: 0.3, blue: 0.2)],
                        badgeText: "本地影音",
                        action: { model.openUserWeb(page: "cinema") }
                    )
                }
            }

            // Section 2: Sanctuary Pulse (Compact Vitality Dashboard)
            let m = model.metrics
            let cpuP = m?.cpuPercent.map { $0 / 100.0 }
            let hasMemorySample = (m?.memoryTotal ?? 0) > 0
            let memTotal = max(m?.memoryTotal ?? 0, 1)
            let memUsed = min(m?.memoryUsed ?? 0, memTotal)
            let memP = Double(memUsed) / Double(memTotal)
            let hasDiskSample = (m?.diskTotal ?? 0) > 0
            let diskTotal = max(m?.diskTotal ?? 0, 1)
            let diskFree = min(m?.diskFree ?? 0, diskTotal)
            let diskUsed = diskTotal - diskFree
            let diskP = Double(diskUsed) / Double(diskTotal)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Mac 运行状态")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("本地实时采样 · 绝不向云端上报")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    LiquidHealthGauge(
                        title: "计算核心利用率",
                        valueText: m?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "等待采样",
                        subtext: m.map { "\($0.cpuCount) 个计算核心" } ?? "尚未取得处理器用量",
                        progress: cpuP,
                        tint: .blue,
                        icon: "cpu"
                    )

                    LiquidHealthGauge(
                        title: "统一内存用量",
                        valueText: hasMemorySample ? formatBytes(memUsed) : "等待采样",
                        subtext: hasMemorySample ? "总计 \(formatBytes(memTotal))" : "尚未取得内存用量",
                        progress: hasMemorySample ? memP : nil,
                        tint: .purple,
                        icon: "memorychip"
                    )

                    LiquidHealthGauge(
                        title: "存储可用空间",
                        valueText: hasDiskSample ? formatBytes(diskFree) : "等待采样",
                        subtext: hasDiskSample ? "已用 \(formatBytes(diskUsed))" : "尚未取得磁盘容量",
                        progress: hasDiskSample ? diskP : nil,
                        tint: .teal,
                        icon: "internaldrive"
                    )

                    LiquidHealthGauge(
                        title: "当前网络流量",
                        valueText: "↓ \(m?.networkDownBps.map { "\(formatBytes(UInt64(max(0, $0))))/s" } ?? "等待采样")",
                        subtext: "↑ \(m?.networkUpBps.map { "\(formatBytes(UInt64(max(0, $0))))/s" } ?? "等待采样")",
                        progress: nil,
                        tint: .indigo,
                        icon: "network"
                    )
                }
            }

            // Section 3: Advanced Diagnostics (Smooth Collapsible Fold)
            LiquidGlassCard(cornerRadius: 18, padding: 14) {
                DisclosureGroup(isExpanded: $showAdvancedDiagnostics) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let coreRSS = model.metrics?.coreRssBytes, let pid = model.metrics?.corePid {
                            HStack {
                                Text("Go Core PID: \(pid)")
                                Spacer()
                                Text("常驻物理内存: \(formatBytes(coreRSS))")
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            IsleHistoryGraph(title: "处理器利用率 (%)", values: model.metricHistory.map(\.cpu), maximum: 100, tint: .blue)
                            IsleHistoryGraph(title: "内存使用率 (%)", values: model.metricHistory.map(\.memory), maximum: 100, tint: .purple)
                            IsleHistoryGraph(title: "网络下载速率", values: model.metricHistory.map(\.download), maximum: max(model.metricHistory.map(\.download).max() ?? 1, 1), tint: .teal)
                            IsleHistoryGraph(title: "网络上传速率", values: model.metricHistory.map(\.upload), maximum: max(model.metricHistory.map(\.upload).max() ?? 1, 1), tint: .indigo)
                        }

                        processMonitorView
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.blue.opacity(0.14))
                                .frame(width: 26, height: 26)
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                        Text("高级系统遥测与采样分析")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    // MARK: - Space Detail Views
    private var filesSpaceView: some View {
        VStack(alignment: .leading, spacing: 12) {
        spaceDetailCard(
            title: "私人文件",
            subtitle: "Mac 本地高速共享目录已锚定，支持全格式文档、音视频与数据压缩包随时跨端存取与管理。",
            icon: "folder.fill",
            gradient: [.cyan, .blue],
            badgeText: "本地共享",
            infoPairs: [
                ("共享目录名称", model.sharedFolderName),
                ("物理存储路径", model.sharedFolderPath ?? "未设置"),
                ("文件访问", "通过已授权的本地或局域网连接访问"),
                ("跨端支持", "Mac 访达 · Web / PWA · Flutter 客户端")
            ],
            primaryTitle: model.sharedFolderPath == nil ? "共享目录未设置 · 去选择存储位置" : "在访达中定位文件夹",
            primaryAction: {
                if let path = model.sharedFolderPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    model.selectedSidebarPage = .storage
                }
            },
            secondaryTitle: "在 Web 空间查看文件 ↗",
            secondaryAction: { model.openUserWeb(page: "files") }
        )
        Button {
            model.selectedSidebarPage = .storage
        } label: {
            Label("设置文件存储位置 / 选择外接硬盘", systemImage: "externaldrive.badge.plus")
        }
        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))
        }
    }

    private var photosSpaceView: some View {
        spaceDetailCard(
            title: "时光相册",
            subtitle: "本地智能解析与缩略图加速，珍藏每一刻珍贵回忆，端到端本地处理，绝不上报视觉内容。",
            icon: "photo.stack.fill",
            gradient: [Color(red: 0.95, green: 0.35, blue: 0.6), .purple],
            badgeText: "原片留在本机",
            infoPairs: [
                ("相册智能缓存", "\(thumbnailCacheMiB >= 1024 ? "\(thumbnailCacheMiB / 1024) GiB" : "\(thumbnailCacheMiB) MiB") 本地空间"),
                ("原片与原图", "存放于 Mac 本地共享目录，保留 Exif 完整元数据"),
                ("隐私等级", "端到端本地解析 · 绝不上报任何视觉内容"),
                ("浏览体验", "时间线智能平滑滚动 · 原图秒级放大")
            ],
            primaryTitle: "在 Web 空间打开时光相册 ↗",
            primaryAction: { model.openUserWeb(page: "photos") },
            secondaryTitle: "管理相册存储与缓存",
            secondaryAction: { model.selectedSidebarPage = .storage }
        )
    }

    private var cinemaSpaceView: some View {
        spaceDetailCard(
            title: "私人影院",
            subtitle: "家庭多媒体娱乐中心，直放优先；安装 Homebrew FFmpeg 后可转封装与硬件转码。",
            icon: "film.stack.fill",
            gradient: [.orange, Color(red: 0.95, green: 0.3, blue: 0.2)],
            badgeText: "直放优先",
            infoPairs: [
                ("媒体串流协议", "HTTP 206 范围请求直放 · 浏览器可解码格式直接播放"),
                ("转码与降级", "未装 FFmpeg 时诚实降级为直放/下载，不虚标能力"),
                ("多语言字幕", "SRT / VTT 外挂字幕与内嵌字幕抽取（需 FFmpeg）"),
                ("观影断点记忆", "多终端自动同步播放进度")
            ],
            primaryTitle: "在 Web 空间开启私人影院 ↗",
            primaryAction: { model.openUserWeb(page: "cinema") },
            secondaryTitle: "管理影音媒体卷",
            secondaryAction: { model.selectedSidebarPage = .storage }
        )
    }

    private func spaceDetailCard(
        title: String,
        subtitle: String,
        icon: String,
        gradient: [Color],
        badgeText: String,
        infoPairs: [(String, String)],
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 20) {
            LiquidGlassCard(cornerRadius: 24, padding: 22) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 56, height: 56)
                                .shadow(color: (gradient.first ?? .blue).opacity(0.35), radius: 10, y: 4)
                            Image(systemName: icon)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(title)
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                Text(badgeText)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                    .foregroundStyle(.secondary)
                            }
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(spacing: 8) {
                        ForEach(infoPairs, id: \.0) { key, val in
                            HStack {
                                Text(key)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(val)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: primaryAction) {
                            HStack(spacing: 6) {
                                Text(primaryTitle)
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .regular))

                        Button(action: secondaryAction) {
                            Text(secondaryTitle)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .regular))

                        Spacer()

                        Button("返回主页概览") {
                            model.selectedSidebarPage = .overview
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Services View (Network & Sharing)
    private var servicesView: some View {
        VStack(spacing: 20) {
            AppleSettingsGroup(title: "核心服务", footer: "LightIsle 服务随原生应用自动静默启停，退出时释放端口与子进程。") {
                AppleSettingsRow(title: "运行状态", icon: "waveform.path.ecg", iconTint: .green) {
                    StatusBadge(isOnline: model.state == .online, text: model.state.label)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "本机服务地址", icon: "desktopcomputer", iconTint: .blue) {
                    HStack(spacing: 8) {
                        Text(model.endpoint?.absoluteString ?? "未启动")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
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
            }

            AppleSettingsGroup(title: "局域网访问", footer: "默认开启 HTTPS（推荐）。如果无法使用 HTTPS，可以主动选择局域网 HTTP；HTTP 不加密登录密码、Cookie 和文件，仅适用于可信家庭网络，切勿端口映射到公网。") {
                AppleSettingsRow(title: "局域网远程连接", icon: "wifi", iconTint: .indigo) {
                    Toggle("", isOn: Binding(
                        get: { model.isRemoteEnabled },
                        set: { model.setRemoteEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(model.state != .online)
                }
                if let address = model.remoteAddress {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "远程访问地址", icon: "globe", iconTint: .cyan) {
                        HStack(spacing: 8) {
                            Text(address)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.blue)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                                showNotice("已复制远程地址")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制远程地址")

                            if let url = URL(string: address) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                                .help("在浏览器中打开远程地址")
                            }
                        }
                    }
                    if let fingerprint = model.remoteFingerprint {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "证书 SHA-256 指纹", icon: "lock.shield", iconTint: .teal) {
                            HStack(spacing: 8) {
                                Text(fingerprint)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                    showNotice("已复制证书指纹")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                                .help("复制证书指纹")
                            }
                        }
                    }
                }
                if let error = model.remoteError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "连接异常", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            AppleSettingsGroup(title: "macOS 原生文件共享 (SMB)", footer: "使用 macOS 系统账号/共享 ACL；不会复用轻屿 Web 成员权限。仅检查 TCP 445 是否监听，不代表已成功配置共享目录；请勿直接将整棵私人 NAS 目录公开。") {
                AppleSettingsRow(title: "SMB 服务状态 (TCP 445)", icon: "externaldrive.connected.to.line.below", iconTint: .orange) {
                    HStack(spacing: 12) {
                        Text(model.smbListening.map { $0 ? "正在监听" : "未监听" } ?? "检测中")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.smbListening == true ? .green : .secondary)
                        Button("系统共享设置…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(
                    title: "文件共享（供手机和另一台 Mac 访问）",
                    subtitle: "到系统设置 → 通用 → 共享 → 文件共享，单独添加授权共享目录，并使用 macOS 用户账号设置访问权限。",
                    icon: "folder.badge.person.crop",
                    iconTint: .blue
                ) {
                    EmptyView()
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(
                    title: "本机作为 Time Machine 备份目的地",
                    subtitle: "为其他 Mac 建立专用共享目录，在 macOS 文件共享选项中启用“作为 Time Machine 备份目的地”；不要直接复用整棵 NAS 私人文件根。",
                    icon: "clock.badge.checkmark",
                    iconTint: .teal
                ) {
                    EmptyView()
                }
            }

            AppleSettingsGroup(title: "私人组网（可选）", footer: "推荐仅在个人设备之间通过现有 VPN/Tailnet 访问，不直接向公网开放 NAS。LightIsle 不安装 VPN，也不会修改系统路由、防火墙或共享权限。") {
                AppleSettingsRow(
                    title: "在家庭网络之外访问",
                    subtitle: "先在 macOS 上启用局域网 HTTPS；远程设备加入同一私有网络后使用受信任地址，并核对证书指纹。",
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

            AppleSettingsGroup(title: "Bonjour 局域网发现", footer: "仅当 LightIsle 局域网监听已开启时广播实际 HTTP/HTTPS 协议；HTTPS 需要校验证书，HTTP 必须在手机端明确允许。") {
                AppleSettingsRow(title: "自动发现状态", icon: "dot.radiowaves.left.and.right", iconTint: .cyan) {
                    Text(model.bonjourStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            AppleSettingsGroup(
                title: "Cloudflare Tunnel（可选）",
                footer: "使用本机已安装的 cloudflared 把 NAS 暴露到公网。免费模式每次启动生成随机临时域名，仅供测试；API Key 模式通过你自己的 Cloudflare 账号创建命名隧道并一键绑定域名。Token 只保存在本机钥匙串，不会写入日志。若系统代理拦截，需对 argotunnel.com 放行直连。"
            ) {
                AppleSettingsRow(title: "cloudflared 二进制", icon: "terminal", iconTint: .gray) {
                    Text(tunnelBinaryDescription)
                        .font(.caption)
                        .foregroundStyle(model.tunnelState?.binaryFound == true ? Color.secondary : Color.orange)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "隧道状态", icon: "point.topleft.down.curvedto.point.bottomright.up", iconTint: .teal) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tunnelStatusDescription)
                            .font(.caption)
                            .foregroundStyle(tunnelStatusColor)
                        if let lastLine = model.tunnelState?.lastLine, !lastLine.isEmpty {
                            Text(lastLine)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(lastLine)
                        }
                    }
                }
                Divider().padding(.leading, 14)
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
                                .foregroundStyle(.blue)
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
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "API Key 模式", subtitle: "填写 Cloudflare API Token 后可创建/删除隧道、一键绑定公共主机名（自动配置 DNS 与路由）。", icon: "key.fill", iconTint: .indigo) {
                    Button("管理隧道…") {
                        presentingTunnelManager = true
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.state != .online)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "高级：运行已有隧道 Token", subtitle: "已通过 Cloudflare 控制台创建的隧道，可直接粘贴其 Token 启动。", icon: "authenticator", iconTint: .purple) {
                    HStack(spacing: 8) {
                        SecureField("粘贴隧道 Token", text: $manualTunnelToken)
                            .frame(width: 210)
                            .textFieldStyle(.roundedBorder)
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
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "隧道异常", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                        Text(tunnelErrorDescription(error))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .task { model.refreshTunnel() }
            .sheet(isPresented: $presentingTunnelManager) {
                TunnelManagementView(model: model)
            }

            AppleSettingsGroup(
                title: "FRP 穿透（可选）",
                footer: "LightIsle 不附带 FRP 程序。一键下载的是官方 frpc 客户端，不包含 frps 服务端。必须先拥有自己的 FRP 服务端，并编辑 TOML 配置。默认不自动连接或开放公网；尤其不要把未加密的 HTTP 服务直接映射到公网。"
            ) {
                AppleSettingsRow(title: "FRP 客户端", subtitle: "官方 frpc · macOS Apple Silicon · SHA-256 校验后安装", icon: "arrow.down.circle", iconTint: .cyan) {
                    HStack(spacing: 8) {
                        Text(model.frpState?.installed == true
                             ? "已安装 \(model.frpState?.version.isEmpty == false ? "v\(model.frpState?.version ?? "")" : "（版本未知）")"
                             : "未安装")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.frpState?.status == "installing" {
                            ProgressView().controlSize(.small)
                            Text("v\(model.frpState?.installingVersion ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "可选版本", subtitle: "自动获取官方发行版本；切换版本不会修改 frpc.toml。", icon: "shippingbox", iconTint: .blue) {
                    HStack(spacing: 8) {
                        Picker("FRP 版本", selection: Binding(
                            get: { model.selectedFRPVersion },
                            set: { model.selectFRPVersion($0) }
                        )) {
                            Text("请选择版本").tag("")
                            ForEach(model.frpVersions) { release in
                                Text(release.displayName).tag(release.version)
                                    .disabled(!release.installable)
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
                                      model.frpState?.status == "installing")
                        }
                    }
                }
                if !model.frpVersions.isEmpty {
                    AppleSettingsRow(title: "发行信息", icon: "info.circle", iconTint: .gray) {
                        Text("共 \(model.frpVersions.count) 个版本 · 默认选择最新稳定版")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "配置文件", subtitle: "用户使用本地编辑器修改 frpc.toml；再次下载不会覆盖原配置。", icon: "doc.text", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        Button("打开配置文件") { model.openFRPConfig() }
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
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "FRP 连接", subtitle: "修改配置后停止并重新启动才会应用配置。", icon: "network", iconTint: .teal) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.frpState?.status == "running" ? Color.green :
                                  model.frpState?.status == "error" ? Color.red : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(model.frpState?.statusDescription ?? "等待 Core 就绪…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let pid = model.frpState?.pid, pid > 0 {
                            Text("PID \(pid)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if model.frpState?.status == "running" {
                            Button("停止") { model.stopFRP() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        } else {
                            Button("启动") { model.startFRP() }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(model.state != .online ||
                                          model.frpState?.installed != true ||
                                          model.frpState?.status == "installing")
                        }
                    }
                }
                if let issue = model.frpError ?? model.frpState?.error {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "操作提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(frpErrorDescription(issue))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .task {
                model.refreshFRP()
                if model.frpVersions.isEmpty { model.refreshFRPVersions() }
            }

            AppleSettingsGroup(title: "Bonjour 局域网发现", footer: "根据当前局域网监听广播 HTTP 或 HTTPS，广播不代表免验证登录或自动信任证书。") {
                AppleSettingsRow(title: "自动发现状态", icon: "dot.radiowaves.left.and.right", iconTint: .cyan) {
                    Text(model.bonjourStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Storage View (Data & Volumes)
    private var storageView: some View {
        VStack(spacing: 20) {
            AppleSettingsGroup(title: "硬盘基础管理", footer: "硬盘操作由 Go Core 与管理员 Web 共用一套受控逻辑。系统盘和正在作为 NAS 存储使用的硬盘不能执行危险操作；不支持强制卸载或自动格式化。") {
                AppleSettingsRow(title: "外置磁盘设备", icon: "externaldrive", iconTint: .blue) {
                    HStack(spacing: 12) {
                        Text("容量、文件系统、SMART 与挂载状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("刷新设备列表") { model.refreshManagedDisks() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.diskOperationPending)
                    }
                }
                if model.diskOperationPending {
                    ProgressView("正在等待 macOS 完成磁盘操作…")
                        .controlSize(.small).padding(.horizontal, 14).padding(.bottom, 10)
                }
                if let error = model.diskManagementError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled).padding(.horizontal, 14).padding(.bottom, 10)
                }
                if let message = model.elevationMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled).padding(.horizontal, 14).padding(.bottom, 10)
                }
                if model.managedDisks.isEmpty {
                    Text("尚未检测到可管理的外置磁盘，或尚未刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
                ForEach(model.managedDisks) { disk in
                    Divider().padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.teal)
                            Text(disk.name).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(disk.mounted ? (disk.readOnly ? "只读" : "已挂载") : "未挂载")
                                .font(.caption).foregroundStyle(disk.readOnly ? .orange : .secondary)
                        }
                        Text("\(disk.id) · \(disk.filesystem.isEmpty ? "格式未知" : disk.filesystem) · \(disk.protocolName.isEmpty ? "连接方式未知" : disk.protocolName)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("SMART：\(disk.smart.isEmpty ? "未知（设备可能不提供）" : disk.smart) · \(disk.total > 0 ? "总容量 \(formatBytes(disk.total))" : "容量未知")\(disk.mounted ? " · 可用 \(formatBytes(disk.free))" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if disk.mounted {
                                Button("重命名…") { model.manageDisk(disk, action: "rename") }
                                    .disabled(model.diskOperationPending || disk.identity.isEmpty)
                                Button("安全弹出…") { model.manageDisk(disk, action: "eject") }
                                    .disabled(model.diskOperationPending || disk.identity.isEmpty)
                            } else {
                                Button("挂载") { model.manageDisk(disk, action: "mount") }
                                    .disabled(model.diskOperationPending || disk.identity.isEmpty)
                            }
                            Button(expandedDiskHealth.contains(disk.id) ? "收起健康详情" : "健康详情…") {
                                if expandedDiskHealth.contains(disk.id) {
                                    expandedDiskHealth.remove(disk.id)
                                } else {
                                    expandedDiskHealth.insert(disk.id)
                                    model.refreshDiskHealth(disk)
                                }
                            }
                            if disk.identity.isEmpty {
                                Text("无法验证唯一身份，仅允许查看。").font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        if expandedDiskHealth.contains(disk.id), let report = model.diskHealthReports[disk.parent] {
                            DiskHealthDetails(report: report, fallbackSMART: disk.smart)
                            if report.reason == "smartctl_permission_required" {
                                HStack(spacing: 8) {
                                    Button(model.elevatingDisks.contains(disk.id) ? "正在授权读取…" : "使用管理员权限读取…") {
                                        model.elevateDiskHealth(disk)
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                    .disabled(model.elevatingDisks.contains(disk.id) || model.state != .online)
                                    Button("sudoers 免密指引…") {
                                        sudoersGuideDevice = disk.parent
                                        presentingSudoersGuide = true
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    if model.elevatingDisks.contains(disk.id) {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
            .sheet(isPresented: $presentingSudoersGuide) {
                SudoersGuideView(device: sudoersGuideDevice)
            }
            if model.sharedFolderPath == nil, let offlinePath = model.offlineSharedFolderPath {
                AppleSettingsGroup(title: "共享存储已离线", footer: "默认保留旧盘绑定和照片、影视等本地记录；只有你主动确认清理时才会放弃旧盘绑定。") {
                    VStack(alignment: .leading, spacing: 11) {
                        Label("请连接原来的存储磁盘，然后点击「重新连接」", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("原共享路径：\(offlinePath)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("如果暂时不连接，可以保留所有绑定和媒体资料，待将来接回磁盘；也可以清理该盘在轻屿中的旧记录，并改用 Mac 本机存储。不会删除离线盘上的原始文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("重新连接原磁盘") { model.retrySharedFolder() }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(model.state != .online || model.offlineCleanupPending)
                            Button("保留记录，稍后连接") { model.keepOfflineShare() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(model.offlineCleanupPending)
                            Button("清理离线盘的记录…") { model.forgetOfflineShare() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(!model.canForgetOfflineShare)
                        }
                        if model.offlineCleanupPending {
                            ProgressView("正在校验并清理离线记录…").controlSize(.small)
                        }
                        if let result = model.offlineCleanupMessage {
                            Text(result).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
            }
            AppleSettingsGroup(title: "当前 NAS 存储位置", footer: "个人 Beta 仅使用一个共享根目录。文件、照片和影视共用这里；设置不会自动迁移旧目录内容。") {
                AppleSettingsRow(title: "当前共享根目录", icon: "folder.fill", iconTint: .blue) {
                    HStack(spacing: 10) {
                        Text(model.sharedFolderName)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Spacer(minLength: 0)
                        if let path = model.sharedFolderPath {
                            Button("在访达中打开") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                        Button("选择其他文件夹…") {
                            model.selectSharedFolder()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(!model.canChangeSharedStorage)
                        Button("重新连接") {
                            model.retrySharedFolder()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online || model.storageSelectionPending)
                    }
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "实际存储路径", icon: "externaldrive", iconTint: .teal) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.sharedFolderPath ?? "共享目录离线或尚未完成设置")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let volumes = model.metrics?.volumes,
                           let mount = StorageVolumeSelection.matchingMount(
                                for: model.sharedFolderPath, mounts: volumes.map(\.mount)
                           ),
                           let volume = volumes.first(where: { $0.mount == mount }) {
                            Text("所在磁盘：\(volume.name) · 可用 \(formatBytes(volume.free)) / 共 \(formatBytes(volume.total))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if model.sharedFolderPath != nil {
                            Text("尚未识别所属磁盘，请刷新服务指标并确认磁盘挂载状态。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if model.storageSelectionPending {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "正在切换", icon: "hourglass", iconTint: .blue) {
                        ProgressView("正在等待 NAS Core 验证磁盘身份…").controlSize(.small)
                    }
                }
                if let message = model.storageSelectionMessage {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "设置结果", icon: "info.circle", iconTint: .blue) {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let error = model.sharedFolderError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "目录异常", icon: "exclamationmark.triangle.fill", iconTint: .red) {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            if model.rootManagement.enabled {
                RootManagementView(model: model.rootManagement)
            }

            if let volumes = model.metrics?.volumes, !volumes.isEmpty {
                AppleSettingsGroup(title: "可用磁盘与存储位置", footer: "选择可写外置磁盘中的专用文件夹作为 NAS 存储位置；不能直接把整块盘设为共享目录。容量和 SMART 状态来自 macOS，SMART 未知不代表健康。") {
                    ForEach(volumes) { volume in
                        let usedRatio = Double(volume.total - min(volume.free, volume.total)) / Double(max(volume.total, 1))
                        let tintColor: Color = volume.mount == "/" ? .blue : .teal
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(tintColor.opacity(0.14))
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(tintColor.opacity(0.22), lineWidth: 1)
                                        )
                                    Image(systemName: volume.mount == "/" ? "internaldrive.fill" : "externaldrive.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(tintColor)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(volume.mount == "/" ? "系统磁盘" : volume.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("\(volume.filesystem) · \(volume.mount)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Text(volume.readOnly ? "只读" : "已挂载")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill((volume.readOnly ? Color.orange : Color.green).opacity(0.12)))
                                    .foregroundStyle(volume.readOnly ? .orange : .green)
                            }
                            HStack(spacing: 12) {
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.06))
                                            .frame(height: 6)
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [tintColor, tintColor.opacity(0.72)],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                            .frame(width: max(0, min(proxy.size.width * CGFloat(max(0, min(1, usedRatio))), proxy.size.width)), height: 6)
                                    }
                                }
                                .frame(height: 6)

                                Text("可用 \(formatBytes(volume.free)) / 共 \(formatBytes(volume.total))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if let disk = model.managedDisks.first(where: { $0.mount == volume.mount }) {
                                let warning = ["failing", "failed", "failure"].contains(disk.smart.lowercased())
                                HStack(spacing: 6) {
                                    Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                                        .foregroundStyle(warning ? .red : .teal)
                                    Text("SMART: \(disk.smart.isEmpty ? "未知（设备未提供）" : disk.smart)")
                                        .foregroundStyle(warning ? .red : .secondary)
                                    Spacer()
                                    if !disk.protocolName.isEmpty {
                                        Text(disk.protocolName)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                            if let activity = diskActivity(for: volume.device) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.triangle.swap")
                                        .foregroundStyle(.teal)
                                    Text(activity)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                            let isCurrentDisk = model.sharedFolderPath != nil &&
                                StorageVolumeSelection.matchingMount(
                                    for: model.sharedFolderPath,
                                    mounts: volumes.map(\.mount)
                                ) == volume.mount
                            HStack(spacing: 8) {
                                if isCurrentDisk {
                                    Label("当前 NAS 存储所在磁盘", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.teal)
                                } else if volume.readOnly {
                                    Text(volume.filesystem.lowercased().contains("ntfs")
                                         ? "NTFS：macOS 默认只能读取，无法直接写入。可以使用磁盘工具格式化为 APFS 或 exFAT。"
                                         : "只读磁盘，无法直接作为存储目标；请检查磁盘权限及文件系统。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if volume.mount == "/" {
                                    Text("系统磁盘：可通过上方「选择其他文件夹」使用主目录")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if StorageVolumeSelection.canChooseOnVolume(
                                    mount: volume.mount, readOnly: volume.readOnly
                                ) {
                                    Button(isCurrentDisk ? "更改此磁盘内的目录…" : "在此磁盘选择存储目录…") {
                                        model.selectSharedFolder(onVolume: volume)
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(!model.canChangeSharedStorage)
                                }
                                if StorageVolumeSelection.canInspectExternalVolume(mount: volume.mount) {
                                    Button("格式化磁盘…") {
                                        model.openDiskFormattingGuide(for: volume)
                                    }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(isCurrentDisk || model.offlineCleanupPending)
                                }
                                if isCurrentDisk && StorageVolumeSelection.canInspectExternalVolume(mount: volume.mount) {
                                    Text("NAS 正在使用，切换存储目录后才可格式化")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        if volume.id != volumes.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            } else {
                AppleSettingsGroup(title: "可用磁盘与存储位置") {
                    AppleSettingsRow(title: "未取得磁盘列表", icon: "externaldrive", iconTint: .orange) {
                        HStack {
                            Text("请确认外置磁盘已挂载，然后刷新服务状态。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("刷新") { model.refreshMetrics() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                .disabled(model.state != .online)
                        }
                    }
                }
            }

            AppleSettingsGroup(title: "低空间告警阈值", footer: "剩余空间低于绝对值或总容量的百分比之一时发出告警并通知；两个条件任一满足即触发。适用于 NAS 存储卷。") {
                AppleSettingsRow(title: "告警阈值", icon: "exclamationmark.triangle", iconTint: .orange) {
                    HStack(spacing: 8) {
                        TextField("剩余 GiB", text: $thresholdFreeMiBText)
                            .frame(width: 74)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Text("GiB 或")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("百分比", text: $thresholdPercentText)
                            .frame(width: 56)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Text("%")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("保存") { applyThresholdDraft() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online)
                    }
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "当前生效阈值", subtitle: "留空表示保持该侧不变；两项同时为 0 会被拒绝。", icon: "scalemass", iconTint: .indigo) {
                    Text(thresholdSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                model.refreshStorageThreshold()
                syncThresholdDraft()
            }
            .onChange(of: model.storageThreshold) { _, _ in syncThresholdDraft() }

            AppleSettingsGroup(title: "回收站自动清理", footer: "开启后，入站超过指定天数的回收站条目会在后台自动永久删除；关闭则一直保留，直到管理员手动清理。删除不可恢复，请确认已有独立备份。") {
                AppleSettingsRow(title: "启用自动清理", icon: "trash", iconTint: .orange) {
                    Toggle("", isOn: Binding(
                        get: { trashRetentionEnabled },
                        set: { value in
                            trashRetentionEnabled = value
                            model.applyTrashRetention(days: Int(trashRetentionDaysText) ?? 30, enabled: value)
                        }
                    ))
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "保留天数", subtitle: "回收站条目入站后保留的天数（1–365）。", icon: "calendar.badge.clock", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        TextField("天数", text: $trashRetentionDaysText)
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button("保存") {
                            model.applyTrashRetention(days: Int(trashRetentionDaysText) ?? 0, enabled: trashRetentionEnabled)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online)
                    }
                }
                if let error = model.trashRetentionError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "设置未生效", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .task {
                model.refreshTrashRetention()
                trashRetentionEnabled = model.trashRetention.enabled
                trashRetentionDaysText = String(model.trashRetention.days)
            }
            .onChange(of: model.trashRetention) { _, value in
                trashRetentionEnabled = value.enabled
                trashRetentionDaysText = String(value.days)
            }

            AppleSettingsGroup(title: "跨磁盘安全迁移与归档", footer: "安全复制支持文件/文件夹；日志化安全移动当前仅支持单文件。先校验目标并持久记录，再把源移入轻屿回收站。失败/中断可能留下两个副本，不自动销毁任何数据。") {
                AppleSettingsRow(title: "跨卷迁移归档", icon: "arrow.left.arrow.right", iconTint: .purple) {
                    HStack(spacing: 8) {
                        Button("选择源文件与目标磁盘…") {
                            model.exportToAnotherDisk()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(model.state != .online || model.exportRunning || model.sharedFolderPath == nil)

                        if model.exportRunning {
                            Button("取消") { model.cancelExport() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                        Button("查看迁移记录") { model.requestTransferHistory() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online)
                    }
                }
                if model.exportRunning {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "进度") {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = model.exportMessage {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "状态信息") {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if !model.transferHistory.isEmpty {
                    Divider().padding(.leading, 14)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("最近安全移动日志")
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(model.transferHistory.prefix(12)) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.source)
                                    .font(.system(size: 12, weight: .medium))
                                    .textSelection(.enabled)
                                Text("状态：" + item.statusDescription)
                                    .font(.caption)
                                    .foregroundStyle(item.phase == "source_in_trash" ? .green : .orange)
                                if let trashID = item.trashId {
                                    Text("回收站记录：" + trashID)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                                Text(item.destination)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let reason = item.error, !reason.isEmpty {
                                    Text("错误：" + reason)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 5)
                            if item.id != model.transferHistory.prefix(12).last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            AppleSettingsGroup(title: "宿主 Mac 磁盘体征") {
                if let m = model.metrics {
                    AppleSettingsRow(title: "系统盘总容量", icon: "internaldrive", iconTint: .blue) {
                        Text(formatBytes(m.diskTotal)).font(.system(size: 12, design: .monospaced))
                    }
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "系统盘剩余可用", icon: "chart.pie.fill", iconTint: .teal) {
                        Text(formatBytes(m.diskFree))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                } else {
                    AppleSettingsRow(title: "系统盘信息", icon: "info.circle", iconTint: .indigo) {
                        Text("正在采样…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            AppleSettingsGroup(title: "备份与恢复", footer: "默认只备份账号、权限、相册和应用设置，不包含原始照片、视频或文档。完整文件备份仍可在高级选项中手动使用。") {
                AppleSettingsRow(title: "应用配置", subtitle: "每周备份一次 · 保留最近 5 份 · 需要 Mac 应用保持运行", icon: "externaldrive", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        Button("设置每周配置备份…") { model.configureMetadataWeeklyBackup() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(model.state != .online || model.backupStatus?.running == true)
                        Button("关闭自动备份") { model.disableBackupSchedule() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.backupSchedule?.enabled != true)
                    }
                }
                AppleSettingsRow(title: "立即操作", icon: "clock.arrow.circlepath", iconTint: .orange) {
                    HStack(spacing: 8) {
                        Button("立即备份配置…") { model.startMetadataBackup() }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                            .disabled(model.state != .online || model.backupStatus?.running == true)
                        Button("从备份恢复…") { model.restoreBackup() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.backupStatus?.running == true)
                        Button(model.backupInventoryLoading ? "读取清单…" : "查看备份…") { model.browseBackupInventory() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(model.state != .online || model.backupInventoryLoading)
                    }
                }
                if let report = model.backupStatus {
                    Divider().padding(.leading, 14)
                    if report.running {
                        AppleSettingsRow(title: "备份进行中") {
                            HStack(spacing: 8) {
                                ProgressView("处理 \(report.files) 个文件").controlSize(.small)
                                Button("取消") { model.cancelBackup() }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            }
                        }
                    } else if let path = report.lastSnapshot {
                        AppleSettingsRow(title: "上次结果") {
                            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let lastError = report.lastError, !lastError.isEmpty {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "上次备份任务失败", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                            Text(backupFailureDescription(lastError))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
                if let warning = model.backupStatus?.retentionError, !warning.isEmpty {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "备份已完成，旧快照清理未完成", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backupFailureDescription(warning))
                            if let removed = model.backupStatus?.retentionRemoved, removed > 0 {
                                Text("已清理 \(removed) 个快照；其他目录请检查。")
                            }
                        }.font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                } else if let removed = model.backupStatus?.retentionRemoved, removed > 0 {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "本次计划清理") {
                        Text("已清理 \(removed) 个旧计划快照").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let inventory = model.backupInventory {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "备份清单", icon: "archivebox", iconTint: .blue) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(inventory.destination).font(.caption.monospaced()).textSelection(.enabled)
                            if inventory.snapshots.isEmpty {
                                Text("此目录未找到可识别的备份快照。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(inventory.snapshots) { snapshot in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.name).font(.caption).textSelection(.enabled)
                                    if !snapshot.version.isEmpty {
                                        Text(snapshot.backupType == "metadata" ? "应用配置快照" : "旧整盘快照（不支持恢复）")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text("\(snapshot.createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(snapshot.createdAt)).formatted() : "时间未知") · 清单容量 \(ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(snapshot.integrity == "invalid" ? "清单异常，不能据此确认可恢复" : snapshot.integrity == "not_verified_limit" ? "超出本次检查上限，内容尚未校验" : "清单可读，内容 SHA-256 尚未校验")
                                        .font(.caption2).foregroundStyle(snapshot.integrity == "invalid" ? Color.orange : Color.secondary)
                                }
                            }
                            if inventory.truncated {
                                Text("目录较大，本次仅展示扫描上限内的快照。可在访达中按目录分别查看。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let message = model.backupError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "备份操作提示", icon: "info.circle.fill", iconTint: .blue) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
                if let s = model.backupSchedule {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "自动备份状态", icon: "calendar.badge.clock", iconTint: .indigo) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(!s.enabled ? "未启用" : "仅应用配置 · 每周 · 保留最近 5 份")
                                .font(.caption).foregroundStyle(.secondary)
                            if s.enabled, s.nextRun > 0 {
                                Text("下次运行：\(Date(timeIntervalSince1970: TimeInterval(s.nextRun)).formatted())").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let destination = s.destination, !destination.isEmpty {
                                Text(destination).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                            if let error = s.lastError, !error.isEmpty {
                                Text(backupFailureDescription(error)).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Divider().padding(.leading, 14)
            }

            AppleSettingsGroup(title: "macOS Time Machine 备份保护", footer: "只读读取系统配置，不会修改备份磁盘、排除项目或自动启动备份。显示为包含 ≠ 已成功备份；建议另外使用独立物理备份盘。") {
                AppleSettingsRow(title: "系统备份状态", icon: "clock.arrow.circlepath", iconTint: .teal) {
                    HStack(spacing: 8) {
                        Text(model.timeMachineDiagnostics?.summary ?? "尚未检查")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(model.timeMachineChecking ? "检查中…" : "检查保护状态") {
                            model.refreshTimeMachineDiagnostics()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.timeMachineChecking)
                        Button("打开系统设置…") { model.openTimeMachineSettings() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                if let status = model.timeMachineDiagnostics {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "LightIsle 元数据目录") {
                        Text(status.metadataFolder.rawValue)
                            .font(.caption)
                            .foregroundStyle(status.metadataFolder == .excluded ? .orange : .secondary)
                    }
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "NAS 原始文件目录") {
                        Text(model.sharedFolderPath == nil ? "未选择共享目录" : status.sharedFolder.rawValue)
                            .font(.caption)
                            .foregroundStyle(status.sharedFolder == .excluded ? .orange : .secondary)
                    }
                    if status.destinationKnown && !status.destinationNames.isEmpty {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "已配置目标") {
                            Text(status.destinationNames.joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "最近可查询的系统备份") {
                        Text(status.latestBackupPath ?? "无法核实最近成功备份，请到 Time Machine 系统设置检查")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if let detail = status.detail {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "需要手动核查", icon: "exclamationmark.triangle", iconTint: .orange) {
                            Text(detail).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .onAppear {
                if model.timeMachineDiagnostics == nil { model.refreshTimeMachineDiagnostics() }
            }
            upgradePreflightView
            metadataRollbackView
        }
    }

    // MARK: - Settings View (Apple System Settings Style)
    private var upgradePreflightView: some View {
        AppleSettingsGroup(title: "Beta 升级前安全检查", footer: "只读检查当前账号及媒体 SQLite 数据库，不进行迁移、恢复或安装。检查通过不等于已有独立备份；正式升级前必须先退出旧版并核实备份。") {
            AppleSettingsRow(title: "数据库基础预检", icon: "checkmark.shield", iconTint: .teal) {
                Button(model.upgradePreflightChecking ? "检查中…" : "检查当前数据库") {
                    model.checkUpgradePreflight()
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                .disabled(model.upgradePreflightChecking || model.activatingMetadata)
            }
            if let report = model.upgradePreflight {
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "升级风险评估", icon: report.canProceedWithManualUpgrade ? "checkmark.circle" : "exclamationmark.triangle", iconTint: report.canProceedWithManualUpgrade ? .teal : .orange) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.summary).font(.caption).foregroundStyle(report.canProceedWithManualUpgrade ? Color.secondary : Color.orange)
                        ForEach(report.databases, id: \.name) { database in
                            Text("\(database.name)：\(database.status)").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(report.issues + report.warnings, id: \.self) { message in
                            Text("• " + message).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var metadataRollbackView: some View {
        AppleSettingsGroup(title: "账号与配置回退", footer: "数据库恢复会保留旧版本供回退；共享原片不覆盖，原片与数据库不保证同一时间点。") {
            if let fullPath = model.backupStatus?.restoredMetadata {
                let stageName = URL(fileURLWithPath: fullPath).lastPathComponent
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "待应用的恢复数据库", icon: "externaldrive.badge.timemachine", iconTint: .blue) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("数据库已放入轻屿私有隔离区。先检查账号、授权、私人相册、收藏、手工资料和任务数量。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(model.metadataPreviewLoading ? "正在检查影响…" : "检查恢复影响") {
                            model.previewRestoredMetadata()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online || model.metadataPreviewLoading || model.activatingMetadata || model.backupStatus?.running == true)
                    }
                }
                if let preview = model.metadataPreview,
                   model.metadataPreviewStageName == stageName,
                   preview.isReady {
                    AppleSettingsRow(title: "恢复影响预览", icon: "checkmark.shield", iconTint: .teal) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(metadataPreviewRows) { row in
                                let count = preview.counts[row.key]
                                Text("\(row.label)：当前 \(previewCount(count?.current)) → 恢复后 \(previewCount(count?.staged))，变化 \(previewDelta(count?.delta))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                            ForEach(preview.warnings, id: \.self) { warning in
                                Text(previewWarning(warning))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button("验证身份并应用这些数据库…") { model.activateRestoredMetadata() }
                                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                                .disabled(model.state != .online || model.activatingMetadata || model.backupStatus?.running == true)
                        }
                    }
                }
            }
            AppleSettingsRow(title: "恢复后重新扫描媒体", icon: "arrow.clockwise.circle", iconTint: .teal) {
                Button("重建图库与影视索引") { model.rebuildMediaIndexes() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.state != .online || model.activatingMetadata || model.backupStatus?.running == true)
            }
            if let status = model.reindexRequestMessage {
                AppleSettingsRow(title: "索引任务提示") {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider().padding(.leading, 14)
            AppleSettingsRow(title: "可验证的恢复版本", icon: "arrow.uturn.backward", iconTint: .orange) {
                Button(model.metadataRollbacksLoading ? "正在检查…" : "查看回退版本") { model.refreshMetadataRollbacks() }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    .disabled(model.metadataRollbacksLoading || model.activatingMetadata)
            }
            if let inventory = model.metadataRollbacks {
                if inventory.transactions.isEmpty {
                    AppleSettingsRow(title: "尚无可验证的恢复记录") {
                        Text("完成一次新版数据库激活后才会生成回退凭据。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(inventory.transactions) { transaction in
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: transaction.activatedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(transaction.activatedAt)).formatted() : "旧版恢复记录") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(transaction.fileCount) 个元数据文件 · \(transaction.id)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            if transaction.canRollback {
                                Button("验证身份并回退…") { model.rollbackMetadata(transaction) }
                                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                                    .disabled(model.state == .starting || model.state == .stopping || model.backupStatus?.running == true || model.activatingMetadata)
                            } else {
                                Text(transaction.state == "rolled_back" ? "此版本已回退，前后数据均已保留" : "暂不可回退：\(transaction.reason ?? "无法验证记录")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if inventory.truncated {
                    AppleSettingsRow(title: "本次检查不完整") {
                        Text("恢复记录或校验数据较多，已达到本次安全检查上限。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let error = model.metadataRollbackError {
                AppleSettingsRow(title: "回退记录检查失败", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            if let message = model.metadataActivationMessage {
                AppleSettingsRow(title: "数据库操作结果") {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var metadataPreviewRows: [MetadataPreviewRow] {
        [
            MetadataPreviewRow(key: "accounts.users", label: "账号"),
            MetadataPreviewRow(key: "accounts.fileGrants", label: "旧目录授权"),
            MetadataPreviewRow(key: "accounts.rootFileGrants", label: "共享根授权"),
            MetadataPreviewRow(key: "accounts.rootFileShares", label: "临时目录分享"),
            MetadataPreviewRow(key: "gallery.privateAlbums", label: "私人相册"),
            MetadataPreviewRow(key: "gallery.privateAlbumItems", label: "私人相册项目"),
            MetadataPreviewRow(key: "gallery.favorites", label: "收藏"),
            MetadataPreviewRow(key: "gallery.manualAlbums", label: "手工相册"),
            MetadataPreviewRow(key: "gallery.indexedAssets", label: "图库索引项目"),
            MetadataPreviewRow(key: "cinema.manualTitles", label: "手工影视标题"),
            MetadataPreviewRow(key: "cinema.indexedFilms", label: "影视索引项目"),
            MetadataPreviewRow(key: "tasks.journal", label: "任务摘要"),
            MetadataPreviewRow(key: "tasks.history", label: "任务历史")
        ]
    }

    private func previewCount(_ value: Int64?) -> String {
        value.map { $0.formatted() } ?? "未知"
    }

    private func previewDelta(_ value: Int64?) -> String {
        guard let value else { return "未知" }
        return value > 0 ? "+\(value.formatted())" : value.formatted()
    }

    private func previewWarning(_ code: String) -> String {
        switch code {
        case "previous_database_preserved": return "激活前的数据库会另行保留，可从回退记录恢复。"
        case "files_and_metadata_snapshot_time_may_differ": return "共享原片与数据库备份可能来自不同时间点。"
        case "source_files_not_replaced": return "本次只恢复应用数据库，不覆盖共享原片。"
        case "media_indexes_rebuildable": return "图库与影视索引可重建；恢复后可手动重新扫描。"
        case "sessions_and_file_shares_cleared": return "网页登录会失效，旧文件分享链接会清除。"
        case "some_counts_unknown_for_legacy_schema": return "旧版数据库或缺少表的项目显示为未知。"
        default: return "部分数据库统计未知，请结合恢复后的检查确认。"
        }
    }

    private var settingsView: some View {
        VStack(spacing: 20) {
            Picker("", selection: $preferencesSection) {
                Text("通用").tag(PreferencesSection.general)
                Text("媒体服务").tag(PreferencesSection.media)
                Text("安全与账号").tag(PreferencesSection.security)
                Text("关于").tag(PreferencesSection.about)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 6)

            AppleSettingsGroup(preferenceSection: .general, title: "NAS 常驻与系统登录", footer: "关闭最后一个窗口只收起管理界面，Go Core 继续运行；只有 ⌘Q 或菜单栏退出才停止 NAS。登录项需 macOS 已登录，空闲防睡眠不阻止主动睡眠、断电或 FileVault 解锁。") {
                AppleSettingsRow(title: "登录 Mac 时自动打开轻屿", icon: "person.crop.circle.badge.checkmark", iconTint: .blue) {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "提供服务时防止空闲睡眠", icon: "moon.zzz", iconTint: .orange) {
                    Toggle("", isOn: Binding(
                        get: { model.keepAwakeWhileServing },
                        set: { model.setKeepAwakeWhileServing($0) }
                    ))
                    .toggleStyle(.switch)
                }
                if let error = model.loginItemError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "登录项提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            AppleSettingsGroup(preferenceSection: .general, title: "macOS 故障通知", footer: "默认关闭，开启后需经系统授权。仅发送 NAS 核心异常、备份操作失败、共享目录离线等事件；同类事件会限频，不上传任何文件信息。") {
                AppleSettingsRow(title: "重要事件系统通知", icon: "bell.badge", iconTint: .orange) {
                    Toggle("", isOn: Binding(
                        get: { model.nativeAlertsEnabled },
                        set: { model.setNativeAlertsEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                }
                if let error = model.nativeAlertError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "通知权限提示", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            AppleSettingsGroup(preferenceSection: .media, title: "TMDB 自动刮削", footer: "配置后服务器会自动为影片与剧集补全标题、海报与简介。Token 只保存在本机钥匙串并经私有通道下发给 Core（仅内存），不会写入服务器磁盘或出现在 Web/移动端。可在 themoviedb.org 免费申请 Read Access Token (v4)。") {
                AppleSettingsRow(title: "配置状态", icon: "film.stack", iconTint: .purple) {
                    HStack(spacing: 8) {
                        if model.tmdbTokenBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.tmdbTokenConfigured ? "已配置（Core 已接收）" : (TmdbSecretVault.load() != nil ? "已保存在钥匙串，等待 Core 确认" : "未配置"))
                            .font(.caption)
                            .foregroundStyle(model.tmdbTokenConfigured ? .green : .secondary)
                    }
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "TMDB Read Access Token", subtitle: "输入后点击保存；不会在界面上回显已保存的 Token。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        SecureField("粘贴 Token…", text: $tmdbTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .font(.system(size: 12, design: .monospaced))
                        Button("保存") {
                            model.configureTmdbToken(tmdbTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                            tmdbTokenDraft = ""
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(tmdbTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.tmdbTokenConfigured || TmdbSecretVault.load() != nil {
                            Button("清除") { model.clearTmdbToken() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
                if let error = model.tmdbTokenError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "保存失败", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                if model.state != .online {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "Core 未连接", icon: "wifi.slash", iconTint: .orange) {
                        Text("Token 已保存在本机钥匙串，Core 就绪后会自动下发。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task { model.refreshTmdbStatus() }
            .onChange(of: model.state) { _, newState in
                if newState == .online { model.refreshTmdbStatus() }
            }

            AppleSettingsGroup(preferenceSection: .security, title: "通知渠道（Bark、邮件、企业微信、钉钉）", footer: "磁盘、下载与自动化执行事件可按渠道外发。密钥只存 Mac 钥匙串，经私有 IPC 交给 Core 使用；Web 只显示已配置渠道，不返回凭据。") {
                AppleSettingsRow(title: "通道状态", icon: "bell.badge", iconTint: .red) {
                    HStack(spacing: 8) {
                        if model.notifyBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.notifyConfigured ? "已配置（Core 已接收）" : (NotifySecretVault.load() != nil ? "已保存在钥匙串，等待 Core 确认" : "未配置"))
                            .font(.caption)
                            .foregroundStyle(model.notifyConfigured ? .green : .secondary)
                        if let stats = model.notifyStats, stats.configured {
                            Text(stats.backingOff
                                 ? "通道连续失败，已暂停 5 分钟"
                                 : "队列 \(stats.queued) · 累计丢弃 \(stats.dropped)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "Bark 服务器", subtitle: "留空使用 https://api.day.app；仅填源地址，不带路径。", icon: "iphone", iconTint: .orange) {
                    TextField("https://api.day.app", text: $notifyBarkServerDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .font(.system(size: 12, design: .monospaced))
                }
                AppleSettingsRow(title: "Bark 设备 Key", subtitle: "Bark App 内复制的 Key；不会在界面上回显已保存的值。", icon: "key.fill", iconTint: .indigo) {
                    HStack(spacing: 8) {
                        SecureField("粘贴设备 Key…", text: $notifyBarkKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                AppleSettingsRow(title: "通用 Webhook", subtitle: "自建服务 POST JSON 接口。企业微信和钉钉请使用下方独立的机器人协议。", icon: "arrowshape.turn.up.right", iconTint: .blue) {
                    TextField("https://example.com/hook", text: $notifyWebhookDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .font(.system(size: 12, design: .monospaced))
                }
                AppleSettingsRow(title: "允许内网目标", subtitle: "自建 Bark/Webhook 部署在内网时勾选；默认拒绝内网与本机回环地址。", icon: "network.badge.shield.half.filled", iconTint: .gray) {
                    Toggle("", isOn: $notifyAllowPrivateDraft)
                        .labelsHidden()
                        .controlSize(.small)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "保存与测试", icon: "paperplane", iconTint: .green) {
                    HStack(spacing: 8) {
                        Button("保存通道") {
                            let savedBarkKey = notifyBarkKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let prior = NotifySecretVault.load()
                            let smtpHost = notifySMTPHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            model.configureNotify(NotifyChannelConfig(
                                barkServer: notifyBarkServerDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                barkKey: savedBarkKey.isEmpty && prior != nil ? prior!.barkKey : savedBarkKey,
                                webhookURL: notifyWebhookDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                allowPrivateTargets: notifyAllowPrivateDraft,
                                smtpHost: smtpHost.isEmpty ? nil : smtpHost,
                                smtpPort: smtpHost.isEmpty ? nil : (Int(notifySMTPPortDraft) ?? 465),
                                smtpUsername: smtpHost.isEmpty ? nil : notifySMTPUserDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                smtpPassword: smtpHost.isEmpty ? nil : (notifySMTPPasswordDraft.isEmpty ? prior?.smtpPassword : notifySMTPPasswordDraft),
                                smtpFrom: smtpHost.isEmpty ? nil : notifySMTPFromDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                smtpTo: smtpHost.isEmpty ? nil : notifySMTPToDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                wecomWebhook: notifyWecomDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                dingtalkWebhook: notifyDingtalkDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                dingtalkSecret: notifyDingtalkSecretDraft.isEmpty ? prior?.dingtalkSecret : notifyDingtalkSecretDraft
                            ))
                            notifyBarkKeyDraft = ""
                            notifySMTPPasswordDraft = ""
                            notifyDingtalkSecretDraft = ""
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(notifyBarkKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyWebhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyWecomDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifyDingtalkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && notifySMTPHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && !(model.notifyConfigured || NotifySecretVault.load() != nil))
                        Button("发送测试") { model.testNotify() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                            .disabled(!model.notifyConfigured)
                        if model.notifyConfigured || NotifySecretVault.load() != nil {
                            Button("清除") { model.clearNotify() }
                                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                    }
                }
                if let result = model.notifyTestResult {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "测试结果", icon: "checkmark.seal", iconTint: .green) {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.notifyError {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "配置失败", icon: "exclamationmark.triangle", iconTint: .orange) {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                if model.state != .online {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "Core 未连接", icon: "wifi.slash", iconTint: .orange) {
                        Text("通道配置已保存在本机钥匙串，Core 就绪后会自动下发。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                model.refreshNotifyStatus()
                if let saved = NotifySecretVault.load() {
                    notifyBarkServerDraft = saved.barkServer
                    notifyWebhookDraft = saved.webhookURL
                    notifyAllowPrivateDraft = saved.allowPrivateTargets
                    notifyWecomDraft = saved.wecomWebhook ?? ""
                    notifyDingtalkDraft = saved.dingtalkWebhook ?? ""
                    notifySMTPHostDraft = saved.smtpHost ?? ""
                    notifySMTPPortDraft = String(saved.smtpPort ?? 465)
                    notifySMTPUserDraft = saved.smtpUsername ?? ""
                    notifySMTPFromDraft = saved.smtpFrom ?? ""
                    notifySMTPToDraft = saved.smtpTo ?? ""
                }
            }
            .onChange(of: model.state) { _, newState in
                if newState == .online { model.refreshNotifyStatus() }
            }

            // Group 1: 管理员身份与安全
            AppleSettingsGroup(preferenceSection: .security,
                title: "管理员身份与安全",
                footer: "首任管理员密码仅保存在本地 Mac，重置后旧登录会话立即失效。"
            ) {
                if let username = model.firstAdminUsername {
                    AppleSettingsRow(title: "当前管理员账号", icon: "person.badge.key.fill", iconTint: .blue) {
                        HStack(spacing: 8) {
                            Text(username)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(username, forType: .string)
                                showNotice("已复制管理员用户名")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制用户名")
                        }
                    }
                    Divider().padding(.leading, 14)
                }

                AppleSettingsRow(title: "新密码", icon: "key.horizontal.fill", iconTint: .indigo) {
                    SecureField("至少 12 位", text: $resetAdminPassword)
                        .liquidInput()
                        .frame(width: 220)
                }
                Divider().padding(.leading, 14)

                AppleSettingsRow(title: "确认新密码", icon: "checkmark.shield.fill", iconTint: .teal) {
                    SecureField("再次输入", text: $resetAdminConfirmation)
                        .liquidInput()
                        .frame(width: 220)
                }
                Divider().padding(.leading, 14)

                AppleSettingsRow(title: "重置管理员密码") {
                    HStack(spacing: 10) {
                        if !resetAdminConfirmation.isEmpty && resetAdminPassword != resetAdminConfirmation {
                            Text("两次密码不一致")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Button(model.resettingAdmin ? "验证中…" : "验证 Mac 身份并重置") {
                            let p = resetAdminPassword
                            resetAdminPassword = ""
                            resetAdminConfirmation = ""
                            model.resetAdministratorPassword(newPassword: p)
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(model.state != .online || model.isConfigured != true ||
                            model.resettingAdmin || resetAdminPassword.utf8.count < 12 ||
                            resetAdminPassword != resetAdminConfirmation)
                    }
                }
            }

            // Group 2: 本机服务端口
            AppleSettingsGroup(
                title: "网络与端口",
                footer: "默认 HTTP 端口 16666。更改并保存后，需完全退出并重新打开应用生效。"
            ) {
                AppleSettingsRow(title: "HTTP 访问端口", icon: "network", iconTint: .orange) {
                    HStack(spacing: 8) {
                        TextField("16666", text: $localPortText)
                            .liquidInput()
                            .frame(width: 90)
                            .onSubmit { _ = model.saveLocalPort(localPortText) }
                        Button("保存") {
                            if model.saveLocalPort(localPortText) {
                                showNotice("端口已保存，重启应用后生效")
                            }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                if let target = model.endpoint {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "当前本机访问地址", icon: "link", iconTint: .blue) {
                        HStack(spacing: 8) {
                            Text(target.absoluteString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(target.absoluteString, forType: .string)
                                showNotice("已复制访问地址")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .borderless, size: .small))
                            .help("复制访问地址")
                        }
                    }
                }
            }

            // Group 3: 相册智能缓存
            AppleSettingsGroup(
                title: "相册智能缓存",
                footer: "按 LRU 机制淘汰旧缩略图以加快相册加载，不修改共享目录中的原图。完全退出后生效。"
            ) {
                AppleSettingsRow(
                    title: "缩略图缓存上限",
                    subtitle: "本地高速 JPEG 缓存配额，可随时调整",
                    icon: "photo.stack",
                    iconTint: .pink
                ) {
                    LiquidMenuPicker(
                        title: "缩略图缓存上限",
                        selection: $thumbnailCacheMiB,
                        options: AppModel.thumbnailCacheOptions.map { option in
                            LiquidMenuOption(
                                value: option,
                                label: option >= 1024 ? "\(option / 1024) GiB" : "\(option) MiB"
                            )
                        },
                        minWidth: 112
                    )
                    .onChange(of: thumbnailCacheMiB) { _, value in
                        _ = model.saveThumbnailCacheMiB(value)
                    }
                }
            }

            // Group 4: Touch ID 凭据保护
            AppleSettingsGroup(
                title: "Touch ID 钥匙串保护",
                footer: "将轻屿管理员凭据安全保存在受 Secure Enclave 和 Touch ID 硬件保护的 Mac 钥匙串中。"
            ) {
                AppleSettingsRow(title: "管理员账号", icon: "person.crop.circle", iconTint: .blue) {
                    TextField("用户名", text: $vaultUsername)
                        .liquidInput()
                        .frame(width: 200)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "当前密码", icon: "lock.shield.fill", iconTint: .indigo) {
                    SecureField("密码", text: $vaultPassword)
                        .liquidInput()
                        .frame(width: 200)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "钥匙串操作", icon: "touchid", iconTint: .cyan) {
                    HStack(spacing: 8) {
                        Button(model.verifyingAdmin ? "验证中…" : "保存到钥匙串") {
                            model.saveAdministratorWithTouchID(username: vaultUsername, password: vaultPassword)
                            vaultPassword = ""
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                        .disabled(model.state != .online || model.verifyingAdmin ||
                            vaultUsername.isEmpty || vaultPassword.isEmpty)

                        Button("Touch ID 查看") { model.unlockAdministratorWithTouchID() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))

                        Button("删除凭据") { model.removeSavedAdministrator() }
                            .buttonStyle(LiquidButtonStyle(variant: .destructive, size: .small))
                    }
                }
                if let saved = model.unlockedAdminCredentials {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "已解锁凭据", icon: "key.fill", iconTint: .teal) {
                        Text("\(saved.username) / \(saved.password)")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            // Group 5: 关于
            AppleSettingsGroup(preferenceSection: .about, title: "关于轻屿") {
                AppleSettingsRow(title: "应用版本", icon: "info.circle.fill", iconTint: .blue) {
                    Text("0.1.0-dev (Apple Silicon)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "开场视效体验", icon: "sparkles", iconTint: .purple) {
                    Button("重新播放动画") {
                        showingManualIntro = true
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(title: "Web 数字生活空间", icon: "safari.fill", iconTint: .cyan) {
                    Button("在浏览器打开 ↗") {
                        model.openUserWeb()
                    }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                }
            }
        }
        .environment(\.currentPreferencesSection, preferencesSection)
    }

    // MARK: - Process Monitor
    private var processMonitorView: some View {
        let processes = (model.metrics?.processes ?? []).sorted { first, second in
            let firstValue = processSortByMemory ? first.rssBytes.map(Double.init) : first.cpuPercent
            let secondValue = processSortByMemory ? second.rssBytes.map(Double.init) : second.cpuPercent
            switch (firstValue, secondValue) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return first.pid < second.pid
            }
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("活动进程列表")
                        .font(.system(size: 13, weight: .semibold))
                    Text("只读采样 · 详情受 macOS 系统安全权限控制")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                LiquidSegmentedPicker(
                    title: "进程排序方式",
                    selection: $processSortByMemory,
                    options: [
                        LiquidMenuOption(value: false, label: "按 CPU"),
                        LiquidMenuOption(value: true, label: "按内存")
                    ]
                )
                Button {
                    model.openActivityMonitor()
                } label: {
                    Label("活动监视器", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
            }

            HStack(spacing: 12) {
                Text("进程名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 70, alignment: .trailing)
                Text("物理内存").frame(width: 85, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            if processes.isEmpty {
                Text("暂无进程信息").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(processes.prefix(10))) { process in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(process.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text("PID \(process.pid)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–")
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(size: 11, design: .monospaced))

                        Text(process.rssBytes.map(formatBytes) ?? "–")
                            .frame(width: 85, alignment: .trailing)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
            }
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func formatRate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    /// volume.device is a partition BSD name ("disk4s1"); counters are keyed
    /// by the whole disk ("disk4").
    private func diskActivity(for device: String) -> String? {
        guard let io = model.metrics?.diskIo, !io.isEmpty else { return nil }
        let whole = device.split(separator: "s").first.map(String.init) ?? device
        guard let entry = io.first(where: { $0.device == whole }),
              let read = entry.readBps, let write = entry.writeBps,
              read >= 1 || write >= 1 else { return nil }
        return "读 \(formatRate(read))/s · 写 \(formatRate(write))/s"
    }

    private var thresholdSummary: String {
        guard let threshold = model.storageThreshold else { return "读取中…" }
        let gib = Double(threshold.freeMiB) / 1024.0
        let gibText = gib == gib.rounded() ? String(Int(gib)) : String(format: "%.1f", gib)
        return "剩余低于 \(gibText) GiB 或总容量 \(threshold.percent)%"
    }

    private func syncThresholdDraft() {
        guard let threshold = model.storageThreshold else { return }
        if thresholdFreeMiBText.isEmpty {
            let gib = Double(threshold.freeMiB) / 1024.0
            thresholdFreeMiBText = gib == gib.rounded() ? String(Int(gib)) : String(format: "%.1f", gib)
        }
        if thresholdPercentText.isEmpty {
            thresholdPercentText = String(threshold.percent)
        }
    }

    private func applyThresholdDraft() {
        var freeMiB = model.storageThreshold?.freeMiB ?? 2048
        var percent = model.storageThreshold?.percent ?? 5
        if let value = Double(thresholdFreeMiBText), value >= 0 {
            freeMiB = Int((value * 1024).rounded())
        }
        if let value = Double(thresholdPercentText), value >= 0 {
            percent = Int(value.rounded())
        }
        model.applyStorageThreshold(StorageThreshold(freeMiB: freeMiB, percent: percent))
    }

    private var tunnelBinaryDescription: String {
        if let path = model.tunnelState?.binary, !path.isEmpty {
            return "已找到：\(path)"
        }
        return "未找到 cloudflared。请先安装：brew install cloudflared"
    }

    private var tunnelStatusDescription: String {
        guard let state = model.tunnelState else { return "等待 Core 就绪…" }
        var text = state.statusDescription
        if state.mode == "quick" {
            text += " · 免费模式"
        } else if state.mode == "named" {
            text += " · 命名隧道\(state.tunnelName.map { "「\($0)」" } ?? "")"
        }
        return text
    }

    private var tunnelStatusColor: Color {
        switch model.tunnelState?.status {
        case "online": return .green
        case "starting": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    private func tunnelErrorDescription(_ code: String) -> String {
        switch code {
        case "cloudflared_not_found":
            return "未找到 cloudflared 二进制。请先执行 brew install cloudflared，然后重启轻屿。"
        case "tunnel_already_running":
            return "已有一个隧道在运行；请先停止再切换模式。"
        default:
            return code
        }
    }

    private func frpErrorDescription(_ code: String) -> String {
        switch code {
        case "frpc_not_installed": return "尚未下载客户端，请先获取并选择 FRP 版本。"
        case "frpc_config_incomplete": return "配置文件中仍有服务端占位值，请打开 frpc.toml 完成配置后再启动。"
        case "frp_busy": return "FRP 正在运行或安装中，请先停止，或等当前下载完成。"
        case "frpc_checksum_mismatch": return "下载校验失败，已拒绝安装。请检查网络或代理后重试。"
        case "frpc_version_unavailable": return "该版本不可安装。请刷新列表并选择提供 macOS ARM64 文件及 SHA-256 校验的版本。"
        case "frpc_github_rate_limited": return "GitHub API 请求过于频繁，稍后点击「获取版本」重试。"
        case "frpc_versions_empty": return "官方没有返回可识别的 FRP 版本。"
        case "frpc_unsafe_path": return "FRP 文件路径不是普通文件，为安全起见已拒绝使用。请检查文件位置。"
        case "frpc_exited", "frpc_exited_unexpectedly": return "frpc 进程已退出。请检查 frpc.toml 的服务端地址、令牌、代理规则及远端 frps 状态。"
        default: return code
        }
    }
}

/// Expandable SMART health details for one managed disk, backed by the
/// optional smartctl integration. When the report degrades, the reason is
/// shown honestly instead of a fabricated health answer.
struct DiskHealthDetails: View {
    let report: DiskHealthReport
    let fallbackSMART: String

    private var reasonText: String {
        switch report.reason {
        case "smartctl_not_installed":
            return "未安装 smartmontools，无法读取详细健康信息。可通过 Homebrew 安装（brew install smartmontools）后重试。"
        case "smartctl_permission_required":
            return "macOS 限制普通权限进程直读设备 SMART。可点击下方「使用管理员权限读取」授权一次（结果 5 分钟内对 Web 端同样可见），或按指引配置 sudoers 免密读取。"
        case "smartctl_device_unsupported":
            return "该磁盘的桥接芯片或控制器不支持通过 smartctl 读取 SMART；当前显示 macOS 基础状态。"
        default:
            return "SMART 查询失败，请稍后重试。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.source == "smartctl" {
                HealthDetailRow(title: "型号", value: report.model)
                HealthDetailRow(title: "序列号", value: report.serial)
                HealthDetailRow(title: "固件", value: report.firmware)
                HealthDetailRow(title: "温度", value: report.temperature.map { "\($0) °C" })
                HealthDetailRow(title: "SMART 结论", value: report.passed.map { $0 ? "健康（已通过）" : "警告：SMART 报告异常" },
                        highlight: report.passed == false ? .red : .teal)
                HealthDetailRow(title: "通电时长", value: report.powerOnHours.map { "\($0) 小时" })
                HealthDetailRow(title: "已用寿命", value: report.lifeUsed.map { "\($0)%" })
            } else {
                Label(reasonText, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("macOS 基础 SMART 状态：\(fallbackSMART.isEmpty ? "未知（设备可能不提供）" : fallbackSMART)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

enum PreferencesSection: Hashable {
    case general, media, security, about
}

private struct HealthDetailRow: View {
    let title: String
    let value: String?
    var highlight: Color?

    var body: some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.caption.weight(.semibold))
                .foregroundStyle(highlight ?? Color.primary)
                .textSelection(.enabled)
        }
    }
}

/// Opt-in, fully manual sudoers rule so the Core can read SMART without any
/// password dialog. The rule is intentionally narrow: one binary at a
/// Homebrew path with fixed arguments. Nothing is written automatically.
struct SudoersGuideView: View {
    let device: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var binaryPath: String { SmartElevation.locateBinary() ?? "/opt/homebrew/bin/smartctl" }

    private var rule: String {
        let user = NSUserName()
        return "# 允许免密运行 smartctl 读取磁盘 SMART（只读）\n\(user) ALL=(root) NOPASSWD: \(binaryPath) --json -a /dev/disk[0-9]*"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("sudoers 免密读取 SMART").font(.system(size: 16, weight: .semibold))
            Text("以下步骤完全手动执行，轻屿不会替你修改 sudoers。配置后 SMART 详情不再弹密码框；删除该文件即可撤销。")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 在终端执行：").font(.system(size: 12, weight: .semibold))
                    Text("sudo visudo -f /etc/sudoers.d/lightisle-smart")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text("2. 写入以下内容并保存：").font(.system(size: 12, weight: .semibold))
                    Text(rule)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button(copied ? "已复制" : "复制规则") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(rule, forType: .string)
                            copied = true
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        Text("3. 校验语法：sudo visudo -c").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            Text("说明：规则只放行 smartctl 以固定参数读取 /dev/diskN；当前读取的是整盘（\(device)）。该白名单对终端同样生效，请仅在自己管理的 Mac 上配置。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
}

/// Automatically configures the hosting NSWindow for seamless edge-to-edge
/// vibrant fluid glass material across the toolbar, sidebar, and detail view.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.title = ""
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        if let contentView = window.contentView {
            suppressLegacyScrollers(in: contentView)
        }
    }

    private func suppressLegacyScrollers(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScroller?.alphaValue = 0
            scrollView.horizontalScroller?.alphaValue = 0
        }
        for subview in view.subviews {
            suppressLegacyScrollers(in: subview)
        }
    }
}
