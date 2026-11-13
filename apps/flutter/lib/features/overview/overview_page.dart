import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_quick_jump.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import '../files/computer_files_page.dart';
import '../files/downloads_page.dart';
import '../files/duplicate_files_page.dart';
import '../files/file_shares_page.dart';
import '../settings/admin_smb_page.dart';
import '../settings/apps_center_page.dart';
import '../settings/automation_page.dart';
import '../settings/dav_page.dart';
import '../settings/storage_page.dart';
import 'dashboard_role_widgets.dart';
import 'overview_telemetry_grid.dart';
import 'storage_volume_browser.dart';
import 'task_history_page.dart';

export 'dashboard_role_widgets.dart' show TaskTile, taskName, taskStatus;
export 'task_history_page.dart' show TaskHistoryPage;

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
  DateTime? _lastComputerFilesCheck;
  bool _computerFilesAvailable = false;
  List<Map<String, dynamic>> _tasks = [];
  String? _error, _taskError;
  Timer? _timer;
  final ValueNotifier<bool> _busyNotifier = ValueNotifier<bool>(false);
  bool get _busy => _busyNotifier.value;
  static const int _maxHistorySamples = 24;
  List<double> _cpuHistory = const [];
  List<double> _netHistory = const [];
  bool _visible = true, _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant OverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isAdmin != widget.isAdmin || oldWidget.api != widget.api) {
      _cpuHistory = const [];
      _netHistory = const [];
      _lastRootCheck = null;
      _lastComputerFilesCheck = null;
      _schedule();
    }
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
    _busyNotifier.value = true;
    var nextStats = _stats;
    var nextPersonalStorage = _personalStorage;
    var nextComputerFilesAvailable = _computerFilesAvailable;
    var nextRoots = _roots;
    var nextRootsError = _rootsError;
    var nextTasks = _tasks;
    var nextError = _error;
    var nextTaskError = _taskError;

    try {
      if (widget.isAdmin) {
        nextStats = await widget.api.get('/api/v2/system');
        nextError = null;
      } else {
        nextPersonalStorage = await widget.api.get('/api/v2/me/storage');
        nextError = null;
        final now = DateTime.now();
        if (_lastComputerFilesCheck == null ||
            now.difference(_lastComputerFilesCheck!) >=
                const Duration(seconds: 60)) {
          _lastComputerFilesCheck = now;
          try {
            final status = await widget.api.get(
              '/api/v2/computer-files/status',
            );
            nextComputerFilesAvailable =
                status['enabled'] == true &&
                (status['mode']?.toString() ?? 'none') != 'none';
          } catch (_) {
            nextComputerFilesAvailable = false;
          }
        }
      }
    } catch (e) {
      nextError = userFacingError(e);
    }
    final now = DateTime.now();
    if (_lastRootCheck == null ||
        now.difference(_lastRootCheck!) >= const Duration(seconds: 30)) {
      _lastRootCheck = now;
      try {
        final response = await widget.api.get('/api/v2/roots');
        final items = response['roots'];
        if (items is! List) throw const FormatException('存储根响应无效');
        nextRoots = items
            .map(
              (item) => LightIsleRoot.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false);
        nextRootsError = null;
      } catch (e) {
        nextRoots = const [];
        nextRootsError = userFacingError(e);
      }
    }
    if (widget.isAdmin && mounted) {
      try {
        final result = await widget.api.get('/api/v2/tasks');
        nextTasks = objectList(result['tasks']);
        nextTaskError = null;
      } catch (e) {
        nextTaskError = userFacingError(e);
      }
    }
    if (!mounted) {
      _busyNotifier.value = false;
      return;
    }
    final changed =
        !_overviewJsonEqual(_stats, nextStats) ||
        !_overviewJsonEqual(_personalStorage, nextPersonalStorage) ||
        _computerFilesAvailable != nextComputerFilesAvailable ||
        !_overviewRootsEqual(_roots, nextRoots) ||
        _rootsError != nextRootsError ||
        !_overviewJsonEqual(_tasks, nextTasks) ||
        _error != nextError ||
        _taskError != nextTaskError;
    _busyNotifier.value = false;
    if (changed) {
      final statsChanged = !_overviewJsonEqual(_stats, nextStats);
      setState(() {
        _stats = nextStats;
        _personalStorage = nextPersonalStorage;
        _computerFilesAvailable = nextComputerFilesAvailable;
        _roots = nextRoots;
        _rootsError = nextRootsError;
        _tasks = nextTasks;
        _error = nextError;
        _taskError = nextTaskError;
        if (statsChanged && nextStats != null) {
          _recordTelemetrySample(nextStats);
        }
      });
    }
  }

  void _recordTelemetrySample(Map<String, dynamic> stats) {
    List<double> append(List<double> list, double value) {
      if (!value.isFinite) return list;
      final next = [...list, value];
      if (next.length > _maxHistorySamples) {
        return List<double>.unmodifiable(
          next.sublist(next.length - _maxHistorySamples),
        );
      }
      return List<double>.unmodifiable(next);
    }

    final cpu = stats['cpuPercent'];
    if (cpu is num) {
      _cpuHistory = append(_cpuHistory, cpu.toDouble().clamp(0.0, 100.0));
    }
    final down = (stats['networkDownBps'] as num?)?.toDouble() ?? 0;
    final up = (stats['networkUpBps'] as num?)?.toDouble() ?? 0;
    _netHistory = append(_netHistory, (down + up).clamp(0.0, double.infinity));
  }

  static bool _overviewRootsEqual(
    List<LightIsleRoot> a,
    List<LightIsleRoot> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].name != b[i].name ||
          a[i].generation != b[i].generation ||
          a[i].online != b[i].online ||
          a[i].isDefault != b[i].isDefault ||
          a[i].volumeMount != b[i].volumeMount) {
        return false;
      }
    }
    return true;
  }

  static bool _overviewJsonEqual(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_overviewJsonEqual(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_overviewJsonEqual(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
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
    _busyNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _openSharesPage() {
    Navigator.of(context).push<void>(
      buildIslePageRoute(builder: (_) => FileSharesPage(api: widget.api)),
    );
  }

  void _openAppsCenterPage() {
    Navigator.of(context).push<void>(
      buildIslePageRoute(
        builder: (_) =>
            AppsCenterPage(api: widget.api, isAdmin: widget.isAdmin),
      ),
    );
  }

  void _openDownloadsPage() {
    Navigator.of(context).push<void>(
      buildIslePageRoute(builder: (_) => DownloadsPage(api: widget.api)),
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
    final message = [
      if (offlineRoots.isNotEmpty)
        '${offlineRoots.length} 个存储目录离线（${offlineRoots.map((e) => e.name).join('、')}）',
      if (failedTasks.isNotEmpty) '${failedTasks.length} 项后台任务异常待处理',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: IsleSurface(
        radius: IsleRadius.item,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 520 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.25;
            final actions = <Widget>[
              if (offlineRoots.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    buildIslePageRoute(
                      builder: (_) =>
                          StoragePage(api: widget.api, isAdmin: true),
                    ),
                  ),
                  child: const Text('查看存储'),
                ),
              ValueListenableBuilder<bool>(
                valueListenable: _busyNotifier,
                builder: (_, busy, _) => TextButton(
                  onPressed: busy ? null : _refresh,
                  child: const Text('重新检查'),
                ),
              ),
            ];
            final messageWidget = Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: scheme.error,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: messageWidget),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 4, runSpacing: 4, children: actions),
                ],
              );
            }
            return Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: scheme.error,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(child: messageWidget),
                ...actions,
              ],
            );
          },
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
        ValueListenableBuilder<bool>(
          valueListenable: _busyNotifier,
          builder: (_, busy, _) => IconButton(
            tooltip: '刷新状态',
            visualDensity: compact ? VisualDensity.compact : null,
            onPressed: busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
      ],
    );
  }

  Widget _buildAdminStatsGrid(Map<String, dynamic> stats) =>
      AdminTelemetryBentoGrid(
        stats: stats,
        cpuHistory: _cpuHistory,
        netHistory: _netHistory,
      );

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
            buildIslePageRoute<void>(
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
                onOpenDownloads: widget.isAdmin ? null : _openDownloadsPage,
                onOpenComputerFiles: (widget.isAdmin || _computerFilesAvailable)
                    ? () => Navigator.of(context).push<void>(
                        buildIslePageRoute(
                          builder: (_) => ComputerFilesPage(
                            api: widget.api,
                            isAdmin: widget.isAdmin,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 10),
              _buildOverviewQuickJumpStrip(context),
              SizedBox(height: compact ? 6 : 12),
              ValueListenableBuilder<bool>(
                valueListenable: _busyNotifier,
                builder: (_, busy, _) {
                  if (!busy ||
                      (widget.isAdmin
                          ? stats != null
                          : _personalStorage != null)) {
                    return const SizedBox.shrink();
                  }
                  return const IsleLoadingState(label: '正在同步设备与空间状态…');
                },
              ),
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
                RepaintBoundary(child: _buildAdminStatsGrid(stats)),
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

  Widget _buildOverviewQuickJumpStrip(BuildContext context) {
    return IsleQuickJumpStrip(
      key: const ValueKey('overviewQuickJumpStrip'),
      items: [
        IsleQuickJumpItem(
          icon: Icons.storage_rounded,
          label: widget.isAdmin ? '存储与成员配额' : '我的存储与额度',
          tooltip: widget.isAdmin ? '管理存储位置、物理盘及成员每盘配额' : '查看各硬盘额度与分类占用',
          onTap: () => Navigator.of(context).push<void>(
            buildIslePageRoute(
              builder: (_) =>
                  StoragePage(api: widget.api, isAdmin: widget.isAdmin),
            ),
          ),
        ),
        IsleQuickJumpItem(
          icon: Icons.folder_shared_outlined,
          label: 'WebDAV 挂载连接',
          tooltip: '获取 WebDAV 挂载地址并管理独立访问密码',
          onTap: () => Navigator.of(context).push<void>(
            buildIslePageRoute(builder: (_) => DavPage(api: widget.api)),
          ),
        ),
        IsleQuickJumpItem(
          icon: Icons.file_copy_outlined,
          label: '重复大文件清理',
          tooltip: '扫描重复大文件并按比例清理释放磁盘空间',
          onTap: () => Navigator.of(context).push<void>(
            buildIslePageRoute(
              builder: (_) => DuplicateFilesPage(api: widget.api),
            ),
          ),
        ),
        if (widget.isAdmin) ...[
          IsleQuickJumpItem(
            icon: Icons.lan_outlined,
            label: 'Mac 文件共享 (SMB)',
            tooltip: '管理局域网 SMB 文件共享与访客权限',
            onTap: () => Navigator.of(context).push<void>(
              buildIslePageRoute(builder: (_) => AdminSmbPage(api: widget.api)),
            ),
          ),
          IsleQuickJumpItem(
            icon: Icons.terminal_rounded,
            label: '本机脚本自动化',
            tooltip: '管理本地调度脚本、Cron 规则与执行日志',
            onTap: () => Navigator.of(context).push<void>(
              buildIslePageRoute(
                builder: (_) => AutomationPage(api: widget.api),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
