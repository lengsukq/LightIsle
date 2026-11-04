part of 'lightisle_api.dart';

// Keep player-specific handling together while the API owns session state.
extension _LightIsleMediaRelay on LightIsleApi {
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
      if (base == null || !LightIsleApi._sameOrigin(base, _baseUri)) {
        local.statusCode = HttpStatus.notFound;
        await _closeRelayResponse(local);
        return;
      }
      target = base
          .resolve(hlsMatch.group(2)!)
          .replace(
            queryParameters: base.queryParameters.isEmpty
                ? null
                : base.queryParameters,
          );
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
    if (target == null || !LightIsleApi._sameOrigin(target, _baseUri)) {
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
      if (!LightIsleApi._isSuccess(upstream.statusCode) &&
          upstream.statusCode != HttpStatus.requestedRangeNotSatisfiable) {
        final errorBody = await _readResponse(
          upstream,
          LightIsleApi._maxErrorBytes,
        );
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
          if (received > LightIsleApi._maxErrorBytes) {
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
}
