import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/login_history_store.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'login_history_section.dart';

Future<void> showAccountSwitcherDialog({
  required BuildContext context,
  required String currentServer,
  required String currentUsername,
  required LoginHistoryStore historyStore,
  required FutureOr<void> Function(
    LightIsleApi api,
    Map<String, dynamic> identity,
  )
  onSwitchAccount,
  required Future<void> Function() onUseNewAccount,
  int Function()? pendingUploads,
  ServerLatencyProber? latencyProber,
  LightIsleApi Function(String serverUrl, {String? certificateFingerprint})?
  apiFactory,
}) {
  return showDialog<void>(
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
}

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

  final String currentServer;
  final String currentUsername;
  final LoginHistoryStore historyStore;
  final FutureOr<void> Function(
    LightIsleApi api,
    Map<String, dynamic> identity,
  )
  onSwitchAccount;
  final Future<void> Function() onUseNewAccount;
  final int Function()? pendingUploads;
  final ServerLatencyProber latencyProber;
  final LightIsleApi Function(
    String serverUrl, {
    String? certificateFingerprint,
  })?
  apiFactory;

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

  String get _currentKey =>
      LoginHistoryEntry.buildKey(widget.currentServer, widget.currentUsername);

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
    final uniqueTargets = <String, LoginHistoryEntry>{};
    for (final entry in items) {
      uniqueTargets.putIfAbsent(entry.serverProbeKey, () => entry);
    }
    setState(() {
      for (final probeKey in uniqueTargets.keys) {
        _latencies[probeKey] = const ServerLatencyResult.probing();
      }
    });
    await Future.wait(
      uniqueTargets.entries.map((pair) async {
        final result = await widget.latencyProber(
          pair.value.server,
          certificateFingerprint: pair.value.certificateFingerprint,
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

  Future<void> _switchTo(LoginHistoryEntry entry) async {
    if (_switchingKey != null) return;
    final unfinished = widget.pendingUploads?.call() ?? 0;
    if (unfinished > 0) {
      final confirmed = await confirmAction(
        context,
        '切换登录账号',
        '当前仍有 $unfinished 个上传任务未结束。切换账号或服务器将暂停当前传输，是否继续切换？',
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
      api =
          widget.apiFactory?.call(
            entry.server,
            certificateFingerprint: entry.certificateFingerprint,
          ) ??
          LightIsleApi(
            entry.server,
            allowInsecureHttp: true,
            certificateFingerprint: entry.certificateFingerprint,
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
          entry.copyWith(
            username: identity['username']?.toString() ?? entry.username,
            role: identity['role']?.toString() ?? entry.role,
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
    final busy = _switchingKey != null;

    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          const Expanded(child: Text('切换服务器与账号')),
          if (_entries.isNotEmpty)
            TextButton.icon(
              key: const Key('switcherRefreshLatenciesButton'),
              onPressed: busy ? null : () => _probeAllLatencies(),
              icon: const Icon(Icons.speed_rounded, size: 16),
              label: const Text('刷新延迟'),
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
              '按「服务器地址 + 账号名」保存历史凭据。切换前可先对比不同域名或局域网地址的响应延迟。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null) ...[
              Notice(_error!, error: true),
              const SizedBox(height: 8),
            ],
            if (_loading)
              const IsleLoadingState(
                compact: true,
                padding: EdgeInsets.symmetric(vertical: 16),
                label: '正在读取保存的登录历史…',
              )
            else if (_entries.isEmpty)
              const Notice('当前还没有保存其他历史登录账号。登录成功后会自动记录在此列表中。')
            else
              for (var i = 0; i < _entries.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _buildSwitcherTile(context, _entries[i]),
              ],
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
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
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
    final isCurrent = entry.key == _currentKey;
    final isSwitchingThis = _switchingKey == entry.key;
    final busy = _switchingKey != null;

    return Container(
      key: Key('switcherHistoryItem_${entry.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: ShapeDecoration(
        shape: IsleShapes.squircle(
          14,
          side: BorderSide(
            color: isCurrent
                ? colors.primary.withValues(alpha: 0.55)
                : IsleGlass.hairlineBorder(isDark),
            width: isCurrent ? 1.2 : 0.8,
          ),
        ),
        color: isCurrent
            ? colors.primary.withValues(alpha: isDark ? 0.16 : 0.08)
            : (isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : colors.surfaceContainerHighest.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          IsleSquircleBadge(
            icon: entry.isAdmin
                ? Icons.admin_panel_settings_rounded
                : Icons.person_rounded,
            color: colors.primary,
            size: 36,
            iconSize: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      entry.username,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
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
                    ServerLatencyBadge(
                      key: Key('switcherLatency_${entry.key}'),
                      result: _latencies[entry.serverProbeKey],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  entry.server,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isCurrent)
            IslePillButton(
              key: Key('switchAccountButton_${entry.key}'),
              label: isSwitchingThis ? '切换中…' : '切换',
              icon: Icons.swap_horiz_rounded,
              variant: IslePillVariant.primary,
              compact: true,
              onPressed: busy ? null : () => _switchTo(entry),
            ),
          const SizedBox(width: 4),
          IconButton(
            key: Key('switchAccountRemove_${entry.key}'),
            tooltip: '移除此历史记录',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            onPressed: busy ? null : () => _removeEntry(entry),
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
