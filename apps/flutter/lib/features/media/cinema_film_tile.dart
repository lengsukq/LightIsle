import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import 'media_models.dart';
import 'media_ui.dart';

class CinemaFilmTile extends StatefulWidget {
  const CinemaFilmTile({
    super.key,
    required this.api,
    required this.film,
    required this.isAdmin,
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
    required this.onRename,
    this.onDetails,
    this.memoryCache,
    this.enableHero = true,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final Future<CinemaFilm> Function() onRename;
  final VoidCallback? onDetails;
  final MediaImageMemoryCache? memoryCache;
  final bool enableHero;

  @override
  State<CinemaFilmTile> createState() => _CinemaFilmTileState();
}

class _CinemaFilmTileState extends State<CinemaFilmTile> {
  bool _hovered = false;
  bool _pressed = false;
  String get _playbackLabel {
    if (widget.film.browserPlayback == 'verified-direct') return '已验证播放';
    if (widget.film.browserPlayback == 'unverified-direct') return '尝试播放';
    switch (widget.film.probeStatus) {
      case 'pending':
        return '正在识别格式';
      case 'unavailable':
        return '格式检查器不可用';
      case 'failed':
        return '格式识别失败';
      case 'unsupported':
        return '当前设备不支持';
      default:
        return '无法直接播放';
    }
  }

  String get _positionLabel {
    final value = Duration(seconds: widget.film.position.round());
    if (value.inHours > 0) {
      return '${value.inHours}时${value.inMinutes.remainder(60)}分';
    }
    return '${value.inMinutes} 分钟';
  }

  @override
  Widget build(BuildContext context) {
    final film = widget.film;
    final percent = film.duration > 0
        ? (film.position / film.duration).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final surface = Theme.of(context).colorScheme;
    final posterImage = AuthenticatedMediaImage(
      api: widget.api,
      memoryCache: widget.memoryCache,
      path: '/api/v2/cinema/${film.id}/poster',
      maxBytes: 4 * 1024 * 1024,
      fit: BoxFit.cover,
      loadingBuilder: _posterPlaceholder,
      errorBuilder: (context, error, retry) => Stack(
        fit: StackFit.expand,
        children: [
          _posterPlaceholder(context),
          Positioned(
            right: 2,
            bottom: 2,
            child: IconButton(
              tooltip: '重试加载封面',
              visualDensity: VisualDensity.compact,
              onPressed: retry,
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.selecting ? '选择：${film.title}' : '播放：${film.title}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          scale: (_hovered || _pressed) && !widget.selecting ? 1.04 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          child: Material(
            color: widget.selected
                ? surface.primaryContainer.withValues(alpha: .32)
                : Colors.transparent,
            child: InkWell(
              onTap: widget.selecting ? widget.onToggle : widget.onOpen,
              onLongPress: widget.onToggle,
              onHighlightChanged: (value) => setState(() => _pressed = value),
              borderRadius: BorderRadius.circular(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (widget.enableHero)
                            Hero(
                              tag: 'cinema_poster_${film.id}',
                              child: posterImage,
                            )
                          else
                            posterImage,
                          if (film.rating > 0 && !widget.selecting)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .72),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  child: Text(
                                    '★ ${film.rating.toStringAsFixed(1)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: const Color(0xFF46D369),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11.5,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .65),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                child: Text(
                                  film.isSeries
                                      ? 'S${film.season} · E${film.episode}'
                                      : '${film.year == 0 ? '电影' : film.year}',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                ),
                              ),
                            ),
                          ),
                          if (!film.canAttemptPlayback && !widget.selecting)
                            Positioned(
                              bottom: percent > 0 && !film.completed ? 10 : 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .65),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.info_outline_rounded,
                                  color: surface.error,
                                  size: 14,
                                ),
                              ),
                            ),
                          if (!widget.selecting && widget.onDetails != null)
                            Positioned(
                              right: 6,
                              bottom: percent > 0 && !film.completed ? 8 : 6,
                              child: Material(
                                color: Colors.black.withValues(alpha: .65),
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: IconButton(
                                  key: ValueKey(
                                    'cinemaFilmDetails_${film.id}',
                                  ),
                                  tooltip: '影片详情与资料匹配',
                                  style: IconButton.styleFrom(
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: const EdgeInsets.all(5),
                                    minimumSize: const Size(26, 26),
                                  ),
                                  onPressed: widget.onDetails,
                                  icon: const Icon(
                                    Icons.info_outline_rounded,
                                    color: Colors.white,
                                    size: 15,
                                  ),
                                ),
                              ),
                            ),
                          if (percent > 0 && !film.completed)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: percent,
                                minHeight: 3.5,
                                backgroundColor: Colors.black38,
                                color: const Color(0xFFE50914),
                              ),
                            ),
                          if (widget.selecting)
                            Positioned(
                              top: 6,
                              left: 6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: widget.selected
                                      ? surface.primary
                                      : Colors.black54,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    widget.selected
                                        ? Icons.check_rounded
                                        : Icons.circle_outlined,
                                    size: 17,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 4, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                film.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '${film.isSeries ? '剧集' : '电影'} · ${formatMediaSeconds(film.durationSeconds > 0 ? film.durationSeconds : film.duration)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: surface.onSurfaceVariant,
                                      fontSize: 11.5,
                                    ),
                              ),
                              if (film.completed)
                                Text(
                                  '已看完',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: const Color(0xFF46D369),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 11.5,
                                      ),
                                )
                              else if (film.canResume)
                                Text(
                                  '已看至 $_positionLabel',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: const Color(0xFFE50914),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 11.5,
                                      ),
                                ),
                              if (!film.canAttemptPlayback)
                                Text(
                                  _playbackLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: surface.error,
                                        fontSize: 11.5,
                                      ),
                                ),
                              if (film.metadataSource.isEmpty)
                                Text(
                                  film.scrapeState == 'miss'
                                      ? '自动未命中 · 待手动匹配'
                                      : '待匹配资料',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: surface.tertiary,
                                        fontSize: 11.5,
                                      ),
                                ),
                            ],
                          ),
                        ),
                        if (widget.isAdmin && !widget.selecting)
                          IconButton(
                            tooltip: '修改展示名称',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: widget.onRename,
                            icon: const Icon(Icons.edit_outlined, size: 15),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _posterPlaceholder(BuildContext context) {
    final film = widget.film;
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primaryContainer,
            colors.surfaceContainerHigh,
            colors.secondaryContainer,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          film.isSeries ? Icons.live_tv_outlined : Icons.movie_outlined,
          size: 42,
          color: colors.primary,
        ),
      ),
    );
  }
}

class FilmTitleDialog extends StatelessWidget {
  const FilmTitleDialog({super.key, required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改影片展示名称'),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: 100,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => Navigator.pop(context, controller.text),
      decoration: const InputDecoration(labelText: '影片名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('保存'),
      ),
    ],
  );
}
