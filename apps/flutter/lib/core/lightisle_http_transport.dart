part of 'lightisle_api.dart';

// HTTP transport, certificate checks and response/session handling.
extension _LightIsleHttpTransport on LightIsleApi {
  Future<_RequestContext> _openRequest(
    String method,
    Uri target, {
    String accept = 'application/json',
    String? contentType,
    int? bodyLength,
    Map<String, String>? extraHeaders,
    FutureOr<void> Function(HttpClientRequest request)? writeBody,
    Duration? requestTimeout,
  }) async {
    _ensureOpen();
    final timeout = requestTimeout ?? _requestTimeout;
    final previousCookie = _liveSessionCookie?.value;
    HttpClientRequest? pendingRequest;
    try {
      final request = await _client.openUrl(method, target).timeout(timeout);
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
          '${LightIsleApi._sessionCookieName}=${cookie.value}',
        );
      }
      if (method != 'GET' && method != 'HEAD') {
        request.headers.set('X-LightIsle-Request', '1');
      }
      if (target.pathSegments.length >= 4 &&
          target.pathSegments[0] == 'api' &&
          target.pathSegments[1] == 'v2' &&
          target.pathSegments[2] == 'roots') {
        final frozenGeneration = target.queryParameters['rootGeneration'];
        if (frozenGeneration != null) {
          final root = _selectedRoot;
          if (root == null ||
              target.pathSegments[3] != root.id ||
              frozenGeneration != '${root.generation}') {
            throw const LightIsleApiException(
              code: 'root_generation_changed',
              message: '共享目录已切换，请重新打开当前操作。',
            );
          }
          request.headers.set('X-LightIsle-Root-Generation', frozenGeneration);
        }
      }
      extraHeaders?.forEach(request.headers.set);
      if (bodyLength != null) request.contentLength = bodyLength;
      if (writeBody != null) {
        await Future<void>.sync(() => writeBody(request)).timeout(timeout);
      }
      final response = await request.close().timeout(timeout);
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
        !LightIsleApi._sameOrigin(target, _baseUri)) {
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
      final limit = LightIsleApi._isSuccess(response.statusCode)
          ? maxBytes
          : (maxBytes < LightIsleApi._maxErrorBytes
                ? maxBytes
                : LightIsleApi._maxErrorBytes);
      return await _readResponse(response, limit);
    } finally {
      _captureCookies(response, context.requestUri);
    }
  }

  Future<Uint8List> _readResponse(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (response.contentLength > maxBytes) {
      // An unlistened response can keep its connection and unread body alive.
      // Cancel instead of draining a potentially arbitrarily large body.
      await response.listen(null).cancel();
      throw _responseTooLarge();
    }
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
    if (LightIsleApi._isSuccess(response.statusCode)) return;

    final status = response.statusCode;
    final rawCode = status >= 300 && status < 400
        ? 'redirect_not_allowed'
        : _responseErrorCode(body);
    final code = _safeErrorCode(rawCode, context.previousCookie);
    final message =
        LightIsleApi._errorMessages[code] ?? _genericStatusMessage(status);

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
        value.contains(LightIsleApi._sessionCookieName) ||
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
    if (!LightIsleApi._sameOrigin(responseUri, _baseUri)) return;
    final setCookieHeaders =
        response.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
    for (final value in setCookieHeaders) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        if (cookie.name != LightIsleApi._sessionCookieName) continue;

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
}
