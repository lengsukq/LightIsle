import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

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
      return '正在取消并清理服务端临时分片…';
    }
    return switch (job.status) {
      FileUploadStatus.checking => '排队中 · 即将校验原文件',
      FileUploadStatus.uploading => '上传中',
      FileUploadStatus.paused => '已暂停',
      FileUploadStatus.failed => job.error ?? '失败',
      FileUploadStatus.complete => '上传成功',
      FileUploadStatus.cancelled =>
        (job.error != null && job.error!.isNotEmpty)
            ? job.error!
            : '已取消（服务端临时分片已清理）',
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(title: const Text('传输任务')),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: center,
        builder: (context, _) {
          final jobs = center.jobs;
          final colors = Theme.of(context).colorScheme;
          return IsleListView(
            children: [
              const IsleIntroCard(
                icon: Icons.cloud_upload_rounded,
                title: '断点续传与传输队列',
                description:
                    '离开此页面可以继续上传。应用被系统终止后，重启将尝试使用原文件和服务端进度续传；'
                    '文件选择器的临时来源可能失效。锁屏或完全退出应用后的持续上传取决于系统后台限制。',
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '任务列表',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextButton.icon(
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
                        size: 18,
                      ),
                      label: const Text('清除已结束'),
                    ),
                  ],
                ),
              ),
              if (jobs.isEmpty)
                const IsleEmptyStateCard(
                  '暂无传输任务。在文件、图库或影视中选择上传后，将在这里显示进度。',
                  icon: Icons.cloud_done_outlined,
                )
              else
                IsleResponsiveGrid(
                  minItemWidth: 340,
                  maxColumns: 2,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final job in jobs.reversed)
                      IsleSurface(
                        key: ValueKey('transfer:${job.destination}'),
                        margin: EdgeInsets.zero,
                        padding: const EdgeInsets.all(14),
                        radius: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                IsleSquircleBadge(
                                  icon: switch (job.status) {
                                    FileUploadStatus.complete =>
                                      Icons.check_circle_outline_rounded,
                                    FileUploadStatus.failed =>
                                      Icons.error_outline_rounded,
                                    FileUploadStatus.paused =>
                                      Icons.pause_circle_outline_rounded,
                                    _ => Icons.upload_file_outlined,
                                  },
                                  color: switch (job.status) {
                                    FileUploadStatus.complete => const Color(
                                      0xff10b981,
                                    ),
                                    FileUploadStatus.failed => colors.error,
                                    FileUploadStatus.paused => const Color(
                                      0xfff59e0b,
                                    ),
                                    _ => colors.primary,
                                  },
                                  size: 36,
                                  iconSize: 19,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        job.file.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      Text(
                                        job.actualDestination,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (job.status == FileUploadStatus.uploading ||
                                    job.status == FileUploadStatus.paused)
                                  IconButton(
                                    tooltip:
                                        job.status == FileUploadStatus.paused
                                        ? '继续上传'
                                        : '暂停上传',
                                    onPressed: center.isAborting(job)
                                        ? null
                                        : () => center.togglePause(job),
                                    icon: Icon(
                                      job.status == FileUploadStatus.paused
                                          ? Icons.play_arrow_rounded
                                          : Icons.pause_rounded,
                                    ),
                                  ),
                                if (center.canRetry(job))
                                  IconButton(
                                    tooltip: '重新尝试',
                                    onPressed: center.isAborting(job)
                                        ? null
                                        : () => center.retry(job),
                                    icon: const Icon(Icons.refresh_rounded),
                                  ),
                                if (job.status != FileUploadStatus.complete &&
                                    job.status != FileUploadStatus.cancelled)
                                  IconButton(
                                    tooltip: '取消任务',
                                    onPressed: center.isAborting(job)
                                        ? null
                                        : () => _confirmAndCancel(context, job),
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _statusDescription(job),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (center.canRetry(job)) ...[
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: () => _chooseSource(context, job),
                                icon: const Icon(Icons.folder_open_outlined),
                                label: const Text('重新选择源文件'),
                              ),
                            ],
                            if (job.status == FileUploadStatus.uploading ||
                                job.status == FileUploadStatus.paused ||
                                job.status == FileUploadStatus.checking) ...[
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value: (job.file.lengthSync() ?? 0) == 0
                                    ? null
                                    : (job.offset / job.file.lengthSync()!)
                                          .clamp(0.0, 1.0),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                '${formatBytes(job.offset)} / '
                                '${formatBytes(job.file.lengthSync())}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    ),
  );
}
