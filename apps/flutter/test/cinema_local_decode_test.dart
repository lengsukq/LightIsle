import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_decode_preference.dart';
import 'package:lightisle/features/media/cinema_detail_dialog.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _NoFfmpegCinemaApi extends LightIsleApi {
  _NoFfmpegCinemaApi() : super('http://127.0.0.1');

  int hlsSessionCalls = 0;
  final List<Uri> streamUris = [];

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
  Future<Uri> mediaUri(String path, {Map<String, String>? query}) async {
    final resolved = uri(path, query);
    streamUris.add(resolved);
    return resolved;
  }

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path == '/api/v2/cinema/108') {
      return Future.value(<String, dynamic>{
        'id': 108,
        'title': '4K HEVC MKV Film',
        'path': 'Cinema/hevc_movie.mkv',
        'kind': 'movie',
        'playable': false,
        'browserPlayback': 'download-only',
        'probeStatus': 'ready',
        'container': 'mkv',
        'videoCodec': 'hevc',
      });
    }
    if (path == '/api/v2/cinema/108/hls/session') {
      hlsSessionCalls++;
      return Future.error(
        const LightIsleApiException(
          code: 'transcode_unavailable',
          statusCode: 503,
          message: 'transcode_unavailable',
        ),
      );
    }
    if (path == '/api/v2/cinema') {
      return Future.value(<String, dynamic>{
        'films': <Object>[],
        'nextCursor': 0,
      });
    }
    throw StateError('Unexpected GET $path');
  }
}

class _FakeVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final List<String> dataSources = [];
  int _nextId = 1;

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
    if (options.dataSource.uri != null) {
      dataSources.add(options.dataSource.uri!);
    }
    final id = _nextId++;
    final events = StreamController<VideoEvent>.broadcast();
    _events[id] = events;
    Timer.run(() {
      if (!events.isClosed) {
        events.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(minutes: 2),
            size: const Size(1920, 1080),
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
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => Texture(textureId: playerId);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CinemaDecodePreference.preferLocalDecode.value = false;
  });

  testWidgets(
    'cinema automatically falls back to direct local decode when FFmpeg is absent',
    (tester) async {
      final api = _NoFfmpegCinemaApi();
      final platform = _FakeVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        api.close();
      });

      final film = CinemaFilm.fromJson(<String, dynamic>{
        'id': 108,
        'title': '4K HEVC MKV Film',
        'path': 'Cinema/hevc_movie.mkv',
        'kind': 'movie',
        'playable': false,
        'browserPlayback': 'download-only',
        'probeStatus': 'ready',
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.dark),
          home: Scaffold(
            body: CinemaDetailDialog(
              api: api,
              film: film,
              isAdmin: true,
              playerOnly: true,
              onRename: (f) async => f,
              onProgressUpdated: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(api.hlsSessionCalls, 1);
      expect(api.streamUris, isNotEmpty);
      expect(
        api.streamUris.last.toString(),
        contains('/api/v2/cinema/108/stream?direct=1'),
      );
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(
        find.textContaining('服务器未安装 FFmpeg，已自动启用原片直传（本地解码）'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'cinema streams directly for local decoding when preferLocalDecode is enabled in settings',
    (tester) async {
      await CinemaDecodePreference.setPreferLocalDecode(true);
      final api = _NoFfmpegCinemaApi();
      final platform = _FakeVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() async {
        await CinemaDecodePreference.setPreferLocalDecode(false);
        await tester.pumpWidget(const SizedBox.shrink());
        api.close();
      });

      final film = CinemaFilm.fromJson(<String, dynamic>{
        'id': 108,
        'title': '4K HEVC MKV Film',
        'path': 'Cinema/hevc_movie.mkv',
        'kind': 'movie',
        'playable': false,
        'browserPlayback': 'download-only',
        'probeStatus': 'ready',
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.dark),
          home: Scaffold(
            body: CinemaDetailDialog(
              api: api,
              film: film,
              isAdmin: true,
              playerOnly: true,
              onRename: (f) async => f,
              onProgressUpdated: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // Should skip FFmpeg HLS transcode completely and stream ?direct=1
      expect(api.hlsSessionCalls, 0);
      expect(
        api.streamUris.single.toString(),
        contains('/api/v2/cinema/108/stream?direct=1'),
      );
      expect(find.byType(VideoPlayer), findsOneWidget);
    },
  );
}
