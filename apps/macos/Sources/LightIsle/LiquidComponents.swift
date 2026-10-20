import SwiftUI

// Shared macOS visual primitives. Content stays readable and opaque; translucent
// materials are reserved for navigation and temporary controls.
enum IsleTheme {
    // Matches design-tokens/tokens.json accentPrimary in light and dark modes.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 56.0 / 255, green: 152.0 / 255, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0, green: 113.0 / 255, blue: 227.0 / 255, alpha: 1)
    })
    static let onAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    })
    static let violet = Color(red: 0.49, green: 0.36, blue: 0.88)
    static let radius: CGFloat = 20
    static let contentPadding: CGFloat = 28
}

/// CPU, memory and traffic history: SwiftUI Path is light enough to redraw
/// only when a new metric sample arrives (no timers, Canvas or constant blur).
struct IsleHistoryGraph: View {
    let title: String
    let values: [Double]
    let maximum: Double
    let tint: Color

    var body: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("最近 \(values.count) 次采样").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    ZStack {
                        VStack {
                            Spacer()
                            Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 1)
                        }
                        Path { path in
                            let points = Array(values.suffix(120))
                            for (index, value) in points.enumerated() {
                                let x = CGFloat(index) * geometry.size.width / CGFloat(max(points.count - 1, 1))
                                let capped = min(max(0, value), max(1, maximum))
                                let y = geometry.size.height * (1 - CGFloat(capped / max(1, maximum)))
                                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: 76)
                .accessibilityLabel(title)
                .accessibilityValue(values.last.map { String(format: "%.1f", $0) } ?? "暂无数据")
            }
        }
    }
}

/// The default action for management pages. Uses a solid, legible surface
/// rather than introducing another floating layer of glass.
struct IsleActionButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ActionSurface(
            label: configuration.label,
            pressed: configuration.isPressed,
            prominent: prominent,
            destructive: destructive,
            enabled: isEnabled,
            reduceMotion: reduceMotion
        )
    }

    private struct ActionSurface<Content: View>: View {
        let label: Content
        let pressed: Bool
        let prominent: Bool
        let destructive: Bool
        let enabled: Bool
        let reduceMotion: Bool
        @State private var hovered = false

        var body: some View {
            label
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .foregroundStyle(prominent ? IsleTheme.onAccent : destructive ? Color.red : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(prominent ? IsleTheme.accent : Color.primary.opacity(hovered ? 0.09 : 0.052))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(prominent ? Color.white.opacity(0.17) : Color.primary.opacity(0.09), lineWidth: 1)
                }
                .scaleEffect(enabled && !reduceMotion ? (pressed ? 0.965 : hovered ? 1.01 : 1) : 1)
                .offset(y: enabled && !reduceMotion ? (pressed ? 1 : hovered ? -1 : 0) : 0)
                .shadow(color: .black.opacity(prominent && enabled ? 0.11 : 0), radius: 9, y: 4)
                .opacity(enabled ? 1 : 0.48)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: pressed)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

enum IsleMotion {
    static let navigation = Animation.spring(response: 0.48, dampingFraction: 0.88)
    static let quick = Animation.spring(response: 0.26, dampingFraction: 0.78)
    static let reveal = Animation.spring(response: 0.55, dampingFraction: 0.9)
}

struct IsleBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [IsleTheme.accent.opacity(0.11), .clear],
                    center: .topTrailing, startRadius: 24,
                    endRadius: max(380, geometry.size.width * 0.83)
                )
                RadialGradient(
                    colors: [IsleTheme.violet.opacity(0.075), .clear],
                    center: .bottomLeading, startRadius: 20,
                    endRadius: max(360, geometry.size.width * 0.65)
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct IsleSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Adds the same tactile response to all custom clickable surfaces, without
/// interfering with their semantic labels, keyboard focus, or disabled states.
struct IslePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        PressedSurface(
            label: configuration.label,
            pressed: configuration.isPressed,
            enabled: isEnabled,
            reduceMotion: reduceMotion
        )
    }

    private struct PressedSurface<Content: View>: View {
        let label: Content
        let pressed: Bool
        let enabled: Bool
        let reduceMotion: Bool
        @State private var hovered = false

        var body: some View {
            label
                .scaleEffect(enabled && !reduceMotion ? (pressed ? 0.975 : hovered ? 1.012 : 1) : 1)
                .offset(y: enabled && !reduceMotion ? (pressed ? 1 : hovered ? -1 : 0) : 0)
                .brightness(enabled ? (pressed ? -0.035 : hovered ? 0.018 : 0) : 0)
                .opacity(enabled ? 1 : 0.55)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: pressed)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

struct IsleTextFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.11), lineWidth: 1)
            }
    }
}

struct LiquidCard<Content: View>: View {
    var cornerRadius: CGFloat = IsleTheme.radius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.primary.opacity(0.045)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.045), radius: 22, x: 0, y: 9)
    }
}

struct LiquidGroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background {
                RoundedRectangle(cornerRadius: IsleTheme.radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
            }
            .overlay {
                RoundedRectangle(cornerRadius: IsleTheme.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: IsleTheme.radius, style: .continuous))
            .shadow(color: .black.opacity(0.035), radius: 16, x: 0, y: 6)
    }
}

struct StatusBadge: View {
    let isOnline: Bool
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isOnline ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: (isOnline ? Color.green : Color.orange).opacity(0.4), radius: 4)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill((isOnline ? Color.green : Color.orange).opacity(0.105)))
        .overlay(Capsule().strokeBorder((isOnline ? Color.green : Color.orange).opacity(0.20), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct BentoStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color
    var progress: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(tint.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let p = progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(LinearGradient(colors: [tint.opacity(0.68), tint], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(p))))
                                .animation(reduceMotion ? nil : IsleMotion.reveal, value: p)
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 4)
                    .accessibilityLabel("\(title)使用比例")
                    .accessibilityValue("\(Int(max(0, min(1, p)) * 100))%")
                }
            }
        }
    }
}
