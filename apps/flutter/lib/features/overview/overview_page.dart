import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import '../files/file_shares_page.dart';
import '../files/computer_files_page.dart';
import '../settings/apps_center_page.dart';
import '../settings/storage_page.dart';
import 'dashboard_role_widgets.dart';
import 'storage_volume_browser.dart';

export 'dashboard_role_widgets.dart' show TaskTile, taskName, taskStatus;

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.api,
    required this.isAdmin,
    this.onNavigate,
    this.onBrowseDirectory,
    this.onOpenFiles,
  });
  final LightIsleApi api;
  final bool isAdmin;
  final ValueChanged<int>? onNavigate;
  final OpenStorageDirectory? onBrowseDirectory;
  final VoidCallback? onOpenFiles;
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

  String _formatSamplingTime(Object? raw) {
    if (raw == null) return '—';
    final text = raw.toString().trim();
    if (text.isEmpty) return '—';
    try {
      final parsed = DateTime.parse(text).toLocal();
      final y = parsed.year.toString().padLeft(4, '0');
      final m = parsed.month.toString().padLeft(2, '0');
      final d = parsed.day.toString().padLeft(2, '0');
      final h = parsed.hour.toString().padLeft(2, '0');
      final min = parsed.minute.toString().padLeft(2, '0');
      final s = parsed.second.toString().padLeft(2, '0');
      return '$y-$m-$d $h:$min:$s';
    } catch (_) {
      return text;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _percent(Object? value) =>
      value is num ? '${value.clamp(0, 100).toStringAsFixed(1)}%' : '采样中';
  void _openSharesPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => FileSharesPage(api: widget.api)),
    );
  }

  void _openAppsCenterPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            AppsCenterPage(api: widget.api, isAdmin: widget.isAdmin),
      ),
    );
  }

  Widget _buildAttentionBanner(BuildContext context) {
    final offlineRoots = _roots.where((r) => !r.online).toList();
    final failedTasks = _tasks
        .where((t) => (t['lastError']?.toString() ?? '').isNotEmpty)
        .toList();
    if (offlineRoots.isEmpty && failedTasks.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: IsleSurface(
        radius: IsleRadius.item,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: scheme.error, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                [
                  if (offlineRoots.isNotEmpty)
                    '${offlineRoots.length} 个存储目录离线（${offlineRoots.map((e) => e.name).join('、')}）',
                  if (failedTasks.isNotEmpty)
                    '${failedTasks.length} 项后台任务异常待处理',
                ].join(' · '),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (offlineRoots.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => StoragePage(api: widget.api, isAdmin: true),
                  ),
                ),
                child: const Text('查看存储'),
              ),
            TextButton(
              onPressed: _busy ? null : _refresh,
              child: const Text('重新检查'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderTrailing({required bool compact}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onOpenFiles != null)
          FilledButton.tonalIcon(
            key: const ValueKey('headerOpenFilesButton'),
            style: compact
                ? FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(40, 36),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  )
                : null,
            onPressed: widget.onOpenFiles,
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('文件管理'),
          ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '刷新状态',
          visualDensity: compact ? VisualDensity.compact : null,
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }

  Widget _buildAdminStatsGrid(Map<String, dynamic> stats) {
    final memoryTotal = (stats['memoryTotal'] as num?) ?? 0;
    final memoryUsed = (stats['memoryUsed'] as num?) ?? 0;
    final diskTotal = (stats['diskTotal'] as num?) ?? 0;
    final diskFree = (stats['diskFree'] as num?) ?? 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
        final columns = largeText
            ? (width >= 760 ? 2 : 1)
            : width >= 680
            ? 4
            : 2;
        final gap = width < IsleLayout.compactPageWidth ? 8.0 : 12.0;
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
            detail: '${stats['cpuCount']} 核 · ${stats['architecture']}',
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
            value: '↓ ${formatBytes(stats['networkDownBps'] as num?)}/s',
            detail: '↑ ${formatBytes(stats['networkUpBps'] as num?)}/s',
            icon: Icons.swap_vert_rounded,
            color: const Color(0xff10b981),
            gradient: const [Color(0xff34d399), Color(0xff059669)],
          ),
        ];
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: List.generate(
            cards.length,
            (i) => SizedBox(
              width: (width - (columns - 1) * gap) / columns,
              child: IsleAnimatedEntrance(
                delay: Duration(milliseconds: 35 * i),
                child: cards[i],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildAdminTasksSection(BuildContext context) {
    return [
      IsleSectionHeader(
        title: '任务中心',
        action: TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(40, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
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
      if (_tasks.isNotEmpty)
        IsleResponsiveGrid(
          minItemWidth: 280,
          maxColumns: 3,
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final task in _tasks)
              TaskTile(api: widget.api, task: task, onChanged: _refresh),
          ],
        ),
      const SizedBox(height: 6),
      const Notice('应用配置备份和恢复请在 Mac 原生管理端进行。原始文件请另行备份。'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final coreRss = stats?['coreRssBytes'] as num?;
    final hostname = stats?['hostname']?.toString().trim() ?? '';
    final hero = IsleDeviceHero(
      title: hostname.isNotEmpty ? hostname : '家里的 Mac',
      detail: _error != null
          ? '设备状态暂时无法确认，请重新检查'
          : widget.isAdmin
          ? '家庭私有云 · 文件、相册与影院'
          : '安全访问个人文件、相册与影院',
      status: _error != null
          ? '待检查'
          : (widget.isAdmin ? stats != null : _personalStorage != null)
          ? '在线运行'
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
        builder: (context, constraints) {
          final inset = IsleLayout.pageInset(constraints.maxWidth);
          final topInset = IsleLayout.pageTopInset(constraints.maxWidth);
          final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(inset, topInset, inset, inset + 60),
            children: [
              IslePageHeader(
                title: widget.isAdmin ? '这台 Mac' : '我的家庭空间',
                subtitle: widget.isAdmin
                    ? '设备活力、文件管理、个人媒体与后台任务，一屏掌控。'
                    : '文件、照片与影片，都在自己的私密空间。',
                hideSubtitleOnCompact: true,
                trailing: _buildHeaderTrailing(compact: compact),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: compact ? 8 : 12),
                child: hero,
              ),
              if (widget.isAdmin) _buildAttentionBanner(context),
              DashboardQuickLinks(
                onNavigate: widget.onNavigate ?? (_) {},
                admin: widget.isAdmin,
                onOpenFiles: widget.onOpenFiles,
                onOpenShares: _openSharesPage,
                onOpenAppsCenter: _openAppsCenterPage,
                onOpenComputerFiles: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ComputerFilesPage(
                      api: widget.api,
                      isAdmin: widget.isAdmin,
                    ),
                  ),
                ),
              ),
              SizedBox(height: compact ? 6 : 12),
              if (_busy &&
                  (widget.isAdmin ? stats == null : _personalStorage == null))
                const IsleLoadingState(label: '正在同步设备与空间状态…'),
              if (_error != null)
                Notice(
                  '无法更新服务状态：$_error${stats == null ? '' : '\n以下为上一次成功采样。'}',
                  onRetry: _refresh,
                  error: true,
                ),
              if (!widget.isAdmin && _personalStorage != null) ...[
                const SizedBox(height: 6),
                MemberStorageSummary(storage: _personalStorage!),
                MemberStorageBrowser(
                  storage: _personalStorage!,
                  roots: _roots,
                  onOpen: widget.onBrowseDirectory,
                ),
              ],
              if (widget.isAdmin && stats != null) ...[
                IsleSectionHeader(
                  title: '硬件活力与实时负载',
                  action: (coreRss != null || stats['timestamp'] != null)
                      ? Text(
                          [
                            if (coreRss != null) '服务内存 ${formatBytes(coreRss)}',
                            if (!compact && stats['timestamp'] != null)
                              _formatSamplingTime(stats['timestamp']),
                          ].join(' · '),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        )
                      : null,
                ),
                _buildAdminStatsGrid(stats),
                const SizedBox(height: 6),
                AdminVolumeBrowser(
                  volumes: objectList(stats['volumes']),
                  roots: _roots,
                  rootsError: _rootsError,
                  onOpen: widget.onBrowseDirectory,
                ),
              ],
              if (widget.isAdmin) ..._buildAdminTasksSection(context),
            ],
          );
        },
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
