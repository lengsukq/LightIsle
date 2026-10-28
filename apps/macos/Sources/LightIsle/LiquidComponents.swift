import SwiftUI
import AppKit

// Native semantic surfaces are generated from tokens.nativeMac; other clients
// retain their own presentation. Existing names keep business views source-compatible.
private struct IsleMotionOverrideKey: EnvironmentKey { static let defaultValue: Bool? = nil }
private struct IsleTransparencyOverrideKey: EnvironmentKey { static let defaultValue: Bool? = nil }
private struct IsleContrastOverrideKey: EnvironmentKey { static let defaultValue: ColorSchemeContrast? = nil }
extension EnvironmentValues {
    var isleReduceMotion: Bool {
        get { self[IsleMotionOverrideKey.self] ?? accessibilityReduceMotion }
        set { self[IsleMotionOverrideKey.self] = newValue }
    }
    var isleReduceTransparency: Bool {
        get { self[IsleTransparencyOverrideKey.self] ?? accessibilityReduceTransparency }
        set { self[IsleTransparencyOverrideKey.self] = newValue }
    }
    var isleContrast: ColorSchemeContrast {
        get { self[IsleContrastOverrideKey.self] ?? colorSchemeContrast }
        set { self[IsleContrastOverrideKey.self] = newValue }
    }
}
private struct IsleAccentKey: EnvironmentKey { static let defaultValue = IsleFluidPalette.brandBlue }
extension EnvironmentValues {
    var isleAccent: Color {
        get { self[IsleAccentKey.self] }
        set { self[IsleAccentKey.self] = newValue }
    }
}

extension ManagementSection {
    var tint: Color {
        switch self {
        case .overview, .services: return IsleFluidPalette.brandBlue
        case .storage: return IsleFluidPalette.brandCyan
        case .spaces: return IsleFluidPalette.brandViolet
        case .containers: return IsleFluidPalette.brandIndigo
        case .settings: return IsleFluidPalette.brandViolet
        }
    }
}

enum IsleTheme {
    static let accent = IsleFluidPalette.accentPrimary
    static let onAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    })
    static let violet = accent
    static let warningText = IsleFluidPalette.warningText
    static let errorText = IsleFluidPalette.errorText
    static let successText = IsleFluidPalette.successText
    static let secondaryText = IsleFluidPalette.secondaryText
    static let radius = IsleFluidPalette.cardRadius
    static let heroRadius = IsleFluidPalette.heroRadius
    static let itemRadius = IsleFluidPalette.itemRadius
    static let smRadius = IsleFluidPalette.smRadius
    static let contentPadding: CGFloat = 24
}

enum IsleMotion {
    static let quick = Animation.easeOut(duration: IsleFluidPalette.hoverSeconds)
    static let fluid = Animation.spring(response: IsleFluidPalette.expandSeconds, dampingFraction: 0.86)
    static let navigation = Animation.spring(response: IsleFluidPalette.navigationSeconds, dampingFraction: 0.88)
    static let reveal = navigation
}

struct IsleGroupSpacing: View {
    var height: CGFloat = 8
    var body: some View { Color.clear.frame(height: height) }
}

