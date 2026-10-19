import SwiftUI
import AppKit

@main
struct LightIsleApp: App {
    @NSApplicationDelegateAdaptor(LightIsleAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("轻屿 LightIsle") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 850, minHeight: 570)
                .onAppear { model.launch() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 730)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class LightIsleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.hasChildProcess else { return .terminateNow }
        Task { @MainActor in
            await AppModel.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

