import 'package:flutter/material.dart';

import '../../core/widgets.dart';

String _formatStorageGiB(double bytes) =>
    '${(bytes / (1 << 30)).toStringAsFixed(1)} GiB';

int _storageInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _storageDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

/// Computes root-level usage proportions across members + filesystem headroom
/// for [StoragePage] without storing or assuming a fake cross-disk total quota.
class StorageRootUsageSummary {
  const StorageRootUsageSummary({
    required this.total,
    required this.free,
    required this.accounted,
    required this.reserved,
    required this.otherUsed,
  });

  final double total;
  final double free;
  final double accounted;
  final double reserved;
  final double otherUsed;

  double get usedFraction =>
      total > 0 ? ((total - free) / total).clamp(0.0, 1.0) : 0.0;

  static StorageRootUsageSummary? fromRoot(
    Map<String, dynamic> root,
    Iterable<Map<String, dynamic>> policies,
  ) {
    if (root['online'] != true) return null;
    final total = _storageDouble(root['filesystemTotalBytes']);
    if (total <= 0) return null;
    final free = _storageDouble(root['filesystemAvailableBytes'])
        .clamp(0.0, total);
    final rootId = root['rootID']?.toString() ?? '';
    final generation = _storageInt(root['generation'], -1);

    var accounted = 0.0;
    var reserved = 0.0;
    for (final policy in policies) {
      final rawQuotas = policy['rootQuotas'];
      if (rawQuotas is! List) continue;
      for (final item in rawQuotas) {
        if (item is! Map) continue;
        if (item['rootID']?.toString() == rootId &&
            _storageInt(item['rootGeneration'], -2) == generation) {
          accounted += _storageDouble(item['accountedBytes']);
          reserved += _storageDouble(item['reservedBytes']);
        }
      }
    }

    final physicalUsed = (total - free).clamp(0.0, total);
    final cappedAccounted = accounted.clamp(0.0, physicalUsed);
    final cappedReserved = reserved.clamp(0.0, physicalUsed - cappedAccounted);
    final otherUsed = (physicalUsed - cappedAccounted - cappedReserved).clamp(
      0.0,
      physicalUsed,
    );
    return StorageRootUsageSummary(
      total: total,
      free: free,
      accounted: cappedAccounted,
      reserved: cappedReserved,
      otherUsed: otherUsed,
    );
  }
}

/// Compact multi-segment capacity bar for a registered online storage root.
class StorageRootBreakdownBar extends StatelessWidget {
  const StorageRootBreakdownBar({super.key, required this.summary});

  final StorageRootUsageSummary summary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final segments = <IsleChartSegment>[
      if (summary.accounted > 0)
        IsleChartSegment(
          label: '成员已入账',
          value: summary.accounted,
          color: const Color(0xff0071e3),
          detail: _formatStorageGiB(summary.accounted),
        ),
      if (summary.reserved > 0)
        IsleChartSegment(
          label: '预占',
          value: summary.reserved,
          color: const Color(0xfff59e0b),
          detail: _formatStorageGiB(summary.reserved),
        ),
      if (summary.otherUsed > 0)
        IsleChartSegment(
          label: summary.accounted > 0 ? '磁盘其他占用' : '磁盘已用',
          value: summary.otherUsed,
          color: colors.secondary.withValues(alpha: 0.55),
          detail: _formatStorageGiB(summary.otherUsed),
        ),
      IsleChartSegment(
        label: '可用',
        value: summary.free,
        color: const Color(0xff10b981).withValues(alpha: 0.72),
        detail: _formatStorageGiB(summary.free),
      ),
    ];
    return IsleSegmentedBar(
      height: 7,
      legendGap: 5,
      legendSpacing: 10,
      legendRunSpacing: 3,
      segments: segments,
    );
  }
}

