import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'desktop_backup_engine.dart';
import 'desktop_backup_models.dart';
import 'desktop_backup_restore.dart';

/// Opens the interactive "Restore from NAS to Local" diff preview & execution dialog.
Future<DesktopRestoreResult?> showDesktopBackupRestoreDialog(
  BuildContext context, {
  required LightIsleApi api,
  required DesktopDirectoryAccess directoryAccess,
  required DesktopBackupStore store,
  required DesktopBackupTask task,
}) => showDialog<DesktopRestoreResult>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DesktopBackupRestoreDialog(
    service: DesktopBackupRestoreService(
      api: api,
      directoryAccess: directoryAccess,
      store: store,
    ),
    task: task,
  ),
);

class _DesktopBackupRestoreDialog extends StatefulWidget {
  const _DesktopBackupRestoreDialog({
    required this.service,
    required this.task,
  });

  final DesktopBackupRestoreService service;
  final DesktopBackupTask task;

  @override
  State<_DesktopBackupRestoreDialog> createState() =>
      _DesktopBackupRestoreDialogState();
}

class _DesktopBackupRestoreDialogState
    extends State<_DesktopBackupRestoreDialog> {
  DesktopRestorePlan? _plan;
  DesktopRestoreProgress? _progress;
  DesktopRestoreResult? _result;
  String? _error;
  bool _loadingPlan = true;
  bool _restoring = false;
  bool _cancelled = false;
  DesktopRestoreConflictStrategy _strategy =
      DesktopRestoreConflictStrategy.missingOnly;
  bool _verifySha256 = true;

  @override
  void initState() {
    super.initState();
    unawaited(_scanDiff());
  }

  Future<void> _scanDiff() async {
    setState(() {
      _loadingPlan = true;
      _error = null;
      _cancelled = false;
    });
    try {
      final plan = await widget.service.buildPlan(
        widget.task,
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        isCancelled: () => _cancelled || !mounted,
      );
      if (mounted) {
        setState(() {
          _plan = plan;
          _loadingPlan = false;
          _progress = null;
        });
      }
    } on DesktopRestoreCancelled {
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingPlan = false;
          _progress = null;
          _error = userFacingError(error);
        });
      }
    }
  }

  Future<void> _startRestore() async {
    final plan = _plan;
    if (plan == null || _restoring) return;
    setState(() {
      _restoring = true;
      _cancelled = false;
      _error = null;
    });
    try {
      final res = await widget.service.executeRestore(
        plan,
        strategy: _strategy,
        verifySha256: _verifySha256,
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        isCancelled: () => _cancelled || !mounted,
      );
      if (mounted) {
        setState(() {
          _restoring = false;
          _progress = null;
          _result = res;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _restoring = false;
          _progress = null;
          _error = userFacingError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final plan = _plan;
    final actionable = plan?.actionableFor(_strategy) ?? const [];

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      title: Text(
        '从 NAS 还原到本机 · ${widget.task.label}',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loadingPlan || _restoring) ...[
                IsleLoadingState(
                  compact: true,
                  label: _progress?.phase ?? '正在处理…',
                ),
                if (_progress?.currentFile.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _progress!.currentFile,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.primary,
                      ),
                    ),
                  ),
              ] else if (_error != null)
                Notice(_error!, error: true)
              else if (_result != null) ...[
                Notice(_result!.formatSummary()),
                for (final f in _result!.failures.take(8))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '• ${f.relativePath}：${f.reason}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ),
              ] else if (plan != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: IsleDecorations.recessedWell(
                    context,
                    radius: IsleRadius.sm,
                  ),
                  child: Text(
                    'NAS 源目录：${widget.task.rootName} → /${widget.task.remoteBasePath == '.' ? '' : widget.task.remoteBasePath}\n'
                    '本机目标：${plan.resolvedLocalRoot}\n'
                    '本地缺失 ${plan.missingItems.length} 项 · 内容差异 ${plan.conflictItems.length} 项 · '
                    '已一致 ${plan.identicalItems.length} 项 · 本地独有 ${plan.localOnlyCount} 项（绝不删除）',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                  ),
                ),
                const SizedBox(height: 8),
                for (final option in DesktopRestoreConflictStrategy.values)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _strategy == option
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: _strategy == option
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    title: Text(
                      option.title,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                    subtitle: Text(
                      option.subtitle,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    onTap: () => setState(() => _strategy = option),
                  ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '下载后逐项校验 SHA-256 完整性（推荐）',
                    style: TextStyle(fontSize: 13),
                  ),
                  value: _verifySha256,
                  onChanged: (v) => setState(() => _verifySha256 = v),
                ),
                Text(
                  actionable.isEmpty
                      ? '本机已包含全部需要的文件，无需下载。'
                      : '预计还原 ${actionable.length} 个文件（共 ${formatBytes(plan.totalBytesFor(_strategy))}）：',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (actionable.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    padding: const EdgeInsets.all(8),
                    decoration: IsleDecorations.recessedWell(
                      context,
                      radius: IsleRadius.sm,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: actionable.length > 30
                          ? 31
                          : actionable.length,
                      itemBuilder: (_, idx) {
                        if (idx == 30) {
                          return Text(
                            '… 以及其余 ${actionable.length - 30} 项',
                            style: theme.textTheme.bodySmall,
                          );
                        }
                        final item = actionable[idx];
                        final tag =
                            item.status ==
                                DesktopRestoreItemStatus.missingLocally
                            ? '[缺失]'
                            : '[覆盖前备份]';
                        return Text(
                          '$tag ${item.relativePath} (${formatBytes(item.remoteSize)})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_loadingPlan || _restoring)
          TextButton(
            onPressed: () => setState(() => _cancelled = true),
            child: const Text('取消'),
          )
        else if (_result != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, _result),
            child: const Text('完成'),
          )
        else ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (_error != null)
            FilledButton.tonal(onPressed: _scanDiff, child: const Text('重新扫描'))
          else
            FilledButton(
              key: const ValueKey('confirmDesktopRestoreButton'),
              onPressed: actionable.isEmpty ? null : _startRestore,
              child: Text('开始还原 (${actionable.length})'),
            ),
        ],
      ],
    );
  }
}
