import SwiftUI

// Native finish generated from the same palette used by the Vue Web client.
// Real-time blur belongs to navigation; content uses softly embossed solid cards.
enum IsleTheme {
    static let accent = IsleFluidPalette.accentPrimary
    static let onAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    })
    static let violet = Color(red: 0.49, green: 0.36, blue: 0.88)
    static let radius: CGFloat = IsleFluidPalette.cardRadius
    static let heroRadius: CGFloat = IsleFluidPalette.heroRadius
    static let itemRadius: CGFloat = IsleFluidPalette.itemRadius
    static let smRadius: CGFloat = IsleFluidPalette.smRadius
    static let contentPadding: CGFloat = 28
}

/// Quiet spatial separation inside an embossed group, instead of hard rules.
struct IsleGroupSpacing: View {
    var height: CGFloat = 8
    var body: some View { Color.clear.frame(height: height) }
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
                            Rectangle().fill(Color.primary.opacity(0.04)).frame(height: 1)
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
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: 76)
                .accessibilityLabel(title)
                .accessibilityValue(values.last.map { String(format: "%.1f", $0) } ?? "暂无数据")
            }
        }
    }
}

enum LiquidButtonVariant {
    case prominent
    case secondary
    case destructive
    case borderless
}

enum LiquidButtonSize {
    case small
    case regular
    case large
}

/// Unified Apple-grade Liquid Glass Button Style.
/// Eliminates raw system grey buttons with radiant gradients, tactile frosted glass,
/// specular rim highlights, and soft layered shadows.
struct LiquidButtonStyle: ButtonStyle {
    var variant: LiquidButtonVariant = .secondary
    var size: LiquidButtonSize = .regular

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        LiquidButtonBody(
            configuration: configuration,
            variant: variant,
            size: size,
            isEnabled: isEnabled,
            reduceMotion: reduceMotion
        )
    }

    private struct LiquidButtonBody: View {
        let configuration: Configuration
        let variant: LiquidButtonVariant
        let size: LiquidButtonSize
        let isEnabled: Bool
        let reduceMotion: Bool
        @State private var hovered = false

        var hPadding: CGFloat {
            switch size {
            case .small: return 10
            case .regular: return 14
            case .large: return 18
            }
        }

        var vPadding: CGFloat {
            switch size {
            case .small: return 5
            case .regular: return 7.5
            case .large: return 10.5
            }
        }

        var fontSize: CGFloat {
            switch size {
            case .small: return 11.5
            case .regular: return 12.5
            case .large: return 14
            }
        }

        var cornerRadius: CGFloat {
            switch size {
            case .small: return 8
            case .regular: return 10
            case .large: return 12
            }
        }

        var body: some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            configuration.label
                .font(.system(size: fontSize, weight: variant == .prominent ? .semibold : .medium, design: .rounded))
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .foregroundStyle(textColor)
                .background {
                    backgroundView(shape)
                }
                .clipShape(shape)
                .contentShape(shape)
                .overlay {
                    strokeView(shape)
                }
                .scaleEffect(isEnabled && !reduceMotion ? (pressed ? 0.965 : hovered ? 1.015 : 1) : 1)
                .offset(y: isEnabled && !reduceMotion ? (pressed ? 1 : hovered ? -1 : 0) : 0)
                .shadow(color: shadowColor, radius: hovered ? 10 : 4, y: hovered ? 4 : 2)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: pressed)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
                .onHover { isHovered in
                    if isEnabled { hovered = isHovered }
                }
        }

        var textColor: Color {
            switch variant {
            case .prominent:
                return .white
            case .secondary:
                return .primary
            case .destructive:
                return .red
            case .borderless:
                return .blue
            }
        }

        @ViewBuilder
        func backgroundView(_ shape: RoundedRectangle) -> some View {
            switch variant {
            case .prominent:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.58, blue: 0.98),
                            Color(red: 0.08, green: 0.42, blue: 0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            case .secondary:
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(hovered ? 0.32 : 0.18),
                                Color.white.opacity(hovered ? 0.14 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            case .destructive:
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.red.opacity(hovered ? 0.18 : 0.10),
                            Color.red.opacity(hovered ? 0.26 : 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            case .borderless:
                shape.fill(hovered ? Color.blue.opacity(0.08) : Color.clear)
            }
        }

        @ViewBuilder
        func strokeView(_ shape: RoundedRectangle) -> some View {
            switch variant {
            case .prominent:
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.48), Color.white.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            case .secondary:
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(hovered ? 0.85 : 0.55),
                            Color.white.opacity(hovered ? 0.35 : 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            case .destructive:
                shape.strokeBorder(Color.red.opacity(hovered ? 0.45 : 0.25), lineWidth: 1)
            case .borderless:
                EmptyView()
            }
        }

        var shadowColor: Color {
            guard isEnabled else { return .clear }
            switch variant {
            case .prominent:
                return Color.blue.opacity(hovered ? 0.32 : 0.18)
            case .secondary:
                return Color.black.opacity(hovered ? 0.06 : 0.02)
            case .destructive:
                return Color.red.opacity(hovered ? 0.16 : 0.05)
            case .borderless:
                return .clear
            }
        }
    }
}

