import SwiftUI
import AppKit

@main
struct LightIsleApp: App {
    @NSApplicationDelegateAdaptor(LightIsleAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("轻屿 LightIsle", id: "main") {
            Group {
                if model.isLightweightMode {
                    // Remove the full view tree (and page-scoped StateObjects)
                    // before closing the manager window. Core stays resident.
                    LightweightWindowCloser()
                } else {
                    ContentView()
                        .frame(minWidth: 850, minHeight: 570)
                        .onAppear { model.launch() }
                        .background(WindowConfigurator())
                        .background(ManagementWindowVisibility())
                }
            }
            .environmentObject(model)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 730)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("偏好与安全") { model.selectedSidebarPage = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(model.isConfigured != true)
            }
            CommandGroup(after: .appSettings) {
                Button("打开 Web 空间") { model.openUserWeb() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.endpoint == nil)
                Button("刷新服务状态") { model.refreshMetrics() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.state != .online)
            }
            CommandMenu("导航") {
                Button("主页") { model.selectedSidebarPage = .overview }
                    .keyboardShortcut(SidebarPage.overview.shortcut, modifiers: .command)
                Button("私人文件") { model.selectedSidebarPage = .files }
                    .keyboardShortcut(SidebarPage.files.shortcut, modifiers: .command)
                Button("时光相册") { model.selectedSidebarPage = .photos }
                    .keyboardShortcut(SidebarPage.photos.shortcut, modifiers: .command)
                Button("私人影院") { model.selectedSidebarPage = .cinema }
                    .keyboardShortcut(SidebarPage.cinema.shortcut, modifiers: .command)
                Button("Docker 与应用") { model.selectedSidebarPage = .containers }
                    .keyboardShortcut(SidebarPage.containers.shortcut, modifiers: .command)
                Button("外部依赖") { model.selectedSidebarPage = .dependencies }
                    .keyboardShortcut(SidebarPage.dependencies.shortcut, modifiers: .command)
                Divider()
                Button("网络与连接") { model.selectedSidebarPage = .services }
                    .keyboardShortcut(SidebarPage.services.shortcut, modifiers: .command)
                Button("数据与存储") { model.selectedSidebarPage = .storage }
                    .keyboardShortcut(SidebarPage.storage.shortcut, modifiers: .command)
                Button("偏好与安全") { model.selectedSidebarPage = .settings }
                    .keyboardShortcut(SidebarPage.settings.shortcut, modifiers: .command)
                .disabled(model.isConfigured != true)
            }
        }
        MenuBarExtra("轻屿 LightIsle", systemImage: model.isLightweightMode ? "leaf.fill" : "externaldrive.fill") {
            LightIsleMenu()
                .environmentObject(model)
        }
    }
}

private struct LightIsleMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("轻屿 NAS · \(model.state.label)")
        Text(model.isLightweightMode ? "轻量模式运行中" : "正常模式")
        Button(model.isLightweightMode ? "恢复正常管理界面" : "打开管理窗口") {
            model.restoreNormalMode()
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if !model.isLightweightMode {
            Button("进入轻量模式") { model.enterLightweightMode() }
        }
        Button("打开 Web 空间") { model.openUserWeb() }
            .disabled(model.state != .online)
        Divider()
        Button("退出轻屿并停止 NAS") { NSApplication.shared.terminate(nil) }
    }
}

/// Track the actual main windows, including close/minimize/hide, instead of
/// treating the lifetime of a SwiftUI view as window visibility.
private struct ManagementWindowVisibility: NSViewRepresentable {
    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ nsView: VisibilityView, context: Context) {}
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) { nsView.detach() }

    final class VisibilityView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var trackedID: ObjectIdentifier?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            trackedID = ObjectIdentifier(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.updateVisibility()
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.report(false)
            })
            DispatchQueue.main.async { [weak self] in self?.updateVisibility() }
        }

        private func updateVisibility() {
            report(window?.isVisible == true && window?.isMiniaturized == false)
        }
        private func report(_ visible: Bool) {
            guard let trackedID else { return }
            AppModel.shared.setManagementWindowVisible(trackedID, visible: visible)
        }
        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            report(false)
            trackedID = nil
        }
        deinit { detach() }
    }
}

/// A view attached only while lightweight mode is active. Removing ContentView
/// releases its caches; closing this exact hosting window avoids affecting
/// status-bar menus and other system windows.
private struct LightweightWindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClosingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ClosingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                if AppModel.shared.isLightweightMode { window?.close() }
            }
        }
    }
}

final class LightIsleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // sessionDidResignActive also covers user switching. Some macOS
        // releases emit the distributed screen-lock event instead.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenLocked(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked(_:)),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil
        )
    }

    @objc private func screenLocked(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.enterLightweightModeOnLock()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppModel.shared.isLightweightMode { AppModel.shared.restoreNormalMode() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // Closing a window only hides the manager. The user must explicitly quit
    // the application to stop the Core, keeping the App = server invariant.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.hasChildProcess else { return .terminateNow }
        Task { @MainActor in
            await AppModel.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

