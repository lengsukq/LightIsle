import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'app_detail_page.dart';
import 'apps_center_helpers.dart';
import 'apps_center_sheets.dart';

export 'app_detail_page.dart';
export 'apps_center_sheets.dart';

part 'apps_center_cards.dart';
part 'apps_center_storage_card.dart';
part 'apps_center_store_card.dart';

class AppsCenterPage extends StatefulWidget {
  const AppsCenterPage({
    super.key,
    required this.api,
    this.isAdmin,
    this.initialLaunchAppId,
    this.initialApps,
    this.urlLauncher,
    @visibleForTesting this.pickBackupSavePath,
  });

  final LightIsleApi api;
  final bool? isAdmin;
  final String? initialLaunchAppId;
  final List<Map<String, dynamic>>? initialApps;
  final Future<bool> Function(Uri uri, {LaunchMode mode})? urlLauncher;
  @visibleForTesting
  final Future<String?> Function(String defaultFileName)? pickBackupSavePath;

  @override
  State<AppsCenterPage> createState() => _AppsCenterPageState();
}

class _AppsCenterPageState extends State<AppsCenterPage> {
  List<Map<String, dynamic>> _apps = const [];
  List<Map<String, dynamic>> _templates = const [];
  Map<String, dynamic>? _store;
  List<Map<String, dynamic>> _members = const [];
  Map<String, dynamic>? _appStorage;
  String _selectedInstallLocationId = '';
  String _storeCategoryFilter = 'all';
  Set<String> _configuredChannels = const {};
  bool _isAdmin = false, _busy = false, _storeBusy = false;
  bool _loaded = false, _workbenchFullscreen = false, _autoRefreshedStore = false;
  String? _wakingAppId,
      _pendingInitialLaunchAppId,
      _activeWorkbenchAppId,
      _activeWorkbenchUrl,
      _error,
      _notice;
  int _workbenchReloadKey = 0;

  @override
  void initState() {
    super.initState();
    _isAdmin = widget.isAdmin ?? false;
    _pendingInitialLaunchAppId = widget.initialLaunchAppId;
    if (widget.initialApps != null && widget.initialApps!.isNotEmpty) {
      _apps = widget.initialApps!;
    }
    _reload(refresh: false);
  }

