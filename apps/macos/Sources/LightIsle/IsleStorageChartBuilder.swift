import SwiftUI

/// Shared chart slice builders ensuring consistent colors and honest labeling
/// across Overview, Storage, and Personal Spaces views.
@MainActor
enum IsleStorageChartBuilder {
    private static let memberPalette: [Color] = [
        IsleFluidPalette.brandBlue,
        IsleFluidPalette.brandViolet,
        IsleFluidPalette.brandCyan,
        .orange,
        .pink
    ]

    static func memorySlices(
        total: UInt64,
        used: UInt64,
        appRss: UInt64,
        coreRss: UInt64
    ) -> [IsleChartSlice] {
        let parts = IsleChartMath.memoryBreakdown(
            total: total,
            used: used,
            appRss: appRss,
            coreRss: coreRss
        )
        return [
            IsleChartSlice(
                label: "轻屿服务",
                value: Double(parts.lightisle),
                displayValue: IsleFormatters.fileSize(parts.lightisle),
                color: IsleFluidPalette.brandBlue
            ),
            IsleChartSlice(
                label: "系统其他",
                value: Double(parts.other),
                displayValue: IsleFormatters.fileSize(parts.other),
                color: IsleFluidPalette.brandViolet
            ),
            IsleChartSlice(
                label: "可用内存",
                value: Double(parts.free),
                displayValue: IsleFormatters.fileSize(parts.free),
                color: Color.primary.opacity(0.14)
            )
        ]
    }

    static func volumeSlices(
        total: UInt64,
        free: UInt64,
        rootID: String? = nil,
        rootGeneration: UInt64? = nil,
        users: [NativeSpaceUserEntry] = []
    ) -> [IsleChartSlice] {
        let clampedFree = min(free, total)
        let used = total - clampedFree

        var memberPairs: [(name: String, bytes: UInt64)] = []
        if let rootID {
            for entry in users {
                let matching = entry.policy.rootQuotas.filter {
                    $0.rootID == rootID && (rootGeneration == nil || $0.rootGeneration == rootGeneration)
                }
                let rawBytes = matching.reduce(Int64(0)) { partial, rq in
                    partial + max(0, rq.accountedBytes) + max(0, rq.reservedBytes)
                }
                if rawBytes > 0 {
                    memberPairs.append((entry.user.username, UInt64(rawBytes)))
                }
            }
        }
        memberPairs.sort { $0.bytes > $1.bytes }

        let totalMemberRaw = memberPairs.reduce(UInt64(0)) { $0 + $1.bytes }
        let parts = IsleChartMath.volumeBreakdown(
            total: total,
            free: clampedFree,
            memberBytes: totalMemberRaw
        )

        var slices: [IsleChartSlice] = []
        if !memberPairs.isEmpty && parts.members > 0 {
            var remainingCap = parts.members
            let head = Array(memberPairs.prefix(4))
            for (index, item) in head.enumerated() where remainingCap > 0 {
                let alloc = min(item.bytes, remainingCap)
                remainingCap -= alloc
                if alloc > 0 {
                    slices.append(
                        IsleChartSlice(
                            id: "member-\(item.name)-\(index)",
                            label: item.name,
                            value: Double(alloc),
                            displayValue: IsleFormatters.fileSize(alloc),
                            color: memberPalette[index % memberPalette.count]
                        )
                    )
                }
            }
            if remainingCap > 0 {
                slices.append(
                    IsleChartSlice(
                        id: "member-others",
                        label: "其他成员",
                        value: Double(remainingCap),
                        displayValue: IsleFormatters.fileSize(remainingCap),
                        color: .teal
                    )
                )
            }
            slices.append(
                IsleChartSlice(
                    id: "other-used",
                    label: "磁盘其他已用",
                    value: Double(parts.otherUsed),
                    displayValue: IsleFormatters.fileSize(parts.otherUsed),
                    color: Color.orange.opacity(0.65)
                )
            )
        } else {
            slices.append(
                IsleChartSlice(
                    id: "used",
                    label: "已用空间",
                    value: Double(used),
                    displayValue: IsleFormatters.fileSize(used),
                    color: IsleFluidPalette.brandBlue
                )
            )
        }

        slices.append(
            IsleChartSlice(
                id: "free",
                label: "剩余可用",
                value: Double(parts.free),
                displayValue: IsleFormatters.fileSize(parts.free),
                color: Color.primary.opacity(0.14)
            )
        )
        return slices
    }

    static func memberQuotaSlices(
        quotaBytes: Int64,
        accountedBytes: Int64,
        reservedBytes: Int64,
        enforcement: String
    ) -> [IsleChartSlice] {
        let parts = IsleChartMath.memberQuotaBreakdown(
            quotaBytes: quotaBytes,
            accountedBytes: accountedBytes,
            reservedBytes: reservedBytes
        )
        let pending = enforcement == "pending"
        var slices: [IsleChartSlice] = [
            IsleChartSlice(
                id: "accounted",
                label: pending ? "应用内已入账" : "已入账空间",
                value: Double(parts.accounted),
                displayValue: IsleFormatters.fileSize(parts.accounted),
                color: IsleTheme.accent
            )
        ]
        if parts.reserved > 0 || pending {
            slices.append(
                IsleChartSlice(
                    id: "reserved",
                    label: "传输预占中",
                    value: Double(parts.reserved),
                    displayValue: IsleFormatters.fileSize(parts.reserved),
                    color: .orange
                )
            )
        }
        slices.append(
            IsleChartSlice(
                id: "remaining",
                label: "剩余可用额度",
                value: Double(parts.remaining),
                displayValue: IsleFormatters.fileSize(parts.remaining),
                color: Color.primary.opacity(0.14)
            )
        )
        return slices
    }
}
