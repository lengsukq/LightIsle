import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'file_upload_stream.dart';
import 'upload_task_center.dart';

/// One shared task list for files, photos and cinema. Does not own or cancel
/// the jobs on pop, so leaving this page is always safe.
class UploadTaskCenterPage extends StatelessWidget {
  const UploadTaskCenterPage({super.key, required this.center});
  final UploadTaskCenter center;

  Future<void> _chooseSource(BuildContext context, FileUploadJob job) async {
    try {
      final selected = await FilePicker.pickFiles(
        type: FileType.any,
        dialogTitle: '重新选择原文件：${job.file.name}',
        darwinOptions: const DarwinOptions(
          assetRepresentationMode: DarwinAssetRepresentationMode.current,
        ),
      );
      if (!context.mounted || selected.isEmpty) return;
      final accepted = await center.reselect(job, selected.first);
      if (!accepted && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(job.error ?? '选择的文件与原上传任务不符。')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法读取所选文件，请确认系统存储权限后重试。')));
      }
    }
  }

  Future<void> _confirmAndCancel(
    BuildContext context,
    FileUploadJob job,
  ) async {
    final hasProgress =
        job.status == FileUploadStatus.uploading ||
        (job.status == FileUploadStatus.paused && job.offset > 0) ||
        job.uploadId != null;
    if (hasProgress) {
      final approved = await confirmAction(
        context,
        '取消上传任务',
        '确认取消「${job.file.name}」？取消后将清理服务端已接收的临时分片，下次需重新上传。若仅需稍后继续，请使用「暂停上传」。',
        action: '确认取消',
        isDestructive: true,
      );
      if (!approved || !context.mounted) return;
    }
    center.cancel(job);
  }