struct IsleFluidBackdrop: View {
    @Environment(\.isleReduceTransparency) private var opaque
    @Environment(\.isleContrast) private var contrast
    var body: some View {
        ZStack {
            IsleFluidPalette.canvasTop
            if !opaque && contrast != .increased {
                LinearGradient(colors: [IsleFluidPalette.canvasTop, IsleFluidPalette.canvasBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [IsleFluidPalette.brandCyan.opacity(0.055), .clear], center: .topTrailing, startRadius: 0, endRadius: 650)
                RadialGradient(colors: [IsleFluidPalette.brandViolet.opacity(0.045), .clear], center: .bottomLeading, startRadius: 0, endRadius: 520)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct IsleBackdrop: View { var body: some View { IsleFluidBackdrop() } }

struct IsleEmbossedSurface: ViewModifier {
    var cornerRadius: CGFloat = IsleTheme.radius
    @Environment(\.isleContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(IsleFluidPalette.cardTop, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.48), lineWidth: 1).allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(IsleFluidPalette.cardShadowOpacity), radius: IsleFluidPalette.cardShadowRadius, y: IsleFluidPalette.cardShadowY)
    }
}
struct IsleItemCardSurface: ViewModifier {
    var cornerRadius: CGFloat = IsleTheme.itemRadius
    var interactive = false
    @State private var hovered = false
    @Environment(\.isleReduceMotion) private var reduceMotion
    @Environment(\.isleContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(hovered && interactive ? IsleFluidPalette.cardHover : IsleFluidPalette.cardItemTop, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.45), lineWidth: 1).allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(hovered && interactive ? 0.09 : 0.045), radius: hovered && interactive ? 20 : 12, y: hovered && interactive ? 9 : 5)
            .offset(y: hovered && interactive && !reduceMotion ? -2 : 0)
            .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
            .onHover { hovered = interactive && $0 }
    }
}
struct IsleFloatingChrome: ViewModifier {
    @Environment(\.isleReduceTransparency) private var opaque
    @Environment(\.isleContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background {
                if opaque || contrast == .increased {
                    RoundedRectangle(cornerRadius: IsleTheme.radius).fill(IsleFluidPalette.cardTop)
                } else {
                    RoundedRectangle(cornerRadius: IsleTheme.radius).fill(.regularMaterial)
                }
            }
            .overlay {
                if contrast == .increased { RoundedRectangle(cornerRadius: IsleTheme.radius).strokeBorder(Color.primary.opacity(0.5)) }
            }
    }
}
struct LiquidCard<Content: View>: View {
    var cornerRadius: CGFloat = IsleTheme.radius
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).modifier(IsleEmbossedSurface(cornerRadius: cornerRadius)) }
}
struct LiquidGlassCard<Content: View>: View {
    var cornerRadius: CGFloat = IsleTheme.radius
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View { content.padding(padding).modifier(IsleEmbossedSurface(cornerRadius: cornerRadius)) }
}
struct LiquidGroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(spacing: 8) { content }.padding(12).modifier(IsleEmbossedSurface()) }
}

enum LiquidButtonVariant { case prominent, secondary, destructive, borderless }
enum LiquidButtonSize { case small, regular, large }
struct LiquidButtonStyle: ButtonStyle {
    var variant: LiquidButtonVariant = .secondary
    var size: LiquidButtonSize = .regular
    func makeBody(configuration: Configuration) -> some View {
        NativeButtonSurface(label: configuration.label, pressed: configuration.isPressed, variant: variant, size: size)
    }
}
private struct NativeButtonSurface<Label: View>: View {
    let label: Label
    let pressed: Bool
    let variant: LiquidButtonVariant
    let size: LiquidButtonSize
    @Environment(\.isleAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isleReduceMotion) private var reduceMotion
    @Environment(\.isleContrast) private var contrast
    @State private var hovered = false
    private var foreground: Color {
        switch variant {
        case .prominent: return IsleTheme.onAccent
        case .destructive: return IsleTheme.errorText
        case .borderless: return accent
        case .secondary: return .primary
        }
    }
    private var background: Color {
        if variant == .prominent { return accent }
        if variant == .borderless { return hovered ? Color.primary.opacity(0.06) : .clear }
        return hovered ? IsleFluidPalette.cardHover : IsleFluidPalette.cardTop
    }
    var body: some View {
        label
            .font(.system(size: size == .large ? 14 : 12, weight: .medium))
            .padding(.horizontal, size == .small ? 10 : 14)
            .padding(.vertical, size == .large ? 10 : 6)
            .frame(minHeight: size == .large ? 36 : 28)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: IsleTheme.smRadius))
            .overlay {
                RoundedRectangle(cornerRadius: IsleTheme.smRadius)
                    .strokeBorder(Color.primary.opacity(variant == .borderless || variant == .prominent ? 0 : contrast == .increased ? 0.5 : 0.16))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: IsleTheme.smRadius))
            .scaleEffect(enabled && !reduceMotion && pressed ? 0.975 : 1)
            .brightness(enabled && pressed ? -0.045 : 0)
            .opacity(enabled ? 1 : 0.48)
            .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
            .animation(reduceMotion ? nil : IsleMotion.fluid, value: pressed)
            .onHover { hovered = enabled && $0 }
    }
}
struct IsleActionButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        NativeButtonSurface(label: configuration.label, pressed: configuration.isPressed,
                            variant: destructive ? .destructive : prominent ? .prominent : .secondary, size: .regular)
    }
}
struct IslePressStyle: ButtonStyle {
    @Environment(\.isleReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : IsleMotion.fluid, value: configuration.isPressed)
    }
}

