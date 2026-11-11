import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

Future<Map<String, dynamic>?> showAppsMcpDebugSheet({
  required BuildContext context,
  required LightIsleApi api,
  required List<Map<String, dynamic>> apps,
  required Map<String, dynamic> initialSnapshot,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _AppsMcpDebugSheet(
      api: api,
      apps: apps,
      initialSnapshot: initialSnapshot,
    ),
  );
}

class _AppsMcpDebugSheet extends StatefulWidget {
  const _AppsMcpDebugSheet({
    required this.api,
    required this.apps,
    required this.initialSnapshot,
  });

  final LightIsleApi api;
  final List<Map<String, dynamic>> apps;
  final Map<String, dynamic> initialSnapshot;

  @override
  State<_AppsMcpDebugSheet> createState() => _AppsMcpDebugSheetState();
}

class _AppsMcpDebugSheetState extends State<_AppsMcpDebugSheet> {
  late bool _mcpEnabled;
  late bool _mcpLanEnabled;
  late String _mcpToken;
  late String _lanPrompt;
  late String _configJson;
  late String _lanHttpUrl;
  List<Map<String, dynamic>> _logs = const [];

  bool _busy = false;
  bool _showToken = false;
  String? _error;
  String? _notice;

  String _debugMethod = 'tools/call';
  String _selectedTool = 'lightisle_get_environment';
  String _selectedUri = 'lightisle://specs/plugin-v2';
  final TextEditingController _argsCtrl = TextEditingController(text: '{}');
  Map<String, dynamic>? _debugRes;

  String _probeAppId = '';
  final String _probeMethod = 'GET';
  final TextEditingController _probePathCtrl = TextEditingController(text: '/');
  Map<String, dynamic>? _probeRes;

  Map<String, dynamic>? _latestSnapshot;

