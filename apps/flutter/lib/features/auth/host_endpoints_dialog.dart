import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_route.dart';
import '../../core/login_history_store.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'login_history_section.dart';

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
}) => showIsleDialog<LoginHistoryEntry>(
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
      setState(
        () => _error =
            '同一主机最多保存 ${LoginHistoryEntry.maxEndpointsPerHost} 条候选地址。',
      );
      return;
    }
    final normalized = LoginHistoryEntry.normalizeUserInputServer(
      _newUrlCtrl.text,
    );
    final parsed = Uri.tryParse(normalized);
    if (normalized.isEmpty ||
        parsed == null ||
        !parsed.isAbsolute ||
        parsed.host.isEmpty) {
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
      label: _newLabelCtrl.text.trim().isEmpty
          ? null
          : _newLabelCtrl.text.trim(),
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
    return savedList.firstWhere(
      (i) => i.key == updated.key,
      orElse: () => updated,
    );
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
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userFacingError(e);
        });
      }
    }
  }

  Future<void> _manualConnect(HostEndpoint ep) async {
    if (widget.onManualConnect == null || _saving || _connectingUrl != null) {
      return;
    }
    setState(() {
      _connectingUrl = ep.normalizedUrl;
      _error = null;
    });
    try {
      final saved = await _persistCurrent() ?? _buildUpdatedEntry();
      if (!mounted) return;
      Navigator.of(context).pop(saved);
      await widget.onManualConnect!(saved, ep);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectingUrl = null;
          _error = userFacingError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final busy = _saving || _connectingUrl != null;
    final normalizedNew = LoginHistoryEntry.normalizeUserInputServer(
      _newUrlCtrl.text,
    );
    final activeNorm = widget.activeConnectedUrl == null
        ? null
        : LoginHistoryEntry.normalizeServer(widget.activeConnectedUrl!);

    return AlertDialog(
      key: const Key('hostEndpointsDialog'),
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
              '主机多地址 · ${widget.entry.username}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton.icon(
            key: const Key('probeHostEndpointsButton'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            onPressed: busy ? null : _probeAll,
            icon: const Icon(Icons.speed_rounded, size: 15),
            label: const Text('全部测速', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
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
            const SizedBox(height: 6),
            SwitchListTile.adaptive(
              key: const Key('hostAutoSelectSwitch'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 2),
              value: _autoSelect,
              onChanged: busy ? null : (v) => setState(() => _autoSelect = v),
              title: const Text(
                '默认自动择优连接',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                _autoSelect
                    ? '仅在登录、启动恢复或切换时测速，按「局域网、Tailscale、公网域名」优先选最快可用地址；连接建立后保持稳定，不在传输中途切线。'
                    : '已关闭：仅固定连接默认主地址，不会自动探测或跳到其他备用地址。',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                  height: 1.38,
                ),
              ),
            ),
            Divider(height: 16, thickness: 1, color: borderColor),
            Text(
              '已绑定线路（${_endpoints.length}/${LoginHistoryEntry.maxEndpointsPerHost}）',
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < _endpoints.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              HostEndpointTile(
                endpoint: _endpoints[i],
                isPrimary: i == 0,
                isActive:
                    activeNorm != null &&
                    activeNorm == _endpoints[i].normalizedUrl,
                canRemove: _endpoints.length > 1,
                busy: busy,
                latency: _latencies[_endpoints[i].probeKey],
                connecting: _connectingUrl == _endpoints[i].normalizedUrl,
                onSetPrimary: i == 0
                    ? null
                    : () => setState(
                        () => _endpoints.insert(0, _endpoints.removeAt(i)),
                      ),
                onManualConnect: widget.onManualConnect == null
                    ? null
                    : () => _manualConnect(_endpoints[i]),
                onRemove: () => setState(() => _endpoints.removeAt(i)),
              ),
            ],
            Divider(height: 18, thickness: 1, color: borderColor),
            Text(
              '添加备用地址（如 Tailscale IP 或公网穿透域名）',
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
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
                    decoration: const InputDecoration(
                      labelText: '线路标签（选填）',
                      hintText: '如：家里局域网 / 公网隧道',
                      isDense: true,
                    ),
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
                decoration: const InputDecoration(
                  labelText: '该地址专属 SHA-256 证书指纹（自签名 HTTPS 必填，公信证书留空）',
                  isDense: true,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Notice(_error!, error: true),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('saveHostEndpointsButton'),
          onPressed: busy ? null : _saveAndClose,
          child: Text(_saving ? '保存中…' : '保存设置'),
        ),
      ],
    );
  }
}
