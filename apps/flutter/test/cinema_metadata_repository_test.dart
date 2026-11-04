import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_metadata_repository.dart';

class _MetadataApi extends LightIsleApi {
  _MetadataApi() : super('http://localhost:16666');
  final calls = <(String, String, Map<String, dynamic>?)>[];
  Map<String, dynamic> searchResponse = {};

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    calls.add((method, path, body is Map<String, dynamic> ? body : null));
    return searchResponse;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add(('GET', path, null));
    return {'id': 1, 'title': '片名', 'path': 'Films/a.mp4'};
  }
}

void main() {
  test('search only returns valid upstream TMDB candidates', () async {
    final api = _MetadataApi()
      ..searchResponse = {
        'results': [
          {'id': 42, 'title': 'Movie', 'kind': 'movie'},
          {'id': 0, 'title': 'Invalid', 'kind': 'movie'},
          'not a record',
          {'id': 43, 'title': 'Another', 'kind': 'tv'},
        ],
      };
    addTearDown(api.close);
    final candidates = await CinemaMetadataRepository(api)
        .search(1, token: 'user-owned-token', query: 'Movie');
    expect(candidates.map((e) => e.id), [42, 43]);
    expect(api.calls.single.$2, '/api/v2/cinema/1/metadata/tmdb/search');
    expect(api.calls.single.$3, {
      'accessToken': 'user-owned-token',
      'query': 'Movie',
    });
    expect(() => candidates.clear(), throwsUnsupportedError);
  });

  test('NFO imports and TMDB match refresh the same film details', () async {
    final api = _MetadataApi();
    addTearDown(api.close);
    final repo = CinemaMetadataRepository(api);
    final imported = await repo.importNfo(1);
    expect(imported.id, 1);
    final matched = await repo.match(1, token: 'secret', tmdbId: 123);
    expect(matched.id, 1);
    expect(api.calls.map((e) => '${e.$1} ${e.$2}'), [
      'POST /api/v2/cinema/1/metadata/nfo',
      'GET /api/v2/cinema/1',
      'POST /api/v2/cinema/1/metadata/tmdb/match',
      'GET /api/v2/cinema/1',
    ]);
    expect(api.calls[2].$3, {'accessToken': 'secret', 'tmdbId': 123});
  });
}
