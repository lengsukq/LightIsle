import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/shell_storage_state.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/computer_files_page.dart';
import '../files/downloads_page.dart';
import '../files/file_shares_page.dart';
import '../media/document_scan_archive_page.dart';
import '../settings/apps_center_helpers.dart';
import '../settings/apps_center_page.dart';
import 'dashboard_role_widgets.dart';
import 'family_board_card.dart';
import 'family_reminders_card.dart';
import 'overview_apps_tiles.dart';
import 'overview_header_and_banners.dart';
import 'overview_telemetry_grid.dart';
import 'storage_volume_browser.dart';

export 'dashboard_role_widgets.dart' show TaskTile, taskName, taskStatus;
export 'task_history_page.dart' show TaskHistoryPage;

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.api,
    required this.isAdmin,
    this.accountId,
    this.storageHandle,
    this.onNavigate,
    this.onBrowseDirectory,
    this.onOpenFiles,
    this.appUrlLauncher,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String? accountId;
  final ShellStorageHandle? storageHandle;
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
    _attachStorageHandle(widget.storageHandle);
  }

  void _attachStorageHandle(ShellStorageHandle? handle) {
    if (handle == null) return;
    _applySharedStorage(handle.value, notify: false);
    // ClientShell already initiates root & personal storage discovery on mount;
    // avoid issuing a duplicate request immediately on first Overview refresh.
    _lastRootCheck = DateTime.now();
    handle.addListener(_onSharedStorageChanged);
  }

  void _onSharedStorageChanged() {
    final handle = widget.storageHandle;
    if (handle == null || !mounted) return;
    _applySharedStorage(handle.value, notify: true);
  }

  void _applySharedStorage(
    ShellStorageSnapshot snapshot, {
    required bool notify,
  }) {
    final nextRoots = snapshot.roots;
    final nextPersonal = snapshot.personalStorage;
    final nextRootsError = snapshot.rootsError;
    final nextError = !widget.isAdmin && snapshot.hasFetched
        ? (nextPersonal == null ? nextRootsError : null)
        : _error;
    final changed =
        !_overviewRootsEqual(_roots, nextRoots) ||
        !_overviewJsonEqual(_personalStorage, nextPersonal) ||
        _rootsError != nextRootsError ||
        _error != nextError;
    if (!changed) return;
    void apply() {
      _roots = nextRoots;
      _personalStorage = nextPersonal;
      _rootsError = nextRootsError;
      if (!widget.isAdmin && snapshot.hasFetched) {
        _error = nextError;
      }
      if (snapshot.hasFetched) {
        _lastRootCheck = DateTime.now();
      }
    }

    if (notify && mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  @override
  void didUpdateWidget(covariant OverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageHandle != widget.storageHandle) {
      oldWidget.storageHandle?.removeListener(_onSharedStorageChanged);
      _attachStorageHandle(widget.storageHandle);
    }
    if (oldWidget.isAdmin != widget.isAdmin || oldWidget.api != widget.api) {
      _cpuHistory = const [];
      _netHistory = const [];
      _lastRootCheck = widget.storageHandle != null ? DateTime.now() : null;
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
      unawaited(_refresh());
      _timer = Timer.periodic(
        Duration(seconds: widget.isAdmin ? 5 : 60),
        (_) => unawaited(_refresh()),
      );
    }
  }

  Future<void> _refresh({bool forceStorage = false}) async {
    if (_busy) return;
    _busyNotifier.value = true;
    final sharedHandle = widget.storageHandle;
    final now = DateTime.now();

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

    final pending = <Future<void>>[];

    if (widget.isAdmin) {
      pending.add(() async {
        try {
          nextStats = await widget.api.get('/api/v2/system');
          nextError = null;
        } catch (e) {
          nextError = userFacingError(e);
        }
      }());
      pending.add(() async {
        try {
          final result = await widget.api.get('/api/v2/tasks');
          nextTasks = objectList(result['tasks']);
          nextTaskError = null;
        } catch (e) {
          nextTaskError = userFacingError(e);
        }
      }());
    } else {
      if (sharedHandle == null) {
        pending.add(() async {
          try {
            nextPersonalStorage = await widget.api.get('/api/v2/me/storage');
            nextError = null;
          } catch (e) {
            nextError = userFacingError(e);
          }
        }());
      }
      if (forceStorage ||
          _lastComputerFilesCheck == null ||
          now.difference(_lastComputerFilesCheck!) >=
              const Duration(seconds: 60)) {
        _lastComputerFilesCheck = now;
        pending.add(() async {
          try {
            final status = await widget.api.get(
              '/api/v2/computer-files/status',
            );
            nextComputerFilesAvailable =
                status['enabled'] == true &&
                (status['mode']?.toString() ?? 'none') != 'none';
          } catch (error) {
            debugPrint(
              'OverviewPage computer-files status probe failed: $error',
            );
            _lastComputerFilesCheck = null;
          }
        }());
      }
    }

    final shouldRefreshRoots =
        forceStorage ||
        _lastRootCheck == null ||
        now.difference(_lastRootCheck!) >= const Duration(seconds: 30);
    if (shouldRefreshRoots) {
      _lastRootCheck = now;
      if (sharedHandle != null) {
        pending.add(() async {
          await sharedHandle.refresh();
          final snapshot = sharedHandle.value;
          nextRoots = snapshot.roots;
          nextPersonalStorage = snapshot.personalStorage;
          nextRootsError = snapshot.rootsError;
          if (!widget.isAdmin && snapshot.hasFetched) {
            nextError = nextPersonalStorage == null ? nextRootsError : null;
          }
        }());
      } else {
        pending.add(() async {
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
        }());
      }
    }

    if (forceStorage ||
        _lastAppsCheck == null ||
        now.difference(_lastAppsCheck!) >= const Duration(seconds: 30)) {
      _lastAppsCheck = now;
      pending.add(() async {
        try {
          final response = await widget.api.get('/api/v2/apps');
          nextApps = objectList(response['apps']);
          nextAppsLoaded = true;
          nextAppsError = null;
        } catch (e) {
          nextAppsLoaded = true;
          nextAppsError = userFacingError(e);
        }
      }());
    }

    await Future.wait<void>(pending);

    if (!mounted) {
      _busyNotifier.value = false;
      return;
    }
    if (sharedHandle != null) {
      final latest = sharedHandle.value;
      nextRoots = latest.roots;
      nextPersonalStorage = latest.personalStorage;
      nextRootsError = latest.rootsError;
      if (!widget.isAdmin && latest.hasFetched) {
        nextError = nextPersonalStorage == null ? nextRootsError : null;
      }
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
          _recordTelemetrySample(nextStats!);
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
    widget.storageHandle?.removeListener(_onSharedStorageChanged);
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

  void _openDocumentScanArchive() {
    Navigator.of(context).push<void>(
      buildIslePageRoute(
        builder: (_) => DocumentScanArchivePage(
          api: widget.api,
          personalStorage: _personalStorage,
          roots: _roots,
          isAdmin: widget.isAdmin,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final coreRss = stats?['coreRssBytes'] as num?;
    final hostname = stats?['hostname']?.toString().trim() ?? '';
    final palette = IslePalette.of(context);

    return RefreshIndicator(
      onRefresh: () => _refresh(forceStorage: true),
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
            onOpenDownloads: widget.isAdmin ? _openDownloadsPage : null,
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

          final familyBoardSection = FamilyBoardSection(
            api: widget.api,
            isAdmin: widget.isAdmin,
          );

          final familyRemindersSection = FamilyRemindersSection(
            api: widget.api,
            isAdmin: widget.isAdmin,
          );

          final documentScanShortcut = OverviewDocumentScanShortcut(
            onTap: _openDocumentScanArchive,
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
              final loadingShared = widget.storageHandle?.value.loading == true;
              if ((!busy && !loadingShared) ||
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
                  onRetry: () => unawaited(_refresh(forceStorage: true)),
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
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        )
                      : null,
                ),
                RepaintBoundary(
                  child: AdminTelemetryBentoGrid(
                    stats: stats,
                    cpuHistory: _cpuHistory,
                    netHistory: _netHistory,
                  ),
                ),
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

          final adminTasksSection = widget.isAdmin
              ? OverviewAdminTasksSection(
                  api: widget.api,
                  tasks: _tasks,
                  taskError: _taskError,
                  onRefresh: _refresh,
                )
              : null;

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(inset, topInset, inset, inset + 54),
            children: [
              IslePageHeader(
                accentColor: widget.isAdmin
                    ? palette['brandBlue']
                    : palette['brandAmber'],
                title: widget.isAdmin ? '这台 Mac' : '我的家庭空间',
                trailing: OverviewHeaderTrailing(
                  api: widget.api,
                  isAdmin: widget.isAdmin,
                  accountId: widget.accountId,
                  onOpenFiles: widget.onOpenFiles,
                  onRefresh: () => unawaited(_refresh(forceStorage: true)),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: compact ? 8 : 12),
                child: OverviewSanctuaryHero(
                  isAdmin: widget.isAdmin,
                  hostname: hostname,
                  stats: stats,
                  personalStorage: _personalStorage,
                  roots: _roots,
                  tasks: _tasks,
                  error: _error,
                ),
              ),
              OverviewAttentionBanner(
                api: widget.api,
                isAdmin: widget.isAdmin,
                accountId: widget.accountId,
                roots: _roots,
                tasks: _tasks,
                personalStorage: _personalStorage,
                busyListenable: _busyNotifier,
                onRefresh: () => unawaited(_refresh(forceStorage: true)),
              ),
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
                          familyBoardSection,
                          const SizedBox(height: 10),
                          homeAppsSection,
                          const SizedBox(height: 10),
                          familyRemindersSection,
                          const SizedBox(height: 10),
                          documentScanShortcut,
                          ?adminTasksSection,
                        ],
                      ),
                    ),
                  ],
                )
              else ...[
                quickLinksSection,
                const SizedBox(height: 8),
                familyBoardSection,
                const SizedBox(height: 8),
                homeAppsSection,
                SizedBox(height: compact ? 6 : 10),
                telemetryAndStorage,
                const SizedBox(height: 8),
                familyRemindersSection,
                const SizedBox(height: 8),
                documentScanShortcut,
                ?adminTasksSection,
              ],
            ],
          );
        },
      ),
    );
  }
}
