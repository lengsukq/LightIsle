import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'file_upload_queue_view.dart';
import 'files_controller.dart';
import 'files_ui_actions.dart';

class FilesReadOnlyBanner extends StatelessWidget {
  const FilesReadOnlyBanner({super.key, required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: ShapeDecoration(
          shape: IsleShapes.sm(
            side: BorderSide(color: IsleGlass.rimBorderColor(isDark)),
          ),
          color: palette['cardItemBottom'],
        ),
        child: Row(
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 15,
              color: palette['brandAmber'],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                compact
                    ? '当前目录为只读 · 可浏览、下载或复制。'
                    : '当前目录为只读。你可以浏览、预览、下载或复制到有写权限的目录。',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FilesBatchProgressBanner extends StatelessWidget {
  const FilesBatchProgressBanner({super.key, required this.controller});

  final FilesController controller;

  @override
  Widget build(BuildContext context) {
    final transfers = controller.transfers;
    final progress = transfers.batchProgress!;
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(
            alpha: isDark ? 0.45 : 0.72,
          ),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: colors.primary.withValues(alpha: isDark ? 0.35 : 0.22),
            width: 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '正在批量${transfers.batchActionLabel ?? '处理'} (${progress.index}/${progress.total}) · ${progress.currentName}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 26),
                  ),
                  onPressed: transfers.batchStopRequested
                      ? null
                      : controller.batch.requestBatchStop,
                  child: Text(
                    transfers.batchStopRequested ? '正在停止…' : '停止后续项',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: progress.total > 0
                    ? (progress.index / progress.total).clamp(0.0, 1.0)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FilesUploadQueueSection extends StatelessWidget {
  const FilesUploadQueueSection({
    super.key,
    required this.controller,
    required this.actions,
  });

  final FilesController controller;
  final FilesUiActions actions;

  @override
  Widget build(BuildContext context) {
    return FileUploadQueueView(
      jobs: controller.uploadJobs,
      retryBusy: controller.transfers.uploadBusy,
      onPause: controller.transfer.togglePause,
      onCancel: (job) =>
          unawaited(actions.confirmAndCancelUpload(context, job)),
      onRetry: (job) => unawaited(controller.transfer.retryUpload(job)),
      onDiscard: (job) => unawaited(
        actions.confirmAndCancelUpload(context, job, discard: true),
      ),
      onClear: controller.transfer.clearUploadJob,
    );
  }
}

class FilesUploadOnlyView extends StatelessWidget {
  const FilesUploadOnlyView({
    super.key,
    required this.controller,
    required this.actions,
  });

  final FilesController controller;
  final FilesUiActions actions;

  @override
  Widget build(BuildContext context) {
    final dir = controller.dir;
    final transfers = controller.transfers;
    final hasTaskCenter = controller.taskCenter != null;
    final jobs = controller.uploadJobs;

    return PopScope(
      canPop: hasTaskCenter || !controller.hasActiveLocalUploads,
      onPopInvokedWithResult: (didPop, result) =>
          unawaited(actions.handleUploadViewPop(context, didPop)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          IsleSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('保存位置', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                Text(
                  '${controller.api.selectedRoot?.name ?? dir.rootName} / ${dir.path == '.' ? '共享目录' : dir.path}',
                ),
                const SizedBox(height: 12),
                Text(
                  hasTaskCenter
                      ? '支持多选。离开此页面上传仍会继续，可在传输任务中心管理。'
                      : '支持多选。保持此页面打开，可暂停、继续或重试。',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: dir.loading || transfers.uploadBusy || !dir.canWrite
                      ? null
                      : () => unawaited(
                          controller.transfer.pickUploads(
                            type: controller.initialUploadType,
                          ),
                        ),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(jobs.isEmpty ? '选择要上传的内容' : '继续添加'),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同名自动改名'),
                  subtitle: const Text('保留原文件和新文件'),
                  value: controller.prefs.uploadAutoRename,
                  onChanged: transfers.uploadBusy
                      ? null
                      : controller.setUploadAutoRename,
                ),
              ],
            ),
          ),
          if (dir.loading) const LinearProgressIndicator(),
          if (dir.error != null)
            Notice(
              dir.error!,
              error: true,
              onRetry: () => unawaited(controller.loadFiles()),
            ),
          if (!dir.loading && !dir.canWrite && dir.error == null)
            const Notice('此位置没有上传权限，请联系管理员开放写入权限。'),
          if (hasTaskCenter)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.sync_alt_rounded),
                label: const Text('查看传输任务'),
                onPressed: () => actions.openUploadTaskCenter(context),
              ),
            ),
          if (jobs.isNotEmpty) ...[
            const SizedBox(height: 16),
            FilesUploadQueueSection(controller: controller, actions: actions),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
