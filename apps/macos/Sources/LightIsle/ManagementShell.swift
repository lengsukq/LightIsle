import SwiftUI
import AppKit

private struct IsleSidebarExpansionKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
extension FocusedValues {
    var isleSidebarExpanded: Binding<Bool>? {
        get { self[IsleSidebarExpansionKey.self] }
        set { self[IsleSidebarExpansionKey.self] = newValue }
    }
}

/// On newer systems the title is a toolbar item, separate from NSWindow's
/// titleVisibility. macOS 14 continues to use the AppKit window configuration.
struct IsleTitleFreeToolbar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) }
        else { content }
    }
}

struct IsleDockResizeHandle: View {
    @Binding var width: CGFloat
    @State private var initialWidth: CGFloat?
    var body: some View {
        Color.clear.frame(width: 8, height: 324).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if initialWidth == nil { initialWidth = width }
                    width = min(280, max(200, (initialWidth ?? width) + value.translation.width))
                }.onEnded { _ in initialWidth = nil })
            .onHover { if $0 { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
            .onDisappear { NSCursor.arrow.set() }
            .accessibilityLabel("导航宽度").accessibilityValue("\(Int(width)) 点")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(280, width + 16)
                case .decrement: width = max(200, width - 16)
                @unknown default: break
                }
            }
            .help("拖动调整导航宽度")
    }
}

struct IsleDockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DockButtonSurface(label: configuration.label, pressed: configuration.isPressed)
    }
    private struct DockButtonSurface<Label: View>: View {
        let label: Label
        let pressed: Bool
        @Environment(\.isleReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var focused
        @State private var hovered = false
        var body: some View {
            label
                .background(hovered ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: 14).strokeBorder(IsleTheme.accent, lineWidth: 2) }
                }
                .scaleEffect(reduceMotion ? 1 : pressed ? 0.93 : hovered ? 1.035 : 1)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
                .animation(reduceMotion ? nil : IsleMotion.fluid, value: pressed)
                .onHover { hovered = $0 }
        }
    }
}

struct IsleDestinationGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], alignment: .leading, spacing: 16) { content }
    }
}

struct IsleCascade: ViewModifier {
    var index: Int
    @Environment(\.isleReduceMotion) private var reduceMotion
    @State private var appeared = false
    func body(content: Content) -> some View {
        content.opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 9)
            .animation(reduceMotion ? nil : IsleMotion.fluid.delay(Double(min(index, 6)) * 0.035), value: appeared)
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
    }
}
