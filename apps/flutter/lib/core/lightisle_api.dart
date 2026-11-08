import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'api_models.dart';
import 'root_api_paths.dart';
export 'api_models.dart'
    show LightIsleApiException, LightIsleRoot, SavedSessionExpired;

part 'lightisle_media_relay.dart';
part 'lightisle_http_transport.dart';
part 'lightisle_api_files.dart';

const int _maxSingleFileVerificationBytes = 2 << 30;
const int _maxRangedFileVerificationBytes = 32 << 30;
const int _fileVerificationChunkBytes = 4 << 20;

/// HTTP client for the LightIsle server.
///
/// Session state is sent only as the `lightisle_session`
/// cookie to this API's origin. Plain HTTP is accepted for loopback addresses;
/// private LAN addresses require [allowInsecureHttp]. Public HTTP URLs are
/// rejected even when that option is enabled.
class LightIsleApi {
  LightIsleRoot? _selectedRoot;
  LightIsleRoot? get selectedRoot => _selectedRoot;
  int _rootSelectionRevision = 0;
  int get rootSelectionRevision => _rootSelectionRevision;

  /// UI must dispose/recreate root-scoped pages when changing this value.
  /// Request URLs are frozen before transport and mutating operations carry
  /// the generation header. Stale requests cannot silently target a new disk.
  void selectRoot(LightIsleRoot? root) {
    if (_selectedRoot?.identity == root?.identity) return;
    _selectedRoot = root;
    _rootSelectionRevision++;
    _mediaTargets.clear();
    _mediaPrefixTargets.clear();
  }

  /// Public file links must retain the exact physical root that minted the
  /// capability. They are NOT included in the normal authenticated scoping
  /// rules; a root share token sent to the legacy global URL always 404s.
  Uri publicFileShareUri(String token) {
    return uri(RootApiPaths.publicSharePath(_selectedRoot, token));
  }

  String scopedApiPath(String path) =>
      RootApiPaths.scopedPath(_selectedRoot, path);

