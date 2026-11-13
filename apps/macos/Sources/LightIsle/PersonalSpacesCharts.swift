import SwiftUI

/// Admin pool summary showing each online root's member-accounted vs other-used vs free split.
struct PersonalSpacesPoolDistributionView: View {
    @ObservedObject var spaces: NativeSpacesModel

    var body: some View {
        let rootsWithCapacity = spaces.onlineRoots.filter {
            ($0.filesystemTotalBytes ?? 0) > 0 && $0.filesystemAvailableBytes != nil
        }
        if !rootsWithCapacity.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("各存储目录成员占用构成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IsleTheme.secondaryText)
                ForEach(rootsWithCapacity) { root in
                    let total = root.filesystemTotalBytes ?? 0
                    let free = min(root.filesystemAvailableBytes ?? 0, total)
                    let usedRatio = total > 0 ? Double(total - free) / Double(total) : 0
                    let slices = IsleStorageChartBuilder.volumeSlices(
                        total: total,
                        free: free,
                        rootID: root.rootID,
                        rootGeneration: root.generation,
                        users: spaces.users
                    )
                    HStack(alignment: .center, spacing: 12) {
                        IsleDonutGauge(
                            progress: usedRatio,
                            centerText: "\(Int(round(usedRatio * 100)))%",
                            tint: usedRatio > 0.88 ? .orange : IsleFluidPalette.brandCyan,
                            size: 46,
                            lineWidth: 5,
                            accessibilityLabel: "\(root.name) 磁盘占用比例"
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(root.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                if root.isDefault {
                                    IsleStatusPill(text: "默认盘", tone: .accent)
                                }
                                Spacer()
                                Text("可用 \(IsleFormatters.fileSize(free)) / 共 \(IsleFormatters.fileSize(total))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(IsleTheme.secondaryText)
                            }
                            IsleSegmentedBar(
                                slices: slices,
                                total: Double(total),
                                barHeight: 9,
                                showsLegend: true,
                                legendMinimumWidth: 132,
                                accessibilityTitle: "\(root.name) 成员空间与磁盘占用构成"
                            )
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }
}

/// Physical disk ring + bar shown inside an admin account card with unlimited software quota.
struct PersonalSpacesAdminDiskSummaryView: View {
    @ObservedObject var spaces: NativeSpacesModel
    let preferredRootID: String

    var body: some View {
        let targetRoot = spaces.rootInfo(for: preferredRootID)
            ?? spaces.onlineRoots.first(where: \.isDefault)
            ?? spaces.onlineRoots.first
        if let root = targetRoot,
           let total = root.filesystemTotalBytes,
           let avail = root.filesystemAvailableBytes,
           total > 0 {
            let clampedFree = min(avail, total)
            let usedRatio = Double(total - clampedFree) / Double(total)
            let slices = IsleStorageChartBuilder.volumeSlices(
                total: total,
                free: clampedFree,
                rootID: root.rootID,
                rootGeneration: root.generation,
                users: spaces.users
            )
            HStack(alignment: .center, spacing: 12) {
                IsleDonutGauge(
                    progress: usedRatio,
                    centerText: "\(Int(round(usedRatio * 100)))%",
                    centerSubtext: "磁盘",
                    tint: usedRatio > 0.88 ? .orange : IsleFluidPalette.brandBlue,
                    size: 50,
                    lineWidth: 5,
                    accessibilityLabel: "\(root.name) 物理磁盘占用比例"
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("当前物理磁盘上限参考：\(root.name)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(IsleTheme.secondaryText)
                        Spacer()
                        Text("可用 \(IsleFormatters.fileSize(clampedFree)) / 共 \(IsleFormatters.fileSize(total))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(IsleTheme.secondaryText)
                    }
                    IsleSegmentedBar(
                        slices: slices,
                        total: Double(total),
                        barHeight: 9,
                        showsLegend: true,
                        legendMinimumWidth: 132,
                        accessibilityTitle: "\(root.name) 物理磁盘占比"
                    )
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Member quota ring badge + honest accounted/reserved/remaining segmented bar.
struct PersonalSpacesMemberQuotaMeterView: View {
    let quotaBytes: Int64
    let accountedBytes: Int64
    let reservedBytes: Int64
    let enforcement: String

    var body: some View {
        let parts = IsleChartMath.memberQuotaBreakdown(
            quotaBytes: quotaBytes,
            accountedBytes: accountedBytes,
            reservedBytes: reservedBytes
        )
        let totalUsed = max(0, accountedBytes) + max(0, reservedBytes)
        let rawRatio = quotaBytes > 0 ? Double(totalUsed) / Double(quotaBytes) : 0
        let clampedRatio = min(1.0, max(0, rawRatio))
        let ringTint: Color = rawRatio >= 1.0 ? IsleTheme.errorText : (rawRatio > 0.85 ? .orange : IsleTheme.accent)
        let slices = IsleStorageChartBuilder.memberQuotaSlices(
            quotaBytes: quotaBytes,
            accountedBytes: accountedBytes,
            reservedBytes: reservedBytes,
            enforcement: enforcement
        )

        HStack(alignment: .center, spacing: 12) {
            IsleDonutGauge(
                progress: clampedRatio,
                centerText: "\(Int(round(clampedRatio * 100)))%",
                tint: ringTint,
                size: 46,
                lineWidth: 5,
                accessibilityLabel: "成员目录配额使用率",
                accessibilityValueText: "已用 \(Int(round(rawRatio * 100)))%"
            )
            VStack(alignment: .leading, spacing: 6) {
                IsleSegmentedBar(
                    slices: slices,
                    total: Double(max(quotaBytes, totalUsed)),
                    barHeight: 9,
                    showsLegend: true,
                    legendMinimumWidth: 130,
                    accessibilityTitle: "成员配额构成"
                )
                if parts.overLimit > 0 {
                    Text("当前已超出设定配额 \(IsleFormatters.fileSize(parts.overLimit))，请调高配额或清理文件。")
                        .font(.caption2)
                        .foregroundStyle(IsleTheme.warningText)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
