import 'package:flutter/material.dart';

import 'media_models.dart';
import 'media_ui.dart';

/// A real series destination with season/episode navigation. Selecting an
/// episode opens the player on top, allowing Back to return to the same season.
class CinemaSeriesOverview extends StatelessWidget {
  const CinemaSeriesOverview({
    super.key,
    required this.series,
    required this.episodes,
    required this.onEpisode,
    this.error,
  });

  final CinemaSeriesInfo series;
  final List<CinemaFilm> episodes;
  final Future<void> Function(CinemaFilm film) onEpisode;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final seasons = episodes.map((film) => film.season).toSet().toList()
      ..sort();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(series.name)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              key: const ValueKey('cinemaSeriesEpisodes'),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
              children: [
                Text(series.name, style: theme.textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(
                  '共 ${episodes.length} 集 · 已看 ${series.watchedCount} 集',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (series.overview.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(series.overview, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 22),
                if (episodes.isEmpty)
                  MediaEmptyState(
                    icon: Icons.live_tv_outlined,
                    title: '还没有可播放的分集',
                    message: error ?? '请确认影片已加入媒体库并完成扫描。',
                  ),
                for (final season in seasons) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
                    child: Text(
                      '第 $season 季',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final film in episodes.where(
                    (item) => item.season == season,
                  ))
                    Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        key: ValueKey('cinemaEpisode_${film.id}'),
                        leading: CircleAvatar(child: Text('${film.episode}')),
                        title: Text(
                          film.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          film.canResume
                              ? '继续观看 · ${formatMediaSeconds(film.position)}'
                              : film.completed
                              ? '已看完'
                              : formatMediaSeconds(
                                  film.durationSeconds > 0
                                      ? film.durationSeconds
                                      : film.duration,
                                ),
                        ),
                        trailing: Icon(
                          film.completed
                              ? Icons.check_circle_outline_rounded
                              : Icons.play_circle_outline_rounded,
                        ),
                        onTap: () => onEpisode(film),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
