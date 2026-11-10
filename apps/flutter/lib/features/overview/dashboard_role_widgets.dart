import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

/// Navigational shortcuts and the primary File Manager entry point on the
/// Dashboard (since File Management is now housed inside the Dashboard
/// launchpad rather than occupying a top-level bottom navigation tab).
class DashboardQuickLinks extends StatelessWidget {
  const DashboardQuickLinks({
    super.key,
    required this.onNavigate,
    required this.admin,
    this.onOpenFiles,
    this.onOpenShares,
    this.onOpenAppsCenter,
    this.onQuickUpload,
  });

  final ValueChanged<int> onNavigate;
  final bool admin;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenShares;
  final VoidCallback? onOpenAppsCenter;
  final VoidCallback? onQuickUpload;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final bigText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final width = constraints.maxWidth;
      final columns = bigText
          ? (width >= 640 ? 2 : 1)
          : width >= 680
          ? 4
          : width >= 300
          ? 2
          : 1;
      final gap = width < IsleLayout.compactPageWidth ? 8.0 : 10.0;
      final cardWidth = (width - (columns - 1) * gap) / columns;
      final compactCard = cardWidth < 210;
      final accentColor = theme.colorScheme.primary;
      final links = <(
        String,
        VoidCallback,
        IconData,
        String,
        String,
        bool,
      )>[
        (
          'dashboardFilesEntry',
          onOpenFiles ?? () => onNavigate(-1),
          Icons.folder_outlined,
          '文件管理',
          '浏览、上传与整理 NAS 目录',
          true,
        ),
        (
          'dashboardPhotosEntry',
          () => onNavigate(1),
          Icons.photo_library_outlined,
          '时光相册',
          '回忆故事流与文件夹相册',
          false,
        ),
        (
          'dashboardCinemaEntry',
          () => onNavigate(2),
          Icons.movie_outlined,
          '私人影院',
          '海报墙、热播走廊与续播',
          false,
        ),
        if (onOpenAppsCenter != null)
          (
            'dashboardAppsEntry',
            onOpenAppsCenter!,
            Icons.apps_rounded,
            '应用中心',
            admin ? '按需轻应用、成员权限与 MCP' : '打开管理员授权的家庭轻应用',
            false,
          ),
        if (onOpenShares != null)
          (
            'dashboardSharesEntry',
            onOpenShares!,
            Icons.ios_share_rounded,
            '我的分享',
            '管理已创建的公开分享链接',
            false,
          )
        else if (onQuickUpload != null)
          (
            'dashboardUploadEntry',
            onQuickUpload!,
            Icons.cloud_upload_outlined,
            '快速上传',
            '直接选择文件或照片入队',
            false,
          ),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IsleSectionHeader(
            title: admin ? '快捷工作台与文件入口' : '个人空间与文件管理',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onOpenAppsCenter != null)
                  ActionChip(
                    key: const ValueKey('dashboardAppsChip'),
                    avatar: const Icon(Icons.apps_rounded, size: 15),
                    label: const Text('应用中心'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onOpenAppsCenter,
                  ),
                if (onQuickUpload != null) ...[
                  if (onOpenAppsCenter != null) const SizedBox(width: 6),
                  TextButton.icon(
                    onPressed: onQuickUpload,
                    icon: const Icon(Icons.upload_file_rounded, size: 16),
                    label: const Text('快速上传'),
                  ),
                ],
              ],
            ),
          ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < links.length; i++)
                Builder(
                  builder: (context) {
                    final item = links[i];
                    return SizedBox(
                      width: cardWidth,
                      child: IsleAnimatedEntrance(
                        delay: Duration(milliseconds: 28 * i),
                        child: IsleSurface(
                          key: ValueKey(item.$1),
                          radius:
                              compactCard ? IsleRadius.item : IsleRadius.card,
                          padding: EdgeInsets.symmetric(
                            horizontal: compactCard ? 10 : 14,
                            vertical: compactCard ? 10 : 13,
                          ),
                          onTap: item.$2,
                          child: Row(
                            children: [
                              IsleSquircleBadge(
                                icon: item.$3,
                                color: accentColor,
                                size: compactCard ? 34 : 40,
                                iconSize: compactCard ? 18 : 20,
                              ),
                              SizedBox(width: compactCard ? 9 : 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            item.$4,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleSmall
                                                ?.copyWith(
                                                  fontSize:
                                                      compactCard ? 13.5 : 14,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: -0.2,
                                                ),
                                          ),
                                        ),
                                        if (item.$6 && !compactCard) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1.5,
                                            ),
                                            decoration: ShapeDecoration(
                                              color: theme
                                                  .colorScheme
                                                  .surfaceContainerHighest
                                                  .withValues(alpha: 0.65),
                                              shape: IsleShapes.squircle(6),
                                            ),
                                            child: Text(
                                              '主入口',
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.$5,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontSize: compactCard ? 11 : 12,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!compactCard)
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
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

/// Per-disk quota data is an application ledger, not measured physical usage.
class MemberStorageSummary extends StatelessWidget {
  const MemberStorageSummary({super.key, required this.storage});

  final Map<String, dynamic> storage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quotas = objectList(storage['rootQuotas']);
    final count = objectList(storage['locations']).length;
    final complete = storage['usageComplete'] == true;
    return IsleSurface(
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.storage_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '我的存储空间',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$count 个目录',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (quotas.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '尚未分配独立硬盘额度，可在设置中查看分类存储位置。',
                style: theme.textTheme.bodySmall,
              ),
            )
          else ...[
            const SizedBox(height: 14),
            IsleResponsiveGrid(
              minItemWidth: 280,
              maxColumns: 2,
              spacing: 14,
              runSpacing: 14,
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
                      return Column(
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
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                '${formatBytes(accounted)} / '
                                '${bound == null ? '不限额' : formatBytes(bound)}',
                                style: theme.textTheme.labelSmall,
                              ),
                            ],
                          ),
                          if (progress != null) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 5,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHighest,
                              ),
                            ),
                          ],
                          if (reserved > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              '上传预占 ${formatBytes(reserved)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      );
                    },
                  ),
              ],
            ),
          ],
          if (!complete) ...[
            const SizedBox(height: 10),
            Text(
              '仅为已入账用量，部分渠道未统计，不等于硬盘实际占用。',
              style: theme.textTheme.bodySmall?.copyWith(
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
    final isRunning = task['running'] == true;
    final hasError = (task['lastError']?.toString() ?? '').isNotEmpty;
    final statusColor = isRunning
        ? const Color(0xff2563eb)
        : hasError
        ? const Color(0xffef4444)
        : const Color(0xff10b981);

    return IsleSurface(
      padding: EdgeInsets.zero,
      radius: IsleRadius.item,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                        ?.copyWith(fontWeight: FontWeight.w700),
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
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (task['kind'] == 'gallery' || task['kind'] == 'cinema')
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(40, 30),
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
                padding: EdgeInsets.symmetric(vertical: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                  child: LinearProgressIndicator(minHeight: 4),
                ),
              ),
            if (hasError) ...[
              const SizedBox(height: 4),
              Text(
                '原因：${task['lastError']}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12.5,
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
