import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import '../files/file_share_dialog.dart';
import 'cinema_metadata_repository.dart';
import 'media_models.dart';
import 'media_ui.dart';

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

  Future<void> _toggleWatched() async {
    if (_actionBusy) return;
    setState(() {
      _actionBusy = true;
      _statusMessage = null;
    });
    final nextCompleted = !_film.completed;
    final nextPosition = nextCompleted ? 0.0 : _film.position;
    try {
      await widget.api.send(
        'POST',
        '/api/v2/cinema/${_film.id}/progress',
        body: <String, Object>{
          'position': nextPosition,
          'duration': _film.durationSeconds > 0
              ? _film.durationSeconds
              : _film.duration,
          'completed': nextCompleted,
        },
      );
      _applyUpdatedFilm(
        _film.withProgress(
          newPosition: nextPosition,
          newDuration: _film.durationSeconds > 0
              ? _film.durationSeconds
              : _film.duration,
          isCompleted: nextCompleted,
        ),
        nextCompleted ? '已标记为已看完。' : '已标记为未看完。',
      );
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

  Future<void> _importLocalNfo() async {
    if (!widget.isAdmin || _metadataBusy) return;
    setState(() {
      _metadataBusy = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final updated = await _metadataRepository.importNfo(_film.id);
      _applyUpdatedFilm(updated, '已导入本地 NFO 资料。');
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = mediaErrorLabel(error);
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _metadataBusy = false);
    }
  }

  Future<void> _searchDouban() async {
    if (!widget.isAdmin || _metadataBusy || _doubanSearching) return;
    final query = _queryController.text.trim();
    if (query.runes.length < 2) {
      setState(() {
        _statusMessage = '请输入至少 2 个字符的影视名称进行豆瓣搜索。';
        _statusIsError = true;
      });
      return;
    }
    setState(() {
      _doubanSearching = true;
      _doubanCandidates = const [];
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final results = await _metadataRepository.searchDouban(
        _film.id,
        query: query,
      );
      if (!mounted) return;
      setState(() {
        _doubanCandidates = results;
        if (results.isEmpty) {
          _statusMessage = '豆瓣未返回匹配条目，可尝试调整关键词或使用 TMDB 搜索。';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = '豆瓣搜索失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _doubanSearching = false);
    }
  }

  Future<void> _matchDouban(DoubanCandidate candidate) async {
    if (!widget.isAdmin || _metadataBusy) return;
    setState(() {
      _metadataBusy = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final updated = await _metadataRepository.matchDouban(
        _film.id,
        query: _queryController.text.trim().isEmpty
            ? candidate.title
            : _queryController.text.trim(),
        doubanId: candidate.id,
      );
      _doubanCandidates = const [];
      _applyUpdatedFilm(updated, '已匹配豆瓣影视资料。');
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = '豆瓣匹配失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _metadataBusy = false);
    }
  }

  Future<void> _searchTmdb() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching) return;
    final token = _tmdbTokenController.text.trim();
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _statusMessage = '请填写影视名称后再搜索 TMDB。';
        _statusIsError = true;
      });
      return;
    }
    setState(() {
      _tmdbSearching = true;
      _tmdbCandidates = const [];
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final results = await _metadataRepository.search(
        _film.id,
        token: token,
        query: query,
      );
      if (!mounted) return;
      setState(() {
        _tmdbCandidates = results;
        if (results.isEmpty) {
          _statusMessage = '没有找到相关 TMDB 资料，请调整关键词后重试。';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = 'TMDB 搜索失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _tmdbSearching = false);
    }
  }

  Future<void> _matchTmdb(TMDBCandidate candidate) async {
    if (!widget.isAdmin || _metadataBusy) return;
    final token = _tmdbTokenController.text.trim();
    setState(() {
      _metadataBusy = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final updated = await _metadataRepository.match(
        _film.id,
        token: token,
        tmdbId: candidate.id,
      );
      _tmdbCandidates = const [];
      _tmdbTokenController.clear();
      _applyUpdatedFilm(updated, '已匹配 TMDB 资料。');
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = 'TMDB 匹配失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _metadataBusy = false);
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
          onPressed: () => widget.onPlay(),
          icon: Icon(
            _film.canResume
                ? Icons.play_circle_filled_rounded
                : Icons.play_arrow_rounded,
          ),
          label: Text(_film.canResume ? '继续观看' : '开始播放'),
        ),
        OutlinedButton.icon(
          onPressed: _actionBusy ? null : _toggleWatched,
          icon: Icon(
            _film.completed
                ? Icons.check_circle_rounded
                : Icons.check_circle_outline_rounded,
            size: 18,
          ),
          label: Text(_film.completed ? '已看完' : '标记已看'),
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
          Text(
            '上次看到 ${formatMediaSeconds(_film.position)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
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

  Widget _buildAdminMetadataPanel(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _metadataBusy || _tmdbSearching || _doubanSearching;
    return IsleSurface(
      key: const ValueKey('cinemaOverviewMetadataPanel'),
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_fix_high_rounded, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '海报与影视资料匹配（管理员）',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : _importLocalNfo,
                icon: const Icon(Icons.description_outlined, size: 17),
                label: const Text('导入 NFO'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '无需开始播放即可直接匹配海报与简介。可优先使用豆瓣快捷搜索或本地 NFO，也可填入 TMDB Token 精确匹配。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _queryController,
            enabled: !busy,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: '搜索片名关键词',
              counterText: '',
              prefixIcon: Icon(Icons.search_rounded),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                onPressed: busy ? null : _searchDouban,
                icon: _doubanSearching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.movie_filter_outlined, size: 18),
                label: Text(_doubanSearching ? '搜索豆瓣中…' : '搜索豆瓣（免凭据）'),
              ),
            ],
          ),
          if (_doubanCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final candidate in _doubanCandidates)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${candidate.title}${candidate.year.isEmpty ? '' : ' (${candidate.year})'}',
                ),
                subtitle: Text('豆瓣 ID: ${candidate.id}'),
                trailing: OutlinedButton(
                  onPressed: busy ? null : () => _matchDouban(candidate),
                  child: const Text('应用资料'),
                ),
              ),
          ],
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          TextField(
            controller: _tmdbTokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'TMDB API Read Access Token（可选）',
              hintText: '留空将默认使用 Mac 端已配置的 Token',
              prefixIcon: Icon(Icons.key_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: busy ? null : _searchTmdb,
              icon: _tmdbSearching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore_outlined, size: 18),
              label: Text(_tmdbSearching ? '搜索 TMDB 中…' : '搜索 TMDB'),
            ),
          ),
          if (_tmdbCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final candidate in _tmdbCandidates)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${candidate.title}${candidate.year.isEmpty ? '' : ' (${candidate.year})'}',
                ),
                subtitle: Text(
                  '评分 ${candidate.rating.toStringAsFixed(1)} · ${candidate.overview}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: OutlinedButton(
                  onPressed: busy ? null : () => _matchTmdb(candidate),
                  child: const Text('选择匹配'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
