import '../../core/lightisle_api.dart';
import 'media_models.dart';

class DoubanCandidate {
  const DoubanCandidate({
    required this.id,
    required this.title,
    this.year = '',
    this.kind = '',
  });

  factory DoubanCandidate.fromJson(Map<String, dynamic> json) =>
      DoubanCandidate(
        id: (json['id'] ?? '').toString().trim(),
        title: (json['title'] ?? '').toString().trim(),
        year: (json['year'] ?? '').toString().trim(),
        kind: (json['kind'] ?? '').toString().trim(),
      );

  final String id;
  final String title;
  final String year;
  final String kind;
}

/// Reads and mutates only cinema metadata. UI confirmation, admin authorization
/// and credential lifetime remain owned by the detail screen and Go Core.
class CinemaMetadataRepository {
  const CinemaMetadataRepository(this.api);

  final LightIsleApi api;

  Future<CinemaFilm> importNfo(int filmId) async {
    await api.send('POST', '/api/v2/cinema/$filmId/metadata/nfo');
    return _updatedFilm(filmId);
  }

  Future<List<DoubanCandidate>> searchDouban(
    int filmId, {
    required String query,
  }) async {
    final response = await api.send(
      'POST',
      '/api/v2/cinema/$filmId/metadata/douban/search',
      body: {'query': query},
    );
    final raw = response['results'];
    final candidates = <DoubanCandidate>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final parsed = DoubanCandidate.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (parsed.id.isNotEmpty && parsed.title.isNotEmpty) {
          candidates.add(parsed);
        }
      }
    }
    return List.unmodifiable(candidates);
  }

  Future<CinemaFilm> matchDouban(
    int filmId, {
    required String query,
    required String doubanId,
  }) async {
    final response = await api.send(
      'POST',
      '/api/v2/cinema/$filmId/metadata/douban/match',
      body: {'query': query, 'doubanId': doubanId},
    );
    if (response.containsKey('id')) {
      return CinemaFilm.fromJson(response);
    }
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
