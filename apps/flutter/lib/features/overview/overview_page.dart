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
  Map<String, dynamic>? _personalStorage;
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
      _timer = Timer.periodic(Duration(seconds: widget.isAdmin ? 5 : 60), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.isAdmin) {
        final stats = await widget.api.get('/api/v1/system');
        if (mounted) setState(() { _stats = stats; _error = null; });
      } else {
        final storage = await widget.api.get('/api/v1/me/storage');
        if (mounted) setState(() { _personalStorage = storage; _error = null; });
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
            radius: 28,
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxWidth < 620;
                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'LIGHTISLE · YOUR PRIVATE SANCTUARY',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            widget.isAdmin ? '家庭设备管理' : '我的家庭空间',
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            widget.isAdmin
                                ? '查看 Mac 运行情况、存储状态和家庭后台任务。'
                                : '浏览自己的文件、时光相册和影院。遇到硬盘问题请联系家庭管理员。',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              height: 1.55,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35),
                                    width: 0.75,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const IslePulsingStatusDot(
                                      color: Color(0xff10b981),
                                      size: 7,
                                    ),
                                    const SizedBox(width: 7),
                                    Flexible(
                                      child: Text(
                                        widget.isAdmin ? (stats?['hostname']?.toString() ?? '家庭 Mac') : '我的轻屿',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IsleButton(
                                onPressed: _busy ? null : _refresh,
                                icon: Icons.refresh_rounded,
                                label: '刷新状态',
                                size: IsleButtonSize.small,
                                variant: IsleButtonVariant.secondary,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!isCompact)
                      const Padding(
                        padding: EdgeInsets.only(left: 24),
                        child: IsleBrandMark(size: 110),
                      ),
                  ],
                );
              },
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
          if (_busy && (widget.isAdmin ? stats == null : _personalStorage == null))
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
          if (!widget.isAdmin && _personalStorage != null) ...[
            const SizedBox(height: 20),
            IsleSurface(
              radius: 20,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('我的存储空间', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text('已配置 ${objectList(_personalStorage!['locations']).length} 个分类目录'),
                  Text('额度：${_personalStorage!['quotaBytes'] == null ? '不限制' : formatBytes(_personalStorage!['quotaBytes'] as num?)}'),
                  Text('已计入 ${formatBytes(_personalStorage!['accountedBytes'] as num?)} · 上传预占 ${formatBytes(_personalStorage!['reservedBytes'] as num?)}'),
                  if (_personalStorage!['usageComplete'] != true)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('部分写入渠道尚未纳入统计；此处不是全部文件的实际使用量。'),
                    ),
                ],
              ),
            ),
          ],
          if (widget.isAdmin && stats != null) ...[
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = width >= 1100
                    ? 4
                    : width >= 600
                    ? 2
                    : 1;
                final cpuPct = stats['cpuPercent'] is num
                    ? (stats['cpuPercent'] as num).toDouble() / 100
                    : null;
                final memPct = memoryTotal > 0
                    ? (memoryUsed / memoryTotal).clamp(0.0, 1.0)
                    : null;
                final diskPct = diskTotal > 0
                    ? (1.0 - (diskFree / diskTotal)).clamp(0.0, 1.0)
                    : null;
                final cards = [
                  IsleBentoStatCard(
                    title: '处理器',
                    value: _percent(stats['cpuPercent']),
                    detail:
                        '${stats['cpuCount']} 核 · ${stats['architecture']}',
                    icon: Icons.memory_rounded,
                    color: const Color(0xff0071e3),
                    gradient: const [Color(0xff2589ff), Color(0xff0066cc)],
                    progress: cpuPct,
                  ),
                  IsleBentoStatCard(
                    title: '内存',
                    value: formatBytes(memoryUsed),
                    detail:
                        '共 ${formatBytes(memoryTotal)} · ${memoryTotal == 0 ? '—' : _percent(memoryUsed / memoryTotal * 100)}',
                    icon: Icons.speed_rounded,
                    color: const Color(0xff8b5cf6),
                    gradient: const [Color(0xffa78bfa), Color(0xff7c3aed)],
                    progress: memPct,
                  ),
                  IsleBentoStatCard(
                    title: '系统磁盘',
                    value: '${formatBytes(diskFree)} 可用',
                    detail: '共 ${formatBytes(diskTotal)}',
                    icon: Icons.storage_rounded,
                    color: const Color(0xff0ea5e9),
                    gradient: const [Color(0xff38bdf8), Color(0xff0284c7)],
                    progress: diskPct,
                  ),
                  IsleBentoStatCard(
                    title: '网络',
                    value:
                        '↓ ${formatBytes(stats['networkDownBps'] as num?)}/s',
                    detail:
                        '↑ ${formatBytes(stats['networkUpBps'] as num?)}/s',
                    icon: Icons.swap_vert_rounded,
                    color: const Color(0xff10b981),
                    gradient: const [Color(0xff34d399), Color(0xff059669)],
                  ),
                ];
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: List.generate(
                    cards.length,
                    (i) => SizedBox(
                      width: (width - (columns - 1) * 12) / columns,
                      child: IsleAnimatedEntrance(
                        delay: Duration(milliseconds: 35 * i),
                        child: cards[i],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            Text('存储卷', style: Theme.of(context).textTheme.titleLarge),
            if (objectList(stats['volumes']).isEmpty)
              const Notice('当前没有可用的存储卷信息。'),
            ...objectList(stats['volumes']).map(
              (volume) {
                final total = ((volume['total'] as num?) ?? 0).toDouble();
                final free = ((volume['free'] as num?) ?? 0).toDouble();
                final usedRatio = total <= 0 ? 0.0 : (1.0 - (free / total)).clamp(0.0, 1.0);
                return IsleSurface(
                  padding: EdgeInsets.zero,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const IsleSquircleBadge(
                              icon: Icons.dns_rounded,
                              color: Color(0xff0ea5e9),
                              gradient: [Color(0xff38bdf8), Color(0xff0284c7)],
                              size: 32,
                              iconSize: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                volume['name']?.toString() ?? '存储卷',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (volume['readOnly'] == true)
                              const IsleStatusBadge(label: '只读', color: Color(0xfff59e0b)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${formatBytes(volume['free'] as num?)} 可用 / ${formatBytes(volume['total'] as num?)} · ${volume['filesystem'] ?? ''}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: Stack(
                            children: [
                              Container(
                                height: 6,
                                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                              ),
                              FractionallySizedBox(
                                widthFactor: usedRatio,
                                child: Container(
                                  height: 6,
                                  decoration: const BoxDecoration(
                                    borderRadius: BorderRadius.all(Radius.circular(999)),
                                    gradient: LinearGradient(
                                      colors: [Color(0xff38bdf8), Color(0xff0284c7)],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
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
            const Notice('应用配置备份和恢复请在 Mac 原生管理端进行。原始文件请另行备份。'),
          ],
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
