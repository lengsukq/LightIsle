import '../../core/lightisle_api.dart';
import 'media_models.dart';

/// Finds the next episode without retaining playback state. Series names must
/// resolve to exactly one series ID; ambiguous matches fail closed.
class CinemaEpisodeNavigator {
  const CinemaEpisodeNavigator(this.api);

  final LightIsleApi api;

  Future<CinemaFilm?> findNext(CinemaFilm current) async {
    if (!current.isSeries || current.series.isEmpty) return null;
    final response = await api.get('/api/v2/series', query: {'limit': '60'});
    final matches = <int>[];
    for (final item in (response['series'] as List? ?? const [])) {
      if (item is Map && item['name'] == current.series && item['id'] is num) {
        matches.add((item['id'] as num).toInt());
      }
    }
    if (matches.length != 1 || matches.single <= 0) return null;
    final detail = await api.get('/api/v2/series/${matches.single}');
    final episodes = <CinemaFilm>[];
    for (final item in (detail['films'] as List? ?? const [])) {
      if (item is Map) {
        try {
          episodes.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
        } on FormatException {
          // Malformed upstream rows must not hide healthy episodes.
        }
      }
    }
    episodes.sort((a, b) {
      final season = a.season.compareTo(b.season);
      if (season != 0) return season;
      final episode = a.episode.compareTo(b.episode);
      return episode != 0 ? episode : a.id.compareTo(b.id);
    });
    final index = episodes.indexWhere((item) => item.id == current.id);
    return index < 0 || index + 1 >= episodes.length
        ? null
        : episodes[index + 1];
  }
}
