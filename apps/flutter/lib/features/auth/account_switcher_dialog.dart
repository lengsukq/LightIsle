import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_route.dart';
import '../../core/lightisle_api.dart';
import '../../core/login_history_store.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'login_history_section.dart';

export 'host_endpoints_dialog.dart' show showHostEndpointsDialog;

Future<void> showAccountSwitcherDialog({
  required BuildContext context,
  required String currentServer,
  required String currentUsername,
  required LoginHistoryStore historyStore,
  required FutureOr<void> Function(LightIsleApi api, Map<String, dynamic> identity) onSwitchAccount,
  required Future<void> Function() onUseNewAccount,
  int Function()? pendingUploads,
  ServerLatencyProber? latencyProber,
  LightIsleApi Function(String serverUrl, {String? certificateFingerprint})? apiFactory,
}) => showIsleDialog<void>(
  context: context,
  builder: (_) => _AccountSwitcherDialog(
    currentServer: currentServer,
    currentUsername: currentUsername,
    historyStore: historyStore,
    onSwitchAccount: onSwitchAccount,
    onUseNewAccount: onUseNewAccount,
    pendingUploads: pendingUploads,
    latencyProber: latencyProber ?? probeServerLatency,
    apiFactory: apiFactory,
  ),
);

class _AccountSwitcherDialog extends StatefulWidget {
  const _AccountSwitcherDialog({
    required this.currentServer,
    required this.currentUsername,
    required this.historyStore,
    required this.onSwitchAccount,
    required this.onUseNewAccount,
    required this.latencyProber,
    this.pendingUploads,
    this.apiFactory,
  });

  final String currentServer, currentUsername;
  final LoginHistoryStore historyStore;
  final FutureOr<void> Function(LightIsleApi api, Map<String, dynamic> identity) onSwitchAccount;
  final Future<void> Function() onUseNewAccount;
  final int Function()? pendingUploads;
  final ServerLatencyProber latencyProber;
  final LightIsleApi Function(String serverUrl, {String? certificateFingerprint})? apiFactory;

  @override
  State<_AccountSwitcherDialog> createState() => _AccountSwitcherDialogState();
}

class _AccountSwitcherDialogState extends State<_AccountSwitcherDialog> {
  List<LoginHistoryEntry> _entries = const [];
  final Map<String, ServerLatencyResult> _latencies = {};
  bool _loading = true;
  String? _switchingKey;
  String? _error;
  int _probeGeneration = 0;

  bool _isCurrentHostAccount(LoginHistoryEntry entry) =>
      entry.username.trim().toLowerCase() ==
          widget.currentUsername.trim().toLowerCase() &&
      entry.ownsServer(widget.currentServer);

  @override
  void initState() {
    super.initState();
    unawaited(_loadEntries());
  }

