part of 'media_pages_test.dart';

final _videoPlayerTestPlatform = _VideoPlayerTestPlatform();

class _MediaApi extends LightIsleApi {
  _MediaApi() : super('http://127.0.0.1');

  bool failProgressSaves = false;
  bool failMediaBytes = false;
  int progressSaveCount = 0;
  final List<Map<String, Object?>> mediaByteRequests = [];
  final List<Map<String, Object?>> sendRequests = [];
  final List<Map<String, String>> photoQueries = [];
  final List<Map<String, String>> cinemaQueries = [];
  final List<Map<String, Object?>> privateAlbumRows = [];
  final List<Map<String, Object?>> sharedAlbumRows = [];
  final List<Map<String, Object?>> timelineRows = [];
  final List<Map<String, dynamic>> tmdbResults = [];
  Map<String, dynamic>? cinemaDetail;
  final Completer<Map<String, dynamic>> firstPhotos = Completer();
  final Completer<Map<String, dynamic>> firstCinema = Completer();
  int _photoCalls = 0;
  int _cinemaCalls = 0;

  @override
  Map<String, String> get mediaHeaders => const {};

  @override
  Uri uri(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    path: path,
    queryParameters: query,
  );

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path == '/api/v2/photos/status') {
      return Future.value(<String, dynamic>{
        'status': <String, dynamic>{'running': false},
      });
    }
    if (path == '/api/v2/photos/albums') {
      return Future.value(<String, dynamic>{'albums': sharedAlbumRows});
    }
    if (path == '/api/v2/photos/private-albums') {
      return Future.value(<String, dynamic>{'albums': privateAlbumRows});
    }
    if (path == '/api/v2/photos/timeline') {
      return Future.value(<String, dynamic>{'months': timelineRows});
    }
    if (path == '/api/v2/photos') {
      _photoCalls++;
      photoQueries.add(Map<String, String>.from(query ?? const {}));
      if (_photoCalls == 1) return firstPhotos.future;
      return Future.value(<String, dynamic>{
        'assets': <Object>[],
        'nextCursor': 0,
      });
    }
    if (path == '/api/v2/cinema/status') {
      return Future.value(<String, dynamic>{
        'status': <String, dynamic>{'running': false},
      });
    }
    if (path == '/api/v2/cinema') {
      if (query != null && query['dir'] != null) {
        if (firstCinema.isCompleted) return firstCinema.future;
        return Future.value(<String, dynamic>{
          'films': <Object>[],
          'nextCursor': 0,
        });
      }
      _cinemaCalls++;
      cinemaQueries.add(Map<String, String>.from(query ?? const {}));
      if (firstCinema.isCompleted) return firstCinema.future;
      if (_cinemaCalls == 1) return firstCinema.future;
      return Future.value(<String, dynamic>{
        'films': <Object>[],
        'nextCursor': 0,
      });
    }
    if (cinemaDetail != null &&
        path == '/api/v2/cinema/${cinemaDetail!['id']}') {
      return Future.value(Map<String, dynamic>.from(cinemaDetail!));
    }
    if (path == '/api/v2/cinema/62') {
      return Future.value(<String, dynamic>{
        'id': 62,
        'title': 'Card title opens the film',
        'path': 'Cinema/card-title.mp4',
        'kind': 'movie',
        'playable': true,
        'browserPlayback': 'verified-direct',
        'probeStatus': 'ready',
      });
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    sendRequests.add(<String, Object?>{
      'method': method,
      'path': path,
      'body': body,
    });
    if (path.endsWith('/progress')) {
      progressSaveCount++;
      if (failProgressSaves) {
        throw const LightIsleApiException(
          code: 'network_timeout',
          message: '连接服务器超时，请检查网络后重试。',
        );
      }
    }
    if (path.endsWith('/metadata/tmdb/search')) {
      return <String, dynamic>{'results': tmdbResults};
    }
    if (path.endsWith('/metadata/nfo') && cinemaDetail != null) {
      cinemaDetail = <String, dynamic>{
        ...cinemaDetail!,
        'overview': 'Imported from local sidecar.',
        'metadataSource': 'nfo:manual.nfo',
      };
      return <String, dynamic>{};
    }
    if (path.endsWith('/metadata/tmdb/match') && cinemaDetail != null) {
      final selected = tmdbResults.first;
      cinemaDetail = <String, dynamic>{
        ...cinemaDetail!,
        'overview': selected['overview'],
        'rating': selected['rating'],
        'metadataSource': 'tmdb:movie:${selected['id']}',
      };
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    mediaByteRequests.add(<String, Object?>{
      'path': path,
      'query': query,
      'maxBytes': maxBytes,
    });
    if (failMediaBytes) {
      throw const LightIsleApiException(
        code: 'network_error',
        message: '无法连接服务器，请检查地址和网络后重试。',
      );
    }
    return Uint8List(0);
  }
}

class _DelayedHlsApi extends _MediaApi {
  final relay = Completer<Uri>();
  bool resolvingRelay = false;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path.endsWith('/hls/session')) {
      return Future.value(<String, dynamic>{
        'sessionId': 'test-session',
        'ready': true,
      });
    }
    return super.get(path, query: query);
  }

  @override
  Future<Uri> mediaHlsUri(String path) {
    resolvingRelay = true;
    return relay.future;
  }
}

Map<String, Object> _photoAssetJson(
  int id,
  String name,
  DateTime localTaken, {
  String type = 'photo',
}) => <String, Object>{
  'id': id,
  'path': 'Trips/$name',
  'name': name,
  'type': type,
  'size': 4096,
  'takenAt': localTaken.millisecondsSinceEpoch ~/ 1000,
  'favorite': false,
  'canWrite': false,
};

class _VideoPlayerTestPlatform extends VideoPlayerPlatform {
  final List<String> calls = [];
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _nextId = 1;
  Size videoSize = const Size(640, 360);

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) => createWithOptions(
    VideoCreationOptions(
      dataSource: dataSource,
      viewType: VideoViewType.textureView,
    ),
  );

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final events = StreamController<VideoEvent>.broadcast();
    _events[id] = events;
    Timer.run(() {
      if (!events.isClosed) {
        events.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(minutes: 1),
            size: videoSize,
          ),
        );
      }
    });
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => Texture(textureId: playerId);
}