struct LiquidInputModifier: ViewModifier {
    var cornerRadius: CGFloat = IsleTheme.smRadius
    @FocusState private var focused: Bool
    @Environment(\.isleContrast) private var contrast
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(focused ? IsleTheme.accent : Color.primary.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}
struct IsleTextFieldSurface: ViewModifier {
    func body(content: Content) -> some View { content.modifier(LiquidInputModifier()) }
}
extension View {
    func liquidInput(cornerRadius: CGFloat = IsleTheme.smRadius) -> some View { modifier(LiquidInputModifier(cornerRadius: cornerRadius)) }
}

struct LiquidMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var icon: String? = nil
    var id: Value { value }
}
struct LiquidMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [LiquidMenuOption<Value>]
    var minWidth: CGFloat = 148
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in Text(option.label).tag(option.value) }
        }
        .labelsHidden().pickerStyle(.menu).frame(minWidth: minWidth, maxWidth: 340).frame(height: 30)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(title)
    }
}
struct LiquidSegmentedPicker<Value: Hashable>: View {
    enum Style { case regular, tabs }
    let title: String
    @Binding var selection: Value
    let options: [LiquidMenuOption<Value>]
    var style: Style = .regular
    @Namespace private var selectionAnimation
    @Environment(\.isleReduceMotion) private var reduceMotion
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(options) { option in
                    Button {
                        withAnimation(reduceMotion ? nil : IsleMotion.navigation) { selection = option.value }
                    } label: {
                        HStack(spacing: 6) {
                            if let icon = option.icon { Image(systemName: icon) }
                            Text(option.label)
                        }
                        .font(.system(size: 12, weight: selection == option.value ? .semibold : .regular))
                        .foregroundStyle(selection == option.value ? Color.primary : IsleTheme.secondaryText)
                        .padding(.horizontal, 11).frame(minHeight: 30)
                        .background {
                            if selection == option.value {
                                RoundedRectangle(cornerRadius: 6).fill(IsleFluidPalette.cardTop)
                                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: selectionAnimation)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(IslePressStyle())
                    .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                }
            }.padding(3).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                .fixedSize(horizontal: true, vertical: false)
            LiquidMenuPicker(title: title, selection: $selection, options: options)
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

private struct PreferencesSectionKey: EnvironmentKey { static let defaultValue: PreferencesSection? = nil }
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
    @ViewBuilder var content: () -> Content
    @Environment(\.currentPreferencesSection) private var currentSection
    init(preferenceSection: PreferencesSection? = nil, title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.preferenceSection = preferenceSection; self.title = title; self.footer = footer; self.content = content
    }
    var body: some View {
        if preferenceSection == nil || preferenceSection == currentSection {
            VStack(alignment: .leading, spacing: 10) {
                if let title { Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 2) }
                VStack(spacing: 0) { content() }.modifier(IsleEmbossedSurface())
                if let footer {
                    Text(footer).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
                }
            }
        }
    }
}
struct AppleSettingsRow<RightContent: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var iconTint: Color? = nil
    @ViewBuilder var rightContent: RightContent
    @Environment(\.isleAccent) private var accent
    init(title: String, subtitle: String? = nil, icon: String? = nil, iconTint: Color? = nil, @ViewBuilder rightContent: () -> RightContent) {
        self.title = title; self.subtitle = subtitle; self.icon = icon; self.iconTint = iconTint; self.rightContent = rightContent()
    }
    private var label: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon { Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 28, height: 28).background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var body: some View {
        SettingsRowLayout {
            label
            VStack(alignment: .leading, spacing: 8) { rightContent }.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Measure both columns with an unconstrained height. GeometryReader-driven
/// state here caused feedback between row width, text compression and height.
struct SettingsRowLayout: Layout {
    private func metrics(_ width: CGFloat, _ views: Subviews) -> (Bool, CGSize, CGSize) {
        guard let first = views.first else { return (true, .zero, .zero) }
        if views.count == 1 {
            return (true, first.sizeThatFits(ProposedViewSize(width: width, height: nil)), .zero)
        }
        let ideal = views[1].sizeThatFits(.unspecified)
        let stacked = width < 660 || ideal.width > width * 0.58
        let rightWidth = stacked ? width : min(max(ideal.width, 28), width * 0.58)
        let leftWidth = stacked ? width : max(120, width - rightWidth - 20)
        return (stacked,
                views[0].sizeThatFits(ProposedViewSize(width: leftWidth, height: nil)),
                views[1].sizeThatFits(ProposedViewSize(width: rightWidth, height: nil)))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(proposal.width ?? 600, 1)
        let (stacked, left, right) = metrics(width, subviews)
        return CGSize(width: width, height: subviews.count == 1 ? left.height : stacked ? left.height + 10 + right.height : max(left.height, right.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if subviews.count == 1 {
            let size = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            return
        }
        let (stacked, left, right) = metrics(bounds.width, subviews)
        let rightWidth = stacked ? bounds.width : min(max(subviews[1].sizeThatFits(.unspecified).width, 28), bounds.width * 0.58)
        let leftWidth = stacked ? bounds.width : max(120, bounds.width - rightWidth - 20)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: stacked ? bounds.minY : bounds.midY - left.height / 2), proposal: ProposedViewSize(width: leftWidth, height: left.height))
        subviews[1].place(at: CGPoint(x: stacked ? bounds.minX : bounds.maxX - rightWidth, y: stacked ? bounds.minY + left.height + 10 : bounds.midY - right.height / 2), proposal: ProposedViewSize(width: rightWidth, height: right.height))
    }
}

struct IsleSectionHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(IsleTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}
private struct BrandStatusLabelStyle: LabelStyle {
    let online: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) { configuration.icon.foregroundStyle(online ? IsleTheme.successText : IsleTheme.warningText); configuration.title }
    }
}
struct StatusBadge: View {
    let isOnline: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: isOnline ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.system(size: 12, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
            .labelStyle(BrandStatusLabelStyle(online: isOnline))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct LiquidSanctuaryTile: View {
    let title: String
    let subtitle: String
    let detail: String
    let icon: String
    let gradientColors: [Color]
    let badgeText: String?
    let action: () -> Void
    @State private var hovered = false
    private var accent: Color { icon.contains("photo") ? IsleFluidPalette.brandViolet : icon.contains("film") ? IsleFluidPalette.brandIndigo : IsleFluidPalette.brandCyan }
    @Environment(\.isleReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(accent)
                        .frame(width: 42, height: 42).background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(IsleTheme.secondaryText)
                        .offset(x: hovered && !reduceMotion ? 2 : 0, y: hovered && !reduceMotion ? -2 : 0)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText)
                    Text(detail).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText).lineLimit(2)
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(IsleItemCardSurface(interactive: true))
                .offset(y: hovered && !reduceMotion ? -2 : 0)
                .animation(reduceMotion ? nil : IsleMotion.fluid, value: hovered)
        }.buttonStyle(IslePressStyle()).onHover { hovered = $0 }
            .help("在浏览器中打开" + title)
    }
}
struct LiquidHealthGauge: View {
    let title: String
    let valueText: String
    let subtext: String
    let progress: Double?
    let tint: Color
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(tint)
                Spacer(minLength: 0)
                IsleDetailInfo(title: title, rows: [("当前读数", valueText), ("说明", subtext), ("数据来源", "本机最新采样；未取得读数时显示等待采样")])
            }
            Text(valueText).font(.system(size: 23, weight: .semibold)).foregroundStyle(tint).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(subtext).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText).lineLimit(2)
            if let progress { ProgressView(value: max(0, min(1, progress))).tint(tint).accessibilityLabel(title) }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(IsleEmbossedSurface())
    }
}
struct BentoStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color
    var progress: Double? = nil
    var body: some View { LiquidHealthGauge(title: title, valueText: value, subtext: subtitle, progress: progress, tint: tint, icon: icon) }
}
struct IsleHistoryGraph: View {
    let title: String
    let values: [Double]
    let maximum: Double
    let tint: Color
    var body: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Text("最近 \(values.count) 次采样").font(.caption).foregroundStyle(IsleTheme.secondaryText) }
                GeometryReader { geometry in
                    Path { path in
                        let points = Array(values.suffix(120))
                        for (index, value) in points.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * geometry.size.width / CGFloat(max(points.count - 1, 1)), y: geometry.size.height * (1 - CGFloat(min(max(value, 0), max(1, maximum)) / max(1, maximum))))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }.stroke(IsleTheme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }.frame(height: 76)
                    .accessibilityLabel(title).accessibilityValue(values.last.map { String(format: "%.1f", $0) } ?? "暂无数据")
            }
        }
    }
}
