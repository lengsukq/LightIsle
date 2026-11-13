import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/isle_quick_jump.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'accounts_page.dart';
import 'apps_center_sheets.dart';
import 'network_diagnostics_page.dart';
import 'storage_page.dart';

export 'apps_center_sheets.dart';

part 'apps_center_cards.dart';
part 'apps_center_storage_card.dart';

class AppsCenterPage extends StatefulWidget {
  const AppsCenterPage({
    super.key,
    required this.api,
    this.isAdmin,
    @visibleForTesting this.urlLauncher,
    @visibleForTesting this.pickBackupSavePath,
  });

  final LightIsleApi api;
  final bool? isAdmin;
  @visibleForTesting
  final Future<bool> Function(Uri uri, {LaunchMode mode})? urlLauncher;
  @visibleForTesting
  final Future<String?> Function(String defaultFileName)? pickBackupSavePath;

  @override
  State<AppsCenterPage> createState() => _AppsCenterPageState();
}

class _AppsCenterPageState extends State<AppsCenterPage> {
  List<Map<String, dynamic>> _apps = const [];
  List<Map<String, dynamic>> _templates = const [];
  List<Map<String, dynamic>> _members = const [];
  Map<String, dynamic>? _appStorage;
  String _selectedInstallLocationId = '';
  Set<String> _configuredChannels = const {};
  bool _isAdmin = false, _busy = false;
  bool _loaded = false, _workbenchFullscreen = false;
  String? _wakingAppId,
      _activeWorkbenchAppId,
      _activeWorkbenchUrl,
      _error,
      _notice;
  int _workbenchReloadKey = 0;

  @override
  void initState() {
    super.initState();
    _isAdmin = widget.isAdmin ?? false;
    _reload(refresh: false);
  }