  String _statusDescription(FileUploadJob job) {
    if (center.isAborting(job)) {
      return '正在取消…';
    }
    return switch (job.status) {
      FileUploadStatus.checking => '校验中',
      FileUploadStatus.uploading => '上传中',
      FileUploadStatus.paused => '已暂停',
      FileUploadStatus.failed => job.error ?? '失败',
      FileUploadStatus.complete => '已完成',
      FileUploadStatus.cancelled =>
        (job.error != null && job.error!.isNotEmpty) ? job.error! : '已取消',
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const IsleAppBar(title: Text('传输任务')),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: center,
        builder: (context, _) {
          final jobs = center.jobs.reversed.toList(growable: false);
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final isDark = theme.brightness == Brightness.dark;
          final palette = IslePalette(isDark);
          final borderColor = IsleGlass.rimBorderColor(isDark);
          final accent = palette['brandAmber'];
          final activeCount = jobs
              .where(
                (j) =>
                    j.status == FileUploadStatus.uploading ||
                    j.status == FileUploadStatus.checking,
              )
              .length;
          final completeCount = jobs
              .where((j) => j.status == FileUploadStatus.complete)
              .length;
          final issueCount = jobs
              .where(
                (j) =>
                    j.status == FileUploadStatus.failed ||
                    j.status == FileUploadStatus.paused,
              )
              .length;

          return IsleListView(
            maxWidth: IsleLayout.workbenchMaxWidth,
            children: [
              IsleFocalStage(
                icon: Icons.cloud_upload_rounded,
                accent: accent,
                title: '传输队列',
                metrics: [
                  IsleFocalMetric(
                    label: '上传中',
                    value: '$activeCount',
                    accent: colors.primary,
                  ),
                  IsleFocalMetric(
                    label: '已完成',
                    value: '$completeCount',
                    accent: palette['brandSage'],
                  ),
                  IsleFocalMetric(
                    label: '暂停/异常',
                    value: '$issueCount',
                    accent: issueCount > 0 ? colors.error : accent,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              IsleSectionHeader(
                title: '任务列表（${jobs.length}）',
                accentColor: accent,
                action: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed:
                      jobs.any(
                        (job) =>
                            job.status == FileUploadStatus.complete ||
                            job.status == FileUploadStatus.cancelled,
                      )
                      ? center.clearFinished
                      : null,
                  icon: const Icon(
                    Icons.cleaning_services_outlined,
                    size: 15.5,
                  ),
                  label: const Text('清除已结束', style: TextStyle(fontSize: 12)),
                ),
              ),
              if (jobs.isEmpty)
                const IsleEmptyStateCard(
                  '暂无传输任务',
                  icon: Icons.cloud_done_outlined,
                )
              else
                IsleAdaptiveBuilder(
                  builder: (context, tier, width) {
                    final textScale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    if (tier == IsleViewportTier.expanded &&
                        jobs.length > 1 &&
                        textScale <= 1.35) {
                      final cardWidth = (width - 12) / 2;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final job in jobs)
                            SizedBox(
                              width: cardWidth,
                              child: IsleSurface(
                                margin: EdgeInsets.zero,
                                padding: EdgeInsets.zero,
                                child: _buildTransferRow(
                                  context,
                                  job,
                                  theme,
                                  colors,
                                  palette,
                                ),
                              ),
                            ),
                        ],
                      );
                    }
                    return IsleSurface(
                      margin: EdgeInsets.zero,
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < jobs.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                thickness: 1,
                                indent: 52,
                                color: borderColor,
                              ),
                            _buildTransferRow(
                              context,
                              jobs[i],
                              theme,
                              colors,
                              palette,
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    ),
  );

  Widget _buildTransferRow(
    BuildContext context,
    FileUploadJob job,
    ThemeData theme,
    ColorScheme colors,
    IslePalette palette,
  ) {
    final tone = switch (job.status) {
      FileUploadStatus.complete => palette['brandSage'],
      FileUploadStatus.failed => colors.error,
      FileUploadStatus.paused => palette['brandAmber'],
      _ => colors.primary,
    };
    final canCancel =
        job.status != FileUploadStatus.complete &&
        job.status != FileUploadStatus.cancelled;
    final canReselect = center.canRetry(job);

    return Padding(
      key: ValueKey('transfer:${job.destination}'),
      padding: const EdgeInsets.fromLTRB(12, 11, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: switch (job.status) {
                  FileUploadStatus.complete =>
                    Icons.check_circle_outline_rounded,
                  FileUploadStatus.failed => Icons.error_outline_rounded,
                  FileUploadStatus.paused => Icons.pause_circle_outline_rounded,
                  _ => Icons.upload_file_outlined,
                },
                color: tone,
                size: 32,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${_statusDescription(job)} · ${job.actualDestination}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (job.status == FileUploadStatus.uploading ||
                  job.status == FileUploadStatus.paused)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: job.status == FileUploadStatus.paused
                      ? '继续上传'
                      : '暂停上传',
                  onPressed: center.isAborting(job)
                      ? null
                      : () => center.togglePause(job),
                  icon: Icon(
                    job.status == FileUploadStatus.paused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    size: 19,
                  ),
                )
              else if (canReselect)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '重新尝试',
                  onPressed: center.isAborting(job)
                      ? null
                      : () => center.retry(job),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
              if (canReselect || canCancel)
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  enabled: !center.isAborting(job),
                  icon: const Icon(Icons.more_horiz_rounded, size: 18),
                  onSelected: (action) {
                    switch (action) {
                      case 'reselect':
                        _chooseSource(context, job);
                      case 'cancel':
                        _confirmAndCancel(context, job);
                    }
                  },
                  itemBuilder: (_) => [
                    if (canReselect)
                      const PopupMenuItem(
                        value: 'reselect',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.folder_open_outlined, size: 18),
                          title: Text('重新选择源文件'),
                        ),
                      ),
                    if (canCancel)
                      const PopupMenuItem(
                        value: 'cancel',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.close_rounded, size: 18),
                          title: Text('取消任务'),
                        ),
                      ),
                  ],
                ),
            ],
          ),
          if (job.status == FileUploadStatus.uploading ||
              job.status == FileUploadStatus.paused ||
              job.status == FileUploadStatus.checking)
            Padding(
              padding: const EdgeInsets.only(left: 42, top: 6, right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 4.5,
                      value: (job.file.lengthSync() ?? 0) == 0
                          ? null
                          : (job.offset / job.file.lengthSync()!).clamp(
                              0.0,
                              1.0,
                            ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${formatBytes(job.offset)} / ${formatBytes(job.file.lengthSync())}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11.5,
                      color: colors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
