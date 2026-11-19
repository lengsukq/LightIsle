import 'package:flutter/material.dart';

import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'dashboard_role_widgets.dart';

class TaskHistoryPage extends StatefulWidget {
  const TaskHistoryPage({super.key, required this.api});

  final LightIsleApi api;

  @override
  State<TaskHistoryPage> createState() => _TaskHistoryPageState();
}

class _TaskHistoryPageState extends State<TaskHistoryPage> {
  final List<Map<String, dynamic>> _runs = [];
  String _cursor = '';
  String _filter = 'all';
  String? _error;
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api.get(
        '/api/v2/tasks/history',
        query: {
          'limit': '20',
          if (!reset && _cursor.isNotEmpty) 'before': _cursor,
        },
      );
      if (mounted) {
        setState(() {
          if (reset) _runs.clear();
          _runs.addAll(objectList(result['runs']));
          _cursor = result['nextCursor']?.toString() ?? '';
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isFailed(Map<String, dynamic> task) {
    final err = task['lastError']?.toString().trim() ?? '';
    final state = task['state']?.toString() ?? '';
    return err.isNotEmpty || state == 'failed' || state == 'error';
  }

  bool _isRunning(Map<String, dynamic> task) => task['running'] == true;

  List<Map<String, dynamic>> get _filteredRuns => switch (_filter) {
    'failed' => _runs.where(_isFailed).toList(growable: false),
    'ok' => _runs
        .where((t) => !_isFailed(t) && !_isRunning(t))
        .toList(growable: false),
    _ => _runs,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final failedCount = _runs.where(_isFailed).length;
    final okCount = _runs.where((t) => !_isFailed(t) && !_isRunning(t)).length;
    final filtered = _filteredRuns;
    final accent = failedCount > 0
        ? palette['brandTerracotta']
        : palette['brandSage'];

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('任务历史'),
        actions: [
          IconButton(
            tooltip: '刷新历史',
            onPressed: _busy ? null : () => _load(reset: true),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
          IsleHelpButton(
            title: '后台任务历史说明',
            accentColor: accent,
            body:
                '汇总图库扫描、影视刮削、重复文件核验、回收站清理与存储换盘等后台任务的历史执行记录与异常原因。',
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.history_rounded,
            accent: accent,
            title: '后台任务与扫描历史',
            metrics: [
              IsleFocalMetric(
                label: '已加载记录',
                value: '${_runs.length}',
                accent: palette['brandBlue'],
              ),
              IsleFocalMetric(
                label: '正常完成',
                value: '$okCount',
                accent: palette['brandSage'],
              ),
              IsleFocalMetric(
                label: '异常记录',
                value: '$failedCount',
                accent: failedCount > 0
                    ? colors.error
                    : palette['brandAmber'],
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_runs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (key, label) in [
                    ('all', '全部 (${_runs.length})'),
                    ('ok', '正常完成 ($okCount)'),
                    ('failed', '异常记录 ($failedCount)'),
                  ])
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      selected: _filter == key,
                      side: BorderSide(
                        color: _filter == key
                            ? colors.primary.withValues(alpha: 0.45)
                            : borderColor,
                        width: 1.0,
                      ),
                      onSelected: (_) => setState(() => _filter = key),
                    ),
                ],
              ),
            ),
          if (_error != null)
            Notice(_error!, error: true, onRetry: () => _load(reset: true)),
          if (_busy && !_loaded)
            const IsleLoadingState(compact: true, label: '正在读取任务历史…')
          else if (_busy)
            const LinearProgressIndicator(minHeight: 2),
          if (_loaded && filtered.isEmpty)
            IsleEmptyStateCard(
              _runs.isEmpty ? '执行媒体扫描、查重或备份后，结果会记录在这里。' : '当前筛选条件下没有匹配记录。',
              title: _runs.isEmpty ? '还没有任务历史' : '暂无匹配记录',
              icon: Icons.history_toggle_off_rounded,
            ),
          if (filtered.isNotEmpty) ...[
            IsleSectionHeader(
              title: '执行明细（${filtered.length}）',
              accentColor: accent,
            ),
            IsleAdaptiveBuilder(
              builder: (context, tier, width) {
                final textScale =
                    MediaQuery.textScalerOf(context).scale(14) / 14;
                if (tier == IsleViewportTier.expanded && textScale <= 1.35) {
                  final cardWidth = (width - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final task in filtered)
                        SizedBox(
                          width: cardWidth,
                          child: IsleSurface(
                            margin: EdgeInsets.zero,
                            padding: EdgeInsets.zero,
                            child: _buildTaskTile(
                              context,
                              colors,
                              palette,
                              task,
                            ),
                          ),
                        ),
                    ],
                  );
                }
                return IsleGroupCard(
                  children: [
                    for (final task in filtered)
                      _buildTaskTile(context, colors, palette, task),
                  ],
                );
              },
            ),
          ],
          if (!_busy && _cursor.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _load,
                  icon: const Icon(Icons.expand_more_rounded, size: 17),
                  label: const Text('加载更早记录'),
                ),
              ),
            ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildTaskTile(
    BuildContext context,
    ColorScheme colors,
    IslePalette palette,
    Map<String, dynamic> task,
  ) {
    final lastError = task['lastError']?.toString().trim() ?? '';
    final failed = _isFailed(task);
    final running = _isRunning(task);
    final statusLabel = taskStatus(task);
    final badgeColor = failed
        ? colors.error
        : running
        ? palette['brandAmber']
        : palette['brandSage'];
    final icon = failed
        ? Icons.error_outline_rounded
        : running
        ? Icons.sync_rounded
        : Icons.check_circle_outline_rounded;
    final subParts = <String>[
      '已处理 ${task['processed'] ?? task['progress'] ?? 0} 项',
      '第 ${task['attempts'] ?? 1} 次尝试',
      if (task['startedAt'] is num)
        _formatTime((task['startedAt'] as num).toInt()),
    ];
    return IsleGroupTile(
      icon: icon,
      iconColor: badgeColor,
      title: taskName(task['kind'], operation: task['operation']),
      subtitle: lastError.isNotEmpty
          ? '${subParts.join(' · ')} · $lastError'
          : subParts.join(' · '),
      trailing: IsleStatusBadge(label: statusLabel, color: badgeColor),
    );
  }

  String _formatTime(int seconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${p(t.month)}-${p(t.day)} '
        '${p(t.hour)}:${p(t.minute)}';
  }
}
