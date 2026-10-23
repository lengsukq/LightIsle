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

                                Text("Apple Silicon · 本地守护")
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
                        let diskFree = m?.diskFree ?? 0
                        let diskTotal = max(m?.diskTotal ?? 1, 1)
                        let diskUsed = diskTotal - diskFree
                        let diskP = Double(diskUsed) / Double(diskTotal)

                        HStack(spacing: 8) {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.teal)
                            Text("存储剩余")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(formatBytes(diskFree))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)

                            // Mini segmented storage bar
                            GeometryReader { p in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5)
                                    Capsule()
                                        .fill(LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(0, min(p.size.width, p.size.width * CGFloat(diskP))), height: 5)
                                }
                            }
                            .frame(width: 80, height: 5)

                            Text("共 \(formatBytes(diskTotal))")
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

            // Section 1: The Three Digital Sanctuaries (3D Tactile Cards)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("数字生活空间")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("全端即时可用 · 零云端中转")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    LiquidSanctuaryTile(
                        title: "私人文件",
                        subtitle: "共享目录 / 全格式即时存取",
                        detail: "\(model.sharedFolderName) · 随时随地跨设备同步",
                        icon: "folder.fill",
                        gradientColors: [Color.cyan, Color.blue],
                        badgeText: "本地共享",
                        action: { model.openUserWeb(page: "files") }
                    )

                    LiquidSanctuaryTile(
                        title: "时光相册",
                        subtitle: "时间线漫游 / 原图智能索引",
                        detail: "\(thumbnailCacheMiB >= 1024 ? "\(thumbnailCacheMiB / 1024) GiB" : "\(thumbnailCacheMiB) MiB") 本地智能缓存",
                        icon: "photo.stack.fill",
                        gradientColors: [Color(red: 0.95, green: 0.35, blue: 0.6), Color.purple],
                        badgeText: "端到端私密",
                        action: { model.openUserWeb(page: "photos") }
                    )

                    LiquidSanctuaryTile(
                        title: "私人影院",
                        subtitle: "4K 原画串流 / 杜比多声道",
                        detail: "家庭影音库 · 芯片硬件直接解码",
                        icon: "film.stack.fill",
                        gradientColors: [Color.orange, Color(red: 0.95, green: 0.3, blue: 0.2)],
                        badgeText: "4K 原画",
                        action: { model.openUserWeb(page: "cinema") }
                    )
                }
            }

            // Section 2: Sanctuary Pulse (Compact Vitality Dashboard)
            let m = model.metrics
            let cpuP = (m?.cpuPercent ?? 0) / 100.0
            let memUsed = m?.memoryUsed ?? 0
            let memTotal = max(m?.memoryTotal ?? 1, 1)
            let memP = Double(memUsed) / Double(memTotal)
            let diskFree = m?.diskFree ?? 0
            let diskTotal = max(m?.diskTotal ?? 1, 1)
            let diskUsed = diskTotal - diskFree
            let diskP = Double(diskUsed) / Double(diskTotal)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("宿主运行健康态 (Sanctuary Pulse)")
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
                        valueText: m?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "运行良好",
                        subtext: "芯片多核协同",
                        progress: cpuP,
                        tint: .blue,
                        icon: "cpu"
                    )

                    LiquidHealthGauge(
                        title: "统一内存健康度",
                        valueText: "\(formatBytes(memUsed))",
                        subtext: "总计 \(formatBytes(memTotal))",
                        progress: memP,
                        tint: .purple,
                        icon: "memorychip"
                    )

                    LiquidHealthGauge(
                        title: "纯净存储余量",
                        valueText: "剩余 \(formatBytes(diskFree))",
                        subtext: "已用 \(formatBytes(diskUsed))",
                        progress: diskP,
                        tint: .teal,
                        icon: "internaldrive"
                    )

                    LiquidHealthGauge(
                        title: "局域网络速率",
                        valueText: "↓ \(m?.networkDownBps.map { "\(formatBytes(UInt64(max(0, $0))))/s" } ?? "0 B/s")",
                        subtext: "↑ \(m?.networkUpBps.map { "\(formatBytes(UInt64(max(0, $0))))/s" } ?? "0 B/s")",
                        progress: 0.35,
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
        spaceDetailCard(
            title: "私人文件",
            subtitle: "Mac 本地高速共享目录已锚定，支持全格式文档、音视频与数据压缩包随时跨端存取与管理。",
            icon: "folder.fill",
            gradient: [.cyan, .blue],
            badgeText: "本地共享",
            infoPairs: [
                ("共享目录名称", model.sharedFolderName),
                ("物理存储路径", model.sharedFolderPath ?? "未设置"),
                ("同步与安全机制", "本地局域网高速传输 · 零第三方云端留存"),
                ("跨端支持", "Mac 访达 · 浏览器 Web · 移动端 PWA")
            ],
            primaryTitle: "在访达中定位文件夹",
            primaryAction: {
                if let path = model.sharedFolderPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            },
            secondaryTitle: "在 Web 空间查看文件 ↗",
            secondaryAction: { model.openUserWeb(page: "files") }
        )
    }

    private var photosSpaceView: some View {
        spaceDetailCard(
            title: "时光相册",
            subtitle: "本地智能解析与缩略图加速，珍藏每一刻珍贵回忆，端到端本地处理，绝不上报视觉内容。",
            icon: "photo.stack.fill",
            gradient: [Color(red: 0.95, green: 0.35, blue: 0.6), .purple],
            badgeText: "端到端私密",
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
            subtitle: "家庭多媒体娱乐中心，支持 4K HDR 原画、杜比多声道音频与外挂字幕无损串流。",
            icon: "film.stack.fill",
            gradient: [.orange, Color(red: 0.95, green: 0.3, blue: 0.2)],
            badgeText: "4K 原画",
            infoPairs: [
                ("媒体串流协议", "HTTP 206 范围断点续传 · 零卡顿"),
                ("多语言字幕", "SRT / VTT 原生字幕自动匹配与外挂"),
                ("观影断点记忆", "多终端自动同步播放进度"),
                ("芯片硬件加速", "Apple Silicon 媒体处理引擎硬件直接解码")
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

            AppleSettingsGroup(title: "局域网访问", footer: "开启后可通过同一家庭局域网下的手机、平板或电脑浏览器访问，由自签名安全证书全程加密。") {
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

            AppleSettingsGroup(title: "Bonjour 局域网发现", footer: "仅当 LightIsle 的局域网 HTTPS 在线时广播 _lightisle._tcp；广播不等于证书受信任，客户端仍要核对 HTTPS 证书指纹。") {
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
            AppleSettingsGroup(title: "数据存储目录", footer: "Mac 本地授权的数据目录，用于安全保存所有文档、相册照片与流媒体影片。") {
                AppleSettingsRow(title: "当前共享根目录", icon: "folder.fill", iconTint: .blue) {
                    HStack(spacing: 10) {
                        Text(model.sharedFolderName)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        if let path = model.sharedFolderPath {
                            Button("在访达中打开") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        }
                        Button("更改目录…") {
                            model.selectSharedFolder()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online || model.rootManagement.enabled)
                        Button("重新连接") {
                            model.retrySharedFolder()
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .disabled(model.state != .online)
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

            if let volumes = model.metrics?.volumes, !volumes.isEmpty {
                AppleSettingsGroup(title: "挂载存储卷与健康诊断", footer: "容量与状态来自 macOS；SMART 读取失败时显示未知，不会虚假标记为健康。") {
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
                            if let health = model.volumeHealth[volume.mount] {
                                HStack(spacing: 6) {
                                    Image(systemName: health.warning ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                                        .foregroundStyle(health.warning ? .red : .teal)
                                    Text("SMART: \(health.status)")
                                        .foregroundStyle(health.warning ? .red : .secondary)
                                    Spacer()
                                    if let p = health.protocolName {
                                        Text(p)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        if volume.id != volumes.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }

            AppleSettingsGroup(title: "时光快照与备份恢复", footer: "创建轻屿专属数据目录的安全快照；恢复至独立目录，绝不静默覆盖现有数据。") {
                AppleSettingsRow(title: "即时任务", icon: "clock.arrow.circlepath", iconTint: .orange) {
                    HStack(spacing: 8) {
                        Button("立即备份…") { model.startBackup() }
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
                                        Text(snapshot.version == "lightisle-complete-backup-v2" ? "文件与应用元数据快照" : snapshot.version == "lightisle-file-backup-v1" ? "旧版文件快照，不包含应用元数据" : snapshot.version)
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
                Divider().padding(.leading, 14)
                AppleSettingsRow(
                    title: "计划快照保留",
                    subtitle: "选择每天或每周并确认目录后生效；只清理成功新备份之前、归属可验证的旧计划快照。",
                    icon: "archivebox",
                    iconTint: .indigo
                ) {
                    LiquidMenuPicker(
                        title: "下次设置备份计划时使用的保留数量",
                        selection: Binding(
                            get: { backupRetentionDraft ?? model.backupSchedule?.retentionCount ?? 0 },
                            set: { backupRetentionDraft = $0 }
                        ),
                        options: [LiquidMenuOption(value: 0, label: "保留所有（不自动清理）")] +
                            (1...30).map { LiquidMenuOption(value: $0, label: "最近 \($0) 个") },
                        minWidth: 168
                    )
                }
                Divider().padding(.leading, 14)
                AppleSettingsRow(
                    title: "定时自动备份（App 运行时）",
                    subtitle: "应用运行期间按设定周期自动执行快照备份",
                    icon: "calendar.badge.clock",
                    iconTint: .indigo
                ) {
                    let isDaily = model.backupSchedule?.enabled == true && model.backupSchedule?.everyHours == 24
                    let isWeekly = model.backupSchedule?.enabled == true && model.backupSchedule?.everyHours == 168
                    let isOff = model.backupSchedule?.enabled != true
                    HStack(spacing: 6) {
                        Button("每天") { model.configureBackupSchedule(hours: 24, retentionCount: backupRetentionDraft ?? model.backupSchedule?.retentionCount ?? 0) }
                            .buttonStyle(LiquidButtonStyle(variant: isDaily ? .prominent : .secondary, size: .small))
                        Button("每周") { model.configureBackupSchedule(hours: 168, retentionCount: backupRetentionDraft ?? model.backupSchedule?.retentionCount ?? 0) }
                            .buttonStyle(LiquidButtonStyle(variant: isWeekly ? .prominent : .secondary, size: .small))
                        Button("关闭") { model.disableBackupSchedule() }
                            .buttonStyle(LiquidButtonStyle(variant: isOff ? .prominent : .secondary, size: .small))
                            .disabled(isOff)
                    }
                    .disabled(model.state != .online)
                }
                if let s = model.backupSchedule, s.enabled {
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "下次运行") {
                        Text(s.destinationIdentityStatus == "confirmation_required" || s.nextRun <= 0 ? "需重新选择备份目录以确认磁盘身份" : "每 \(s.everyHours) 小时 · \(Date(timeIntervalSince1970: TimeInterval(s.nextRun)).formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().padding(.leading, 14)
                    AppleSettingsRow(title: "当前计划保留策略") {
                        Text((s.retentionCount ?? 0) == 0 ? "保留所有，不自动清理" : "最近 \(s.retentionCount ?? 0) 个计划快照")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let volumeID = s.destinationVolumeUUID, !volumeID.isEmpty {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "已绑定备份卷") {
                            Text(volumeID).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let destination = s.destination, !destination.isEmpty {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "备份目录") {
                            Text(destination)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    if s.lastAttempt > 0 {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "上次尝试") {
                            Text(Date(timeIntervalSince1970: TimeInterval(s.lastAttempt)).formatted())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let lastError = s.lastError, !lastError.isEmpty {
                        Divider().padding(.leading, 14)
                        AppleSettingsRow(title: "上次定时备份失败", icon: "exclamationmark.triangle.fill", iconTint: .orange) {
                            Text(backupFailureDescription(lastError))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
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
            metadataRollbackView
        }
    }

    // MARK: - Settings View (Apple System Settings Style)
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
            AppleSettingsGroup(title: "NAS 常驻与系统登录", footer: "关闭最后一个窗口只收起管理界面，Go Core 继续运行；只有 ⌘Q 或菜单栏退出才停止 NAS。登录项需 macOS 已登录，空闲防睡眠不阻止主动睡眠、断电或 FileVault 解锁。") {
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

            AppleSettingsGroup(title: "macOS 故障通知", footer: "默认关闭，开启后需经系统授权。仅发送 NAS 核心异常、备份操作失败、共享目录离线等事件；同类事件会限频，不上传任何文件信息。") {
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

            // Group 1: 管理员身份与安全
            AppleSettingsGroup(
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
            AppleSettingsGroup(title: "关于轻屿") {
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
