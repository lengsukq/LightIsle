import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'desktop_backup_engine.dart';
import 'desktop_backup_models.dart';
import 'desktop_folder_backup_task_sheet.dart';

class DesktopFolderBackupPage extends StatefulWidget {
  const DesktopFolderBackupPage({
    super.key,
    required this.api,
    required this.userId,
    required this.accountName,
    required this.isAdmin,
    this.controller,
    this.directoryAccess,
  });

  final LightIsleApi api;
  final int userId;
  final String accountName;
  final bool isAdmin;
  final DesktopBackupController? controller;
  final DesktopDirectoryAccess? directoryAccess;

  @override
  State<DesktopFolderBackupPage> createState() =>
      _DesktopFolderBackupPageState();
}

class _DesktopFolderBackupPageState extends State<DesktopFolderBackupPage> {
  late final DesktopBackupController _controller;
  late final bool _ownsController;
  final Map<String, (List<DesktopBackupFailure>, int)> _failuresByTask =
      <String, (List<DesktopBackupFailure>, int)>{};

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
      _ownsController = false;
      unawaited(_controller.reloadFromStore().then((_) => _refreshFailures()));
    } else {
      _controller = DesktopBackupController(
        api: widget.api,
        userId: widget.userId,
        accountName: widget.accountName,
        directoryAccess: widget.directoryAccess,
      );
      _ownsController = true;
      unawaited(_controller.initialize().then((_) => _refreshFailures()));
    }
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_controller.running) {
      unawaited(_refreshFailures());
    }
  }

  Future<void> _refreshFailures() async {
    final next = <String, (List<DesktopBackupFailure>, int)>{};
    for (final task in _controller.tasks) {
      next[task.id] = await _controller.store.loadFailures(task.id);
    }
    if (mounted) {
      setState(() {
        _failuresByTask
          ..clear()
          ..addAll(next);
      });
    }
  }

  Future<void> _addOrEditTask([DesktopBackupTask? existing]) async {
    final saved = await showDesktopBackupTaskDialog(
      context,
      api: widget.api,
      isAdmin: widget.isAdmin,
      directoryAccess: _controller.directoryAccess,
      existing: existing,
    );
    if (saved == null || !mounted) return;
    await _controller.upsertTask(saved);
    await _refreshFailures();
  }

  Future<void> _confirmDeleteTask(DesktopBackupTask task) async {
    final confirmed = await confirmAction(
      context,
      '移除备份任务',
      '确定移除「${task.label}」吗？\n'
          '这只会清除本机客户端的同步配置与快检缓存，不会删除本机源文件夹或 NAS 上的任何已备份文件。',
      action: '移除任务',
    );
    if (!confirmed || !mounted) return;
    try {
      await _controller.deleteTask(task.id);
      await _refreshFailures();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(userFacingError(error))));
      }
    }
  }

  String _formatTimestamp(int ms) {
    if (ms <= 0) return '尚未完成过完整同步';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Widget _buildOverviewCard(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tasks = _controller.tasks;
    final running = _controller.running;
    final progress = _controller.activeProgress;

    return IsleSurface(
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IsleSquircleBadge(
                    icon: Icons.drive_folder_upload_rounded,
                    color: colors.primary,
                    size: 40,
                    iconSize: 20,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本机文件夹单向增量备份',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tasks.isEmpty
                              ? '尚未添加文件夹 · 支持断网续传与 SHA-256 落盘核验'
                              : '已配置 ${tasks.length} 个文件夹任务 · 只读扫描本地源文件',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('addDesktopBackupTaskButton'),
                    onPressed: running ? null : () => _addOrEditTask(),
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: const Text('添加文件夹'),
                  ),
                  if (running)
                    FilledButton.icon(
                      key: const ValueKey('pauseDesktopBackupButton'),
                      onPressed: _controller.requestCancel,
                      icon: const Icon(Icons.pause_circle_outline, size: 18),
                      label: const Text('暂停同步'),
                    )
                  else if (tasks.isNotEmpty)
                    FilledButton.icon(
                      key: const ValueKey('runAllDesktopBackupButton'),
                      onPressed: tasks.any((t) => t.enabled)
                          ? () => unawaited(_controller.runAllEnabled())
                          : null,
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: const Text('全部立即备份'),
                    ),
                ],
              ),
            ],
          ),
          if (running && progress != null) ...[
            const SizedBox(height: 14),
            if (progress.totalFiles > 0) ...[
              Row(
                children: [
                  IsleDonutGauge(
                    fraction: (progress.completedFiles / progress.totalFiles)
                        .clamp(0.0, 1.0),
                    color: colors.primary,
                    size: 38,
                    strokeWidth: 4,
                    centerText:
                        '${((progress.completedFiles / progress.totalFiles).clamp(0.0, 1.0) * 100).round()}%',
                    centerStyle: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    semanticsLabel:
                        '桌面备份进度 ${progress.completedFiles}/${progress.totalFiles}',
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: IsleSegmentedBar(
                      height: 8,
                      showPercentInLegend: true,
                      legendGap: 5,
                      legendSpacing: 10,
                      legendRunSpacing: 2,
                      segments: [
                        IsleChartSegment(
                          label: '已同步',
                          value: progress.completedFiles.toDouble(),
                          color: colors.primary,
                          detail: '${progress.completedFiles} 项',
                        ),
                        IsleChartSegment(
                          label: '待处理',
                          value: (progress.totalFiles - progress.completedFiles)
                              .clamp(0, progress.totalFiles)
                              .toDouble(),
                          color: colors.surfaceContainerHighest,
                          detail:
                              '${(progress.totalFiles - progress.completedFiles).clamp(0, progress.totalFiles)} 项',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ] else
              const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(
              progress.currentFile.isEmpty
                  ? progress.phase
                  : '${progress.phase} · ${progress.currentFile}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 14),
          DropdownButtonFormField<DesktopBackupSchedule>(
            key: const ValueKey('desktopBackupScheduleDropdown'),
            initialValue: _controller.schedule,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '自动检查频率（仅客户端打开期间运行，无后台驻留进程）',
            ),
            items: [
              for (final option in DesktopBackupSchedule.values)
                DropdownMenuItem<DesktopBackupSchedule>(
                  value: option,
                  child: Text(option.label),
                ),
            ],
            onChanged: (next) {
              if (next != null) {
                unawaited(
                  _controller.setSchedule(next, armTimer: !_ownsController),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return IsleSurface(
      radius: IsleRadius.card,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          Icon(
            Icons.folder_copy_outlined,
            size: 42,
            color: colors.primary.withValues(alpha: 0.8),
          ),
          const SizedBox(height: 12),
          Text(
            '将常用桌面文件夹安全增量备份到 NAS',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '单向增量备份只读取本机源文件，绝不修改或删除本机目录，也不会自动删除 NAS 上的历史文件。\n'
            '在 macOS 上会自动保存只读安全书签，重启客户端后无需重复授权。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _addOrEditTask(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加第一个备份文件夹'),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(BuildContext context, DesktopBackupTask task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final running = _controller.running;
    final isCurrent = _controller.activeProgress?.taskId == task.id;
    final (failures, omittedFailures) =
        _failuresByTask[task.id] ?? (const <DesktopBackupFailure>[], 0);
    final totalFailures = failures.length + omittedFailures;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: IsleSurface(
        key: ValueKey('desktopBackupTaskCard:${task.id}'),
        radius: IsleRadius.card,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        task.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      IsleStatusBadge(
                        label: task.conflictPolicy.shortLabel,
                        color: colors.primary,
                      ),
                      if (isCurrent)
                        const IsleStatusBadge(
                          label: '同步中',
                          color: Color(0xFF0EA5E9),
                        )
                      else if (totalFailures > 0 || task.lastError != null)
                        IsleStatusBadge(
                          label: totalFailures > 0
                              ? '待处理 $totalFailures'
                              : '需检查',
                          color: const Color(0xFFF59E0B),
                        )
                      else if (task.lastCompleteAtMs > 0)
                        const IsleStatusBadge(
                          label: '已核验',
                          color: Color(0xFF10B981),
                        ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: task.enabled,
                  onChanged: running
                      ? null
                      : (v) => unawaited(
                          _controller.upsertTask(task.copyWith(enabled: v)),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              '本机：${task.localPath}\n'
              'NAS：${task.rootName} (代数 ${task.rootGeneration}) → /${task.remoteBasePath == '.' ? '' : task.remoteBasePath}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '最近完整核验：${_formatTimestamp(task.lastCompleteAtMs)}'
              '${task.lastSummary != null ? ' · ${task.lastSummary}' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            if (task.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                task.lastError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (failures.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: Text(
                  '失败文件明细（共 $totalFailures 项）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                children: [
                  for (final f in failures.take(12))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '• ${f.relativePath}：${f.reason}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  if (failures.length > 12 || omittedFailures > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '其余 ${failures.length - (failures.length > 12 ? 12 : failures.length) + omittedFailures} 项已省略显示',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: ValueKey('runDesktopBackupTask:${task.id}'),
                  onPressed: running
                      ? null
                      : () => unawaited(
                          _controller
                              .runTask(task.id)
                              .then((_) => _refreshFailures()),
                        ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('立即备份'),
                ),
                if (totalFailures > 0)
                  OutlinedButton.icon(
                    key: ValueKey('retryDesktopBackupFailures:${task.id}'),
                    onPressed: running
                        ? null
                        : () => unawaited(
                            _controller
                                .runTask(task.id, retryFailuresOnly: true)
                                .then((_) => _refreshFailures()),
                          ),
                    icon: const Icon(Icons.replay_rounded, size: 17),
                    label: const Text('仅重试失败项'),
                  ),
                OutlinedButton.icon(
                  onPressed: running ? null : () => _addOrEditTask(task),
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('编辑'),
                ),
                TextButton.icon(
                  onPressed: running ? null : () => _confirmDeleteTask(task),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: colors.error,
                  ),
                  label: Text('移除', style: TextStyle(color: colors.error)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const IsleAppBar(title: Text('本机文件夹备份')),
      body: SafeArea(
        child: IsleListView(
          maxWidth: IsleLayout.settingsWidth,
          children: [
            _buildOverviewCard(context),
            if (_controller.tasks.isEmpty) ...[
              const SizedBox(height: 12),
              _buildEmptyState(context),
            ] else
              for (final task in _controller.tasks)
                _buildTaskCard(context, task),
            const SizedBox(height: 14),
            const IsleHelpDisclosure(
              summary: '单向增量与数据安全说明',
              details:
                  '1. 仅单向新增或更新：本机删除文件不会删除 NAS 上的备份文件。\n'
                  '2. 两阶段防丢更新：选择「旧版进回收站并更新」时，新文件先完整上传并通过 NAS 端 SHA-256 校验，再将旧版移入 NAS 回收站并原子归位；中途断网绝不损坏旧版。\n'
                  '3. 物理硬盘防串盘：若目标硬盘离线、移除或代际变更，同步会立即失败闭合，绝不自动写入其他硬盘。',
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
