import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'app_config_models.dart';

const _automationCronPresets = [
  ('*/15 * * * *', '每 15 分钟'),
  ('0 * * * *', '每小时'),
  ('0 2 * * *', '每天 02:00'),
];

String automationRunStateLabel(Object? state) => switch (state) {
  'running' => '运行中',
  'success' => '成功',
  'failure' => '失败',
  'timeout' => '超时',
  'interrupted' => '中断',
  'skipped' => '已跳过',
  _ => state?.toString() ?? '未知',
};

Iterable<Widget> _buildDeliveryLines(Object? deliveries) sync* {
  if (deliveries is! Map) return;
  const labels = {
    'queued': '等待发送',
    'sent': '已发送',
    'not_configured': '渠道未配置',
    'backoff': '渠道退避中',
    'queue_full': '发送队列已满',
    'interrupted': '发送结果未确认',
    'authentication_failed': '认证失败',
    'tls_failed': '加密连接失败',
    'connection_failed': '连接失败',
    'delivery_failed': '发送失败',
  };
  for (final (id, name) in kAppChannelOptions) {
    final status = deliveries[id];
    if (status is String) {
      yield Text('$name · ${labels[status] ?? status}');
    }
  }
}

Future<void> showAutomationRunOutputDialog(
  BuildContext context,
  Map<String, dynamic> run,
) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final deliveries = _buildDeliveryLines(run['deliveries']).toList();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark)),
      ),
      title: Text(
        '${automationRunStateLabel(run['state'])} · '
        '${formatUnixSeconds(run['startedAt'], emptyLabel: '未知时间', includeSeconds: true)}',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (run['exitCode'] is int && run['exitCode'] >= 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('退出码：${run['exitCode']}'),
                ),
              if (deliveries.isNotEmpty) ...[
                ...deliveries,
                const SizedBox(height: 8),
              ],
              AppTerminalLogBox(
                minHeight: 72,
                text: (run['output']?.toString().trim().isNotEmpty == true)
                    ? run['output'].toString()
                    : '（没有标准输出）',
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton.tonal(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// Renders one local script automation task card, including inline Cron /
/// notification editing and expandable run history.
class AutomationTaskCard extends StatelessWidget {
  const AutomationTaskCard({
    super.key,
    required this.task,
    required this.busy,
    required this.isEditing,
    required this.isShowingRuns,
    required this.runsBusy,
    required this.runs,
    required this.configuredChannels,
    required this.cronController,
    required this.timezoneController,
    required this.editingEnabled,
    required this.editingEvents,
    required this.editingChannels,
    required this.onToggleEnabled,
    required this.onStartEdit,
    required this.onLoadRuns,
    required this.onDeleteTask,
    required this.onEditingEnabledChanged,
    required this.onToggleEditingEvent,
    required this.onToggleEditingChannel,
    required this.onSaveEdit,
    required this.onReloadEditingTask,
    required this.onCancelEdit,
    required this.onCollapseRuns,
  });

  final Map<String, dynamic> task;
  final bool busy;
  final bool isEditing;
  final bool isShowingRuns;
  final bool runsBusy;
  final List<Map<String, dynamic>> runs;
  final Set<String> configuredChannels;
  final TextEditingController cronController;
  final TextEditingController timezoneController;
  final bool editingEnabled;
  final Set<String> editingEvents;
  final Set<String> editingChannels;
  final VoidCallback onToggleEnabled;
  final VoidCallback onStartEdit;
  final VoidCallback onLoadRuns;
  final VoidCallback onDeleteTask;
  final ValueChanged<bool> onEditingEnabledChanged;
  final void Function(String eventId, bool selected) onToggleEditingEvent;
  final void Function(String channelId, bool selected) onToggleEditingChannel;
  final VoidCallback onSaveEdit;
  final VoidCallback onReloadEditingTask;
  final VoidCallback onCancelEdit;
  final VoidCallback onCollapseRuns;

  Widget _buildHeader(
    BuildContext context,
    ColorScheme colors,
    IslePalette palette,
  ) {
    final id = task['id']?.toString() ?? '';
    final name = task['name']?.toString() ?? id;
    final entry = task['entry']?.toString() ?? '';
    final enabled = task['enabled'] == true;
    final running = task['running'] == true;
    final lastError = task['lastError']?.toString() ?? '';
    final schedule = task['schedule'] is Map
        ? Map<String, dynamic>.from(task['schedule'] as Map)
        : const <String, dynamic>{};
    final cron = schedule['cron']?.toString() ?? '无 Cron';
    final tz = schedule['timezone']?.toString() ?? '未设置时区';
    final lastRun = task['lastRun'];
    final nextRun = task['nextRun'];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IsleSquircleBadge(
          icon: Icons.terminal_rounded,
          color: palette['brandTerracotta'],
          size: 38,
          iconSize: 19,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IsleStatusBadge(
                    label: running ? '运行中' : (enabled ? '已启用' : '已暂停'),
                    color: running
                        ? palette['brandBlue']
                        : enabled
                        ? palette['brandSage']
                        : colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '$id · $entry · $cron ($tz)',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (nextRun is num && nextRun > 0)
                Text(
                  '下次执行 ${formatUnixSeconds(nextRun, emptyLabel: '未知时间', includeSeconds: true)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (lastRun is Map)
                Text(
                  '上次结果 ${automationRunStateLabel(lastRun['state'])} · '
                  '${formatUnixSeconds(lastRun['finishedAt'], emptyLabel: '未知时间', includeSeconds: true)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (lastError.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  lastError,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, ColorScheme colors) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = task['enabled'] == true;
    final running = task['running'] == true;
    final lastError = task['lastError']?.toString() ?? '';
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: busy || lastError.isNotEmpty
                    ? null
                    : onToggleEnabled,
                icon: Icon(
                  enabled ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 16,
                ),
                label: Text(enabled ? '关闭' : '启用'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: busy || lastError.isNotEmpty ? null : onStartEdit,
                icon: const Icon(Icons.schedule_rounded, size: 16),
                label: const Text('Cron 与通知'),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多任务操作',
          enabled: !busy,
          icon: Icon(
            Icons.more_horiz_rounded,
            size: 19,
            color: colors.onSurfaceVariant,
          ),
          style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
          shape: IsleShapes.md(
            side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1),
          ),
          onSelected: (action) {
            if (action == 'logs') {
              onLoadRuns();
            } else if (action == 'delete') {
              onDeleteTask();
            }
          },
          itemBuilder: (_) => [
            isleActionMenuItem(
              value: 'logs',
              icon: Icons.receipt_long_rounded,
              label: '查看执行日志',
            ),
            isleActionMenuItem(
              value: 'delete',
              enabled: !running,
              icon: Icons.delete_outline_rounded,
              label: '删除任务目录',
              destructive: true,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInlineEditor(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 22),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (expr, label) in _automationCronPresets)
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text('$label ($expr)'),
                onPressed: () => cronController.text = expr,
              ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final cronField = TextField(
              controller: cronController,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '五段 Cron',
                hintText: '0 8 * * *',
                isDense: true,
              ),
            );
            final tzField = TextField(
              controller: timezoneController,
              decoration: const InputDecoration(
                labelText: '时区',
                hintText: 'Asia/Shanghai',
                isDense: true,
              ),
            );
            if (constraints.maxWidth < 380) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [cronField, const SizedBox(height: 8), tzField],
              );
            }
            return Row(
              children: [
                Expanded(child: cronField),
                const SizedBox(width: 10),
                Expanded(child: tzField),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.schedule_rounded,
              title: '启用此定时任务',
              onTap: () => onEditingEnabledChanged(!editingEnabled),
              trailing: Switch.adaptive(
                value: editingEnabled,
                onChanged: onEditingEnabledChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('通知事件', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (evId, evLabel) in kAppEventOptions)
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: Text(evLabel),
                selected: editingEvents.contains(evId),
                onSelected: (selected) => onToggleEditingEvent(evId, selected),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text('通知渠道', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (chId, chLabel) in kAppChannelOptions)
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  configuredChannels.contains(chId) ? chLabel : '$chLabel（未配置）',
                ),
                selected: editingChannels.contains(chId),
                onSelected:
                    configuredChannels.contains(chId) ||
                        editingChannels.contains(chId)
                    ? (selected) => onToggleEditingChannel(chId, selected)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: busy ? null : onSaveEdit,
              child: const Text('保存设置'),
            ),
            OutlinedButton(
              onPressed: busy ? null : onReloadEditingTask,
              child: const Text('加载最新配置'),
            ),
            TextButton(
              onPressed: busy ? null : onCancelEdit,
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRunsPanel(
    BuildContext context,
    ColorScheme colors,
    IslePalette palette,
  ) {
    final sage = palette['brandSage'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 22),
        Row(
          children: [
            Expanded(
              child: Text(
                '最近执行记录',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: runsBusy ? null : onLoadRuns,
              child: const Text('刷新日志'),
            ),
            TextButton(onPressed: onCollapseRuns, child: const Text('收起')),
          ],
        ),
        if (runsBusy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (runs.isEmpty)
          Text(
            '暂无执行记录。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          )
        else
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              for (final run in runs)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 1,
                  ),
                  onTap: () => showAutomationRunOutputDialog(context, run),
                  leading: IsleStatusBadge(
                    label: automationRunStateLabel(run['state']),
                    color: run['state']?.toString() == 'success'
                        ? sage
                        : colors.error,
                  ),
                  title: Text(
                    formatUnixSeconds(
                      run['startedAt'],
                      emptyLabel: '未知时间',
                      includeSeconds: true,
                    ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: run['exitCode'] is int && run['exitCode'] >= 0
                      ? Text(
                          '退出码 ${run['exitCode']}',
                          style: const TextStyle(fontSize: 11.5),
                        )
                      : null,
                  trailing: const Icon(Icons.help_outline_rounded, size: 17),
                ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = IslePalette.of(context);
    final id = task['id']?.toString() ?? '';
    return IsleSurface(
      key: ValueKey('automationTask_$id'),
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, colors, palette),
          const SizedBox(height: 10),
          _buildActions(context, colors),
          if (isEditing) _buildInlineEditor(context),
          if (isShowingRuns) _buildRunsPanel(context, colors, palette),
        ],
      ),
    );
  }
}
