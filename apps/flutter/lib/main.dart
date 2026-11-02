import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/lightisle_api.dart';
import 'core/background_photo_backup_session.dart';
import 'core/secure_session_store.dart';
import 'core/isle_theme.dart';
import 'core/user_facing_error.dart';
import 'features/media/offline_photo_store.dart';
import 'features/media/offline_photos_page.dart';
import 'features/auth/login_page.dart';
import 'features/shell/client_shell.dart';
export 'features/auth/login_page.dart' show LoginPage;
export 'features/shell/client_shell.dart' show ClientShell;

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
  /// Cold-start NAS outages must not hide locally retained photo originals.
  /// Read only the account identity stored in the OS-protected session vault;
  /// the temporary offline browser API has NO cookie and makes no requests.
  Future<void> _browseOfflinePhotos() async {
    final snapshot = _offlineSnapshot;
    if (snapshot == null ||
        snapshot['offlineAccountId'] is! int ||
        (snapshot['offlineAccountId'] as int) < 1 ||
        snapshot['server'] is! String) {
      return;
    }
    final offlineApi = LightIsleApi(
      snapshot['server'] as String,
      allowInsecureHttp: true,
      certificateFingerprint: snapshot['certificateFingerprint'] as String?,
    );
    final accountId = 'uid:${snapshot['offlineAccountId']}';
    try {
      final sources = await OfflinePhotoStore.savedLocations(
        api: offlineApi,
        accountId: accountId,
      );
      if (!mounted) return;
      final context = _navigator.currentContext;
      if (context == null || !context.mounted) return;
      if (sources.isEmpty) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('当前账号还没有保存过本机离线照片。')));
        return;
      }
      OfflinePhotoSource? chosen;
      if (sources.length == 1) {
        chosen = sources.single;
      } else {
        chosen = await showDialog<OfflinePhotoSource>(
          context: context,
          builder: (dialogContext) => SimpleDialog(
            title: const Text('选择离线照片所在的硬盘'),
            children: [
              for (final source in sources)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, source),
                  child: Text(source.name),
                ),
            ],
          ),
        );
      }
      if (chosen == null || !mounted || !context.mounted) return;
      offlineApi.selectRoot(chosen.root);
      await _navigator.currentState?.push<void>(
        MaterialPageRoute(
          builder: (_) =>
              OfflinePhotosPage(api: offlineApi, accountId: accountId),
        ),
      );
    } catch (error) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('打开本机离线照片失败：${userFacingError(error)}')),
        );
      }
    } finally {
      offlineApi.close();
    }
  }

  final _navigator = GlobalKey<NavigatorState>();
  LightIsleApi? _api;
  Map<String, dynamic>? _identity;
  bool _expired = false;
  late final _nativePhotoBackup =
      widget.photoBackupSession ?? BackgroundPhotoBackupSession();
  late final _sessionStore = widget.sessionStore ?? SecureSessionStore();
  bool _restoring = true;
  String? _restoreError;
  Map<String, dynamic>? _offlineSnapshot;
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
      _offlineSnapshot = snapshot;
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
          _offlineSnapshot = null;
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
      _offlineSnapshot = null;
      _offlineSnapshot = null;
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
      final session = api.sessionSnapshot;
      final userID = identity['id'];
      final snapshot = session == null
          ? null
          : <String, dynamic>{
              ...session,
              if (userID is int && userID > 0) 'offlineAccountId': userID,
            };
      if (snapshot == null) throw StateError('服务器未提供可保留的登录状态，请更新 NAS 后重试。');
      try {
        await _sessionStore.write(snapshot);
        _offlineSnapshot = snapshot;
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
        _offlineSnapshot = null;
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
            onBrowseOfflinePhotos: _offlineSnapshot?['offlineAccountId'] is int
                ? _browseOfflinePhotos
                : null,
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
    this.onBrowseOfflinePhotos,
  });
  final bool busy;
  final String? message;
  final VoidCallback onRetry, onUseAnotherAccount;
  final VoidCallback? onBrowseOfflinePhotos;
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
                  if (onBrowseOfflinePhotos != null)
                    OutlinedButton.icon(
                      onPressed: onBrowseOfflinePhotos,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('不连接 NAS，查看本机离线照片'),
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
