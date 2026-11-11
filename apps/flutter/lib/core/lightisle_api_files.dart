part of 'lightisle_api.dart';

// File verification, resumable upload/download, network speed tests, and origin validation.
extension _LightIsleApiFiles on LightIsleApi {
  Future<Uri> _createPublicFileShareImpl({
    required String path,
    required int hours,
    String? password,
    int? maxDownloads,
  }) async {
    if (path.trim().isEmpty) {
      throw ArgumentError('分享路径不能为空。');
    }
    if (hours <= 0) {
      throw ArgumentError('分享有效期必须大于零。');
    }
    final result = await sendRoot(
      'POST',
      '/api/v2/file-shares',
      body: <String, Object?>{
        'path': path,
        'hours': hours,
        if (password != null && password.trim().isNotEmpty)
          'password': password.trim(),
        if (maxDownloads != null && maxDownloads > 0)
          'maxDownloads': maxDownloads,
      },
    );
    final share = result['share'] is Map
        ? Map<String, dynamic>.from(result['share'] as Map)
        : result;
    final token = (result['token'] ?? share['token'] ?? '').toString().trim();
    if (token.isEmpty) {
      throw const FormatException('服务端没有返回分享链接，请刷新分享列表确认创建状态。');
    }
    return publicFileShareUri(token);
  }

  Future<bool> _remoteFileMatchesSHA256Impl(
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
      result = await get('/api/v2/files/sha256', query: {'path': path});
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
        result = await get('/api/v2/files/sha256', query: query);
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

  Future<bool> _remoteFileHasSizeImpl(String path, int expectedSize) async {
    if (expectedSize < 0) throw ArgumentError('文件大小无效。');
    final context = await _openRequest(
      'HEAD',
      uri('/api/v2/files/content', <String, String>{'path': path}),
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

  Future<int> _networkTestDownloadImpl(
    int length, {
    void Function(int transferred, int total)? onProgress,
  }) async {
    if (length < 1 || length > (16 << 20)) {
      throw ArgumentError('测速下载量须在 1 B 至 16 MiB 之间。');
    }
    final target = uri('/api/v2/network-test/download', {'bytes': '$length'});
    final context = await _openRequest('GET', target, accept: '*/*');
    if (!LightIsleApi._isSuccess(context.response.statusCode)) {
      final error = await _readWithCookieCapture(
        context,
        LightIsleApi._maxErrorBytes,
      );
      _throwForBadStatus(context, error);
    }
    _captureCookies(context.response, target);
    var received = 0;
    onProgress?.call(0, length);
    await for (final chunk in context.response.timeout(_requestTimeout)) {
      received += chunk.length;
      if (received > length) {
        throw const LightIsleApiException(
          code: 'network_test_incomplete',
          message: '测速收到超出预期的数据，请检查代理或服务器。',
        );
      }
      onProgress?.call(received, length);
    }
    if (received != length) {
      throw const LightIsleApiException(
        code: 'network_test_incomplete',
        message: '测速数据不完整，请检查连接稳定性。',
      );
    }
    return received;
  }

  Future<int> _networkTestUploadImpl(
    int length, {
    void Function(int transferred, int total)? onProgress,
  }) async {
    if (length < 1 || length > (16 << 20)) {
      throw ArgumentError('测速上传量须在 1 B 至 16 MiB 之间。');
    }
    final payload = Uint8List(64 << 10);
    var value = 0x517cc1b7;
    for (var i = 0; i < payload.length; i++) {
      value = (value * 1664525 + 1013904223) & 0xffffffff;
      payload[i] = value >> 24;
    }
    final context = await _openRequest(
      'POST',
      uri('/api/v2/network-test/upload'),
      contentType: 'application/octet-stream',
      bodyLength: length,
      requestTimeout: const Duration(seconds: 90),
      extraHeaders: const <String, String>{'Cache-Control': 'no-transform'},
      writeBody: (request) async {
        onProgress?.call(0, length);
        var sent = 0;
        // Let HttpClient's addStream apply transport backpressure. Pushing
        // 8-16 MiB synchronously with request.add() would fill buffers and
        // freeze the UI on slower Wi-Fi/remote tunnels.
        Stream<List<int>> chunks() async* {
          while (sent < length) {
            final part = min(payload.length, length - sent);
            yield part == payload.length
                ? payload
                : Uint8List.sublistView(payload, 0, part);
            sent += part;
            onProgress?.call(sent, length);
          }
        }

        await request.addStream(chunks());
      },
    );
    final data = await _readWithCookieCapture(
      context,
      LightIsleApi._maxJsonBytes,
    );
    _throwForBadStatus(context, data);
    final result = _decodeJsonObject(data);
    if (result['receivedBytes'] != length) {
      throw const LightIsleApiException(
        code: 'network_test_incomplete',
        message: '测速上传不完整，请检查连接稳定性。',
      );
    }
    return length;
  }

  Future<void> _downloadImpl(
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
    if (!LightIsleApi._isSuccess(response.statusCode)) {
      final body = await _readWithCookieCapture(
        context,
        LightIsleApi._maxErrorBytes,
      );
      _throwForBadStatus(context, body);
    }
    _captureCookies(response, targetUri);

    final total = response.contentLength;
    final parent = target.parent;
    final sequence = ++LightIsleApi._downloadSequence;
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

  Future<Map<String, dynamic>> _uploadChunkImpl(
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
    if (length < 0 || length > LightIsleApi._maxUploadChunkBytes) {
      throw ArgumentError('上传数据块必须介于 0 到 8 MiB。');
    }
    if (offset < 0) {
      throw ArgumentError('上传偏移量不能小于零。');
    }

    final encodedId = Uri.encodeComponent(id);
    final context = await _openRequest(
      'PATCH',
      uri('/api/v2/uploads/$encodedId'),
      accept: 'application/json',
      contentType: 'application/octet-stream',
      bodyLength: length,
      extraHeaders: <String, String>{'X-Upload-Offset': '$offset'},
      writeBody: (request) async {
        await request.addStream(_exactLengthStream(data, length));
      },
    );
    final bytes = await _readWithCookieCapture(
      context,
      LightIsleApi._maxJsonBytes,
    );
    _throwForBadStatus(context, bytes);
    return _decodeJsonObject(bytes);
  }

  Future<bool> _destinationExists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  LightIsleApiException _destinationAlreadyExists() =>
      const LightIsleApiException(
        code: 'destination_exists',
        message: '目标位置已存在文件，请选择其他位置。',
      );
}

Uri _validatedLightIsleBaseUri(String serverUrl, bool allowInsecureHttp) {
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

String? _normalizeLightIsleCertificateFingerprint(String? value) {
  if (value == null) return null;
  final normalized = value.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
    throw ArgumentError('服务器证书指纹格式无效，请检查后重试。');
  }
  return normalized;
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
    return true;
  }
  final address = InternetAddress.tryParse(normalized);
  return address?.isLoopback ?? false;
}

bool _isPrivateHost(String host) {
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
    return (first & 0xfe) == 0xfc || (first == 0xfe && (second & 0xc0) == 0x80);
  }
  return false;
}

Stream<List<int>> _exactLengthStream(
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
