part of 'cinema_detail_dialog.dart';

extension _CinemaDetailMetadata on _CinemaDetailDialogState {
  Future<void> _importLocalNfo() async {
    if (!widget.isAdmin ||
        _metaMatch.busy ||
        _metaMatch.tmdbSearching ||
        _metaMatch.tmdbMatching) {
      return;
    }
    final generation = ++_metaMatch.generation;
    final filmId = _film.id;
    _updateState(() {
      _metaMatch.busy = true;
      _metaMatch.message = null;
      _metaMatch.isError = false;
    });
    try {
      final updated = await _metadataRepository.importNfo(filmId);
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(() {
        _film = updated;
        _metaMatch.message = '已导入本地 NFO 资料，原视频和观看进度未修改。';
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(() {
        _metaMatch.message = mediaErrorLabel(error);
        _metaMatch.isError = true;
      });
    } finally {
      if (mounted && generation == _metaMatch.generation) {
        _updateState(() => _metaMatch.busy = false);
      }
    }
  }

  Future<void> _searchTmdb() async {
    if (!widget.isAdmin ||
        _metaMatch.busy ||
        _metaMatch.tmdbSearching ||
        _metaMatch.tmdbMatching) {
      return;
    }
    final token = _metaMatch.tmdbTokenController.text.trim();
    final query = _metaMatch.tmdbQueryController.text.trim();
    if (query.isEmpty) {
      _updateState(() {
        _metaMatch.tmdbMessage = '请输入影视名称搜索关键词。';
      });
      return;
    }
    if (token.isNotEmpty &&
        (token.length < 20 ||
            token.length > 2048 ||
            RegExp(r'\s').hasMatch(token))) {
      _updateState(() {
        _metaMatch.tmdbMessage =
            '填写的 TMDB Read Access Token 格式无效（留空可直接使用 Mac 端已配置的 Token）。';
      });
      return;
    }
    final generation = ++_metaMatch.generation;
    final filmId = _film.id;
    _updateState(() {
      _metaMatch.tmdbSearching = true;
      _metaMatch.tmdbCandidates = const [];
      _metaMatch.tmdbMessage = null;
    });
    try {
      final candidates = await _metadataRepository.search(
        filmId,
        token: token,
        query: query,
      );
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(() {
        _metaMatch.tmdbCandidates = candidates;
        if (candidates.isEmpty) {
          _metaMatch.tmdbMessage = '没有找到相关影视资料，可以调整关键词后再搜索。';
        }
      });
    } catch (error) {
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(
        () => _metaMatch.tmdbMessage = '搜索失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (mounted && generation == _metaMatch.generation) {
        _updateState(() => _metaMatch.tmdbSearching = false);
      }
    }
  }

  Future<void> _matchTmdb(TMDBCandidate candidate) async {
    if (!widget.isAdmin ||
        _metaMatch.busy ||
        _metaMatch.tmdbSearching ||
        _metaMatch.tmdbMatching) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
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
    final token = _metaMatch.tmdbTokenController.text.trim();
    if (token.isNotEmpty &&
        (token.length < 20 ||
            token.length > 2048 ||
            RegExp(r'\s').hasMatch(token))) {
      _updateState(() {
        _metaMatch.tmdbMessage =
            '填写的 TMDB Read Access Token 格式无效（留空可直接使用 Mac 端已配置的 Token）。';
      });
      return;
    }
    final hadPageToken = token.isNotEmpty;
    final generation = ++_metaMatch.generation;
    final filmId = _film.id;
    _updateState(() {
      _metaMatch.tmdbMatching = true;
      _metaMatch.tmdbMessage = null;
    });
    try {
      final updated = await _metadataRepository.match(
        filmId,
        token: token,
        tmdbId: candidate.id,
      );
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(() {
        _film = updated;
        _metaMatch.tmdbCandidates = const [];
        _metaMatch.tmdbTokenController.clear();
        _metaMatch.message = hadPageToken
            ? '已匹配 TMDB 资料；页面输入的临时凭据已清除。'
            : '已匹配 TMDB 资料。';
        _metaMatch.isError = false;
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(
        () => _metaMatch.tmdbMessage = '匹配失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (mounted && generation == _metaMatch.generation) {
        _updateState(() => _metaMatch.tmdbMatching = false);
      }
    }
  }

  Future<void> _searchDouban() async {
    if (!widget.isAdmin || _metaMatch.isAnyBusy) return;
    final query = _metaMatch.tmdbQueryController.text.trim();
    if (query.runes.length < 2) {
      _updateState(() {
        _metaMatch.doubanMessage = '请输入至少 2 个字符的影视名称进行豆瓣搜索。';
      });
      return;
    }
    final generation = ++_metaMatch.generation;
    final filmId = _film.id;
    _updateState(() {
      _metaMatch.doubanSearching = true;
      _metaMatch.doubanCandidates = const [];
      _metaMatch.doubanMessage = null;
    });
    try {
      final results = await _metadataRepository.searchDouban(
        filmId,
        query: query,
      );
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(() {
        _metaMatch.doubanCandidates = results;
        if (results.isEmpty) {
          _metaMatch.doubanMessage = '豆瓣未返回匹配条目，可尝试调整关键词或使用 TMDB 搜索。';
        }
      });
    } catch (error) {
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(
        () => _metaMatch.doubanMessage = '豆瓣搜索失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (mounted && generation == _metaMatch.generation) {
        _updateState(() => _metaMatch.doubanSearching = false);
      }
    }
  }

  Future<void> _matchDouban(DoubanCandidate candidate) async {
    if (!widget.isAdmin || _metaMatch.isAnyBusy) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        title: const Text('确认匹配豆瓣资料？'),
        content: Text(
          '将“${candidate.title}”的豆瓣资料匹配到“${_film.title}”。手动设置的影片名称会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认匹配'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final generation = ++_metaMatch.generation;
    final filmId = _film.id;
    _updateState(() {
      _metaMatch.busy = true;
      _metaMatch.doubanMessage = null;
    });
    try {
      final updated = await _metadataRepository.matchDouban(
        filmId,
        query: _metaMatch.tmdbQueryController.text.trim(),
        doubanId: candidate.id,
      );
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(() {
        _film = updated;
        _metaMatch.doubanCandidates = const [];
        _metaMatch.message = '已匹配豆瓣资料。';
        _metaMatch.isError = false;
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metaMatch.generation) return;
      _updateState(
        () => _metaMatch.doubanMessage = '匹配失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (mounted && generation == _metaMatch.generation) {
        _updateState(() => _metaMatch.busy = false);
      }
    }
  }

  Widget _metadataMatchingPanel(BuildContext context) {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final busy = _metaMatch.isAnyBusy;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return IsleSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '影视资料',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '资料来源可在本地 NFO 和 TMDB 之间手动选择。不会自动联网查询。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _buildPlaybackQuickActions(busy: busy),
          if (_metaMatch.message != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: _metaMatch.message!,
              icon: _metaMatch.isError
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              isError: _metaMatch.isError,
            ),
          ],
          const SizedBox(height: 14),
          Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
          const SizedBox(height: 14),
          _buildTmdbSearchSection(theme, busy: busy),
          const SizedBox(height: 14),
          Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
          const SizedBox(height: 14),
          _buildDoubanSearchSection(theme, busy: busy),
        ],
      ),
    );
  }

  Widget _buildPlaybackQuickActions({required bool busy}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () =>
                    unawaited(_markWatched(completed: !_film.completed)),
                icon: Icon(
                  _film.completed
                      ? Icons.visibility_off_outlined
                      : Icons.check_circle_outline,
                  size: 17,
                ),
                label: Text(_film.completed ? '标记未看' : '标记已看'),
              ),
              if (_film.position > 5 && !_film.completed)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => unawaited(_restartFromBeginning()),
                  icon: const Icon(Icons.replay_rounded, size: 17),
                  label: const Text('从头播放'),
                ),
              if (_film.isSeries)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _playback.closing || _playlistState.nextEpisodeBusy
                      ? null
                      : () => unawaited(_goToNextEpisode()),
                  icon: const Icon(Icons.skip_next_rounded, size: 17),
                  label: Text(
                    _playlistState.nextEpisodeBusy ? '查找下一集…' : '下一集',
                  ),
                ),
            ],
          ),
        ),
        if (_film.isSeries)
          SwitchListTile.adaptive(
            dense: true,
            title: const Text('播完自动下一集'),
            subtitle: const Text('默认关闭；先保存本集进度，再开始下一集。'),
            value: _playlistState.autoPlayNext,
            onChanged: _setAutoplayNext,
            contentPadding: EdgeInsets.zero,
          ),
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: busy ? null : _importLocalNfo,
            icon: _metaMatch.busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.description_outlined, size: 17),
            label: const Text('导入本地 NFO 资料'),
          ),
        ),
      ],
    );
  }

  Widget _buildTmdbSearchSection(ThemeData theme, {required bool busy}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'TMDB 在线匹配（自愿联网）',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
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
          controller: _metaMatch.tmdbTokenController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: 'TMDB API Read Access Token（可选）',
            hintText: '留空将默认使用 Mac 端已配置的 Token',
            isDense: true,
            prefixIcon: Icon(Icons.key_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 10),
        _buildResponsiveQueryRow(
          labelText: '影视名称',
          prefixIcon: Icons.search,
          busy: busy,
          onSubmitted: () => unawaited(_searchTmdb()),
          button: FilledButton.icon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: busy ? null : _searchTmdb,
            icon: _metaMatch.tmdbSearching
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.travel_explore_outlined, size: 17),
            label: Text(_metaMatch.tmdbSearching ? '搜索中…' : '搜索 TMDB'),
          ),
        ),
        if (_metaMatch.tmdbMessage != null) ...[
          const SizedBox(height: 8),
          MediaStatusBanner(
            message: _metaMatch.tmdbMessage!,
            icon: Icons.info_outline,
            isError:
                _metaMatch.tmdbCandidates.isEmpty &&
                !_metaMatch.tmdbSearching &&
                _metaMatch.tmdbMessage!.startsWith('搜索失败'),
          ),
        ],
        if (_metaMatch.tmdbCandidates.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final candidate in _metaMatch.tmdbCandidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _tmdbCandidateCard(candidate, busy),
            ),
        ],
      ],
    );
  }

  Widget _buildDoubanSearchSection(ThemeData theme, {required bool busy}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '豆瓣快捷匹配（免凭据）',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '无需 TMDB 令牌，直接使用豆瓣公共条目快捷匹配封面海报与基本信息。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        _buildResponsiveQueryRow(
          labelText: '影视片名关键词',
          prefixIcon: Icons.search_rounded,
          busy: busy,
          onSubmitted: () => unawaited(_searchDouban()),
          button: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: busy ? null : _searchDouban,
            icon: _metaMatch.doubanSearching
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.movie_filter_outlined, size: 17),
            label: Text(_metaMatch.doubanSearching ? '搜索中…' : '搜索豆瓣（免凭据）'),
          ),
        ),
        if (_metaMatch.doubanMessage != null) ...[
          const SizedBox(height: 8),
          MediaStatusBanner(
            message: _metaMatch.doubanMessage!,
            icon: Icons.info_outline,
            isError:
                _metaMatch.doubanCandidates.isEmpty &&
                !_metaMatch.doubanSearching &&
                _metaMatch.doubanMessage!.startsWith('豆瓣搜索失败'),
          ),
        ],
        if (_metaMatch.doubanCandidates.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final candidate in _metaMatch.doubanCandidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _doubanCandidateCard(candidate, busy),
            ),
        ],
      ],
    );
  }

  Widget _buildResponsiveQueryRow({
    required String labelText,
    required IconData prefixIcon,
    required bool busy,
    required VoidCallback onSubmitted,
    required Widget button,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = TextField(
          controller: _metaMatch.tmdbQueryController,
          maxLength: 120,
          enabled: !busy,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSubmitted(),
          decoration: InputDecoration(
            labelText: labelText,
            isDense: true,
            prefixIcon: Icon(prefixIcon, size: 18),
            counterText: '',
          ),
        );
        if (constraints.maxWidth < 460) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [field, const SizedBox(height: 8), button],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: field),
            const SizedBox(width: 10),
            button,
          ],
        );
      },
    );
  }

  Widget _doubanCandidateCard(DoubanCandidate candidate, bool busy) {
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
            onPressed: busy ? null : () => unawaited(_matchDouban(candidate)),
            child: const Text('应用资料'),
          ),
        ],
      ),
    );
  }

  Widget _tmdbCandidateCard(TMDBCandidate candidate, bool busy) {
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
            onPressed: busy ? null : () => _matchTmdb(candidate),
            icon: const Icon(Icons.check_circle_outline, size: 17),
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
