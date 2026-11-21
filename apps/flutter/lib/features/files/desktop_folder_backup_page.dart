import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingError(error))));
      }
    }
  }

  Future<void> _showTaskFailuresDialog(
    BuildContext context,
    String label,
    List<DesktopBackupFailure> failures,
    int omittedFailures,
  ) {
    final total = failures.length + omittedFailures;
    return showIsleHelpDialog(
      context,
      title: '$label · 失败明细（$total 项）',
      icon: Icons.error_outline_rounded,
      accentColor: Theme.of(context).colorScheme.error,
      items: [
        for (final f in failures.take(20))
          IsleHelpItem(title: f.relativePath, body: f.reason),
        if (failures.length > 20 || omittedFailures > 0)
          IsleHelpItem(
            title: '其余记录已省略',
            body:
                '另有 ${failures.length - (failures.length > 20 ? 20 : failures.length) + omittedFailures} 项待重试记录保存在本机数据库。',
          ),
      ],
    );
  }

  Widget _buildOverviewCard(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final accent = palette['brandAmber'];
    final sage = palette['brandSage'];
    final tasks = _controller.tasks;
    final running = _controller.running;
    final progress = _controller.activeProgress;
    final verifiedCount = tasks.where((t) => t.lastCompleteAtMs > 0).length;

    return IsleSurface(
      margin: EdgeInsets.zero,
      tint: accent,
      radius: IsleRadius.hero,
      padding: const EdgeInsets.all(18),
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
                    color: accent,
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
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                        if (tasks.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${tasks.length} 个任务 · 已核验 $verifiedCount 个',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('addDesktopBackupTaskButton'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: running ? null : () => _addOrEditTask(),
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 17,
                    ),
                    label: const Text('添加文件夹'),
                  ),
                  if (running)
                    FilledButton.icon(
                      key: const ValueKey('pauseDesktopBackupButton'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _controller.requestCancel,
                      icon: const Icon(Icons.pause_circle_outline, size: 17),
                      label: const Text('暂停同步'),
                    )
                  else if (tasks.isNotEmpty)
                    FilledButton.icon(
                      key: const ValueKey('runAllDesktopBackupButton'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: tasks.any((t) => t.enabled)
                          ? () => unawaited(_controller.runAllEnabled())
                          : null,
                      icon: const Icon(Icons.sync_rounded, size: 17),
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
                    color: sage,
                    size: 38,
                    strokeWidth: 3.5,
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
                  const SizedBox(width: 10),
                  Expanded(
                    child: IsleSegmentedBar(
                      height: 7,
                      showPercentInLegend: true,
                      legendGap: 5,
                      legendSpacing: 10,
                      legendRunSpacing: 2,
                      segments: [
                        IsleChartSegment(
                          label: '已同步',
                          value: progress.completedFiles.toDouble(),
                          color: sage,
                          detail: '${progress.completedFiles} 项',
                        ),
                        IsleChartSegment(
                          label: '待处理',
                          value: (progress.totalFiles - progress.completedFiles)
                              .clamp(0, progress.totalFiles)
                              .toDouble(),
                          color: palette['cardItemBottom'],
                          detail:
                              '${(progress.totalFiles - progress.completedFiles).clamp(0, progress.totalFiles)} 项',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ] else
              const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 6),
            Text(
              progress.currentFile.isEmpty
                  ? progress.phase
                  : '${progress.phase} · ${progress.currentFile}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
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
              labelText: '自动检查频率',
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
    final palette = IslePalette.of(context);
    final accent = palette['brandAmber'];
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Column(
        children: [
          IsleSquircleBadge(
            icon: Icons.folder_copy_outlined,
            color: accent,
            size: 44,
            iconSize: 22,
          ),
          const SizedBox(height: 12),
          Text(
            '还没有本机备份任务',
            style: theme.textTheme.titleSmall?.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => _addOrEditTask(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('添加第一个备份文件夹'),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(BuildContext context, DesktopBackupTask task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final running = _controller.running;
    final isCurrent = _controller.activeProgress?.taskId == task.id;
    final (failures, omittedFailures) =
        _failuresByTask[task.id] ?? (const <DesktopBackupFailure>[], 0);
    final totalFailures = failures.length + omittedFailures;

    return IsleSurface(
      key: ValueKey('desktopBackupTaskCard:${task.id}'),
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(15),
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
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    IsleStatusBadge(
                      label: task.conflictPolicy.shortLabel,
                      color: colors.primary,
                    ),
                    if (isCurrent)
                      IsleStatusBadge(
                        label: '同步中',
                        color: palette['brandBlue'],
                      )
                    else if (totalFailures > 0 || task.lastError != null)
                      IsleStatusBadge(
                        label: totalFailures > 0
                            ? '待处理 $totalFailures'
                            : '需检查',
                        color: palette['brandAmber'],
                      )
                    else if (task.lastCompleteAtMs > 0)
                      IsleStatusBadge(
                        label: '已核验',
                        color: palette['brandSage'],
                      ),
                    if (failures.isNotEmpty)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          Icons.help_outline_rounded,
                          size: 14,
                          color: colors.error,
                        ),
                        label: Text(
                          '失败明细 ($totalFailures)',
                          style: TextStyle(fontSize: 11.5, color: colors.error),
                        ),
                        onPressed: () => _showTaskFailuresDialog(
                          context,
                          task.label,
                          failures,
                          omittedFailures,
                        ),
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
          Container(
            padding: const EdgeInsets.all(10),
            decoration: IsleDecorations.recessedWell(context, radius: 10),
            child: SelectableText(
              '本机：${task.localPath}\n'
              'NAS：${task.rootName} → /${task.remoteBasePath == '.' ? '' : task.remoteBasePath}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '最近同步：${formatUnixMillis(task.lastCompleteAtMs, emptyLabel: '尚未完成同步')}'
            '${task.lastSummary != null ? ' · ${task.lastSummary}' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: colors.onSurfaceVariant,
            ),
          ),
          if (task.lastError != null) ...[
            const SizedBox(height: 6),
            Text(
              task.lastError!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.tonalIcon(
                key: ValueKey('runDesktopBackupTask:${task.id}'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: running
                    ? null
                    : () => unawaited(
                        _controller
                            .runTask(task.id)
                            .then((_) => _refreshFailures()),
                      ),
                icon: const Icon(Icons.play_arrow_rounded, size: 17),
                label: const Text('立即备份'),
              ),
              if (totalFailures > 0) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: ValueKey('retryDesktopBackupFailures:${task.id}'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: running
                      ? null
                      : () => unawaited(
                          _controller
                              .runTask(task.id, retryFailuresOnly: true)
                              .then((_) => _refreshFailures()),
                        ),
                  icon: const Icon(Icons.replay_rounded, size: 16),
                  label: const Text('仅重试失败项'),
                ),
              ],
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '任务操作',
                enabled: !running,
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 19,
                  color: colors.onSurfaceVariant,
                ),
                style: IconButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                shape: IsleShapes.md(
                  side: BorderSide(color: borderColor, width: 1.0),
                ),
                onSelected: (action) {
                  if (action == 'edit') {
                    _addOrEditTask(task);
                  } else if (action == 'delete') {
                    _confirmDeleteTask(task);
                  }
                },
                itemBuilder: (_) => [
                  isleActionMenuItem(
                    value: 'edit',
                    icon: Icons.edit_outlined,
                    label: '编辑配置',
                  ),
                  isleActionMenuItem(
                    value: 'delete',
                    icon: Icons.delete_outline_rounded,
                    label: '移除任务',
                    destructive: true,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('本机文件夹备份'),
        actions: [
          IsleHelpButton(
            title: '本机备份规则说明',
            accentColor: palette['brandAmber'],
            items: const [
              IsleHelpItem(
                title: '单向增量只读保护',
                body: '仅单向读取本机源文件夹并增量上传至 NAS，不会修改或删除本机目录，也不会自动清理 NAS 上已有文件。',
              ),
              IsleHelpItem(
                title: '快检缓存与安全过滤',
                body:
                    '结合修改时间、体积与 SHA-256 摘要实现秒级跳过未变动文件，并自动忽略 .DS_Store 等系统隐藏文件与指向目录外的软链接。',
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: IsleListView(
          maxWidth: IsleLayout.workbenchMaxWidth,
          children: [
            if (_controller.loadError case final loadError?) ...[
              Notice(loadError, error: true),
              const SizedBox(height: 10),
            ],
            _buildOverviewCard(context),
            const SizedBox(height: 12),
            if (_controller.tasks.isEmpty)
              _buildEmptyState(context)
            else
              IsleAdaptiveBuilder(
                builder: (context, tier, width) {
                  final textScale =
                      MediaQuery.textScalerOf(context).scale(14) / 14;
                  if (tier == IsleViewportTier.expanded &&
                      _controller.tasks.length > 1 &&
                      textScale <= 1.35) {
                    final cardWidth = (width - 12) / 2;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final task in _controller.tasks)
                          SizedBox(
                            width: cardWidth,
                            child: _buildTaskCard(context, task),
                          ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _controller.tasks.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        _buildTaskCard(context, _controller.tasks[i]),
                      ],
                    ],
                  );
                },
              ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
