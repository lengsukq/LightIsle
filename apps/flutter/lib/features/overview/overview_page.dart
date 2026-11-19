import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../core/isle_action_menu.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import '../files/computer_files_page.dart';
import '../files/downloads_page.dart';
import '../files/duplicate_files_page.dart';
import '../files/file_shares_page.dart';
import '../settings/admin_smb_page.dart';
import '../settings/apps_center_helpers.dart';
import '../settings/apps_center_page.dart';
import '../settings/automation_page.dart';
import '../settings/dav_page.dart';
import '../settings/storage_page.dart';
import 'dashboard_role_widgets.dart';
import 'overview_apps_tiles.dart';
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
    this.appUrlLauncher,
  });
  final LightIsleApi api;
  final bool isAdmin;
  final ValueChanged<int>? onNavigate;
  final OpenStorageDirectory? onBrowseDirectory;
  final VoidCallback? onOpenFiles;
  final Future<bool> Function(Uri uri, {LaunchMode mode})? appUrlLauncher;
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
  DateTime? _lastAppsCheck;
  bool _computerFilesAvailable = false;
  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _apps = const [];
  bool _appsLoaded = false;
  String? _error, _taskError, _appsError;
  String? _launchingHomeAppId;
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
      _lastAppsCheck = null;
      _apps = const [];
      _appsLoaded = false;
      _appsError = null;
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
    var nextApps = _apps;
    var nextAppsLoaded = _appsLoaded;
    var nextError = _error;
    var nextTaskError = _taskError;
    var nextAppsError = _appsError;

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
    if (_lastAppsCheck == null ||
        now.difference(_lastAppsCheck!) >= const Duration(seconds: 30)) {
      _lastAppsCheck = now;
      try {
        final response = await widget.api.get('/api/v2/apps');
        nextApps = objectList(response['apps']);
        nextAppsLoaded = true;
        nextAppsError = null;
      } catch (e) {
        nextAppsLoaded = true;
        nextAppsError = userFacingError(e);
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
        !_overviewJsonEqual(_apps, nextApps) ||
        _appsLoaded != nextAppsLoaded ||
        _error != nextError ||
        _taskError != nextTaskError ||
        _appsError != nextAppsError;
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
        _apps = nextApps;
        _appsLoaded = nextAppsLoaded;
        _error = nextError;
        _taskError = nextTaskError;
        _appsError = nextAppsError;
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
      final h = parsed.hour.toString().padLeft(2, '0');
      final min = parsed.minute.toString().padLeft(2, '0');
      final s = parsed.second.toString().padLeft(2, '0');
      return '$h:$min:$s';
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

  Future<void> _openAppsCenterPage({String? launchAppId}) async {
    await Navigator.of(context).push<void>(
      buildIslePageRoute(
        builder: (_) => AppsCenterPage(
          api: widget.api,
          isAdmin: widget.isAdmin,
          initialApps: _apps.isNotEmpty ? _apps : null,
          initialLaunchAppId: launchAppId,
          urlLauncher: widget.appUrlLauncher,
        ),
      ),
    );
    _lastAppsCheck = null;
    if (mounted) unawaited(_refresh());
  }

  void _openAppFromHome(Map<String, dynamic> app) {
    final id = app['id']?.toString() ?? '';
    final ready = id.isNotEmpty && isHomeAppReady(app);
    if (!ready) {
      unawaited(_openAppsCenterPage());
      return;
    }
    unawaited(_launchHomeAppDirectly(app));
  }

  Future<void> _launchHomeAppDirectly(Map<String, dynamic> app) async {
    final id = app['id']?.toString() ?? '';
    final name = app['name']?.toString() ?? id;
    if (id.isEmpty || _launchingHomeAppId != null) return;
    setState(() => _launchingHomeAppId = id);
    try {
      await launchLightIsleApp(
        api: widget.api,
        appId: id,
        urlLauncher: widget.appUrlLauncher,
      );
      if (mounted) {
        _lastAppsCheck = null;
        unawaited(_refresh());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('打开「$name」失败：${userFacingError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _launchingHomeAppId = null);
    }
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
      padding: const EdgeInsets.only(bottom: 12),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        radius: IsleRadius.md,
        tint: scheme.error,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 520 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.25;
            final compactTextBtn = TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
            final actions = <Widget>[
              if (offlineRoots.isNotEmpty)
                TextButton(
                  style: compactTextBtn,
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
                  style: compactTextBtn,
                  onPressed: busy ? null : _refresh,
                  child: const Text('重新检查'),
                ),
              ),
            ];
            final messageWidget = Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
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
                        size: 19,
                      ),
                      const SizedBox(width: 9),
                      Expanded(child: messageWidget),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 4, children: actions),
                ],
              );
            }
            return Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.error, size: 19),
                const SizedBox(width: 10),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onOpenFiles != null)
          FilledButton.icon(
            key: const ValueKey('headerOpenFilesButton'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(38, 36),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: widget.onOpenFiles,
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('文件管理'),
          ),
        const SizedBox(width: 2),
        PopupMenuButton<String>(
          tooltip: '更多工具',
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
          style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
          position: PopupMenuPosition.under,
          shape: IsleShapes.md(
            side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1),
          ),
          onSelected: (value) {
            switch (value) {
              case 'refresh':
                _refresh();
              case 'storage':
                Navigator.of(context).push<void>(
                  buildIslePageRoute(
                    builder: (_) =>
                        StoragePage(api: widget.api, isAdmin: widget.isAdmin),
                  ),
                );
              case 'dav':
                Navigator.of(context).push<void>(
                  buildIslePageRoute(builder: (_) => DavPage(api: widget.api)),
                );
              case 'duplicates':
                Navigator.of(context).push<void>(
                  buildIslePageRoute(
                    builder: (_) => DuplicateFilesPage(api: widget.api),
                  ),
                );
              case 'smb':
                Navigator.of(context).push<void>(
                  buildIslePageRoute(
                    builder: (_) => AdminSmbPage(api: widget.api),
                  ),
                );
              case 'automation':
                Navigator.of(context).push<void>(
                  buildIslePageRoute(
                    builder: (_) => AutomationPage(api: widget.api),
                  ),
                );
            }
          },
          itemBuilder: (_) => [
            isleActionMenuItem(
              value: 'refresh',
              icon: Icons.refresh_rounded,
              label: '刷新状态',
            ),
            const PopupMenuDivider(),
            isleActionMenuItem(
              value: 'storage',
              icon: Icons.storage_rounded,
              label: widget.isAdmin ? '存储与成员配额' : '我的存储空间',
            ),
            isleActionMenuItem(
              value: 'dav',
              icon: Icons.folder_shared_outlined,
              label: 'WebDAV 挂载连接',
            ),
            isleActionMenuItem(
              value: 'duplicates',
              icon: Icons.cleaning_services_outlined,
              label: '重复大文件清理',
            ),
            if (widget.isAdmin) ...[
              isleActionMenuItem(
                value: 'smb',
                icon: Icons.lan_outlined,
                label: 'Mac 文件共享 (SMB)',
              ),
              isleActionMenuItem(
                value: 'automation',
                icon: Icons.terminal_rounded,
                label: '本机脚本自动化',
              ),
            ],
          ],
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
    final palette = IslePalette.of(context);
    return [
      IsleSectionHeader(
        title: '任务中心',
        accentColor: palette['brandViolet'],
        action: TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(36, 28),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: () => Navigator.of(context).push(
            buildIslePageRoute<void>(
              builder: (_) => TaskHistoryPage(api: widget.api),
            ),
          ),
          child: const Text('查看历史', style: TextStyle(fontSize: 12.5)),
        ),
      ),
      if (_taskError != null)
        Notice('任务状态更新失败：$_taskError', error: true, onRetry: _refresh),
      if (_tasks.isEmpty && _taskError == null)
        const Notice('暂无后台任务。可在图库或影视中开始扫描。'),
      if (_tasks.isNotEmpty)
        IsleResponsiveGrid(
          minItemWidth: 260,
          maxColumns: 3,
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final task in _tasks)
              TaskTile(api: widget.api, task: task, onChanged: _refresh),
          ],
        ),
    ];
  }

  Widget _buildSanctuaryFocalHero(
    BuildContext context, {
    required Map<String, dynamic>? stats,
    required String hostname,
  }) {
    final palette = IslePalette.of(context);
    final onlineRoots = _roots.where((r) => r.online).length;
    final runningTasks = _tasks.where((t) => t['running'] == true).length;
    final memberLocations = objectList(_personalStorage?['locations']).length;

    final statusLabel = _error != null
        ? '待检查'
        : (widget.isAdmin ? stats != null : _personalStorage != null)
        ? '在线运行'
        : '检查中';
    final statusTone = _error != null
        ? Theme.of(context).colorScheme.error
        : (widget.isAdmin ? stats != null : _personalStorage != null)
        ? palette['brandSage']
        : palette['brandAmber'];

    final metrics = widget.isAdmin
        ? <IsleFocalMetric>[
            if (_roots.isNotEmpty)
              IsleFocalMetric(
                label: '在线磁盘',
                value: '$onlineRoots / ${_roots.length}',
                icon: Icons.dns_rounded,
                color: palette['brandSage'],
              ),
            if (stats != null && stats['cpuPercent'] is num)
              IsleFocalMetric(
                label: 'CPU 负载',
                value: '${(stats['cpuPercent'] as num).toStringAsFixed(1)}%',
                icon: Icons.memory_rounded,
                color: palette['brandBlue'],
              ),
            IsleFocalMetric(
              label: '后台任务',
              value: runningTasks > 0 ? '$runningTasks 运行中' : '空闲',
              icon: Icons.auto_mode_rounded,
              color: palette['brandAmber'],
            ),
          ]
        : <IsleFocalMetric>[
            IsleFocalMetric(
              label: '个人目录',
              value: '$memberLocations 个',
              icon: Icons.folder_special_rounded,
              color: palette['brandAmber'],
            ),
            IsleFocalMetric(
              label: '在线磁盘',
              value: '$onlineRoots 块',
              icon: Icons.storage_rounded,
              color: palette['brandSage'],
            ),
          ];

    return IsleFocalStage(
      title: hostname.isNotEmpty
          ? hostname
          : (widget.isAdmin ? '家里的 Mac' : '我的家庭空间'),
      subtitle: _error != null ? '设备状态暂时无法确认，请检查连接' : '',
      icon: widget.isAdmin ? Icons.desktop_mac_rounded : Icons.cottage_rounded,
      accent: widget.isAdmin ? palette['brandBlue'] : palette['brandAmber'],
      statusBadge: IsleStatusBadge(label: statusLabel, color: statusTone),
      metrics: metrics,
      margin: EdgeInsets.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final coreRss = stats?['coreRssBytes'] as num?;
    final hostname = stats?['hostname']?.toString().trim() ?? '';
    final palette = IslePalette.of(context);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final inset = IsleLayout.pageInset(width);
          final topInset = IsleLayout.pageTopInset(width);
          final compact = width < IsleLayout.compactPageWidth;
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final desktopSplit = width >= 1040 && textScale <= 1.3;

          final quickLinksSection = DashboardQuickLinks(
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
          );

          final homeAppsSection = HomeAppsTileSection(
            apps: _apps,
            isAdmin: widget.isAdmin,
            loaded: _appsLoaded,
            error: _appsError,
            onOpenApp: _openAppFromHome,
            onOpenAppsCenter: () => _openAppsCenterPage(),
            onRetry: () {
              _lastAppsCheck = null;
              unawaited(_refresh());
            },
          );

          final statusLoading = ValueListenableBuilder<bool>(
            valueListenable: _busyNotifier,
            builder: (_, busy, _) {
              if (!busy ||
                  (widget.isAdmin ? stats != null : _personalStorage != null)) {
                return const SizedBox.shrink();
              }
              return const IsleLoadingState(
                compact: true,
                label: '正在同步设备与空间状态…',
              );
            },
          );

          final errorNotice = _error != null
              ? Notice(
                  '无法更新服务状态：$_error${stats == null ? '' : '\n以下为上一次成功采样。'}',
                  onRetry: _refresh,
                  error: true,
                )
              : null;

          final telemetryAndStorage = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              statusLoading,
              ?errorNotice,
              if (!widget.isAdmin && _personalStorage != null) ...[
                const SizedBox(height: 4),
                MemberStorageSummary(storage: _personalStorage!),
                MemberStorageBrowser(
                  storage: _personalStorage!,
                  roots: _roots,
                  onOpen: widget.onBrowseDirectory,
                ),
              ],
              if (widget.isAdmin && stats != null) ...[
                IsleSectionHeader(
                  title: '实时负载',
                  accentColor: palette['brandBlue'],
                  action: (coreRss != null || stats['timestamp'] != null)
                      ? Text(
                          [
                            if (coreRss != null) '内存 ${formatBytes(coreRss)}',
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
            ],
          );

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(inset, topInset, inset, inset + 54),
            children: [
              IslePageHeader(
                accentColor: widget.isAdmin
                    ? palette['brandBlue']
                    : palette['brandAmber'],
                title: widget.isAdmin ? '这台 Mac' : '我的家庭空间',
                trailing: _buildHeaderTrailing(compact: compact),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: compact ? 8 : 12),
                child: _buildSanctuaryFocalHero(
                  context,
                  stats: stats,
                  hostname: hostname,
                ),
              ),
              if (widget.isAdmin) _buildAttentionBanner(context),
              if (desktopSplit)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          quickLinksSection,
                          const SizedBox(height: 8),
                          telemetryAndStorage,
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          homeAppsSection,
                          if (widget.isAdmin) ..._buildAdminTasksSection(context),
                        ],
                      ),
                    ),
                  ],
                )
              else ...[
                quickLinksSection,
                const SizedBox(height: 8),
                homeAppsSection,
                SizedBox(height: compact ? 6 : 10),
                telemetryAndStorage,
                if (widget.isAdmin) ..._buildAdminTasksSection(context),
              ],
            ],
          );
        },
      ),
    );
  }
}
