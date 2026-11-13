part of 'apps_center_page.dart';

extension _AppsCenterMcpCard on _AppsCenterPageState {
  Widget _buildAdminMcpCard(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final origin = widget.api.uri('/').origin;
    final effectiveHttp = _lanHttpUrl.isNotEmpty
        ? _lanHttpUrl
        : '$origin/api/v2/mcp';
    final effectiveSse = _lanSseUrl.isNotEmpty
        ? _lanSseUrl
        : '$effectiveHttp/sse';
    final maskedToken = _mcpToken.length > 12
        ? '${_mcpToken.substring(0, 6)}••••••••${_mcpToken.substring(_mcpToken.length - 4)}'
        : (_mcpToken.isEmpty ? '尚未生成' : '••••••••');

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
                      'AI Agent (MCP) 服务',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '开启主开关默认启用本机免令牌直连；关闭主开关将同步关闭局域网与 Cloud MCP 访问。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
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
              FilledButton.icon(
                key: const ValueKey('openMcpWizardSheetButton'),
                onPressed: _mcpBusy
                    ? null
                    : () => showMcpClientWizardSheet(
                        context: context,
                        mcpEnabled: _mcpEnabled,
                        mcpLanEnabled: _mcpLanEnabled,
                        mcpToken: _mcpToken,
                        command: _mcpCommand,
                        lanHttpUrl: _lanHttpUrl,
                        lanSseUrl: _lanSseUrl,
                        mcpPrompt: _mcpPrompt,
                        lanMcpPrompt: _lanMcpPrompt,
                        onEnableMcp: () => _toggleMcp(true),
                        onEnableLanMcp: () => _toggleMcpLan(true),
                      ),
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: const Text('客户端接入向导'),
              ),
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
              OutlinedButton.icon(
                key: const ValueKey('openMcpDebugSheetButton'),
                onPressed: _busy
                    ? null
                    : () => _applySheetResult(
                        showAppsMcpDebugSheet(
                          context: context,
                          api: widget.api,
                          apps: _apps,
                          initialSnapshot: _rawMcpSnapshot,
                        ),
                        '已同步局域网 MCP 与调试配置。',
                      ),
                icon: const Icon(Icons.terminal_rounded, size: 18),
                label: const Text('MCP 调试器'),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: !_mcpEnabled
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 24),
                      Row(
                        children: [
                          const Icon(Icons.hub_outlined, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '允许局域网 / Cloud MCP 访问',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '开启后允许局域网设备或 Gemini Cloud MCP 持 Token 访问 /api/v2/mcp',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            key: const ValueKey('mcpLanEnableSwitch'),
                            value: _mcpLanEnabled,
                            onChanged: _mcpBusy ? null : _toggleMcpLan,
                          ),
                        ],
                      ),
                      if (_mcpLanEnabled) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest.withValues(
                              alpha: 0.4,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '远程端点：$effectiveHttp',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(fontFamily: 'monospace'),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _copyMcpText(
                                      effectiveHttp,
                                      '已复制 /api/v2/mcp 端点 URL',
                                    ),
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      size: 15,
                                    ),
                                    label: const Text('复制 HTTP'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _copyMcpText(
                                      effectiveSse,
                                      '已复制 SSE 端点 URL',
                                    ),
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      size: 15,
                                    ),
                                    label: const Text('SSE'),
                                  ),
                                ],
                              ),
                              const Divider(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '鉴权 Token：${_revealMcpToken ? _mcpToken : maskedToken}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(fontFamily: 'monospace'),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _updateState(
                                      () => _revealMcpToken = !_revealMcpToken,
                                    ),
                                    child: Text(_revealMcpToken ? '隐藏' : '显示'),
                                  ),
                                  TextButton(
                                    onPressed: _mcpToken.isEmpty
                                        ? null
                                        : () => _copyMcpText(
                                            _mcpToken,
                                            '已复制 MCP Bearer Token',
                                          ),
                                    child: const Text('复制'),
                                  ),
                                  TextButton(
                                    key: const ValueKey('rotateMcpTokenButton'),
                                    onPressed: _mcpBusy ? null : _rotateMcpToken,
                                    child: const Text('轮换'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        ExpansionTile(
                          key: const ValueKey('mcpCallLogsAccordion'),
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 4),
                          title: Text(
                            '底部调用日志（最近 ${_mcpLogs.length} 条）',
                            style: theme.textTheme.titleSmall,
                          ),
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _reload(refresh: false),
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('刷新'),
                                ),
                                TextButton.icon(
                                  onPressed: _mcpBusy || _mcpLogs.isEmpty
                                      ? null
                                      : _clearMcpLogs,
                                  icon: const Icon(
                                    Icons.delete_sweep_outlined,
                                    size: 16,
                                  ),
                                  label: const Text('清空'),
                                ),
                              ],
                            ),
                            if (_mcpLogs.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Text(
                                  '暂无 MCP 调用记录。',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              )
                            else
                              for (final entry in _mcpLogs.take(15))
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    entry['isError'] == true
                                        ? Icons.error_outline_rounded
                                        : Icons.check_circle_outline_rounded,
                                    size: 18,
                                    color: entry['isError'] == true
                                        ? colors.error
                                        : colors.primary,
                                  ),
                                  title: Text(
                                    '${entry['method'] ?? ''}${entry['target'] != null && entry['target'].toString().isNotEmpty ? ' · ${entry['target']}' : ''}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '[${entry['transport'] ?? 'local'}] ${entry['remoteAddr'] ?? 'local'} · ${entry['timestamp'] ?? ''}',
                                    style: theme.textTheme.labelSmall,
                                  ),
                                  trailing: Text(
                                    '${entry['durationMs'] ?? 0} ms',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
