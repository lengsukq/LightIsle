import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/insecure_http_allowlist.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/login_history_store.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'login_flow_background.dart';
import 'login_history_section.dart';
import 'nas_discovery_picker.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.onSignedIn,
    this.expired = false,
    this.notice,
    this.historyStore,
    this.latencyProber,
    @visibleForTesting this.httpAllowlist,
    @visibleForTesting this.apiFactory,
  });
  final String? notice;
  final FutureOr<void> Function(LightIsleApi, Map<String, dynamic>) onSignedIn;
  final bool expired;
  final LoginHistoryStore? historyStore;
  final ServerLatencyProber? latencyProber;
  @visibleForTesting
  final InsecureHttpAllowlist? httpAllowlist;
  @visibleForTesting
  final LightIsleApi Function(
    String serverUrl, {
    String? certificateFingerprint,
  })?
  apiFactory;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _fingerprint = TextEditingController();
  final _usernameFocus = FocusNode();
  late final LoginHistoryStore _historyStore =
      widget.historyStore ?? LoginHistoryStore();
  late final ServerLatencyProber _latencyProber =
      widget.latencyProber ?? probeServerLatency;
  late final InsecureHttpAllowlist _httpAllowlist =
      widget.httpAllowlist ?? InsecureHttpAllowlist.instance;
  List<LoginHistoryEntry> _history = const [];
  Set<String> _allowedHttpOrigins = const {};
  final Map<String, ServerLatencyResult> _historyLatencies = {};
  ServerLatencyResult? _currentServerLatency;
  String? _selectedHistoryKey;
  int _historyProbeGen = 0, _currentProbeGen = 0;
  bool _busy = false, _hide = true;
  bool _securityExpanded = false;
  SharedPreferences? _preferences;
  String? _pinOrigin;
  String? _error;
  LightIsleApi? _connecting;

  @override
  void initState() {
    super.initState();
    _allowedHttpOrigins = _httpAllowlist.origins;
    _loadAddress();
    unawaited(_loadHttpAllowlist());
    unawaited(_loadHistory());
  }

  Future<void> _loadHttpAllowlist() async {
    final loaded = await _httpAllowlist.load();
    if (!mounted) return;
    setState(() => _allowedHttpOrigins = loaded);
  }

  Future<void> _toggleCurrentHttpAllowlist(bool enable, String origin) async {
    if (_busy) return;
    if (enable) {
      final confirmed = await confirmAction(
        context,
        '允许公网明文 HTTP 连接？',
        '将 $origin 加入本机明文 HTTP 白名单后，登录密码与会话 Cookie 将不经 TLS 加密传输。\n\n仅建议在个人临时调试或信任的网络环境使用；长期外网访问请优先配置 HTTPS。',
        action: '确认加入白名单',
      );
      if (!confirmed || !mounted) return;
      try {
        final updated = await _httpAllowlist.add(
          origin,
          preferences: _preferences,
        );
        if (!mounted) return;
        setState(() {
          _allowedHttpOrigins = updated;
          _error = null;
        });
      } catch (error) {
        if (!mounted) return;
        setState(() => _error = userFacingError(error));
      }
      return;
    }
    final updated = await _httpAllowlist.remove(
      origin,
      preferences: _preferences,
    );
    if (!mounted) return;
    setState(() => _allowedHttpOrigins = updated);
  }

  Future<void> _removeAllowedHttpOrigin(String origin) async {
    if (_busy) return;
    final updated = await _httpAllowlist.remove(
      origin,
      preferences: _preferences,
    );
    if (!mounted) return;
    setState(() => _allowedHttpOrigins = updated);
  }

  Future<void> _loadHistory() async {
    try {
      final entries = await _historyStore.readAll();
      if (!mounted) return;
      setState(() => _history = entries);
      if (entries.isNotEmpty) {
        unawaited(_probeHistoryLatencies(entries));
      }
    } catch (_) {
      /* History is optional convenience storage. */
    }
  }

  Future<void> _probeHistoryLatencies([List<LoginHistoryEntry>? source]) async {
    final entries = source ?? _history;
    if (entries.isEmpty) return;
    final gen = ++_historyProbeGen;
    final unique = <String, HostEndpoint>{};
    for (final entry in entries) {
      for (final ep in entry.effectiveEndpoints) {
        unique.putIfAbsent(ep.probeKey, () => ep);
      }
    }
    setState(() {
      for (final key in unique.keys) {
        _historyLatencies[key] = const ServerLatencyResult.probing();
      }
    });
    await Future.wait(
      unique.entries.map((pair) async {
        final result = await _latencyProber(
          pair.value.normalizedUrl,
          certificateFingerprint: pair.value.normalizedFingerprint,
        );
        if (!mounted || gen != _historyProbeGen) return;
        setState(() {
          _historyLatencies[pair.key] = result;
          final currentProbeKey = LoginHistoryEntry.buildServerProbeKey(
            _server.text,
            _fingerprint.text,
          );
          if (currentProbeKey == pair.key) {
            _currentServerLatency = result;
          }
        });
      }),
    );
  }

  String _normalizeServerAddress(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final hasPortOrPath = RegExp(
      r'^(\[[^\]]+\]|[^/:]+)(:\d+|/)',
    ).hasMatch(trimmed);
    return hasPortOrPath ? 'http://$trimmed' : 'http://$trimmed:16666';
  }

  Future<void> _probeCurrentServer() async {
    final url = _normalizeServerAddress(_server.text);
    if (url.isEmpty) return;
    final gen = ++_currentProbeGen;
    final pin = _fingerprint.text.trim().isEmpty
        ? null
        : _fingerprint.text.trim();
    final probeKey = LoginHistoryEntry.buildServerProbeKey(url, pin);
    setState(() {
      _currentServerLatency = const ServerLatencyResult.probing();
    });
    final result = await _latencyProber(url, certificateFingerprint: pin);
    if (!mounted || gen != _currentProbeGen) return;
    setState(() {
      _currentServerLatency = result;
      _historyLatencies[probeKey] = result;
    });
  }

  void _selectHistoryEntry(
    LoginHistoryEntry entry, {
    HostEndpoint? forcedEndpoint,
  }) {
    final chosen =
        forcedEndpoint ?? entry.selectPreferredEndpoint(_historyLatencies);
    _server.text = chosen.normalizedUrl;
    _username.text = entry.username;
    _password.text = entry.password;
    _pinOrigin = _httpsOrigin(chosen.normalizedUrl);
    _fingerprint.text = chosen.normalizedFingerprint ?? '';
    setState(() {
      _selectedHistoryKey = entry.key;
      _currentServerLatency = _historyLatencies[chosen.probeKey];
      if (chosen.normalizedFingerprint != null &&
          chosen.normalizedFingerprint!.isNotEmpty) {
        _securityExpanded = true;
      }
      _error = null;
    });
  }

  Future<void> _quickLoginHistoryEntry(LoginHistoryEntry entry) async {
    if (_busy) return;
    final chosen = await entry.resolveConnectEndpoint(
      _latencyProber,
      latencyCache: _historyLatencies,
    );
    if (!mounted) return;
    _selectHistoryEntry(entry, forcedEndpoint: chosen);
    await _login();
  }

  Future<void> _openHostEndpointsDialog(LoginHistoryEntry entry) async {
    if (_busy) return;
    final updated = await showHostEndpointsDialog(
      context: context,
      entry: entry,
      historyStore: _historyStore,
      latencyProber: _latencyProber,
      onManualConnect: (saved, manualEndpoint) async {
        if (!mounted || _busy) return;
        _selectHistoryEntry(saved, forcedEndpoint: manualEndpoint);
        await _login();
      },
    );
    if (!mounted || updated == null) return;
    await _loadHistory();
    if (_selectedHistoryKey == entry.key ||
        _selectedHistoryKey == updated.key) {
      _selectHistoryEntry(updated);
    }
  }

  Future<void> _removeHistoryEntry(LoginHistoryEntry entry) async {
    try {
      final updated = await _historyStore.remove(entry.server, entry.username);
      if (!mounted) return;
      setState(() {
        _history = updated;
        if (_selectedHistoryKey == entry.key) {
          _selectedHistoryKey = null;
          _username.clear();
          _password.clear();
        }
      });
    } catch (error) {
      debugPrint('LoginPage: history entry removal skipped: $error');
    }
  }

  Future<void> _loadAddress() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (mounted) {
        _preferences = preferences;
        if (_server.text.isEmpty) {
          _server.text = preferences.getString('lightisle.server') ?? '';
        }
        if (_fingerprint.text.isEmpty) _addressChanged(_server.text);
      }
    } catch (_) {
      /* Remembering an address is optional. */
    }
  }

  String? _httpsOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? uri.origin
        : null;
  }

  void _addressChanged(String value) {
    final origin = _httpsOrigin(value);
    if (origin != _pinOrigin) {
      _pinOrigin = origin;
      _fingerprint.text = origin == null
          ? ''
          : _preferences?.getString('lightisle.certificatePin.$origin') ?? '';
    }
    final probeKey = LoginHistoryEntry.buildServerProbeKey(
      value,
      _fingerprint.text,
    );
    _currentServerLatency = _historyLatencies[probeKey];
    if (_selectedHistoryKey != null &&
        LoginHistoryEntry.buildKey(value, _username.text) !=
            _selectedHistoryKey) {
      _selectedHistoryKey = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final rawServer = _normalizeServerAddress(_server.text);
    if (rawServer != _server.text.trim() && rawServer.isNotEmpty) {
      _server.text = rawServer;
    }
    final rawUsername = _username.text.trim();
    final rawPassword = _password.text;
    final rawPin = _fingerprint.text.trim().isEmpty
        ? null
        : _fingerprint.text.trim();
    LightIsleApi? api;
    try {
      api =
          widget.apiFactory?.call(rawServer, certificateFingerprint: rawPin) ??
          LightIsleApi(
            rawServer,
            allowInsecureHttp: true,
            allowedInsecureHttpOrigins: widget.httpAllowlist?.origins,
            certificateFingerprint: rawPin,
          );
      _connecting = api;
      final status = await api.get('/api/v2/auth/status');
      if (status['configured'] != true) {
        throw StateError('服务尚未初始化，请先在 Mac 原生管理端创建首任管理员。');
      }
      final identity = await api.send(
        'POST',
        '/api/v2/auth/login',
        body: {'username': rawUsername, 'password': rawPassword},
      );
      if (!mounted) {
        api.close();
        return;
      }
      if (!api.authenticated) throw StateError('服务未返回可用会话，请检查连接地址。');
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('lightisle.server', rawServer);
        final origin = _httpsOrigin(rawServer);
        if (origin != null) {
          final key = 'lightisle.certificatePin.$origin';
          if (rawPin == null) {
            await preferences.remove(key);
          } else {
            await preferences.setString(key, rawPin);
          }
        }
      } catch (_) {
        /* The session is saved separately in OS-protected storage. */
      }
      try {
        final canonicalServer = LoginHistoryEntry.normalizeServer(rawServer);
        final canonicalUser = identity['username'] is String
            ? (identity['username'] as String).trim()
            : rawUsername;
        await _historyStore.upsert(
          LoginHistoryEntry(
            server: canonicalServer,
            username: canonicalUser.isNotEmpty ? canonicalUser : rawUsername,
            password: rawPassword,
            role: identity['role'] is String
                ? identity['role'] as String
                : null,
            certificateFingerprint: api.certificateFingerprint ?? rawPin,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } catch (_) {
        /* Login succeeds even if the history vault is locked. */
      }
      if (!mounted) {
        api.close();
        return;
      }
      _password.clear();
      _connecting = null;
      await widget.onSignedIn(api, identity);
    } catch (error) {
      api?.close();
      if (mounted) {
        final needsAllowlist =
            error is ArgumentError &&
            InsecureHttpAllowlist.requiresAllowlist(rawServer) &&
            !_httpAllowlist.contains(rawServer);
        setState(() {
          _error = userFacingError(error);
          if (needsAllowlist) _securityExpanded = true;
        });
      }
    } finally {
      _connecting = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _connecting?.close();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _fingerprint.dispose();
    _usernameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(
          child: IgnorePointer(child: LoginFlowBackground()),
        ),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
              final wide =
                  width >= 960 &&
                  constraints.maxHeight >= 580 &&
                  textScale <= 1.45;
              final medium = !wide && width >= 600 && textScale <= 1.35;
              final inset = width < 360
                  ? 14.0
                  : width < 680
                  ? 20.0
                  : 36.0;
              return Center(
                child: SingleChildScrollView(
                  key: const Key('loginScrollView'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.symmetric(
                    horizontal: inset,
                    vertical: width < 600 ? 16 : 28,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: wide
                          ? 960
                          : medium
                          ? 540
                          : 400,
                    ),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Expanded(
                                flex: 10,
                                child: Padding(
                                  padding: EdgeInsets.only(right: 40),
                                  child: LoginBrandHeader(wide: true),
                                ),
                              ),
                              Expanded(
                                flex: 9,
                                child: _buildForm(
                                  context,
                                  wide: true,
                                  medium: false,
                                ),
                              ),
                            ],
                          )
                        : _buildForm(context, wide: false, medium: medium),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );

  List<Widget> _buildServerAddressFields(ThemeData theme, ColorScheme colors) {
    final normalized = _normalizeServerAddress(_server.text);
    final showNormalizedHint =
        _server.text.trim().isNotEmpty &&
        !_server.text.trim().startsWith('http://') &&
        !_server.text.trim().startsWith('https://');
    return [
      TextFormField(
        controller: _server,
        enabled: !_busy,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
        autocorrect: false,
        onChanged: _addressChanged,
        decoration: const InputDecoration(
          isDense: true,
          labelText: '服务器地址',
          hintText: '192.168.1.100:16666',
          prefixIcon: Icon(Icons.dns_outlined, size: 19),
        ),
        validator: (v) =>
            v == null || v.trim().isEmpty ? '请输入 Mac 管理端显示的连接地址' : null,
      ),
      if (showNormalizedHint)
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(
            '将连接：$normalized',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            NasDiscoveryPicker(
              enabled: !_busy,
              onSelected: (server) async {
                if (_busy) return;
                _server.text = server.address;
                _addressChanged(server.address);
                setState(() {
                  _securityExpanded = _httpsOrigin(server.address) != null;
                  _error = null;
                });
                if (_username.text.trim().isEmpty) {
                  _usernameFocus.requestFocus();
                }
              },
            ),
            CurrentServerLatencyBar(
              serverUrl: normalized,
              result: _currentServerLatency,
              enabled: !_busy,
              onProbe: _probeCurrentServer,
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildUsernameField() => TextFormField(
    controller: _username,
    focusNode: _usernameFocus,
    enabled: !_busy,
    textInputAction: TextInputAction.next,
    autocorrect: false,
    autofillHints: const [AutofillHints.username],
    onChanged: (_) {
      if (_selectedHistoryKey != null &&
          LoginHistoryEntry.buildKey(_server.text, _username.text) !=
              _selectedHistoryKey) {
        setState(() => _selectedHistoryKey = null);
      }
    },
    decoration: const InputDecoration(
      isDense: true,
      labelText: '用户名',
      prefixIcon: Icon(Icons.person_outline_rounded, size: 19),
    ),
    validator: (v) => v == null || v.trim().isEmpty ? '请输入用户名' : null,
  );

  Widget _buildPasswordField() => TextFormField(
    controller: _password,
    enabled: !_busy,
    obscureText: _hide,
    textInputAction: TextInputAction.done,
    autofillHints: const [AutofillHints.password],
    decoration: InputDecoration(
      isDense: true,
      labelText: '密码',
      prefixIcon: const Icon(Icons.lock_outline_rounded, size: 19),
      suffixIcon: IconButton(
        tooltip: _hide ? '显示密码' : '隐藏密码',
        visualDensity: VisualDensity.compact,
        onPressed: () => setState(() => _hide = !_hide),
        icon: Icon(
          _hide ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          size: 19,
        ),
      ),
    ),
    validator: (v) => v == null || v.isEmpty ? '请输入密码' : null,
    onFieldSubmitted: (_) => _login(),
  );

  List<Widget> _buildCredentialFields({required bool sideBySide}) {
    if (sideBySide) {
      return [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildUsernameField()),
            const SizedBox(width: 12),
            Expanded(child: _buildPasswordField()),
          ],
        ),
      ];
    }
    return [
      _buildUsernameField(),
      const SizedBox(height: 11),
      _buildPasswordField(),
    ];
  }

  List<Widget> _buildSecurityPinFields(ColorScheme colors) {
    final normalizedServer = _normalizeServerAddress(_server.text);
    final publicHttpOrigin =
        InsecureHttpAllowlist.requiresAllowlist(normalizedServer)
        ? InsecureHttpAllowlist.normalizeOrigin(normalizedServer)
        : null;
    final currentOriginAllowed =
        publicHttpOrigin != null &&
        _allowedHttpOrigins.contains(publicHttpOrigin);
    final sortedAllowlist = _allowedHttpOrigins.toList()..sort();
    final securityLabel = _fingerprint.text.isNotEmpty
        ? '连接安全设置 · 已记住证书指纹'
        : currentOriginAllowed
        ? '连接安全设置 · 已信任明文 HTTP'
        : sortedAllowlist.isNotEmpty
        ? '连接安全设置 · ${sortedAllowlist.length} 条 HTTP 白名单'
        : '连接安全设置';
    return [
      Row(
        children: [
          Flexible(
            child: TextButton.icon(
              key: const Key('connectionSecurityToggle'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: const Size(0, 32),
              ),
              onPressed: _busy
                  ? null
                  : () =>
                        setState(() => _securityExpanded = !_securityExpanded),
              icon: Icon(
                _securityExpanded ? Icons.expand_less : Icons.shield_outlined,
                size: 16,
              ),
              label: Text(
                securityLabel,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '首次连接指引',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: _busy ? null : () => showLoginSetupGuideDialog(context),
            icon: Icon(
              Icons.help_outline_rounded,
              size: 17,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
      IsleAnimatedExpand(
        expanded: _securityExpanded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            TextFormField(
              key: const Key('certificateFingerprint'),
              controller: _fingerprint,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'HTTPS 证书 SHA-256 指纹（可选）',
                helperText: '仅自签名 HTTPS 首次连接需核对；受信任证书可留空。',
                helperMaxLines: 3,
                prefixIcon: Icon(Icons.verified_user_outlined, size: 19),
              ),
              validator: (value) {
                final pin = (value ?? '').replaceAll(RegExp(r'[:\s]'), '');
                if (pin.isEmpty) return null;
                if (_httpsOrigin(_normalizeServerAddress(_server.text)) ==
                    null) {
                  return '证书指纹仅用于 HTTPS 地址';
                }
                return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(pin)
                    ? null
                    : '请输入完整的 64 位 SHA-256 指纹';
              },
            ),
            const SizedBox(height: 8),
            if (publicHttpOrigin != null)
              SwitchListTile.adaptive(
                key: const Key('allowInsecureHttpOriginSwitch'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                value: currentOriginAllowed,
                onChanged: _busy
                    ? null
                    : (v) => _toggleCurrentHttpAllowlist(v, publicHttpOrigin),
                title: const Text(
                  '允许此地址使用明文 HTTP',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '$publicHttpOrigin（风险自担：密码与会话不加密）',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            if (sortedAllowlist.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '本机明文 HTTP 白名单（精确 Origin）',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              for (final origin in sortedAllowlist)
                Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: colors.tertiary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        origin,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      key: Key('removeHttpAllowlist_$origin'),
                      tooltip: '移出白名单',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: _busy
                          ? null
                          : () => _removeAllowedHttpOrigin(origin),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
            ] else if (publicHttpOrigin == null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                child: Text(
                  '公网地址默认要求 HTTPS；输入公网 http:// 地址时，可在此按精确 Origin 加入本机白名单。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ];
  }

  Widget _buildForm(
    BuildContext context, {
    required bool wide,
    required bool medium,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardPadding = screenWidth < 380
        ? 16.0
        : wide
        ? 26.0
        : medium
        ? 22.0
        : 20.0;
    return AutofillGroup(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!wide) ...[
              LoginBrandHeader(wide: false, medium: medium),
              const SizedBox(height: 18),
            ],
            IsleSurface(
              radius: IsleRadius.hero,
              padding: EdgeInsets.all(cardPadding),
              glass: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide) ...[
                    Text(
                      '欢迎回来',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.45,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  LoginHistorySection(
                    entries: _history,
                    latencies: _historyLatencies,
                    selectedKey: _selectedHistoryKey,
                    busy: _busy,
                    onSelect: _selectHistoryEntry,
                    onQuickLogin: _quickLoginHistoryEntry,
                    onRemove: _removeHistoryEntry,
                    onRefreshLatencies: _probeHistoryLatencies,
                    onManageEndpoints: _openHostEndpointsDialog,
                  ),
                  if (widget.expired) const Notice('登录已过期或失效，请重新登录。'),
                  if (widget.notice != null)
                    Notice(widget.notice!, error: true),
                  ..._buildServerAddressFields(theme, colors),
                  const SizedBox(height: 11),
                  ..._buildCredentialFields(sideBySide: medium),
                  const SizedBox(height: 4),
                  ..._buildSecurityPinFields(colors),
                  if (_error != null) Notice(_error!, error: true),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: _busy ? null : _login,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: Text(_busy ? '正在连接…' : '连接并登录'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '家庭局域网默认使用 HTTP；开启 HTTPS 时可核对证书指纹',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                color: colors.onSurfaceVariant.withValues(alpha: 0.76),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
