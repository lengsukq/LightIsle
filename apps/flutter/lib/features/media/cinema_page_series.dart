part of 'cinema_page.dart';

extension _CinemaPageSeries on _CinemaPageState {
  Future<void> _loadSeries() async {
    if (_subpages.seriesLoading) return;
    _updateState(() {
      _subpages.seriesLoading = true;
      _subpages.seriesError = null;
    });
    try {
      final query = <String, String>{'limit': '60'};
      if (_catalog.query.trim().isNotEmpty) {
        query['query'] = _catalog.query.trim();
      }
      if (_catalog.watched != 'all') query['watched'] = _catalog.watched;
      if (_catalog.sort != 'recent') query['sort'] = _catalog.sort;
      final response = await widget.api.get('/api/v2/series', query: query);
      final items = <CinemaSeriesInfo>[];
      final raw = response['series'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            items.add(
              CinemaSeriesInfo.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      }
      if (!mounted) return;
      _updateState(() {
        _subpages.series
          ..clear()
          ..addAll(items);
        _subpages.seriesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        _subpages.seriesLoading = false;
        _subpages.seriesError = mediaErrorLabel(error);
      });
    }
  }

  Future<CinemaSeriesSnapshot?> _fetchSeriesSnapshot(int seriesId) async {
    try {
      final response = await widget.api.get('/api/v2/series/$seriesId');
      final raw = response['films'];
      final parsed = <CinemaFilm>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            try {
              parsed.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
            } on FormatException {
              // Skip malformed rows while keeping usable episodes.
            }
          }
        }
      }
      CinemaSeriesInfo? seriesInfo;
      final rawSeries = response['series'];
      if (rawSeries is Map) {
        seriesInfo = CinemaSeriesInfo.fromJson(
          Map<String, dynamic>.from(rawSeries),
        );
      }
      return (series: seriesInfo, episodes: parsed);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openSeries(CinemaSeriesInfo series) async {
    HapticFeedback.selectionClick();
    List<CinemaFilm> films = const [];
    var currentSeries = series;
    String? error;
    try {
      final response = await widget.api.get('/api/v2/series/${series.id}');
      final raw = response['films'];
      final parsed = <CinemaFilm>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            try {
              parsed.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
            } on FormatException {
              // Skip malformed rows while keeping usable episodes.
            }
          }
        }
      }
      final rawSeries = response['series'];
      if (rawSeries is Map) {
        currentSeries = CinemaSeriesInfo.fromJson(
          Map<String, dynamic>.from(rawSeries),
        );
      }
      films = parsed;
    } catch (caught) {
      error = mediaErrorLabel(caught);
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      buildIslePageRoute(
        builder: (_) => CinemaSeriesOverview(
          series: currentSeries,
          episodes: films,
          error: error,
          onRefreshEpisodes: () => _fetchSeriesSnapshot(series.id),
          onEpisode: (episode) => _openFilmPlayer(episode, playlist: films),
        ),
      ),
    );
    if (!mounted) return;
    await Future.wait([_loadSeries(), _loadShelves(), _loadFilms(reset: true)]);
  }

  Future<void> _refreshScrape() async {
    try {
      final status = CinemaScrapeStatus.fromJson(
        await widget.api.get('/api/v2/cinema/scrape/status'),
      );
      if (!mounted) return;
      _updateState(() => _indexing.scrapeStatus = status);
    } catch (_) {
      // Status polling is best-effort.
    }
  }

  Future<void> _startScrape() async {
    if (_indexing.scrapeBusy || (_indexing.scrapeStatus?.running ?? false)) {
      return;
    }
    _updateState(() {
      _indexing.scrapeBusy = true;
      _indexing.scrapeMessage = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/cinema/scrape/start',
        body: const <String, Object>{'retryMisses': true},
      );
      if (!mounted) return;
      _updateState(() {
        _indexing.scrapeMessage = '已触发未匹配影片重试刮削。';
      });
      await _refreshScrape();
    } catch (error) {
      if (!mounted) return;
      String message;
      if (error is LightIsleApiException &&
          error.code == 'tmdb_token_not_configured') {
        message = '需要先在 Mac App「偏好与安全」中配置 TMDB Token。';
      } else if (error is LightIsleApiException &&
          error.code == 'scan_running') {
        message = '媒体库扫描正在进行，请稍后再试。';
      } else {
        message = mediaErrorLabel(error);
      }
      _updateState(() => _indexing.scrapeMessage = message);
    } finally {
      if (mounted) _updateState(() => _indexing.scrapeBusy = false);
    }
  }

  Widget _viewChip(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) => MediaFilterChip(
    label: label,
    selected: selected,
    onSelected: onTap,
    icon: icon,
  );

  List<Widget> _seriesView() {
    final theme = Theme.of(context);
    final queryTokens = _catalog.query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    final filteredSeries = queryTokens.isEmpty
        ? _subpages.series
        : _subpages.series
              .where(
                (item) => queryTokens.every(
                  (token) => item.name.toLowerCase().contains(token),
                ),
              )
              .toList();
    return <Widget>[
      if (_subpages.seriesLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 30),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_subpages.seriesError != null)
        MediaStatusBanner(
          message: '剧集库读取失败：${_subpages.seriesError}',
          isError: true,
          icon: Icons.error_outline,
          trailing: TextButton(onPressed: _loadSeries, child: const Text('重试')),
        )
      else if (filteredSeries.isEmpty)
        MediaEmptyState(
          icon: Icons.live_tv_outlined,
          title: _catalog.query.isNotEmpty ? '没有找到匹配的剧集' : '还没有可聚合的剧集',
          message: _catalog.query.isNotEmpty
              ? '请调整搜索关键词后再试。'
              : '将剧集文件（如 Show.S01E01.mkv）加入共享目录并扫描后，这里会按剧名聚合。',
        )
      else
        Padding(
          padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 0),
          child: Builder(
            builder: (context) {
              final width = MediaQuery.sizeOf(context).width;
              final textScale =
                  (MediaQuery.textScalerOf(context).scale(14) / 14)
                      .clamp(1.0, 2.5)
                      .toDouble();
              final crossAxisCount = textScale > 1.35
                  ? (width >= 760 ? 2 : 1)
                  : width >= 900
                  ? 3
                  : width >= 540
                  ? 2
                  : 1;
              return GridView.count(
                crossAxisCount: crossAxisCount,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: textScale > 1.35 ? 2.6 : 3.4,
                children: <Widget>[
                  for (final series in filteredSeries)
                    IsleSurface(
                      margin: EdgeInsets.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      radius: IsleRadius.item,
                      onTap: () => unawaited(_openSeries(series)),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  series.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  series.hasContinue && series.inProgress
                                      ? '继续：${series.nextTitle} · 已看 ${series.watchedCount}/${series.episodeCount} 集'
                                      : '已看 ${series.watchedCount}/${series.episodeCount} 集',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            series.hasContinue && series.inProgress
                                ? Icons.play_circle_outline
                                : Icons.live_tv_outlined,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      if (widget.isAdmin) _adminScrapeBar(),
    ];
  }

  Widget _adminScrapeBar() {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final status = _indexing.scrapeStatus;
    return Padding(
      key: const ValueKey('cinemaAdminScrapeBar'),
      padding: EdgeInsets.fromLTRB(_pageInset, 8, _pageInset, 8),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        radius: IsleRadius.item,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                const Icon(Icons.auto_awesome_rounded, size: 18),
                Text('TMDB 自动刮削', style: theme.textTheme.titleSmall),
                if (status != null &&
                    status.tmdbConfigured &&
                    status.processed > 0)
                  IsleDonutGauge(
                    fraction: (status.matched / status.processed).clamp(
                      0.0,
                      1.0,
                    ),
                    color: const Color(0xFFF97316),
                    size: 30,
                    strokeWidth: 3.5,
                    centerText:
                        '${((status.matched / status.processed).clamp(0.0, 1.0) * 100).round()}%',
                    centerStyle: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    semanticsLabel:
                        'TMDB 刮削已匹配 ${status.matched}/${status.processed}',
                  ),
                if (status == null)
                  TextButton(
                    onPressed: _refreshScrape,
                    child: const Text('查看状态'),
                  )
                else if (!status.tmdbConfigured)
                  Text(
                    '需要在 Mac App「偏好与安全」中配置 TMDB Token 后使用',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else if (status.running)
                  Text(
                    '刮削进行中：已处理 ${status.processed} 项 · 匹配 ${status.matched} 项',
                    style: theme.textTheme.bodySmall,
                  )
                else ...<Widget>[
                  Text(
                    '已默认开启（仅 Mac 端可关闭）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _indexing.scrapeBusy ? null : _startScrape,
                    icon: _indexing.scrapeBusy
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('重试未匹配项'),
                  ),
                ],
              ],
            ),
            if (_indexing.scrapeMessage != null) ...[
              const SizedBox(height: 6),
              Text(_indexing.scrapeMessage!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filmGrid() {
    if (_catalog.films.isEmpty && _catalog.loading) {
      return const SliverToBoxAdapter(
        child: IsleLoadingState(
          padding: EdgeInsets.all(48),
          label: '正在加载私人影院…',
        ),
      );
    }
    if (_catalog.films.isEmpty && _catalog.loadError != null) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.local_movies_outlined,
          title: '暂时无法读取影视库',
          message: _catalog.loadError!,
          action: OutlinedButton.icon(
            onPressed: _catalog.loading ? null : () => _loadFilms(reset: true),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_catalog.films.isEmpty) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.local_movies_outlined,
          title: _catalog.query.isNotEmpty
              ? '没有找到匹配影片'
              : _catalog.mode == 'continue'
              ? '没有待续播的影片'
              : '影视库还没有影片',
          message: _catalog.query.isNotEmpty
              ? '调整关键词后再搜索。'
              : '点击上传，把设备上的视频保存到 NAS。',
          action: _catalog.query.isEmpty
              ? FilledButton.icon(
                  onPressed: _upload,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('上传视频'),
                )
              : null,
        ),
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
            .clamp(1.0, 2.5)
            .toDouble();
        final width = constraints.crossAxisExtent;
        final columns = textScale > 1.25
            ? (width / 176).floor().clamp(2, 6).toInt()
            : width < 340
            ? 2
            : width < 600
            ? (width / 112).floor().clamp(3, 4).toInt()
            : width < 1024
            ? (width / 145).floor().clamp(4, 6).toInt()
            : (width / 160).floor().clamp(6, 8).toInt();
        final crossSpacing = width < 600 ? 8.0 : 12.0;
        final mainSpacing = width < 600 ? 10.0 : 14.0;
        final posterWidth =
            (width - _pageInset * 2 - (columns - 1) * crossSpacing) / columns;
        final footerHeight = 88 * textScale + 12;
        final duplicateKeys = duplicateCinemaTitleKeys(_catalog.films);
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(_pageInset, 2, _pageInset, 0),
          sliver: SliverGrid.builder(
            itemCount: _catalog.films.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: crossSpacing,
              mainAxisSpacing: mainSpacing,
              mainAxisExtent: posterWidth * 1.5 + footerHeight,
            ),
            itemBuilder: (context, index) {
              final film = _catalog.films[index];
              return CinemaFilmTile(
                api: widget.api,
                memoryCache: _posterCache,
                film: film,
                folderBadge: cinemaDisambiguationBadge(film, duplicateKeys),
                isAdmin: widget.isAdmin,
                selecting: _selection.selecting,
                selected: _selection.selectedFilmIds.contains(film.id),
                onToggle: () => _toggleFilmSelection(film),
                onOpen: () => _openFilm(film),
                onDetails: () => _openFilmDetails(film),
                onRename: () => _renameFilm(film),
              );
            },
          ),
        );
      },
    );
  }
}
