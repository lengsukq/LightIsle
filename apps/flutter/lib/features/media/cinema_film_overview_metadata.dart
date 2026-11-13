part of 'cinema_film_overview.dart';

extension _CinemaFilmOverviewMetadata on _CinemaFilmOverviewState {
  Future<void> _importLocalNfo() async {
    if (!widget.isAdmin || _metadataBusy) return;
    _updateState(() {
      _metadataBusy = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final updated = await _metadataRepository.importNfo(_film.id);
      _applyUpdatedFilm(updated, '已导入本地 NFO 资料。');
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _statusMessage = mediaErrorLabel(error);
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _metadataBusy = false);
    }
  }

  Future<void> _searchDouban() async {
    if (!widget.isAdmin || _metadataBusy || _doubanSearching) return;
    final query = _queryController.text.trim();
    if (query.runes.length < 2) {
      _updateState(() {
        _statusMessage = '请输入至少 2 个字符的影视名称进行豆瓣搜索。';
        _statusIsError = true;
      });
      return;
    }
    _updateState(() {
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
      _updateState(() {
        _doubanCandidates = results;
        if (results.isEmpty) {
          _statusMessage = '豆瓣未返回匹配条目，可尝试调整关键词或使用 TMDB 搜索。';
        }
      });
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _statusMessage = '豆瓣搜索失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _doubanSearching = false);
    }
  }

  Future<void> _matchDouban(DoubanCandidate candidate) async {
    if (!widget.isAdmin || _metadataBusy) return;
    _updateState(() {
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
        _updateState(() {
          _statusMessage = '豆瓣匹配失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _metadataBusy = false);
    }
  }

  Future<void> _searchTmdb() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching) return;
    final token = _tmdbTokenController.text.trim();
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      _updateState(() {
        _statusMessage = '请填写影视名称后再搜索 TMDB。';
        _statusIsError = true;
      });
      return;
    }
    _updateState(() {
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
      _updateState(() {
        _tmdbCandidates = results;
        if (results.isEmpty) {
          _statusMessage = '没有找到相关 TMDB 资料，请调整关键词后重试。';
        }
      });
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _statusMessage = 'TMDB 搜索失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _tmdbSearching = false);
    }
  }

  Future<void> _matchTmdb(TMDBCandidate candidate) async {
    if (!widget.isAdmin || _metadataBusy) return;
    final token = _tmdbTokenController.text.trim();
    _updateState(() {
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
        _updateState(() {
          _statusMessage = 'TMDB 匹配失败：${mediaErrorLabel(error)}';
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _metadataBusy = false);
    }
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
