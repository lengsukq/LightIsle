import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'apps_center_sheets.dart';
import 'apps_mcp_debug_sheet.dart';

export 'apps_center_sheets.dart';
export 'apps_mcp_debug_sheet.dart';

part 'apps_center_cards.dart';

const String _defaultMcpPrompt =
    '请帮我将当前 Mac 上的「LightIsle（轻屿）开发者 MCP Server」安装并注册到你的 MCP 配置文件中：\n'
    '- MCP 服务名称：lightisle-dev\n'
    '- 传输方式：stdio\n'
    '- 可执行命令：/Applications/LightIsle.app/Contents/Resources/core/lightisled\n'
    '- 命令参数：["mcp", "--data-dir", "~/Library/Application Support/LightIsle"]\n'
    '配置完成后，请调用 lightisle_get_environment 工具与读取 lightisle://specs/plugin-v2 资源。';

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
  List<Map<String, dynamic>> _members = const [];
  Set<String> _configuredChannels = const {};
  bool _isAdmin = false, _mcpEnabled = false, _busy = false;
  bool _mcpBusy = false, _loaded = false, _workbenchFullscreen = false;
  String _mcpPrompt = _defaultMcpPrompt;
  Map<String, dynamic> _rawMcpSnapshot = const {};
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

  void _updateState(VoidCallback fn) => setState(fn);

  void _applySnapshot(Map<String, dynamic> res) {
    final channelsRaw = res['configuredChannels'];
    setState(() {
      if (res['apps'] is List) _apps = objectList(res['apps']);
      if (res['members'] is List) _members = objectList(res['members']);
      if (channelsRaw is List) {
        _configuredChannels = {
          for (final item in channelsRaw)
            if (item.toString().isNotEmpty) item.toString(),
        };
      }
      if (res['isAdmin'] is bool) _isAdmin = res['isAdmin'] as bool;
      if (res['mcpEnabled'] is bool) _mcpEnabled = res['mcpEnabled'] as bool;
      final prompt = res['mcpPrompt']?.toString().trim() ?? '';
      if (prompt.isNotEmpty) _mcpPrompt = prompt;
      _rawMcpSnapshot = Map<String, dynamic>.from(res);
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

  Future<void> _reload({required bool refresh}) =>
      _runBusy('加载应用中心失败', () async {
        final res = refresh
            ? await widget.api.send('POST', '/api/v2/apps/refresh')
            : await widget.api.get('/api/v2/apps');
        if (mounted) _applySnapshot(res);
      });

  Future<void> _toggleMcp(bool enabled) async {
    if (_mcpBusy) return;
    setState(() {
      _mcpBusy = true;
      _error = null;
      _notice = null;
    });
    try {
      final res = await widget.api.send(
        'PUT',
        '/api/v2/apps/mcp',
        body: {'enabled': enabled},
      );
      if (!mounted) return;
      setState(() {
        _mcpEnabled = res['mcpEnabled'] == true;
        final prompt = res['mcpPrompt']?.toString().trim() ?? '';
        if (prompt.isNotEmpty) _mcpPrompt = prompt;
        _notice = _mcpEnabled
            ? '已开启本地 AI Agent (MCP) 开发者服务。'
            : '已关闭本地 AI Agent (MCP) 开发者服务。';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '切换 MCP 开关失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _mcpBusy = false);
    }
  }

  Future<void> _copyMcpPrompt() async {
    if (_mcpBusy) return;
    if (!_mcpEnabled) {
      await _toggleMcp(true);
      if (!mounted || !_mcpEnabled) return;
    }
    await Clipboard.setData(ClipboardData(text: _mcpPrompt));
    if (mounted) {
      setState(() {
        _notice = '已复制 MCP 接入提示词，请直接粘贴给本机 Claude Code / Antigravity / Codex。';
      });
    }
  }

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
      if (mounted) setState(() => _error = '打开应用失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _wakingAppId = null);
    }
  }

  Future<void> _performAction(Map<String, dynamic> app, String action) async {
    final id = app['id']?.toString() ?? '';
    if (id.isEmpty) return;
    await _runBusy('操作未完成', () async {
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
    return Scaffold(
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
          else ...[
            if (_isAdmin) _buildAdminMcpCard(context),
            if (!_isAdmin)
              const IsleIntroCard(
                icon: Icons.apps_rounded,
                title: '家庭轻应用工作台',
                description: '这里展示家庭管理员为你开启的实用工具与看板，点击即可免密打开，无需额外配置端口或账号。',
              ),
            if (_error != null)
              Notice(
                _error!,
                error: true,
                onRetry: () => _reload(refresh: _isAdmin),
              ),
            if (_notice != null) Notice(_notice!),
            if (_busy || _wakingAppId != null) const LinearProgressIndicator(),
            if (_loaded && _apps.isEmpty && !_busy)
              IsleEmptyStateCard(
                _isAdmin
                    ? '还没有已安装的轻应用插件。可打开上方 MCP 开关并复制提示词，让本地 AI Agent 自动创建或迁移轻应用。'
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
    );
  }
}
