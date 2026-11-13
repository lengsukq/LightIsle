import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'cinema_catalog_display.dart';
import 'media_models.dart';
import 'media_ui.dart';

typedef CinemaSeriesSnapshot = ({
  CinemaSeriesInfo? series,
  List<CinemaFilm> episodes,
});

/// A real series destination with season/episode navigation aligned with
/// Netflix series detail views. Selecting an episode opens the player on top,
/// allowing Back to return to the same season.
class CinemaSeriesOverview extends StatefulWidget {
  const CinemaSeriesOverview({
    super.key,
    required this.series,
    required this.episodes,
    required this.onEpisode,
    this.onRefreshEpisodes,
    this.error,
  });

  final CinemaSeriesInfo series;
  final List<CinemaFilm> episodes;
  final Future<void> Function(CinemaFilm film) onEpisode;
  final Future<CinemaSeriesSnapshot?> Function()? onRefreshEpisodes;
  final String? error;

  @override
  State<CinemaSeriesOverview> createState() => _CinemaSeriesOverviewState();
}

class _CinemaSeriesOverviewState extends State<CinemaSeriesOverview> {
  late CinemaSeriesInfo _series = widget.series;
  late List<CinemaFilm> _episodes = widget.episodes;
  int _selectedSeason = 0;
  final GlobalKey _resumeCardKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _selectedSeason = _initialSeason(_series, _episodes);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToResume());
  }

  @override
  void didUpdateWidget(covariant CinemaSeriesOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series != widget.series ||
        oldWidget.episodes != widget.episodes) {
      _series = widget.series;
      _episodes = widget.episodes;
      final seasons = _episodes.map((f) => f.season).toSet();
      if (_selectedSeason != 0 && !seasons.contains(_selectedSeason)) {
        _selectedSeason = _initialSeason(_series, _episodes);
      }
    }
  }

  int _initialSeason(CinemaSeriesInfo series, List<CinemaFilm> episodes) {
    final seasons = episodes.map((f) => f.season).toSet();
    if (series.nextSeason > 0 && seasons.contains(series.nextSeason)) {
      return series.nextSeason;
    }
    final resume = resolveSeriesResumeEpisode(series, episodes);
    if (resume != null &&
        (resume.canResume || series.inProgress || series.nextFilmId > 0) &&
        seasons.contains(resume.season)) {
      return resume.season;
    }
    return 0;
  }

  void _scrollToResume() {
    if (!mounted) return;
    final ctx = _resumeCardKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: 0.25, duration: Duration.zero);
  }

  Future<void> _playEpisode(CinemaFilm film) async {
    await widget.onEpisode(film);
    final refresh = widget.onRefreshEpisodes;
    if (!mounted || refresh == null) return;
    final latest = await refresh();
    if (!mounted || latest == null) return;
    setState(() {
      if (latest.series != null) _series = latest.series!;
      _episodes = latest.episodes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _episodes.map((film) => film.season).toSet().toList()
      ..sort();
    final visibleSeasons = _selectedSeason == 0
        ? seasons
        : seasons.where((s) => s == _selectedSeason).toList();
    final resumeTarget = resolveSeriesResumeEpisode(_series, _episodes);
    final ctaTarget =
        resumeTarget ?? (_episodes.isNotEmpty ? _episodes.first : null);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: IsleAppBar(title: Text(_series.name)),
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
                        '共 ${_episodes.length} 集 · 已看 ${_series.watchedCount} 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _series.name,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (_series.overview.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(_series.overview, style: theme.textTheme.bodyMedium),
                ],
                if (ctaTarget != null) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('cinemaSeriesPlayCta'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE50914),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                        onPressed: () => unawaited(_playEpisode(ctaTarget)),
                        icon: Icon(
                          ctaTarget.canResume
                              ? Icons.play_circle_filled_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(
                          ctaTarget.canResume
                              ? formatCinemaResumeCtaLabel(ctaTarget)
                              : '播放 ${formatCinemaSeasonEpisodeCode(ctaTarget).isEmpty ? '第 ${ctaTarget.episode} 集' : formatCinemaSeasonEpisodeCode(ctaTarget)}',
                        ),
                      ),
                    ],
                  ),
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
                if (_episodes.isEmpty)
                  MediaEmptyState(
                    icon: Icons.live_tv_outlined,
                    title: '还没有可播放的分集',
                    message: widget.error ?? '请确认影片已加入媒体库并完成扫描。',
                  ),
                for (final season in visibleSeasons) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
                    child: Text(
                      '第 $season 季',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IsleResponsiveGrid(
                    minItemWidth: 320,
                    maxColumns: 2,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      for (final film in _episodes.where(
                        (item) => item.season == season,
                      ))
                        _buildEpisodeCard(
                          context,
                          film: film,
                          isResumeTarget: resumeTarget?.id == film.id,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeCard(
    BuildContext context, {
    required CinemaFilm film,
    required bool isResumeTarget,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final remaining = film.canResume ? formatCinemaRemainingText(film) : '';
    final subtitleText = film.canResume
        ? '已看 ${formatMediaSeconds(film.position)}${remaining.isEmpty ? '' : ' · 剩余 $remaining'}'
        : film.completed
        ? '已看完'
        : formatMediaSeconds(
            film.durationSeconds > 0 ? film.durationSeconds : film.duration,
          );
    final surface = Container(
      key: isResumeTarget ? const ValueKey('cinemaSeriesResumeEpisode') : null,
      decoration: isResumeTarget
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: const Color(0xFFE50914).withValues(alpha: 0.72),
                width: 1.5,
              ),
            )
          : null,
      child: IsleSurface(
        margin: EdgeInsets.zero,
        padding: EdgeInsets.zero,
        radius: 14,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: ValueKey('cinemaEpisode_${film.id}'),
              dense: true,
              leading: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: film.completed
                      ? const Color(0xFF15803D).withValues(alpha: 0.16)
                      : isResumeTarget
                      ? const Color(0xFFE50914).withValues(alpha: 0.14)
                      : scheme.primaryContainer,
                ),
                child: Text(
                  '${film.episode}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: film.completed
                        ? const Color(0xFF15803D)
                        : isResumeTarget
                        ? const Color(0xFFE50914)
                        : scheme.onPrimaryContainer,
                  ),
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      film.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (isResumeTarget) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE50914).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        film.canResume ? '上次看到' : '下一集',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFFE50914),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                subtitleText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(
                film.completed
                    ? Icons.check_circle_outline_rounded
                    : Icons.play_circle_outline_rounded,
                color: isResumeTarget ? const Color(0xFFE50914) : null,
              ),
              onTap: () => unawaited(_playEpisode(film)),
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
    );
    if (!isResumeTarget) return surface;
    return KeyedSubtree(key: _resumeCardKey, child: surface);
  }
}
