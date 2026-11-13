import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';

Future<void> showMcpClientWizardSheet({
  required BuildContext context,
  required bool mcpEnabled,
  required bool mcpLanEnabled,
  required String mcpToken,
  required String command,
  required String lanHttpUrl,
  required String lanSseUrl,
  required String mcpPrompt,
  required String lanMcpPrompt,
  required Future<void> Function() onEnableMcp,
  required Future<void> Function() onEnableLanMcp,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _McpClientWizardSheet(
      mcpEnabled: mcpEnabled,
      mcpLanEnabled: mcpLanEnabled,
      mcpToken: mcpToken,
      command: command,
      lanHttpUrl: lanHttpUrl,
      lanSseUrl: lanSseUrl,
      mcpPrompt: mcpPrompt,
      lanMcpPrompt: lanMcpPrompt,
      onEnableMcp: onEnableMcp,
      onEnableLanMcp: onEnableLanMcp,
    ),
  );
}

enum _WizardTab { gemini, claude, cursor, cloud }

class _McpClientWizardSheet extends StatefulWidget {
  const _McpClientWizardSheet({
    required this.mcpEnabled,
    required this.mcpLanEnabled,
    required this.mcpToken,
    required this.command,
    required this.lanHttpUrl,
    required this.lanSseUrl,
    required this.mcpPrompt,
    required this.lanMcpPrompt,
    required this.onEnableMcp,
    required this.onEnableLanMcp,
  });

  final bool mcpEnabled;
  final bool mcpLanEnabled;
  final String mcpToken;
  final String command;
  final String lanHttpUrl;
  final String lanSseUrl;
  final String mcpPrompt;
  final String lanMcpPrompt;
  final Future<void> Function() onEnableMcp;
  final Future<void> Function() onEnableLanMcp;

  @override
  State<_McpClientWizardSheet> createState() => _McpClientWizardSheetState();
}

class _McpClientWizardSheetState extends State<_McpClientWizardSheet> {
  static const String _geminiServerName = '轻屿 LightIsle';
  static const String _geminiDescription = '管理轻屿私有空间的文件、时光相册、私人影院、下载任务与家庭轻应用';
  static const String _defaultLocalCommand =
      '/Applications/LightIsle.app/Contents/Resources/core/lightisled mcp';

  _WizardTab _tab = _WizardTab.gemini;
  late bool _mcpEnabled = widget.mcpEnabled;
  late bool _mcpLanEnabled = widget.mcpLanEnabled;
  bool _busy = false;
  String? _copiedKey;
  String? _feedback;

  String get _effectiveCommand =>
      widget.command.trim().isNotEmpty ? widget.command.trim() : _defaultLocalCommand;

  String get _effectiveHttpUrl => widget.lanHttpUrl.trim().isNotEmpty
      ? widget.lanHttpUrl.trim()
      : 'http://127.0.0.1:16666/api/v2/mcp';

  String get _effectiveSseUrl => widget.lanSseUrl.trim().isNotEmpty
      ? widget.lanSseUrl.trim()
      : '$_effectiveHttpUrl/sse';

  String get _tokenPlaceholder => widget.mcpToken.trim().isNotEmpty
      ? widget.mcpToken.trim()
      : '<开启服务后自动生成 Token>';

  String get _claudeJson => const JsonEncoder.withIndent('  ').convert({
    'mcpServers': {
      'lightisle': {
        'command': '/Applications/LightIsle.app/Contents/Resources/core/lightisled',
        'args': ['mcp'],
      },
    },
  });

  String get _cursorJson {
    final servers = <String, dynamic>{
      'lightisle': {
        'command': '/Applications/LightIsle.app/Contents/Resources/core/lightisled',
        'args': ['mcp'],
      },
    };
    if (_mcpLanEnabled) {
      servers['lightisle-lan'] = {
        'type': 'streamable-http',
        'url': _effectiveHttpUrl,
        'headers': {'Authorization': 'Bearer $_tokenPlaceholder'},
      };
    }
    return const JsonEncoder.withIndent('  ').convert({'mcpServers': servers});
  }

  String get _cloudJson => const JsonEncoder.withIndent('  ').convert({
    'mcpServers': {
      'lightisle-cloud': {
        'type': 'streamable-http',
        'url': _effectiveHttpUrl,
        'headers': {
          'Authorization': 'Bearer $_tokenPlaceholder',
          'X-LightIsle-MCP-Token': _tokenPlaceholder,
        },
      },
    },
  });

