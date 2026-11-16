import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/cinema_catalog_display.dart';
import 'package:lightisle/features/media/media_models.dart';

CinemaFilm _film(int id, String title, String path) => CinemaFilm.fromJson({
  'id': id,
  'title': title,
  'path': path,
  'kind': 'movie',
  'duration': 7200,
});

void main() {
  test(
    'shouldShowCinemaDiscoveryRails hides redundant shelves on small libraries',
    () {
      expect(shouldShowCinemaDiscoveryRails(0, 0), isFalse);
      expect(shouldShowCinemaDiscoveryRails(5, 0), isFalse);
      expect(shouldShowCinemaDiscoveryRails(8, 0), isFalse);
      expect(shouldShowCinemaDiscoveryRails(8, 24), isTrue);
      expect(shouldShowCinemaDiscoveryRails(9, 0), isTrue);
    },
  );

  test('duplicateCinemaTitleKeys and cinemaDisambiguationBadge disambiguate multi-folder copies', () {
    final films = [
      _film(1, '杀戮都市 O', 'Users/u1/videos/杀戮都市 O.mkv'),
      _film(2, '杀戮都市：O', '影视/杀戮都市：O.mkv'),
      _film(3, '黑豹2', 'Users/u1/videos/漫威/黑豹2.mp4'),
      _film(4, '黑豹2', '影视/黑豹2.mp4'),
      _film(5, '星际穿越', '影视/星际穿越.mkv'),
    ];
    final dupes = duplicateCinemaTitleKeys(films);
    expect(cinemaDisambiguationBadge(films[0], dupes), '个人空间');
    expect(cinemaDisambiguationBadge(films[1], dupes), '影视');
    expect(cinemaDisambiguationBadge(films[2], dupes), '个人空间 · 漫威');
    expect(cinemaDisambiguationBadge(films[3], dupes), '影视');
    expect(cinemaDisambiguationBadge(films[4], dupes), isNull);
  });

  test('displayTitle preserves manual rename over series and distinct episodes are not duplicates', () {
    final ep1 = CinemaFilm.fromJson({
      'id': 10,
      'title': '庆余年',
      'path': '影视/庆余年/第2季/EP01.mp4',
      'kind': 'series',
      'series': '庆余年',
      'season': 2,
      'episode': 1,
      'titleSource': 'tmdb:tv:95557',
      'duration': 2700,
    });
    final ep2 = CinemaFilm.fromJson({
      'id': 11,
      'title': '庆余年',
      'path': '影视/庆余年/第2季/EP02.mp4',
      'kind': 'series',
      'series': '庆余年',
      'season': 2,
      'episode': 2,
      'titleSource': 'tmdb:tv:95557',
      'duration': 2700,
    });
    expect(ep1.displayTitle, '庆余年');
    final renamed = ep1.withTitle('庆余年 S02E01 特别篇');
    expect(renamed.titleSource, 'manual');
    expect(renamed.displayTitle, '庆余年 S02E01 特别篇');

    final dupes = duplicateCinemaTitleKeys([ep1, ep2]);
    expect(dupes, isEmpty);
    expect(cinemaDisambiguationBadge(ep1, dupes), isNull);
  });
}
