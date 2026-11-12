import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/login_history_store.dart';
import '../../core/widgets.dart';
import '../../core/user_facing_error.dart';
import 'login_history_section.dart';
import 'nas_discovery_picker.dart';
import 'login_flow_background.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.onSignedIn,
    this.expired = false,
    this.notice,
    this.historyStore,
    this.latencyProber,
    @visibleForTesting this.apiFactory,
  });
  final String? notice;
  final FutureOr<void> Function(LightIsleApi, Map<String, dynamic>) onSignedIn;
  final bool expired;
  final LoginHistoryStore? historyStore;
  final ServerLatencyProber? latencyProber;
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
  late final LoginHistoryStore _historyStore =
      widget.historyStore ?? LoginHistoryStore();
  late final ServerLatencyProber _latencyProber =
      widget.latencyProber ?? probeServerLatency;
  List<LoginHistoryEntry> _history = const [];
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
    _loadAddress();
    unawaited(_loadHistory());
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
    final unique = <String, LoginHistoryEntry>{};
    for (final entry in entries) {
      unique.putIfAbsent(entry.serverProbeKey, () => entry);
    }
    setState(() {
      for (final key in unique.keys) {
        _historyLatencies[key] = const ServerLatencyResult.probing();
      }
    });
    await Future.wait(
      unique.entries.map((pair) async {
        final result = await _latencyProber(
          pair.value.server,
          certificateFingerprint: pair.value.certificateFingerprint,
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

  Future<void> _probeCurrentServer() async {
    final url = _server.text.trim();
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

  void _selectHistoryEntry(LoginHistoryEntry entry) {
    _server.text = entry.server;
    _username.text = entry.username;
    _password.text = entry.password;
    _pinOrigin = _httpsOrigin(entry.server);
    _fingerprint.text = entry.certificateFingerprint ?? '';
    setState(() {
      _selectedHistoryKey = entry.key;
      _currentServerLatency = _historyLatencies[entry.serverProbeKey];
      if (entry.certificateFingerprint != null &&
          entry.certificateFingerprint!.isNotEmpty) {
        _securityExpanded = true;
      }
      _error = null;
    });
  }

  Future<void> _quickLoginHistoryEntry(LoginHistoryEntry entry) async {
    if (_busy) return;
    _selectHistoryEntry(entry);
    await _login();
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
    final rawServer = _server.text.trim();
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
            // Accept both advertised schemes without an extra UI toggle, but the
            // transport still refuses cleartext connections to public IPs.
            allowInsecureHttp: true,
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
        setState(() {
          _error = userFacingError(error);
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
              final inset = width < 360
                  ? 18.0
                  : width < 680
                  ? 24.0
                  : 42.0;
              return Center(
                child: SingleChildScrollView(
                  key: const Key('loginScrollView'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.symmetric(
                    horizontal: inset,
                    vertical: width < 600 ? 22 : 40,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: wide ? 1090 : 460),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Expanded(
                                flex: 11,
                                child: Padding(
                                  padding: EdgeInsets.only(right: 44),
                                  child: LoginBrandHeader(wide: true),
                                ),
                              ),
                              const SizedBox(width: 32),
                              Expanded(
                                flex: 9,
                                child: _buildForm(context, wide: true),
                              ),
                            ],
                          )
                        : _buildForm(context, wide: false),
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
    return [
      TextFormField(
        controller: _server,
        enabled: !_busy,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
        autocorrect: false,
        onChanged: _addressChanged,
        decoration: const InputDecoration(
          labelText: '服务器地址',
          hintText: 'http://192.168.1.100:16666',
          prefixIcon: Icon(Icons.dns_outlined, size: 20),
        ),
        validator: (v) =>
            v == null || v.trim().isEmpty ? '请输入 Mac 管理端显示的连接地址' : null,
      ),
      CurrentServerLatencyBar(
        serverUrl: _server.text,
        result: _currentServerLatency,
        enabled: !_busy,
        onProbe: _probeCurrentServer,
      ),
      NasDiscoveryPicker(
        enabled: !_busy,
        onSelected: (server) async {
          if (_busy) return;
          _server.text = server.address;
          _addressChanged(server.address);
          setState(() {
            _securityExpanded = true;
            _error = null;
          });
        },
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '家庭局域网默认使用 HTTP；需要加密时可在 Mac 设置中开启 HTTPS。HTTP 请勿暴露到公网。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildCredentialFields() {
    return [
      TextFormField(
        controller: _username,
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
          labelText: '用户名',
          prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
        ),
        validator: (v) => v == null || v.trim().isEmpty ? '请输入用户名' : null,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _password,
        enabled: !_busy,
        obscureText: _hide,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.password],
        decoration: InputDecoration(
          labelText: '密码',
          prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
          suffixIcon: IconButton(
            tooltip: _hide ? '显示密码' : '隐藏密码',
            onPressed: () => setState(() => _hide = !_hide),
            icon: Icon(
              _hide ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            ),
          ),
        ),
        validator: (v) => v == null || v.isEmpty ? '请输入密码' : null,
        onFieldSubmitted: (_) => _login(),
      ),
    ];
  }

  List<Widget> _buildSecurityPinFields() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy
              ? null
              : () => setState(() => _securityExpanded = !_securityExpanded),
          icon: Icon(
            _securityExpanded ? Icons.expand_less : Icons.shield_outlined,
          ),
          label: Text(
            _fingerprint.text.isEmpty ? '连接安全设置' : '连接安全设置 · 已记住证书指纹',
          ),
        ),
      ),
      IsleAnimatedExpand(
        expanded: _securityExpanded,
        child: _securityExpanded
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    key: const Key('certificateFingerprint'),
                    controller: _fingerprint,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    minLines: 2,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '连接验证信息（加密连接时使用）',
                      helperText:
                          '第一次连接 Mac 时，从 Mac「连接其他设备」中复制验证信息并仔细核对。使用已受信任的证书时可留空。',
                      helperMaxLines: 5,
                      prefixIcon: Icon(Icons.verified_user_outlined, size: 20),
                    ),
                    validator: (value) {
                      final pin = (value ?? '').replaceAll(
                        RegExp(r'[:\s]'),
                        '',
                      );
                      if (pin.isEmpty) return null;
                      if (_httpsOrigin(_server.text) == null) {
                        return '证书指纹仅用于 HTTPS 地址';
                      }
                      return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(pin)
                          ? null
                          : '请输入完整的 64 位 SHA-256 指纹';
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              )
            : const SizedBox.shrink(),
      ),
    ];
  }

  Widget _buildForm(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardPadding = screenWidth < 380 ? 16.0 : (wide ? 30.0 : 22.0);
    return AutofillGroup(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!wide) ...[
              const LoginBrandHeader(wide: false),
              const SizedBox(height: 20),
            ],
            Container(
              padding: EdgeInsets.all(cardPadding),
              decoration: ShapeDecoration(
                shape: IsleShapes.hero(
                  side: BorderSide(
                    color: IsleGlass.specularBorder(isDark),
                    width: 1.0,
                  ),
                ),
                gradient: IsleGlass.cardGradient(
                  isDark,
                  accent: colors.primary,
                ),
                shadows: IsleShadows.floating(isDark),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide) ...[
                    Text(
                      '欢迎回来',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '连接你的设备，继续浏览私人空间。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const LoginSetupHelpCard(),
                  const SizedBox(height: 16),
                  LoginHistorySection(
                    entries: _history,
                    latencies: _historyLatencies,
                    selectedKey: _selectedHistoryKey,
                    busy: _busy,
                    onSelect: _selectHistoryEntry,
                    onQuickLogin: _quickLoginHistoryEntry,
                    onRemove: _removeHistoryEntry,
                    onRefreshLatencies: _probeHistoryLatencies,
                  ),
                  if (widget.expired) const Notice('登录已过期或失效，请重新登录。'),
                  if (widget.notice != null)
                    Notice(widget.notice!, error: true),
                  ..._buildServerAddressFields(theme, colors),
                  const SizedBox(height: 16),
                  ..._buildCredentialFields(),
                  const SizedBox(height: 6),
                  ..._buildSecurityPinFields(),
                  if (_error != null) Notice(_error!, error: true),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _busy ? null : _login,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.login_rounded, size: 20),
                    label: Text(_busy ? '正在连接…' : '连接并登录'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '请保持 Mac 原生管理端运行。局域网连接默认自动开启，首次管理员初始化、存储授权和备份恢复仍在 Mac 管理端完成。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant.withValues(alpha: 0.8),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