  @override
  void initState() {
    super.initState();
    _applySnap(widget.initialSnapshot);
    if (widget.apps.isNotEmpty) {
      _probeAppId = widget.apps.first['id']?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _argsCtrl.dispose();
    _probePathCtrl.dispose();
    super.dispose();
  }

  void _applySnap(Map<String, dynamic> s) {
    _latestSnapshot = s;
    _mcpEnabled = s['mcpEnabled'] == true;
    _mcpLanEnabled = s['mcpLanEnabled'] == true;
    _mcpToken = s['mcpToken']?.toString() ?? '';
    _lanPrompt = s['lanMcpPrompt']?.toString() ?? '';
    _configJson = s['mcpConfigJson']?.toString() ?? '';
    _lanHttpUrl =
        s['lanHttpUrl']?.toString() ??
        s['localHttpUrl']?.toString() ??
        '/api/v2/mcp';
    if (s['mcpLogs'] is List) {
      _logs = objectList(s['mcpLogs']);
    }
  }

  Future<void> _toggleLanMcp(bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final res = await widget.api.send(
        'PUT',
        '/api/v2/apps/mcp',
        body: {
          'mcpEnabled': enabled ? true : _mcpEnabled,
          'mcpLanEnabled': enabled,
        },
      );
      if (!mounted) return;
      setState(() {
        _applySnap(res);
        _notice = enabled ? '已开启局域网 MCP (HTTP/SSE) 服务。' : '已关闭局域网 MCP 服务。';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '切换局域网 MCP 失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rotateToken() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final res = await widget.api.send(
        'POST',
        '/api/v2/apps/mcp/token/rotate',
        body: {},
      );
      if (!mounted) return;
      setState(() {
        _applySnap(res);
        _notice = '已轮换 MCP Bearer Token。';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '轮换 Token 失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runMcpDebug() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      dynamic parsedArgs = const <String, dynamic>{};
      if (_debugMethod == 'tools/call') {
        parsedArgs = jsonDecode(
          _argsCtrl.text.trim().isEmpty ? '{}' : _argsCtrl.text,
        );
      }
      final res = await widget.api.send(
        'POST',
        '/api/v2/apps/mcp/debug',
        body: {
          'method': _debugMethod,
          'tool': _debugMethod == 'tools/call' ? _selectedTool : '',
          'uri': _debugMethod == 'resources/read' ? _selectedUri : '',
          'args': parsedArgs,
        },
      );
      if (!mounted) return;
      setState(() {
        _debugRes = res;
        if (res['logs'] is List) _logs = objectList(res['logs']);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'MCP 调试执行失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runProbe() async {
    if (_busy || _probeAppId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.api.send(
        'POST',
        '/api/v2/apps/${Uri.encodeComponent(_probeAppId)}/probe',
        body: {
          'method': _probeMethod,
          'path': _probePathCtrl.text.trim().isEmpty
              ? '/'
              : _probePathCtrl.text.trim(),
          'role': 'admin',
        },
      );
      if (!mounted) return;
      setState(() {
        _probeRes = res['probe'] is Map
            ? Map<String, dynamic>.from(res['probe'] as Map)
            : res;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '网关探针请求失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLogs() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.send('DELETE', '/api/v2/apps/mcp/logs');
      if (mounted) setState(() => _logs = const []);
    } catch (e) {
      if (mounted) setState(() => _error = '清空日志失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _notice = label);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final maskedToken = _mcpToken.length > 10
        ? '${_mcpToken.substring(0, 6)}••••••••${_mcpToken.substring(_mcpToken.length - 4)}'
        : (_mcpToken.isEmpty ? '未生成' : '••••••');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      minChildSize: 0.55,
      maxChildSize: 0.96,
      builder: (ctx, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '局域网 MCP 配置与在线调试台',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(_latestSnapshot),
                child: const Text('完成'),
              ),
            ],
          ),
          if (_error != null) Notice(_error!, error: true),
          if (_notice != null) Notice(_notice!),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('lanMcpEnableSwitch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('允许局域网远程 MCP (HTTP / SSE) 接入'),
            subtitle: Text('端点：$_lanHttpUrl（仅限本机与私有局域网 IP 持 Token 访问）'),
            value: _mcpLanEnabled,
            onChanged: _busy ? null : _toggleLanMcp,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('copyLanMcpPromptButton'),
                onPressed: _lanPrompt.isEmpty
                    ? null
                    : () => _copyText(_lanPrompt, '已复制局域网 MCP 接入提示词'),
                icon: const Icon(Icons.copy_all_rounded, size: 16),
                label: const Text('复制局域网 MCP 提示词'),
              ),
              OutlinedButton.icon(
                onPressed: _configJson.isEmpty
                    ? null
                    : () => _copyText(_configJson, '已复制 mcpServers JSON 配置'),
                icon: const Icon(Icons.data_object_rounded, size: 16),
                label: const Text('复制 JSON 配置'),
              ),
              if (_mcpToken.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: () => setState(() => _showToken = !_showToken),
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: Text(_showToken ? _mcpToken : 'Token: $maskedToken'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _copyText(_mcpToken, '已复制 MCP Bearer Token'),
                  icon: const Icon(Icons.key_rounded, size: 16),
                  label: const Text('复制 Token'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _rotateToken,
                  icon: const Icon(Icons.autorenew_rounded, size: 16),
                  label: const Text('轮换 Token'),
                ),
              ],
            ],
          ),
          const Divider(height: 28),
          Text(
            'MCP 交互式调试器 (MCP Inspector)',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('mcpDebugMethodDropdown'),
                  isExpanded: true,
                  initialValue: _debugMethod,
                  decoration: const InputDecoration(labelText: '请求方法'),
                  items: const [
                    DropdownMenuItem(
                      value: 'tools/call',
                      child: Text('tools/call (调用工具)'),
                    ),
                    DropdownMenuItem(
                      value: 'tools/list',
                      child: Text('tools/list (列出工具)'),
                    ),
                    DropdownMenuItem(
                      value: 'resources/list',
                      child: Text('resources/list (列出资源)'),
                    ),
                    DropdownMenuItem(
                      value: 'resources/read',
                      child: Text('resources/read (读取规范资源)'),
                    ),
                  ],
                  onChanged: (v) =>
                      setState(() => _debugMethod = v ?? 'tools/call'),
                ),
              ),
              if (_debugMethod == 'tools/call') ...[
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _selectedTool,
                    decoration: const InputDecoration(labelText: 'MCP 工具'),
                    items: const [
                      DropdownMenuItem(
                        value: 'lightisle_get_health',
                        child: Text('lightisle_get_health'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_get_system',
                        child: Text('lightisle_get_system'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_disks',
                        child: Text('lightisle_list_disks'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_roots',
                        child: Text('lightisle_list_roots'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_files',
                        child: Text('lightisle_list_files'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_move_to_trash',
                        child: Text('lightisle_move_to_trash'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_trash',
                        child: Text('lightisle_list_trash'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_get_photo_status',
                        child: Text('lightisle_get_photo_status'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_get_cinema_status',
                        child: Text('lightisle_get_cinema_status'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_downloads',
                        child: Text('lightisle_list_downloads'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_members',
                        child: Text('lightisle_list_members'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_automation_tasks',
                        child: Text('lightisle_list_automation_tasks'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_trigger_automation_task',
                        child: Text('lightisle_trigger_automation_task'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_tasks',
                        child: Text('lightisle_list_tasks'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_alerts',
                        child: Text('lightisle_list_alerts'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_get_audit_history',
                        child: Text('lightisle_get_audit_history'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_get_environment',
                        child: Text('lightisle_get_environment'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_list_apps',
                        child: Text('lightisle_list_apps'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_scaffold_app',
                        child: Text('lightisle_scaffold_app'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_validate_and_reload',
                        child: Text('lightisle_validate_and_reload'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_read_plugin_file',
                        child: Text('lightisle_read_plugin_file'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_write_plugin_file',
                        child: Text('lightisle_write_plugin_file'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_app_action',
                        child: Text('lightisle_app_action'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_get_app_logs',
                        child: Text('lightisle_get_app_logs'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle_probe_app',
                        child: Text('lightisle_probe_app'),
                      ),
                    ],
                    onChanged: (v) => setState(
                      () => _selectedTool = v ?? 'lightisle_get_environment',
                    ),
                  ),
                ),
              ],
              if (_debugMethod == 'resources/read') ...[
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: const ValueKey('mcpDebugResourceUriDropdown'),
                    isExpanded: true,
                    initialValue: _selectedUri,
                    decoration: const InputDecoration(
                      labelText: 'MCP 规范资源 URI',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'lightisle://specs/mcp-security',
                        child: Text('lightisle://specs/mcp-security'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle://specs/plugin-v2',
                        child: Text('lightisle://specs/plugin-v2'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle://specs/ui-theme',
                        child: Text('lightisle://specs/ui-theme'),
                      ),
                      DropdownMenuItem(
                        value: 'lightisle://specs/automation-v1',
                        child: Text('lightisle://specs/automation-v1'),
                      ),
                    ],
                    onChanged: (v) => setState(
                      () => _selectedUri = v ?? 'lightisle://specs/plugin-v2',
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_debugMethod == 'tools/call') ...[
            const SizedBox(height: 8),
            TextField(
              controller: _argsCtrl,
              maxLines: 2,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(labelText: '工具参数 (JSON)'),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('runMcpDebugButton'),
              onPressed: _busy ? null : _runMcpDebug,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('发送 MCP 调试请求'),
            ),
          ),
          if (_debugRes != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                _debugRes!['responseJson']?.toString() ?? '',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
          ],
          const Divider(height: 28),
          if (widget.apps.isNotEmpty) ...[
            Text(
              '轻应用网关 HTTP 探针',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _probeAppId,
                    decoration: const InputDecoration(labelText: '目标应用'),
                    items: [
                      for (final a in widget.apps)
                        DropdownMenuItem(
                          value: a['id']?.toString() ?? '',
                          child: Text('${a['name'] ?? a['id']}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _probeAppId = v ?? ''),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _probePathCtrl,
                    decoration: const InputDecoration(labelText: '探测路径 (如 /)'),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: _busy ? null : _runProbe,
                  child: const Text('发送探针'),
                ),
              ],
            ),
            if (_probeRes != null) ...[
              const SizedBox(height: 8),
              Text(
                'HTTP ${_probeRes!['statusCode']} · ${_probeRes!['durationMs']} ms · 状态 ${_probeRes!['status']}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                _probeRes!['bodyPreview']?.toString() ?? '',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ],
            const Divider(height: 28),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'MCP 调用追踪日志 (${_logs.length})',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_logs.isNotEmpty)
                TextButton(
                  onPressed: _busy ? null : _clearLogs,
                  child: const Text('清空日志'),
                ),
            ],
          ),
          if (_logs.isEmpty)
            Text(
              '暂无 MCP 调用记录',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            )
          else
            for (final entry in _logs.take(12))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '[${entry['transport']}] ${entry['method']} ${entry['target'] ?? ''} · ${entry['durationMs']} ms · ${entry['remoteAddr'] ?? 'local'}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
