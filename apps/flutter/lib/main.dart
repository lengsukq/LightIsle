import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/lightisle_api.dart';
import 'core/personal_storage_routing.dart';
import 'core/background_photo_backup_session.dart';
import 'core/secure_session_store.dart';
import 'core/isle_theme.dart';
import 'core/widgets.dart';
import 'features/files/files_page.dart';
import 'features/media/photos_page.dart';
import 'features/media/cinema_page.dart';
import 'features/overview/overview_page.dart';
import 'features/settings/settings_page.dart';
import 'features/auth/nas_discovery_picker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const LightIsleApp());
}

/// Lightweight full-window opening experience matching the macOS sanctuary
/// branding, without waiting on the network or blocking first login forever.
class _StartupCurtain extends StatelessWidget {
  const _StartupCurtain();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette['canvasTop'],
            Color.lerp(
              palette['canvasBottom'],
              theme.colorScheme.primary,
              0.07,
            )!,
          ],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 1000),
                tween: Tween(begin: 0.91, end: 1),
                curve: Curves.easeOutCubic,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Container(
                  padding: const EdgeInsets.all(25),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: 0.12),
                        theme.colorScheme.primary.withValues(alpha: 0.02),
                      ],
                    ),
                  ),
                  child: const IsleBrandMark(size: 104),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '轻屿 LightIsle',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                '让每一份珍藏，自在归屿',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: 112,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: const LinearProgressIndicator(minHeight: 3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

ThemeData isleTheme(Brightness brightness) => buildIsleTheme(brightness);

class LightIsleApp extends StatefulWidget {
  const LightIsleApp({
    super.key,
    this.sessionStore,
    this.restoreApiFactory,
    this.photoBackupSession,
  });
  @visibleForTesting
  final SecureSessionStore? sessionStore;
  @visibleForTesting
  final LightIsleApi Function(Map<String, dynamic>)? restoreApiFactory;
  @visibleForTesting
  final BackgroundPhotoBackupSession? photoBackupSession;
  @override
  State<LightIsleApp> createState() => _LightIsleAppState();
}

class _LightIsleAppState extends State<LightIsleApp> {
  final _navigator = GlobalKey<NavigatorState>();
  LightIsleApi? _api;
  Map<String, dynamic>? _identity;
  bool _expired = false;
  late final _nativePhotoBackup =
      widget.photoBackupSession ?? BackgroundPhotoBackupSession();
  late final _sessionStore = widget.sessionStore ?? SecureSessionStore();
  bool _restoring = true;
  String? _restoreError;
  String? _sessionNotice;
  LightIsleApi? _restoringApi;
  int _sessionTransition = 0;
  bool _showStartup = true;
  bool _startupOpaque = true;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreSession());
    // Present a complete branded frame rather than a white login flash.
    Future<void>.delayed(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _startupOpaque = false);
    });
    Future<void>.delayed(const Duration(milliseconds: 1570), () {
      if (mounted) setState(() => _showStartup = false);
    });
  }

  Future<void> _restoreSession() async {
    final transition = ++_sessionTransition;
    setState(() {
      _restoring = true;
      _restoreError = null;
    });
    LightIsleApi? api;
    try {
      final snapshot = await _sessionStore.read();
      if (!mounted || transition != _sessionTransition || snapshot == null) {
        return;
      }
      api = (widget.restoreApiFactory ?? LightIsleApi.fromSessionSnapshot)(
        snapshot,
      );
      _restoringApi = api;
      final identity = await api
          .get('/api/v2/auth/me')
          .timeout(const Duration(seconds: 12));
      if (!mounted || transition != _sessionTransition) {
        api.close();
        return;
      }
      if (!api.authenticated ||
          identity['username'] is! String ||
          identity['role'] is! String) {
        throw const FormatException('无法确认保存的账号，请重新登录。');
      }
      await _signedIn(api, identity, restoring: true);
    } catch (error) {
      api?.close();
      if (!mounted || transition != _sessionTransition) return;
      final invalid =
          error is SavedSessionExpired ||
          error is FormatException ||
          error is ArgumentError ||
          (error is LightIsleApiException &&
              error.statusCode == HttpStatus.unauthorized);
      if (invalid) {
        try {
          await _nativePhotoBackup.forgetLocalSession();
          await _sessionStore.clear();
          if (!mounted || transition != _sessionTransition) return;
          setState(() {
            _expired = true;
            _sessionNotice = null;
          });
        } catch (_) {
          if (mounted && transition == _sessionTransition) {
            setState(() => _restoreError = '登录状态已失效，但暂时无法清除本机记录。请解锁设备后重试。');
          }
        }
      } else {
        setState(
          () => _restoreError = error is TimeoutException
              ? '连接 NAS 超时，已保留登录状态。请检查网络或 NAS 后重试。'
              : error is LightIsleApiException
              ? '${error.message} 已保留登录状态，可以重试连接。'
              : '无法读取或恢复保存的登录状态。请确认设备已解锁，并检查 NAS 连接后重试。',
        );
      }
    } finally {
      if (identical(_restoringApi, api)) _restoringApi = null;
      if (mounted && transition == _sessionTransition) {
        setState(() => _restoring = false);
      }
    }
  }

  Future<void> _useAnotherAccount() async {
    ++_sessionTransition;
    _restoringApi?.close();
    _restoringApi = null;
    setState(() => _restoring = true);
    try {
      await _nativePhotoBackup.forgetLocalSession();
      await _sessionStore.clear();
      if (mounted) {
        setState(() {
          _restoreError = null;
          _expired = false;
          _sessionNotice = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _restoreError = '无法清除旧账号的登录或后台备份授权，请解锁设备后重试。');
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _signedIn(
    LightIsleApi api,
    Map<String, dynamic> identity, {
    bool restoring = false,
  }) async {
    final transition = restoring ? _sessionTransition : ++_sessionTransition;
    String? nativeToken;
    var savedNewLogin = false;
    try {
      final snapshot = api.sessionSnapshot;
      if (snapshot == null) throw StateError('服务器未提供可保留的登录状态，请更新 NAS 后重试。');
      try {
        await _sessionStore.write(snapshot);
        savedNewLogin = !restoring;
      } catch (_) {
        throw StateError('无法安全保存登录状态，请解锁设备并检查存储空间后重试。');
      }
      nativeToken = await _nativePhotoBackup.replaceSession(
        server: api.uri('/api/v2/me/storage').origin,
        cookie: api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
        username: identity['username']?.toString() ?? '',
      );
      if (!mounted || transition != _sessionTransition) {
        if (nativeToken != null) await _nativePhotoBackup.end(nativeToken);
        api.close();
        return;
      }
    } catch (_) {
      // A fresh login must not be silently restored on the next launch if
      // native account binding failed and the UI rejected that login. Keep
      // an already-remembered session intact on restore so it can be retried.
      // Only the current transition may roll back its own new vault entry.
      if (savedNewLogin && transition == _sessionTransition) {
        try {
          await _sessionStore.clear();
        } catch (_) {
          api.close();
          throw StateError('登录未完成，也无法清理已保存的登录状态。请解锁设备后选择使用其他账号或服务器。');
        }
      }
      api.close();
      rethrow;
    }
    _api?.close();
    api.onUnauthorized = () {
      if (!mounted || !identical(api, _api)) return;
      _navigator.currentState?.popUntil((route) => route.isFirst);
      final invalidatedTransition = ++_sessionTransition;
      unawaited(
        _nativePhotoBackup.forgetLocalSession().catchError((Object _) {
          if (mounted && invalidatedTransition == _sessionTransition) {
            setState(() => _sessionNotice = '会话已失效，但后台备份尚未关闭。请重试清除本机账号。');
          }
        }),
      );
      unawaited(
        _sessionStore.clear().catchError((Object _) {
          if (mounted && invalidatedTransition == _sessionTransition) {
            setState(() => _sessionNotice = '登录已失效，但本机记录尚未清除。请解锁设备后重试。');
          }
        }),
      );
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
      _restoring = false;
      _restoreError = null;
      _sessionNotice = null;
    });
  }

  Future<void> _logout() async {
    final transition = ++_sessionTransition;
    final api = _api;
    try {
      // Stop the persisted worker even if its in-memory token was lost when
      // Android restarted the process. A failure must not claim sign-out.
      await _nativePhotoBackup.forgetLocalSession();
      await _sessionStore.clear();
    } catch (_) {
      final messengerContext = _navigator.currentContext;
      if (mounted && messengerContext != null && messengerContext.mounted) {
        ScaffoldMessenger.of(messengerContext).showSnackBar(
          const SnackBar(content: Text('无法清除登录或旧后台备份授权，请解锁设备后重试退出。')),
        );
      }
      return;
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
        await api.send('POST', '/api/v2/auth/logout');
      } catch (_) {
        /* Local sign-out still succeeds offline. */
      }
      api.close();
    }
  }

  @override
  void dispose() {
    _sessionTransition++;
    _restoringApi?.close();
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
    builder: (context, child) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        ),
        child: IsleCanvas(
          child: Stack(
            fit: StackFit.expand,
            children: [
              child!,
              IgnorePointer(
                ignoring: !_startupOpaque,
                child: AnimatedOpacity(
                  opacity: _startupOpaque ? 1 : 0,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeInOutCubic,
                  child: _showStartup
                      ? const _StartupCurtain()
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      );
    },
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh'), Locale('en')],
    home: _restoring || _restoreError != null
        ? _SessionReconnectPage(
            busy: _restoring,
            message: _restoreError,
            onRetry: _restoreSession,
            onUseAnotherAccount: _useAnotherAccount,
          )
        : _identity == null
        ? LoginPage(
            onSignedIn: _signedIn,
            expired: _expired,
            notice: _sessionNotice,
          )
        : ClientShell(
            key: ObjectKey(_api),
            api: _api!,
            identity: _identity!,
            onLogout: _logout,
          ),
  );
}

class _SessionReconnectPage extends StatelessWidget {
  const _SessionReconnectPage({
    required this.busy,
    required this.message,
    required this.onRetry,
    required this.onUseAnotherAccount,
  });
  final bool busy;
  final String? message;
  final VoidCallback onRetry, onUseAnotherAccount;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const IsleBrandMark(size: 64),
                const SizedBox(height: 24),
                Text(
                  busy ? '正在恢复登录' : '暂时无法连接 NAS',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                if (busy)
                  const CircularProgressIndicator()
                else ...[
                  Text(message!, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试连接'),
                  ),
                  TextButton(
                    onPressed: onUseAnotherAccount,
                    child: const Text('使用其他账号或服务器'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.onSignedIn,
    this.expired = false,
    this.notice,
  });
  final String? notice;
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
        // Accept both advertised schemes without an extra UI toggle, but the
        // transport still refuses cleartext connections to public IPs.
        allowInsecureHttp: true,
        certificateFingerprint: _fingerprint.text.trim().isEmpty
            ? null
            : _fingerprint.text.trim(),
      );
      _connecting = api;
      final status = await api.get('/api/v2/auth/status');
      if (status['configured'] != true) {
        throw StateError('服务尚未初始化，请先在 Mac 原生管理端创建首任管理员。');
      }
      final identity = await api.send(
        'POST',
        '/api/v2/auth/login',
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
        /* The session is saved separately in OS-protected storage. */
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
                      if (widget.expired) const Notice('登录已过期或失效，请重新登录。'),
                      if (widget.notice != null)
                        Notice(widget.notice!, error: true),
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
                          '支持 HTTPS 与可信局域网 HTTP；HTTP 不加密数据，不支持公网 HTTP。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
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
  Map<String, dynamic>? _myStoragePolicy;
  String? _personalRouteError;
  int? _manualRootSection;
  List<LightIsleRoot> _roots = const [];
  bool _rootsLoading = false;
  String? _rootsError;
  @override
  void initState() {
    super.initState();
    unawaited(_refreshRoots());
  }

  Future<void> _refreshRoots() async {
    if (_rootsLoading) return;
    setState(() {
      _rootsLoading = true;
      _rootsError = null;
    });
    try {
      final response = await widget.api.get('/api/v2/roots');
      final raw = response['roots'];
      if (raw is! List) throw const FormatException('共享目录列表无效。');
      final roots = raw
          .map(
            (item) =>
                LightIsleRoot.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
      final policy = await widget.api.get('/api/v2/me/storage');
      if (!mounted) return;
      final old = widget.api.selectedRoot;
      final isCurrent =
          old == null ||
          roots.any((root) => root.identity == old.identity && root.online);
      if (!isCurrent) widget.api.selectRoot(null);
      setState(() {
        _roots = roots;
        _myStoragePolicy = policy;
        if (!isCurrent) _pages.clear();
      });
      _applyPersonalRoute(_index);
      if (!isCurrent) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('原共享目录已离线或更换，请重新选择目录。')));
      }
    } on LightIsleApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _rootsError = error.statusCode == 404
            ? 'NAS 服务不支持 v2 多硬盘接口，请更新 Mac 端后重试。'
            : error.message;
        _personalRouteError = '无法确认个人目录位置，请检查 NAS 状态后重试。';
        _pages.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _rootsError = '读取共享目录失败，请重试：$error';
          _personalRouteError = '个人存储配置暂不可用，请重试。';
          _pages.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _rootsLoading = false);
    }
  }

  Future<void> _chooseRoot(String id) async {
    final chosen = id.isEmpty
        ? null
        : _roots.where((r) => r.id == id).firstOrNull;
    if (id.isNotEmpty && (chosen == null || !chosen.online)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该共享目录不可用，请检查硬盘连接。')));
      return;
    }
    if (widget.api.selectedRoot?.identity == chosen?.identity) return;
    if (!await confirmAction(
      context,
      '切换共享目录',
      '切换将关闭当前文件传输、照片和视频页面。请先确认上传或下载任务已完成。',
      action: '切换目录',
    )) {
      return;
    }
    if (!mounted) return;
    widget.api.selectRoot(chosen);
    setState(() {
      _manualRootSection = _index;
      _personalRouteError = null;
      _pages.clear();
    });
  }

  PersonalStorageRoute _routeFor(int index) =>
      resolvePersonalRoute(_myStoragePolicy, _roots, switch (index) {
        1 => 'files',
        2 => 'photos',
        3 => 'cinema',
        _ => '',
      });

  void _applyPersonalRoute(int index) {
    if (_manualRootSection == index) return;
    if (index < 1 || index > 3) return;
    if (_myStoragePolicy == null) {
      setState(() {
        _personalRouteError = '无法读取个人硬盘配置，请刷新共享目录。';
        _pages.clear();
      });
      return;
    }
    final route = _routeFor(index);
    if (route.kind == PersonalRouteKind.offline) {
      setState(() {
        _personalRouteError = '该分类绑定的硬盘离线或已更换。请连接原硬盘，或在 Mac 管理端手动重建。';
        _pages.clear();
      });
      return;
    }
    final target = route.kind == PersonalRouteKind.personal ? route.root : null;
    if (widget.api.selectedRoot?.identity != target?.identity) {
      widget.api.selectRoot(target);
      setState(() => _pages.clear());
    }
    if (_personalRouteError != null) {
      setState(() {
        _personalRouteError = null;
        _pages.clear();
      });
    }
  }

  static const _labels = ['概览', '文件', '图库', '影视', '设置'];
  static const _sectionThemes = [
    IsleSectionTheme.overview,
    IsleSectionTheme.files,
    IsleSectionTheme.photos,
    IsleSectionTheme.cinema,
    IsleSectionTheme.settings,
  ];
  bool get _admin => widget.identity['role'] == 'admin';
  // Never eagerly mount inactive tabs against the shared session client:
  // their initState requests would inherit whichever physical disk happens
  // to be selected by the visible tab.
  Widget _page(int index) {
    if (index != _index) return const SizedBox.shrink();
    return _pages.putIfAbsent(
      index,
      () => KeyedSubtree(
        key: ValueKey(
          'root:${widget.api.selectedRoot?.identity ?? 'default'}:$index',
        ),
        child:
            _personalRouteError != null &&
                index == _index &&
                index >= 1 &&
                index <= 3 &&
                _manualRootSection != index
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.storage_outlined, size: 40),
                      const SizedBox(height: 12),
                      Text(_personalRouteError!, textAlign: TextAlign.center),
                      TextButton.icon(
                        onPressed: _rootsLoading ? null : _refreshRoots,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新检查'),
                      ),
                    ],
                  ),
                ),
              )
            : switch (index) {
                0 => OverviewPage(
                  api: widget.api,
                  isAdmin: _admin,
                  onNavigate: _select,
                ),
                1 => FilesPage(
                  api: widget.api,
                  isAdmin: _admin,
                  accountName: widget.identity['username']?.toString() ?? '',
                  initialPath:
                      _routeFor(1).kind == PersonalRouteKind.personal &&
                          _manualRootSection != 1
                      ? _routeFor(1).path!
                      : '.',
                  showPhotoBackup: false,
                ),
                2 => PhotosPage(
                  api: widget.api,
                  isAdmin: _admin,
                  accountName: widget.identity['username']?.toString() ?? '',
                  canBackup:
                      _manualRootSection != 2 &&
                      _routeFor(2).kind == PersonalRouteKind.personal,
                  uploadDirectory:
                      _manualRootSection != 2 &&
                          _routeFor(2).kind == PersonalRouteKind.personal
                      ? _routeFor(2).path!
                      : '.',
                  backupDirectory:
                      _routeFor(2).kind == PersonalRouteKind.personal &&
                          _manualRootSection != 2
                      ? _routeFor(2).path!
                      : 'PhonePhotos',
                ),
                3 => CinemaPage(
                  api: widget.api,
                  isAdmin: _admin,
                  uploadDirectory:
                      _manualRootSection != 3 &&
                          _routeFor(3).kind == PersonalRouteKind.personal
                      ? _routeFor(3).path!
                      : '.',
                ),
                _ => SettingsPage(
                  api: widget.api,
                  identity: widget.identity,
                  onLogout: widget.onLogout,
                ),
              },
      ),
    );
  }

  void _select(int index) {
    if (_index != index) {
      HapticFeedback.selectionClick();
      setState(() {
        _index = index;
        _manualRootSection = null;
        _pages.clear();
      });
      _applyPersonalRoute(index);
    }
  }

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
            final rail =
                constraints.maxWidth >= 840 && constraints.maxHeight >= 600;
            _page(_index);
            final animatedBody = IsleFluidTabSwitcher(
              index: _index,
              children: List.generate(5, (i) => _page(i)),
            );
            final extendedRail =
                constraints.maxWidth >= 1120 &&
                MediaQuery.textScalerOf(context).scale(14) < 23;
            return Scaffold(
              appBar: AppBar(
                title: Row(
                  children: [
                    const IsleBrandMark(size: 26),
                    const SizedBox(width: 8),
                    const Text('轻屿'),
                    if (rail) ...[
                      const SizedBox(width: 12),
                      Text(_labels[_index]),
                    ],
                  ],
                ),
                actions: [
                  PopupMenuButton<String>(
                    tooltip: '选择共享目录',
                    icon: Icon(
                      _rootsError != null
                          ? Icons.sync_problem_rounded
                          : Icons.storage_outlined,
                    ),
                    onSelected: (value) {
                      if (value == '__refresh') {
                        unawaited(_refreshRoots());
                      } else {
                        unawaited(_chooseRoot(value));
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        enabled: false,
                        child: Text(
                          '当前位置：${widget.api.selectedRoot?.name ?? '默认共享目录'}',
                        ),
                      ),
                      const PopupMenuItem(value: '', child: Text('默认共享目录')),
                      ..._roots.map(
                        (root) => PopupMenuItem(
                          value: root.id,
                          enabled: root.online,
                          child: Text(
                            '${root.name}${root.online ? '' : ' · 离线'}',
                          ),
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: '__refresh',
                        enabled: !_rootsLoading,
                        child: Text(_rootsLoading ? '正在检查…' : '刷新共享目录状态'),
                      ),
                    ],
                  ),
                  if (_rootsLoading)
                    const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
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
              body: SafeArea(
                top: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (rail)
                      NavigationRail(
                        selectedIndex: _index,
                        extended: extendedRail,
                        minExtendedWidth: 190,
                        labelType: extendedRail
                            ? NavigationRailLabelType.none
                            : NavigationRailLabelType.all,
                        onDestinationSelected: _select,
                        destinations: List.generate(
                          5,
                          (i) => NavigationRailDestination(
                            icon: Icon(_sectionThemes[i].icon),
                            label: Text(_labels[i]),
                          ),
                        ),
                      ),
                    Expanded(child: IsleContent(child: animatedBody)),
                  ],
                ),
              ),
              bottomNavigationBar: rail
                  ? null
                  : NavigationBar(
                      selectedIndex: _index,
                      onDestinationSelected: _select,
                      destinations: List.generate(
                        5,
                        (i) => NavigationDestination(
                          icon: Icon(_sectionThemes[i].icon),
                          selectedIcon: Icon(
                            _sectionThemes[i].icon,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          label: _labels[i],
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