  @override
  void didUpdateWidget(covariant AppsCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.isAdmin != widget.isAdmin) {
      _isAdmin = widget.isAdmin ?? false;
      _pendingInitialLaunchAppId = widget.initialLaunchAppId;
      _activeWorkbenchAppId = null;
      _activeWorkbenchUrl = null;
      _loaded = false;
      _store = null;
      _autoRefreshedStore = false;
      _selectedInstallLocationId = '';
      _storeCategoryFilter = 'all';
      unawaited(_reload(refresh: false));
    } else if (oldWidget.initialLaunchAppId != widget.initialLaunchAppId) {
      _pendingInitialLaunchAppId = widget.initialLaunchAppId;
      _consumeInitialLaunchIfReady();
    }
  }

  void _updateState(VoidCallback fn) => setState(fn);

  void _applySnapshot(Map<String, dynamic> res) {
    final channelsRaw = res['configuredChannels'];
    var shouldAutoRefreshStore = false;
    setState(() {
      if (res['apps'] is List) _apps = objectList(res['apps']);
      if (res['templates'] is List) _templates = objectList(res['templates']);
      if (res['store'] is Map) {
        _store = Map<String, dynamic>.from(res['store'] as Map);
      }
      if (res['members'] is List) _members = objectList(res['members']);
      if (channelsRaw is List) {
        _configuredChannels = {
          for (final item in channelsRaw)
            if (item.toString().isNotEmpty) item.toString(),
        };
      }
      if (res['appStorage'] is Map) {
        _appStorage = Map<String, dynamic>.from(res['appStorage'] as Map);
        final locations = objectList(_appStorage?['locations']);
        final selectedAvailable =
            _selectedInstallLocationId.isEmpty ||
            locations.any(
              (loc) =>
                  loc['id']?.toString() == _selectedInstallLocationId &&
                  loc['online'] == true &&
                  loc['writable'] == true,
            );
        if (!selectedAvailable) {
          _selectedInstallLocationId = '';
        }
      }
      if (res['isAdmin'] is bool) _isAdmin = res['isAdmin'] as bool;
      _loaded = true;
      if (_isAdmin &&
          !_autoRefreshedStore &&
          _store != null &&
          _store!['source'] == 'empty' &&
          objectList(_store!['plugins']).isEmpty) {
        _autoRefreshedStore = true;
        shouldAutoRefreshStore = true;
      }
    });
    _consumeInitialLaunchIfReady();
    if (shouldAutoRefreshStore) {
      unawaited(_refreshStore(silentNotice: true));
    }
  }

  void _consumeInitialLaunchIfReady() {
    final targetId = _pendingInitialLaunchAppId?.trim() ?? '';
    if (targetId.isEmpty || !_loaded || _wakingAppId != null) return;
    _pendingInitialLaunchAppId = null;
    Map<String, dynamic>? target;
    for (final app in _apps) {
      if (app['id']?.toString() == targetId) {
        target = app;
        break;
      }
    }
    if (target == null) return;
    if (!isHomeAppReady(target) || !isHomeAppWebEnabled(target)) return;
    unawaited(_launchApp(target));
  }

  Future<void> _runBusy(
    String errorPrefix,
    Future<void> Function() task,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await task();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$errorPrefix：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshDiagnosticSnapshot() async {
    if (!_isAdmin) return;
    try {
      final res = await widget.api.get('/api/v2/apps');
      if (mounted) _applySnapshot(res);
    } catch (error) {
      debugPrint('AppsCenterPage._refreshDiagnosticSnapshot failed: $error');
    }
  }

  Future<void> _reload({required bool refresh}) =>
      _runBusy('加载应用中心失败', () async {
        final res = refresh
            ? await widget.api.send('POST', '/api/v2/apps/refresh')
            : await widget.api.get('/api/v2/apps');
        if (mounted) _applySnapshot(res);
      });

  Future<void> _launchApp(
    Map<String, dynamic> app, {
    bool preferExternal = false,
  }) async {
    final id = app['id']?.toString() ?? '';
    if (id.isEmpty || _wakingAppId != null) return;
    setState(() {
      _wakingAppId = id;
      _error = null;
      _notice = null;
    });
    try {
      final launched = await launchLightIsleApp(
        api: widget.api,
        appId: id,
        preferExternal: preferExternal,
        urlLauncher: widget.urlLauncher,
      );
      if (!mounted) return;
      final refreshed = await widget.api.get('/api/v2/apps');
      if (mounted) {
        _applySnapshot(refreshed);
        setState(() {
          _activeWorkbenchAppId = id;
          _activeWorkbenchUrl = launched.displayUri.toString();
          _workbenchReloadKey++;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '打开应用失败：${userFacingError(e)}');
        unawaited(_refreshDiagnosticSnapshot());
      }
    } finally {
      if (mounted) setState(() => _wakingAppId = null);
    }
  }

  Future<void> _performAction(Map<String, dynamic> app, String action) async {
    final id = app['id']?.toString() ?? '';
    if (id.isEmpty) return;
    await _runBusy('操作未完成', () async {
      try {
        final res = await widget.api.send(
          'POST',
          '/api/v2/apps/${Uri.encodeComponent(id)}/action',
          body: {'action': action},
        );
        if (!mounted) return;
        final snap = res['apps'] is List
            ? res
            : await widget.api.get('/api/v2/apps');
        if (mounted) _applySnapshot(snap);
      } catch (e) {
        if (mounted) unawaited(_refreshDiagnosticSnapshot());
        rethrow;
      }
    });
  }

  Future<void> _refreshStore({bool silentNotice = false}) async {
    if (!_isAdmin || _storeBusy) return;
    setState(() {
      _storeBusy = true;
      if (!silentNotice) {
        _error = null;
        _notice = null;
      }
    });
    try {
      final res = await widget.api.send('POST', '/api/v2/apps/store/refresh');
      if (!mounted) return;
      _applySnapshot(res);
      if (!silentNotice) {
        final count = objectList(_store?['plugins']).length;
        setState(() => _notice = '已从 Git 在线商店同步最新目录（共 $count 款应用）。');
      }
    } catch (e) {
      if (mounted && !silentNotice) {
        setState(() => _error = '刷新在线插件商店失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _storeBusy = false);
    }
  }

  Future<void> _updateStoreConfig({
    required String registryUrl,
    required String mirrorPrefix,
    required bool resetDefault,
  }) async {
    if (!_isAdmin || _busy || _storeBusy) return;
    await _runBusy('保存插件商店配置失败', () async {
      final res = await widget.api.send(
        'PUT',
        '/api/v2/apps/store/config',
        body: <String, dynamic>{
          'registryUrl': registryUrl,
          'mirrorPrefix': mirrorPrefix,
          'resetDefault': resetDefault,
        },
      );
      if (!mounted) return;
      _applySnapshot(res);
      setState(() {
        _notice = resetDefault
            ? '已恢复官方默认 Git 插件商店并刷新目录。'
            : '已保存 Git 插件商店源与镜像配置并同步目录。';
      });
    });
  }

  Future<void> _installStorePlugin(Map<String, dynamic> plugin) async {
    final id = plugin['id']?.toString() ?? '';
    final name = plugin['name']?.toString() ?? id;
    if (id.isEmpty || _busy) return;
    final endpoint = _store != null
        ? '/api/v2/apps/store/${Uri.encodeComponent(id)}/install'
        : '/api/v2/apps/templates/${Uri.encodeComponent(id)}/install';
    await _runBusy('下载安装插件失败', () async {
      final res = await widget.api.send(
        'POST',
        endpoint,
        body: _selectedInstallLocationId.isEmpty
            ? const <String, dynamic>{}
            : <String, dynamic>{'locationId': _selectedInstallLocationId},
      );
      if (!mounted) return;
      _applySnapshot(res);
      final pending =
          res['app'] is Map && (res['app'] as Map)['pendingActivation'] == true;
      setState(
        () => _notice = pending
            ? '已从在线商店下载并校验「$name」，请确认安全后点击「确认激活」。'
            : '已从在线商店校验 SHA-256 并安装「$name」。',
      );
    });
  }

  Future<void> _upgradeStorePlugin(Map<String, dynamic> plugin) async {
    final id = plugin['id']?.toString() ?? '';
    final name = plugin['name']?.toString() ?? id;
    final nextVer = plugin['version']?.toString() ?? '';
    final curVer = plugin['installedVersion']?.toString() ?? '';
    if (id.isEmpty || _busy) return;
    final confirmed = await confirmAction(
      context,
      '确认升级轻应用「$name」？',
      '将从 ${curVer.isEmpty ? '当前版本' : 'v$curVer'} 原地升级至 v$nextVer。升级过程会强制校验 SHA-256，仅替换应用代码，不会删除业务数据目录（plugin-data）、env.json 与成员访问权限。',
      action: '校验并升级',
    );
    if (!confirmed || !mounted) return;
    await _runBusy('升级轻应用失败', () async {
      final res = await widget.api.send(
        'POST',
        '/api/v2/apps/store/${Uri.encodeComponent(id)}/upgrade',
      );
      if (!mounted) return;
      _applySnapshot(res);
      setState(() => _notice = '已原地升级「$name」至 v$nextVer，原有业务数据已完整保留。');
    });
  }

  Future<void> _mutateAppStorage(Map<String, dynamic> payload) async {
    final action = payload['action']?.toString() ?? '';
    if (_busy || action.isEmpty) return;
    if (action == 'remove_external') {
      final confirmed = await confirmAction(
        context,
        '移除其他盘应用存储登记',
        '系统会先停止来自该位置的应用进程，但绝不会删除硬盘上的插件源码或业务数据。',
        action: '确认移除',
        isDestructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    await _runBusy('更新应用存储位置失败', () async {
      final res = await widget.api.send(
        'PUT',
        '/api/v2/apps/storage',
        body: payload,
      );
      if (!mounted) return;
      _applySnapshot(res);
      final notice = switch (action) {
        'set_default' => '已更新新建与安装应用的默认存储位置。',
        'reset_internal' => '已恢复 Mac 内置盘为系统默认目录。',
        'remove_external' => '已安全移除其他盘登记（硬盘原有文件已保留）。',
        'add' => '已添加其他盘应用存储位置。',
        _ => '已更新应用数据存储位置。',
      };
      setState(() => _notice = notice);
    });
  }

  void _openAppDetailPage(Map<String, dynamic> app) {
    final name = app['name']?.toString() ?? app['id']?.toString() ?? '轻应用';
    unawaited(
      Navigator.of(context).push<void>(
        buildIslePageRoute<void>(
          builder: (_) => AppDetailPage(
            api: widget.api,
            initialApp: app,
            members: _members,
            configuredChannels: _configuredChannels,
            onLaunch: (target) async {
              await launchLightIsleApp(
                api: widget.api,
                appId: target['id']?.toString() ?? '',
                urlLauncher: widget.urlLauncher,
              );
              await _reload(refresh: false);
            },
            onExportData: _exportAppData,
            onExportPackage: _exportAppPackage,
            onSnapshotUpdated: (res) {
              if (!mounted) return;
              if (res['apps'] is List) {
                _applySnapshot(res);
              }
            },
            onDeleted: (deletedId) {
              if (!mounted) return;
              setState(() {
                _apps = _apps
                    .where((a) => a['id']?.toString() != deletedId)
                    .toList();
                _notice = '已删除插件“$name”。';
              });
            },
          ),
        ),
      ),
    );
  }

  Future<String?> _chooseBackupSavePath(String fileName) async {
    if (widget.pickBackupSavePath != null) {
      final chosen = await widget.pickBackupSavePath!(fileName);
      final trimmed = chosen?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    }
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择轻应用业务数据备份保存目录',
    );
    if (dir == null || dir.trim().isEmpty) return null;
    return '${dir.trim()}${Platform.pathSeparator}$fileName';
  }

  Future<void> _exportAppData(Map<String, dynamic> app) async {
    final id = app['id']?.toString() ?? '';
    if (id.isEmpty || _busy) return;
    final fileName = '$id-data-backup.tar.gz';
    await _runBusy('导出数据失败', () async {
      final savePath = await _chooseBackupSavePath(fileName);
      if (!mounted || savePath == null || savePath.isEmpty) return;
      await widget.api.download(
        '/api/v2/apps/${Uri.encodeComponent(id)}/data-backup',
        savePath,
      );
      if (mounted) {
        setState(() {
          _notice = '已导出「${app['name'] ?? id}」的业务数据归档至：$savePath';
        });
      }
    });
  }

  Future<void> _exportAppPackage(Map<String, dynamic> app) async {
    final id = app['id']?.toString() ?? '';
    if (id.isEmpty || _busy) return;
    final fileName = '$id.liapp.zip';
    await _runBusy('导出分享包失败', () async {
      final savePath = await _chooseBackupSavePath(fileName);
      if (!mounted || savePath == null || savePath.isEmpty) return;
      await widget.api.download(
        '/api/v2/apps/${Uri.encodeComponent(id)}/package-export',
        savePath,
      );
      if (mounted) {
        setState(() {
          _notice = '已导出「${app['name'] ?? id}」的轻应用分享包至：$savePath';
        });
      }
    });
  }

  Future<void> _importAppPackage() async {
    if (!_isAdmin || _busy) return;
    final selected = await FilePicker.pickFile(
      dialogTitle: '选择要导入的轻应用分享包 (.liapp.zip)',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (!mounted || selected == null) return;
    await _runBusy('导入插件包失败', () async {
      final rawBytes = await selected.readAsBytes();
      if (rawBytes.isEmpty) return;
      final res = await widget.api.sendBytes(
        'POST',
        '/api/v2/apps/package-import',
        rawBytes,
        contentType: 'application/zip',
        query: _selectedInstallLocationId.isEmpty
            ? null
            : <String, String>{'locationId': _selectedInstallLocationId},
      );
      if (!mounted) return;
      _applySnapshot(res);
      final importedName =
          (res['app'] is Map ? (res['app'] as Map)['name']?.toString() : null) ??
          selected.name;
      setState(() {
        _notice = '已导入轻应用「$importedName」（待管理员确认激活后即可使用）。';
      });
    });
  }

  Map<String, dynamic>? get _activeWorkbenchApp {
    final id = _activeWorkbenchAppId;
    if (id == null || id.isEmpty) return null;
    for (final app in _apps) {
      if (app['id']?.toString() == id) return app;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final activeWorkbench = _activeWorkbenchApp;
    final palette = IslePalette.of(context);
    final violet = palette['brandViolet'];
    return PopScope(
      canPop: activeWorkbench == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || activeWorkbench == null) return;
        setState(() {
          _activeWorkbenchAppId = null;
          _activeWorkbenchUrl = null;
          _workbenchFullscreen = false;
        });
        _reload(refresh: false);
      },
      child: Scaffold(
        appBar: IsleAppBar(
          title: Text(
            activeWorkbench != null
                ? '应用工作台 · ${activeWorkbench['name'] ?? ''}'
                : '应用中心',
          ),
          actions: [
            if (_isAdmin)
              IconButton(
                key: const ValueKey('importAppPackageIconButton'),
                tooltip: '导入插件包 (.liapp.zip)',
                onPressed: _busy ? null : _importAppPackage,
                icon: const Icon(Icons.upload_file_rounded),
              ),
            IconButton(
              key: const ValueKey('refreshAppsIconButton'),
              tooltip: '刷新应用列表',
              onPressed: _busy ? null : () => _reload(refresh: _isAdmin),
              icon: const Icon(Icons.refresh_rounded),
            ),
            IsleHelpButton(
              title: '家庭轻应用说明',
              accentColor: violet,
              items: const [
                IsleHelpItem(
                  title: '零冗余按需运行',
                  body: '官方精选静态模板占用 0 MB 常驻内存；动态 Web 应用支持按需唤醒与闲置自动休眠。',
                ),
                IsleHelpItem(
                  title: '代码与数据解耦',
                  body: '应用代码与业务数据分目录存放，升级或移除插件不会影响已保存的数据归档。',
                ),
              ],
            ),
          ],
        ),
        body: IsleListView(
          maxWidth: activeWorkbench != null
              ? 1320
              : IsleLayout.workbenchMaxWidth,
          children: [
            if (activeWorkbench != null)
              _buildEmbeddedWorkbench(context, activeWorkbench)
            else if (!_loaded && _busy)
              const IsleLoadingState(label: '正在加载应用中心…')
            else ...[
              if (!_isAdmin) ...[
                IsleFocalStage(
                  icon: Icons.apps_rounded,
                  accent: violet,
                  title: '家庭轻应用工作台',
                  metrics: [
                    IsleFocalMetric(
                      label: '可用应用',
                      value: '${_apps.length}',
                      accent: violet,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (_isAdmin && _appStorage != null) ...[
                _buildStorageLocationsCard(context),
                const SizedBox(height: 12),
              ],
              if (_isAdmin && (_store != null || _templates.isNotEmpty)) ...[
                _buildOnlineStoreCard(context),
                const SizedBox(height: 12),
              ],
              if (_error != null)
                Notice(
                  _error!,
                  error: true,
                  onRetry: () => _reload(refresh: _isAdmin),
                ),
              if (_notice != null) Notice(_notice!),
              if (_busy || _wakingAppId != null)
                const LinearProgressIndicator(),
              if (_loaded && _apps.isEmpty && !_busy)
                IsleEmptyStateCard(
                  _isAdmin
                      ? '还没有已安装的轻应用插件。可从上方 Git 在线插件商店按需下载安装，或在 Mac 端添加。'
                      : '管理员暂未向当前账号开放轻应用。',
                  title: '暂无可用轻应用',
                  icon: Icons.widgets_outlined,
                ),
              if (_apps.isNotEmpty) ...[
                IsleSectionHeader(
                  title: _isAdmin
                      ? '已安装轻应用（${_apps.length}）'
                      : '可用轻应用（${_apps.length}）',
                  accentColor: violet,
                ),
                IsleResponsiveGrid(
                  minItemWidth: 340,
                  maxColumns: 3,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final app in _apps) _buildAppCard(context, app),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
