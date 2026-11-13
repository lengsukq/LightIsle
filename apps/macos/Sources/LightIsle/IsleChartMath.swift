import CoreGraphics
import Foundation

/// Pure proportion and geometry helpers for macOS native vector charts.
enum IsleChartMath {
    static func clampProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    static func sanitizedNonNegative(_ values: [Double]) -> [Double] {
        values.map { $0.isFinite ? max(0, $0) : 0 }
    }

    /// Computes non-overflowing pixel widths for positive segments inside `containerWidth`.
    static func segmentWidths(
        values: [Double],
        total: Double?,
        containerWidth: CGFloat,
        gapWidth: CGFloat = 1.5,
        minVisibleWidth: CGFloat = 4
    ) -> [CGFloat] {
        guard containerWidth > 0, !values.isEmpty else {
            return Array(repeating: 0, count: values.count)
        }
        let clean = sanitizedNonNegative(values)
        let positiveIndices = clean.indices.filter { clean[$0] > 0 }
        guard !positiveIndices.isEmpty else {
            return Array(repeating: 0, count: values.count)
        }
        let sum = clean.reduce(0, +)
        let effectiveTotal = max(total.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? sum, sum)
        guard effectiveTotal > 0 else {
            return Array(repeating: 0, count: values.count)
        }

        let gapCount = max(0, positiveIndices.count - 1)
        let usableWidth = max(0, containerWidth - CGFloat(gapCount) * max(0, gapWidth))
        guard usableWidth > 0 else {
            return Array(repeating: 0, count: values.count)
        }

        let floorWidth = min(minVisibleWidth, usableWidth / CGFloat(positiveIndices.count))
        var widths = Array(repeating: CGFloat(0), count: values.count)
        var locked = Set<Int>()
        var remainingWidth = usableWidth
        var remainingValue = effectiveTotal

        // Iteratively lock tiny non-zero slices to `floorWidth` so remaining slices stay proportional.
        while true {
            var bumpedAny = false
            for idx in positiveIndices where !locked.contains(idx) {
                let candidate = remainingValue > 0 ? remainingWidth * CGFloat(clean[idx] / remainingValue) : 0
                if candidate < floorWidth {
                    widths[idx] = floorWidth
                    locked.insert(idx)
                    remainingWidth = max(0, remainingWidth - floorWidth)
                    remainingValue = max(0, remainingValue - clean[idx])
                    bumpedAny = true
                }
            }
            if !bumpedAny { break }
        }

        for idx in positiveIndices where !locked.contains(idx) {
            let ratio = remainingValue > 0 ? clean[idx] / remainingValue : 0
            widths[idx] = max(0, remainingWidth * CGFloat(ratio))
        }
        return widths
    }

    static func normalizedSparklinePoints(
        values: [Double],
        minimum: Double? = nil,
        maximum: Double? = nil,
        size: CGSize
    ) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let clean = values.map { $0.isFinite ? $0 : 0 }
        let minVal = clean.min() ?? 0
        let maxVal = clean.max() ?? 0
        let lo = minimum.flatMap { $0.isFinite ? $0 : nil } ?? minVal
        let hi = maximum.flatMap { $0.isFinite ? $0 : nil } ?? maxVal
        let span = hi - lo
        let verticalPadding: CGFloat = 2
        let usableHeight = max(1, size.height - verticalPadding * 2)

        return clean.enumerated().map { index, val in
            let x = CGFloat(index) * size.width / CGFloat(max(clean.count - 1, 1))
            let ratio: Double
            if span <= 1e-9 {
                ratio = val <= lo ? 0 : 0.5
            } else {
                ratio = min(1, max(0, (val - lo) / span))
            }
            let y = verticalPadding + usableHeight * CGFloat(1 - ratio)
            return CGPoint(x: x, y: y)
        }
    }

    static func memoryBreakdown(
        total: UInt64,
        used: UInt64,
        appRss: UInt64,
        coreRss: UInt64
    ) -> (lightisle: UInt64, other: UInt64, free: UInt64) {
        let clampedUsed = min(used, total)
        let (combinedRss, overflow) = appRss.addingReportingOverflow(coreRss)
        let safeRss = overflow ? UInt64.max : combinedRss
        let lightisle = min(safeRss, clampedUsed)
        let other = clampedUsed - lightisle
        let free = total - clampedUsed
        return (lightisle, other, free)
    }

    static func volumeBreakdown(
        total: UInt64,
        free: UInt64,
        memberBytes: UInt64
    ) -> (members: UInt64, otherUsed: UInt64, free: UInt64) {
        let clampedFree = min(free, total)
        let used = total - clampedFree
        let members = min(memberBytes, used)
        let otherUsed = used - members
        return (members, otherUsed, clampedFree)
    }

    static func memberQuotaBreakdown(
        quotaBytes: Int64,
        accountedBytes: Int64,
        reservedBytes: Int64
    ) -> (accounted: Int64, reserved: Int64, remaining: Int64, overLimit: Int64) {
        let safeQuota = max(0, quotaBytes)
        let safeAccounted = max(0, accountedBytes)
        let safeReserved = max(0, reservedBytes)
        let totalUsed = safeAccounted.saturatingAdd(safeReserved)
        if totalUsed >= safeQuota {
            return (safeAccounted, safeReserved, 0, totalUsed - safeQuota)
        }
        return (safeAccounted, safeReserved, safeQuota - totalUsed, 0)
    }
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (result, overflow) = addingReportingOverflow(other)
        if overflow {
            return (self >= 0 && other >= 0) ? Int64.max : Int64.min
        }
        return result
    }
}
