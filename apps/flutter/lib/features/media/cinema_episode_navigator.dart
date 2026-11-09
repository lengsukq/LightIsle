import '../../core/lightisle_api.dart';
import 'media_models.dart';

/// Finds the next episode or builds a same-directory playlist without
/// retaining playback state. Series names must resolve to exactly one series
/// ID; ambiguous matches fail closed.
class CinemaEpisodeNavigator {
  const CinemaEpisodeNavigator(this.api);

  final LightIsleApi api;

  static String directoryOf(String rawPath) {
    final normalized = rawPath.trim().replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash <= 0) return '.';
    return normalized.substring(0, slash);
  }

  static String directoryLabel(String rawPath) {
    final dir = directoryOf(rawPath);
    if (dir == '.' || dir.isEmpty) return '根目录';
    return dir.replaceAll('/', ' / ');
  }

  static List<CinemaFilm> buildSameDirectoryPlaylist(
    CinemaFilm current,
    Iterable<CinemaFilm> candidates,
  ) {
    final targetDir = directoryOf(current.path);
    final byId = <int, CinemaFilm>{current.id: current};
    for (final item in candidates) {
      if (item.id == current.id) continue;
      if (directoryOf(item.path) == targetDir) {
        byId.putIfAbsent(item.id, () => item);
      }
    }
    final items = byId.values.toList();
    items.sort((a, b) {
      final aHasEp = a.season > 0 || a.episode > 0;
      final bHasEp = b.season > 0 || b.episode > 0;
      if (aHasEp != bHasEp) return aHasEp ? -1 : 1;
      if (aHasEp) {
        final season = a.season.compareTo(b.season);
        if (season != 0) return season;
        final episode = a.episode.compareTo(b.episode);
        if (episode != 0) return episode;
      }
      final pathCmp = a.path.toLowerCase().compareTo(b.path.toLowerCase());
      if (pathCmp != 0) return pathCmp;
      return a.id.compareTo(b.id);
    });
    return items;
  }

  Future<List<CinemaFilm>> loadSameDirectory(CinemaFilm current) async {
    final dir = directoryOf(current.path);
    final response = await api.get(
      '/api/v2/cinema',
      query: <String, String>{'dir': dir, 'limit': '120'},
    );
    final parsed = <CinemaFilm>[];
    for (final item in (response['films'] as List? ?? const [])) {
      if (item is Map) {
        try {
          parsed.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
        } on FormatException {
          // Malformed upstream rows must not hide healthy siblings.
        }
      }
    }
    return buildSameDirectoryPlaylist(current, parsed);
  }

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
