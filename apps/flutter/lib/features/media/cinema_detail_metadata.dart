part of 'cinema_detail_dialog.dart';

extension _CinemaDetailMetadata on _CinemaDetailDialogState {
  Future<void> _importLocalNfo() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    _updateState(() {
      _metadataBusy = true;
      _metadataMessage = null;
      _metadataIsError = false;
    });
    try {
      final updated = await _metadataRepository.importNfo(filmId);
      if (!mounted || generation != _metadataGeneration) return;
      _updateState(() {
        _film = updated;
        _metadataMessage = '已导入本地 NFO 资料，原视频和观看进度未修改。';
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      _updateState(() {
        _metadataMessage = mediaErrorLabel(error);
        _metadataIsError = true;
      });
    } finally {
      if (mounted && generation == _metadataGeneration) {
        _updateState(() => _metadataBusy = false);
      }
    }
  }

  Future<void> _searchTmdb() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final token = _tmdbTokenController.text.trim();
    final query = _tmdbQueryController.text.trim();
    if (token.isEmpty || query.isEmpty) {
      _updateState(() {
        _tmdbMessage = '请输入自己的 TMDB API Read Access Token 和搜索关键词。';
      });
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    _updateState(() {
      _tmdbSearching = true;
      _tmdbCandidates = const [];
      _tmdbMessage = null;
    });
    try {
      final candidates = await _metadataRepository.search(
        filmId,
        token: token,
        query: query,
      );
      if (!mounted || generation != _metadataGeneration) return;
      _updateState(() {
        _tmdbCandidates = candidates;
        if (candidates.isEmpty) {
          _tmdbMessage = '没有找到相关影视资料，可以调整关键词后再搜索。';
        }
      });
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      _updateState(() => _tmdbMessage = '搜索失败：${mediaErrorLabel(error)}');
    } finally {
      if (mounted && generation == _metadataGeneration) {
        _updateState(() => _tmdbSearching = false);
      }
    }
  }

  Future<void> _matchTmdb(TMDBCandidate candidate) async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认匹配影视资料？'),
        content: Text(
          '将“${candidate.title}”的 TMDB 简介、评分和海报资料匹配到“${_film.title}”。手动设置的影片名称会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认匹配'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final token = _tmdbTokenController.text.trim();
    if (token.isEmpty) {
      _updateState(() => _tmdbMessage = '令牌已清除，请重新输入后搜索并匹配。');
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    _updateState(() {
      _tmdbMatching = true;
      _tmdbMessage = null;
    });
    try {
      final updated = await _metadataRepository.match(
        filmId,
        token: token,
        tmdbId: candidate.id,
      );
      if (!mounted || generation != _metadataGeneration) return;
      _updateState(() {
        _film = updated;
        _tmdbCandidates = const [];
        _tmdbTokenController.clear();
        _metadataMessage = '已匹配 TMDB 资料；API 凭据已从页面内存清除。';
        _metadataIsError = false;
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      _updateState(() => _tmdbMessage = '匹配失败：${mediaErrorLabel(error)}');
    } finally {
      if (mounted && generation == _metadataGeneration) {
        _updateState(() => _tmdbMatching = false);
      }
    }
  }

  Widget _metadataMatchingPanel(BuildContext context) {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final busy = _metadataBusy || _tmdbSearching || _tmdbMatching;
    final theme = Theme.of(context);
    return IsleSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('影视资料', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '资料来源可在本地 NFO 和 TMDB 之间手动选择。不会自动联网查询。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () =>
                      unawaited(_markWatched(completed: !_film.completed)),
                  icon: Icon(
                    _film.completed
                        ? Icons.visibility_off_outlined
                        : Icons.check_circle_outline,
                  ),
                  label: Text(_film.completed ? '标记未看' : '标记已看'),
                ),
                if (_film.position > 5 && !_film.completed)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_restartFromBeginning()),
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('从头播放'),
                  ),
                if (_film.isSeries)
                  OutlinedButton.icon(
                    onPressed: _closing || _nextEpisodeBusy
                        ? null
                        : () => unawaited(_goToNextEpisode()),
                    icon: const Icon(Icons.skip_next_rounded),
                    label: Text(_nextEpisodeBusy ? '查找下一集…' : '下一集'),
                  ),
              ],
            ),
          ),
          if (_film.isSeries)
            SwitchListTile.adaptive(
              title: const Text('播完自动下一集'),
              subtitle: const Text('默认关闭；先保存本集进度，再开始下一集。'),
              value: _autoPlayNext,
              onChanged: _setAutoplayNext,
              contentPadding: EdgeInsets.zero,
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: busy ? null : _importLocalNfo,
              icon: _metadataBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.description_outlined),
              label: const Text('导入本地 NFO 资料'),
            ),
          ),
          if (_metadataMessage != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: _metadataMessage!,
              icon: _metadataIsError
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              isError: _metadataIsError,
            ),
          ],
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Text('TMDB 在线匹配（自愿联网）', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            '只有点击“搜索 TMDB”或确认匹配时，令牌和请求才会发送到当前 LightIsle 服务器，由服务器联系 TMDB。令牌仅保存在当前页面内存，不写入 LightIsle 数据库；关闭详情页会清除令牌。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'This product uses the TMDB API but is not endorsed or certified by TMDB.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tmdbTokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'TMDB API Read Access Token',
              hintText: '仅为本次手动匹配提供',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.key_outlined),
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                controller: _tmdbQueryController,
                maxLength: 120,
                enabled: !busy,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_searchTmdb()),
                decoration: const InputDecoration(
                  labelText: '影视名称',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                  counterText: '',
                ),
              );
              final button = FilledButton.icon(
                onPressed: busy ? null : _searchTmdb,
                icon: _tmdbSearching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore_outlined),
                label: Text(_tmdbSearching ? '搜索中…' : '搜索 TMDB'),
              );
              if (constraints.maxWidth < 460) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [field, const SizedBox(height: 8), button],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: button,
                  ),
                ],
              );
            },
          ),
          if (_tmdbMessage != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: _tmdbMessage!,
              icon: Icons.info_outline,
              isError:
                  _tmdbCandidates.isEmpty &&
                  !_tmdbSearching &&
                  _tmdbMessage!.startsWith('搜索失败'),
            ),
          ],
          if (_tmdbCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final candidate in _tmdbCandidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _tmdbCandidateCard(candidate, busy),
              ),
          ],
        ],
      ),
    );
  }

  Widget _tmdbCandidateCard(TMDBCandidate candidate, bool busy) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Text(
            '${candidate.title}${candidate.year.isEmpty ? '' : ' (${candidate.year})'}',
            style: theme.textTheme.titleSmall,
          );
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
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
            onPressed: busy ? null : () => _matchTmdb(candidate),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('选择匹配'),
          );
          if (constraints.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [description, const SizedBox(height: 8), matchButton],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: description),
              const SizedBox(width: 8),
              matchButton,
            ],
          );
        },
      ),
    );
  }

  Widget _metadata(BuildContext context) {
    final format = <String>[
      _film.container.toUpperCase(),
      _film.videoCodec.toUpperCase(),
      _film.audioCodec.toUpperCase(),
    ].where((value) => value.isNotEmpty).join(' · ');
    final rows = <(IconData, String, String)>[
      (
        Icons.video_library_outlined,
        '类型',
        _film.isSeries
            ? '剧集 · 第 ${_film.season} 季 · 第 ${_film.episode} 集'
            : _film.year > 0
            ? '电影 · ${_film.year}'
            : '电影',
      ),
      (Icons.storage_outlined, '文件大小', formatMediaSize(_film.size)),
      (
        Icons.schedule_outlined,
        '时长',
        formatMediaSeconds(
          _film.durationSeconds > 0 ? _film.durationSeconds : _film.duration,
        ),
      ),
      if (_film.width > 0 && _film.height > 0)
        (
          Icons.aspect_ratio_outlined,
          '画面尺寸',
          '${_film.width} × ${_film.height}',
        ),
      if (format.isNotEmpty) (Icons.movie_outlined, '编码格式', format),
      if (_film.mime.isNotEmpty)
        (Icons.insert_drive_file_outlined, '媒体类型', _film.mime),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        for (final row in rows)
          SizedBox(
            width: 230,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  row.$1,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.$2,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(row.$3),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
