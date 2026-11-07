import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'file_upload_stream.dart';

/// View-only list of current uploads. The page or shared task center owns
/// retries, cancellation and persistence; this component only sends actions.
class FileUploadQueueView extends StatelessWidget {
  const FileUploadQueueView({
    super.key,
    required this.jobs,
    required this.retryBusy,
    required this.onPause,
    required this.onCancel,
    required this.onRetry,
    required this.onDiscard,
    required this.onClear,
  });

  final List<FileUploadJob> jobs;
  final bool retryBusy;
  final ValueChanged<FileUploadJob> onPause;
  final ValueChanged<FileUploadJob> onCancel;
  final ValueChanged<FileUploadJob> onRetry;
  final ValueChanged<FileUploadJob> onDiscard;
  final ValueChanged<FileUploadJob> onClear;

  @override
  Widget build(BuildContext context) => IsleSurface(
    radius: IsleTokens.cardRadius,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '上传任务',
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        for (final job in jobs.reversed) _taskTile(context, job),
      ],
    ),
  );

  Widget _taskTile(BuildContext context, FileUploadJob job) {
    final size = job.file.lengthSync() ?? 0;
    final progress = size > 0
        ? (job.offset / size).clamp(0, 1).toDouble()
        : 0.0;
    final label = switch (job.status) {
      FileUploadStatus.checking =>
        '正在计算 SHA-256 ${size == 0 ? '' : '${(job.hashingBytes / size * 100).clamp(0, 100).round()}%'}',
      FileUploadStatus.uploading =>
        '上传中 ${formatBytes(job.offset)} / ${formatBytes(size)}',
      FileUploadStatus.paused =>
        '已暂停 ${formatBytes(job.offset)} / ${formatBytes(size)}',
      FileUploadStatus.failed => job.error ?? '上传失败',
      FileUploadStatus.complete => '上传完成 · ${formatBytes(size)}',
      FileUploadStatus.cancelled => job.error ?? '已取消',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 20),
              const SizedBox(width: 8),
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
                      '$label · ${job.actualDestination}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
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
                  onPressed: () => onPause(job),
                  icon: Icon(
                    job.status == FileUploadStatus.paused
                        ? Icons.play_arrow
                        : Icons.pause,
                  ),
                ),
              if (job.status == FileUploadStatus.uploading ||
                  job.status == FileUploadStatus.paused ||
                  job.status == FileUploadStatus.checking)
                IconButton(
                  tooltip: '取消上传',
                  onPressed: () => onCancel(job),
                  icon: const Icon(Icons.close),
                ),
              if (job.status == FileUploadStatus.failed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '重试上传',
                      onPressed: retryBusy ? null : () => onRetry(job),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: '取消并清除上传任务',
                      onPressed: () => onDiscard(job),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              if (job.status == FileUploadStatus.complete ||
                  job.status == FileUploadStatus.cancelled)
                IconButton(
                  tooltip: '移除任务',
                  onPressed: () => onClear(job),
                  icon: const Icon(Icons.clear),
                ),
            ],
          ),
          if (job.status == FileUploadStatus.uploading ||
              job.status == FileUploadStatus.paused)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: LinearProgressIndicator(
                value: size == 0 ? null : progress,
              ),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}
