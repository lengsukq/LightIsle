import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(
      title: const Text('任务历史'),
      actions: [
        IconButton(
          tooltip: '刷新历史',
          onPressed: _busy ? null : () => _load(reset: true),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: IsleListView(
      maxWidth: 1120,
      children: [
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_loaded && _runs.isEmpty) const Notice('还没有任务历史。'),
        if (_runs.isNotEmpty)
          IsleGroupCard(
            children: [
              for (final task in _runs)
                Builder(
                  builder: (context) {
                    final lastError = task['lastError']?.toString() ?? '';
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      leading: IsleSquircleBadge(
                        icon: Icons.assignment_outlined,
                        color: IslePalette.of(context)['brandBlue'],
                        size: 36,
                        iconSize: 19,
                      ),
                      title: Text(
                        '${taskName(task['kind'], operation: task['operation'])} · ${taskStatus(task)}',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '已处理 ${task['processed'] ?? task['progress'] ?? 0} 项 · '
                            '第 ${task['attempts'] ?? 1} 次尝试',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                          if (task['startedAt'] is num)
                            Text(
                              _formatTime((task['startedAt'] as num).toInt()),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          if (lastError.isNotEmpty)
                            Text(
                              '原因：$lastError',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        if (!_busy && _cursor.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: _load,
                child: const Text('加载更多'),
              ),
            ),
          ),
      ],
    ),
  );

  String _formatTime(int seconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${p(t.month)}-${p(t.day)} '
        '${p(t.hour)}:${p(t.minute)}';
  }
}
