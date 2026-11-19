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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final reversed = jobs.reversed.toList(growable: false);

    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_upload_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '上传任务（${reversed.length}）',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: borderColor),
          for (var i = 0; i < reversed.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 46,
                color: borderColor,
              ),
            _taskTile(context, reversed[i]),
          ],
        ],
      ),
    );
  }

  Widget _taskTile(BuildContext context, FileUploadJob job) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
    final tone = switch (job.status) {
      FileUploadStatus.complete => const Color(0xff10b981),
      FileUploadStatus.failed => colors.error,
      FileUploadStatus.paused => const Color(0xfff59e0b),
      _ => colors.primary,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.insert_drive_file_outlined,
                color: tone,
                size: 28,
                iconSize: 15,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$label · ${job.actualDestination}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
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
                  onPressed: () => onPause(job),
                  icon: Icon(
                    job.status == FileUploadStatus.paused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    size: 18,
                  ),
                ),
              if (job.status == FileUploadStatus.uploading ||
                  job.status == FileUploadStatus.paused ||
                  job.status == FileUploadStatus.checking)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '取消上传',
                  onPressed: () => onCancel(job),
                  icon: const Icon(Icons.close_rounded, size: 17),
                ),
              if (job.status == FileUploadStatus.failed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '重试上传',
                      onPressed: retryBusy ? null : () => onRetry(job),
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '取消并清除上传任务',
                      onPressed: () => onDiscard(job),
                      icon: const Icon(Icons.delete_outline_rounded, size: 17),
                    ),
                  ],
                ),
              if (job.status == FileUploadStatus.complete ||
                  job.status == FileUploadStatus.cancelled)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '移除任务',
                  onPressed: () => onClear(job),
                  icon: const Icon(Icons.clear_rounded, size: 17),
                ),
            ],
          ),
          if (job.status == FileUploadStatus.uploading ||
              job.status == FileUploadStatus.paused)
            Padding(
              padding: const EdgeInsets.only(left: 37, top: 5, right: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: size == 0 ? null : progress,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
