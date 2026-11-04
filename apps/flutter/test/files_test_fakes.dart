part of 'files_test.dart';

class _DelayedTextPreviewApi extends _FilesTestApi {
  final pending = Completer<Uint8List>();
  int previewCalls = 0;

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) {
    expect(path, '/api/v2/files/preview');
    expect(query, {'path': '计划说明.txt'});
    expect(maxBytes, 1 << 20);
    previewCalls++;
    return pending.future;
  }

  void completePreview() =>
      pending.complete(Uint8List.fromList([72, 101, 108, 108, 111]));
}

class _RecordedRequest {
  const _RecordedRequest(
    this.method,
    this.path,
    this.queryParameters, [
    this.body,
  ]);

  final String method;
  final String path;
  final Map<String, String> queryParameters;
  final Object? body;
}

class _FilesTestApi extends LightIsleApi {
  _FilesTestApi({this.writable = false})
    : super('http://127.0.0.1:1', httpClient: _NoopHttpClient());

  final bool writable;
  final List<_RecordedRequest> requests = [];
  Object? batchBody;
  final List<Map<String, Object?>> trash = [
    {
      'id': '0123456789abcdef0123456789abcdef',
      'name': '待清理.txt',
      'originalPath': 'Docs/待清理.txt',
      'deletedAt': '2026-10-20T12:00:00Z',
    },
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add(_RecordedRequest('GET', path, query ?? const {}));
    if (path == '/api/v2/files/root') return {'name': '共享盘'};
    if (path == '/api/v2/files/search') {
      return {
        'entries': [_entry('计划说明.txt', '计划说明.txt', 'file', 128)],
        'truncated': true,
        'canWrite': writable,
      };
    }
    if (path == '/api/v2/files/trash') return {'entries': trash};
    if (path == '/api/v2/files') {
      final directory = query?['path'] ?? '.';
      return {
        'path': directory,
        'entries': directory == '.'
            ? [
                _entry('资料夹', '资料夹', 'folder', 0),
                _entry('计划说明.txt', '计划说明.txt', 'file', 128),
              ]
            : <Map<String, Object?>>[],
        'nextCursor': '',
        'canWrite': writable,
      };
    }
    throw StateError('Unexpected API request: $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    requests.add(_RecordedRequest(method, path, query ?? const {}, body));
    if (method == 'POST' && path == '/api/v2/files/batch') {
      batchBody = body;
      final paths = (body as Map)['paths'] as List;
      return {
        'results': [
          for (final item in paths) {'path': item, 'success': true},
        ],
      };
    }
    if (method == 'DELETE' && path.startsWith('/api/v2/files/trash/')) {
      final id = path.split('/').last;
      trash.removeWhere((entry) => entry['id'] == id);
      return {'deleted': true};
    }
    if (method == 'POST' && path.endsWith('/restore')) {
      return {'restored': true};
    }
    return {};
  }

  Map<String, Object?> _entry(
    String name,
    String path,
    String type,
    int size,
  ) => {
    'name': name,
    'path': path,
    'type': type,
    'size': size,
    'modified': '2026-10-21T10:30:00Z',
    'canWrite': writable,
  };
}

class _DownloadTestApi extends LightIsleApi {
  _DownloadTestApi()
    : super('http://127.0.0.1:1', httpClient: _NoopHttpClient());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/files/root') return {'name': '共享盘'};
    if (path == '/api/v2/files') {
      return {
        'entries': [
          {
            'name': '说明.txt',
            'path': '说明.txt',
            'type': 'file',
            'size': 10,
            'canWrite': false,
          },
        ],
        'nextCursor': '',
        'canWrite': false,
      };
    }
    throw StateError('Unexpected API request: $path');
  }

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    File(destination).writeAsStringSync('test bytes');
    onProgress?.call(10, 10);
  }
}

class _FilesParityTestApi extends LightIsleApi {
  _FilesParityTestApi({
    this.withShare = false,
    this.withVideo = false,
    this.withImage = false,
  }) : super('http://127.0.0.1:1', httpClient: _NoopHttpClient());

  final bool withShare;
  final bool withVideo;
  final bool withImage;
  final List<_RecordedRequest> sent = [];
  final List<_RecordedRequest> downloads = [];
  final List<_RecordedRequest> mediaRequests = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/files/root') return {'name': '共享盘'};
    if (path == '/api/v2/files') {
      final entries = <Map<String, Object?>>[
        _entry('资料夹', '资料夹', 'folder'),
        _entry('说明.txt', '说明.txt', 'file'),
        if (withVideo) _entry('clip.mp4', 'clip.mp4', 'file'),
        if (withImage) _entry('photo.jpg', 'photo.jpg', 'file'),
      ];
      return {'entries': entries, 'nextCursor': '', 'canWrite': false};
    }
    if (path == '/api/v2/file-shares') {
      return {
        'shares': withShare
            ? [
                {
                  'id': 'share-id',
                  'path': 'Docs/说明.txt',
                  'createdAt': 1792756800,
                  'expiresAt': 1793361600,
                },
              ]
            : [],
      };
    }
    throw StateError('Unexpected API request: $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final request = _RecordedRequest(method, path, query ?? const {}, body);
    sent.add(request);
    if (method == 'POST' && path == '/api/v2/file-shares') {
      return {'token': 'demo-token', 'share': <String, Object?>{}};
    }
    return {'revoked': true};
  }

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    downloads.add(_RecordedRequest('GET', path, query ?? const {}));
    File(
      destination,
    ).writeAsStringSync(path.endsWith('/archive') ? 'zip bytes' : 'file bytes');
    onProgress?.call(10, 10);
  }

  @override
  Future<Uri> mediaUri(String path, {Map<String, String>? query}) async {
    mediaRequests.add(_RecordedRequest('GET', path, query ?? const {}));
    return Uri.parse('http://127.0.0.1:1/native-media');
  }

  Map<String, Object?> _entry(String name, String path, String type) => {
    'name': name,
    'path': path,
    'type': type,
    'size': 10,
    'modified': '2026-10-21T10:30:00Z',
    'canWrite': false,
  };
}

class _NoopHttpClient extends Fake implements HttpClient {
  @override
  void close({bool force = false}) {}
}
