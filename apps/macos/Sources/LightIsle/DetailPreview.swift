import SwiftUI
import AppKit

@MainActor
final class DetailPreviewCoordinator: ObservableObject {
    @Published private(set) var state = DetailPreviewState()
    private var pending: Task<Void, Never>?
    func enter(_ id: UUID) {
        pending?.cancel()
        let ticket = state.invalidateDelay()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.state.show(id, ticket: ticket)
        }
    }
    func leave(_ id: UUID) {
        guard state.owner == nil || state.owner == id else { return }
        pending?.cancel()
        let ticket = state.invalidateDelay()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.state.dismiss(ticket: ticket)
        }
    }
    func remain() { pending?.cancel(); _ = state.invalidateDelay() }
    func pin(_ id: UUID) { pending?.cancel(); state.pin(id) }
    func dismiss() { pending?.cancel(); pending = nil; state.dismiss() }
    deinit { pending?.cancel() }
}

struct IsleDetailInfo: View {
    let title: String
    let rows: [(String, String)]
    @State private var id = UUID()
    @EnvironmentObject private var previews: DetailPreviewCoordinator
    var body: some View {
        Button { previews.pin(id) } label: {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看" + title + "详情")
        .accessibilityHint("打开可阅读和复制的详细信息")
        .onHover { if $0 { previews.enter(id) } else { previews.leave(id) } }
        .popover(isPresented: Binding(get: { previews.state.owner == id }, set: { if !$0 && previews.state.owner == id { previews.dismiss() } }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if !previews.state.pinned {
                        Button { previews.pin(id) } label: { Image(systemName: "pin") }.help("固定详情，移开鼠标后继续阅读")
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.0).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText)
                        Text(row.1.isEmpty ? "暂无数据" : row.1).font(.system(size: 13)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(18).frame(width: 300, alignment: .leading)
                .onHover { if $0 { previews.remain() } else { previews.leave(id) } }
                .onExitCommand { previews.dismiss() }
        }
        .onDisappear { if previews.state.owner == id { previews.dismiss() } }
    }
}

struct IsleDestinationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    var value: String? = nil
    let action: () -> Void
    @Environment(\.isleAccent) private var accent
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(accent)
                        .frame(width: 36, height: 36).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)).foregroundStyle(accent.opacity(0.8))
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                if let value { Text(value).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText).lineLimit(1) }
            }.padding(20).frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                .modifier(IsleItemCardSurface(interactive: true)).contentShape(Rectangle())
        }.buttonStyle(IslePressStyle())
            .help("打开" + title)
    }
}

struct IsleBackButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: "chevron.left") }
            .buttonStyle(LiquidButtonStyle(variant: .borderless))
            .keyboardShortcut("[", modifiers: .command)
            .help("返回" + title)
    }
}

@MainActor
final class ManagementScrollStore: ObservableObject { var offsets: [String: CGPoint] = [:] }

/// Observes this scroll view only. The observer follows view lifetime and never
/// hides system scroll bars or retains a page after lightweight mode unloads it.
struct ManagementScrollMemory: NSViewRepresentable {
    let route: String
    let store: ManagementScrollStore
    let onScroll: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.configure(route: route, store: store, onScroll: onScroll)
    }
    final class ObserverView: NSView {
        private var token: NSObjectProtocol?
        private weak var clip: NSClipView?
        private var route = ""
        private var store: ManagementScrollStore?
        private var onScroll: (() -> Void)?
        private var lastOrigin = CGPoint.zero
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func configure(route: String, store: ManagementScrollStore, onScroll: @escaping () -> Void) {
            let changed = self.route != route
            self.route = route; self.store = store; self.onScroll = onScroll
            attach()
            if changed { restore() }
        }
        private func attach() {
            guard let next = enclosingScrollView?.contentView, next !== clip else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            clip = next
            next.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: next, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let clip = self.clip else { return }
                    guard self.lastOrigin != clip.bounds.origin else { return }
                    self.lastOrigin = clip.bounds.origin
                    self.store?.offsets[self.route] = clip.bounds.origin
                    self.onScroll?()
                }
            }
            restore()
        }
        private func restore() {
            let point = store?.offsets[route] ?? .zero
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = self.clip else { return }
                clip.scroll(to: point); self.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
