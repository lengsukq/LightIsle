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
  required FutureOr<void> Function(LightIsleApi api, Map<String, dynamic> identity) onSwitchAccount,
  required Future<void> Function() onUseNewAccount,
  int Function()? pendingUploads,
  ServerLatencyProber? latencyProber,
  LightIsleApi Function(String serverUrl, {String? certificateFingerprint})? apiFactory,
}) => showDialog<void>(
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
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '同一台主机可点击路由图标绑定多条地址（如局域网、Tailscale 与公网域名），支持随时开关自动择优或手动选线直连。',
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
                label: '正在读取保存的主机与账号…',
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
                const SizedBox(height: 4),
                Text(
                  shownUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: Key('switcherEndpointsButton_${entry.key}'),
            tooltip: '多地址管理、自动择优开关与手动选线',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: busy ? null : () => _openEndpointsManager(entry),
            icon: Icon(
              Icons.alt_route_rounded,
              size: 18,
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

/// Dialog for managing one host's multiple addresses, toggling conservative
/// automatic route selection ON/OFF, and manually connecting to any address.
Future<LoginHistoryEntry?> showHostEndpointsDialog({
  required BuildContext context,
  required LoginHistoryEntry entry,
  required LoginHistoryStore historyStore,
  ServerLatencyProber? latencyProber,
  String? activeConnectedUrl,
  Future<void> Function(LoginHistoryEntry updated, HostEndpoint chosen)?
  onManualConnect,
}) => showDialog<LoginHistoryEntry>(
  context: context,
  builder: (_) => _HostEndpointsDialog(
    entry: entry,
    historyStore: historyStore,
    latencyProber: latencyProber ?? probeServerLatency,
    activeConnectedUrl: activeConnectedUrl,
    onManualConnect: onManualConnect,
  ),
);

class _HostEndpointsDialog extends StatefulWidget {
  const _HostEndpointsDialog({
    required this.entry,
    required this.historyStore,
    required this.latencyProber,
    this.activeConnectedUrl,
    this.onManualConnect,
  });

  final LoginHistoryEntry entry;
  final LoginHistoryStore historyStore;
  final ServerLatencyProber latencyProber;
  final String? activeConnectedUrl;
  final Future<void> Function(LoginHistoryEntry updated, HostEndpoint chosen)?
  onManualConnect;

  @override
  State<_HostEndpointsDialog> createState() => _HostEndpointsDialogState();
}

class _HostEndpointsDialogState extends State<_HostEndpointsDialog> {
  late final TextEditingController _hostLabelCtrl;
  final _newUrlCtrl = TextEditingController();
  final _newLabelCtrl = TextEditingController();
  final _newPinCtrl = TextEditingController();
  late bool _autoSelect;
  late List<HostEndpoint> _endpoints;
  final Map<String, ServerLatencyResult> _latencies = {};
  bool _saving = false;
  String? _connectingUrl, _error;
  int _probeGen = 0;

  @override
  void initState() {
    super.initState();
    _hostLabelCtrl = TextEditingController(text: widget.entry.hostLabel ?? '');
    _autoSelect = widget.entry.autoSelectEndpoint;
    _endpoints = List<HostEndpoint>.from(widget.entry.effectiveEndpoints);
    unawaited(_probeAll());
  }

  @override
  void dispose() {
    _hostLabelCtrl.dispose();
    _newUrlCtrl.dispose();
    _newLabelCtrl.dispose();
    _newPinCtrl.dispose();
    super.dispose();
  }

  Future<void> _probeAll() async {
    if (_endpoints.isEmpty) return;
    final gen = ++_probeGen;
    setState(() {
      for (final ep in _endpoints) {
        _latencies[ep.probeKey] = const ServerLatencyResult.probing();
      }
    });
    await Future.wait(
      _endpoints.map((ep) async {
        final res = await widget.latencyProber(
          ep.normalizedUrl,
          certificateFingerprint: ep.normalizedFingerprint,
        );
        if (mounted && gen == _probeGen) {
          setState(() => _latencies[ep.probeKey] = res);
        }
      }),
    );
  }

  void _addEndpoint() {
    setState(() => _error = null);
    if (_endpoints.length >= LoginHistoryEntry.maxEndpointsPerHost) {
      setState(() => _error = '同一主机最多保存 ${LoginHistoryEntry.maxEndpointsPerHost} 条候选地址。');
      return;
    }
    final normalized = LoginHistoryEntry.normalizeUserInputServer(_newUrlCtrl.text);
    final parsed = Uri.tryParse(normalized);
    if (normalized.isEmpty || parsed == null || !parsed.isAbsolute || parsed.host.isEmpty) {
      setState(() => _error = '请输入有效的 HTTP 或 HTTPS 服务器地址。');
      return;
    }
    if (_endpoints.any((e) => e.normalizedUrl == normalized)) {
      setState(() => _error = '该地址已在此主机列表中，无需重复添加。');
      return;
    }
    final rawPin = _newPinCtrl.text.trim();
    String? validPin;
    if (rawPin.isNotEmpty) {
      if (!normalized.startsWith('https://')) {
        setState(() => _error = '证书指纹仅适用于 HTTPS 加密地址。');
        return;
      }
      validPin = LoginHistoryEntry.normalizeFingerprint(rawPin);
      if (validPin == null) {
        setState(() => _error = '请输入完整的 64 位 SHA-256 证书指纹。');
        return;
      }
    }
    final added = HostEndpoint(
      url: normalized,
      label: _newLabelCtrl.text.trim().isEmpty ? null : _newLabelCtrl.text.trim(),
      certificateFingerprint: validPin,
    );
    setState(() {
      _endpoints = [..._endpoints, added];
      _newUrlCtrl.clear();
      _newLabelCtrl.clear();
      _newPinCtrl.clear();
    });
    unawaited(_probeAll());
  }

  LoginHistoryEntry _buildUpdatedEntry() {
    final primary = _endpoints.first;
    final trimmedLabel = _hostLabelCtrl.text.trim();
    return LoginHistoryEntry(
      server: primary.normalizedUrl,
      username: widget.entry.username,
      password: widget.entry.password,
      role: widget.entry.role,
      certificateFingerprint: primary.normalizedFingerprint,
      hostLabel: trimmedLabel.isEmpty ? null : trimmedLabel,
      autoSelectEndpoint: _autoSelect,
      endpoints: List<HostEndpoint>.unmodifiable(_endpoints),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<LoginHistoryEntry?> _persistCurrent() async {
    final updated = _buildUpdatedEntry();
    final savedList = await widget.historyStore.saveHostProfile(
      originalKey: widget.entry.key,
      updatedProfile: updated,
    );
    return savedList.firstWhere((i) => i.key == updated.key, orElse: () => updated);
  }

  Future<void> _saveAndClose() async {
    if (_saving || _connectingUrl != null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await _persistCurrent();
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = userFacingError(e); });
    }
  }

  Future<void> _manualConnect(HostEndpoint ep) async {
    if (widget.onManualConnect == null || _saving || _connectingUrl != null) return;
    setState(() { _connectingUrl = ep.normalizedUrl; _error = null; });
    try {
      final saved = await _persistCurrent() ?? _buildUpdatedEntry();
      if (!mounted) return;
      Navigator.of(context).pop(saved);
      await widget.onManualConnect!(saved, ep);
    } catch (e) {
      if (mounted) setState(() { _connectingUrl = null; _error = userFacingError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final busy = _saving || _connectingUrl != null;
    final normalizedNew = LoginHistoryEntry.normalizeUserInputServer(_newUrlCtrl.text);
    final activeNorm = widget.activeConnectedUrl == null
        ? null
        : LoginHistoryEntry.normalizeServer(widget.activeConnectedUrl!);

    return AlertDialog(
      key: const Key('hostEndpointsDialog'),
      scrollable: true,
      title: Row(
        children: [
          Expanded(child: Text('主机多地址 · ${widget.entry.username}')),
          TextButton.icon(
            key: const Key('probeHostEndpointsButton'),
            onPressed: busy ? null : _probeAll,
            icon: const Icon(Icons.speed_rounded, size: 16),
            label: const Text('全部测速'),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('hostProfileLabelField'),
              controller: _hostLabelCtrl,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: '主机备注名（选填）',
                hintText: '例如：家里 Mac mini',
                isDense: true,
                prefixIcon: Icon(Icons.computer_rounded, size: 18),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              key: const Key('hostAutoSelectSwitch'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              value: _autoSelect,
              onChanged: busy ? null : (v) => setState(() => _autoSelect = v),
              title: const Text('默认自动择优连接', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              subtitle: Text(
                _autoSelect
                    ? '仅在登录、启动恢复或切换时测速，按「局域网、Tailscale、公网域名」优先选最快可用地址；连接建立后保持稳定，不在传输中途切线。'
                    : '已关闭：仅固定连接默认主地址，不会自动探测或跳到其他备用地址。',
                style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
              ),
            ),
            const Divider(height: 18),
            Text(
              '已绑定线路（${_endpoints.length}/${LoginHistoryEntry.maxEndpointsPerHost}）',
              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _endpoints.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              HostEndpointTile(
                endpoint: _endpoints[i],
                isPrimary: i == 0,
                isActive: activeNorm != null && activeNorm == _endpoints[i].normalizedUrl,
                canRemove: _endpoints.length > 1,
                busy: busy,
                latency: _latencies[_endpoints[i].probeKey],
                connecting: _connectingUrl == _endpoints[i].normalizedUrl,
                onSetPrimary: i == 0 ? null : () => setState(() => _endpoints.insert(0, _endpoints.removeAt(i))),
                onManualConnect: widget.onManualConnect == null ? null : () => _manualConnect(_endpoints[i]),
                onRemove: () => setState(() => _endpoints.removeAt(i)),
              ),
            ],
            const Divider(height: 22),
            Text('添加备用地址（如 Tailscale IP 或公网穿透域名）', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              key: const Key('newHostEndpointUrlField'),
              controller: _newUrlCtrl,
              enabled: !busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '备用连接地址',
                hintText: 'https://nas.example.com 或 100.88.1.2:16666',
                isDense: true,
                prefixIcon: Icon(Icons.add_link_rounded, size: 18),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('newHostEndpointLabelField'),
                    controller: _newLabelCtrl,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: '线路标签（选填）', hintText: '如：家里局域网 / 公网隧道', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  key: const Key('addHostEndpointButton'),
                  onPressed: busy ? null : _addEndpoint,
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text('添加线路'),
                ),
              ],
            ),
            if (normalizedNew.startsWith('https://')) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('newHostEndpointPinField'),
                controller: _newPinCtrl,
                enabled: !busy,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '该地址专属 SHA-256 证书指纹（自签名 HTTPS 必填，公信证书留空）', isDense: true),
              ),
            ],
            if (_error != null) ...[const SizedBox(height: 10), Notice(_error!, error: true)],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(key: const Key('saveHostEndpointsButton'), onPressed: busy ? null : _saveAndClose, child: Text(_saving ? '保存中…' : '保存设置')),
      ],
    );
  }
}
