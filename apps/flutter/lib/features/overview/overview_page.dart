import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import 'dashboard_role_widgets.dart';
import 'storage_volume_browser.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.api,
    required this.isAdmin,
    this.onNavigate,
    this.onBrowseDirectory,
  });
  final LightIsleApi api;
  final bool isAdmin;
  final ValueChanged<int>? onNavigate;
  final OpenStorageDirectory? onBrowseDirectory;
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _personalStorage;
  List<LightIsleRoot> _roots = const [];
  String? _rootsError;
  DateTime? _lastRootCheck;
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
      _timer = Timer.periodic(
        Duration(seconds: widget.isAdmin ? 5 : 60),
        (_) => _refresh(),
      );
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.isAdmin) {
        final stats = await widget.api.get('/api/v2/system');
        if (mounted) {
          setState(() {
            _stats = stats;
            _error = null;
          });
        }
      } else {
        final storage = await widget.api.get('/api/v2/me/storage');
        if (mounted) {
          setState(() {
            _personalStorage = storage;
            _error = null;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    }
    // Root discovery is permission filtered by the backend. Refresh more
    // slowly than the 5s system metrics; a device swap still requires a new
    // generation and is validated again when opening the file browser.
    final now = DateTime.now();
    if (_lastRootCheck == null ||
        now.difference(_lastRootCheck!) >= const Duration(seconds: 30)) {
      _lastRootCheck = now;
      try {
        final response = await widget.api.get('/api/v2/roots');
        final items = response['roots'];
        if (items is! List) throw const FormatException('存储根响应无效');
        final roots = items
            .map(
              (item) => LightIsleRoot.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false);
        if (mounted) {
          setState(() {
            _roots = roots;
            _rootsError = null;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _roots = const [];
            _rootsError = userFacingError(e);
          });
        }
      }
    }
    if (widget.isAdmin && mounted) {
      try {
        final result = await widget.api.get('/api/v2/tasks');
        if (mounted) {
          setState(() {
            _tasks = objectList(result['tasks']);
            _taskError = null;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _taskError = userFacingError(e));
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
    final hero = IsleDeviceHero(
      title: '家里的 Mac',
      detail: _error != null
          ? '设备状态暂时无法确认，请重新检查'
          : widget.isAdmin
          ? '通过这台 Mac 管理你的私人文件与媒体'
          : '安全访问属于你的家庭资料',
      status: _error != null
          ? '待检查'
          : (widget.isAdmin ? stats != null : _personalStorage != null)
          ? '已连接'
          : '检查中',
      statusColor: _error != null
          ? Theme.of(context).colorScheme.error
          : (widget.isAdmin ? stats != null : _personalStorage != null)
          ? IslePalette.of(context)['success']
          : null,
    );
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: EdgeInsets.all(IsleLayout.pageInset(constraints.maxWidth)),
          children: [
            IslePageHeader(
              title: widget.isAdmin ? '这台 Mac' : '我的家庭空间',
              subtitle: widget.isAdmin
                  ? '设备状态、个人内容与后台任务，一目了然。'
                  : '文件、照片与影片，都在自己的空间。',
              trailing: IconButton(
                tooltip: '刷新状态',
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ),
            if (constraints.maxWidth >= 600)
              Padding(padding: const EdgeInsets.only(bottom: 16), child: hero),
            if (!widget.isAdmin && widget.onNavigate != null) ...[
              DashboardQuickLinks(onNavigate: widget.onNavigate!, admin: false),
              const SizedBox(height: 6),
            ],
            if (constraints.maxWidth < 600)
              Padding(padding: const EdgeInsets.only(bottom: 16), child: hero),
            if (_busy &&
                (widget.isAdmin ? stats == null : _personalStorage == null))
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
              const SizedBox(height: 16),
              MemberStorageSummary(storage: _personalStorage!),
              MemberStorageBrowser(
                storage: _personalStorage!,
                roots: _roots,
                onOpen: widget.onBrowseDirectory,
              ),
            ],
            if (widget.isAdmin && stats != null) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final largeText =
                      MediaQuery.textScalerOf(context).scale(14) > 19;
                  // Two 130px stat cards lose the number and its units at
                  // phone widths, especially with accessibility text sizes.
                  final columns = largeText
                      ? (width >= 900 ? 2 : 1)
                      : width >= 960
                      ? 4
                      : 2;
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
              const SizedBox(height: 12),
              IsleSurface(
                radius: 20,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    const IsleSquircleBadge(
                      icon: Icons.memory_rounded,
                      color: Color(0xff6366f1),
                      size: 40,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '轻屿服务内存占用',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            'LightIsle 文件服务占用的内存，不包含其他应用',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      formatBytes(stats['coreRssBytes'] as num?),
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              if (widget.onNavigate != null) ...[
                const SizedBox(height: 20),
                DashboardQuickLinks(
                  onNavigate: widget.onNavigate!,
                  admin: true,
                ),
              ],
              AdminVolumeBrowser(
                volumes: objectList(stats['volumes']),
                roots: _roots,
                rootsError: _rootsError,
                onOpen: widget.onBrowseDirectory,
              ),
              const SizedBox(height: 8),
              Text(
                '采样时间：${stats['timestamp'] ?? '—'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (widget.isAdmin) ...[
              IsleSectionHeader(
                title: '任务中心',
                action: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TaskHistoryPage(api: widget.api),
                    ),
                  ),
                  child: const Text('查看历史'),
                ),
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
      await widget.api.send('POST', '/api/v2/tasks/${task['kind']}/$action');
      await widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
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
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IsleStatusBadge(label: taskStatus(task), color: statusColor),
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
    body: IsleListView(
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
                        '${taskName(task['kind'])} · ${taskStatus(task)}',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '已处理 ${task['progress'] ?? 0} 项 · '
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
