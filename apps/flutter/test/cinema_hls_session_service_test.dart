import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_hls_session_service.dart';

class _HlsApi extends LightIsleApi {
  _HlsApi() : super('http://127.0.0.1:16666');

  int attempts = 0;
  int failFor = 0;
  int statusCode = 404;
  bool current = true;
  Map<String, String>? lastQuery;
  Completer<Uint8List>? pendingBytes;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    expect(path, '/api/v2/cinema/film-id/hls/session');
    lastQuery = query;
    return {
      'sessionId': 'session-one',
      'start': 30.5,
      'quality': '720',
      'profile': 'remux',
      'ready': false,
    };
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    attempts++;
    expect(path, '/api/v2/cinema/film-id/hls/session-one/index.m3u8');
    expect(maxBytes, 1 << 20);
    if (pendingBytes != null) return pendingBytes!.future;
    if (attempts <= failFor) {
      throw LightIsleApiException(
        code: 'not_ready',
        message: 'HLS segment not ready',
        statusCode: statusCode,
      );
    }
    return Uint8List(0);
  }

  @override
  Future<Uri> mediaHlsUri(String path) async =>
      Uri.parse('http://127.0.0.1:16666${path}index.m3u8');
}

void main() {
  test(
    'waits for first segment and preserves source quality and resume offset',
    () async {
      final api = _HlsApi()..failFor = 2;
      addTearDown(api.close);
      final source = await prepareCinemaHlsSource(
        api: api,
        filmId: 'film-id',
        isCurrent: () => api.current,
        start: 30.5,
        audio: 2,
        quality: '720',
        retryDelay: Duration.zero,
      );
      expect(api.attempts, 3);
      expect(api.lastQuery, {
        'start': '30.500',
        'audio': '2',
        'quality': '720',
      });
      expect(source?.session.start, 30.5);
      expect(source?.playlist.path, contains('session-one/index.m3u8'));
    },
  );

  test('502 relay failure is terminal rather than delayed retry', () async {
    final api = _HlsApi()
      ..failFor = 5
      ..statusCode = 502;
    addTearDown(api.close);
    await expectLater(
      prepareCinemaHlsSource(
        api: api,
        filmId: 'film-id',
        isCurrent: () => api.current,
        retryDelay: Duration.zero,
      ),
      throwsA(isA<LightIsleApiException>()),
    );
    expect(api.attempts, 1);
  });

  test(
    'returns no obsolete media capability after closing the detail dialog',
    () async {
      final api = _HlsApi()..pendingBytes = Completer<Uint8List>();
      addTearDown(api.close);
      final pending = prepareCinemaHlsSource(
        api: api,
        filmId: 'film-id',
        isCurrent: () => api.current,
        retryDelay: Duration.zero,
      );
      await Future<void>.delayed(Duration.zero);
      api.current = false;
      api.pendingBytes!.complete(Uint8List(0));
      expect(await pending, null);
    },
  );

  test('reports timeout when playlist stays unavailable', () async {
    final api = _HlsApi()..failFor = 10;
    addTearDown(api.close);
    await expectLater(
      prepareCinemaHlsSource(
        api: api,
        filmId: 'film-id',
        isCurrent: () => api.current,
        attempts: 2,
        retryDelay: Duration.zero,
      ),
      throwsA(
        isA<LightIsleApiException>().having(
          (error) => error.code,
          'code',
          'transcode_start_timeout',
        ),
      ),
    );
    expect(api.attempts, 2);
  });
}
