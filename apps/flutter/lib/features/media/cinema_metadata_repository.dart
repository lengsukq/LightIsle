import '../../core/lightisle_api.dart';
import 'media_models.dart';

/// Reads and mutates only cinema metadata. UI confirmation, admin authorization
/// and credential lifetime remain owned by the detail screen and Go Core.
class CinemaMetadataRepository {
  const CinemaMetadataRepository(this.api);

  final LightIsleApi api;

  Future<CinemaFilm> importNfo(int filmId) async {
    await api.send('POST', '/api/v2/cinema/$filmId/metadata/nfo');
    return _updatedFilm(filmId);
  }

  Future<List<TMDBCandidate>> search(
    int filmId, {
    required String token,
    required String query,
  }) async {
    final response = await api.send(
      'POST',
      '/api/v2/cinema/$filmId/metadata/tmdb/search',
      body: {'accessToken': token, 'query': query},
    );
    final raw = response['results'];
    final candidates = <TMDBCandidate>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          candidates.add(
            TMDBCandidate.fromJson(Map<String, dynamic>.from(item)),
          );
        } on FormatException {
          // A malformed upstream result must not hide the other candidates.
        }
      }
    }
    return List.unmodifiable(candidates);
  }

  Future<CinemaFilm> match(
    int filmId, {
    required String token,
    required int tmdbId,
  }) async {
    await api.send(
      'POST',
      '/api/v2/cinema/$filmId/metadata/tmdb/match',
      body: {'accessToken': token, 'tmdbId': tmdbId},
    );
    return _updatedFilm(filmId);
  }

  Future<CinemaFilm> _updatedFilm(int filmId) async =>
      CinemaFilm.fromJson(await api.get('/api/v2/cinema/$filmId'));
}
