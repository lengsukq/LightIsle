import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../files/duplicate_files_page.dart';
import '../settings/storage_page.dart';
import 'dashboard_role_widgets.dart';
import 'task_history_page.dart';

/// Computes offline/changed personal storage categories for a regular member.
List<String> memberOfflineCategoryLabels({
  required Map<String, dynamic>? personalStorage,
  required List<LightIsleRoot> roots,
}) {
  if (personalStorage == null || roots.isEmpty) return const [];
  const categoryLabels = {
    'files': '普通文件',
    'photos': '照片',
    'videos': '视频',
  };
  final offline = <String>[];
  for (final loc in objectList(personalStorage['locations'])) {
    final rootId = loc['rootID']?.toString() ?? '';
    final generation = loc['rootGeneration'];
    if (rootId.isEmpty) continue;
    LightIsleRoot? matched;
    for (final root in roots) {
      if (root.id == rootId) {
        matched = root;
        break;
      }
    }
    final unavailable =
        matched == null ||
        !matched.online ||
        (generation is num && matched.generation != generation.toInt());
    if (unavailable) {
      final category = loc['category']?.toString() ?? '';
      offline.add(categoryLabels[category] ?? category);
    }
  }
  return offline;
}

/// Top sanctuary focal hero summarizing host health or member space overview.
class OverviewSanctuaryHero extends StatelessWidget {
  const OverviewSanctuaryHero({
    super.key,
    required this.isAdmin,
    required this.hostname,
    required this.stats,
    required this.personalStorage,
    required this.roots,
    required this.tasks,
    required this.error,
  });

  final bool isAdmin;
  final String hostname;
  final Map<String, dynamic>? stats;
  final Map<String, dynamic>? personalStorage;
  final List<LightIsleRoot> roots;
  final List<Map<String, dynamic>> tasks;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final onlineRoots = roots.where((r) => r.online).length;
    final runningTasks = tasks.where((t) => t['running'] == true).length;
    final memberLocations = objectList(personalStorage?['locations']).length;
    final ready = isAdmin ? stats != null : personalStorage != null;

    final statusLabel = error != null
        ? '待检查'
        : ready
        ? '在线运行'
        : '检查中';
    final statusTone = error != null
        ? Theme.of(context).colorScheme.error
        : ready
        ? palette['brandSage']
        : palette['brandAmber'];

    final metrics = isAdmin
        ? <IsleFocalMetric>[
            if (roots.isNotEmpty)
              IsleFocalMetric(
                label: '在线磁盘',
                value: '$onlineRoots / ${roots.length}',
                icon: Icons.dns_rounded,
                color: palette['brandSage'],
              ),
            if (stats != null && stats!['cpuPercent'] is num)
              IsleFocalMetric(
                label: 'CPU 负载',
                value: '${(stats!['cpuPercent'] as num).toStringAsFixed(1)}%',
                icon: Icons.memory_rounded,
                color: palette['brandBlue'],
              ),
            IsleFocalMetric(
              label: '后台任务',
              value: runningTasks > 0 ? '$runningTasks 运行中' : '空闲',
              icon: Icons.auto_mode_rounded,
              color: palette['brandAmber'],
            ),
          ]
        : <IsleFocalMetric>[
            IsleFocalMetric(
              label: '个人目录',
              value: '$memberLocations 个',
              icon: Icons.folder_special_rounded,
              color: palette['brandAmber'],
            ),
            IsleFocalMetric(
              label: '在线磁盘',
              value: '$onlineRoots 块',
              icon: Icons.storage_rounded,
              color: palette['brandSage'],
            ),
          ];

    return IsleFocalStage(
      title: hostname.isNotEmpty
          ? hostname
          : (isAdmin ? '家里的 Mac' : '我的家庭空间'),
      subtitle: error != null ? '设备状态暂时无法确认，请检查连接' : '',
      icon: isAdmin ? Icons.desktop_mac_rounded : Icons.cottage_rounded,
      accent: isAdmin ? palette['brandBlue'] : palette['brandAmber'],
      statusBadge: IsleStatusBadge(label: statusLabel, color: statusTone),
      metrics: metrics,
      margin: EdgeInsets.zero,
    );
  }
}

