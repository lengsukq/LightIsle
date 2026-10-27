import AppKit
import SwiftUI

/// Track the actual main windows, including close/minimize/hide, instead of
/// treating the lifetime of a SwiftUI view as window visibility.
struct ManagementWindowVisibility: NSViewRepresentable {
    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ nsView: VisibilityView, context: Context) {}
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) { nsView.detach() }

    final class VisibilityView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var trackedID: ObjectIdentifier?
        private var visibilityObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            trackedID = ObjectIdentifier(window)
            visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                self?.updateVisibility()
            }
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
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: NSApplication.shared, queue: .main) { [weak self] _ in
                    self?.updateVisibility()
                })
            }
            DispatchQueue.main.async { [weak self] in self?.updateVisibility() }
        }

        private func updateVisibility() {
            report(!NSApplication.shared.isHidden && window?.isVisible == true && window?.isMiniaturized == false)
        }
        private func report(_ visible: Bool) {
            guard let trackedID else { return }
            AppModel.shared.setManagementWindowVisible(trackedID, visible: visible)
        }
        func detach() {
            visibilityObservation?.invalidate()
            visibilityObservation = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            report(false)
            trackedID = nil
        }
        deinit { detach() }
    }
}
