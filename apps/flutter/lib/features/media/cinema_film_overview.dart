import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import '../files/file_share_dialog.dart';
import 'cinema_catalog_display.dart';
import 'cinema_metadata_repository.dart';
import 'cinema_online_subtitles_and_collections.dart';
import 'cinema_poster_image.dart';
import 'media_models.dart';
import 'media_ui.dart';

part 'cinema_film_overview_metadata.dart';

class CinemaFilmOverview extends StatefulWidget {
  const CinemaFilmOverview({
    super.key,
    required this.api,
    required this.film,
    required this.onPlay,
    this.isAdmin = false,
    this.onRename,
    this.onUpdated,
    this.memoryCache,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final Future<void> Function() onPlay;
  final bool isAdmin;
  final Future<CinemaFilm> Function(CinemaFilm film)? onRename;
  final ValueChanged<CinemaFilm>? onUpdated;
  final MediaImageMemoryCache? memoryCache;

  @override
  State<CinemaFilmOverview> createState() => _CinemaFilmOverviewState();
}

class _CinemaFilmOverviewState extends State<CinemaFilmOverview> {
  void _updateState(VoidCallback fn) => setState(fn);

  late CinemaFilm _film = widget.film;
  late final TextEditingController _queryController = TextEditingController(
    text: widget.film.title,
  );
  final TextEditingController _tmdbTokenController = TextEditingController();

  CinemaMetadataRepository get _metadataRepository =>
      CinemaMetadataRepository(widget.api);

  bool _actionBusy = false;
  bool _metadataBusy = false;
  bool _tmdbSearching = false;
  bool _doubanSearching = false;
  String? _statusMessage;
  bool _statusIsError = false;
  List<TMDBCandidate> _tmdbCandidates = const [];
  List<DoubanCandidate> _doubanCandidates = const [];

  @override
  void dispose() {
    _queryController.dispose();
    _tmdbTokenController.dispose();
    super.dispose();
  }

  void _applyUpdatedFilm(CinemaFilm updated, String message) {
    if (!mounted) return;
    setState(() {
      _film = updated;
      _statusMessage = message;
      _statusIsError = false;
    });
    widget.onUpdated?.call(updated);
  }

  Future<void> _playAndSync() async {
    await widget.onPlay();
    final latest = await _metadataRepository.fetchFilm(_film.id);
    if (!mounted || latest == null) return;
    setState(() => _film = latest);
    widget.onUpdated?.call(latest);
  }

  Future<void> _toggleWatched() async {
    if (_actionBusy) return;
    setState(() {
      _actionBusy = true;
      _statusMessage = null;
    });
    final nextCompleted = !_film.completed;
    try {
      final updated = await _metadataRepository.setWatched(
        _film,
        completed: nextCompleted,
      );
      _applyUpdatedFilm(updated, nextCompleted ? '已标记为已看完。' : '已标记为未看完。');
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = mediaErrorLabel(error);
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _clearProgress() async {
    if (_actionBusy) return;
    setState(() {
      _actionBusy = true;
      _statusMessage = null;
    });
    try {
      final updated = await _metadataRepository.clearProgress(_film);
      _applyUpdatedFilm(updated, '已移出继续观看，原影片文件保留不变。');
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = mediaErrorLabel(error);
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _handleRename() async {
    final rename = widget.onRename;
    if (rename == null || _actionBusy) return;
    try {
      final updated = await rename(_film);
      if (!mounted) return;
      setState(() => _film = updated);
      widget.onUpdated?.call(updated);
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = mediaErrorLabel(error);
          _statusIsError = true;
        });
      }
    }
  }

  String get _resolutionBadge {
    if (_film.width >= 3800 || _film.height >= 2100) return '4K UHD';
    if (_film.width >= 1900 || _film.height >= 1060) return '1080P HD';
    if (_film.width >= 1200 || _film.height >= 700) return '720P HD';
    return '';
  }

  Widget _buildPoster(BuildContext context, ColorScheme scheme) {
    final style = IsleThemeStyle.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: style.borderRadiusFor(IsleRadius.card),
        border: Border.all(
          color: style.rimBorderColor(),
          width: style.effectiveBorderWidth(),
        ),
        boxShadow: style.floatingShadows(),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: CinemaPosterImage.film(
          api: widget.api,
          film: _film,
          memoryCache: widget.memoryCache,
          fit: BoxFit.cover,
          maxBytes: 4 * 1024 * 1024,
          loadingBuilder: (_) => ColoredBox(
            color: scheme.surfaceContainerHigh,
            child: const Center(child: Icon(Icons.movie_outlined, size: 42)),
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
  }

  Widget _buildMetaPill(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    String text,
  ) {
    final style = IsleThemeStyle.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: IsleDecorations.recessedWell(
        context,
        radius: style.preset.cornerStyle == IsleCornerStyle.sharp
            ? IsleRadius.sm
            : IsleRadius.pill,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          key: const ValueKey('cinemaOverviewPlay'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          ),
          onPressed: _playAndSync,
          icon: Icon(
            _film.canResume
                ? Icons.play_circle_filled_rounded
                : Icons.play_arrow_rounded,
            size: 18,
          ),
          label: Text(formatCinemaResumeCtaLabel(_film)),
        ),
        OutlinedButton.icon(
          key: const ValueKey('cinemaOverviewWatchedToggle'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: _actionBusy ? null : _toggleWatched,
          icon: Icon(
            _film.completed
                ? Icons.check_circle_rounded
                : Icons.check_circle_outline_rounded,
            size: 17,
          ),
          label: Text(_film.completed ? '已看完' : '标记已看'),
        ),
        if (_film.canResume)
          OutlinedButton.icon(
            key: const ValueKey('cinemaOverviewClearProgress'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _actionBusy ? null : _clearProgress,
            icon: const Icon(Icons.playlist_remove_rounded, size: 17),
            label: const Text('移出继续观看'),
          ),
        if (widget.isAdmin && widget.onRename != null)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _actionBusy ? null : _handleRename,
            icon: const Icon(Icons.drive_file_rename_outline, size: 17),
            label: const Text('修改名称'),
          ),
        if (_film.path.isNotEmpty)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => FileShareDialog(
                api: widget.api,
                path: _film.path,
                name: _film.title,
                isFolder: false,
              ),
            ),
            icon: const Icon(Icons.ios_share_outlined, size: 17),
            label: const Text('分享'),
          ),
      ],
    );
  }

  Widget _buildOverviewDetails(
    BuildContext context, {
    required ThemeData theme,
    required ColorScheme scheme,
  }) {
    final matchScore = _film.rating > 0
        ? (_film.rating * 10).round().clamp(75, 99)
        : 0;
    final codecLabel = [
      if (_resolutionBadge.isNotEmpty) _resolutionBadge,
      if (_film.videoCodec.isNotEmpty) _film.videoCodec.toUpperCase(),
      if (_film.audioCodec.isNotEmpty) _film.audioCodec.toUpperCase(),
      if (_film.container.isNotEmpty) _film.container.toUpperCase(),
    ].join(' · ');

    final palette = IslePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IsleBadgePill(
              label: _film.isSeries ? 'LIGHTISLE 剧集' : 'LIGHTISLE 影院',
              color: palette['brandTerracotta'],
            ),
            if (matchScore > 0) ...[
              const SizedBox(width: 10),
              Text(
                '$matchScore% 推荐 · ★ ${_film.rating.toStringAsFixed(1)}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: palette['brandAmber'],
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _film.title,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_film.year > 0)
              _buildMetaPill(context, theme, scheme, '${_film.year}'),
            _buildMetaPill(context, theme, scheme, _film.isSeries ? '剧集' : '电影'),
            _buildMetaPill(
              context,
              theme,
              scheme,
              formatMediaSeconds(
                _film.durationSeconds > 0
                    ? _film.durationSeconds
                    : _film.duration,
              ),
            ),
            if (_film.rating > 0)
              _buildMetaPill(
                context,
                theme,
                scheme,
                '评分 ${_film.rating.toStringAsFixed(1)}',
              ),
            if (codecLabel.isNotEmpty)
              _buildMetaPill(context, theme, scheme, codecLabel),
          ],
        ),
        const SizedBox(height: 18),
        _buildActionButtons(context),
        if (_film.canResume) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final remaining = formatCinemaRemainingText(_film);
              return Text(
                remaining.isEmpty
                    ? '上次看到 ${formatMediaSeconds(_film.position)}'
                    : '上次看到 ${formatMediaSeconds(_film.position)} · 剩余 $remaining',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              );
            },
          ),
        ],
        if (_statusMessage != null) ...[
          const SizedBox(height: 12),
          MediaStatusBanner(message: _statusMessage!, isError: _statusIsError),
        ],
        if (_film.overview.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            '剧情简介',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _film.overview,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.56,
              color: scheme.onSurface,
            ),
          ),
        ],
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: IsleDecorations.recessedWell(context, radius: IsleRadius.md),
          child: Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              if (_film.size > 0)
                Text(
                  '文件大小：${formatMediaSize(_film.size)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              if (_film.width > 0 && _film.height > 0)
                Text(
                  '分辨率：${_film.width} × ${_film.height}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              Text(
                '资料来源：${_film.metadataSource.isEmpty ? '未匹配' : _film.metadataSource.toUpperCase()}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (!_film.canAttemptPlayback) ...[
          const SizedBox(height: 12),
          Text(
            '当前设备可能无法直接播放此格式。可以尝试播放时的服务端实时转码兼容方案，或保存原文件。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cinemaTheme = buildIsleCinemaTheme(Theme.of(context));
    return Theme(
      data: cinemaTheme,
      child: Builder(
        builder: (cinemaContext) {
          final theme = Theme.of(cinemaContext);
          final scheme = theme.colorScheme;
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: const IsleAppBar(title: Text('影片详情')),
            body: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: IsleLayout.workbenchMaxWidth,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 680;
                      final desktop = constraints.maxWidth >= 980;
                      final poster = _buildPoster(context, scheme);
                      final content = _buildOverviewDetails(
                        context,
                        theme: theme,
                        scheme: scheme,
                      );
                      return ListView(
                        padding: EdgeInsets.all(wide ? 26 : 16),
                        children: [
                          if (wide)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: desktop ? 248 : 210,
                                  child: poster,
                                ),
                                SizedBox(width: desktop ? 32 : 24),
                                Expanded(child: content),
                              ],
                            )
                          else ...[
                            Center(
                              child: SizedBox(
                                width: constraints.maxWidth
                                    .clamp(0, 200)
                                    .toDouble(),
                                child: poster,
                              ),
                            ),
                            const SizedBox(height: 18),
                            content,
                          ],
                          if (widget.isAdmin) ...[
                            const SizedBox(height: 20),
                            CinemaOnlineSubtitlesAndCollectionsCard(
                              api: widget.api,
                              film: _film,
                            ),
                            const SizedBox(height: 20),
                            _buildAdminMetadataPanel(context),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
