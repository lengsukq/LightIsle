import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/media_models.dart';

void main() {
  group('PhotoAsset contract parsing', () {
    test(
      'keeps shared write capability explicit and fails closed when absent',
      () {
        final readOnly = PhotoAsset.fromJson(<String, dynamic>{
          'id': 8,
          'path': 'Trips/shore.jpg',
          'name': 'shore.jpg',
          'type': 'photo',
          'size': 2048,
          'takenAt': 1_792_000_000,
          'favorite': true,
        });
        final writable = PhotoAsset.fromJson(<String, dynamic>{
          'id': 9,
          'path': 'Trips/sunset.jpg',
          'name': 'sunset.jpg',
          'type': 'photo',
          'favorite': false,
          'personalFavorite': true,
          'canWrite': true,
        });

        expect(readOnly.canWrite, isFalse);
        expect(readOnly.favorite, isTrue);
        expect(readOnly.takenAt, 1_792_000_000);
        expect(writable.canWrite, isTrue);
        expect(writable.favorite, isFalse);
        expect(writable.personalFavorite, isTrue);
        expect(writable.withFavorite(true).personalFavorite, isTrue);
        expect(writable.withPersonalFavorite(false).favorite, isFalse);
        expect(
          () => PhotoAsset.fromJson(<String, dynamic>{'id': 0}),
          throwsFormatException,
        );
      },
    );
  });

  group('CinemaFilm contract parsing', () {
    test('preserves per-account progress and playback capability', () {
      final film = CinemaFilm.fromJson(<String, dynamic>{
        'id': 14,
        'title': 'The Sea',
        'path': 'Cinema/The Sea.mp4',
        'kind': 'movie',
        'size': 4_000_000,
        'playable': true,
        'browserPlayback': 'verified-direct',
        'probeStatus': 'ready',
        'container': 'mp4',
        'videoCodec': 'h264',
        'audioCodec': 'aac',
        'durationSeconds': 7200,
        'position': 1350.5,
        'duration': 7200,
        'completed': false,
        'overview': 'A story about the sea.',
        'rating': 8.2,
        'metadataSource': 'tmdb:movie:42',
        'posterURL': 'https://image.tmdb.org/t/p/w342/poster.jpg',
      });

      expect(film.canAttemptPlayback, isTrue);
      expect(film.canResume, isTrue);
      expect(film.position, 1350.5);
      expect(film.durationSeconds, 7200);
      expect(film.overview, 'A story about the sea.');
      expect(film.rating, 8.2);
      expect(film.metadataSource, 'tmdb:movie:42');
      expect(film.posterURL, contains('/poster.jpg'));
      expect(film.withTitle('A new display name').overview, film.overview);
      expect(
        film
            .withProgress(
              newPosition: 7200,
              newDuration: 7200,
              isCompleted: true,
            )
            .completed,
        isTrue,
      );
    });

    test('does not try formats the server marks download-only', () {
      final film = CinemaFilm.fromJson(<String, dynamic>{
        'id': 15,
        'title': 'Archive',
        'browserPlayback': 'download-only',
        'playable': false,
        'probeStatus': 'unsupported',
      });

      expect(film.canAttemptPlayback, isFalse);
      expect(film.probeStatus, 'unsupported');
    });
  });

  test('parses TMDB candidates and rejects rows without a stable match', () {
    final candidate = TMDBCandidate.fromJson(<String, dynamic>{
      'id': 35,
      'kind': 'movie',
      'title': 'The Sea',
      'year': '2026',
      'overview': 'A quiet story.',
      'rating': 7.5,
      'posterURL': 'https://image.tmdb.org/t/p/w342/sea.jpg',
    });

    expect(candidate.id, 35);
    expect(candidate.title, 'The Sea');
    expect(candidate.rating, 7.5);
    expect(
      () => TMDBCandidate.fromJson(<String, dynamic>{'id': 35, 'title': ' '}),
      throwsFormatException,
    );
  });

  test('parses backend VTT cues and ignores malformed blocks', () {
    final cues = parseWebVtt('''
\uFEFFWEBVTT

1
00:00:01,000 --> 00:00:02.500 align:center
你好，世界
第二行

bad timing --> still bad
忽略这段

00:00:04.000 --> 00:00:03.000
结束早于开始
''');

    expect(cues, hasLength(1));
    expect(cues.single.start, const Duration(seconds: 1));
    expect(cues.single.end, const Duration(milliseconds: 2500));
    expect(cues.single.text, '你好，世界\n第二行');
    expect(cues.single.contains(const Duration(seconds: 2)), isTrue);
    expect(cues.single.contains(const Duration(seconds: 3)), isFalse);
  });

  test('accepts minimized status payloads returned to members', () {
    final status = MediaScanStatus.fromJson(<String, dynamic>{'running': true});

    expect(status.running, isTrue);
    expect(status.scanned, 0);
    expect(status.found, 0);
  });
}
