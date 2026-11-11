import SwiftUI
import AppKit
import Darwin

/// Current resident memory (not peak RSS) of this SwiftUI host process.
/// Kept separate from the Go Core's RSS so the numbers aren't misrepresented
/// as whole-system RAM or added to unrelated processes.
enum LightIsleHostMemory {
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size /
                                           MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}

struct MetadataPreviewRow: Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var appsCenter = AppModel.shared.appsCenter
    @StateObject var dependencyStore = ExternalDependencyStore()
    @Environment(\.isleReduceMotion) var reduceMotion
    @AppStorage("hasSeenIntro") var hasSeenIntro = false
    @State var showingManualIntro = false
    @State var confirmPlainHTTP = false
    @State var firstUsername = ""
    @State var firstPassword = ""
    @State var confirmPassword = ""
    @State var copiedNotice: String?
    @State var backupRetentionDraft: Int?
    @State var showingRollbackRecovery = false
    @State var localPortText = ""
    @State var thumbnailCacheMiB = AppModel.shared.preferredThumbnailCacheMiB
    @State var vaultUsername = ""
    @State var vaultPassword = ""
    @State var resetAdminPassword = ""
    @State var resetAdminConfirmation = ""
    @State var processSortByMemory = false
    @State var showAdvancedDiagnostics = false
    @AppStorage("lightisle.sidebarExpanded") var sidebarExpanded = false
    @AppStorage("lightisle.sidebarWidth") var sidebarWidth: Double = 224
    @Namespace var sidebarSelection
    @StateObject var childEdits = ManagementEdits()
    @State var draftTimeout: Task<Void, Never>?
    @State var revealUnlockedPassword = false
    @State var selectedDiskID: String?
    @StateObject var previews = DetailPreviewCoordinator()
    @StateObject var scrollStore = ManagementScrollStore()
    @State var storageDetail: StorageDetail?
    @State var connectionDetail: ConnectionDetail?
    @State var editingFRPConfig = false
    @State var frpEditorHasChanges = false
    @State var showingUnsavedFRP = false
    @State var settingsDetail: PreferencesSection?
    @State var settingsTool: SettingsTool?
    @State var dockerDetail: DockerDetail = .containers
    @AppStorage("lightisle.dockerContext") var dockerContext = "desktop-linux"
    @State var selectedPluginAppID: String?
    @State var selectedDockerContainer: DockerContainer?
    @State var pendingNavigation: (() -> Void)?
    @State var showingUnsavedChanges = false
    @State var saveBeforeLeaving = false
    @State var draftError: String?
    @State var pendingDraftSaves: Set<NativeDraft> = []
    @State var notificationDraftLoaded = false
    @State var notificationBaseline: [String] = []
    @State var confirmedRoute: SidebarPage = .overview
    @State var suppressRouteGuard = false
    @State var expandedDiskHealth: Set<String> = []
    @State var thresholdFreeMiBText = ""
    @State var thresholdPercentText = ""
    @State var presentingTunnelManager = false
    @State var tmdbTokenDraft = ""
    @State var tiandituKeyDraft = ""
    @State var notifyBarkServerDraft = ""
    @State var notifyBarkKeyDraft = ""
    @State var notifyWebhookDraft = ""
    @State var notifyAllowPrivateDraft = false
    @State var notifyWecomDraft = ""
    @State var notifyDingtalkDraft = ""
    @State var notifyDingtalkSecretDraft = ""
    @State var notifySMTPHostDraft = ""
    @State var notifySMTPPortDraft = "465"
    @State var notifySMTPUserDraft = ""
    @State var notifySMTPPasswordDraft = ""
    @State var notifySMTPFromDraft = ""
    @State var notifySMTPToDraft = ""
    @State var trashRetentionDaysText = "30"
    @State var trashRetentionEnabled = false
    @State var preferencesSection: PreferencesSection = .general
    @State var manualTunnelToken = ""
    @State var presentingSudoersGuide = false
    @State var sudoersGuideDevice = "disk0"
    @State var showingStatusPopover = false
    let settingsControlWidth: CGFloat = 320

    var body: some View {
        Group {
            if showingManualIntro {
                IntroAnimationView { showingManualIntro = false }
            } else if model.isConfigured == false {
                if !hasSeenIntro { IntroAnimationView { hasSeenIntro = true } }
                else { nativeSetupView }
            } else if model.isConfigured == nil { connectingView }
            else { managementShell }
        }
        .tint(IsleTheme.accent)
        .modifier(IsleTitleFreeToolbar())
        .environmentObject(previews)
        .environmentObject(childEdits)
        .animation(reduceMotion ? nil : IsleMotion.reveal, value: model.isConfigured)
        .animation(reduceMotion ? nil : IsleMotion.reveal, value: showingManualIntro)
        .onAppear {
            model.navigationRequest = { requestNavigation($0) }
            model.storageDetailNavigationRequest = { detail in
                requestLocalNavigation {
                    model.selectedSidebarPage = .storage
                    confirmedRoute = .storage
                    storageDetail = detail
                }
            }
        }
        .onChange(of: model.selectedSidebarPage) { previous, next in
            previews.dismiss()
            guard !suppressRouteGuard else { suppressRouteGuard = false; confirmedRoute = next; return }
            if editingFRPConfig && frpEditorHasChanges {
                suppressRouteGuard = true
                model.selectedSidebarPage = previous
                pendingNavigation = {
                    editingFRPConfig = false
                    frpEditorHasChanges = false
                    model.selectedSidebarPage = next
                    confirmedRoute = next
                }
                showingUnsavedFRP = true
            } else if hasUnsavedDrafts {
                suppressRouteGuard = true
                model.selectedSidebarPage = previous
                pendingNavigation = { model.selectedSidebarPage = next; confirmedRoute = next }
                showingUnsavedChanges = true
            } else { confirmedRoute = next }
        }
        .onChange(of: model.isConfigured) { _, configured in
            if configured == true { firstPassword = ""; confirmPassword = "" }
        }
        .onChange(of: model.unlockedAdminCredentials?.username) { _, _ in revealUnlockedPassword = false }
        .onChange(of: draftSaveSignal) { _, _ in completeDraftSaveIfReady() }
        .onChange(of: model.diskManagementError) { _, error in
            if storageDetail == .capacity, let error {
                draftError = error; pendingDraftSaves.remove(.threshold); saveBeforeLeaving = false; draftTimeout?.cancel()
            }
        }
        .confirmationDialog("有尚未保存的修改", isPresented: $showingUnsavedChanges, titleVisibility: .visible) {
            Button("保存并离开") { saveDraftsAndLeave() }
            Button("放弃修改", role: .destructive) { discardDrafts(); finishNavigation() }
            Button("继续编辑", role: .cancel) { pendingNavigation = nil }
        } message: { Text("可以先保存修改，也可以留在当前页面继续编辑。") }
        .confirmationDialog("FRP 有尚未保存的配置", isPresented: $showingUnsavedFRP, titleVisibility: .visible) {
            Button("放弃 FRP 修改并离开", role: .destructive) {
                frpEditorHasChanges = false
                editingFRPConfig = false
                finishNavigation()
            }
            Button("继续编辑", role: .cancel) { pendingNavigation = nil }
        } message: { Text("返回后当前的服务端、Token 和代理草稿不会保留。请先在 FRP 配置页保存。") }
        .sheet(isPresented: $showingRollbackRecovery) {
            VStack(spacing: 16) {
                ScrollView { metadataRollbackView.padding(24) }
                Button("关闭") { showingRollbackRecovery = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.activatingMetadata)
                    .padding(.bottom, 16)
            }.frame(minWidth: 600, idealWidth: 660, maxWidth: 720, minHeight: 400, idealHeight: 480, maxHeight: 550)
                .interactiveDismissDisabled(model.activatingMetadata)
        }
        .onDisappear { model.navigationRequest = nil; model.storageDetailNavigationRequest = nil; previews.dismiss(); childEdits.reset(); noticeTask?.cancel(); draftTimeout?.cancel(); model.setDiagnosticsVisible(false) }
    }

    var managementShell: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                sidebarView.frame(width: sidebarExpanded ? CGFloat(sidebarWidth) : 76)
                if sidebarExpanded {
                    IsleDockResizeHandle(
                        width: Binding(
                            get: { CGFloat(sidebarWidth) },
                            set: { sidebarWidth = Double($0) }
                        )
                    )
                }
            }.padding(.leading, 20).padding(.trailing, 4).padding(.top, 72)
            detailView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IsleBackdrop().environment(\.isleAccent, model.selectedSidebarPage.section.tint))
        .focusedSceneValue(\.isleSidebarExpanded, $sidebarExpanded)
        .animation(reduceMotion ? nil : IsleMotion.navigation, value: sidebarExpanded)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { sidebarExpanded.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(sidebarExpanded ? "收起导航标签（⌃⌘S）" : "展开导航标签（⌃⌘S）")
                    .accessibilityLabel(sidebarExpanded ? "收起导航标签" : "展开导航标签")
            }
            if model.isPresentationPreview {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                        Text("设计预览 · 模拟数据")
                    }
                    .font(.system(size: 11)).foregroundStyle(IsleTheme.secondaryText)
                    .fixedSize().accessibilityElement(children: .combine)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.refreshMetrics() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.state != .online)
                    .help(model.state == .online ? "重新读取本机状态" : "核心服务就绪后可刷新")
            }
        }
        .onAppear {
            if let initial = ProcessInfo.processInfo.environment["LIGHTISLE_INITIAL_PAGE"] ?? (model.isPresentationPreview ? Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignPage") as? String : nil),
               let matched = SidebarPage.allCases.first(where: { $0.rawValue == initial || String(describing: $0) == initial || (initial == "主页" && $0 == .overview) }) {
                model.selectedSidebarPage = matched
            }
            if model.isPresentationPreview {
                storageDetail = (Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignStorage") as? String).flatMap(StorageDetail.init(rawValue:))
                connectionDetail = (Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignConnection") as? String).flatMap(ConnectionDetail.init(rawValue:))
                settingsDetail = (Bundle.main.object(forInfoDictionaryKey: "LightIsleDesignSettings") as? String).flatMap(PreferencesSection.init(rawValue:))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice = copiedNotice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.system(size: 13)).padding(14).modifier(IsleFloatingChrome()).padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    var sidebarView: some View {
        VStack(spacing: 8) {
            ForEach(ManagementSection.allCases) { section in sidebarRow(section) }
        }
        .padding(10)
        .modifier(IsleGlassBarSurface(cornerRadius: 24))
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : IsleMotion.navigation, value: model.selectedSidebarPage.section)
        .accessibilityElement(children: .contain).accessibilityLabel("主导航")
    }
    func sidebarRow(_ section: ManagementSection) -> some View {
        let selected = model.selectedSidebarPage.section == section
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            requestLocalNavigation {
                resetSubroute(for: section)
                model.selectedSidebarPage = .primary(section)
                confirmedRoute = .primary(section)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 18, weight: selected ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24)
                    .foregroundStyle(selected ? IsleTheme.onAccent : section.tint)
                if sidebarExpanded {
                    Text(section.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? IsleTheme.onAccent : Color.primary)
                        .lineLimit(1)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, sidebarExpanded ? 12 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                if selected {
                    shape.fill(
                        LinearGradient(
                            colors: [section.tint.opacity(0.92), section.tint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    }
                    .matchedGeometryEffect(id: "sidebar-selection", in: sidebarSelection)
                    .shadow(color: section.tint.opacity(0.28), radius: 10, y: 4)
                }
            }
            .contentShape(shape)
        }.buttonStyle(IsleDockButtonStyle())
            .accessibilityLabel(section.rawValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help("打开" + section.rawValue)
    }
    func resetSubroute(for section: ManagementSection) {
        switch section {
        case .storage: storageDetail = nil; selectedDiskID = nil
        case .services: connectionDetail = nil; editingFRPConfig = false; presentingTunnelManager = false
        case .containers: selectedPluginAppID = nil; selectedDockerContainer = nil
        case .settings: settingsDetail = nil; settingsTool = nil
        default: break
        }
    }
    var routeKey: String {
        "\(model.selectedSidebarPage)-\(storageDetail?.rawValue ?? "")-\(connectionDetail?.rawValue ?? "")-\(editingFRPConfig)-\(presentingTunnelManager)-\(settingsDetail?.rawValue ?? "")-\(String(describing: settingsTool))"
    }
    var scrollRouteKey: String {
        if model.selectedSidebarPage == .containers {
            return "\(routeKey)-\(appsCenter.workspaceSection.rawValue)-\(dockerDetail.rawValue)-\(selectedPluginAppID ?? "")-\(selectedDockerContainer?.id ?? "")"
        }
        return routeKey
    }
    private var activeHeaderInfo: (parentTitle: String?, backAction: (() -> Void)?, title: String, subtitle: String, icon: String) {
        switch model.selectedSidebarPage {
        case .services:
            if connectionDetail == .frp && editingFRPConfig {
                return ("FRP 穿透", { requestLocalNavigation { editingFRPConfig = false; frpEditorHasChanges = false } },
                        "可视化配置", "编辑本机 frpc.toml · 只在点击保存后修改文件", "doc.text.fill")
            } else if connectionDetail == .cloudflare && presentingTunnelManager {
                return ("Cloudflare Tunnel", { requestLocalNavigation { presentingTunnelManager = false } },
                        "API 隧道与域名管理", "通过 Cloudflare API 创建隧道、绑定公共主机名并配置路由", "cloud.fill")
            } else if let detail = connectionDetail {
                return ("网络与连接", { requestLocalNavigation { connectionDetail = nil; editingFRPConfig = false; presentingTunnelManager = false } },
                        detail.rawValue, detail.subtitle, detail.icon)
            }
        case .containers:
            if appsCenter.workspaceSection == .plugins, let appID = selectedPluginAppID {
                let app = appsCenter.apps.first(where: { $0.id == appID })
                let ver = app.map { " · v\($0.version)" } ?? ""
                return ("轻应用与插件", { requestLocalNavigation { selectedPluginAppID = nil } },
                        app?.name ?? appID, "ID: \(appID)\(ver) · 运行日志、成员权限与生命周期配置", "puzzlepiece.extension.fill")
            } else if appsCenter.workspaceSection == .docker, detailIsContainerSubpage, let container = selectedDockerContainer {
                return ("Docker 容器", { requestLocalNavigation { selectedDockerContainer = nil } },
                        container.name, "\(container.image) · 容器日志与实时资源采样", "shippingbox.fill")
            }
        case .storage:
            if let detail = storageDetail {
                return ("存储", { requestLocalNavigation { storageDetail = nil; selectedDiskID = nil } },
                        detail.rawValue, detail.subtitle, detail.icon)
            }
        case .settings:
            if settingsDetail == .tools && settingsTool == .diagnostics {
                return ("工具", { settingsTool = nil },
                        "高级诊断", "应用常驻内存、采样曲线与本机活动进程", "waveform.path.ecg")
            } else if let detail = settingsDetail {
                return ("设置", { requestLocalNavigation { settingsDetail = nil; settingsTool = nil } },
                        detail.title, detail.subtitle, detail.icon)
            }
        case .dependencies:
            return ("设置 · 工具", { requestNavigation(.settings); settingsDetail = .tools },
                    SidebarPage.dependencies.rawValue, SidebarPage.dependencies.subtitle, SidebarPage.dependencies.icon)
        case .files, .photos, .cinema:
            return ("个人空间", { requestNavigation(.spaces) },
                    model.selectedSidebarPage.rawValue, model.selectedSidebarPage.subtitle, model.selectedSidebarPage.icon)
        default:
            break
        }
        return (nil, nil, model.selectedSidebarPage.rawValue, model.selectedSidebarPage.subtitle, model.selectedSidebarPage.section.icon)
    }
    var detailView: some View {
        let info = activeHeaderInfo
        let tint = model.selectedSidebarPage.section.tint
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                if let backAction = info.backAction, let parentTitle = info.parentTitle {
                    IsleBackButton(title: parentTitle, action: backAction)
                    IsleHeaderIconBadge(icon: info.icon, tint: tint, size: 36)
                } else if model.selectedSidebarPage == .overview {
                    BrandMark(size: 38)
                } else {
                    IsleHeaderIconBadge(icon: info.icon, tint: tint, size: 38)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    Text(info.subtitle).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                headerStatusButton
                Button {
                    model.openUserWeb()
                } label: {
                    Label("打开 Web 端", systemImage: "safari")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .large))
                .disabled(model.state != .online || model.endpoint == nil)
                .help(model.state == .online
                      ? "在默认浏览器打开本机 Web 空间（⌘⇧O）"
                      : "核心服务就绪后即可打开 Web 空间")
                .accessibilityLabel("在浏览器中打开 LightIsle Web 端")
            }
            .frame(maxWidth: 1044, alignment: .leading).padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let draftError { Text(draftError).font(.system(size: 13)).foregroundStyle(IsleTheme.warningText).textSelection(.enabled) }
                    if saveBeforeLeaving { ProgressView("正在保存修改…").controlSize(.small) }
                    if let error = model.webOpenError { Text(error).font(.system(size: 13)).foregroundStyle(IsleTheme.warningText) }
                    pageContent
                        .environment(\.isleAccent, tint)
                        .tint(tint)
                        .id(routeKey)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: 10).combined(with: .opacity), removal: .opacity))
                }
                .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 28)
                .frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                .background(ManagementScrollMemory(route: scrollRouteKey, store: scrollStore, onScroll: previews.dismiss))
            }.clipped()
        }
        .animation(reduceMotion ? nil : IsleMotion.navigation, value: routeKey)
        .onChange(of: routeKey) { _, _ in previews.dismiss(); model.setDiagnosticsVisible(settingsDetail == .tools && settingsTool == .diagnostics && model.selectedSidebarPage == .settings) }
    }
    var headerStatusButton: some View {
        let online = model.state == .online
        let portSuffix = model.endpoint?.port.map { " · :\($0)" } ?? ""
        return Button {
            showingStatusPopover.toggle()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(online ? IsleTheme.successText : IsleTheme.warningText)
                    .frame(width: 7, height: 7)
                Text(model.state.label + (online ? portSuffix : ""))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IsleTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .modifier(IsleGlassBarSurface(cornerRadius: 17))
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(IslePressStyle())
        .help("查看服务状态与快捷访问地址（关闭管理窗口后，轻屿仍会继续提供服务）")
        .popover(isPresented: $showingStatusPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusBadge(isOnline: online, text: model.state.label)
                    Spacer()
                    if online {
                        Button("刷新状态") { model.refreshMetrics() }
                            .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    } else {
                        Button("重新启动") { model.launch(); showingStatusPopover = false }
                            .buttonStyle(LiquidButtonStyle(variant: .prominent, size: .small))
                    }
                }
                if let endpoint = model.endpoint?.absoluteString {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本机访问").font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                            Text(endpoint).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(endpoint, forType: .string)
                            showNotice("已复制本机访问地址")
                            showingStatusPopover = false
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .help("复制本机地址")
                    }
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("局域网其他设备").font(.caption2).foregroundStyle(IsleTheme.secondaryText)
                        Text(model.remoteAddress ?? "未启用局域网访问")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(model.remoteAddress == nil ? IsleTheme.secondaryText : .primary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if let lan = model.remoteAddress {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(lan, forType: .string)
                            showNotice("已复制局域网地址")
                            showingStatusPopover = false
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                        .help("复制局域网地址")
                    } else {
                        Button("去开启") {
                            showingStatusPopover = false
                            requestLocalNavigation { model.selectedSidebarPage = .services; connectionDetail = .lan }
                        }
                        .buttonStyle(LiquidButtonStyle(variant: .secondary, size: .small))
                    }
                }
                Text("关闭管理窗口后，轻屿后台服务仍会继续运行。")
                    .font(.caption2).foregroundStyle(IsleTheme.secondaryText)
            }
            .padding(16)
            .frame(width: 310, alignment: .leading)
        }
    }
    @ViewBuilder var pageContent: some View {
        switch model.selectedSidebarPage {
        case .overview: overviewView
        case .storage: storageView
        case .services: servicesView
        case .spaces: personalSpacesView
        case .files: filesSpaceView
        case .photos: photosSpaceView
        case .cinema: cinemaSpaceView
        case .settings: settingsView
        case .dependencies:
            ExternalDependenciesView(store: dependencyStore) { requestNavigation($0) }.disabled(model.isPresentationPreview)
        case .containers:
            DockerManagementView(
                detail: $dockerDetail,
                context: $dockerContext,
                selectedPluginAppID: $selectedPluginAppID,
                selectedContainer: $selectedDockerContainer
            )
        }
    }
    private var detailIsContainerSubpage: Bool { dockerDetail == .containers }
    func requestNavigation(_ page: SidebarPage) {
        requestLocalNavigation { model.selectedSidebarPage = page; confirmedRoute = page }
    }
    func requestLocalNavigation(_ action: @escaping () -> Void) {
        if editingFRPConfig && frpEditorHasChanges {
            pendingNavigation = action
            showingUnsavedFRP = true
        } else if hasUnsavedDrafts { pendingNavigation = action; showingUnsavedChanges = true }
        else { previews.dismiss(); action() }
    }
    func finishNavigation() {
        let action = pendingNavigation; pendingNavigation = nil
        suppressRouteGuard = true
        action?()
        // Local navigation does not publish a new sidebar selection.
        DispatchQueue.main.async { suppressRouteGuard = false }
    }
    @State var noticeTask: Task<Void, Never>?
    func showNotice(_ message: String) {
        noticeTask?.cancel()
        withAnimation(reduceMotion ? nil : IsleMotion.fluid) { copiedNotice = message }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : IsleMotion.fluid) { copiedNotice = nil }
        }
    }
}
