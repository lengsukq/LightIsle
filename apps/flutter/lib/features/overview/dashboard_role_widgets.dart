import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

/// Curated multi-pigment studio launchpad with crisp single-line tiles.
class DashboardQuickLinks extends StatelessWidget {
  const DashboardQuickLinks({
    super.key,
    required this.onNavigate,
    required this.admin,
    this.onOpenFiles,
    this.onOpenShares,
    this.onOpenAppsCenter,
    this.onOpenComputerFiles,
    this.onOpenDownloads,
    this.onQuickUpload,
  });

  final ValueChanged<int> onNavigate;
  final bool admin;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenShares;
  final VoidCallback? onOpenAppsCenter;
  final VoidCallback? onOpenComputerFiles;
  final VoidCallback? onOpenDownloads;
  final VoidCallback? onQuickUpload;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final palette = IslePalette.of(context);
      final bigText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final width = constraints.maxWidth;

      final links = <(String, VoidCallback, IconData, String, Color, bool)>[
        (
          'dashboardFilesEntry',
          onOpenFiles ?? () => onNavigate(-1),
          Icons.folder_rounded,
          '文件管理',
          palette['brandAmber'],
          true,
        ),
        (
          'dashboardPhotosEntry',
          () => onNavigate(1),
          Icons.photo_library_rounded,
          '时光相册',
          palette['brandRose'],
          false,
        ),
        (
          'dashboardCinemaEntry',
          () => onNavigate(2),
          Icons.movie_rounded,
          '私人影院',
          palette['brandTerracotta'],
          false,
        ),
        if (!admin && onOpenDownloads != null)
          (
            'dashboardDownloadsEntry',
            onOpenDownloads!,
            Icons.downloading_rounded,
            '下载中心',
            palette['brandSage'],
            false,
          ),
        if (onOpenComputerFiles != null)
          (
            'dashboardComputerFilesEntry',
            onOpenComputerFiles!,
            Icons.laptop_mac_rounded,
            '电脑文件',
            palette['brandBlue'],
            false,
          ),
        if (onOpenAppsCenter != null)
          (
            'dashboardAppsEntry',
            onOpenAppsCenter!,
            Icons.apps_rounded,
            '应用中心',
            palette['brandViolet'],
            false,
          ),
        if (onOpenShares != null)
          (
            'dashboardSharesEntry',
            onOpenShares!,
            Icons.ios_share_rounded,
            '我的分享',
            palette['brandIndigo'],
            false,
          )
        else if (onQuickUpload != null)
          (
            'dashboardUploadEntry',
            onQuickUpload!,
            Icons.cloud_upload_outlined,
            '快速上传',
            palette['brandSage'],
            false,
          ),
      ];