  Future<void> _copy(String key, String text, String notice) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() {
      _copiedKey = key;
      _feedback = notice;
    });
  }

  Future<void> _enableMain() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onEnableMcp();
      if (mounted) setState(() => _mcpEnabled = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enableLan() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onEnableLanMcp();
      if (mounted) {
        setState(() {
          _mcpEnabled = true;
          _mcpLanEnabled = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.85;
    return SizedBox(
      height: height.clamp(420.0, 680.0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI 客户端接入向导',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '适配 Gemini 桌面端（本地 / Cloud MCP）、Claude Desktop 与 Cursor',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in const [
                    (_WizardTab.gemini, 'Gemini 桌面端'),
                    (_WizardTab.claude, 'Claude Desktop'),
                    (_WizardTab.cursor, 'Cursor'),
                    (_WizardTab.cloud, '局域网 / Cloud MCP'),
                  ]) ...[
                    ChoiceChip(
                      key: ValueKey('wizardTab_${item.$1.name}'),
                      label: Text(item.$2),
                      selected: _tab == item.$1,
                      onSelected: (_) => setState(() => _tab = item.$1),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (!_mcpEnabled)
              _statusBanner(
                context,
                icon: Icons.warning_amber_rounded,
                text: '当前 AI Agent (MCP) 主开关尚未开启，客户端暂无法调用轻屿工具。',
                actionLabel: '立即开启',
                onAction: _busy ? null : _enableMain,
              )
            else if ((_tab == _WizardTab.gemini || _tab == _WizardTab.cloud) &&
                !_mcpLanEnabled)
              _statusBanner(
                context,
                icon: Icons.hub_outlined,
                text: '本机 stdio 已就绪；如需局域网或 Cloud MCP 接入，可顺便开启局域网访问。',
                actionLabel: '开启局域网访问',
                onAction: _busy ? null : _enableLan,
              ),
            Expanded(
              child: SingleChildScrollView(
                child: switch (_tab) {
                  _WizardTab.gemini => _buildGeminiTab(context),
                  _WizardTab.claude => _buildCodeTab(
                    context,
                    title: 'Claude Desktop 本机配置（claude_desktop_config.json）',
                    subtitle: '打开 Claude Desktop → Settings → Developer → Edit Config，合并 mcpServers 配置。',
                    copyKey: 'claude',
                    code: _claudeJson,
                    notice: '已复制 Claude Desktop MCP 配置',
                  ),
                  _WizardTab.cursor => _buildCodeTab(
                    context,
                    title: 'Cursor 配置（~/.cursor/mcp.json）',
                    subtitle: '本机推荐 stdio 直连；开启局域网后同步提供 Streamable HTTP 配置。',
                    copyKey: 'cursor',
                    code: _cursorJson,
                    notice: '已复制 Cursor MCP 配置',
                  ),
                  _WizardTab.cloud => _buildCloudTab(context),
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _feedback ?? '点击字段右侧按钮即可一键复制对应值。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _feedback != null
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBanner(
    BuildContext context, {
    required IconData icon,
    required String text,
    required String actionLabel,
    required VoidCallback? onAction,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildGeminiTab(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Gemini 桌面端「设置自定义的关联应用」逐项填写清单',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        _copyRow(
          context,
          label: '选择设置方法',
          value: '同机选「本地 MCP」，跨设备或远程选「Cloud MCP」',
          copyKey: 'gemini-method',
          copyValue: '本地 MCP',
          notice: '已复制设置方法建议',
        ),
        _copyRow(
          context,
          label: '服务器名称',
          value: _geminiServerName,
          copyKey: 'gemini-name',
          copyValue: _geminiServerName,
          notice: '已复制服务器名称',
        ),
        _copyRow(
          context,
          label: '说明',
          value: _geminiDescription,
          copyKey: 'gemini-desc',
          copyValue: _geminiDescription,
          notice: '已复制服务器说明',
        ),
        _copyRow(
          context,
          label: '命令',
          value: _effectiveCommand,
          copyKey: 'gemini-cmd',
          copyValue: _effectiveCommand,
          notice: '已复制本地 MCP 启动命令',
          monospace: true,
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('geminiSandboxWarning'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.errorContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: colors.error.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 18, color: colors.error),
                  const SizedBox(width: 8),
                  Text(
                    '沙盒设置避坑说明（必看）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.error,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '1. Gemini 桌面端默认开启沙盒，仅放行关联目录、~/.cache 与 /tmp，可能拦截子进程直读 ~/Library/Application Support/LightIsle。\n'
                '2. 轻屿 Core 已内置 ~/.cache 与 /tmp 本机回环桥接通道：请保持轻屿运行，即可自动绕开目录拦截。\n'
                '3. 若仍受限，请在 Gemini「沙盒设置」中切换受限更少模式，或改用 Cloud MCP（$_effectiveHttpUrl）。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCloudTab(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _copyRow(
          context,
          label: 'Streamable HTTP URL',
          value: _effectiveHttpUrl,
          copyKey: 'cloud-http',
          copyValue: _effectiveHttpUrl,
          notice: '已复制 Streamable HTTP URL',
          monospace: true,
        ),
        _copyRow(
          context,
          label: 'SSE 兼容 URL',
          value: _effectiveSseUrl,
          copyKey: 'cloud-sse',
          copyValue: _effectiveSseUrl,
          notice: '已复制 SSE 端点 URL',
          monospace: true,
        ),
        _copyRow(
          context,
          label: 'Bearer Token',
          value: _tokenPlaceholder,
          copyKey: 'cloud-token',
          copyValue: widget.mcpToken.trim(),
          notice: '已复制 MCP Bearer Token',
          monospace: true,
          copyDisabled: widget.mcpToken.trim().isEmpty,
        ),
        const SizedBox(height: 8),
        _buildCodeTab(
          context,
          title: '标准 mcpServers（Streamable HTTP）配置',
          subtitle: '建议在局域网、Tailscale 或 Cloudflare Tunnel HTTPS 下使用，并妥善保管 Token。',
          copyKey: 'cloud-json',
          code: _cloudJson,
          notice: '已复制 Cloud MCP JSON 配置',
        ),
      ],
    );
  }

  Widget _copyRow(
    BuildContext context, {
    required String label,
    required String value,
    required String copyKey,
    required String copyValue,
    required String notice,
    bool monospace = false,
    bool copyDisabled = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final copied = _copiedKey == copyKey;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  value,
                  style: monospace
                      ? theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')
                      : theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: ValueKey('wizardCopy_$copyKey'),
            onPressed: copyDisabled ? null : () => _copy(copyKey, copyValue, notice),
            child: Text(copied ? '已复制' : '复制'),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeTab(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String copyKey,
    required String code,
    required String notice,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final copied = _copiedKey == copyKey;
    return IsleSurface(
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: ValueKey('wizardCopy_$copyKey'),
                onPressed: () => _copy(copyKey, code, notice),
                child: Text(copied ? '已复制' : '复制 JSON'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              code,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
