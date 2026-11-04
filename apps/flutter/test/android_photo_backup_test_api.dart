part of 'android_photo_backup_test.dart';

class _PhotoApi extends LightIsleApi {
  _PhotoApi() : super('http://127.0.0.1');
  @override
  Map<String, String> get mediaHeaders => const {
    HttpHeaders.cookieHeader:
        'lightisle_session=testsession_012345678901234567890123456789',
  };

  final Map<String, int> backed = {};
  final Map<String, String> digestByPath = {};
  Map<String, dynamic>? upload;
  var created = 0;
  var completed = 0;
  var loseCompletionOnce = false;
  var sizeProbeCalls = 0;
  var uploadChunkCalls = 0;
  Future<bool> Function(String, int, String)? remoteHashHandler;
  Future<bool> Function(String, int)? remoteSizeHandler;
  Future<Map<String, dynamic>> Function(String, Map<String, String>?)?
  uploadStateHandler;

  @override
  Future<bool> remoteFileHasSize(String path, int expectedSize) async {
    sizeProbeCalls++;
    final handler = remoteSizeHandler;
    if (handler != null) return handler(path, expectedSize);
    return backed[path] == expectedSize;
  }

  @override
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String digest, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) async {
    final handler = remoteHashHandler;
    if (handler != null) return handler(path, expectedSize, digest);
    return backed[path] == expectedSize && digestByPath[path] == digest;
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots/disk_photo/files/folders')
      return {'created': true};
    if (path == '/api/v2/roots/disk_photo/uploads') {
      created++;
      final info = body! as Map<String, dynamic>;
      upload = {
        'id': 'test-session-$created',
        'path': info['path'],
        'size': info['size'],
        'offset': 0,
      };
      return Map.from(upload!);
    }
    if (path.endsWith('/complete')) {
      completed++;
      backed[upload!['path'] as String] = upload!['size'] as int;
      final hash = sha256.convert([10, 20, 30, 40, 50, 60]).toString();
      digestByPath[upload!['path'] as String] = hash;
      if (loseCompletionOnce) {
        loseCompletionOnce = false;
        throw StateError('lost response after server commit');
      }
      return {'completed': true};
    }
    throw StateError('Unexpected write $method $path');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/me/storage') {
      return {
        'userId': 7,
        'locations': [
          {
            'category': 'photos',
            'rootID': 'disk_photo',
            'rootGeneration': 4,
            'relativePath': 'Users/u7/photos',
          },
        ],
      };
    }
    if (path == '/api/v2/roots') {
      return {
        'roots': [
          {'rootID': 'disk_photo', 'generation': 4, 'online': true},
        ],
      };
    }
    if (path == '/api/v2/roots/disk_photo/files') {
      return {'path': query?['path'], 'entries': []};
    }
    if (path.startsWith('/api/v2/roots/disk_photo/uploads/')) {
      final handler = uploadStateHandler;
      if (handler != null) return handler(path, query);
      if (upload != null) return Map.from(upload!);
    }
    throw StateError('Unexpected read $path');
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int offset,
  ) async {
    uploadChunkCalls++;
    if (upload == null || upload!['id'] != id || upload!['offset'] != offset) {
      throw StateError('bad upload resume');
    }
    var read = 0;
    await for (final block in data) {
      read += block.length;
    }
    if (read != length) throw StateError('chunk content length mismatch');
    upload!['offset'] = offset + read;
    return Map.from(upload!);
  }
}
