import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/lightisle_api.dart';
import 'core/isle_cache_manager.dart';
import 'core/background_photo_backup_session.dart';
import 'core/login_history_store.dart';
import 'core/secure_session_store.dart';
import 'core/isle_theme.dart';
import 'core/widgets.dart';
import 'core/user_facing_error.dart';
import 'features/media/offline_photo_store.dart';
import 'features/media/offline_photos_page.dart';
import 'features/auth/login_page.dart';
import 'features/shell/client_shell.dart';
import 'features/shell/startup_curtain.dart';
export 'features/auth/login_page.dart' show LoginPage;
export 'features/shell/client_shell.dart' show ClientShell;
export 'features/shell/startup_curtain.dart' show StartupCurtain;

void configureLightIsleImageCache() {
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 300;
  imageCache.maximumSizeBytes = Platform.isMacOS ? (128 << 20) : (64 << 20);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureLightIsleImageCache();
  unawaited(IsleCacheManager.instance.pruneOrphanedDiskFiles());
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const LightIsleApp());
}

ThemeData isleTheme(Brightness brightness) => buildIsleTheme(brightness);

class LightIsleApp extends StatefulWidget {
  const LightIsleApp({
    super.key,
    this.sessionStore,
    this.historyStore,
    this.latencyProber,
    this.restoreApiFactory,
    this.photoBackupSession,
  });
  @visibleForTesting
  final SecureSessionStore? sessionStore;
  @visibleForTesting
  final LoginHistoryStore? historyStore;
  @visibleForTesting
  final ServerLatencyProber? latencyProber;
  @visibleForTesting
  final LightIsleApi Function(Map<String, dynamic>)? restoreApiFactory;
  @visibleForTesting
  final BackgroundPhotoBackupSession? photoBackupSession;
  @override
  State<LightIsleApp> createState() => _LightIsleAppState();
}

class _LightIsleAppState extends State<LightIsleApp>
    with WidgetsBindingObserver {
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
        buildIslePageRoute(
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
  late final _historyStore = widget.historyStore ?? LoginHistoryStore();
  bool _restoring = true;
  String? _restoreError;
  Map<String, dynamic>? _offlineSnapshot;
  String? _sessionNotice;
  LightIsleApi? _restoringApi;
  int _sessionTransition = 0;
  bool _showStartup = true;
  bool _startupOpaque = true;
  Timer? _startupFadeTimer;
  Timer? _startupHideTimer;

  @override
  void initState() {
    super.initState();
    configureLightIsleImageCache();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreSession());
    // Present a complete branded frame rather than a white login flash.
    _startupFadeTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _startupOpaque = false);
    });
    _startupHideTimer = Timer(const Duration(milliseconds: 1570), () {
      if (mounted) setState(() => _showStartup = false);
    });
  }

  @override
  void didHaveMemoryPressure() {
    IsleCacheManager.instance.clearMemoryCaches();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (IsleMotion.reducedMotion(context)) {
      // Respect system reduced motion even for the app's branded startup
      // transition; there must be no opaque overlay blocking login actions.
      _startupFadeTimer?.cancel();
      _startupHideTimer?.cancel();
      _startupOpaque = false;
      _showStartup = false;
    }
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
      IsleCacheManager.instance.clearMemoryCaches();
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
    if (_api != null && !identical(_api, api)) {
      IsleCacheManager.instance.clearMemoryCaches();
    }
    _api?.close();
    api.onUnauthorized = () {
      if (!mounted || !identical(api, _api)) return;
      _navigator.currentState?.popUntil((route) => route.isFirst);
      final invalidatedTransition = ++_sessionTransition;
      IsleCacheManager.instance.clearMemoryCaches();
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
    IsleCacheManager.instance.clearMemoryCaches();
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
    WidgetsBinding.instance.removeObserver(this);
    _startupFadeTimer?.cancel();
    _startupHideTimer?.cancel();
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
      dragDevices: {
        ui.PointerDeviceKind.touch,
        ui.PointerDeviceKind.mouse,
        ui.PointerDeviceKind.trackpad,
        ui.PointerDeviceKind.stylus,
      },
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
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeInOutCubic,
                  child: _showStartup
                      ? StartupCurtain(exiting: !_startupOpaque)
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
            historyStore: _historyStore,
            latencyProber: widget.latencyProber,
          )
        : ClientShell(
            key: ObjectKey(_api),
            api: _api!,
            identity: _identity!,
            onLogout: _logout,
            historyStore: _historyStore,
            latencyProber: widget.latencyProber,
            onSwitchAccount: _signedIn,
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: IsleGlassSurface(
                radius: IsleRadius.sheet,
                padding: const EdgeInsets.fromLTRB(26, 30, 26, 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: ShapeDecoration(
                        shape: IsleShapes.squircle(
                          26,
                          side: BorderSide(
                            color: IsleGlass.rimBorderColor(
                              dark,
                              isGlass: true,
                            ),
                            width: 1.0,
                          ),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            palette['cardTop'].withValues(
                              alpha: dark ? 0.90 : 0.96,
                            ),
                            Color.lerp(
                              palette['cardBottom'],
                              colors.primary,
                              dark ? 0.12 : 0.05,
                            )!,
                          ],
                        ),
                        shadows: [
                          BoxShadow(
                            color: colors.primary.withValues(
                              alpha: dark ? 0.24 : 0.14,
                            ),
                            blurRadius: 28,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: const Center(child: IsleBrandMark(size: 56)),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      busy ? '正在恢复登录' : '暂时无法连接 NAS',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (busy)
                      const IsleLoadingState(
                        compact: true,
                        padding: EdgeInsets.symmetric(vertical: 14),
                        label: '正在安全验证你的私有会话…',
                      )
                    else ...[
                      Text(
                        message!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试连接'),
                        ),
                      ),
                      if (onBrowseOfflinePhotos != null) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: onBrowseOfflinePhotos,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('不连接 NAS，查看本机离线照片'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
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
      ),
    );
  }
}