  /// Creates a client for an HTTP(S) server.
  ///
  /// When [certificateFingerprint] is set, the server must use HTTPS and each
  /// TLS connection is checked before request headers are written. An optional
  /// [securityContext] can add private trust roots; the leaf fingerprint is
  /// still required to match on every connection.
  LightIsleApi(
    String serverUrl, {
    HttpClient? httpClient,
    bool allowInsecureHttp = false,
    Duration requestTimeout = const Duration(seconds: 45),
    String? certificateFingerprint,
    this.securityContext,
  }) : _baseUri = _validatedLightIsleBaseUri(serverUrl, allowInsecureHttp),
       _certificateFingerprint = _normalizeLightIsleCertificateFingerprint(
         certificateFingerprint,
       ),
       _nativeMediaToken = certificateFingerprint == null
           ? null
           : _randomToken(),
       _client = httpClient ?? HttpClient(),
       _createdClient = httpClient == null,
       _requestTimeout = requestTimeout {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError('请求超时时间必须大于零。');
    }
    if (_certificateFingerprint != null && _baseUri.scheme != 'https') {
      throw ArgumentError('使用服务器证书指纹时必须连接 HTTPS 地址。');
    }
    if (securityContext != null && _certificateFingerprint == null) {
      throw ArgumentError('自定义证书上下文需要同时设置服务器证书指纹。');
    }
    if (_createdClient) {
      _client.connectionTimeout = _connectionTimeout;
      _client.idleTimeout = requestTimeout;
    }
    if (_certificateFingerprint != null) {
      // The custom connection factory verifies a leaf certificate before the
      // HttpClient can write headers or credentials. Force direct connections
      // so proxy trust cannot bypass the per-origin certificate pin.
      _client.findProxy = (_) => 'DIRECT';
      _client.connectionTimeout = _connectionTimeout;
      _client.connectionFactory = _pinnedConnectionFactory;
    }
  }

  /// Independently read and SHA-256 hash the stored NAS bytes after upload.
  /// Small files retain the original single-response contract. Larger files
  /// require local per-chunk digests from the same pass that produced the
  /// complete [expectedSHA256]; each bounded NAS range is compared with its
  /// corresponding local digest under one stable object-version token.
  /// Returns false if missing/changed; a size-only HEAD is never proof of a
  /// successful backup.
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String expectedSHA256, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) => _remoteFileMatchesSHA256Impl(
    path,
    expectedSize,
    expectedSHA256,
    chunkSHA256s: chunkSHA256s,
    checkActive: checkActive,
  );

  /// Verify that a previously uploaded original is still present on this
  /// authenticated NAS with its recorded byte length. A local success marker
  /// alone is not proof of a durable remote photo after manual deletion.
  /// HEAD cannot be redirected to another origin or send a request body.
  Future<bool> remoteFileHasSize(String path, int expectedSize) =>
      _remoteFileHasSizeImpl(path, expectedSize);

  static const String _sessionCookieName = 'lightisle_session';
  static const int _maxJsonBytes = 2 * 1024 * 1024;
  static const int _maxErrorBytes = 64 * 1024;
  static const int _maxUploadChunkBytes = 8 * 1024 * 1024;
  static const int _maxMediaTargets = 128;
  static const Duration _connectionTimeout = Duration(seconds: 15);

  static int _downloadSequence = 0;

  static String _randomToken() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256), growable: false),
    ).replaceAll('=', '');
  }

  static const Map<String, String> _errorMessages = <String, String>{
    'storage_quota_exceeded': '个人存储空间不足，请清理无用文件或联系管理员调整配额。',
    'storage_reservation_missing': '上传容量预占记录缺失，请取消旧任务并重新上传。',
    'storage_accounting_conflict': '目标文件已存在或正在占用空间，请更换文件名后再试。',
    'storage_accounting_uncertain': '文件可能已写入，但空间账本尚未确认，请核对后再操作。',
    'storage_operation_uncertain': '操作可能已在原硬盘上执行。请重新连接原硬盘并检查文件和回收站，再决定是否重试。',
    'storage_trash_purge_accounting_pending': '为避免误释放其他文件的额度，暂时无法永久清理私人目录的回收站。文件仍可恢复，请等待修复。',
    'trash_item_changed': '回收站中的内容与原记录不一致，操作已停止。请在 Mac 上检查原位置和回收站后再处理。',
    'storage_destination_not_assigned': '存储硬盘未分配或已离线，请在存储设置中检查。',
    'authentication_required': '登录状态已失效，请重新登录。',
    'invalid_credentials': '用户名或密码不正确，请检查后重试。',
    'current_password_invalid': '当前密码不正确，请检查后重试。',
    'invalid_new_password': '新密码需为 12–256 字节，首尾不能有空白字符。',
    'password_change_failed': '密码未能更新，请稍后重试。',
    'password_reset_failed': '成员密码未能重置，请稍后重试。',
    'protected_account': '此账号受保护或已停用，无法执行此操作。',
    'username_exists': '用户名已存在，请使用其他名称。',
    'sessions_unavailable': '暂时无法读取登录会话，请稍后重试。',
    'session_revoke_failed': '会话未能撤销，请稍后重试。',
    'alert_center_unavailable': '异常通知暂时不可用，请稍后刷新。',
    'audit_unavailable': '审计记录暂时不可用，请稍后刷新。',
    'too_many_attempts': '登录尝试过于频繁，请稍后再试。',
    'download_network_admin_only': '只有管理员可以发起或继续网络下载。',
    'upload_server_busy': '上传通道已满，请稍后重试。',
    'upload_timed_out': '上传长时间未收到数据，请检查连接后重试。',
    'password_service_busy': '密码验证繁忙，请稍后重试。',
    'admin_only': '此操作需要管理员权限。',
    'database_not_ready': '账户服务尚未就绪，请稍后重试。',
    'database_unavailable': '账户服务暂时不可用，请稍后重试。',
    'invalid_request': '请求内容无效，请检查后重试。',
    'invalid_path': '文件路径无效，请重新选择文件。',
    'file_permission_denied': '当前账户没有权限执行此操作。',
    'file_not_found': '找不到对应文件，它可能已被移动或删除。',
    'storage_unavailable': '文件存储暂时不可用，请稍后重试。',
    'default_root_not_configured':
        '尚未指定默认 NAS 存储目录。请在 Mac LightIsle「数据与存储 → NAS 存储空间」选择已登记且在线的硬盘并设为默认。',
    'registered_root_required': '需要明确选择已登记的存储硬盘。请刷新硬盘列表并重新选择原目录。',
    'root_unavailable': '原存储硬盘当前无法使用或身份未确认，请在 Mac「数据与存储」检查并重新确认连接。',
    'root_not_found': '所选物理存储目录已被移除，请在 Mac「数据与存储」检查登记记录。',
    'root_generation_changed': '存储硬盘身份已变化，请刷新硬盘列表并重新选择原目录。',
    'storage_registry_unavailable': '无法读取存储硬盘登记配置，请检查 Mac LightIsle 的存储管理状态。',
    'storage_root_unavailable': '当前存储硬盘已离线或身份验证失败，请在 Mac「数据与存储」检查原硬盘。',
    'shared_volume_offline': '共享存储磁盘离线，请在 Mac「数据与存储」检查连接并确认重新绑定。',
    'share_root_offline': '共享存储目录离线，请在 Mac「数据与存储」检查原硬盘的连接状态。',
    'volume_offline': '图库所在硬盘已离线或身份尚未确认，请在 Mac「数据与存储」检查原卷。',
    'gallery_unavailable': '当前图库服务未就绪，请先确认 Mac 上的存储目录已正确连接。',
    'cinema_unavailable': '当前影视索引服务未就绪，请先确认 Mac 上的存储目录已正确连接。',
    'shared_directory_transition_busy': 'Mac 正在切换共享目录，请稍后刷新重试。原请求不会写入新目录。',
    'verification_filesystem_unsupported':
        '大视频分块校验目前需要 APFS 格式的 Mac 存储卷；请把 NAS 备份目录放在 APFS 磁盘后重试。',
    'verification_filesystem_unavailable': '无法确认存储卷类型，已停止大文件校验以避免误报备份成功。',
    'offset_mismatch': '上传进度已变化，请刷新上传状态后重试。',
    'invalid_chunk_size': '上传数据块大小无效，请重试。',
    'redirect_not_allowed': '服务器返回了不安全的跳转，已停止请求。',
    'response_too_large': '服务器返回的数据过大，无法安全读取。',
    'invalid_response': '服务器返回的数据无法识别，请稍后重试。',
    'network_timeout': '连接服务器超时，请检查网络后重试。',
    'network_error': '无法连接服务器，请检查地址和网络后重试。',
    'certificate_untrusted':
        '无法验证服务器证书。连接 Mac 自签名 HTTPS 时，请在连接安全设置中填入并核对管理端显示的 SHA-256 指纹。',
    'certificate_mismatch': '服务器证书指纹已变化或无效，请核对服务器证书后重试。',
    'media_relay_unavailable': '无法安全启动本机媒体转发，请重试。',
    'download_failed': '文件保存失败，请检查存储空间和目标位置。',
    'destination_exists': '目标位置已存在文件，请选择其他位置。',
    'upload_length_mismatch': '上传数据长度与声明不一致，请重试。',
  };

  final Uri _baseUri;
  final String? _certificateFingerprint;
  final SecurityContext? securityContext;
  String? _nativeMediaToken;
  final HttpClient _client;
  final bool _createdClient;
  final Duration _requestTimeout;
  _SessionCookie? _sessionCookie;
  HttpServer? _mediaRelay;
  Future<HttpServer>? _mediaRelayStarting;
  final Map<String, Uri> _mediaTargets = <String, Uri>{};
  final Map<String, Uri> _mediaPrefixTargets = <String, Uri>{};
  bool _closed = false;

  /// Called after a protected request receives `authentication_required`.
  /// Invalid login responses do not clear a previously valid session.
  void Function()? onUnauthorized;

  /// Whether an unexpired session cookie is currently held in memory.
  bool get authenticated => _liveSessionCookie != null;

  /// The normalized SHA-256 fingerprint pinned to this server, if configured.
  String? get certificateFingerprint => _certificateFingerprint;

  /// Sensitive snapshot for the OS-protected session vault only. Never put
  /// this map in preferences, logs, URLs, or UI state restored without /me.
  Map<String, dynamic>? get sessionSnapshot {
    final cookie = _liveSessionCookie;
    if (cookie == null || cookie.expiresAt == null) return null;
    return {
      'version': 1,
      'server': _baseUri.origin,
      'cookie': cookie.value,
      'expiresAt': cookie.expiresAt!.millisecondsSinceEpoch,
      'certificateFingerprint': _certificateFingerprint,
    };
  }

  factory LightIsleApi.fromSessionSnapshot(Map<String, dynamic> snapshot) {
    if (snapshot['version'] != 1 ||
        snapshot['server'] is! String ||
        (snapshot['certificateFingerprint'] != null &&
            snapshot['certificateFingerprint'] is! String)) {
      throw const FormatException('保存的登录状态无效，请重新登录。');
    }
    final api = LightIsleApi(
      snapshot['server'] as String,
      allowInsecureHttp: true,
      certificateFingerprint: snapshot['certificateFingerprint'] as String?,
    );
    try {
      api.restoreSession(snapshot);
      return api;
    } catch (_) {
      api.close();
      rethrow;
    }
  }

  void restoreSession(Map<String, dynamic> snapshot) {
    _ensureOpen();
    final value = snapshot['cookie'];
    final expires = snapshot['expiresAt'];
    if (snapshot['version'] != 1 ||
        snapshot['server'] != _baseUri.origin ||
        snapshot['certificateFingerprint'] != _certificateFingerprint ||
        value is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{30,128}$').hasMatch(value) ||
        expires is! int ||
        expires <= 0 ||
        expires > 8640000000000000) {
      throw const FormatException('保存的登录状态无效，请重新登录。');
    }
    final expiry = DateTime.fromMillisecondsSinceEpoch(expires);
    if (!expiry.isAfter(DateTime.now())) throw const SavedSessionExpired();
    _sessionCookie = _SessionCookie(value, expiry);
  }

  /// Headers for native media APIs that cannot use this client's HTTP stack.
  /// Use only with a URI returned by [uri], so the cookie remains on this
  /// server's origin and never becomes part of a URL.
  Map<String, String> get mediaHeaders {
    final cookie = _liveSessionCookie;
    if (cookie == null) return const <String, String>{};
    return Map<String, String>.unmodifiable(<String, String>{
      HttpHeaders.cookieHeader: '$_sessionCookieName=${cookie.value}',
    });
  }

  /// Headers for native media requests.
  ///
  /// With a pinned certificate, native players use a loopback relay and this
  /// per-client bearer token; the session cookie is added only by the pinned
  /// Dart HTTP client when it contacts the configured server. Without a pin,
  /// this is equivalent to [mediaHeaders].
  Map<String, String> get nativeMediaHeaders {
    final token = _nativeMediaToken;
    if (token == null) return mediaHeaders;
    return Map<String, String>.unmodifiable(<String, String>{
      'X-LightIsle-Media-Token': token,
    });
  }

  /// Returns a native-player URI for a same-origin media endpoint.
  ///
  /// Unpinned servers are returned directly. Pinned servers are exposed only
  /// through this API instance's authenticated loopback relay so plugins that
  /// own a separate TLS stack never receive the server cookie or bypass the
  /// configured certificate fingerprint.
  Future<Uri> mediaUri(String path, {Map<String, String>? query}) async {
    _ensureOpen();
    final target = uri(path, query);
    if (_certificateFingerprint == null) return target;

    final relay = await _ensureMediaRelay();
    _ensureOpen();
    final id = _randomToken();
    _mediaTargets[id] = target;
    while (_mediaTargets.length > _maxMediaTargets) {
      _mediaTargets.remove(_mediaTargets.keys.first);
    }
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: relay.port,
      pathSegments: <String>['media', id],
    );
  }

  /// Returns a native-player URI for an HLS playlist inside a session
  /// directory, e.g. `/api/v2/cinema/{id}/hls/{session}/`.
  ///
  /// HLS playlists reference segments with relative URLs, so a pinned server
  /// cannot use the single-target [mediaUri] relay: the player would resolve
  /// `segment_00000.m4s` against the relay origin without a registered id.
  /// Instead one prefix target is registered for the whole session directory
  /// and the relay forwards a strict allow-list of playlist/segment names
  /// beneath `/media/hls/{id}/`. Unpinned servers return the direct URL.
  Future<Uri> mediaHlsUri(String path) async {
    _ensureOpen();
    final normalized = path.endsWith('/') ? path : '$path/';
    final target = uri(normalized);
    if (_certificateFingerprint == null) {
      return target
          .resolve('index.m3u8')
          .replace(
            queryParameters: target.queryParameters.isEmpty
                ? null
                : target.queryParameters,
          );
    }
    final relay = await _ensureMediaRelay();
    _ensureOpen();
    final id = _randomToken();
    _mediaPrefixTargets[id] = target;
    while (_mediaPrefixTargets.length > _maxMediaTargets) {
      _mediaPrefixTargets.remove(_mediaPrefixTargets.keys.first);
    }
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: relay.port,
      pathSegments: <String>['media', 'hls', id, 'index.m3u8'],
    );
  }

  /// Builds a same-origin endpoint URI and safely encodes [query].
  Uri uri(String path, [Map<String, String>? query]) {
    if (path.isEmpty || path.startsWith('//') || path.contains('\\')) {
      throw ArgumentError('请求路径必须位于当前服务器内。');
    }
    final sessionValue = _liveSessionCookie?.value;
    if (query?.keys.any((key) => key.toLowerCase() == _sessionCookieName) ??
        false) {
      throw ArgumentError('认证信息只能通过 Cookie 请求头发送。');
    }
    if (sessionValue != null &&
        (path.contains(sessionValue) ||
            (query?.values.any((value) => value.contains(sessionValue)) ??
                false))) {
      throw ArgumentError('认证信息不能放入 URL。');
    }
    for (final segment in path.split('/')) {
      String decodedSegment;
      try {
        decodedSegment = Uri.decodeComponent(segment);
      } on FormatException {
        throw ArgumentError('请求路径必须位于当前服务器内。');
      }
      if (decodedSegment == '.' ||
          decodedSegment == '..' ||
          decodedSegment.contains('/') ||
          decodedSegment.contains('\\')) {
        throw ArgumentError('请求路径必须位于当前服务器内。');
      }
    }
    final parsed = Uri.tryParse(path);
    if (parsed == null ||
        parsed.hasScheme ||
        parsed.hasAuthority ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        parsed.pathSegments.any(
          (segment) => segment == '.' || segment == '..',
        )) {
      throw ArgumentError('请求路径必须位于当前服务器内。');
    }

    final normalized = parsed.path.startsWith('/') ? path : '/$path';
    final scoped = scopedApiPath(normalized);
    final root = _selectedRoot;
    // Bind the generation to the URL BEFORE any asynchronous transport work.
    // If the same root ID is later rebound to another physical disk, the old
    // URI must fail rather than acquiring the new disk's generation header.
    final effectiveQuery = <String, String>{...?query};
    if (scoped != normalized && root != null) {
      effectiveQuery['rootGeneration'] = '${root.generation}';
    }
    final result = _baseUri
        .resolveUri(Uri.parse(scoped))
        .replace(
          queryParameters: effectiveQuery.isEmpty ? null : effectiveQuery,
        );
    if (!_sameOrigin(result, _baseUri)) {
      throw ArgumentError('请求路径必须位于当前服务器内。');
    }
    return result;
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    final context = await _openRequest('GET', uri(path, query));
    final bytes = await _readWithCookieCapture(context, _maxJsonBytes);
    _throwForBadStatus(context, bytes);
    return _decodeJsonObject(bytes);
  }

  /// An explicit generation-bound root configuration action. Keeping this
  /// separate preserves the existing send contract and its fake/test clients.
  Future<Map<String, dynamic>> assignStorageRoot(
    String path,
    int rootGeneration,
  ) async {
    if (rootGeneration < 1 || !path.startsWith('/api/v2/roots/')) {
      throw ArgumentError('根目录路径或代际无效。');
    }
    final context = await _openRequest(
      'PUT',
      uri(path),
      extraHeaders: <String, String>{
        'X-LightIsle-Root-Generation': '$rootGeneration',
      },
    );
    final bytes = await _readWithCookieCapture(context, _maxJsonBytes);
    _throwForBadStatus(context, bytes);
    return _decodeJsonObject(bytes);
  }

  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final normalizedMethod = method.toUpperCase();
    if (!RegExp(r'^[A-Z]{3,12}$').hasMatch(normalizedMethod)) {
      throw ArgumentError('HTTP 方法无效。');
    }

    Uint8List? bodyBytes;
    if (body != null) {
      try {
        bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
      } on Object {
        throw const LightIsleApiException(
          code: 'invalid_request_body',
          message: '请求内容无法编码，请检查后重试。',
        );
      }
    }

    final context = await _openRequest(
      normalizedMethod,
      uri(path, query),
      contentType: bodyBytes == null ? null : 'application/json; charset=utf-8',
      bodyLength: bodyBytes?.length,
      writeBody: bodyBytes == null
          ? null
          : (request) {
              request.add(bodyBytes!);
            },
    );
    final bytes = await _readWithCookieCapture(context, _maxJsonBytes);
    _throwForBadStatus(context, bytes);
    return _decodeJsonObject(bytes);
  }

  /// Reads a bounded binary response into memory.
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    final limit = maxBytes ?? 16 * 1024 * 1024;
    if (limit < 0) {
      throw ArgumentError('最大响应大小不能小于零。');
    }
    final context = await _openRequest('GET', uri(path, query), accept: '*/*');
    final data = await _readWithCookieCapture(context, limit);
    _throwForBadStatus(context, data);
    return data;
  }

  /// Measures transfer to the *currently authenticated LightIsle origin*,
  /// never a public speed-test provider or an arbitrary external address.
  /// Server-generated data is discarded after the request; it is not a file.
  Future<int> networkTestDownload(
    int length, {
    void Function(int transferred, int total)? onProgress,
  }) => _networkTestDownloadImpl(length, onProgress: onProgress);

  /// Bounded binary upload (no user file). This retains TLS pinning, cookies,
  /// no-redirect rules and request timeouts through the normal API transport.
  Future<int> networkTestUpload(
    int length, {
    void Function(int transferred, int total)? onProgress,
  }) => _networkTestUploadImpl(length, onProgress: onProgress);

  /// Streams a response to [destination] without replacing an existing file.
  ///
  /// [onProgress] receives transferred bytes and the response length, or -1
  /// when the server does not provide a content length.
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) => _downloadImpl(path, destination, query: query, onProgress: onProgress);

  /// Sends one resumable upload chunk using the server's offset contract.
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int offset,
  ) => _uploadChunkImpl(id, data, length, offset);

  /// Clears session state and force-closes the client, aborting active streams.
  /// This also closes an injected client.
  void close() {
    if (_closed) return;
    _closed = true;
    _sessionCookie = null;
    _nativeMediaToken = null;
    _mediaTargets.clear();
    _mediaPrefixTargets.clear();
    _client.close(force: true);
    final relay = _mediaRelay;
    _mediaRelay = null;
    if (relay != null) {
      unawaited(relay.close(force: true).catchError((Object _) {}));
    }
  }

  static bool _isSuccess(int statusCode) =>
      statusCode >= 200 && statusCode < 300;

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;
}

final class _SessionCookie {
  const _SessionCookie(this.value, this.expiresAt);

  final String value;
  final DateTime? expiresAt;
}

final class _RequestContext {
  const _RequestContext(this.response, this.previousCookie, this.requestUri);

  final HttpClientResponse response;
  final String? previousCookie;
  final Uri requestUri;
}
