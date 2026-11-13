import SwiftUI
import AppKit

@main
struct LightIsleApp: App {
    @NSApplicationDelegateAdaptor(LightIsleAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @FocusedValue(\.isleSidebarExpanded) private var sidebarExpanded

    var body: some Scene {
        WindowGroup("轻屿 LightIsle", id: "main") {
            Group {
                if model.isLightweightMode {
                    // Remove the full view tree (and page-scoped StateObjects)
                    // before closing the manager window. Core stays resident.
                    LightweightWindowCloser()
                } else {
                    ContentView()
                        .modifier(NativePresentationPreview())
                        .frame(minWidth: 850, minHeight: 518, alignment: .topLeading)
                        .onAppear { model.launchInitiallyIfNeeded() }
                        .background(WindowConfigurator())
                        .background(ManagementWindowVisibility())
                }
            }
            .environmentObject(model)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: NativeWindowSize.width, height: NativeWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("设置") { model.navigate(to: .settings) }
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
                Button(sidebarExpanded?.wrappedValue == true ? "收起导航标签" : "展开导航标签") {
                    sidebarExpanded?.wrappedValue.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(sidebarExpanded == nil || model.isConfigured != true)
                Divider()
                Group {
                    Button("概览") { model.navigate(to: .overview) }
                        .keyboardShortcut(SidebarPage.overview.shortcut, modifiers: .command)
                    Button("数据与存储") { model.navigate(to: .storage) }
                        .keyboardShortcut(SidebarPage.storage.shortcut, modifiers: .command)
                    Button("网络与连接") { model.navigate(to: .services) }
                        .keyboardShortcut(SidebarPage.services.shortcut, modifiers: .command)
                    Button("Docker 与应用") { model.navigate(to: .containers) }
                        .keyboardShortcut(SidebarPage.containers.shortcut, modifiers: .command)
                    Button("个人空间") { model.navigate(to: .spaces) }
                        .keyboardShortcut(SidebarPage.spaces.shortcut, modifiers: .command)
                    Button("设置") { model.navigate(to: .settings) }
                        .keyboardShortcut(SidebarPage.settings.shortcut, modifiers: .command)
                    Divider()
                    Menu("空间与工具快捷直达") {
                        Button("私人文件") { model.navigate(to: .files) }
                            .keyboardShortcut(SidebarPage.files.shortcut, modifiers: .command)
                        Button("时光相册") { model.navigate(to: .photos) }
                            .keyboardShortcut(SidebarPage.photos.shortcut, modifiers: .command)
                        Button("私人影院") { model.navigate(to: .cinema) }
                            .keyboardShortcut(SidebarPage.cinema.shortcut, modifiers: .command)
                        Divider()
                        Button("外部依赖") { model.navigate(to: .dependencies) }
                            .keyboardShortcut(SidebarPage.dependencies.shortcut, modifiers: .command)
                    }
                }
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
    @State private var copiedAddress = false

    var body: some View {
        Text("轻屿 NAS · \(model.state.label)")
        Text(model.isLightweightMode ? "轻量模式运行中" : "正常模式")
        if case .error(let reason) = model.state {
            Text(reason)
            Text(model.details)
            Button("重新启动轻屿服务") { model.launch() }
                .disabled(model.corePortRecoveryBusy)
        }
        if !model.coreServiceWarnings.isEmpty {
            Text("有 \(model.coreServiceWarnings.count) 项服务需要检查")
        }
        Divider()
        Button(model.corePortConflict != nil ? "处理端口冲突…" : model.isLightweightMode ? "恢复正常管理界面" : "打开管理窗口") {
            model.restoreNormalMode()
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("打开 Web 空间") { model.openUserWeb() }
            .disabled(model.state != .online)
        if let shareURL = model.remoteAddress ?? model.endpoint?.absoluteString, model.state == .online {
            Button(copiedAddress ? "✓ 已复制访问地址" : (model.remoteAddress != nil ? "复制局域网访问地址" : "复制本机访问地址")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareURL, forType: .string)
                copiedAddress = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1800))
                    copiedAddress = false
                }
            }
        }
        if !model.isLightweightMode {
            Button("进入轻量模式") { model.enterLightweightMode() }
        }
        Divider()
        Button("退出轻屿并停止 NAS") { NSApplication.shared.terminate(nil) }
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

