part of 'mobile_photo_backup_page.dart';

class _NativeStreamInspection {
  const _NativeStreamInspection({
    required this.size,
    required this.modified,
    required this.generation,
    required this.digest,
    required this.chunkDigests,
  });

  final int size;
  final int modified;
  final int generation;
  final String digest;
  final List<String> chunkDigests;
}

extension _MobilePhotoBackupTransfer on _MobilePhotoBackupState {
  Future<void> _cancelPrepare(String requestId) async {
    try {
      await _photosChannel.invokeMethod<bool>('cancelPrepare', {
        'requestId': requestId,
      });
    } catch (_) {
      // Native prepare/stream cleanup owns cancellation races.
    }
  }

  void _cancelActivePrepare() {
    final requestId = _activePrepareRequestId;
    if (requestId == null || _cancelledPrepareRequestId == requestId) return;
    _cancelledPrepareRequestId = requestId;
    unawaited(_cancelPrepare(requestId));
  }

  String _newPrepareRequestId() =>
      '$_deviceId-${DateTime.now().microsecondsSinceEpoch}-${_prepareSequence++}';

  void _ensureActive() {
    if (_cancel || !mounted || !_isForeground) {
      throw const _PausePhotoBackup();
    }
    final root = _boundRoot;
    if (root == null ||
        !root.online ||
        !_personalDestination ||
        widget.api.selectedRoot?.identity != root.identity) {
      throw const _PausePhotoBackup();
    }
  }

  Future<PhotoHashResult> _hashPreparedPhoto(File source, int expectedSize) =>
      hashBackupPhoto(source, expectedSize, checkActive: _ensureActive);

  Future<bool> _permission({
    bool checkForegroundRun = false,
    bool? includeVideos,
  }) async {
    final videos = includeVideos ?? _includeVideos;
    final granted = await _photosChannel.invokeMethod<bool>('permission', {
      'includeVideos': videos,
    });
    if (checkForegroundRun) _ensureActive();
    if (granted == true) {
      return true;
    }
    final requested = await _photosChannel.invokeMethod<bool>(
      'requestPermission',
      {'includeVideos': videos},
    );
    if (checkForegroundRun) _ensureActive();
    return requested == true;
  }

  String _extension(String name) {
    final lower = name.toLowerCase();
    final index = lower.lastIndexOf('.');
    final ext = index >= 0 ? lower.substring(index + 1) : '';
    return {
          'jpg',
          'jpeg',
          'png',
          'heic',
          'heif',
          'webp',
          'avif',
          'gif',
          'tiff',
          'bmp',
          'mp4',
          'mov',
          'm4v',
          '3gp',
          'webm',
          'mkv',
          'avi',
          'dng',
          'cr2',
          'cr3',
          'nef',
          'arw',
          'raf',
          'rw2',
          'orf',
          'pef',
        }.contains(ext)
        ? ext
        : 'jpg';
  }

