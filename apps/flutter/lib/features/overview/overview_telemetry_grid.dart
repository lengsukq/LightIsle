import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/widgets.dart';

/// Admin overview Bento grid displaying CPU, memory breakdown, system disk,
/// and network throughput with curated Warm Gallery pigments, vector charts,
/// and locked equal card heights across mobile (2x2) and desktop (1x4) grids.
class AdminTelemetryBentoGrid extends StatelessWidget {
  const AdminTelemetryBentoGrid({
    super.key,
    required this.stats,
    this.cpuHistory = const [],
    this.netHistory = const [],
  });

  final Map<String, dynamic> stats;
  final List<double> cpuHistory;
  final List<double> netHistory;

  static String _percent(Object? value) =>
      value is num ? '${value.clamp(0, 100).toStringAsFixed(1)}%' : '采样中';

  Widget _buildSingleLineBarFooter(
    BuildContext context, {
    required double height,
    required List<IsleChartSegment> barSegments,
    required List<(Color, String)> legendItems,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 11,
      height: 1.25,
      color: colors.onSurfaceVariant,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IsleSegmentedBar(
            height: 6,
            showLegend: false,
            segments: barSegments,
          ),
          Text.rich(
            TextSpan(
              style: labelStyle,
              children: [
                for (var i = 0; i < legendItems.length; i++) ...[
                  if (i > 0) const TextSpan(text: ' · '),
                  TextSpan(
                    text: '● ',
                    style: TextStyle(
                      fontSize: 9.5,
                      color: legendItems[i].$1,
                    ),
                  ),
                  TextSpan(text: legendItems[i].$2),
                ],
              ],
            ),
            strutStyle: const StrutStyle(
              fontSize: 11,
              height: 1.25,
              forceStrutHeight: true,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final memoryTotal = (stats['memoryTotal'] as num?) ?? 0;
    final memoryUsed = (stats['memoryUsed'] as num?) ?? 0;
    final diskTotal = (stats['diskTotal'] as num?) ?? 0;
    final diskFree = (stats['diskFree'] as num?) ?? 0;
    final palette = IslePalette.of(context);

    final cpuColor = palette['brandBlue']; // Mineral Teal
    final memColor = palette['brandViolet']; // Muted Plum
    final diskColor = palette['brandAmber']; // Warm Ochre
    final netColor = palette['brandSage']; // Botanical Sage

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final textScaler = MediaQuery.textScalerOf(context);
        final largeText = textScaler.scale(14) > 19;
        final columns = largeText
            ? (width >= 760 ? 2 : 1)
            : width >= 680
            ? 4
            : 2;
        final gap = width < IsleLayout.compactPageWidth ? 8.0 : 12.0;
        final legendRowHeight = math.max(
          14.0,
          (textScaler.scale(11.0) * 1.32).ceilToDouble(),
        );
        final footerHeight = 6.0 + 4.0 + legendRowHeight;

        final cpuPct = stats['cpuPercent'] is num
            ? (stats['cpuPercent'] as num).toDouble().clamp(0.0, 100.0) / 100
            : null;
        final memPct = memoryTotal > 0
            ? (memoryUsed / memoryTotal).clamp(0.0, 1.0).toDouble()
            : null;
        final diskPct = diskTotal > 0
            ? (1.0 - (diskFree / diskTotal)).clamp(0.0, 1.0).toDouble()
            : null;
        final coreRss = ((stats['coreRssBytes'] as num?)?.toDouble() ?? 0.0)
            .clamp(0.0, memoryUsed.toDouble());
        final otherMemUsed = (memoryUsed.toDouble() - coreRss).clamp(
          0.0,
          memoryTotal.toDouble(),
        );
        final memFree = (memoryTotal.toDouble() - memoryUsed.toDouble()).clamp(
          0.0,
          memoryTotal.toDouble(),
        );
        final diskUsedBytes = (diskTotal.toDouble() - diskFree.toDouble())
            .clamp(0.0, diskTotal.toDouble());
        final downBps = (stats['networkDownBps'] as num?)?.toDouble() ?? 0.0;
        final upBps = (stats['networkUpBps'] as num?)?.toDouble() ?? 0.0;
        final ringTextStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        final trackColor = Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest;

        final effectiveCpuHistory = cpuHistory.isNotEmpty
            ? cpuHistory
            : (cpuPct != null ? <double>[cpuPct * 100] : const <double>[]);
        final effectiveNetHistory = netHistory.isNotEmpty
            ? netHistory
            : <double>[(downBps + upBps).clamp(0.0, double.infinity)];

        final cards = [
          IsleBentoStatCard(
            title: '处理器',
            value: _percent(stats['cpuPercent']),
            detail: '${stats['cpuCount']} 核 · ${stats['architecture']}',
            icon: Icons.memory_rounded,
            color: cpuColor,
            trailingChart: cpuPct == null
                ? null
                : IsleDonutGauge(
                    fraction: cpuPct,
                    color: cpuColor,
                    size: 34,
                    strokeWidth: 4.0,
                    centerText: '${(cpuPct * 100).round()}%',
                    centerStyle: ringTextStyle,
                    semanticsLabel:
                        '处理器占用 ${(cpuPct * 100).toStringAsFixed(1)}%',
                  ),
            footer: IsleSparkline(
              values: effectiveCpuHistory,
              color: cpuColor,
              height: footerHeight,
              minValue: 0,
              maxValue: 100,
              semanticsLabel: '处理器占用率趋势',
            ),
          ),
          IsleBentoStatCard(
            title: '内存',
            value: formatBytes(memoryUsed),
            detail:
                '共 ${formatBytes(memoryTotal)} · ${memoryTotal == 0 ? '—' : _percent(memoryUsed / memoryTotal * 100)}',
            icon: Icons.speed_rounded,
            color: memColor,
            trailingChart: memPct == null
                ? null
                : IsleDonutGauge(
                    fraction: memPct,
                    color: memColor,
                    size: 34,
                    strokeWidth: 4.0,
                    centerText: '${(memPct * 100).round()}%',
                    centerStyle: ringTextStyle,
                    semanticsLabel:
                        '内存占用 ${(memPct * 100).toStringAsFixed(1)}%',
                  ),
            footer: memoryTotal > 0
                ? _buildSingleLineBarFooter(
                    context,
                    height: footerHeight,
                    barSegments: [
                      if (coreRss > 0)
                        IsleChartSegment(
                          label: '核心服务',
                          value: coreRss,
                          color: memColor,
                          detail: formatBytes(coreRss),
                        ),
                      if (otherMemUsed > 0)
                        IsleChartSegment(
                          label: coreRss > 0 ? '系统已用' : '已用',
                          value: otherMemUsed,
                          color: memColor.withValues(alpha: 0.55),
                          detail: formatBytes(otherMemUsed),
                        ),
                      IsleChartSegment(
                        label: '可用',
                        value: memFree,
                        color: trackColor,
                        detail: formatBytes(memFree),
                      ),
                    ],
                    legendItems: [
                      if (coreRss > 0)
                        (memColor, '核心服务 ${formatBytes(coreRss)}'),
                      if (otherMemUsed > 0)
                        (
                          memColor.withValues(alpha: 0.65),
                          '${coreRss > 0 ? '系统' : '已用'} ${formatBytes(otherMemUsed)}',
                        )
                      else
                        (trackColor, '可用 ${formatBytes(memFree)}'),
                    ],
                  )
                : SizedBox(height: footerHeight),
          ),
          IsleBentoStatCard(
            title: '系统磁盘',
            value: '${formatBytes(diskFree)} 可用',
            detail: '共 ${formatBytes(diskTotal)}',
            icon: Icons.storage_rounded,
            color: diskColor,
            trailingChart: diskPct == null
                ? null
                : IsleDonutGauge(
                    fraction: diskPct,
                    color: diskColor,
                    size: 34,
                    strokeWidth: 4.0,
                    centerText: '${(diskPct * 100).round()}%',
                    centerStyle: ringTextStyle,
                    semanticsLabel:
                        '系统磁盘已用 ${(diskPct * 100).toStringAsFixed(1)}%',
                  ),
            footer: diskTotal > 0
                ? _buildSingleLineBarFooter(
                    context,
                    height: footerHeight,
                    barSegments: [
                      IsleChartSegment(
                        label: '已用',
                        value: diskUsedBytes,
                        color: diskColor,
                        detail: formatBytes(diskUsedBytes),
                      ),
                      IsleChartSegment(
                        label: '可用',
                        value: diskFree.toDouble().clamp(
                          0.0,
                          diskTotal.toDouble(),
                        ),
                        color: trackColor,
                        detail: formatBytes(diskFree),
                      ),
                    ],
                    legendItems: [
                      (diskColor, '已用 ${formatBytes(diskUsedBytes)}'),
                      (trackColor, '可用 ${formatBytes(diskFree)}'),
                    ],
                  )
                : SizedBox(height: footerHeight),
          ),
          IsleBentoStatCard(
            title: '网络',
            value: '↓ ${formatBytes(stats['networkDownBps'] as num?)}/s',
            detail: '↑ ${formatBytes(stats['networkUpBps'] as num?)}/s',
            icon: Icons.swap_vert_rounded,
            color: netColor,
            footer: IsleSparkline(
              values: effectiveNetHistory,
              color: netColor,
              height: footerHeight,
              minValue: 0,
              semanticsLabel: '网络吞吐趋势',
            ),
          ),
        ];

        final itemWidth = (width - (columns - 1) * gap) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: List.generate(
            cards.length,
            (i) => SizedBox(
              width: itemWidth,
              child: IsleAnimatedEntrance(
                delay: Duration(milliseconds: 35 * i),
                child: cards[i],
              ),
            ),
          ),
        );
      },
    );
  }
}
