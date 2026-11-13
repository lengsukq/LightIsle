import SwiftUI

/// Data slice used across `IsleSegmentedBar` and `IsleDonutGauge` breakdowns.
struct IsleChartSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let value: Double
    let displayValue: String
    let color: Color

    init(
        id: String? = nil,
        label: String,
        value: Double,
        displayValue: String,
        color: Color
    ) {
        self.id = id ?? label
        self.label = label
        self.value = value.isFinite ? max(0, value) : 0
        self.displayValue = displayValue
        self.color = color
    }
}

/// Crisp vector ring gauge with zero idle animations and full VoiceOver metadata.
struct IsleDonutGauge: View {
    let progress: Double?
    let centerText: String
    var centerSubtext: String? = nil
    let tint: Color
    var size: CGFloat = 58
    var lineWidth: CGFloat = 6.5
    let accessibilityLabel: String
    var accessibilityValueText: String? = nil

    @Environment(\.isleReduceMotion) private var reduceMotion
    @Environment(\.isleContrast) private var contrast

    private var clamped: Double {
        IsleChartMath.clampProgress(progress) ?? 0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    contrast == .increased ? Color.primary.opacity(0.22) : Color.primary.opacity(0.085),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            if progress != nil && clamped > 0 {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.75), tint],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(max(12, 360 * clamped))
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : IsleMotion.fluid, value: clamped)
            }

            VStack(spacing: 1) {
                Text(centerText)
                    .font(.system(size: size >= 64 ? 13 : 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let centerSubtext, !centerSubtext.isEmpty {
                    Text(centerSubtext)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            accessibilityValueText ?? (progress.map { _ in String(format: "%.0f%%", clamped * 100) } ?? centerText)
        )
    }
}

/// Apple System Settings Storage-style multi-color segmented capacity bar with wrapped legend.
struct IsleSegmentedBar: View {
    let slices: [IsleChartSlice]
    var total: Double? = nil
    var barHeight: CGFloat = 11
    var showsLegend: Bool = true
    var legendMinimumWidth: CGFloat = 148
    var accessibilityTitle: String = "空间构成"

    @Environment(\.isleReduceMotion) private var reduceMotion
    @Environment(\.isleContrast) private var contrast

    private var activeSlices: [IsleChartSlice] {
        slices.filter { $0.value > 0 }
    }

    private var effectiveTotal: Double {
        let sum = slices.reduce(0) { $0 + $1.value }
        return max(total.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? sum, sum)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { proxy in
                let widths = IsleChartMath.segmentWidths(
                    values: activeSlices.map(\.value),
                    total: effectiveTotal,
                    containerWidth: proxy.size.width,
                    gapWidth: 1.5,
                    minVisibleWidth: 4
                )
                let shape = RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                ZStack(alignment: .leading) {
                    shape.fill(Color.primary.opacity(0.065))

                    if !activeSlices.isEmpty {
                        HStack(spacing: 1.5) {
                            ForEach(Array(activeSlices.enumerated()), id: \.element.id) { index, slice in
                                Rectangle()
                                    .fill(slice.color)
                                    .frame(width: index < widths.count ? widths[index] : 0)
                            }
                        }
                        .clipShape(shape)
                        .animation(reduceMotion ? nil : IsleMotion.fluid, value: activeSlices.map(\.value))
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        contrast == .increased ? Color.primary.opacity(0.45) : IsleFluidPalette.rim.opacity(0.55),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(height: barHeight)

            if showsLegend {
                if slices.isEmpty || effectiveTotal <= 0 {
                    Text("暂无构成统计")
                        .font(.system(size: 11))
                        .foregroundStyle(IsleTheme.secondaryText)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: legendMinimumWidth), spacing: 10, alignment: .leading)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(slices) { slice in
                            let sharePct = effectiveTotal > 0 ? (slice.value / effectiveTotal) * 100 : 0
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 7.5, height: 7.5)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
                                    }
                                Text(slice.label)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(sharePct >= 1 || slice.value == 0
                                     ? "\(slice.displayValue) · \(Int(round(sharePct)))%"
                                     : "\(slice.displayValue) · <1%")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(
            slices.map { "\($0.label) \($0.displayValue)" }.joined(separator: "，")
        )
    }
}

/// Compact area sparkline without timers or idle background activity.
struct IsleSparkline: View {
    let values: [Double]
    var minimum: Double? = 0
    var maximum: Double? = nil
    let tint: Color
    var height: CGFloat = 34
    var accessibilityLabel: String = "最近采样趋势"
    var latestValueText: String? = nil

    var body: some View {
        GeometryReader { geometry in
            let points = IsleChartMath.normalizedSparklinePoints(
                values: values,
                minimum: minimum,
                maximum: maximum,
                size: geometry.size
            )
            ZStack {
                if points.count >= 2 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))

                    if let last = points.last {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .overlay {
                                Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                            }
                            .position(last)
                    }
                } else {
                    Path { path in
                        let y = geometry.size.height * 0.55
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                    .stroke(
                        tint.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3])
                    )
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(latestValueText ?? (values.last.map { String(format: "%.1f", $0) } ?? "等待采样"))
    }
}