/// Liquid Glass Input Field Surface for TextField and SecureField.
/// Replaces dated AppKit .roundedBorder with a modern frosted glass slot.
struct LiquidInputModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(hovered ? 0.055 : 0.035))
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                IsleFluidPalette.rim.opacity(hovered ? 0.85 : 0.65),
                                IsleFluidPalette.rim.opacity(hovered ? 0.38 : 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: IsleFluidPalette.shadow.opacity(0.03), radius: 4, y: 1.5)
            .onHover { isHovered in
                hovered = isHovered
            }
    }
}

extension View {
    func liquidInput(cornerRadius: CGFloat = 8) -> some View {
        self.modifier(LiquidInputModifier(cornerRadius: cornerRadius))
    }
}

struct LiquidMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var icon: String? = nil
    var id: Value { value }

    init(value: Value, label: String, icon: String? = nil) {
        self.value = value
        self.label = label
        self.icon = icon
    }
}

/// Apple-grade Liquid Glass Menu Picker.
/// Replaces stretched or dated AppKit NSPopUpButton with a compact frosted glass pill,
/// specular rim border, and dual-chevron indicator badge.
struct LiquidMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [LiquidMenuOption<Value>]
    var minWidth: CGFloat = 148

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Text(selectedLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 11)
        .padding(.trailing, 32)
        .padding(.vertical, 5.5)
        .frame(minWidth: minWidth, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(hovered ? 0.56 : 0.40),
                            Color.white.opacity(hovered ? 0.32 : 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
        }
        .overlay(alignment: .trailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(IsleTheme.accent.opacity(hovered ? 0.22 : 0.14))
                    .frame(width: 18, height: 18)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(IsleTheme.accent)
            }
            .padding(.trailing, 7)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(hovered ? 0.92 : 0.72),
                            Color.primary.opacity(hovered ? 0.14 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.black.opacity(hovered ? 0.06 : 0.03), radius: hovered ? 8 : 3, y: hovered ? 3 : 1)
        .opacity(isEnabled ? 1 : 0.48)
        .onHover { isHovered in
            if isEnabled { hovered = isHovered }
        }
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
    }
}

/// Apple-grade Liquid Glass Segmented Pill Selector.
/// Renders a frosted glass track with a raised, radiant active pill.
struct LiquidSegmentedPicker<Value: Hashable>: View {
    enum Style {
        case regular
        case tabs
    }

    let title: String
    @Binding var selection: Value
    let options: [LiquidMenuOption<Value>]
    var style: Style = .regular

    @Namespace private var pillAnimation
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pillRadius: CGFloat {
        style == .tabs ? 9 : 7
    }

    private var trackRadius: CGFloat {
        style == .tabs ? 13 : 10
    }

    private var horizontalPadding: CGFloat {
        style == .tabs ? 14 : 11
    }

    private var verticalPadding: CGFloat {
        style == .tabs ? 7 : 5
    }

    private var fontSize: CGFloat {
        style == .tabs ? 12.5 : 11.5
    }

    private var iconSize: CGFloat {
        style == .tabs ? 12.5 : 11
    }

    private var trackPadding: CGFloat {
        style == .tabs ? 4 : 3
    }

