import SwiftUI
import AppKit

@main
struct LightIsleApp: App {
    @NSApplicationDelegateAdaptor(LightIsleAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("轻屿 LightIsle", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 850, minHeight: 570)
                .onAppear { model.launch() }
                .background(WindowConfigurator())
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
        MenuBarExtra("轻屿 LightIsle", systemImage: "externaldrive.fill") {
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
        Button("打开管理窗口") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("打开 Web 空间") { model.openUserWeb() }
            .disabled(model.state != .online)
        Divider()
        Button("退出轻屿并停止 NAS") { NSApplication.shared.terminate(nil) }
    }
}

final class LightIsleAppDelegate: NSObject, NSApplicationDelegate {
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

