import 'package:flutter/material.dart';

import '../../core/widgets.dart';

/// Admin overview Bento grid displaying CPU, memory breakdown, system disk,
/// and network throughput with Apple-style native vector charts.
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

  @override
  Widget build(BuildContext context) {
    final memoryTotal = (stats['memoryTotal'] as num?) ?? 0;
    final memoryUsed = (stats['memoryUsed'] as num?) ?? 0;
    final diskTotal = (stats['diskTotal'] as num?) ?? 0;
    final diskFree = (stats['diskFree'] as num?) ?? 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
        final columns = largeText
            ? (width >= 760 ? 2 : 1)
            : width >= 680
            ? 4
            : 2;
        final gap = width < IsleLayout.compactPageWidth ? 8.0 : 12.0;

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
        final ringTextStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        final trackColor = Theme.of(context)
            .colorScheme
            .surfaceContainerHighest;

        final cards = [
          IsleBentoStatCard(
            title: '处理器',
            value: _percent(stats['cpuPercent']),
            detail: '${stats['cpuCount']} 核 · ${stats['architecture']}',
            icon: Icons.memory_rounded,
            color: const Color(0xff0071e3),
            gradient: const [Color(0xff2589ff), Color(0xff0066cc)],
            trailingChart: cpuPct == null
                ? null
                : IsleDonutGauge(
                    fraction: cpuPct,
                    color: const Color(0xff0071e3),
                    size: 38,
                    strokeWidth: 4.5,
                    centerText: '${(cpuPct * 100).round()}%',
                    centerStyle: ringTextStyle,
                    semanticsLabel:
                        '处理器占用 ${(cpuPct * 100).toStringAsFixed(1)}%',
                  ),
            footer: cpuHistory.isEmpty
                ? null
                : IsleSparkline(
                    values: cpuHistory,
                    color: const Color(0xff0071e3),
                    height: 26,
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
            color: const Color(0xff8b5cf6),
            gradient: const [Color(0xffa78bfa), Color(0xff7c3aed)],
            trailingChart: memPct == null
                ? null
                : IsleDonutGauge(
                    fraction: memPct,
                    color: const Color(0xff8b5cf6),
                    size: 38,
                    strokeWidth: 4.5,
                    centerText: '${(memPct * 100).round()}%',
                    centerStyle: ringTextStyle,
                    semanticsLabel:
                        '内存占用 ${(memPct * 100).toStringAsFixed(1)}%',
                  ),
            footer: memoryTotal > 0
                ? IsleSegmentedBar(
                    height: 7,
                    legendGap: 5,
                    legendSpacing: 8,
                    legendRunSpacing: 2,
                    segments: [
                      if (coreRss > 0)
                        IsleChartSegment(
                          label: '核心服务',
                          value: coreRss,
                          color: const Color(0xff7c3aed),
                          detail: formatBytes(coreRss),
                        ),
                      if (otherMemUsed > 0)
                        IsleChartSegment(
                          label: coreRss > 0 ? '系统已用' : '已用',
                          value: otherMemUsed,
                          color: const Color(0xffc084fc),
                          detail: formatBytes(otherMemUsed),
                        ),
                      IsleChartSegment(
                        label: '可用',
                        value: memFree,
                        color: trackColor,
                        detail: formatBytes(memFree),
                      ),
                    ],
                  )
                : null,
          ),
          IsleBentoStatCard(
            title: '系统磁盘',
            value: '${formatBytes(diskFree)} 可用',
            detail: '共 ${formatBytes(diskTotal)}',
            icon: Icons.storage_rounded,
            color: const Color(0xff0ea5e9),
            gradient: const [Color(0xff38bdf8), Color(0xff0284c7)],
            trailingChart: diskPct == null
                ? null
                : IsleDonutGauge(
                    fraction: diskPct,
                    color: const Color(0xff0ea5e9),
                    size: 38,
                    strokeWidth: 4.5,
                    centerText: '${(diskPct * 100).round()}%',
                    centerStyle: ringTextStyle,
                    semanticsLabel:
                        '系统磁盘已用 ${(diskPct * 100).toStringAsFixed(1)}%',
                  ),
            footer: diskTotal > 0
                ? IsleSegmentedBar(
                    height: 7,
                    legendGap: 5,
                    legendSpacing: 8,
                    legendRunSpacing: 2,
                    segments: [
                      IsleChartSegment(
                        label: '已用',
                        value: diskUsedBytes,
                        color: const Color(0xff0ea5e9),
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
                  )
                : null,
          ),
          IsleBentoStatCard(
            title: '网络',
            value: '↓ ${formatBytes(stats['networkDownBps'] as num?)}/s',
            detail: '↑ ${formatBytes(stats['networkUpBps'] as num?)}/s',
            icon: Icons.swap_vert_rounded,
            color: const Color(0xff10b981),
            gradient: const [Color(0xff34d399), Color(0xff059669)],
            footer: netHistory.isEmpty
                ? null
                : IsleSparkline(
                    values: netHistory,
                    color: const Color(0xff10b981),
                    height: 26,
                    minValue: 0,
                    semanticsLabel: '网络吞吐趋势',
                  ),
          ),
        ];

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: List.generate(
            cards.length,
            (i) => SizedBox(
              width: (width - (columns - 1) * gap) / columns,
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
