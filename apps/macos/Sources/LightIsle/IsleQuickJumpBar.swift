import SwiftUI

/// Single contextual quick-jump destination in `IsleQuickJumpBar`.
struct IsleQuickJumpItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    var tint: Color
    let help: String
    let action: () -> Void

    init(
        _ title: String,
        icon: String,
        tint: Color = IsleTheme.accent,
        help: String,
        action: @escaping () -> Void
    ) {
        self.id = title
        self.title = title
        self.icon = icon
        self.tint = tint
        self.help = help
        self.action = action
    }
}

/// Restrained single-line contextual bridge connecting related management workflows.
struct IsleQuickJumpBar: View {
    var label: String = "相关直达"
    let items: [IsleQuickJumpItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(IsleTheme.secondaryText)
                .padding(.trailing, 2)

                ForEach(items) { item in
                    Button(action: item.action) {
                        HStack(spacing: 5) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.tint)
                            Text(item.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(IsleTheme.secondaryText.opacity(0.8))
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(IsleQuickJumpPillStyle(tint: item.tint))
                    .help(item.help)
                    .accessibilityLabel("\(item.title)：\(item.help)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: IsleTheme.smRadius, style: .continuous)
                .fill(IsleFluidPalette.cardTop.opacity(0.55))
        )
        .overlay {
            RoundedRectangle(cornerRadius: IsleTheme.smRadius, style: .continuous)
                .strokeBorder(IsleFluidPalette.rim.opacity(0.5), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }
}

private struct IsleQuickJumpPillStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        IsleQuickJumpPillSurface(label: configuration.label, pressed: configuration.isPressed, tint: tint)
    }
}

private struct IsleQuickJumpPillSurface<Label: View>: View {
    let label: Label
    let pressed: Bool
    let tint: Color
    @Environment(\.isleReduceMotion) private var reduceMotion
    @Environment(\.isleContrast) private var contrast
    @State private var hovered = false

    var body: some View {
        let shape = Capsule()
        label
            .background {
                shape.fill(
                    hovered
                        ? tint.opacity(0.13)
                        : IsleFluidPalette.cardItemTop.opacity(0.85)
                )
            }
            .overlay {
                shape.strokeBorder(
                    hovered
                        ? tint.opacity(0.36)
                        : (contrast == .increased ? Color.primary.opacity(0.45) : IsleFluidPalette.rim.opacity(0.65)),
                    lineWidth: 0.85
                )
                .allowsHitTesting(false)
            }
            .contentShape(shape)
            .scaleEffect(!reduceMotion && pressed ? 0.975 : 1)
            .brightness(pressed ? -0.03 : 0)
            .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
            .animation(reduceMotion ? nil : IsleMotion.fluid, value: pressed)
            .onHover { hovered = $0 }
    }
}

/// Standardized icon-only button for secondary actions with mandatory tooltip and VoiceOver label.
struct IsleIconButton: View {
    let icon: String
    var tint: Color? = nil
    var variant: LiquidButtonVariant = .secondary
    var size: LiquidButtonSize = .small
    let help: String
    var accessibilityLabel: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size == .large ? 14 : 12, weight: .semibold))
                .foregroundStyle(resolvedForeground)
                .frame(minWidth: 16, minHeight: 14)
        }
        .buttonStyle(LiquidButtonStyle(variant: variant, size: size))
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
    }

    private var resolvedForeground: Color {
        if let tint { return tint }
        switch variant {
        case .prominent: return IsleTheme.onAccent
        case .destructive: return IsleTheme.errorText
        case .borderless: return IsleTheme.accent
        case .secondary: return .primary
        }
    }
}
