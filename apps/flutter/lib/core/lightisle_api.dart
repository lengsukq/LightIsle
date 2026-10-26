import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int _maxSingleFileVerificationBytes = 2 << 30;
const int _maxRangedFileVerificationBytes = 32 << 30;
const int _fileVerificationChunkBytes = 4 << 20;

/// A structured API failure with a stable machine-readable [code].
///
/// The message is safe to show to a user. Response bodies, request URLs, and
/// session cookies are deliberately never included in [toString].
final class LightIsleApiException implements Exception {
  const LightIsleApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// HTTP client for the LightIsle server.
///
/// Session state stays in memory and is sent only as the `lightisle_session`
/// cookie to this API's origin. Plain HTTP is accepted for loopback addresses;
/// private LAN addresses require [allowInsecureHttp]. Public HTTP URLs are
/// rejected even when that option is enabled.
class LightIsleApi {
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
  }) : _baseUri = _validatedBaseUri(serverUrl, allowInsecureHttp),
       _certificateFingerprint = _normalizeCertificateFingerprint(
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
  }) async {
    if (expectedSize < 0 ||
        expectedSize > _maxRangedFileVerificationBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSHA256)) {
      throw ArgumentError('无效的照片 SHA-256 校验输入。');
    }
    if (expectedSize > _maxSingleFileVerificationBytes) {
      final expectedChunks =
          (expectedSize + _fileVerificationChunkBytes - 1) ~/
          _fileVerificationChunkBytes;
      if (chunkSHA256s == null ||
          chunkSHA256s.length != expectedChunks ||
          chunkSHA256s.any(
            (digest) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest),
          )) {
        throw ArgumentError('大文件 SHA-256 校验需要完整的本地分块摘要。');
      }
      return _remoteFileMatchesRangedSHA256(
        path,
        expectedSize,
        chunkSHA256s,
        checkActive: checkActive,
      );
    }
    checkActive?.call();
    final Map<String, dynamic> result;
    try {
      result = await get('/api/v1/files/sha256', query: {'path': path});
      checkActive?.call();
    } on LightIsleApiException catch (error) {
      if (error.statusCode == HttpStatus.notFound) return false;
      rethrow;
    }
    final actual = result['sha256'];
    final size = result['size'];
    if (result['algorithm'] != 'sha256' ||
        actual is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(actual) ||
        size is! num ||
        !_isExactInteger(size)) {
      throw const LightIsleApiException(
        code: 'invalid_response',
        message: '服务器未返回可信的 SHA-256 校验结果。',
      );
    }
    return actual == expectedSHA256 && size.toInt() == expectedSize;
  }

  Future<bool> _remoteFileMatchesRangedSHA256(
    String path,
    int expectedSize,
    List<String> chunkSHA256s, {
    void Function()? checkActive,
  }) async {
    String? version;
    var offset = 0;
    var chunkIndex = 0;
    while (offset < expectedSize) {
      checkActive?.call();
      final length = min(_fileVerificationChunkBytes, expectedSize - offset);
      final query = <String, String>{
        'path': path,
        'mode': 'range',
        'offset': '$offset',
        'length': '$length',
        'version': ?version,
      };
      final Map<String, dynamic> result;
      try {
        result = await get('/api/v1/files/sha256', query: query);
        checkActive?.call();
      } on LightIsleApiException catch (error) {
        if (error.statusCode == HttpStatus.notFound) return false;
        rethrow;
      }
      final actual = result['sha256'];
      final size = result['size'];
      final actualOffset = result['offset'];
      final actualLength = result['length'];
      final actualVersion = result['version'];
      if (result['algorithm'] != 'sha256' ||
          actual is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(actual) ||
          size is! num ||
          actualOffset is! num ||
          actualLength is! num ||
          !_isExactInteger(size) ||
          !_isExactInteger(actualOffset) ||
          !_isExactInteger(actualLength) ||
          actualVersion is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(actualVersion)) {
        throw const LightIsleApiException(
          code: 'invalid_response',
          message: '服务器未返回可信的分块 SHA-256 校验结果。',
        );
      }
      if (size.toInt() != expectedSize ||
          actualOffset.toInt() != offset ||
          actualLength.toInt() != length ||
          (version != null && actualVersion != version)) {
        return false;
      }
      version ??= actualVersion;
      if (actual != chunkSHA256s[chunkIndex]) return false;
      offset += length;
      chunkIndex++;
    }
    checkActive?.call();
    return offset == expectedSize && chunkIndex == chunkSHA256s.length;
  }

  bool _isExactInteger(num value) =>
      value.isFinite && value == value.roundToDouble();

  /// Verify that a previously uploaded original is still present on this
  /// authenticated NAS with its recorded byte length. A local success marker
  /// alone is not proof of a durable remote photo after manual deletion.
  /// HEAD cannot be redirected to another origin or send a request body.
  Future<bool> remoteFileHasSize(String path, int expectedSize) async {
    if (expectedSize < 0) throw ArgumentError('文件大小无效。');
    final context = await _openRequest(
      'HEAD',
      uri('/api/v1/files/content', <String, String>{'path': path}),
      accept: '*/*',
    );
    // HEAD advertises the *full remote file size* in Content-Length, even
    // though no body is transmitted. The JSON read-size gate must not be
    // applied to that header or a large photo would be rejected as a reply.
    try {
      await context.response.drain<void>();
    } finally {
      _captureCookies(context.response, context.requestUri);
    }
    if (context.response.statusCode == HttpStatus.notFound) return false;
    _throwForBadStatus(context, Uint8List(0));
    return context.response.contentLength == expectedSize;
  }

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
    'admin_only': '此操作需要管理员权限。',
    'database_not_ready': '账户服务尚未就绪，请稍后重试。',
    'database_unavailable': '账户服务暂时不可用，请稍后重试。',
    'invalid_request': '请求内容无效，请检查后重试。',
    'invalid_path': '文件路径无效，请重新选择文件。',
    'file_permission_denied': '当前账户没有权限执行此操作。',
    'file_not_found': '找不到对应文件，它可能已被移动或删除。',
    'storage_unavailable': '文件存储暂时不可用，请稍后重试。',
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
  /// directory, e.g. `/api/v1/cinema/{id}/hls/{session}/`.
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
      return target.resolve('index.m3u8');
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

    final endpoint = parsed.path.startsWith('/')
        ? parsed
        : parsed.replace(path: '/${parsed.path}');
    final result = _baseUri
        .resolveUri(endpoint)
        .replace(queryParameters: query);
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

  /// Streams a response to [destination] without replacing an existing file.
  ///
  /// [onProgress] receives transferred bytes and the response length, or -1
  /// when the server does not provide a content length.
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    final target = File(destination);
    if (await _destinationExists(destination)) {
      throw _destinationAlreadyExists();
    }
    final targetUri = uri(path, query);
    final context = await _openRequest('GET', targetUri, accept: '*/*');
    final response = context.response;
    if (!_isSuccess(response.statusCode)) {
      final body = await _readWithCookieCapture(context, _maxErrorBytes);
      _throwForBadStatus(context, body);
    }
    _captureCookies(response, targetUri);

    final total = response.contentLength;
    final parent = target.parent;
    final sequence = ++_downloadSequence;
    final temporary = File(
      '${target.path}.lightisle-$pid-${DateTime.now().microsecondsSinceEpoch}-$sequence.part',
    );
    RandomAccessFile? output;
    var received = 0;
    var destinationReserved = false;
    try {
      await parent.create(recursive: true);
      output = await temporary.open(mode: FileMode.writeOnly);
      onProgress?.call(0, total);
      await for (final chunk in response.timeout(_requestTimeout)) {
        await output.writeFrom(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await output.flush();
      await output.close();
      output = null;
      try {
        await target.create(exclusive: true);
        destinationReserved = true;
      } on FileSystemException {
        if (await _destinationExists(destination)) {
          throw _destinationAlreadyExists();
        }
        rethrow;
      }
      final sink = target.openWrite();
      try {
        await temporary.openRead().pipe(sink);
      } on Object {
        await sink.close();
        rethrow;
      }
      destinationReserved = false;
    } on LightIsleApiException {
      rethrow;
    } on TimeoutException {
      throw _networkTimeout();
    } on FileSystemException {
      throw const LightIsleApiException(
        code: 'download_failed',
        message: '文件保存失败，请检查存储空间和目标位置。',
      );
    } on SocketException {
      throw _networkError();
    } on HttpException {
      throw _networkError();
    } finally {
      try {
        await output?.close();
      } on Object {
        // Preserve the transfer error; the temporary file cleanup below is
        // best-effort because a closed or full filesystem can reject it.
      }
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // Preserve the primary result.
      }
      if (destinationReserved) {
        try {
          await target.delete();
        } on Object {
          // Preserve the transfer error.
        }
      }
    }
  }

  /// Sends one resumable upload chunk using the server's offset contract.
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int offset,
  ) async {
    if (id.isEmpty ||
        id == '.' ||
        id == '..' ||
        id.contains('/') ||
        id.contains('\\')) {
      throw ArgumentError('上传标识无效。');
    }
    if (length < 0 || length > _maxUploadChunkBytes) {
      throw ArgumentError('上传数据块必须介于 0 到 8 MiB。');
    }
    if (offset < 0) {
      throw ArgumentError('上传偏移量不能小于零。');
    }

    final encodedId = Uri.encodeComponent(id);
    final context = await _openRequest(
      'PATCH',
      uri('/api/v1/uploads/$encodedId'),
      accept: 'application/json',
      contentType: 'application/octet-stream',
      bodyLength: length,
      extraHeaders: <String, String>{'X-Upload-Offset': '$offset'},
      writeBody: (request) async {
        await request.addStream(_exactLengthStream(data, length));
      },
    );
    final bytes = await _readWithCookieCapture(context, _maxJsonBytes);
    _throwForBadStatus(context, bytes);
    return _decodeJsonObject(bytes);
  }

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

  Future<HttpServer> _ensureMediaRelay() {
    _ensureOpen();
    final existing = _mediaRelay;
    if (existing != null) return Future<HttpServer>.value(existing);
    final pending = _mediaRelayStarting;
    if (pending != null) return pending;
    final completer = Completer<HttpServer>();
    _mediaRelayStarting = completer.future;
    _startMediaRelay().then(
      completer.complete,
      onError: (Object error, StackTrace stackTrace) {
        _mediaRelayStarting = null;
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  Future<HttpServer> _startMediaRelay() async {
    late final HttpServer relay;
    try {
      relay = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
    } on Object {
      throw const LightIsleApiException(
        code: 'media_relay_unavailable',
        message: '无法安全启动本机媒体转发，请重试。',
      );
    }
    if (_closed) {
      await relay.close(force: true);
      _ensureOpen();
    }
    _mediaRelay = relay;
    relay.listen(
      (request) => unawaited(_handleMediaRelayRequest(request)),
      onError: (Object _) {},
      cancelOnError: false,
    );
    return relay;
  }

  Future<void> _handleMediaRelayRequest(HttpRequest request) async {
    try {
      await _serveMediaRelayRequest(request);
    } on Object {
      // Header accessors can throw on duplicate values. Keep malformed local
      // player requests isolated to this response instead of leaking an error
      // from the unawaited server callback.
      try {
        request.response.statusCode = HttpStatus.badRequest;
      } on Object {
        // The response may already have been committed or abandoned.
      }
      await _closeRelayResponse(request.response);
    }
  }

  Future<void> _serveMediaRelayRequest(HttpRequest request) async {
    final local = request.response;
    var headersCommitted = false;
    final remoteAddress = request.connectionInfo?.remoteAddress;
    if (_closed || remoteAddress == null || !remoteAddress.isLoopback) {
      local.statusCode = HttpStatus.forbidden;
      await _closeRelayResponse(local);
      return;
    }
    final suppliedToken = _singleHeaderValue(
      request.headers,
      'X-LightIsle-Media-Token',
    );
    if (!_constantTimeEquals(_nativeMediaToken, suppliedToken)) {
      local.statusCode = HttpStatus.forbidden;
      await _closeRelayResponse(local);
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      local.statusCode = HttpStatus.methodNotAllowed;
      local.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await _closeRelayResponse(local);
      return;
    }
    if (request.contentLength > 0 ||
        _singleHeaderValue(
              request.headers,
              HttpHeaders.transferEncodingHeader,
            ) !=
            null) {
      local.statusCode = HttpStatus.badRequest;
      await _closeRelayResponse(local);
      return;
    }
    Uri? target;
    final hlsMatch = RegExp(
      r'^/media/hls/([A-Za-z0-9_-]{40,48})/(index\.m3u8|init\.mp4|segment_[0-9]{5}\.m4s)$',
    ).firstMatch(request.uri.path);
    if (hlsMatch != null) {
      // HLS session directories forward an allow-listed remainder beneath a
      // registered prefix so relative segment URLs keep flowing through the
      // authenticated loopback relay.
      final base = _mediaPrefixTargets[hlsMatch.group(1)];
      if (base == null || !_sameOrigin(base, _baseUri)) {
        local.statusCode = HttpStatus.notFound;
        await _closeRelayResponse(local);
        return;
      }
      target = base.resolve(hlsMatch.group(2)!);
    } else {
      if (request.uri.query.isNotEmpty ||
          !RegExp(r'^/media/([A-Za-z0-9_-]{40,48})$')
              .hasMatch(request.uri.path)) {
        local.statusCode = HttpStatus.notFound;
        await _closeRelayResponse(local);
        return;
      }
      final id = request.uri.pathSegments.length == 2
          ? request.uri.pathSegments[1]
          : '';
      target = _mediaTargets[id];
    }
    if (target == null || !_sameOrigin(target, _baseUri)) {
      local.statusCode = HttpStatus.notFound;
      await _closeRelayResponse(local);
      return;
    }

    final range = _singleHeaderValue(request.headers, HttpHeaders.rangeHeader);
    if (range != null && !_isSafeMediaRange(range)) {
      local.statusCode = HttpStatus.badRequest;
      await _closeRelayResponse(local);
      return;
    }
    final ifRange = _singleHeaderValue(
      request.headers,
      HttpHeaders.ifRangeHeader,
    );
    if (ifRange != null &&
        (ifRange.length > 512 ||
            ifRange.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f))) {
      local.statusCode = HttpStatus.badRequest;
      await _closeRelayResponse(local);
      return;
    }

    try {
      final context = await _openRequest(
        request.method,
        target,
        accept: '*/*',
        extraHeaders: <String, String>{
          HttpHeaders.rangeHeader: ?range,
          HttpHeaders.ifRangeHeader: ?ifRange,
          HttpHeaders.acceptEncodingHeader: 'identity',
        },
      );
      final upstream = context.response;
      _captureCookies(upstream, target);

      if (upstream.statusCode >= 300 && upstream.statusCode < 400) {
        await _discardResponse(upstream);
        local.statusCode = HttpStatus.badGateway;
        await _closeRelayResponse(local);
        return;
      }
      if (!_isSuccess(upstream.statusCode) &&
          upstream.statusCode != HttpStatus.requestedRangeNotSatisfiable) {
        final errorBody = await _readResponse(upstream, _maxErrorBytes);
        try {
          _throwForBadStatus(context, errorBody);
        } on LightIsleApiException catch (error) {
          local.statusCode = error.statusCode ?? HttpStatus.badGateway;
          await _closeRelayResponse(local);
          return;
        }
      }

      local.statusCode = upstream.statusCode;
      _copyMediaResponseHeaders(upstream.headers, local.headers);
      if (upstream.contentLength >= 0) {
        local.contentLength = upstream.contentLength;
      }
      if (request.method == 'HEAD' ||
          upstream.statusCode == HttpStatus.notModified ||
          upstream.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await _discardResponse(upstream);
        await _closeRelayResponse(local);
        return;
      }

      local.bufferOutput = false;
      await for (final chunk in upstream.timeout(_requestTimeout)) {
        local.add(chunk);
        await local.flush();
        headersCommitted = true;
      }
      await _closeRelayResponse(local);
    } on TimeoutException {
      if (!headersCommitted) local.statusCode = HttpStatus.badGateway;
      await _closeRelayResponse(local);
    } on LightIsleApiException catch (error) {
      if (!headersCommitted) {
        local.statusCode = error.statusCode ?? HttpStatus.badGateway;
      }
      await _closeRelayResponse(local);
    } on Object {
      if (!headersCommitted) local.statusCode = HttpStatus.badGateway;
      await _closeRelayResponse(local);
    }
  }

  Future<void> _discardResponse(HttpClientResponse response) async {
    final completed = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    Timer? deadline;
    var received = 0;
    try {
      subscription = response.listen(
        (chunk) {
          received += chunk.length;
          if (received > _maxErrorBytes) {
            unawaited(subscription.cancel());
            if (!completed.isCompleted) completed.complete();
          }
        },
        onError: (Object _, StackTrace _) {
          if (!completed.isCompleted) completed.complete();
        },
        onDone: () {
          if (!completed.isCompleted) completed.complete();
        },
        cancelOnError: true,
      );
      deadline = Timer(_requestTimeout, () {
        unawaited(subscription.cancel());
        if (!completed.isCompleted) completed.complete();
      });
      await completed.future;
    } on Object {
      // The relay is closing this response; a drain error carries no useful
      // information to the native player.
    } finally {
      deadline?.cancel();
      if (deadline != null) unawaited(subscription.cancel());
    }
  }

  String? _singleHeaderValue(HttpHeaders headers, String name) {
    final values = headers[name] ?? const <String>[];
    if (values.length > 1) {
      throw const FormatException('重复的媒体请求头。');
    }
    return values.isEmpty ? null : values.single;
  }

  Future<void> _closeRelayResponse(HttpResponse response) async {
    try {
      await response.close();
    } on Object {
      // A disconnected native player has already abandoned this relay stream.
    }
  }

  void _copyMediaResponseHeaders(HttpHeaders source, HttpHeaders target) {
    for (final name in <String>[
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.cacheControlHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.contentTypeHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.lastModifiedHeader,
    ]) {
      for (final value in source[name] ?? const <String>[]) {
        target.add(name, value);
      }
    }
  }

  bool _isSafeMediaRange(String value) {
    if (value.length > 80) return false;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null) return false;
    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty && endText.isEmpty) return false;
    final start = int.tryParse(startText);
    final end = int.tryParse(endText);
    if ((startText.isNotEmpty && start == null) ||
        (endText.isNotEmpty && end == null)) {
      return false;
    }
    return start == null || end == null || end >= start;
  }

  bool _constantTimeEquals(String? expected, String? actual) {
    if (expected == null || actual == null) return false;
    final left = utf8.encode(expected);
    final right = utf8.encode(actual);
    var difference = left.length ^ right.length;
    final count = left.length < right.length ? left.length : right.length;
    for (var index = 0; index < count; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  Future<_RequestContext> _openRequest(
    String method,
    Uri target, {
    String accept = 'application/json',
    String? contentType,
    int? bodyLength,
    Map<String, String>? extraHeaders,
    FutureOr<void> Function(HttpClientRequest request)? writeBody,
  }) async {
    _ensureOpen();
    final previousCookie = _liveSessionCookie?.value;
    HttpClientRequest? pendingRequest;
    try {
      final request = await _client
          .openUrl(method, target)
          .timeout(_requestTimeout);
      pendingRequest = request;
      // HttpClient follows redirects by default. A manually supplied Cookie
      // header must never cross an origin boundary, so reject every redirect.
      request.followRedirects = false;
      request.maxRedirects = 0;
      request.headers.set(HttpHeaders.acceptHeader, accept);
      if (contentType != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      final cookie = _liveSessionCookie;
      if (cookie != null) {
        request.headers.set(
          HttpHeaders.cookieHeader,
          '$_sessionCookieName=${cookie.value}',
        );
      }
      if (method != 'GET' && method != 'HEAD') {
        request.headers.set('X-LightIsle-Request', '1');
      }
      extraHeaders?.forEach(request.headers.set);
      if (bodyLength != null) request.contentLength = bodyLength;
      if (writeBody != null) {
        await Future<void>.sync(() => writeBody(request))
            .timeout(_requestTimeout);
      }
      final response = await request.close().timeout(_requestTimeout);
      pendingRequest = null;
      return _RequestContext(response, previousCookie, target);
    } on LightIsleApiException {
      pendingRequest?.abort();
      rethrow;
    } on TimeoutException {
      pendingRequest?.abort();
      throw _networkTimeout();
    } on TlsException {
      pendingRequest?.abort();
      throw _untrustedCertificate();
    } on SocketException {
      pendingRequest?.abort();
      throw _networkError();
    } on HttpException {
      pendingRequest?.abort();
      throw _networkError();
    } on Object {
      pendingRequest?.abort();
      throw _networkError();
    }
  }

  Future<ConnectionTask<Socket>> _pinnedConnectionFactory(
    Uri target,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null ||
        proxyPort != null ||
        target.scheme != 'https' ||
        !_sameOrigin(target, _baseUri)) {
      throw _certificateMismatch();
    }
    final task = await SecureSocket.startConnect(
      target.host,
      target.port,
      context: securityContext,
      onBadCertificate: (certificate) =>
          _isPinnedCertificate(certificate, target.host, target.port),
      supportedProtocols: const <String>['http/1.1'],
    );
    final socket = task.socket
        .then<Socket>((secureSocket) {
          final certificate = secureSocket.peerCertificate;
          if (certificate == null ||
              !_isPinnedCertificate(certificate, target.host, target.port)) {
            secureSocket.destroy();
            throw _certificateMismatch();
          }
          return secureSocket;
        })
        .catchError((Object error) {
          if (error is LightIsleApiException) throw error;
          if (error is TlsException) throw _certificateMismatch();
          throw error;
        });
    return ConnectionTask.fromSocket<Socket>(socket, task.cancel);
  }

  bool _isPinnedCertificate(
    X509Certificate certificate,
    String host,
    int port,
  ) {
    final pin = _certificateFingerprint;
    if (pin == null ||
        host.toLowerCase() != _baseUri.host.toLowerCase() ||
        port != _baseUri.port) {
      return false;
    }
    final now = DateTime.now();
    if (now.isBefore(certificate.startValidity) ||
        !now.isBefore(certificate.endValidity)) {
      return false;
    }
    return sha256.convert(certificate.der).toString() == pin;
  }

  Future<Uint8List> _readWithCookieCapture(
    _RequestContext context,
    int maxBytes,
  ) async {
    final response = context.response;
    try {
      final limit = _isSuccess(response.statusCode)
          ? maxBytes
          : (maxBytes < _maxErrorBytes ? maxBytes : _maxErrorBytes);
      return await _readResponse(response, limit);
    } finally {
      _captureCookies(response, context.requestUri);
    }
  }

  Future<Uint8List> _readResponse(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (response.contentLength > maxBytes) throw _responseTooLarge();
    final builder = BytesBuilder(copy: false);
    var received = 0;
    try {
      await for (final chunk in response.timeout(_requestTimeout)) {
        if (chunk.length > maxBytes - received) throw _responseTooLarge();
        received += chunk.length;
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on LightIsleApiException {
      rethrow;
    } on TimeoutException {
      throw _networkTimeout();
    } on SocketException {
      throw _networkError();
    } on HttpException {
      throw _networkError();
    } on Object {
      throw _networkError();
    }
  }

  void _throwForBadStatus(_RequestContext context, Uint8List body) {
    final response = context.response;
    if (_isSuccess(response.statusCode)) return;

    final status = response.statusCode;
    final rawCode = status >= 300 && status < 400
        ? 'redirect_not_allowed'
        : _responseErrorCode(body);
    final code = _safeErrorCode(rawCode, context.previousCookie);
    final message = _errorMessages[code] ?? _genericStatusMessage(status);

    if (status == HttpStatus.unauthorized &&
        code == 'authentication_required') {
      _sessionCookie = null;
      try {
        onUnauthorized?.call();
      } on Object {
        // An app callback must not replace the server's authentication error.
      }
    }
    throw LightIsleApiException(
      code: code,
      statusCode: status,
      message: message,
    );
  }

  String _safeErrorCode(String code, String? previousCookie) {
    final value = code.trim();
    final currentCookie = _sessionCookie?.value;
    if (value.isEmpty ||
        value.contains(_sessionCookieName) ||
        (previousCookie != null &&
            previousCookie.isNotEmpty &&
            value.contains(previousCookie)) ||
        (currentCookie != null &&
            currentCookie.isNotEmpty &&
            value.contains(currentCookie))) {
      return 'server_error';
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$').hasMatch(value)) {
      return 'server_error';
    }
    return value;
  }

  String _responseErrorCode(Uint8List body) {
    if (body.isEmpty) return 'http_error';
    try {
      final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on Object {
      // The status remains actionable even when an intermediary returned
      // plain text or malformed JSON.
    }
    return 'http_error';
  }

  Map<String, dynamic> _decodeJsonObject(Uint8List body) {
    if (body.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      throw const LightIsleApiException(
        code: 'invalid_response',
        message: '服务器返回的数据无法识别，请稍后重试。',
      );
    }
    throw const LightIsleApiException(
      code: 'invalid_response',
      message: '服务器返回的数据格式不正确，请稍后重试。',
    );
  }

  void _captureCookies(HttpClientResponse response, Uri responseUri) {
    if (!_sameOrigin(responseUri, _baseUri)) return;
    final setCookieHeaders =
        response.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
    for (final value in setCookieHeaders) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        if (cookie.name != _sessionCookieName) continue;

        final domain = cookie.domain
            ?.replaceFirst(RegExp(r'^\.'), '')
            .toLowerCase();
        if ((domain != null && domain != _baseUri.host.toLowerCase()) ||
            (cookie.path != null && cookie.path != '/') ||
            !cookie.httpOnly ||
            (cookie.secure && _baseUri.scheme != 'https')) {
          continue;
        }

        final now = DateTime.now();
        if (cookie.value.isEmpty ||
            (cookie.maxAge != null && cookie.maxAge! <= 0) ||
            (cookie.maxAge == null &&
                cookie.expires != null &&
                !cookie.expires!.isAfter(now))) {
          _sessionCookie = null;
          continue;
        }
        if (!RegExp(r'^[A-Za-z0-9_-]{30,128}$').hasMatch(cookie.value)) {
          continue;
        }

        final expiry = cookie.maxAge == null
            ? cookie.expires
            : now.add(Duration(seconds: cookie.maxAge!));
        _sessionCookie = _SessionCookie(cookie.value, expiry);
      } on Object {
        // Ignore malformed or unrelated cookies; they cannot authenticate an
        // API request and should not affect the current valid session.
      }
    }
  }

  _SessionCookie? get _liveSessionCookie {
    final cookie = _sessionCookie;
    if (cookie != null &&
        cookie.expiresAt != null &&
        !cookie.expiresAt!.isAfter(DateTime.now())) {
      _sessionCookie = null;
      return null;
    }
    return cookie;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const LightIsleApiException(
        code: 'client_closed',
        message: '服务器连接已关闭，请重新打开应用后重试。',
      );
    }
  }

  LightIsleApiException _networkTimeout() => const LightIsleApiException(
    code: 'network_timeout',
    message: '连接服务器超时，请检查网络后重试。',
  );

  LightIsleApiException _networkError() => const LightIsleApiException(
    code: 'network_error',
    message: '无法连接服务器，请检查地址和网络后重试。',
  );

  LightIsleApiException _certificateMismatch() => const LightIsleApiException(
    code: 'certificate_mismatch',
    message: '服务器证书指纹已变化或无效，请核对服务器证书后重试。',
  );

  LightIsleApiException _untrustedCertificate() => const LightIsleApiException(
    code: 'certificate_untrusted',
    message: '无法验证服务器证书。连接 Mac 自签名 HTTPS 时，请在连接安全设置中填入并核对管理端显示的 SHA-256 指纹。',
  );

  LightIsleApiException _responseTooLarge() => const LightIsleApiException(
    code: 'response_too_large',
    message: '服务器返回的数据过大，无法安全读取。',
  );

  String _genericStatusMessage(int status) {
    if (status == HttpStatus.notFound) return '请求的内容不存在或已被移除。';
    if (status == HttpStatus.forbidden) return '服务器拒绝了此操作，请检查账户权限。';
    if (status == HttpStatus.tooManyRequests) return '请求过于频繁，请稍后再试。';
    if (status >= 500) return '服务器暂时无法完成请求，请稍后重试。';
    return '请求未能完成，请稍后重试。';
  }

  static bool _isSuccess(int statusCode) =>
      statusCode >= 200 && statusCode < 300;

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  Future<bool> _destinationExists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  LightIsleApiException _destinationAlreadyExists() =>
      const LightIsleApiException(
        code: 'destination_exists',
        message: '目标位置已存在文件，请选择其他位置。',
      );

  static Uri _validatedBaseUri(String serverUrl, bool allowInsecureHttp) {
    final parsed = Uri.tryParse(serverUrl.trim());
    if (parsed == null ||
        !parsed.isAbsolute ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        (parsed.path.isNotEmpty && parsed.path != '/')) {
      throw ArgumentError('服务器地址无效，请检查协议、主机名和端口。');
    }
    if (parsed.scheme == 'http' && !_isLoopbackHost(parsed.host)) {
      if (!allowInsecureHttp || !_isPrivateHost(parsed.host)) {
        throw ArgumentError(
          '此服务器地址不允许使用未加密连接。请使用 HTTPS；连接局域网服务器时，可在设置中明确允许未加密连接。',
        );
      }
    }
    return Uri(
      scheme: parsed.scheme.toLowerCase(),
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
    );
  }

  static String? _normalizeCertificateFingerprint(String? value) {
    if (value == null) return null;
    final normalized = value.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
      throw ArgumentError('服务器证书指纹格式无效，请检查后重试。');
    }
    return normalized;
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    final address = InternetAddress.tryParse(normalized);
    return address?.isLoopback ?? false;
  }

  static bool _isPrivateHost(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final first = bytes[0];
      final second = bytes[1];
      return first == 10 ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168) ||
          (first == 169 && second == 254);
    }
    if (address.type == InternetAddressType.IPv6) {
      final first = bytes[0];
      final second = bytes[1];
      return (first & 0xfe) == 0xfc ||
          (first == 0xfe && (second & 0xc0) == 0x80);
    }
    return false;
  }

  static Stream<List<int>> _exactLengthStream(
    Stream<List<int>> source,
    int expected,
  ) async* {
    var sent = 0;
    await for (final chunk in source) {
      if (chunk.length > expected - sent) {
        throw const LightIsleApiException(
          code: 'upload_length_mismatch',
          message: '上传数据长度与声明不一致，请重试。',
        );
      }
      sent += chunk.length;
      yield chunk;
    }
    if (sent != expected) {
      throw const LightIsleApiException(
        code: 'upload_length_mismatch',
        message: '上传数据长度与声明不一致，请重试。',
      );
    }
  }
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
