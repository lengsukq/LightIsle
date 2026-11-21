import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'cinema_metadata_repository.dart';
import 'cinema_poster_image.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Candidate card for manual Douban metadata matching in Cinema detail view.
class CinemaDoubanCandidateCard extends StatelessWidget {
  const CinemaDoubanCandidateCard({
    super.key,
    required this.candidate,
    required this.busy,
    required this.onApply,
  });

  final DoubanCandidate candidate;
  final bool busy;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : theme.colorScheme.surface,
        border: Border.all(
          color: IsleGlass.rimBorderColor(isDark),
          width: 1.0,
        ),
        borderRadius: IsleRadius.brMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${candidate.title}${candidate.year.isEmpty ? '' : ' (${candidate.year})'}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '豆瓣 ID: ${candidate.id}${candidate.kind.isEmpty ? '' : ' · ${candidate.kind}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: busy ? null : onApply,
            child: const Text('应用资料'),
          ),
        ],
      ),
    );
  }
}

/// Candidate card for manual TMDB metadata matching in Cinema detail view.
class CinemaTmdbCandidateCard extends StatelessWidget {
  const CinemaTmdbCandidateCard({
    super.key,
    required this.api,
    required this.candidate,
    required this.busy,
    required this.onMatch,
  });

  final LightIsleApi api;
  final TMDBCandidate candidate;
  final bool busy;
  final VoidCallback onMatch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : theme.colorScheme.surface,
        border: Border.all(
          color: IsleGlass.rimBorderColor(isDark),
          width: 1.0,
        ),
        borderRadius: IsleRadius.brMd,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${candidate.title}${candidate.year.isEmpty ? '' : ' (${candidate.year})'}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${candidate.kind == 'tv' || candidate.kind == 'series' ? '剧集' : '电影'} · 评分 ${candidate.rating.toStringAsFixed(1)} / 10',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (candidate.overview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  candidate.overview,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          );
          final matchButton = OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: busy ? null : onMatch,
            icon: const Icon(Icons.check_circle_outline, size: 17),
            label: const Text('选择匹配'),
          );
          final posterThumb = candidate.posterURL.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 44,
                    height: 66,
                    child: CinemaPosterImage.tmdbCandidate(
                      api: api,
                      posterURL: candidate.posterURL,
                      loadingBuilder: (_) => ColoredBox(
                        color: theme.colorScheme.surfaceContainerHigh,
                      ),
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: const Icon(Icons.movie_outlined, size: 18),
                      ),
                    ),
                  ),
                )
              : null;
          final bodyWithPoster = posterThumb == null
              ? description
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    posterThumb,
                    const SizedBox(width: 10),
                    Expanded(child: description),
                  ],
                );
          if (constraints.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bodyWithPoster,
                const SizedBox(height: 8),
                matchButton,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: bodyWithPoster),
              const SizedBox(width: 8),
              matchButton,
            ],
          );
        },
      ),
    );
  }
}

/// Technical specification rows (type, size, duration, resolution, codecs, MIME)
/// for a Cinema film or episode.
class CinemaTechnicalMetadataCard extends StatelessWidget {
  const CinemaTechnicalMetadataCard({super.key, required this.film});

  final CinemaFilm film;

  @override
  Widget build(BuildContext context) {
    final format = <String>[
      film.container.toUpperCase(),
      film.videoCodec.toUpperCase(),
      film.audioCodec.toUpperCase(),
    ].where((value) => value.isNotEmpty).join(' · ');
    final rows = <(IconData, String, String)>[
      (
        Icons.video_library_outlined,
        '类型',
        film.isSeries
            ? '剧集 · 第 ${film.season} 季 · 第 ${film.episode} 集'
            : film.year > 0
            ? '电影 · ${film.year}'
            : '电影',
      ),
      (Icons.storage_outlined, '文件大小', formatMediaSize(film.size)),
      (
        Icons.schedule_outlined,
        '时长',
        formatMediaSeconds(
          film.durationSeconds > 0 ? film.durationSeconds : film.duration,
        ),
      ),
      if (film.width > 0 && film.height > 0)
        (Icons.aspect_ratio_outlined, '画面尺寸', '${film.width} × ${film.height}'),
      if (format.isNotEmpty) (Icons.movie_outlined, '编码格式', format),
      if (film.mime.isNotEmpty)
        (Icons.insert_drive_file_outlined, '媒体类型', film.mime),
    ];
    return IsleGroupCard(
      margin: EdgeInsets.zero,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                Icon(
                  row.$1,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 72,
                  child: Text(
                    row.$2,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    row.$3,
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
