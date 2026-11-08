import 'package:flutter/material.dart';

import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// A real series destination with season/episode navigation aligned with
/// Netflix series detail views. Selecting an episode opens the player on top,
/// allowing Back to return to the same season.
class CinemaSeriesOverview extends StatefulWidget {
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
  State<CinemaSeriesOverview> createState() => _CinemaSeriesOverviewState();
}

class _CinemaSeriesOverviewState extends State<CinemaSeriesOverview> {
  int _selectedSeason = 0;

  @override
  Widget build(BuildContext context) {
    final seasons = widget.episodes.map((film) => film.season).toSet().toList()
      ..sort();
    final visibleSeasons = _selectedSeason == 0
        ? seasons
        : seasons.where((s) => s == _selectedSeason).toList();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: IsleAppBar(title: Text(widget.series.name)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              key: const ValueKey('cinemaSeriesEpisodes'),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE50914).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'LIGHTISLE 剧集',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFFE50914),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '共 ${widget.episodes.length} 集 · 已看 ${widget.series.watchedCount} 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  widget.series.name,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (widget.series.overview.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(widget.series.overview, style: theme.textTheme.bodyMedium),
                ],
                if (seasons.length > 1) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('全部季'),
                        selected: _selectedSeason == 0,
                        onSelected: (_) => setState(() => _selectedSeason = 0),
                      ),
                      for (final season in seasons)
                        ChoiceChip(
                          label: Text('S$season'),
                          selected: _selectedSeason == season,
                          onSelected: (_) =>
                              setState(() => _selectedSeason = season),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (widget.episodes.isEmpty)
                  MediaEmptyState(
                    icon: Icons.live_tv_outlined,
                    title: '还没有可播放的分集',
                    message: widget.error ?? '请确认影片已加入媒体库并完成扫描。',
                  ),
                for (final season in visibleSeasons) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
                    child: Text(
                      '第 $season 季',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final film in widget.episodes.where(
                    (item) => item.season == season,
                  ))
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            key: ValueKey('cinemaEpisode_${film.id}'),
                            leading: CircleAvatar(
                              backgroundColor: film.completed
                                  ? const Color(0xFF15803D).withValues(alpha: 0.16)
                                  : theme.colorScheme.primaryContainer,
                              child: Text('${film.episode}'),
                            ),
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
                            onTap: () => widget.onEpisode(film),
                          ),
                          if (film.canResume && film.duration > 0)
                            LinearProgressIndicator(
                              value: (film.position / film.duration)
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                              minHeight: 3,
                              backgroundColor: Colors.black12,
                              color: const Color(0xFFE50914),
                            ),
                        ],
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
