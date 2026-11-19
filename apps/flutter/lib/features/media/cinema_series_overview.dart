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
    final cinemaTheme = buildIsleCinemaTheme(Theme.of(context));
    final seasons = _episodes.map((film) => film.season).toSet().toList()
      ..sort();
    final visibleSeasons = _selectedSeason == 0
        ? seasons
        : seasons.where((s) => s == _selectedSeason).toList();
    final resumeTarget = resolveSeriesResumeEpisode(_series, _episodes);
    final ctaTarget =
        resumeTarget ?? (_episodes.isNotEmpty ? _episodes.first : null);

    return Theme(
      data: cinemaTheme,
      child: Builder(
        builder: (cinemaContext) {
          final theme = Theme.of(cinemaContext);
          final scheme = theme.colorScheme;
          final style = IsleThemeStyle.of(cinemaContext);
          final palette = style.palette;
          final accent = palette['brandTerracotta'];
          final pageInset = IsleLayout.pageInset(
            MediaQuery.sizeOf(cinemaContext).width,
          );
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: IsleAppBar(title: Text(_series.name)),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: IsleLayout.workbenchMaxWidth,
                  ),
                  child: ListView(
                    key: const ValueKey('cinemaSeriesEpisodes'),
                    padding: EdgeInsets.fromLTRB(pageInset, 16, pageInset, 36),
                    children: [
                      IsleSurface(
                        radius: IsleRadius.hero,
                        tint: accent,
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                IsleBadgePill(
                                  label: 'LIGHTISLE 剧集',
                                  color: accent,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '共 ${_episodes.length} 集 · 已看 ${_series.watchedCount} 集',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _series.name,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (_series.overview.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                _series.overview,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.5,
                                ),
                              ),
                            ],
                            if (ctaTarget != null) ...[
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  FilledButton.icon(
                                    key: const ValueKey('cinemaSeriesPlayCta'),
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 10,
                                      ),
                                    ),
                                    onPressed: () =>
                                        unawaited(_playEpisode(ctaTarget)),
                                    icon: Icon(
                                      ctaTarget.canResume
                                          ? Icons.play_circle_filled_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 18,
                                    ),
                                    label: Text(
                                      ctaTarget.canResume
                                          ? formatCinemaResumeCtaLabel(
                                              ctaTarget,
                                            )
                                          : '播放 ${formatCinemaSeasonEpisodeCode(ctaTarget).isEmpty ? '第 ${ctaTarget.episode} 集' : formatCinemaSeasonEpisodeCode(ctaTarget)}',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (seasons.length > 1) ...[
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              side: BorderSide(
                                color: style.rimBorderColor(),
                                width: style.effectiveBorderWidth(),
                              ),
                              label: const Text('全部季'),
                              selected: _selectedSeason == 0,
                              onSelected: (_) =>
                                  setState(() => _selectedSeason = 0),
                            ),
                            for (final season in seasons)
                              ChoiceChip(
                                visualDensity: VisualDensity.compact,
                                side: BorderSide(
                                  color: style.rimBorderColor(),
                                  width: style.effectiveBorderWidth(),
                                ),
                                label: Text('S$season'),
                                selected: _selectedSeason == season,
                                onSelected: (_) =>
                                    setState(() => _selectedSeason = season),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 14),
                      if (_episodes.isEmpty)
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
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IsleResponsiveGrid(
                          minItemWidth: 300,
                          maxColumns: 3,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (final film in _episodes.where(
                              (item) => item.season == season,
                            ))
                              _buildEpisodeCard(
                                cinemaContext,
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
        },
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
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final accent = palette['brandTerracotta'];
    final doneColor = palette['success'];
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
              borderRadius: style.borderRadiusFor(IsleRadius.md + 1),
              border: Border.all(
                color: accent.withValues(alpha: 0.78),
                width: 1.5,
              ),
            )
          : null,
      child: IsleSurface(
        margin: EdgeInsets.zero,
        padding: EdgeInsets.zero,
        radius: IsleRadius.md,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: ValueKey('cinemaEpisode_${film.id}'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 3,
              ),
              leading: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: style.borderRadiusFor(IsleRadius.sm),
                  color: film.completed
                      ? doneColor.withValues(alpha: 0.16)
                      : isResumeTarget
                      ? accent.withValues(alpha: 0.18)
                      : scheme.primaryContainer,
                ),
                child: Text(
                  '${film.episode}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: film.completed
                        ? doneColor
                        : isResumeTarget
                        ? accent
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
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (isResumeTarget) ...[
                    const SizedBox(width: 6),
                    IsleBadgePill(
                      label: film.canResume ? '上次看到' : '下一集',
                      color: accent,
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                subtitleText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              trailing: Icon(
                film.completed
                    ? Icons.check_circle_outline_rounded
                    : Icons.play_circle_outline_rounded,
                size: 20,
                color: isResumeTarget ? accent : null,
              ),
              onTap: () => unawaited(_playEpisode(film)),
            ),
            if (film.canResume && film.duration > 0)
              LinearProgressIndicator(
                value: (film.position / film.duration)
                    .clamp(0.0, 1.0)
                    .toDouble(),
                minHeight: 3,
                backgroundColor: scheme.surfaceContainerHighest,
                color: accent,
              ),
          ],
        ),
      ),
    );
    if (!isResumeTarget) return surface;
    return KeyedSubtree(key: _resumeCardKey, child: surface);
  }
}
