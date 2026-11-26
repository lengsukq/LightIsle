import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'downloads_dialogs.dart';

int _downloadNonNegInt(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toInt() : 0;

String downloadStatusLabel(String value) =>
    const {
      'queued': '排队中',
      'running': '下载中',
      'paused': '已暂停',
      'completed': '已完成',
      'failed': '未完成',
      'cancelled': '已取消',
    }[value] ??
    '状态未知';

/// Renders one remote download task row with progress bar, conflict banners,
/// and pause/resume/retry/delete controls.
class DownloadTaskRow extends StatelessWidget {
  const DownloadTaskRow({
    super.key,
    required this.task,
    required this.canAct,
    required this.available,
    required this.networkAllowed,
    required this.onAction,
  });

  final Map<String, dynamic> task;
  final bool canAct;
  final bool available;
  final bool networkAllowed;
  final void Function(Map<String, dynamic> task, String action) onAction;

  @override
  Widget build(BuildContext context) {
    final status = task['status'] as String;
    final engine = task['engine']?.toString() ?? '';
    final engineLabel = switch (engine) {
      'ytdlp' => 'yt-dlp',
      'webarchive' => '网页归档',
      'aria2' => 'aria2',
      _ => '',
    };
    final supportsPause = engine.isEmpty || engine == 'aria2';
    final total = _downloadNonNegInt(task['totalBytes']);
    final done = _downloadNonNegInt(task['completedBytes']);
    final published = objectList(task['publishedFiles']);
    final publishedCount = _downloadNonNegInt(task['publishedFilesTotal']) > 0
        ? _downloadNonNegInt(task['publishedFilesTotal'])
        : published.length;
    final active = const ['queued', 'running', 'paused'].contains(status);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);

    final statusColor = switch (status) {
      'completed' => palette['brandSage'],
      'running' => colors.primary,
      'paused' => palette['brandAmber'],
      'failed' => colors.error,
      _ => colors.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: status == 'completed'
                    ? Icons.download_done_rounded
                    : Icons.downloading_rounded,
                color: statusColor,
                size: 32,
                iconSize: 16.5,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task['filename']?.toString().isNotEmpty == true
                          ? task['filename'].toString()
                          : task['url']?.toString() ?? '下载任务',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${engineLabel.isNotEmpty ? '$engineLabel · ' : ''}${status == 'running' && task['phase'] == 'publishing' ? '正在保存' : downloadStatusLabel(status)} · 保存到 ${task['destination'] == '.' ? '共享根目录' : task['destination']}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IsleBadgePill(
                label: status == 'running' && task['phase'] == 'publishing'
                    ? '正在保存'
                    : downloadStatusLabel(status),
                color: statusColor,
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 42),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: (done / total).clamp(0.0, 1.0),
                      minHeight: 5,
                      semanticsLabel: '下载进度',
                      backgroundColor: colors.outlineVariant.withValues(
                        alpha: 0.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatBytes(done)} / ${formatBytes(total)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (task['partialPublish'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 42),
              child: Text(
                '部分文件已保存，任务尚未全部完成。重试会核对已有文件。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (task['recoveryRequired'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 42),
              child: Text(
                '已有文件与任务记录不一致，请先在 Mac 核对文件；不会自动覆盖。',
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
          if (task['error']?.toString().isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 42),
              child: Text(
                userFacingError(task['error'].toString()),
                style: TextStyle(color: colors.error, fontSize: 12.5),
              ),
            ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Row(
              children: [
                if (supportsPause &&
                    task['phase'] != 'publishing' &&
                    (status == 'queued' || status == 'running'))
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: canAct && available
                        ? () => onAction(task, 'pause')
                        : null,
                    child: const Text('暂停', style: TextStyle(fontSize: 12.5)),
                  ),
                if (status == 'paused')
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: canAct && available && networkAllowed
                        ? () => onAction(task, 'resume')
                        : null,
                    child: const Text('继续', style: TextStyle(fontSize: 12.5)),
                  ),
                if (status == 'failed' || status == 'cancelled')
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed:
                        canAct &&
                            ((available && networkAllowed) ||
                                task['phase'] == 'publishing')
                        ? () => onAction(task, 'retry')
                        : null,
                    child: const Text('重试', style: TextStyle(fontSize: 12.5)),
                  ),
                if (!active)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: canAct ? () => onAction(task, 'delete') : null,
                    child: const Text('删除记录', style: TextStyle(fontSize: 12.5)),
                  ),
                if (published.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => showPublishedDownloadFilesDialog(
                      context,
                      task: task,
                      published: published,
                      totalCount: publishedCount,
                    ),
                    icon: const Icon(Icons.help_outline_rounded, size: 14.5),
                    label: Text(
                      '文件处理记录（$publishedCount 项）',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                const Spacer(),
                if (active)
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    enabled: canAct,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    style: IconButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    shape: IsleShapes.md(
                      side: BorderSide(
                        color: IsleGlass.rimBorderColor(isDark),
                        width: 1.0,
                      ),
                    ),
                    onSelected: (act) => onAction(task, act),
                    itemBuilder: (_) => [
                      isleActionMenuItem(
                        value: 'cancel',
                        icon: Icons.cancel_outlined,
                        label: '取消下载',
                      ),
                      isleActionMenuItem(
                        value: 'delete',
                        icon: Icons.delete_outline_rounded,
                        label: '删除记录',
                        destructive: true,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