/// Top attention banner for offline roots, failed admin tasks, or offline
/// personal drives for regular members.
class OverviewAttentionBanner extends StatelessWidget {
  const OverviewAttentionBanner({
    super.key,
    required this.api,
    required this.isAdmin,
    required this.accountId,
    required this.roots,
    required this.tasks,
    required this.personalStorage,
    required this.busyListenable,
    required this.onRefresh,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String? accountId;
  final List<LightIsleRoot> roots;
  final List<Map<String, dynamic>> tasks;
  final Map<String, dynamic>? personalStorage;
  final ValueListenable<bool> busyListenable;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final offlineRoots = isAdmin
        ? roots.where((r) => !r.online).toList()
        : const <LightIsleRoot>[];
    final failedTasks = isAdmin
        ? tasks
              .where((t) => (t['lastError']?.toString() ?? '').isNotEmpty)
              .toList()
        : const <Map<String, dynamic>>[];
    final memberOfflineCategories = isAdmin
        ? const <String>[]
        : memberOfflineCategoryLabels(
            personalStorage: personalStorage,
            roots: roots,
          );
    if (offlineRoots.isEmpty &&
        failedTasks.isEmpty &&
        memberOfflineCategories.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final message = isAdmin
        ? [
            if (offlineRoots.isNotEmpty)
              '${offlineRoots.length} 个存储目录离线（${offlineRoots.map((e) => e.name).join('、')}）',
            if (failedTasks.isNotEmpty) '${failedTasks.length} 项后台任务异常待处理',
          ].join(' · ')
        : '个人存储硬盘当前离线或已变更（${memberOfflineCategories.join('、')}），请检查硬盘连接或联系管理员核对。';
    final hasOfflineAction =
        offlineRoots.isNotEmpty || memberOfflineCategories.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: IsleSurface(
        key: const ValueKey('overviewAttentionBanner'),
        margin: EdgeInsets.zero,
        radius: IsleRadius.md,
        tint: scheme.error,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 520 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.25;
            final compactTextBtn = TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
            final actions = <Widget>[
              if (hasOfflineAction)
                TextButton(
                  style: compactTextBtn,
                  onPressed: () => Navigator.of(context).push<void>(
                    buildIslePageRoute(
                      builder: (_) => StoragePage(
                        api: api,
                        isAdmin: isAdmin,
                        accountId: accountId,
                      ),
                    ),
                  ),
                  child: Text(isAdmin ? '查看存储' : '查看我的空间'),
                ),
              ValueListenableBuilder<bool>(
                valueListenable: busyListenable,
                builder: (_, busy, _) => TextButton(
                  style: compactTextBtn,
                  onPressed: busy ? null : onRefresh,
                  child: const Text('重新检查'),
                ),
              ),
            ];
            final messageWidget = Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: scheme.error,
                        size: 19,
                      ),
                      const SizedBox(width: 9),
                      Expanded(child: messageWidget),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 4, children: actions),
                ],
              );
            }
            return Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.error, size: 19),
                const SizedBox(width: 10),
                Expanded(child: messageWidget),
                ...actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Overview header trailing actions: direct Files Workbench CTA and overflow menu.
class OverviewHeaderTrailing extends StatelessWidget {
  const OverviewHeaderTrailing({
    super.key,
    required this.api,
    required this.isAdmin,
    required this.accountId,
    required this.onRefresh,
    this.onOpenFiles,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String? accountId;
  final VoidCallback onRefresh;
  final VoidCallback? onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onOpenFiles != null)
          FilledButton.icon(
            key: const ValueKey('headerOpenFilesButton'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(38, 36),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: onOpenFiles,
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('文件管理'),
          ),
        const SizedBox(width: 2),
        PopupMenuButton<String>(
          tooltip: '更多工具',
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
          style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
          position: PopupMenuPosition.under,
          shape: IsleShapes.md(
            side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1),
          ),
          onSelected: (value) {
            switch (value) {
              case 'refresh':
                onRefresh();
              case 'storage':
                Navigator.of(context).push<void>(
                  buildIslePageRoute(
                    builder: (_) => StoragePage(
                      api: api,
                      isAdmin: isAdmin,
                      accountId: accountId,
                    ),
                  ),
                );
              case 'duplicates':
                Navigator.of(context).push<void>(
                  buildIslePageRoute(
                    builder: (_) => DuplicateFilesPage(api: api),
                  ),
                );
            }
          },
          itemBuilder: (_) => [
            isleActionMenuItem(
              value: 'refresh',
              icon: Icons.refresh_rounded,
              label: '刷新状态',
            ),
            const PopupMenuDivider(),
            isleActionMenuItem(
              value: 'storage',
              icon: Icons.storage_rounded,
              label: isAdmin ? '存储与成员配额' : '我的存储空间',
            ),
            isleActionMenuItem(
              value: 'duplicates',
              icon: Icons.cleaning_services_outlined,
              label: '重复大文件清理',
            ),
          ],
        ),
      ],
    );
  }
}

/// Admin task queue section displayed on `OverviewPage`.
class OverviewAdminTasksSection extends StatelessWidget {
  const OverviewAdminTasksSection({
    super.key,
    required this.api,
    required this.tasks,
    required this.taskError,
    required this.onRefresh,
  });

  final LightIsleApi api;
  final List<Map<String, dynamic>> tasks;
  final String? taskError;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '任务中心',
          accentColor: palette['brandViolet'],
          action: TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(36, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => Navigator.of(context).push(
              buildIslePageRoute<void>(
                builder: (_) => TaskHistoryPage(api: api),
              ),
            ),
            child: const Text('查看历史', style: TextStyle(fontSize: 12.5)),
          ),
        ),
        if (taskError != null)
          Notice('任务状态更新失败：$taskError', error: true, onRetry: onRefresh),
        if (tasks.isEmpty && taskError == null)
          const Notice('暂无后台任务。可在图库或影视中开始扫描。'),
        if (tasks.isNotEmpty)
          IsleResponsiveGrid(
            minItemWidth: 260,
            maxColumns: 3,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final task in tasks)
                TaskTile(api: api, task: task, onChanged: onRefresh),
            ],
          ),
      ],
    );
  }
}
