import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/lightisle_api.dart';
import 'core/background_photo_backup_session.dart';
import 'core/isle_theme.dart';
import 'core/widgets.dart';
import 'features/files/files_page.dart';
import 'features/media/photos_page.dart';
import 'features/media/cinema_page.dart';
import 'features/overview/overview_page.dart';
import 'features/settings/settings_page.dart';
import 'features/auth/nas_discovery_picker.dart';

void main() => runApp(const LightIsleApp());

ThemeData isleTheme(Brightness brightness) => buildIsleTheme(brightness);

class LightIsleApp extends StatefulWidget {
  const LightIsleApp({super.key});
  @override
  State<LightIsleApp> createState() => _LightIsleAppState();
}

class _LightIsleAppState extends State<LightIsleApp> {
  final _navigator = GlobalKey<NavigatorState>();
  LightIsleApi? _api;
  Map<String, dynamic>? _identity;
  bool _expired = false;
  final _nativePhotoBackup = BackgroundPhotoBackupSession();
  int _sessionTransition = 0;

  Future<void> _signedIn(
    LightIsleApi api,
    Map<String, dynamic> identity,
  ) async {
    final transition = ++_sessionTransition;
    String? nativeToken;
    try {
      nativeToken = await _nativePhotoBackup.replaceSession(
        server: api.uri('/api/v1/files').origin,
        cookie: api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
        username: identity['username']?.toString() ?? '',
      );
      if (!mounted || transition != _sessionTransition) {
        if (nativeToken != null) await _nativePhotoBackup.end(nativeToken);
        api.close();
        return;
      }
    } catch (_) {
      api.close();
      rethrow;
    }
    _api?.close();
    final sessionToken = nativeToken;
    api.onUnauthorized = () {
      if (!mounted || !identical(api, _api)) return;
      if (sessionToken != null) {
        unawaited(_nativePhotoBackup.end(sessionToken).catchError((_) {}));
      }
      _navigator.currentState?.popUntil((route) => route.isFirst);
      _sessionTransition++;
      setState(() {
        _identity = null;
        _api = null;
        _expired = true;
      });
      api.close();
    };
    setState(() {
      _api = api;
      _identity = identity;
      _expired = false;
    });
  }