  Future<void> _ensureFolder(String path) async {
    _ensureActive();
    try {
      await widget.api.get(
        _photoApi('files'),
        query: _photoQuery({'path': path}),
      );
      _ensureActive();
      return;
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 403) rethrow;
      _ensureActive();
    }
    _ensureActive();
    try {
      await widget.api.send(
        'POST',
        _photoApi('files/folders'),
        body: {'path': path},
        query: _photoQuery(),
      );
      _ensureActive();
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 409) rethrow;
      _ensureActive();
    }
  }

  Future<Map<String, dynamic>?> _existingUpload(
    String key,
    int size,
    String destination,
  ) async {
    _ensureActive();
    final id = _prefs?.getString(key);
    if (id == null || id.isEmpty) return null;
    try {
      final state = await widget.api.get(
        _photoApi('uploads/${Uri.encodeComponent(id)}'),
        query: _photoQuery(),
      );
      _ensureActive();
      final offset = (state['offset'] as num?)?.toInt() ?? -1;
      if (state['path'] == destination &&
          state['size'] == size &&
          offset >= 0 &&
          offset <= size) {
        return state;
      }
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404) rethrow;
      _ensureActive();
    }
    _ensureActive();
    await _prefs?.remove(key);
    _ensureActive();
    return null;
  }

  Future<_NativeStreamInspection> _inspectAndroidStreamAsset(String id) async {
    _ensureActive();
    final requestId = _newPrepareRequestId();
    _activePrepareRequestId = requestId;
    _cancelledPrepareRequestId = null;
    try {
      final inspected = await _photosChannel.invokeMapMethod<String, dynamic>(
        'inspectAndHash',
        {'id': id, 'requestId': requestId, 'includeVideos': _includeVideos},
      );
      _ensureActive();
      final size = (inspected?['size'] as num?)?.toInt() ?? -1;
      final modified = (inspected?['modified'] as num?)?.toInt() ?? -1;
      final generation = (inspected?['generation'] as num?)?.toInt() ?? 0;
      final digest = inspected?['sha256']?.toString() ?? '';
      final rawChunks = inspected?['chunkDigests'];
      final chunkDigests = rawChunks is List
          ? rawChunks.map((e) => e.toString()).toList(growable: false)
          : const <String>[];
      if (size <= 0 ||
          size > _maxPhotoBackupBytes ||
          modified < 0 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw PlatformException(code: 'photo_source_changed');
      }
      return _NativeStreamInspection(
        size: size,
        modified: modified,
        generation: generation,
        digest: digest,
        chunkDigests: chunkDigests,
      );
    } finally {
      if (_activePrepareRequestId == requestId) {
        _activePrepareRequestId = null;
      }
      if (_cancelledPrepareRequestId == requestId) {
        _cancelledPrepareRequestId = null;
      }
    }
  }

  Future<Uint8List> _readAndroidStreamChunk({
    required String id,
    required int offset,
    required int length,
    required _NativeStreamInspection inspection,
  }) async {
    _ensureActive();
    final requestId = _newPrepareRequestId();
    _activePrepareRequestId = requestId;
    _cancelledPrepareRequestId = null;
    try {
      final bytes = await _photosChannel.invokeMethod<Uint8List>('readChunk', {
        'id': id,
        'requestId': requestId,
        'includeVideos': _includeVideos,
        'offset': offset,
        'length': length,
        'expectedSize': inspection.size,
        'expectedModified': inspection.modified,
        'expectedGeneration': inspection.generation,
      });
      _ensureActive();
      if (bytes == null || bytes.length != length) {
        throw PlatformException(code: 'photo_source_changed');
      }
      return bytes;
    } finally {
      if (_activePrepareRequestId == requestId) {
        _activePrepareRequestId = null;
      }
      if (_cancelledPrepareRequestId == requestId) {
        _cancelledPrepareRequestId = null;
      }
    }
  }

  Future<void> _uploadFromChunkProvider({
    required int size,
    required String destination,
    required String key,
    required String digest,
    required List<String> chunkSHA256s,
    required Future<Stream<List<int>>> Function(int offset, int length)
    openChunk,
  }) async {
    _ensureActive();
    var state = await _existingUpload(key, size, destination);
    _ensureActive();
    if (state == null) {
      _ensureActive();
      state = await widget.api.send(
        'POST',
        _photoApi('uploads'),
        body: {'path': destination, 'size': size},
        query: _photoQuery(),
      );
    }
    final id = state['id']?.toString() ?? '';
    if (id.isEmpty || state['path'] != destination || state['size'] != size) {
      throw StateError('服务端上传会话与备份照片不一致。');
    }
    await _prefs?.setString(key, id);
    _ensureActive();
    var offset = (state['offset'] as num?)?.toInt() ?? -1;
    if (offset < 0 || offset > size) throw StateError('无效的续传偏移量。');
    while (offset < size) {
      _ensureActive();
      if (_wifiOnly) {
        final isWifi = await _photosChannel.invokeMethod<bool>('isWifi');
        _ensureActive();
        if (isWifi != true) throw StateError('Wi-Fi 已断开，当前上传已暂停。');
      }
      final length = min(4 * 1024 * 1024, size - offset);
      final chunkStream = await openChunk(offset, length);
      _ensureActive();
      try {
        state = await widget.api.uploadChunk(id, chunkStream, length, offset);
        _ensureActive();
      } catch (_) {
        _ensureActive();
        final latest = await widget.api.get(
          _photoApi('uploads/${Uri.encodeComponent(id)}'),
          query: _photoQuery(),
        );
        _ensureActive();
        final next = (latest['offset'] as num?)?.toInt() ?? -1;
        if (latest['path'] != destination ||
            latest['size'] != size ||
            next <= offset ||
            next > size) {
          rethrow;
        }
        state = latest;
      }
      final next = (state['offset'] as num?)?.toInt() ?? -1;
      if (next <= offset || next > size) throw StateError('上传进度未前进，备份已暂停。');
      offset = next;
    }
    _ensureActive();
    await widget.api.send(
      'POST',
      _photoApi('uploads/${Uri.encodeComponent(id)}/complete'),
      query: _photoQuery(),
    );
    _ensureActive();
    final matches = await widget.api.remoteFileMatchesSHA256(
      destination,
      size,
      digest,
      chunkSHA256s: chunkSHA256s,
      checkActive: _ensureActive,
    );
    _ensureActive();
    if (!matches) {
      throw StateError('NAS 原片 SHA-256 与手机不一致，不能标记备份成功。');
    }
    await _prefs?.remove(key);
    _ensureActive();
  }

  Future<void> _upload(
    File source,
    int size,
    String destination,
    String key,
    String digest,
    List<String> chunkSHA256s,
  ) => _uploadFromChunkProvider(
    size: size,
    destination: destination,
    key: key,
    digest: digest,
    chunkSHA256s: chunkSHA256s,
    openChunk: (offset, length) async =>
        source.openRead(offset, offset + length),
  );
}
