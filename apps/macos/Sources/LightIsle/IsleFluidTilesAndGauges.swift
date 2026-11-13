import SwiftUI

struct LiquidSanctuaryTile: View {
    let title: String
    let subtitle: String
    let detail: String
    let icon: String
    let badgeText: String?
    let action: () -> Void
    @State private var hovered = false
    private var accent: Color { icon.contains("photo") ? IsleFluidPalette.brandViolet : icon.contains("film") ? IsleFluidPalette.brandIndigo : IsleFluidPalette.brandCyan }
    @Environment(\.isleReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon).font(.system(size: 21, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .background(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(accent.opacity(0.24), lineWidth: 0.8) }
                    Spacer()
                    if let badgeText {
                        Text(badgeText).font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(accent.opacity(0.10), in: Capsule())
                    }
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(IsleTheme.secondaryText)
                        .frame(width: 26, height: 26).background(Color.primary.opacity(0.045), in: Circle())
                        .offset(x: hovered && !reduceMotion ? 2 : 0, y: hovered && !reduceMotion ? -2 : 0)
                        .animation(reduceMotion ? nil : IsleMotion.quick, value: hovered)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    Text(detail).font(.system(size: 12)).foregroundStyle(IsleTheme.secondaryText).lineLimit(2)
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(IsleItemCardSurface(interactive: true))
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
    var sparklineValues: [Double]? = nil
    var sparklineMax: Double? = nil
    var segmentedSlices: [IsleChartSlice]? = nil
    var segmentedTotal: Double? = nil
    @Environment(\.isleReduceMotion) private var reduceMotion

    var body: some View {
        let clamped = IsleChartMath.clampProgress(progress)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 26, height: 26).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(IsleTheme.secondaryText)
                Spacer(minLength: 0)
                IsleDetailInfo(title: title, rows: [("当前读数", valueText), ("说明", subtext), ("数据来源", "本机最新采样；未取得读数时显示等待采样")])
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(valueText)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .animation(reduceMotion ? nil : IsleMotion.quick, value: valueText)
                    Text(subtext)
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsleTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if let clamped {
                    IsleDonutGauge(
                        progress: clamped,
                        centerText: "\(Int(round(clamped * 100)))%",
                        tint: tint,
                        size: 50,
                        lineWidth: 5.5,
                        accessibilityLabel: title
                    )
                }
            }

            if let segmentedSlices, !segmentedSlices.isEmpty {
                IsleSegmentedBar(
                    slices: segmentedSlices,
                    total: segmentedTotal,
                    barHeight: 7,
                    showsLegend: true,
                    legendMinimumWidth: 110,
                    accessibilityTitle: "\(title)构成"
                )
            }

            if let sparklineValues {
                IsleSparkline(
                    values: sparklineValues,
                    minimum: 0,
                    maximum: sparklineMax,
                    tint: tint,
                    height: 26,
                    accessibilityLabel: "\(title)最近采样趋势",
                    latestValueText: valueText
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(IsleEmbossedSurface())
    }
}

struct IsleHistoryGraph: View {
    let title: String
    let values: [Double]
    let maximum: Double
    let tint: Color
    var body: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("最近 \(values.count) 次采样").font(.system(size: 11, weight: .medium)).foregroundStyle(IsleTheme.secondaryText)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.primary.opacity(0.045), in: Capsule())
                }
                GeometryReader { geometry in
                    let points = Array(values.suffix(120))
                    let cap = max(1, maximum)
                    ZStack {
                        if points.count > 1 {
                            Path { path in
                                for (index, value) in points.enumerated() {
                                    let x = CGFloat(index) * geometry.size.width / CGFloat(max(points.count - 1, 1))
                                    let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), cap) / cap))
                                    if index == 0 { path.move(to: CGPoint(x: x, y: geometry.size.height)); path.addLine(to: CGPoint(x: x, y: y)) }
                                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                                }
                                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                                path.closeSubpath()
                            }.fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        }
                        Path { path in
                            for (index, value) in points.enumerated() {
                                let point = CGPoint(x: CGFloat(index) * geometry.size.width / CGFloat(max(points.count - 1, 1)), y: geometry.size.height * (1 - CGFloat(min(max(value, 0), cap) / cap)))
                                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                        }.stroke(tint, style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                    }
                }.frame(height: 76)
                    .accessibilityLabel(title).accessibilityValue(values.last.map { String(format: "%.1f", $0) } ?? "暂无数据")
            }
        }
    }
}
