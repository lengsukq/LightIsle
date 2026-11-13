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

String formatCinemaSeasonEpisodeCode(CinemaFilm film) {
  if (!film.isSeries || (film.season <= 0 && film.episode <= 0)) return '';
  final s = film.season > 0 ? film.season : 1;
  final e = film.episode > 0 ? film.episode : 1;
  return 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
}

String formatCinemaRemainingText(CinemaFilm film) {
  final total = film.duration > 0 ? film.duration : film.durationSeconds;
  if (!total.isFinite || total <= 0) return '';
  final remaining = (total - film.position).clamp(0.0, total).toDouble();
  if (remaining <= 0) return '';
  if (remaining < 60) return '不足 1 分钟';
  final totalMinutes = (remaining / 60).ceil();
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours > 0 && minutes > 0) return '$hours 小时 $minutes 分钟';
  if (hours > 0) return '$hours 小时';
  return '$totalMinutes 分钟';
}

String formatCinemaResumeCtaLabel(CinemaFilm film) {
  if (!film.canResume) return '开始播放';
  final code = formatCinemaSeasonEpisodeCode(film);
  final remaining = formatCinemaRemainingText(film);
  final parts = <String>[
    '继续播放',
    if (code.isNotEmpty) code,
    if (remaining.isNotEmpty) '剩余 $remaining',
  ];
  if (parts.length == 1) return parts.first;
  if (code.isNotEmpty && remaining.isNotEmpty) {
    return '继续播放 $code · 剩余 $remaining';
  }
  if (code.isNotEmpty) return '继续播放 $code';
  return '继续播放 · 剩余 $remaining';
}

CinemaFilm? resolveSeriesResumeEpisode(
  CinemaSeriesInfo series,
  List<CinemaFilm> episodes,
) {
  if (episodes.isEmpty) return null;
  if (series.nextFilmId > 0) {
    for (final episode in episodes) {
      if (episode.id == series.nextFilmId) return episode;
    }
  }
  for (final episode in episodes) {
    if (episode.canResume) return episode;
  }
  if (series.nextSeason > 0 && series.nextEpisode > 0) {
    for (final episode in episodes) {
      if (episode.season == series.nextSeason &&
          episode.episode == series.nextEpisode) {
        return episode;
      }
    }
  }
  if (series.inProgress) {
    for (final episode in episodes) {
      if (!episode.completed) return episode;
    }
  }
  return null;
}
