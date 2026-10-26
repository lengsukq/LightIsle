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

        final located = PhotoAsset.fromJson(<String, dynamic>{
          'id': 12,
          'path': 'Trips/boat.jpg',
          'name': 'boat.jpg',
          'type': 'photo',
          'size': 4096,
          'takenAt': 1_792_000_000,
          'favorite': false,
          'canWrite': false,
          'latitude': 31.2304,
          'longitude': 121.4737,
          'cameraMake': 'Fixture Camera',
          'cameraModel': 'Fixture One',
          'lensModel': 'Fixture Lens 23mm',
          'iso': 200,
          'fNumber': 2.8,
          'exposureSeconds': 0.004,
          'focalLength': 23,
        });
        final bare = PhotoAsset.fromJson(<String, dynamic>{
          'id': 13,
          'path': 'Trips/plain.png',
          'name': 'plain.png',
          'type': 'photo',
          'size': 10,
          'takenAt': 1_792_000_000,
          'favorite': false,
          'canWrite': false,
        });

        expect(located.latitude, closeTo(31.2304, 1e-9));
        expect(located.longitude, closeTo(121.4737, 1e-9));
        expect(located.cameraModel, 'Fixture One');
        expect(located.iso, 200);
        expect(located.fNumber, 2.8);
        expect(located.focalLength, 23);
        expect(located.withFavorite(true).longitude, located.longitude);
        expect(located.withPersonalFavorite(true).cameraMake, 'Fixture Camera');
        expect(bare.latitude, isNull);
        expect(bare.longitude, isNull);
        expect(bare.cameraMake, isEmpty);

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

  group('cinemaPlaybackClock original-timeline judgments', () {
    test('late-offset session must not complete on its short playlist', () {
      final clock = cinemaPlaybackClock(
        12,
        25,
        sessionStart: 600,
        originalDuration: 720,
      );

      expect(clock.position, closeTo(612, 1e-9));
      expect(clock.duration, closeTo(720, 1e-9));
      expect(clock.nearEnd, isFalse);
    });

    test('completion uses the indexed original timeline', () {
      final resumed = cinemaPlaybackClock(
        115,
        120,
        sessionStart: 600,
        originalDuration: 720,
      );
      final fromStart = cinemaPlaybackClock(
        115,
        120,
        sessionStart: 0,
        originalDuration: 120,
      );

      expect(resumed.position, closeTo(715, 1e-9));
      expect(resumed.duration, closeTo(720, 1e-9));
      expect(resumed.nearEnd, isTrue);
      expect(fromStart.position, closeTo(115, 1e-9));
      expect(fromStart.duration, closeTo(120, 1e-9));
      expect(fromStart.nearEnd, isTrue);
    });

    test('unknown original duration cannot mark a late session watched', () {
      final clock = cinemaPlaybackClock(14, 15, sessionStart: 300);

      expect(clock.position, closeTo(314, 1e-9));
      expect(clock.duration, closeTo(315, 1e-9));
      expect(clock.nearEnd, isFalse);
    });

    test('position past the indexed end still reports near end', () {
      final clock = cinemaPlaybackClock(
        10,
        12,
        sessionStart: 7195,
        originalDuration: 7200,
      );

      expect(clock.position, closeTo(7205, 1e-9));
      expect(clock.duration, closeTo(7205, 1e-9));
      expect(clock.nearEnd, isTrue);
    });

    test('non-finite and negative inputs fall back to a zero clock', () {
      final clock = cinemaPlaybackClock(
        double.nan,
        -5,
        sessionStart: double.infinity,
        originalDuration: double.nan,
      );

      expect(clock.position, 0);
      expect(clock.duration, 0);
      expect(clock.nearEnd, isFalse);
    });
  });
}