    var body: some View {
        HStack(spacing: style == .tabs ? 4 : 3) {
            ForEach(options) { option in
                LiquidSegmentedButton(
                    option: option,
                    isSelected: option.value == selection,
                    pillRadius: pillRadius,
                    horizontalPadding: horizontalPadding,
                    verticalPadding: verticalPadding,
                    fontSize: fontSize,
                    iconSize: iconSize,
                    animationNamespace: pillAnimation,
                    reduceMotion: reduceMotion
                ) {
                    if reduceMotion {
                        selection = option.value
                    } else {
                        withAnimation(IsleMotion.quick) {
                            selection = option.value
                        }
                    }
                }
            }
        }
        .padding(trackPadding)
        .background {
            RoundedRectangle(cornerRadius: trackRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: trackRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: trackRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            IsleFluidPalette.rim.opacity(style == .tabs ? 0.70 : 0.65),
                            IsleFluidPalette.rim.opacity(style == .tabs ? 0.25 : 0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: IsleFluidPalette.shadow.opacity(style == .tabs ? 0.06 : 0.04), radius: style == .tabs ? 10 : 8, y: 2)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct LiquidSegmentedButton<Value: Hashable>: View {
    let option: LiquidMenuOption<Value>
    let isSelected: Bool
    let pillRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let fontSize: CGFloat
    let iconSize: CGFloat
    let animationNamespace: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5.5) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: isSelected ? .semibold : .medium))
                }
                Text(option.label)
                    .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.white : (hovered ? Color.primary.opacity(0.85) : Color.secondary))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.12, green: 0.58, blue: 0.98),
                                    Color(red: 0.08, green: 0.42, blue: 0.92)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                        )
                        .shadow(color: Color.blue.opacity(0.24), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "liquidPill", in: animationNamespace)
                } else if hovered {
                    RoundedRectangle(cornerRadius: pillRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            if !reduceMotion {
                withAnimation(IsleMotion.quick) { hovered = isHovered }
            } else {
                hovered = isHovered
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
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(prominent ? IsleTheme.onAccent : destructive ? Color.red : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: IsleTheme.smRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: prominent
                                    ? [IsleTheme.accent, IsleTheme.accent.opacity(0.88)]
                                    : destructive
                                        ? [Color.red.opacity(hovered ? 0.18 : 0.10), Color.red.opacity(hovered ? 0.24 : 0.14)]
                                        : [IsleFluidPalette.cardTop, hovered ? IsleFluidPalette.cardHover : IsleFluidPalette.cardBottom],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: IsleTheme.smRadius, style: .continuous)
                        .strokeBorder(
                            prominent
                                ? Color.white.opacity(0.3)
                                : destructive
                                    ? Color.red.opacity(0.35)
                                    : IsleFluidPalette.rim.opacity(hovered ? 0.85 : 0.65),
                            lineWidth: 1
                        )
                }
                .scaleEffect(enabled && !reduceMotion ? (pressed ? 0.965 : hovered ? 1.015 : 1) : 1)
                .offset(y: enabled && !reduceMotion ? (pressed ? 1 : hovered ? -1.5 : 0) : 0)
                .shadow(
                    color: IsleFluidPalette.shadow.opacity(enabled ? (prominent ? 0.22 : hovered ? 0.14 : 0.07) : 0),
                    radius: hovered ? 14 : 7,
                    y: hovered ? 6 : 3
                )
                .opacity(enabled ? 1 : 0.48)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: pressed)
                .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

enum IsleMotion {
    static let navigation = Animation.spring(response: 0.44, dampingFraction: 0.86)
    static let quick = Animation.spring(response: 0.28, dampingFraction: 0.78)
    static let reveal = Animation.spring(response: 0.52, dampingFraction: 0.88)
    static let fluid = Animation.spring(response: 0.36, dampingFraction: 0.75)
}

/// Living, breathing atmospheric ambient mesh backdrop.
/// Renders fluid celestial hues (Azure Ocean, Sky Cyan, Aurora Violet)
/// with subtle hardware-accelerated breathing, or static calm tones when reduceMotion is active.
struct IsleFluidBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            // Base ambient canvas tint
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 9/255, green: 13/255, blue: 24/255, alpha: 1)
                    : NSColor(srgbRed: 243/255, green: 247/255, blue: 253/255, alpha: 1)
            })

            // Dynamic fluid orbs
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height

                // Top-left azure dawn glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.12, green: 0.58, blue: 0.95).opacity(breathe ? 0.22 : 0.14),
                                Color(red: 0.22, green: 0.74, blue: 0.97).opacity(breathe ? 0.12 : 0.05),
                                .clear
                            ],
                            center: .center,
                            startRadius: 40,
                            endRadius: max(w, h) * 0.48
                        )
                    )
                    .frame(width: max(w, h) * 0.95, height: max(w, h) * 0.95)
                    .offset(x: -w * 0.15 + (breathe ? 15 : -15), y: -h * 0.22 + (breathe ? -10 : 10))
                    .blur(radius: 65)

                // Top-right celestial purple / aurora glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.52, green: 0.38, blue: 0.95).opacity(breathe ? 0.18 : 0.11),
                                Color(red: 0.75, green: 0.45, blue: 0.98).opacity(breathe ? 0.09 : 0.04),
                                .clear
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: max(w, h) * 0.42
                        )
                    )
                    .frame(width: max(w, h) * 0.85, height: max(w, h) * 0.85)
                    .offset(x: w * 0.38 + (breathe ? -20 : 15), y: -h * 0.12 + (breathe ? 12 : -12))
                    .blur(radius: 75)

                // Bottom-center serene ocean reflection
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.08, green: 0.65, blue: 0.92).opacity(breathe ? 0.15 : 0.08),
                                Color.blue.opacity(breathe ? 0.08 : 0.03),
                                .clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: w * 0.55
                        )
                    )
                    .frame(width: w * 1.15, height: h * 0.5)
                    .offset(x: -w * 0.08, y: h * 0.68)
                    .blur(radius: 80)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// Backward-compatible alias for IsleFluidBackdrop.
