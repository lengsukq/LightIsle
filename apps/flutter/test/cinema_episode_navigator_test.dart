import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_episode_navigator.dart';
import 'package:lightisle/features/media/media_models.dart';

class _EpisodeApi extends LightIsleApi {
  _EpisodeApi() : super('http://localhost:16666');

  List<Object?> series = [];
  List<Object?> films = [];
  final requested = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requested.add(path);
    if (path == '/api/v2/series') {
      expect(query, {'limit': '60'});
      return {'series': series};
    }
    if (path.startsWith('/api/v2/series/')) return {'films': films};
    throw StateError('Unexpected path $path');
  }
}

Map<String, dynamic> film(int id, int season, int episode) => {
  'id': id,
  'title': 'Episode $episode',
  'kind': 'series',
  'series': 'Family',
  'season': season,
  'episode': episode,
  'path': 'TV/$id.mp4',
};

void main() {
  test(
    'findNext sorts season and episode independently of server order',
    () async {
      final api = _EpisodeApi()
        ..series = [
          {'id': 20, 'name': 'Family'},
        ]
        ..films = [film(4, 2, 1), film(3, 1, 3), film(1, 1, 1), film(2, 1, 2)];
      addTearDown(api.close);
      final next = await CinemaEpisodeNavigator(api)
          .findNext(CinemaFilm.fromJson(film(2, 1, 2)));
      expect(next?.id, 3);
      expect(api.requested, ['/api/v2/series', '/api/v2/series/20']);
    },
  );

  test(
    'ambiguous series names fail closed and do not fetch episodes',
    () async {
      final api = _EpisodeApi()
        ..series = [
          {'id': 20, 'name': 'Family'},
          {'id': 21, 'name': 'Family'},
        ];
      addTearDown(api.close);
      expect(
        await CinemaEpisodeNavigator(api)
            .findNext(CinemaFilm.fromJson(film(1, 1, 1))),
        isNull,
      );
      expect(api.requested, ['/api/v2/series']);
    },
  );

  test('unknown or last episode and malformed rows do not auto-play', () async {
    final api = _EpisodeApi()
      ..series = [
        {'id': 20, 'name': 'Family'},
      ]
      ..films = [
        'malformed',
        {'id': 0},
        film(1, 1, 1),
        film(2, 1, 2),
      ];
    addTearDown(api.close);
    final navigator = CinemaEpisodeNavigator(api);
    expect(
      await navigator.findNext(CinemaFilm.fromJson(film(2, 1, 2))),
      isNull,
    );
    expect(
      await navigator.findNext(CinemaFilm.fromJson(film(99, 5, 1))),
      isNull,
    );
  });

  test('standalone films never query a series', () async {
    final api = _EpisodeApi();
    addTearDown(api.close);
    final movie = CinemaFilm.fromJson({...film(1, 1, 1), 'kind': 'movie'});
    expect(await CinemaEpisodeNavigator(api).findNext(movie), isNull);
    expect(api.requested, isEmpty);
  });
}
