import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import '../files/file_share_dialog.dart';
import 'cinema_catalog_display.dart';
import 'cinema_metadata_repository.dart';
import 'media_models.dart';
import 'media_ui.dart';

part 'cinema_film_overview_metadata.dart';

/// Content-first film destination aligned with Netflix detail sheets.
/// The player is a separate route; opening a poster does not immediately
/// allocate a video decoder or begin streaming, and administrators can match
/// NFO / Douban / TMDB metadata directly on this page.
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

  Widget _buildPoster(ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: AuthenticatedMediaImage(
          api: widget.api,
          memoryCache: widget.memoryCache,
          path: '/api/v2/cinema/${_film.id}/poster',
          fit: BoxFit.cover,
          maxBytes: 4 * 1024 * 1024,
          loadingBuilder: (_) => ColoredBox(
            color: scheme.surfaceContainerHigh,
            child: const Center(child: Icon(Icons.movie_outlined, size: 48)),
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

  Widget _buildActionButtons(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          key: const ValueKey('cinemaOverviewPlay'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE50914),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          ),
          onPressed: _playAndSync,
          icon: Icon(
            _film.canResume
                ? Icons.play_circle_filled_rounded
                : Icons.play_arrow_rounded,
          ),
          label: Text(formatCinemaResumeCtaLabel(_film)),
        ),
        OutlinedButton.icon(
          key: const ValueKey('cinemaOverviewWatchedToggle'),
          onPressed: _actionBusy ? null : _toggleWatched,
          icon: Icon(
            _film.completed
                ? Icons.check_circle_rounded
                : Icons.check_circle_outline_rounded,
            size: 18,
          ),
          label: Text(_film.completed ? '已看完' : '标记已看'),
        ),
        if (_film.canResume)
          OutlinedButton.icon(
            key: const ValueKey('cinemaOverviewClearProgress'),
            onPressed: _actionBusy ? null : _clearProgress,
            icon: const Icon(Icons.playlist_remove_rounded, size: 18),
            label: const Text('移出继续观看'),
          ),
        if (widget.isAdmin && widget.onRename != null)
          OutlinedButton.icon(
            onPressed: _actionBusy ? null : _handleRename,
            icon: const Icon(Icons.drive_file_rename_outline, size: 18),
            label: const Text('修改名称'),
          ),
        if (_film.path.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => FileShareDialog(
                api: widget.api,
                path: _film.path,
                name: _film.title,
                isFolder: false,
              ),
            ),
            icon: const Icon(Icons.ios_share_outlined, size: 18),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE50914).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _film.isSeries ? 'LIGHTISLE 剧集' : 'LIGHTISLE 影院',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: const Color(0xFFE50914),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            if (matchScore > 0) ...[
              const SizedBox(width: 10),
              Text(
                '$matchScore% 推荐 · ★ ${_film.rating.toStringAsFixed(1)}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF15803D),
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
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_film.year > 0) Chip(label: Text('${_film.year}')),
            Chip(label: Text(_film.isSeries ? '剧集' : '电影')),
            Chip(
              label: Text(
                formatMediaSeconds(
                  _film.durationSeconds > 0
                      ? _film.durationSeconds
                      : _film.duration,
                ),
              ),
            ),
            if (_film.rating > 0)
              Chip(label: Text('评分 ${_film.rating.toStringAsFixed(1)}')),
            if (codecLabel.isNotEmpty) Chip(label: Text(codecLabel)),
          ],
        ),
        const SizedBox(height: 20),
        _buildActionButtons(context),
        if (_film.canResume) ...[
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              final remaining = formatCinemaRemainingText(_film);
              return Text(
                remaining.isEmpty
                    ? '上次看到 ${formatMediaSeconds(_film.position)}'
                    : '上次看到 ${formatMediaSeconds(_film.position)} · 剩余 $remaining',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              );
            },
          ),
        ],
        if (_statusMessage != null) ...[
          const SizedBox(height: 14),
          MediaStatusBanner(message: _statusMessage!, isError: _statusIsError),
        ],
        if (_film.overview.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('剧情简介', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(_film.overview, style: theme.textTheme.bodyLarge),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 8,
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
        if (!_film.canAttemptPlayback) ...[
          const SizedBox(height: 16),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: const IsleAppBar(title: Text('影片详情')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 650;
                final poster = _buildPoster(scheme);
                final content = _buildOverviewDetails(
                  context,
                  theme: theme,
                  scheme: scheme,
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
                    if (widget.isAdmin) ...[
                      const SizedBox(height: 28),
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
  }
}