  @override
  void didUpdateWidget(covariant AppsCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.isAdmin != widget.isAdmin) {
      _isAdmin = widget.isAdmin ?? false;
      _activeWorkbenchAppId = null;
      _activeWorkbenchUrl = null;
      _loaded = false;
      _selectedInstallLocationId = '';
      unawaited(_reload(refresh: false));
    }
  }

  void _updateState(VoidCallback fn) => setState(fn);

  void _applySnapshot(Map<String, dynamic> res) {
    final channelsRaw = res['configuredChannels'];
    setState(() {
      if (res['apps'] is List) _apps = objectList(res['apps']);
      if (res['templates'] is List) _templates = objectList(res['templates']);
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
    });
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
    } catch (_) {
      // Keep original action error visible.
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
      final res = await widget.api.send(
        'POST',
        '/api/v2/apps/${Uri.encodeComponent(id)}/launch',
      );
      if (!mounted) return;
      final launchPath = res['launchUrl']?.toString().trim() ?? '/apps/$id/';
      final cleanPath = res['launchPath']?.toString().trim() ?? '/apps/$id/';
      final origin = widget.api.uri('/').origin;
      final urlText = launchPath.startsWith('http')
          ? launchPath
          : '$origin${launchPath.startsWith('/') ? launchPath : '/$launchPath'}';
      final displayUrl = cleanPath.startsWith('http')
          ? cleanPath
          : '$origin${cleanPath.startsWith('/') ? cleanPath : '/$cleanPath'}';
      final targetUri = Uri.parse(urlText);
      final launcher =
          widget.urlLauncher ??
          (Uri u, {LaunchMode mode = LaunchMode.platformDefault}) =>
              launchUrl(u, mode: mode);
      var opened = false;
      Object? lastLaunchError;
      if (!preferExternal) {
        try {
          opened = await launcher(targetUri, mode: LaunchMode.inAppWebView);
        } catch (e) {
          lastLaunchError = e;
        }
        if (!opened) {
          try {
            opened = await launcher(
              targetUri,
              mode: LaunchMode.inAppBrowserView,
            );
          } catch (e) {
            lastLaunchError = e;
          }
        }
      }
      if (!opened) {
        try {
          opened = await launcher(
            targetUri,
            mode: LaunchMode.externalApplication,
          );
        } catch (e) {
          lastLaunchError = e;
        }
      }
      if (!opened) {
        if (lastLaunchError != null) throw lastLaunchError;
        throw StateError('无法在浏览器中打开该轻应用，请检查系统默认浏览器设置。');
      }
      if (!mounted) return;
      final refreshed = await widget.api.get('/api/v2/apps');
      if (mounted) {
        _applySnapshot(refreshed);
        setState(() {
          _activeWorkbenchAppId = id;
          _activeWorkbenchUrl = displayUrl;
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

  Future<void> _deleteApp(Map<String, dynamic> app) async {
    final id = app['id']?.toString() ?? '';
    final name = app['name']?.toString() ?? id;
    if (id.isEmpty || _busy) return;
    if (!await confirmAction(
      context,
      '删除轻应用插件',
      '确定删除“$name”？将移除 plugins/$id/ 代码目录；plugin-data/$id/ 数据目录会保留。',
      action: '删除插件',
      isDestructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    await _runBusy('删除失败', () async {
      final res = await widget.api.send(
        'DELETE',
        '/api/v2/apps/${Uri.encodeComponent(id)}',
      );
      if (!mounted) return;
      if (res['apps'] is List) {
        _applySnapshot(res);
      } else {
        setState(
          () => _apps = _apps.where((a) => a['id']?.toString() != id).toList(),
        );
      }
      setState(() => _notice = '已删除插件“$name”。');
    });
  }

  Future<void> _installOfficialTemplate(Map<String, dynamic> tpl) async {
    final id = tpl['id']?.toString() ?? '';
    final name = tpl['name']?.toString() ?? id;
    if (id.isEmpty || _busy) return;
    await _runBusy('安装模板失败', () async {
      final res = await widget.api.send(
        'POST',
        '/api/v2/apps/templates/${Uri.encodeComponent(id)}/install',
        body: _selectedInstallLocationId.isEmpty
            ? const <String, dynamic>{}
            : <String, dynamic>{'locationId': _selectedInstallLocationId},
      );
      if (!mounted) return;
      _applySnapshot(res);
      setState(() => _notice = '已一键安装官方精选轻应用「$name」（纯静态 · 0 MB）。');
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

  Future<void> _applySheetResult(
    Future<Map<String, dynamic>?> sheetFuture,
    String successNotice,
  ) async {
    final updated = await sheetFuture;
    if (!mounted || updated == null) return;
    if (updated['apps'] is List) {
      _applySnapshot(updated);
    } else {
      await _reload(refresh: false);
    }
    if (mounted) setState(() => _notice = successNotice);
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
            IconButton(
              key: const ValueKey('refreshAppsIconButton'),
              tooltip: '刷新应用列表',
              onPressed: _busy ? null : () => _reload(refresh: _isAdmin),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: IsleListView(
          children: [
            if (activeWorkbench != null)
              _buildEmbeddedWorkbench(context, activeWorkbench)
            else if (!_loaded && _busy)
              const IsleLoadingState(label: '正在加载应用中心…')
            else ...[
              if (_isAdmin && _appStorage != null)
                _buildStorageLocationsCard(context),
              if (_isAdmin && _templates.isNotEmpty)
                _buildOfficialTemplatesCard(context),
              if (!_isAdmin)
                const IsleIntroCard(
                  icon: Icons.apps_rounded,
                  title: '家庭轻应用工作台',
                  description: '这里展示家庭管理员为你开启的实用工具与看板，点击即可免密打开，无需额外配置端口或账号。',
                ),
              IsleQuickJumpStrip(
                key: const ValueKey('appsCenterQuickJumpStrip'),
                items: [
                  if (_isAdmin) ...[
                    IsleQuickJumpItem(
                      icon: Icons.storage_rounded,
                      label: '管理存储与配额',
                      tooltip: '查看物理磁盘状态与轻应用可用存储位置',
                      onTap: () => Navigator.of(context).push<void>(
                        buildIslePageRoute<void>(
                          builder: (_) =>
                              StoragePage(api: widget.api, isAdmin: true),
                        ),
                      ),
                    ),
                    IsleQuickJumpItem(
                      icon: Icons.people_outline_rounded,
                      label: '成员与目录授权',
                      tooltip: '管理家庭成员账号并配合轻应用授权可见范围',
                      onTap: () => Navigator.of(context).push<void>(
                        buildIslePageRoute<void>(
                          builder: (_) => AccountsPage(api: widget.api),
                        ),
                      ),
                    ),
                  ],
                  IsleQuickJumpItem(
                    icon: Icons.speed_rounded,
                    label: '连接测速',
                    tooltip: '检测轻量应用与 NAS 服务连接的网络质量',
                    onTap: () => Navigator.of(context).push<void>(
                      buildIslePageRoute<void>(
                        builder: (_) => NetworkDiagnosticsPage(api: widget.api),
                      ),
                    ),
                  ),
                ],
              ),
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
                      ? '还没有已安装的轻应用插件。可一键安装上方官方精选轻应用，或在 Mac 端 LightIsle 客户端中添加。'
                      : '管理员暂未向当前账号开放轻应用。',
                  title: '暂无可用轻应用',
                  icon: Icons.widgets_outlined,
                ),
              if (_apps.isNotEmpty) ...[
                IsleSectionHeader(
                  title: _isAdmin
                      ? '已安装轻应用（${_apps.length}）'
                      : '可用轻应用（${_apps.length}）',
                ),
                IsleResponsiveGrid(
                  minItemWidth: 340,
                  maxColumns: 2,
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
