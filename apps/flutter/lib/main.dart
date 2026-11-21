import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/insecure_http_allowlist.dart';
import 'core/lightisle_api.dart';
import 'core/isle_cache_manager.dart';
import 'core/background_photo_backup_session.dart';
import 'core/login_history_store.dart';
import 'core/secure_session_store.dart';
import 'core/isle_theme.dart';
import 'features/auth/login_page.dart';
import 'features/shell/client_shell.dart';
import 'features/shell/session_reconnect_stage.dart';
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

ThemeData isleTheme(
  Brightness brightness, {
  IsleThemePresetId presetId = IsleThemePresetId.warmGallery,
}) => buildIsleTheme(brightness, presetId: presetId);

class LightIsleApp extends StatefulWidget {
  const LightIsleApp({
    super.key,
    this.sessionStore,
    this.historyStore,
    this.latencyProber,
    this.restoreApiFactory,
    this.photoBackupSession,
    this.themeController,
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
  @visibleForTesting
  final IsleThemeController? themeController;
  @override
  State<LightIsleApp> createState() => _LightIsleAppState();
}

class _LightIsleAppState extends State<LightIsleApp>
    with WidgetsBindingObserver {
  Future<void> _browseOfflinePhotos() => openOfflinePhotosFromSnapshot(
    snapshot: _offlineSnapshot,
    navigatorKey: _navigator,
    isMounted: () => mounted,
  );

  final _navigator = GlobalKey<NavigatorState>();
  LightIsleApi? _api;
  Map<String, dynamic>? _identity;
  bool _expired = false;
  late final _nativePhotoBackup =
      widget.photoBackupSession ?? BackgroundPhotoBackupSession();
  late final _sessionStore = widget.sessionStore ?? SecureSessionStore();
  late final _historyStore = widget.historyStore ?? LoginHistoryStore();
  late final bool _ownsThemeController = widget.themeController == null;
  late final IsleThemeController _themeController =
      widget.themeController ?? IsleThemeController();
  bool _restoring = true;
  String? _restoringStatus;
  String? _restoreError;
  Map<String, dynamic>? _offlineSnapshot;
  String? _sessionNotice;
  LightIsleApi? _restoringApi;
  int _sessionTransition = 0;
  bool _showStartup = true;
  bool _startupOpaque = true;
  Timer? _startupFadeTimer;
  Timer? _startupHideTimer;

  static const Duration _startupFadeDuration = Duration(milliseconds: 260);
  static const Duration _startupMaxOpaqueCap = Duration(milliseconds: 900);

  void _dismissStartupCurtain({bool immediate = false}) {
    _startupFadeTimer?.cancel();
    _startupFadeTimer = null;
    if (!_showStartup) return;
    if (immediate || (mounted && IsleMotion.reducedMotion(context))) {
      _startupHideTimer?.cancel();
      _startupHideTimer = null;
      if (mounted) {
        setState(() {
          _startupOpaque = false;
          _showStartup = false;
        });
      }
      return;
    }
    if (_startupOpaque) {
      if (mounted) setState(() => _startupOpaque = false);
      _startupHideTimer?.cancel();
      _startupHideTimer = Timer(_startupFadeDuration + const Duration(milliseconds: 20), () {
        if (mounted) setState(() => _showStartup = false);
      });
    }
  }

  static String _shortEndpointLabel(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.host.isEmpty) return rawUrl.trim();
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  void _setRestoringStatus(int transition, String? status) {
    if (!mounted || transition != _sessionTransition) return;
    if (_restoringStatus == status) return;
    setState(() => _restoringStatus = status);
  }

  @override
  void initState() {
    super.initState();
    configureLightIsleImageCache();
    WidgetsBinding.instance.addObserver(this);
    if (!_themeController.loaded) {
      unawaited(_themeController.load());
    }
    unawaited(_restoreSession());
    // Reveal the reconnect progress screen if session verification takes longer
    // than a brief opening beat; otherwise dismiss immediately once ready.
    _startupFadeTimer = Timer(_startupMaxOpaqueCap, _dismissStartupCurtain);
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

  Future<bool> _tryRestoreViaPreferredHostEndpoint(
    Map<String, dynamic> snapshot,
    int transition,
  ) async {
    if (widget.restoreApiFactory != null) return false;
    final savedServer = snapshot['server'];
    if (savedServer is! String || savedServer.trim().isEmpty) return false;
    final savedUser = snapshot['offlineUsername'] is String
        ? (snapshot['offlineUsername'] as String).trim().toLowerCase()
        : null;
    LoginHistoryEntry? matched;
    try {
      final entries = await _historyStore.readAll();
      for (final item in entries) {
        if (!item.ownsServer(savedServer)) continue;
        if (savedUser != null &&
            savedUser.isNotEmpty &&
            item.username.trim().toLowerCase() != savedUser) {
          continue;
        }
        matched = item;
        break;
      }
    } catch (_) {
      return false;
    }
    if (matched == null ||
        !matched.autoSelectEndpoint ||
        !matched.hasMultipleEndpoints) {
      return false;
    }
    final baseProber =
        widget.latencyProber ??
        (String url, {String? certificateFingerprint}) => probeServerLatency(
          url,
          certificateFingerprint: certificateFingerprint,
          timeout: const Duration(seconds: 4),
        );
    _setRestoringStatus(
      transition,
      '正在探测可用线路（共 ${matched.endpoints.length} 条）…',
    );
    Future<ServerLatencyResult> trackingProber(
      String url, {
      String? certificateFingerprint,
    }) {
      _setRestoringStatus(
        transition,
        '正在探测线路：${_shortEndpointLabel(url)}…',
      );
      return baseProber(url, certificateFingerprint: certificateFingerprint);
    }
    final latencies = <String, ServerLatencyResult>{};
    final chosen = await matched.resolveConnectEndpoint(
      trackingProber,
      latencyCache: latencies,
    );
    if (!mounted || transition != _sessionTransition) return true;
    final normalizedSaved = LoginHistoryEntry.normalizeServer(savedServer);
    if (chosen.normalizedUrl == normalizedSaved ||
        latencies[chosen.probeKey]?.state != ServerLatencyState.online) {
      return false;
    }
    _setRestoringStatus(
      transition,
      '正在连接优选线路：${_shortEndpointLabel(chosen.normalizedUrl)}…',
    );
    LightIsleApi? altApi;
    try {
      altApi = LightIsleApi(
        chosen.normalizedUrl,
        allowInsecureHttp: true,
        certificateFingerprint: chosen.normalizedFingerprint,
      );
      _restoringApi = altApi;
      final status = await altApi
          .get('/api/v2/auth/status')
          .timeout(const Duration(seconds: 8));
      if (status['configured'] != true) {
        altApi.close();
        return false;
      }
      final identity = await altApi
          .send(
            'POST',
            '/api/v2/auth/login',
            body: <String, dynamic>{
              'username': matched.username,
              'password': matched.password,
            },
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted || transition != _sessionTransition) {
        altApi.close();
        return true;
      }
      if (!altApi.authenticated ||
          identity['username'] is! String ||
          identity['role'] is! String) {
        altApi.close();
        return false;
      }
      final promoted = altApi;
      altApi = null;
      await _signedIn(promoted, identity, restoring: true);
      return true;
    } catch (_) {
      altApi?.close();
      if (identical(_restoringApi, altApi)) _restoringApi = null;
      return false;
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
      await InsecureHttpAllowlist.instance.load();
      final snapshot = await _sessionStore.read();
      if (!mounted || transition != _sessionTransition || snapshot == null) {
        return;
      }
      final rawExpires = snapshot['expiresAt'];
      if (rawExpires is int &&
          rawExpires > 0 &&
          !DateTime.fromMillisecondsSinceEpoch(
            rawExpires,
          ).isAfter(DateTime.now())) {
        throw const SavedSessionExpired();
      }
      _offlineSnapshot = snapshot;
      if (await _tryRestoreViaPreferredHostEndpoint(snapshot, transition)) {
        return;
      }
      if (!mounted || transition != _sessionTransition) return;
      final savedServer = snapshot['server'];
      if (savedServer is String && savedServer.trim().isNotEmpty) {
        _setRestoringStatus(
          transition,
          '正在验证线路：${_shortEndpointLabel(savedServer)}…',
        );
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
        setState(() {
          _restoring = false;
          _restoringStatus = null;
        });
        _dismissStartupCurtain();
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
      final uname = identity['username'];
      final snapshot = session == null
          ? null
          : <String, dynamic>{
              ...session,
              if (userID is int && userID > 0) 'offlineAccountId': userID,
              if (uname is String && uname.trim().isNotEmpty)
                'offlineUsername': uname.trim(),
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
    if (_ownsThemeController) {
      _themeController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IsleThemeScope(
    controller: _themeController,
    child: ListenableBuilder(
      listenable: _themeController,
      builder: (context, _) {
        final presetId = _themeController.presetId;
        return MaterialApp(
          navigatorKey: _navigator,
          title: '轻屿 LightIsle',
          debugShowCheckedModeBanner: false,
          themeMode: _themeController.themeMode,
          theme: isleTheme(Brightness.light, presetId: presetId),
          darkTheme: isleTheme(Brightness.dark, presetId: presetId),
          highContrastTheme: buildIsleTheme(
            Brightness.light,
            presetId: presetId,
            highContrast: true,
          ),
          highContrastDarkTheme: buildIsleTheme(
            Brightness.dark,
            presetId: presetId,
            highContrast: true,
          ),
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
                  duration: _startupFadeDuration,
                  curve: IsleMotion.silk,
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
    home: IsleStageEntrance(
      stageKey: _restoring || _restoreError != null
          ? 'stage:reconnect'
          : _identity == null
          ? 'stage:login'
          : ObjectKey(_api),
      child: _restoring || _restoreError != null
          ? SessionReconnectPage(
              busy: _restoring,
              statusLabel: _restoringStatus,
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
          ),
        );
      },
    ),
  );
}
