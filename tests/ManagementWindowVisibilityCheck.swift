import AppKit
import Foundation

// The actual view is compiled unchanged against this minimal model. These
// isolated windows never launch Core or use the owner's application data.
@MainActor
final class AppModel {
    static let shared = AppModel()
    var visible = Set<ObjectIdentifier>()
    func setManagementWindowVisible(_ id: ObjectIdentifier, visible: Bool) {
        if visible { self.visible.insert(id) }
        else { self.visible.remove(id) }
    }
}

@main
struct ManagementWindowVisibilityCheck {
    @MainActor
    static func pump() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.015))
    }

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for iteration in 0..<100 {
            weak var releasedView: NSView?
            autoreleasepool {
                let window = NSWindow(
                    contentRect: NSRect(x: -8000, y: -8000, width: 16, height: 16),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                let view = ManagementWindowVisibility.VisibilityView()
                window.contentView = view
                releasedView = view
                window.orderBack(nil)
                pump()
                precondition(AppModel.shared.visible.contains(ObjectIdentifier(window)), "opened window was not sampled")
                if iteration == 0 {
                    app.hide(nil)
                    pump()
                    precondition(app.isHidden && AppModel.shared.visible.isEmpty, "hidden app kept UI sampling alive")
                    app.unhideWithoutActivation()
                    pump()
                    precondition(!app.isHidden && AppModel.shared.visible.count == 1, "unhidden app did not resume sampling")
                }
                window.orderOut(nil)
                pump()
                precondition(AppModel.shared.visible.isEmpty, "hidden window continued sampling")
                window.orderBack(nil)
                pump()
                precondition(AppModel.shared.visible.count == 1, "reopened window did not resume sampling")
                window.close()
                pump()
                precondition(AppModel.shared.visible.isEmpty, "closed window remained visible")
            }
            pump()
            precondition(releasedView == nil, "notification observers retained view at cycle \(iteration)")
        }
        precondition(AppModel.shared.visible.isEmpty)
        autoreleasepool {
            let windows = (0..<2).map { _ in
                NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 16, height: 16), styleMask: [.borderless], backing: .buffered, defer: false)
            }
            for window in windows {
                window.isReleasedWhenClosed = false
                window.contentView = ManagementWindowVisibility.VisibilityView()
                window.orderBack(nil)
            }
            pump()
            precondition(AppModel.shared.visible.count == 2)
            windows[0].close()
            pump()
            precondition(AppModel.shared.visible.count == 1, "closing one window stopped another visible window")
            windows[1].close()
            pump()
            precondition(AppModel.shared.visible.isEmpty)
        }
        print("PASS: 100 isolated AppKit open/hide/reopen/close cycles release visibility observers")
    }
}
