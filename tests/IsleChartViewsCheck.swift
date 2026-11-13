import AppKit
import Foundation
import SwiftUI

@main
struct IsleChartViewsCheck {
    @MainActor
    static func main() {
        // 1. Progress clamping & NaN/Inf safety
        precondition(IsleChartMath.clampProgress(nil) == nil)
        precondition(IsleChartMath.clampProgress(.nan) == nil)
        precondition(IsleChartMath.clampProgress(.infinity) == nil)
        precondition(IsleChartMath.clampProgress(-0.2) == 0)
        precondition(IsleChartMath.clampProgress(1.8) == 1)
        precondition(IsleChartMath.clampProgress(0.42) == 0.42)

        // 2. Segmented bar proportional widths must never overflow containerWidth
        let widths = IsleChartMath.segmentWidths(
            values: [1_000_000, 50_000_000_000, 49_999_000_000],
            total: 100_000_000_000,
            containerWidth: 320,
            gapWidth: 1.5,
            minVisibleWidth: 4
        )
        precondition(widths.count == 3)
        precondition(widths[0] >= 4, "tiny non-zero segment should remain visible")
        let totalRendered = widths.reduce(0, +) + 2 * 1.5
        precondition(abs(totalRendered - 320) <= 0.5, "segments overflowed container: \(totalRendered)")

        // Zero-total safety
        let zeroWidths = IsleChartMath.segmentWidths(values: [0, 0], total: 0, containerWidth: 200)
        precondition(zeroWidths == [0, 0])

        // 3. Memory breakdown invariant: lightisle + other + free == total even if RSS > used
        let mem = IsleChartMath.memoryBreakdown(total: 1000, used: 400, appRss: 300, coreRss: 250)
        precondition(mem.lightisle == 400 && mem.other == 0 && mem.free == 600)
        let normalMem = IsleChartMath.memoryBreakdown(total: 1000, used: 600, appRss: 120, coreRss: 80)
        precondition(normalMem.lightisle == 200 && normalMem.other == 400 && normalMem.free == 400)

        // 4. Volume & member breakdown invariant
        let vol = IsleChartMath.volumeBreakdown(total: 1000, free: 450, memberBytes: 300)
        precondition(vol.members == 300 && vol.otherUsed == 250 && vol.free == 450)
        let clampedVol = IsleChartMath.volumeBreakdown(total: 1000, free: 450, memberBytes: 900)
        precondition(clampedVol.members == 550 && clampedVol.otherUsed == 0 && clampedVol.free == 450)

        // 5. Member quota breakdown (pending / over-limit honesty)
        let quotaNormal = IsleChartMath.memberQuotaBreakdown(quotaBytes: 1000, accountedBytes: 300, reservedBytes: 150)
        precondition(quotaNormal.accounted == 300 && quotaNormal.reserved == 150 && quotaNormal.remaining == 550 && quotaNormal.overLimit == 0)
        let quotaOver = IsleChartMath.memberQuotaBreakdown(quotaBytes: 1000, accountedBytes: 900, reservedBytes: 300)
        precondition(quotaOver.remaining == 0 && quotaOver.overLimit == 200)

        // 6. Sparkline normalization with edge cases
        precondition(IsleChartMath.normalizedSparklinePoints(values: [1.0], size: CGSize(width: 100, height: 30)).isEmpty)
        let flatPoints = IsleChartMath.normalizedSparklinePoints(values: [5, 5, 5], minimum: 0, maximum: 10, size: CGSize(width: 100, height: 30))
        precondition(flatPoints.count == 3 && flatPoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let peakPoints = IsleChartMath.normalizedSparklinePoints(values: [0, 50, 100], minimum: 0, maximum: 100, size: CGSize(width: 120, height: 34))
        precondition(peakPoints.count == 3 && peakPoints[0].y > peakPoints[1].y && peakPoints[1].y > peakPoints[2].y)

        // 7. SwiftUI chart layout checks across narrow & regular widths
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let sampleSlices = [
            IsleChartSlice(label: "轻屿服务", value: 180, displayValue: "180 MB", color: .blue),
            IsleChartSlice(label: "系统其他", value: 420, displayValue: "420 MB", color: .purple),
            IsleChartSlice(label: "可用内存", value: 400, displayValue: "400 MB", color: .gray.opacity(0.3))
        ]
        for width in [CGFloat(490), 780] {
            let panel = VStack(alignment: .leading, spacing: 12) {
                HStack {
                    IsleDonutGauge(progress: 0.6, centerText: "60%", centerSubtext: "已用", tint: .blue, accessibilityLabel: "磁盘使用率")
                    IsleSparkline(values: [12, 24, 18, 30, 28], minimum: 0, maximum: 100, tint: .cyan)
                }
                IsleSegmentedBar(slices: sampleSlices, total: 1000, accessibilityTitle: "内存构成")
            }
            .padding(14)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            let size = NSHostingView(rootView: panel).fittingSize
            precondition(size.height > 70 && size.height < 260, "chart panel unexpected height \(size.height) at width \(width)")
        }
        print("PASS: IsleChartMath invariants and SwiftUI chart layout checks")
    }
}
