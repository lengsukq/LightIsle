import 'media_models.dart';

bool shouldShowCinemaDiscoveryRails(int loadedCount, int nextCursor) {
  return nextCursor > 0 || loadedCount > 8;
}

final RegExp _cinemaTitlePunctuation = RegExp(
  r'[\s:：·・\-_—–.。!！?？()（）\[\]【】]+',
);
final RegExp _userScopedPrefix = RegExp(
  r'^users/u\d+(/|$)',
  caseSensitive: false,
);

String normalizeCinemaTitleKey(String title) {
  return title.trim().toLowerCase().replaceAll(_cinemaTitlePunctuation, '');
}

Set<String> duplicateCinemaTitleKeys(Iterable<CinemaFilm> films) {
  final counts = <String, int>{};
  for (final film in films) {
    final key = normalizeCinemaTitleKey(film.title);
    if (key.isEmpty) continue;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return {
    for (final entry in counts.entries)
      if (entry.value > 1) entry.key,
  };
}

String cinemaFilmFolderBadge(String filePath) {
  final clean = filePath.replaceAll(RegExp(r'^/+|/+$'), '');
  if (clean.isEmpty || !clean.contains('/')) return '根目录';
  final parts = clean.split('/');
  if (_userScopedPrefix.hasMatch(clean)) {
    if (parts.length > 4) return '个人空间 · ${parts[parts.length - 2]}';
    return '个人空间';
  }
  return parts.length >= 2 ? parts[parts.length - 2] : parts.first;
}

String? cinemaDisambiguationBadge(
  CinemaFilm film,
  Set<String> duplicateTitleKeys,
) {
  if (duplicateTitleKeys.isEmpty) return null;
  final key = normalizeCinemaTitleKey(film.title);
  if (!duplicateTitleKeys.contains(key)) return null;
  return cinemaFilmFolderBadge(film.path);
}
