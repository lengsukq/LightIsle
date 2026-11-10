// dart format off
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

export 'apps_center_sheets.dart';

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
  String? _wakingAppId, _activeWorkbenchAppId, _activeWorkbenchUrl, _error, _notice;
  int _workbenchReloadKey = 0;

  @override
  void initState() {
    super.initState();
    _isAdmin = widget.isAdmin ?? false;
    _reload(refresh: false);
  }

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
      _loaded = true;
    });
  }

  Future<void> _runBusy(String errorPrefix, Future<void> Function() task) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; _notice = null; });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => _error = '$errorPrefix：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload({required bool refresh}) => _runBusy('加载应用中心失败', () async {
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
      final res = await widget.api.send('PUT', '/api/v2/apps/mcp', body: {'enabled': enabled});
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
      if (mounted) setState(() => _error = '切换 MCP 开关失败：${userFacingError(e)}');
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

  Future<void> _launchApp(Map<String, dynamic> app, {bool preferExternal = false}) async {
    final id = app['id']?.toString() ?? '';
    if (id.isEmpty || _wakingAppId != null) return;
    setState(() {
      _wakingAppId = id;
      _error = null;
      _notice = null;
    });
    try {
      final res = await widget.api.send('POST', '/api/v2/apps/${Uri.encodeComponent(id)}/launch');
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
      final launcher = widget.urlLauncher ??
          (Uri u, {LaunchMode mode = LaunchMode.platformDefault}) => launchUrl(u, mode: mode);
      var opened = false;
      if (!preferExternal) {
        try {
          opened = await launcher(targetUri, mode: LaunchMode.inAppWebView);
        } catch (_) {}
        if (!opened) {
          try {
            opened = await launcher(targetUri, mode: LaunchMode.inAppBrowserView);
          } catch (_) {}
        }
      }
      if (!opened) {
        try {
          opened = await launcher(targetUri, mode: LaunchMode.externalApplication);
        } catch (_) {}
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
      final snap = res['apps'] is List ? res : await widget.api.get('/api/v2/apps');
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
      final res = await widget.api.send('DELETE', '/api/v2/apps/${Uri.encodeComponent(id)}');
      if (!mounted) return;
      if (res['apps'] is List) {
        _applySnapshot(res);
      } else {
        setState(() => _apps = _apps.where((a) => a['id']?.toString() != id).toList());
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
      return widget.pickBackupSavePath!(fileName);
    }
    try {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: '选择轻应用业务数据备份保存目录',
      );
      if (dir != null && dir.trim().isNotEmpty) {
        return '${dir.trim()}${Platform.pathSeparator}$fileName';
      }
      return null;
    } catch (_) {
      return '${Directory.systemTemp.path}${Platform.pathSeparator}$fileName';
    }
  }

  Future<void> _exportAppData(Map<String, dynamic> app) async {
    final id = app['id']?.toString() ?? '';
    if (id.isEmpty || _busy) return;
    final fileName = '$id-data-backup.tar.gz';
    final savePath = await _chooseBackupSavePath(fileName);
    if (!mounted || savePath == null || savePath.isEmpty) return;
    await _runBusy('导出数据失败', () async {
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

  Widget _buildEmbeddedWorkbench(BuildContext context, Map<String, dynamic> app) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final draft = AppConfigDraft.fromApp(app);
    final (runtimeLabel, runtimeColor) = _runtimeBadge(app, draft.webMode);
    final urlText = _activeWorkbenchUrl ?? '';
    return IsleSurface(
      key: ValueKey('embeddedAppWorkbench_$_workbenchReloadKey'),
      radius: IsleRadius.card,
      padding: EdgeInsets.all(_workbenchFullscreen ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('workbenchBackButton'),
                    onPressed: () {
                      setState(() {
                        _activeWorkbenchAppId = null;
                        _activeWorkbenchUrl = null;
                        _workbenchFullscreen = false;
                      });
                      _reload(refresh: false);
                    },
                    icon: const Icon(Icons.arrow_back_rounded, size: 16),
                    label: const Text('← 返回应用中心'),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    draft.name,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  IsleStatusBadge(label: runtimeLabel, color: runtimeColor),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('workbenchRefreshButton'),
                    onPressed: () => _launchApp(app),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('🔄 重新打开窗口'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('workbenchFullscreenButton'),
                    onPressed: () =>
                        setState(() => _workbenchFullscreen = !_workbenchFullscreen),
                    icon: Icon(
                      _workbenchFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      size: 16,
                    ),
                    label: Text(_workbenchFullscreen ? '⛶ 退出全屏' : '⛶ 全屏展开'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('workbenchExternalButton'),
                    onPressed: () => _launchApp(app, preferExternal: true),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('↗ 外部浏览器打开'),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '轻应用运行会话 · ${draft.name}',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  urlText,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                Text(
                  '已通过一次性 Launch Ticket 完成免二次登录鉴权并唤起浏览器会话窗口（凭据仅兑换为受保护的 HttpOnly 会话 Cookie，不驻留于地址栏）。若窗口已关闭或被遮挡，可点击上方「🔄 重新打开窗口」或「↗ 外部浏览器打开」。',
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeWorkbench = _activeWorkbenchApp;
    return Scaffold(
      appBar: IsleAppBar(
        title: Text(activeWorkbench != null ? '应用工作台 · ${activeWorkbench['name'] ?? ''}' : '应用中心'),
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
              Notice(_error!, error: true, onRetry: () => _reload(refresh: _isAdmin)),
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
                title: _isAdmin ? '已安装轻应用（${_apps.length}）' : '可用轻应用（${_apps.length}）',
              ),
              IsleResponsiveGrid(
                minItemWidth: 340,
                maxColumns: 2,
                spacing: 12,
                runSpacing: 12,
                children: [for (final app in _apps) _buildAppCard(context, app)],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildAdminMcpCard(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    return IsleSurface(
      key: const ValueKey('adminMcpControlCard'),
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.smart_toy_outlined,
                color: colors.primary,
                size: 40,
                iconSize: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '允许 AI Agent (MCP) 接入',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '开启后，本机 Claude Code / Antigravity / Codex 可通过 lightisled mcp 读取规范、生成脚手架并热重载（新应用默认仅管理员可见）。',
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                key: const ValueKey('mcpEnableSwitch'),
                value: _mcpEnabled,
                onChanged: _mcpBusy ? null : _toggleMcp,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('copyMcpPromptButton'),
                onPressed: _mcpBusy ? null : _copyMcpPrompt,
                icon: const Icon(Icons.copy_all_rounded, size: 18),
                label: const Text('复制 MCP 接入提示词'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('refreshAppsButton'),
                onPressed: _busy ? null : () => _reload(refresh: true),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(_busy ? '正在扫描…' : '扫描本地插件目录'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppCard(BuildContext context, Map<String, dynamic> app) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final draft = AppConfigDraft.fromApp(app);
    final id = draft.id, name = draft.name;
    final description = app['description']?.toString().trim() ?? '家庭轻应用';
    final category = app['category']?.toString();
    final isWaking = _wakingAppId == id;
    final lastError = app['lastError']?.toString().trim() ?? '';
    final (runtimeLabel, runtimeColor) = _runtimeBadge(app, draft.webMode);
    final accessLabel = switch (draft.accessPolicy) {
      'all_members' => '全员可用',
      'selected_members' => '指定成员',
      _ => '仅管理员',
    };
    final cronSummary = draft.cronExpression.isEmpty
        ? null
        : (draft.cronEnabled
              ? '定时 ${draft.cronExpression}'
              : '定时已暂停 (${draft.cronExpression})');

    return IsleSurface(
      key: ValueKey('appCard_$id'),
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: _categoryIcon(category),
                color: colors.primary,
                size: 40,
                iconSize: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IsleStatusBadge(label: _categoryLabel(category), color: colors.primary),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isAdmin) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                IsleStatusBadge(label: runtimeLabel, color: runtimeColor),
                if (app['pendingActivation'] == true)
                  const IsleStatusBadge(label: '待首次激活', color: Color(0xFFD97706)),
                IsleStatusBadge(label: accessLabel, color: const Color(0xFF6366F1)),
                if (cronSummary != null)
                  IsleStatusBadge(label: cronSummary, color: const Color(0xFF0EA5E9)),
              ],
            ),
            if (lastError.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                lastError,
                style: TextStyle(fontSize: 12.5, color: colors.error, fontWeight: FontWeight.w600),
              ),
            ],
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: ValueKey('launchApp_$id'),
                onPressed: isWaking ? null : () => _launchApp(app),
                icon: Icon(
                  isWaking ? Icons.hourglass_top_rounded : Icons.open_in_new_rounded,
                  size: 16,
                ),
                label: Text(isWaking ? '正在唤醒…' : '立即打开'),
              ),
              if (_isAdmin) ...[
                OutlinedButton.icon(
                  key: ValueKey('accessApp_$id'),
                  onPressed: _busy
                      ? null
                      : () => _applySheetResult(
                          showAppMemberAccessSheet(
                            context: context,
                            api: widget.api,
                            app: app,
                            members: _members,
                          ),
                          '已更新“$name”的成员访问权限。',
                        ),
                  icon: const Icon(Icons.group_outlined, size: 16),
                  label: const Text('成员权限'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('configApp_$id'),
                  onPressed: _busy
                      ? null
                      : () => _applySheetResult(
                          showAppLifecycleCronSheet(
                            context: context,
                            api: widget.api,
                            app: app,
                            configuredChannels: _configuredChannels,
                          ),
                          '已保存“$name”的运行与定时设置。',
                        ),
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('运行与定时设置'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('logsApp_$id'),
                  onPressed: () => showAppLogsSheet(context: context, api: widget.api, app: app),
                  icon: const Icon(Icons.receipt_long_rounded, size: 16),
                  label: const Text('运行日志'),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('moreActionsApp_$id'),
                  tooltip: '更多操作',
                  onSelected: (act) {
                    if (act == 'delete') {
                      _deleteApp(app);
                    } else if (act == 'export_data') {
                      _exportAppData(app);
                    } else {
                      _performAction(app, act);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'start', child: Text('启动 Web 进程')),
                    PopupMenuItem(value: 'stop', child: Text('休眠 / 停止进程')),
                    PopupMenuItem(value: 'restart', child: Text('重启 Web 进程')),
                    PopupMenuItem(value: 'run_cron', child: Text('立即执行定时任务')),
                    PopupMenuItem(value: 'export_data', child: Text('导出应用数据 (.tar.gz)')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'delete', child: Text('删除插件')),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  (String, Color) _runtimeBadge(Map<String, dynamic> app, String mode) {
    final web = app['web'] is Map
        ? Map<String, dynamic>.from(app['web'] as Map)
        : const <String, dynamic>{};
    final runtime = app['runtime'] is Map
        ? Map<String, dynamic>.from(app['runtime'] as Map)
        : const <String, dynamic>{};
    final status =
        app['status']?.toString() ??
        web['status']?.toString() ??
        runtime['status']?.toString() ??
        (mode == 'static' ? 'static' : 'sleeping');
    final memBytes =
        (app['memoryBytes'] ??
            app['rssBytes'] ??
            web['rssBytes'] ??
            runtime['memoryBytes'] ??
            runtime['rssBytes']) as num?;
    final memMbRaw = (app['memoryMB'] ?? web['memoryMB'] ?? runtime['memoryMB']) as num?;
    final mb = memMbRaw != null
        ? memMbRaw.round()
        : (memBytes != null && memBytes > 0 ? (memBytes / (1024 * 1024)).ceil() : 0);
    if (mode == 'static' || status == 'static') {
      return ('纯静态 0 MB', const Color(0xFF10B981));
    }
    if (status == 'running') {
      return mode == 'persistent' && mb <= 0
          ? ('常驻守护', const Color(0xFF0A84FF))
          : ('运行中 $mb MB', const Color(0xFF10B981));
    }
    return mode == 'persistent'
        ? ('常驻守护', const Color(0xFF0A84FF))
        : ('按需休眠 0 MB', const Color(0xFF64748B));
  }

  String _categoryLabel(String? c) => switch (c) {
    'network' => '网络监控',
    'media' => '影音工具',
    'home' => '家庭看板',
    'finance' => '账单记账',
    'system' => '系统扩展',
    _ => '实用工具',
  };

  IconData _categoryIcon(String? c) => switch (c) {
    'network' => Icons.router_rounded,
    'media' => Icons.movie_filter_rounded,
    'home' => Icons.home_work_outlined,
    'finance' => Icons.account_balance_wallet_outlined,
    'system' => Icons.memory_rounded,
    _ => Icons.widgets_rounded,
  };
}
