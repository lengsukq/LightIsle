import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Content-first film destination. The player is a separate route; opening a
/// poster does not immediately allocate a video decoder or begin streaming.
class CinemaFilmOverview extends StatelessWidget {
  const CinemaFilmOverview({
    super.key,
    required this.api,
    required this.film,
    required this.onPlay,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final Future<void> Function() onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('影片详情')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 650;
                final poster = ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: AuthenticatedMediaImage(
                      api: api,
                      path: '/api/v2/cinema/${film.id}/poster',
                      fit: BoxFit.cover,
                      maxBytes: 4 * 1024 * 1024,
                      loadingBuilder: (_) => ColoredBox(
                        color: scheme.surfaceContainerHigh,
                        child: const Center(
                          child: Icon(Icons.movie_outlined, size: 48),
                        ),
                      ),
                      errorBuilder: (_, _, retry) => ColoredBox(
                        color: scheme.surfaceContainerHigh,
                        child: Center(
                          child: IconButton(
                            tooltip: '重新加载影片封面',
                            onPressed: retry,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                final content = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      film.title,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (film.year > 0) Chip(label: Text('${film.year}')),
                        Chip(label: Text(film.isSeries ? '剧集' : '电影')),
                        Chip(
                          label: Text(
                            formatMediaSeconds(
                              film.durationSeconds > 0
                                  ? film.durationSeconds
                                  : film.duration,
                            ),
                          ),
                        ),
                        if (film.rating > 0)
                          Chip(
                            label: Text('评分 ${film.rating.toStringAsFixed(1)}'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const ValueKey('cinemaOverviewPlay'),
                      onPressed: () => onPlay(),
                      icon: Icon(
                        film.canResume
                            ? Icons.play_circle_filled_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(film.canResume ? '继续观看' : '开始播放'),
                    ),
                    if (film.canResume) ...[
                      const SizedBox(height: 8),
                      Text(
                        '上次看到 ${formatMediaSeconds(film.position)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (film.overview.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text('简介', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(film.overview, style: theme.textTheme.bodyLarge),
                    ],
                    if (!film.canAttemptPlayback) ...[
                      const SizedBox(height: 20),
                      Text(
                        '当前设备可能无法直接播放此格式。可以尝试播放时的兼容方案，或保存原文件。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                );
                return ListView(
                  padding: EdgeInsets.all(wide ? 32 : 20),
                  children: [
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 250, child: poster),
                          const SizedBox(width: 32),
                          Expanded(child: content),
                        ],
                      )
                    else ...[
                      Center(
                        child: SizedBox(
                          width: constraints.maxWidth.clamp(0, 240).toDouble(),
                          child: poster,
                        ),
                      ),
                      const SizedBox(height: 22),
                      content,
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