struct IsleBackdrop: View {
    var body: some View {
        IsleFluidBackdrop()
    }
}

/// An authentic Apple-grade Liquid Glass Card.
/// Combines dynamic material blur, smooth continuous squircle corners,
/// tactile specular rim highlights, and multi-layered soft ambient shadows.
struct LiquidGlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    var padding: CGFloat = 18
    @ViewBuilder let content: Content

    init(cornerRadius: CGFloat = 22, padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.65),
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.06),
                            Color.white.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Color.black.opacity(0.05), radius: 22, x: 0, y: 10)
            .shadow(color: Color.blue.opacity(0.03), radius: 8, x: 0, y: 3)
    }
}

/// 3D Interactive Liquid Sanctuary Tile (Files, Photos, Cinema).
/// Tactile, responsive, floating with delicate ambient aura.
struct LiquidSanctuaryTile: View {
    let title: String
    let subtitle: String
    let detail: String
    let icon: String
    let gradientColors: [Color]
    let badgeText: String?
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            VStack(alignment: .leading, spacing: 14) {
                // Top row: Icon badge + arrow
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: gradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 42, height: 42)
                            .shadow(color: (gradientColors.first ?? .clear).opacity(0.35), radius: 8, y: 4)

                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    if let badge = badgeText {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "arrow.up.forward.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                        .opacity(hovered ? 0.9 : 0.4)
                        .scaleEffect(hovered ? 1.1 : 1.0)
                }

                // Title & Subtitles
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(hovered ? 0.28 : 0.16),
                                Color.white.opacity(hovered ? 0.10 : 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(hovered ? 0.85 : 0.55),
                            (gradientColors.first ?? Color.white).opacity(hovered ? 0.35 : 0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: hovered ? 1.5 : 1.0
                )
            }
            .shadow(
                color: Color.black.opacity(hovered ? 0.09 : 0.035),
                radius: hovered ? 22 : 12,
                y: hovered ? 10 : 4
            )
            .shadow(
                color: (gradientColors.first ?? .clear).opacity(hovered ? 0.22 : 0.0),
                radius: 16,
                y: 6
            )
            .offset(y: hovered && !reduceMotion ? -3 : 0)
            .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
            .onHover { hovered = $0 }
        }
        .buttonStyle(.plain)
    }
}

/// Compact, elegant Sanctuary Vitality Gauge capsule.
/// Displays metric gracefully with fluid colored progress and crisp typography.
struct LiquidHealthGauge: View {
    let title: String
    let valueText: String
    let subtext: String
    let progress: Double?
    let tint: Color
    let icon: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(valueText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtext)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Only measured utilization has a meaningful fraction. Network
            // throughput has no known capacity denominator.
            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 5)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [tint, tint.opacity(0.75)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, min(proxy.size.width * CGFloat(max(0, min(1, progress))), proxy.size.width)), height: 5)
                    }
                }
                .frame(height: 5)
            } else {
                Color.clear.frame(height: 5).accessibilityHidden(true)
            }
        }
        .padding(14)
        .background {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.white.opacity(0.08))
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.03), radius: 8, y: 2)
    }
}

/// An Apple-grade Inset Grouped Section Card (matching macOS System Settings).
/// Groups rows cleanly with subtle hairlines, pure crisp background, and rounded corners.
// Current section of the 偏好与安全 segmented control; groups that declare a
// section render only while it matches. Other pages leave it unset (nil-like
// general default) so groups without a section always render.
private struct PreferencesSectionKey: EnvironmentKey {
    static let defaultValue: PreferencesSection? = nil
}

extension EnvironmentValues {
    var currentPreferencesSection: PreferencesSection? {
        get { self[PreferencesSectionKey.self] }
        set { self[PreferencesSectionKey.self] = newValue }
    }
}

struct AppleSettingsGroup<Content: View>: View {
    let title: String?
    let footer: String?
    var preferenceSection: PreferencesSection? = nil
    @ViewBuilder let content: Content
    @Environment(\.currentPreferencesSection) private var currentSection

