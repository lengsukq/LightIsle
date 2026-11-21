import AppKit
import os
import SwiftUI

/// Track the actual main windows, including close/minimize/hide, instead of
/// treating the lifetime of a SwiftUI view as window visibility.
struct ManagementWindowVisibility: NSViewRepresentable {
    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ nsView: VisibilityView, context: Context) {}
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) { nsView.detach() }

    final class VisibilityView: NSView {
        private let trackedWindowID = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
        private var visibilityObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            let windowID = ObjectIdentifier(window)
            trackedWindowID.withLock { $0 = windowID }
            visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateVisibility()
                }
            }
            let center = NotificationCenter.default
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                center.addObserver(self, selector: #selector(handleVisibilityNotification(_:)), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(handleWindowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                center.addObserver(self, selector: #selector(handleVisibilityNotification(_:)), name: name, object: NSApplication.shared)
            }
            DispatchQueue.main.async { [weak self] in self?.updateVisibility() }
        }

        @objc private func handleVisibilityNotification(_ notification: Notification) {
            updateVisibility()
        }

        @objc private func handleWindowWillClose(_ notification: Notification) {
            report(false)
        }

        private func updateVisibility() {
            report(!NSApplication.shared.isHidden && window?.isVisible == true && window?.isMiniaturized == false)
        }

        private func report(_ visible: Bool) {
            guard let id = trackedWindowID.withLock({ $0 }) else { return }
            AppModel.shared.setManagementWindowVisible(id, visible: visible)
        }

        func detach() {
            visibilityObservation?.invalidate()
            visibilityObservation = nil
            NotificationCenter.default.removeObserver(self)
            report(false)
            trackedWindowID.withLock { $0 = nil }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            if let id = trackedWindowID.withLock({ state -> ObjectIdentifier? in
                defer { state = nil }
                return state
            }) {
                Task { @MainActor in
                    AppModel.shared.setManagementWindowVisible(id, visible: false)
                }
            }
        }
    }
}