/// Compact ring gauge badge showing a percentage inside [StoragePage] cards.
class StorageCompactDonut extends StatelessWidget {
  const StorageCompactDonut({
    super.key,
    required this.fraction,
    required this.color,
    this.semanticsLabel,
  });

  final double fraction;
  final Color color;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.clamp(0.0, 1.0);
    return IsleDonutGauge(
      fraction: clamped,
      color: color,
      size: 30,
      strokeWidth: 3.5,
      centerText: '${(clamped * 100).round()}%',
      centerStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontSize: 9,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      semanticsLabel: semanticsLabel,
    );
  }
}

/// Multi-segment quota bar (accounted + upload reserved + remaining quota).
class StorageQuotaSegmentedBar extends StatelessWidget {
  const StorageQuotaSegmentedBar({
    super.key,
    required this.used,
    required this.reserved,
    required this.max,
    this.showLegend = false,
  });

  final double used;
  final double reserved;
  final double max;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ratio = max > 0 ? ((used + reserved) / max).clamp(0.0, 1.0) : 0.0;
    final accountedColor = ratio >= 0.92
        ? const Color(0xffef4444)
        : ratio >= 0.8
        ? const Color(0xfff59e0b)
        : const Color(0xff0071e3);
    final remaining = (max - used - reserved).clamp(0.0, max);

    return IsleSegmentedBar(
      height: 7,
      showLegend: showLegend,
      legendGap: 5,
      legendSpacing: 10,
      legendRunSpacing: 3,
      segments: [
        if (used > 0)
          IsleChartSegment(
            label: '已入账',
            value: used,
            color: accountedColor,
            detail: _formatStorageGiB(used),
          ),
        if (reserved > 0)
          IsleChartSegment(
            label: '上传预占',
            value: reserved,
            color: const Color(0xfff59e0b),
            detail: _formatStorageGiB(reserved),
          ),
        IsleChartSegment(
          label: '剩余额度',
          value: remaining,
          color: colors.surfaceContainerHighest,
          detail: _formatStorageGiB(remaining),
        ),
      ],
      semanticsLabel:
          '配额占用 ${(ratio * 100).round()}%，已入账 ${_formatStorageGiB(used)}，'
          '预占 ${_formatStorageGiB(reserved)}，剩余 ${_formatStorageGiB(remaining)}',
    );
  }
}

/// Compact root status row with inline usage ring gauge and segmented breakdown.
class StorageRootSummaryRow extends StatelessWidget {
  const StorageRootSummaryRow({
    super.key,
    required this.root,
    required this.physicalLabel,
    required this.boundCount,
    required this.summary,
  });

  final Map<String, dynamic> root;
  final String physicalLabel;
  final int boundCount;
  final StorageRootUsageSummary? summary;

  @override
  Widget build(BuildContext context) {
    final online = root['online'] == true;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ratio = summary?.usedFraction ?? 0.0;
    final ringColor = ratio >= 0.9
        ? const Color(0xffef4444)
        : ratio >= 0.78
        ? const Color(0xfff59e0b)
        : const Color(0xff0071e3);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                online
                    ? Icons.check_circle_outline_rounded
                    : Icons.do_not_disturb_on_outlined,
                color: online
                    ? const Color(0xff10b981)
                    : const Color(0xfff59e0b),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          root['name']?.toString() ?? '未命名存储位置',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (root['isDefault'] == true)
                          const IsleStatusBadge(
                            label: '默认主目录',
                            color: Color(0xff0071e3),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$physicalLabel · 已绑定 $boundCount 个账号分类',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (summary != null) ...[
                const SizedBox(width: 8),
                StorageCompactDonut(
                  fraction: ratio,
                  color: ringColor,
                  semanticsLabel:
                      '${root['name'] ?? '存储位置'} 磁盘已用 ${(ratio * 100).round()}%',
                ),
              ],
            ],
          ),
          if (summary != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: StorageRootBreakdownBar(summary: summary!),
            ),
          ],
        ],
      ),
    );
  }
}