    init(preferenceSection: PreferencesSection? = nil, title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.preferenceSection = preferenceSection
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        if preferenceSection == nil || preferenceSection == currentSection {
            groupBody
        }
    }

    private var groupBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content
            }
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.04), radius: 16, y: 6)

            if let footer = footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A standard Apple Settings Row with label, optional icon/subtitle, and right-aligned control.
struct AppleSettingsRow<RightContent: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var iconTint: Color? = nil
    @ViewBuilder let rightContent: RightContent

    init(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        iconTint: Color? = nil,
        @ViewBuilder rightContent: () -> RightContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconTint = iconTint
        self.rightContent = rightContent()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((iconTint ?? Color.blue).opacity(0.14))
                        .frame(width: 26, height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder((iconTint ?? Color.blue).opacity(0.22), lineWidth: 1)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconTint ?? Color.blue)
                }
            }

            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            rightContent
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct IsleSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
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
                .scaleEffect(enabled && !reduceMotion ? (pressed ? 0.972 : hovered ? 1.012 : 1) : 1)
                .offset(y: enabled && !reduceMotion ? (pressed ? 1 : hovered ? -1.2 : 0) : 0)
                .brightness(enabled ? (pressed ? -0.03 : hovered ? 0.02 : 0) : 0)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: IsleTheme.smRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [IsleFluidPalette.cardItemTop, IsleFluidPalette.cardItemBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            )
            .overlay {
                RoundedRectangle(cornerRadius: IsleTheme.smRadius, style: .continuous)
                    .strokeBorder(IsleFluidPalette.rim.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: IsleFluidPalette.shadow.opacity(0.045), radius: 6, y: 2)
    }
}

/// Embossed, fully readable surface with stereoscopic three-dimensional presence.
struct IsleEmbossedSurface: ViewModifier {
    var cornerRadius: CGFloat = IsleTheme.radius
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [IsleFluidPalette.cardTop, IsleFluidPalette.cardBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [IsleFluidPalette.rim.opacity(0.92), IsleFluidPalette.rim.opacity(0.20)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1
                )
            }
            .shadow(
                color: IsleFluidPalette.shadow.opacity(IsleFluidPalette.cardShadowOpacity),
                radius: IsleFluidPalette.cardShadowRadius,
                y: IsleFluidPalette.cardShadowY
            )
    }
}

/// Embossed item surface for individual rows, cards, or list entries.
/// Replaces flat dividing lines with sculpted micro-cards.
struct IsleItemCardSurface: ViewModifier {
    var cornerRadius: CGFloat = IsleTheme.itemRadius
    var interactive: Bool = false
    @State private var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [
                            IsleFluidPalette.cardItemTop,
                            (hovered && interactive) ? IsleFluidPalette.cardHover : IsleFluidPalette.cardItemBottom
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            IsleFluidPalette.rim.opacity((hovered && interactive) ? 0.95 : 0.75),
                            IsleFluidPalette.rim.opacity((hovered && interactive) ? 0.35 : 0.16)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1
                )
            }
            .shadow(
                color: IsleFluidPalette.shadow.opacity((hovered && interactive) ? 0.08 : 0.035),
                radius: (hovered && interactive) ? 12 : 5,
                y: (hovered && interactive) ? 4 : 2
            )
            .offset(y: (hovered && interactive) ? -1.5 : 0)
            .animation(IsleMotion.quick, value: hovered)
            .onHover { isHovered in
                if interactive { hovered = isHovered }
            }
    }
}

/// Floating Liquid Glass navigation layer with continuous squircle border-radius.
struct IsleFloatingChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: IsleTheme.radius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [IsleFluidPalette.rim.opacity(0.78), IsleFluidPalette.rim.opacity(0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1
                )
            }
            .shadow(color: IsleFluidPalette.shadow.opacity(0.12), radius: 20, y: 8)
    }
}

struct LiquidCard<Content: View>: View {
    var cornerRadius: CGFloat = IsleTheme.radius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(22)
            .modifier(IsleEmbossedSurface(cornerRadius: cornerRadius))
    }
}

struct LiquidGroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) { content }
            .padding(10)
            .modifier(IsleEmbossedSurface())
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill((isOnline ? Color.green : Color.orange).opacity(0.11)))
        .overlay(Capsule().strokeBorder((isOnline ? Color.green : Color.orange).opacity(0.22), lineWidth: 1))
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
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: IsleTheme.smRadius, style: .continuous)
                            .fill(tint.opacity(0.13))
                            .frame(width: 38, height: 38)
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
                                .fill(LinearGradient(colors: [tint.opacity(0.72), tint], startPoint: .leading, endPoint: .trailing))
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