      final columns = bigText
          ? (width >= 640 ? 2 : 1)
          : width >= 680
          ? 3
          : width >= 300
          ? 2
          : 1;
      final gap = width < IsleLayout.compactPageWidth ? 8.0 : 10.0;
      final cardWidth = (width - (columns - 1) * gap) / columns;
      final compactCard = cardWidth < 200;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IsleSectionHeader(
            title: '快捷入口',
            accentColor: palette['brandAmber'],
            action: onQuickUpload != null
                ? TextButton.icon(
                    onPressed: onQuickUpload,
                    icon: const Icon(Icons.upload_file_rounded, size: 16),
                    label: const Text('快速上传'),
                  )
                : null,
          ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < links.length; i++)
                Builder(
                  builder: (context) {
                    final item = links[i];
                    final isHero = item.$6;
                    final tone = item.$5;
                    return SizedBox(
                      width: cardWidth,
                      child: IsleAnimatedEntrance(
                        delay: Duration(milliseconds: 20 * i),
                        child: IsleSurface(
                          key: ValueKey(item.$1),
                          tint: isHero ? tone : null,
                          radius: IsleRadius.item,
                          padding: EdgeInsets.symmetric(
                            horizontal: compactCard ? 11 : 13,
                            vertical: compactCard ? 10 : 11,
                          ),
                          onTap: item.$2,
                          child: Row(
                            children: [
                              IsleSquircleBadge(
                                icon: item.$3,
                                color: tone,
                                size: compactCard ? 32 : 34,
                                iconSize: compactCard ? 16.5 : 17.5,
                              ),
                              SizedBox(width: compactCard ? 9 : 11),
                              Expanded(
                                child: Text(
                                  item.$4,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontSize: compactCard ? 13.5 : 14,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.15,
                                  ),
                                ),
                              ),
                              if (!compactCard)
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 16,
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.45),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// Per-disk quota ledger card styled as a warm physical drive allocation bay.
class MemberStorageSummary extends StatelessWidget {
  const MemberStorageSummary({super.key, required this.storage});

  final Map<String, dynamic> storage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    final quotas = objectList(storage['rootQuotas']);
    final count = objectList(storage['locations']).length;
    final complete = storage['usageComplete'] == true;
    return IsleSurface(
      radius: IsleRadius.card,
      tint: palette['brandAmber'],
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.storage_rounded,
                color: palette['brandAmber'],
                size: 32,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '我的存储空间',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IsleStatusBadge(
                label: '$count 个目录',
                color: palette['brandAmber'],
              ),
            ],
          ),
          if (quotas.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '尚未分配独立硬盘额度，可在设置中查看分类存储位置。',
                style: theme.textTheme.bodySmall,
              ),
            )
          else ...[
            const SizedBox(height: 12),
            IsleResponsiveGrid(
              minItemWidth: 280,
              maxColumns: 2,
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < quotas.length; i++)
                  Builder(
                    builder: (context) {
                      final quota = quotas[i];
                      final bound = quota['quotaBytes'] as num?;
                      final accounted = (quota['accountedBytes'] as num?) ?? 0;
                      final reserved = (quota['reservedBytes'] as num?) ?? 0;
                      final name = quota['name']?.toString();
                      final diskId = quota['rootID']?.toString() ?? '';
                      final suffix = diskId.length > 6
                          ? diskId.substring(0, 6)
                          : diskId;
                      final label = name != null && name.isNotEmpty
                          ? name
                          : '硬盘 $suffix';
                      final progress = bound != null && bound > 0
                          ? ((accounted + reserved) / bound)
                                .clamp(0.0, 1.0)
                                .toDouble()
                          : null;
                      final quotaColor = progress == null
                          ? palette['brandBlue']
                          : progress >= 0.92
                          ? palette['error']
                          : progress >= 0.8
                          ? palette['warning']
                          : palette['brandSage'];
                      final remaining = bound != null && bound > 0
                          ? (bound - accounted - reserved)
                                .clamp(0.0, bound)
                                .toDouble()
                          : 0.0;
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: IsleDecorations.recessedWell(context),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${formatBytes(accounted)} / '
                                  '${bound == null ? '不限额' : formatBytes(bound)}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (progress != null) ...[
                                  const SizedBox(width: 8),
                                  IsleDonutGauge(
                                    fraction: progress,
                                    color: quotaColor,
                                    size: 28,
                                    strokeWidth: 3.2,
                                    centerText: '${(progress * 100).round()}%',
                                    centerStyle: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.w800,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                    semanticsLabel:
                                        '$label 配额已用 ${(progress * 100).round()}%',
                                  ),
                                ],
                              ],
                            ),
                            if (progress != null) ...[
                              const SizedBox(height: 7),
                              IsleSegmentedBar(
                                height: 6.5,
                                legendGap: 5,
                                legendSpacing: 10,
                                legendRunSpacing: 2,
                                segments: [
                                  if (accounted > 0)
                                    IsleChartSegment(
                                      label: '已入账',
                                      value: accounted.toDouble(),
                                      color: quotaColor,
                                      detail: formatBytes(accounted),
                                    ),
                                  if (reserved > 0)
                                    IsleChartSegment(
                                      label: '上传预占',
                                      value: reserved.toDouble(),
                                      color: palette['warning'],
                                      detail: formatBytes(reserved),
                                    ),
                                  IsleChartSegment(
                                    label: '剩余额度',
                                    value: remaining,
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    detail: formatBytes(remaining),
                                  ),
                                ],
                              ),
                            ] else if (accounted > 0 || reserved > 0) ...[
                              const SizedBox(height: 7),
                              IsleSegmentedBar(
                                height: 6,
                                legendGap: 5,
                                legendSpacing: 10,
                                legendRunSpacing: 2,
                                segments: [
                                  if (accounted > 0)
                                    IsleChartSegment(
                                      label: '已入账',
                                      value: accounted.toDouble(),
                                      color: quotaColor,
                                      detail: formatBytes(accounted),
                                    ),
                                  if (reserved > 0)
                                    IsleChartSegment(
                                      label: '上传预占',
                                      value: reserved.toDouble(),
                                      color: palette['warning'],
                                      detail: formatBytes(reserved),
                                    ),
                                ],
                              ),
                            ],
                            if (reserved > 0) ...[
                              const SizedBox(height: 3),
                              Text(
                                '上传预占 ${formatBytes(reserved)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
          if (!complete) ...[
            const SizedBox(height: 8),
            Text(
              '仅为已入账用量，部分渠道未统计，不等于硬盘实际占用。',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String taskName(Object? kind, {Object? operation}) {
  if (kind == 'cinema' && operation == 'scrape') return '影视刮削';
  return switch (kind) {
    'gallery' => '图库扫描',
    'cinema' => '影视扫描',
    'backup' => '备份与恢复',
    'trash' => '回收站清理',
    'uploads' => '上传维护',
    _ => '后台任务',
  };
}

String taskStatus(Map<String, dynamic> task) => task['running'] == true
    ? '运行中'
    : (task['lastError']?.toString() ?? '').isNotEmpty
    ? '未完成'
    : '已结束';

class TaskTile extends StatefulWidget {
  const TaskTile({
    super.key,
    required this.api,
    required this.task,
    required this.onChanged,
  });
  final LightIsleApi api;
  final Map<String, dynamic> task;
  final Future<void> Function() onChanged;
  @override
  State<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<TaskTile> {
  bool _busy = false;
  String? _error;
  Future<void> _act() async {
    final task = widget.task;
    final action = task['running'] == true ? 'cancel' : 'retry';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send('POST', '/api/v2/tasks/${task['kind']}/$action');
      await widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final palette = IslePalette.of(context);
    final isRunning = task['running'] == true;
    final hasError = (task['lastError']?.toString() ?? '').isNotEmpty;
    final statusColor = isRunning
        ? palette['brandAmber']
        : hasError
        ? palette['error']
        : palette['brandSage'];

    return IsleSurface(
      padding: EdgeInsets.zero,
      radius: IsleRadius.item,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${taskName(task['kind'], operation: task['operation'])} · ${taskStatus(task)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontSize: 13.5, fontWeight: FontWeight.w700),
                  ),
                ),
                IsleStatusBadge(label: taskStatus(task), color: statusColor),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已处理 ${task['processed'] ?? task['progress'] ?? 0} 项${((task['bytes'] as num?) ?? 0) > 0 ? ' · ${formatBytes(task['bytes'] as num?)}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (task['kind'] == 'gallery' || task['kind'] == 'cinema')
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(40, 28),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                    ),
                    onPressed: _busy ? null : _act,
                    icon: Icon(
                      isRunning ? Icons.close_rounded : Icons.replay_rounded,
                      size: 14,
                    ),
                    label: Text(
                      isRunning ? '取消扫描' : '重新扫描',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            if (isRunning)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 5),
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                  child: LinearProgressIndicator(minHeight: 4),
                ),
              ),
            if (hasError) ...[
              const SizedBox(height: 3),
              Text(
                '原因：${task['lastError']}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            if (_error != null) Notice(_error!, error: true),
          ],
        ),
      ),
    );
  }
}
