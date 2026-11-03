import '../../core/lightisle_api.dart';
import 'media_models.dart';

/// Resolved, authenticated HLS session. Player ownership stays with the
/// screen, but network readiness and retry policy live in this service.
final class CinemaHlsSource {
  const CinemaHlsSource({required this.session, required this.playlist});

  final CinemaHlsSession session;
  final Uri playlist;
}

/// Start HLS on the server and wait for the first playable playlist.
///
/// The server writes its first segment asynchronously, so a newly created
/// session can return 404 until muxing starts. HTTP 502 is a terminal failure,
/// while other expected media API failures may be retried. A closed screen
/// must never initialize a player with an obsolete capability URL.
Future<CinemaHlsSource?> prepareCinemaHlsSource({
  required LightIsleApi api,
  required String filmId,
  required bool Function() isCurrent,
  double start = 0,
  int audio = 0,
  String quality = 'source',
  int attempts = 60,
  Duration retryDelay = const Duration(milliseconds: 500),
}) async {
  final session = CinemaHlsSession.fromJson(
    await api.get(
      '/api/v2/cinema/$filmId/hls/session',
      query: <String, String>{
        'start': start.clamp(0, double.infinity).toStringAsFixed(3),
        'audio': '$audio',
        if (quality != 'source') 'quality': quality,
      },
    ),
  );
  if (!isCurrent()) return null;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (!isCurrent()) return null;
    try {
      await api.bytes(
        '/api/v2/cinema/$filmId/hls/${session.sessionId}/index.m3u8',
        maxBytes: 1 << 20,
      );
      if (!isCurrent()) return null;
      final playlist = await api.mediaHlsUri(
        '/api/v2/cinema/$filmId/hls/${session.sessionId}/',
      );
      if (!isCurrent()) return null;
      return CinemaHlsSource(session: session, playlist: playlist);
    } on LightIsleApiException catch (error) {
      if (error.statusCode == 502) rethrow;
      if (attempt + 1 < attempts) await Future<void>.delayed(retryDelay);
    }
  }
  if (!isCurrent()) return null;
  throw const LightIsleApiException(
    code: 'transcode_start_timeout',
    message: '转码启动超时。',
  );
}