  Future<void> _logout() async {
    final transition = ++_sessionTransition;
    final api = _api;
    try {
      await _nativePhotoBackup.endCurrent();
    } catch (_) {
      // Local sign-out must still work offline. Native state is durably
      // removed before WorkManager cancellation normally completes.
    }
    if (!mounted || transition != _sessionTransition) return;
    _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _identity = null;
      _api = null;
      _expired = false;
    });
    if (api != null) {
      api.onUnauthorized = null;
      try {
        await api.send('POST', '/api/v1/auth/logout');
      } catch (_) {
        /* Local sign-out still succeeds offline. */
      }
      api.close();
    }
  }

  @override
  void dispose() {
    _api?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigator,
    title: '轻屿 LightIsle',
    debugShowCheckedModeBanner: false,
    theme: isleTheme(Brightness.light),
    darkTheme: isleTheme(Brightness.dark),
    highContrastTheme: buildIsleTheme(Brightness.light, highContrast: true),
    highContrastDarkTheme: buildIsleTheme(Brightness.dark, highContrast: true),
    scrollBehavior: const MaterialScrollBehavior().copyWith(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
    ),
    builder: (context, child) => IsleCanvas(child: child!),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh'), Locale('en')],
    home: _identity == null
        ? LoginPage(onSignedIn: _signedIn, expired: _expired)
        : ClientShell(
            key: ObjectKey(_api),
            api: _api!,
            identity: _identity!,
            onLogout: _logout,
          ),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSignedIn, this.expired = false});
  final FutureOr<void> Function(LightIsleApi, Map<String, dynamic>) onSignedIn;
  final bool expired;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _fingerprint = TextEditingController();
  bool _busy = false, _insecure = false, _hide = true;
  bool _securityExpanded = false;
  SharedPreferences? _preferences;
  String? _pinOrigin;
  String? _error;
  LightIsleApi? _connecting;
  @override
  void initState() {
    super.initState();
    _loadAddress();
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
    if (origin == _pinOrigin) return;
    _pinOrigin = origin;
    _fingerprint.text = origin == null
        ? ''
        : _preferences?.getString('lightisle.certificatePin.$origin') ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    LightIsleApi? api;
    try {
      api = LightIsleApi(
        _server.text.trim(),
        allowInsecureHttp: _insecure,
        certificateFingerprint: _fingerprint.text.trim().isEmpty
            ? null
            : _fingerprint.text.trim(),
      );
      _connecting = api;
      final status = await api.get('/api/v1/auth/status');
      if (status['configured'] != true) {
        throw StateError('服务尚未初始化，请先在 Mac 原生管理端创建首任管理员。');
      }
      final identity = await api.send(
        'POST',
        '/api/v1/auth/login',
        body: {'username': _username.text.trim(), 'password': _password.text},
      );
      if (!mounted) {
        api.close();
        return;
      }
      if (!api.authenticated) throw StateError('服务未返回可用会话，请检查连接地址。');
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('lightisle.server', _server.text.trim());
        final origin = _httpsOrigin(_server.text);
        if (origin != null) {
          final key = 'lightisle.certificatePin.$origin';
          if (_fingerprint.text.trim().isEmpty) {
            await preferences.remove(key);
          } else {
            await preferences.setString(key, _fingerprint.text.trim());
          }
        }
      } catch (_) {
        /* Credentials are never persisted. */
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
          _error = error.toString().replaceFirst('Bad state: ', '');
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
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: AutofillGroup(
              child: IsleSurface(
                radius: 30,
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 400 ? 22 : 36,
                ),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Theme.of(context).colorScheme.primary
                                    .withValues(alpha: 0.25),
                                blurRadius: 28,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const IsleBrandMark(size: 76),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '轻屿 LightIsle',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '连接你的个人 NAS，随时查看文件、照片与影视。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (widget.expired) const Notice('会话已失效，请重新登录。'),
                      TextFormField(
                        controller: _server,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        onChanged: _addressChanged,
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'https://nas.example.com:8443',
                          prefixIcon: Icon(Icons.dns_outlined, size: 20),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? '请输入 Mac 管理端显示的连接地址'
                            : null,
                      ),
                      NasDiscoveryPicker(
                        enabled: !_busy,
                        onSelected: (server) {
                          if (_busy) return;
                          _server.text = server.address;
                          _addressChanged(server.address);
                          setState(() {
                            _insecure = false;
                            _securityExpanded = true;
                            _error = null;
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _username,
                        enabled: !_busy,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          prefixIcon: Icon(
                            Icons.person_outline_rounded,
                            size: 20,
                          ),
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请输入用户名' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _hide,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: '密码',
                          prefixIcon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 20,
                          ),
                          suffixIcon: IconButton(
                            tooltip: _hide ? '显示密码' : '隐藏密码',
                            onPressed: () => setState(() => _hide = !_hide),
                            icon: Icon(
                              _hide
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (v) =>
                            v == null || v.isEmpty ? '请输入密码' : null,
                        onFieldSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () => setState(
                                  () => _securityExpanded = !_securityExpanded,
                                ),
                          icon: Icon(
                            _securityExpanded
                                ? Icons.expand_less
                                : Icons.shield_outlined,
                          ),
                          label: Text(
                            _fingerprint.text.isEmpty
                                ? '连接安全设置'
                                : '连接安全设置 · 已记住证书指纹',
                          ),
                        ),
                      ),
                      if (_securityExpanded) ...[
                        TextFormField(
                          key: const Key('certificateFingerprint'),
                          controller: _fingerprint,
                          enabled: !_busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          minLines: 2,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: '自签名证书 SHA-256 指纹（可选）',
                            helperText: '连接 Mac 默认 HTTPS 时，从 Mac 管理端复制并核对指纹。受系统信任的 HTTPS 可留空；证书变化后需重新核对。',
                            helperMaxLines: 5,
                            prefixIcon: Icon(
                              Icons.verified_user_outlined,
                              size: 20,
                            ),
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
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _insecure,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _insecure = v!),
                          title: const Text(
                            '允许可信局域网 HTTP',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: const Text(
                            'HTTP 会明文传输密码与文件，仅用于你信任的网络。',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                      if (_error != null) Notice(_error!, error: true),
                      const SizedBox(height: 8),
                      FilledButton.icon(
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
                      const SizedBox(height: 22),
                      Text(
                        '请保持 Mac 原生管理端运行并开启远程连接。首次管理员初始化、存储授权和备份恢复仍在 Mac 管理端完成。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class ClientShell extends StatefulWidget {
  const ClientShell({
    super.key,
    required this.api,
    required this.identity,
    required this.onLogout,
  });
  final LightIsleApi api;
  final Map<String, dynamic> identity;
  final Future<void> Function() onLogout;
  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell> {
  int _index = 0;
  final Map<int, Widget> _pages = {};
  static const _labels = ['概览', '文件', '图库', '影视', '设置'];
  static const _sectionThemes = [
    IsleSectionTheme.overview,
    IsleSectionTheme.files,
    IsleSectionTheme.photos,
    IsleSectionTheme.cinema,
    IsleSectionTheme.settings,
  ];
  bool get _admin => widget.identity['role'] == 'admin';
  Widget _page(int index) => _pages.putIfAbsent(
    index,
    () => switch (index) {
      0 => OverviewPage(api: widget.api, isAdmin: _admin, onNavigate: _select),
      1 => FilesPage(
        api: widget.api,
        isAdmin: _admin,
        accountName: widget.identity['username']?.toString() ?? '',
      ),
      2 => PhotosPage(api: widget.api, isAdmin: _admin),
      3 => CinemaPage(api: widget.api, isAdmin: _admin),
      _ => SettingsPage(
        api: widget.api,
        identity: widget.identity,
        onLogout: widget.onLogout,
      ),
    },
  );
  void _select(int index) => setState(() => _index = index);
  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
          _select(4),
      for (var i = 0; i < 5; i++)
        SingleActivator(
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
            LogicalKeyboardKey.digit5,
          ][i],
          meta: (defaultTargetPlatform == TargetPlatform.macOS),
          control: !(defaultTargetPlatform == TargetPlatform.macOS),
        ): () =>
            _select(i),
    };
    Widget content = CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final rail =
                constraints.maxWidth >= 840 && constraints.maxHeight >= 600;
            _page(_index);
            final animatedBody = IsleFluidTabSwitcher(
              index: _index,
              children: List.generate(
                5,
                (i) => _page(i),
              ),
            );
            final extendedRail =
                constraints.maxWidth >= 1120 &&
                MediaQuery.textScalerOf(context).scale(14) < 23;
            return Scaffold(
              appBar: PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface.withValues(
                          alpha: isDark ? 0.72 : 0.84,
                        ),
                    border: Border(
                      bottom: BorderSide(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withValues(alpha: 0.35),
                        width: 0.75,
                      ),
                    ),
                  ),
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: AppBar(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        scrolledUnderElevation: 0,
                        title: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const IsleBrandMark(size: 28),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                '轻屿 · ${_labels[_index]}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                        actions: [
                          if (constraints.maxWidth > 640)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: 0.4),
                                      width: 0.75,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const IslePulsingStatusDot(
                                        color: Color(0xff10b981),
                                        size: 7,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        widget.identity['username']?.toString() ?? '',
                                        style: Theme.of(context).textTheme.bodySmall
                                            ?.copyWith(fontWeight: FontWeight.w600),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          IconButton(
                            tooltip: '账号与连接',
                            onPressed: () => _select(4),
                            icon: const Icon(Icons.account_circle_outlined),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              body: SafeArea(
                top: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (rail)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 0, 20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface.withValues(
                                  alpha: isDark ? 0.80 : 0.90,
                                ),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.10)
                                  : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35),
                              width: 0.85,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                                blurRadius: 20,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: NavigationRail(
                            selectedIndex: _index,
                            extended: extendedRail,
                            minExtendedWidth: 210,
                            backgroundColor: Colors.transparent,
                            indicatorColor: Colors.transparent,
                            labelType: extendedRail
                                ? NavigationRailLabelType.none
                                : NavigationRailLabelType.all,
                            leading: Padding(
                              padding: EdgeInsets.fromLTRB(
                                extendedRail ? 12 : 0,
                                8,
                                0,
                                28,
                              ),
                              child: extendedRail
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const IsleBrandMark(size: 36),
                                        const SizedBox(width: 10),
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Text(
                                              '轻屿 LightIsle',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: -0.3,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                              decoration: BoxDecoration(
                                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(999),
                                              ),
                                              child: Text(
                                                'NAS CLIENT',
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 0.5,
                                                  color: Theme.of(context).colorScheme.primary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    )
                                  : const IsleBrandMark(size: 36),
                            ),
                            onDestinationSelected: _select,
                            destinations: List.generate(
                              5,
                              (i) {
                                final item = _sectionThemes[i];
                                return NavigationRailDestination(
                                  icon: IsleSquircleBadge(
                                    icon: item.icon,
                                    color: item.color.withValues(alpha: isDark ? 0.22 : 0.12),
                                    iconColor: item.color,
                                    size: 28,
                                    iconSize: 16,
                                    shadow: false,
                                  ),
                                  selectedIcon: IsleSquircleBadge(
                                    icon: item.icon,
                                    color: item.color,
                                    gradient: item.gradient,
                                    iconColor: Colors.white,
                                    size: 28,
                                    iconSize: 16,
                                    shadow: false,
                                  ),
                                  label: Text(_labels[i]),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    Expanded(child: IsleContent(child: animatedBody)),
                  ],
                ),
              ),
              bottomNavigationBar: rail
                  ? null
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface.withValues(
                                alpha: isDark ? 0.85 : 0.92,
                              ),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.10)
                                : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35),
                            width: 0.85,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                              blurRadius: 18,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: NavigationBar(
                            selectedIndex: _index,
                            onDestinationSelected: _select,
                            backgroundColor: Colors.transparent,
                            elevation: 0,
                            indicatorColor: Colors.transparent,
                            animationDuration: const Duration(milliseconds: 200),
                            destinations: List.generate(
                              5,
                              (i) {
                                final item = _sectionThemes[i];
                                return NavigationDestination(
                                  icon: IsleSquircleBadge(
                                    icon: item.icon,
                                    color: item.color.withValues(alpha: isDark ? 0.22 : 0.12),
                                    iconColor: item.color,
                                    size: 24,
                                    iconSize: 14,
                                    shadow: false,
                                  ),
                                  selectedIcon: IsleSquircleBadge(
                                    icon: item.icon,
                                    color: item.color,
                                    gradient: item.gradient,
                                    iconColor: Colors.white,
                                    size: 24,
                                    iconSize: 14,
                                    shadow: false,
                                  ),
                                  label: _labels[i],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
            );
          },
        ),
      ),
    );
    if ((defaultTargetPlatform == TargetPlatform.macOS)) {
      content = PlatformMenuBar(
        menus: [
          PlatformMenu(
            label: '轻屿',
            menus: [
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about,
              ),
              PlatformMenuItem(
                label: '设置…',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.comma,
                  meta: true,
                ),
                onSelected: () => _select(4),
              ),
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.quit,
              ),
            ],
          ),
          PlatformMenu(
            label: '前往',
            menus: List.generate(
              5,
              (i) => PlatformMenuItem(
                label: _labels[i],
                onSelected: () => _select(i),
              ),
            ),
          ),
          PlatformMenu(
            label: '编辑',
            menus: [
              for (final command in <(String, Intent, LogicalKeyboardKey)>[
                (
                  '剪切',
                  const CopySelectionTextIntent.cut(
                    SelectionChangedCause.toolbar,
                  ),
                  LogicalKeyboardKey.keyX,
                ),
                ('复制', CopySelectionTextIntent.copy, LogicalKeyboardKey.keyC),
                (
                  '粘贴',
                  const PasteTextIntent(SelectionChangedCause.toolbar),
                  LogicalKeyboardKey.keyV,
                ),
                (
                  '全选',
                  const SelectAllTextIntent(SelectionChangedCause.toolbar),
                  LogicalKeyboardKey.keyA,
                ),
              ])
                PlatformMenuItem(
                  label: command.$1,
                  shortcut: SingleActivator(command.$3, meta: true),
                  onSelected: () {
                    final focusContext =
                        FocusManager.instance.primaryFocus?.context;
                    if (focusContext != null) {
                      Actions.maybeInvoke(focusContext, command.$2);
                    }
                  },
                ),
            ],
          ),
        ],
        child: content,
      );
    }
    return content;
  }
}