  Future<void> _loadEntries() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.historyStore.readAll();
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
      unawaited(_probeAllLatencies(list));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingError(error);
      });
    }
  }

  Future<void> _probeAllLatencies([List<LoginHistoryEntry>? source]) async {
    final items = source ?? _entries;
    if (items.isEmpty) return;
    final generation = ++_probeGeneration;
    final uniqueTargets = <String, HostEndpoint>{};
    for (final entry in items) {
      for (final ep in entry.effectiveEndpoints) {
        uniqueTargets.putIfAbsent(ep.probeKey, () => ep);
      }
    }
    setState(() {
      for (final probeKey in uniqueTargets.keys) {
        _latencies[probeKey] = const ServerLatencyResult.probing();
      }
    });
    await Future.wait(
      uniqueTargets.entries.map((pair) async {
        final result = await widget.latencyProber(
          pair.value.normalizedUrl,
          certificateFingerprint: pair.value.normalizedFingerprint,
        );
        if (!mounted || generation != _probeGeneration) return;
        setState(() {
          _latencies[pair.key] = result;
        });
      }),
    );
  }

  Future<void> _removeEntry(LoginHistoryEntry entry) async {
    try {
      final next = await widget.historyStore.remove(
        entry.server,
        entry.username,
      );
      if (!mounted) return;
      setState(() => _entries = next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = userFacingError(error));
    }
  }

  Future<void> _openEndpointsManager(LoginHistoryEntry entry) async {
    final isCurrent = _isCurrentHostAccount(entry);
    final updated = await showHostEndpointsDialog(
      context: context,
      entry: entry,
      historyStore: widget.historyStore,
      latencyProber: widget.latencyProber,
      activeConnectedUrl: isCurrent ? widget.currentServer : null,
      onManualConnect: (savedProfile, manualEndpoint) =>
          _switchTo(savedProfile, manualEndpoint: manualEndpoint),
    );
    if (!mounted || updated == null) return;
    await _loadEntries();
  }

  Future<void> _switchTo(
    LoginHistoryEntry entry, {
    HostEndpoint? manualEndpoint,
  }) async {
    if (_switchingKey != null) return;
    final unfinished = widget.pendingUploads?.call() ?? 0;
    if (unfinished > 0) {
      final confirmed = await confirmAction(
        context,
        '切换连接或账号',
        '当前仍有 $unfinished 个上传任务未结束。切换线路或账号将暂停当前传输，是否继续切换？',
        action: '继续切换',
      );
      if (!confirmed || !mounted) return;
    }
    setState(() {
      _switchingKey = entry.key;
      _error = null;
    });
    LightIsleApi? api;
    try {
      final chosen =
          manualEndpoint ??
          await entry.resolveConnectEndpoint(
            widget.latencyProber,
            latencyCache: _latencies,
          );
      if (!mounted) return;
      api =
          widget.apiFactory?.call(
            chosen.normalizedUrl,
            certificateFingerprint: chosen.normalizedFingerprint,
          ) ??
          LightIsleApi(
            chosen.normalizedUrl,
            allowInsecureHttp: true,
            certificateFingerprint: chosen.normalizedFingerprint,
          );
      final status = await api.get('/api/v2/auth/status');
      if (status['configured'] != true) {
        throw StateError('目标服务器尚未完成管理员初始化。');
      }
      final identity = await api.send(
        'POST',
        '/api/v2/auth/login',
        body: <String, dynamic>{
          'username': entry.username,
          'password': entry.password,
        },
      );
      if (!mounted) {
        api.close();
        return;
      }
      if (!api.authenticated) {
        throw StateError('目标服务器未返回有效登录会话。');
      }
      try {
        await widget.historyStore.upsert(
          LoginHistoryEntry(
            server: chosen.normalizedUrl,
            username: identity['username']?.toString() ?? entry.username,
            password: entry.password,
            role: identity['role']?.toString() ?? entry.role,
            certificateFingerprint:
                api.certificateFingerprint ?? chosen.normalizedFingerprint,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } catch (_) {
        // Switching still succeeds even if updating the timestamp fails.
      }
      if (!mounted) {
        api.close();
        return;
      }
      final switchedApi = api;
      api = null;
      await widget.onSwitchAccount(switchedApi, identity);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      api?.close();
      if (mounted) {
        setState(() {
          _error = userFacingError(error);
          _switchingKey = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final busy = _switchingKey != null;

    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 16, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      shape: IsleShapes.card(
        side: BorderSide(color: borderColor, width: 1.0),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '切换服务器与账号',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (_entries.isNotEmpty)
            TextButton.icon(
              key: const Key('switcherRefreshLatenciesButton'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: busy ? null : () => _probeAllLatencies(),
              icon: const Icon(Icons.speed_rounded, size: 15),
              label: const Text('刷新延迟', style: TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '同一台主机可点击路由图标绑定多条地址（如局域网、Tailscale 与公网域名），支持随时开关自动择优或手动选线直连。',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            if (_error != null) ...[
              Notice(_error!, error: true),
              const SizedBox(height: 8),
            ],
            if (_loading)
              const IsleLoadingState(
                compact: true,
                padding: EdgeInsets.symmetric(vertical: 14),
                label: '正在读取保存的主机与账号…',
              )
            else if (_entries.isEmpty)
              const Notice('当前还没有保存其他历史登录账号。登录成功后会自动记录在此列表中。')
            else
              Container(
                decoration: ShapeDecoration(
                  shape: IsleShapes.md(
                    side: BorderSide(color: borderColor, width: 1.0),
                  ),
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.03)
                      : colors.surfaceContainerHighest.withValues(alpha: 0.28),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < _entries.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          indent: 52,
                          color: borderColor,
                        ),
                      _buildSwitcherTile(context, _entries[i]),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          key: const Key('switcherUseNewAccountButton'),
          onPressed: busy
              ? null
              : () async {
                  Navigator.of(context).pop();
                  await widget.onUseNewAccount();
                },
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
          label: const Text('登录其他新账号…'),
        ),
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildSwitcherTile(BuildContext context, LoginHistoryEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isCurrent = _isCurrentHostAccount(entry);
    final isSwitchingThis = _switchingKey == entry.key;
    final busy = _switchingKey != null;
    final preferred = entry.selectPreferredEndpoint(_latencies);
    final latency =
        _latencies[preferred.probeKey] ?? _latencies[entry.serverProbeKey];
    final count = entry.effectiveEndpoints.length;
    final shownUrl = isCurrent
        ? LoginHistoryEntry.normalizeServer(widget.currentServer)
        : preferred.normalizedUrl;

    return Container(
      key: Key('switcherHistoryItem_${entry.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      color: isCurrent
          ? colors.primary.withValues(alpha: isDark ? 0.14 : 0.07)
          : Colors.transparent,
      child: Row(
        children: [
          IsleSquircleBadge(
            icon: entry.isAdmin
                ? Icons.admin_panel_settings_rounded
                : Icons.person_rounded,
            color: colors.primary,
            size: 32,
            iconSize: 16.5,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 5,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      entry.username,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (entry.hostLabel != null &&
                        entry.hostLabel!.trim().isNotEmpty)
                      Text(
                        '· ${entry.hostLabel!.trim()}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (isCurrent)
                      const IsleBadgePill(
                        label: '当前使用',
                        color: Color(0xff10b981),
                        icon: Icons.check_circle_rounded,
                      )
                    else if (entry.role != null)
                      IsleStatusBadge(
                        label: entry.isAdmin ? '管理员' : '成员',
                        color: colors.primary,
                      ),
                    if (count > 1)
                      IsleStatusBadge(
                        label: entry.autoSelectEndpoint
                            ? '自动择优 · $count 线路'
                            : '固定 · $count 线路',
                        color: entry.autoSelectEndpoint
                            ? const Color(0xff0a84ff)
                            : colors.onSurfaceVariant,
                      ),
                    ServerLatencyBadge(
                      key: Key('switcherLatency_${entry.key}'),
                      result: latency,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  shownUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: Key('switcherEndpointsButton_${entry.key}'),
            tooltip: '多地址管理、自动择优开关与手动选线',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            onPressed: busy ? null : () => _openEndpointsManager(entry),
            icon: Icon(
              Icons.alt_route_rounded,
              size: 17,
              color: count > 1 ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
          if (!isCurrent) ...[
            const SizedBox(width: 4),
            IslePillButton(
              key: Key('switchAccountButton_${entry.key}'),
              label: isSwitchingThis ? '切换中…' : '切换',
              icon: Icons.swap_horiz_rounded,
              variant: IslePillVariant.primary,
              compact: true,
              onPressed: busy ? null : () => _switchTo(entry),
            ),
          ],
          const SizedBox(width: 2),
          IconButton(
            key: Key('switchAccountRemove_${entry.key}'),
            tooltip: '移除此历史记录',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            onPressed: busy ? null : () => _removeEntry(entry),
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 17,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
