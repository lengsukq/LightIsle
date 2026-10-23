import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.api,
    required this.isAdmin,
    this.onNavigate,
  });
  final LightIsleApi api;
  final bool isAdmin;
  final ValueChanged<int>? onNavigate;
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _tasks = [];
  String? _error, _taskError;
  Timer? _timer;
  bool _busy = false, _visible = true, _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_visible && _foreground) {
      _refresh();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final stats = await widget.api.get('/api/v1/system');
      if (mounted) {
        setState(() {
          _stats = stats;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (widget.isAdmin && mounted) {
      try {
        final result = await widget.api.get('/api/v1/tasks');
        if (mounted) {
          setState(() {
            _tasks = objectList(result['tasks']);
            _taskError = null;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _taskError = e.toString());
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _percent(Object? value) =>
      value is num ? '${value.clamp(0, 100).toStringAsFixed(1)}%' : '采样中';
  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final memoryTotal = (stats?['memoryTotal'] as num?) ?? 0;
    final memoryUsed = (stats?['memoryUsed'] as num?) ?? 0;
    final diskTotal = (stats?['diskTotal'] as num?) ?? 0;
    final diskFree = (stats?['diskFree'] as num?) ?? 0;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          IsleSurface(
            radius: 30,
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'LIGHTISLE · YOUR PRIVATE SPACE',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                letterSpacing: 1.4,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '让记忆如水般流淌',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '照片、家庭影音与珍贵档案，安放于这台 Mac。',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                height: 1.6,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              stats?['hostname']?.toString() ?? '你的轻屿',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            TextButton.icon(
                              onPressed: _busy ? null : _refresh,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('刷新状态'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (constraints.maxWidth > 620)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: IsleBrandMark(size: 110),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (widget.onNavigate != null) ...[
            Text(
              '数字生活空间',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900
                    ? 3
                    : constraints.maxWidth >= 560
                    ? 2
                    : 1;
                final items = <(int, IconData, String, String, List<Color>)>[
                  (
                    1,
                    Icons.folder_rounded,
                    '私人文件',
                    '文档与珍贵档案，有序存取。',
                    [const Color(0xff0284c7), const Color(0xff2563eb)],
                  ),
                  (
                    2,
                    Icons.photo_library_rounded,
                    '时光相册',
                    '保留原画，翻阅每一个美好瞬间。',
                    [const Color(0xff7c3aed), const Color(0xffec4899)],
                  ),
                  (
                    3,
                    Icons.movie_rounded,
                    '私人影院',
                    '家庭影音，随时接着上次观看。',
                    [const Color(0xff2563eb), const Color(0xff4f46e5)],
                  ),
                ];
                return Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: items
                      .map(
                        (item) => SizedBox(
                          width:
                              (constraints.maxWidth - (columns - 1) * 14) /
                              columns,
                          child: IsleSanctuaryTile(
                            title: item.$3,
                            subtitle: item.$4,
                            icon: item.$2,
                            gradientColors: item.$5,
                            onTap: () => widget.onNavigate!(item.$1),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 28),
          ],
          if (_busy && stats == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Notice(
              '无法更新服务状态：$_error${stats == null ? '' : '\n以下为上一次成功采样。'}',
              onRetry: _refresh,
              error: true,
            ),
          if (stats != null) ...[
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = width >= 1100
                    ? 4
                    : width >= 600
                    ? 2
                    : 1;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children:
                      [
                            _Metric(
                              title: '处理器',
                              value: _percent(stats['cpuPercent']),
                              detail:
                                  '${stats['cpuCount']} 核 · ${stats['architecture']}',
                              icon: Icons.memory,
                            ),
                            _Metric(
                              title: '内存',
                              value: formatBytes(memoryUsed),
                              detail:
                                  '共 ${formatBytes(memoryTotal)} · ${memoryTotal == 0 ? '—' : _percent(memoryUsed / memoryTotal * 100)}',
                              icon: Icons.speed,
                            ),
                            _Metric(
                              title: '系统磁盘',
                              value: '${formatBytes(diskFree)} 可用',
                              detail: '共 ${formatBytes(diskTotal)}',
                              icon: Icons.storage,
                            ),
                            _Metric(
                              title: '网络',
                              value:
                                  '↓ ${formatBytes(stats['networkDownBps'] as num?)}/s',
                              detail:
                                  '↑ ${formatBytes(stats['networkUpBps'] as num?)}/s',
                              icon: Icons.swap_vert,
                            ),
                          ]
                          .map(
                            (tile) => SizedBox(
                              width: (width - (columns - 1) * 12) / columns,
                              child: tile,
                            ),
                          )
                          .toList(),
                );
              },
            ),
            const SizedBox(height: 24),
            Text('存储卷', style: Theme.of(context).textTheme.titleLarge),
            if (objectList(stats['volumes']).isEmpty)
              const Notice('当前没有可用的存储卷信息。'),
            ...objectList(stats['volumes']).map(
              (volume) => IsleSurface(
                padding: EdgeInsets.zero,
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        volume['name']?.toString() ?? '存储卷',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${formatBytes(volume['free'] as num?)} 可用 / ${formatBytes(volume['total'] as num?)} · ${volume['filesystem'] ?? ''}${volume['readOnly'] == true ? ' · 只读' : ''}',
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: ((volume['total'] as num?) ?? 0) <= 0
                            ? 0
                            : (1 -
                                      ((volume['free'] as num?) ?? 0) /
                                          (volume['total'] as num))
                                  .clamp(0, 1)
                                  .toDouble(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '采样时间：${stats['timestamp'] ?? '—'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (widget.isAdmin) ...[
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('任务中心', style: Theme.of(context).textTheme.titleLarge),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TaskHistoryPage(api: widget.api),
                    ),
                  ),
                  child: const Text('查看历史'),
                ),
              ],
            ),
            if (_taskError != null)
              Notice('任务状态更新失败：$_taskError', error: true, onRetry: _refresh),
            if (_tasks.isEmpty && _taskError == null)
              const Notice('暂无后台任务。可在图库或影视中开始扫描。'),
            ..._tasks.map(
              (task) =>
                  TaskTile(api: widget.api, task: task, onChanged: _refresh),
            ),
            const Notice('备份与恢复任务请在 Mac 原生管理端发起。'),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
  });
  final String title, value, detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return IsleSurface(
      radius: 18,
      padding: const EdgeInsets.all(18),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: isDark ? 0.20 : 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 17, color: colors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

String taskName(Object? kind) => switch (kind) {
  'gallery' => '图库扫描',
  'cinema' => '影视扫描',
  'backup' => '备份与恢复',
  _ => '后台任务',
};
String taskStatus(Map<String, dynamic> task) => task['running'] == true
    ? '运行中'
    : (task['lastError']?.toString() ?? '').isNotEmpty
    ? '未完成'
    : '已结束';

class TaskTile extends StatefulWidget {
  const TaskTile({
    super.key,
    required this.api,
    required this.task,
    required this.onChanged,
  });
  final LightIsleApi api;
  final Map<String, dynamic> task;
  final Future<void> Function() onChanged;
  @override
  State<TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<TaskTile> {
  bool _busy = false;
  String? _error;
  Future<void> _act() async {
    final task = widget.task;
    final action = task['running'] == true ? 'cancel' : 'retry';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send('POST', '/api/v1/tasks/${task['kind']}/$action');
      await widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final isRunning = task['running'] == true;
    final hasError = (task['lastError']?.toString() ?? '').isNotEmpty;
    final statusColor = isRunning
        ? const Color(0xff2563eb)
        : hasError
        ? const Color(0xffef4444)
        : const Color(0xff10b981);

    return IsleSurface(
      padding: EdgeInsets.zero,
      radius: 18,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${taskName(task['kind'])} · ${taskStatus(task)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IsleStatusBadge(
                  label: taskStatus(task),
                  color: statusColor,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '已处理 ${task['progress'] ?? 0} 项${((task['bytes'] as num?) ?? 0) > 0 ? ' · ${formatBytes(task['bytes'] as num?)}' : ''}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (isRunning)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                  child: LinearProgressIndicator(minHeight: 4),
                ),
              ),
            if (hasError) ...[
              const SizedBox(height: 4),
              Text(
                '原因：${task['lastError']}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ],
            if (_error != null) Notice(_error!, error: true),
            if (task['kind'] == 'gallery' || task['kind'] == 'cinema') ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : _act,
                  icon: Icon(
                    isRunning ? Icons.close_rounded : Icons.replay_rounded,
                    size: 16,
                  ),
                  label: Text(isRunning ? '取消扫描' : '重新扫描'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

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
  bool _busy = false, _loaded = false;
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
        '/api/v1/tasks/history',
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
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('任务历史'),
      actions: [
        IconButton(
          tooltip: '刷新历史',
          onPressed: _busy ? null : () => _load(reset: true),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_loaded && _runs.isEmpty) const Notice('还没有任务历史。'),
        ..._runs.map(
          (task) => IsleSurface(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${taskName(task['kind'])} · ${taskStatus(task)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '已处理 ${task['progress'] ?? 0} 项 · 第 ${task['attempts'] ?? 1} 次尝试',
                  ),
                  if (task['startedAt'] is num)
                    Text(
                      DateTime.fromMillisecondsSinceEpoch(
                        (task['startedAt'] as num).toInt() * 1000,
                      ).toLocal().toString(),
                    ),
                  if ((task['lastError']?.toString() ?? '').isNotEmpty)
                    Text('原因：${task['lastError']}'),
                ],
              ),
            ),
          ),
        ),
        if (_busy) const Center(child: CircularProgressIndicator()),
        if (!_busy && _cursor.isNotEmpty)
          OutlinedButton(onPressed: _load, child: const Text('加载更多')),
      ],
    ),
  );
}
