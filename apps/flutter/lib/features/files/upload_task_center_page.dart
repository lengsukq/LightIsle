import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('传输任务')),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: center,
        builder: (context, _) {
          final jobs = center.jobs;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Notice(
                '离开此页面可以继续上传。应用被系统终止后，重启将尝试使用原文件和服务端进度续传；'
                '文件选择器的临时来源可能失效。锁屏或完全退出应用后的持续上传取决于系统后台限制。',
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('任务列表', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton.icon(
                    onPressed:
                        jobs.any(
                          (job) =>
                              job.status == FileUploadStatus.complete ||
                              job.status == FileUploadStatus.cancelled,
                        )
                        ? center.clearFinished
                        : null,
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Text('清除已结束'),
                  ),
                ],
              ),
              if (jobs.isEmpty)
                const Notice('暂无传输任务。在文件、图库或影视中选择上传后，将在这里显示进度。')
              else
                IsleResponsiveGrid(
                  minItemWidth: 340,
                  maxColumns: 2,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final job in jobs.reversed)
                      Card(
                        key: ValueKey('transfer:${job.destination}'),
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.upload_file_outlined, size: 24),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          job.file.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          job.actualDestination,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (job.status == FileUploadStatus.uploading ||
                                      job.status == FileUploadStatus.paused)
                                    IconButton(
                                      tooltip: job.status == FileUploadStatus.paused
                                          ? '继续上传'
                                          : '暂停上传',
                                      onPressed: () => center.togglePause(job),
                                      icon: Icon(
                                        job.status == FileUploadStatus.paused
                                            ? Icons.play_arrow_rounded
                                            : Icons.pause_rounded,
                                      ),
                                    ),
                                  if (center.canRetry(job))
                                    IconButton(
                                      tooltip: '重新尝试',
                                      onPressed: () => center.retry(job),
                                      icon: const Icon(Icons.refresh_rounded),
                                    ),
                                  if (job.status != FileUploadStatus.complete &&
                                      job.status != FileUploadStatus.cancelled)
                                    IconButton(
                                      tooltip: '取消任务',
                                      onPressed: () => center.cancel(job),
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(switch (job.status) {
                                FileUploadStatus.checking => '排队中 · 即将校验原文件',
                                FileUploadStatus.uploading => '上传中',
                                FileUploadStatus.paused => '已暂停',
                                FileUploadStatus.failed => job.error ?? '失败',
                                FileUploadStatus.complete => '上传成功',
                                FileUploadStatus.cancelled => '已取消',
                              }, style: Theme.of(context).textTheme.bodySmall),
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
                                      : (job.offset / job.file.lengthSync()!).clamp(
                                          0.0,
                                          1.0,
                                        ),
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
