part of 'cinema_page.dart';

extension _CinemaPageSeries on _CinemaPageState {
  Future<void> _loadSeries() async {
    if (_seriesLoading) return;
    _updateState(() {
      _seriesLoading = true;
      _seriesError = null;
    });
    try {
      final response = await widget.api.get(
        '/api/v2/series',
        query: const <String, String>{'limit': '60'},
      );
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
        _series
          ..clear()
          ..addAll(items);
        _seriesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        _seriesLoading = false;
        _seriesError = mediaErrorLabel(error);
      });
    }
  }

  Future<void> _openSeries(CinemaSeriesInfo series) async {
    HapticFeedback.selectionClick();
    List<CinemaFilm> films = const [];
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
      films = parsed;
    } catch (caught) {
      error = mediaErrorLabel(caught);
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CinemaSeriesOverview(
          series: series,
          episodes: films,
          error: error,
          onEpisode: _openFilmPlayer,
        ),
      ),
    );
  }

  Future<void> _refreshScrape() async {
    try {
      final status = CinemaScrapeStatus.fromJson(
        await widget.api.get('/api/v2/cinema/scrape/status'),
      );
      if (!mounted) return;
      _updateState(() => _scrapeStatus = status);
    } catch (_) {
      // Status polling is best-effort.
    }
  }

  Future<void> _startScrape() async {
    if (_scrapeBusy || (_scrapeStatus?.running ?? false)) return;
    _updateState(() {
      _scrapeBusy = true;
      _scrapeMessage = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/cinema/scrape/start',
        body: <String, Object>{'retryMisses': _scrapeRetryMisses},
      );
      if (!mounted) return;
      _updateState(() {
        _scrapeMessage = '自动刮削已启动；可在任务中心随时取消。';
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
      _updateState(() => _scrapeMessage = message);
    } finally {
      if (mounted) _updateState(() => _scrapeBusy = false);
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
    return <Widget>[
      if (_seriesLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 30),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_seriesError != null)
        MediaStatusBanner(
          message: '剧集库读取失败：$_seriesError',
          isError: true,
          icon: Icons.error_outline,
          trailing: TextButton(onPressed: _loadSeries, child: const Text('重试')),
        )
      else if (_series.isEmpty)
        MediaEmptyState(
          icon: Icons.live_tv_outlined,
          title: '还没有可聚合的剧集',
          message: '将剧集文件（如 Show.S01E01.mkv）加入共享目录并扫描后，这里会按剧名聚合。',
        )
      else
        Padding(
          padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 0),
          child: GridView.count(
            crossAxisCount: MediaQuery.sizeOf(context).width > 720 ? 3 : 1,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 3.4,
            children: <Widget>[
              for (final series in _series)
                IsleSurface(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  radius: 14,
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
                            const SizedBox(height: 3),
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
          ),
        ),
      if (widget.isAdmin) _adminScrapeBar(),
    ];
  }

  Widget _adminScrapeBar() {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('cinemaAdminScrapeBar'),
      padding: EdgeInsets.fromLTRB(_pageInset, 8, _pageInset, 8),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        radius: 14,
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
                if (_scrapeStatus == null)
                  TextButton(
                    onPressed: _refreshScrape,
                    child: const Text('查看状态'),
                  )
                else if (!_scrapeStatus!.tmdbConfigured)
                  Text(
                    '需要在 Mac App「偏好与安全」中配置 TMDB Token 后使用',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else if (_scrapeStatus!.running)
                  Text(
                    '刮削进行中：已处理 ${_scrapeStatus!.processed} 项 · 匹配 ${_scrapeStatus!.matched} 项',
                    style: theme.textTheme.bodySmall,
                  )
                else ...<Widget>[
                  OutlinedButton.icon(
                    onPressed: _scrapeBusy ? null : _startScrape,
                    icon: _scrapeBusy
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('开始自动刮削'),
                  ),
                  FilterChip(
                    label: const Text('重试未匹配项'),
                    selected: _scrapeRetryMisses,
                    onSelected: (value) =>
                        _updateState(() => _scrapeRetryMisses = value),
                  ),
                ],
              ],
            ),
            if (_scrapeMessage != null) ...[
              const SizedBox(height: 6),
              Text(_scrapeMessage!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filmGrid() {
    if (_films.isEmpty && _loading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(56),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_films.isEmpty && _loadError != null) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.local_movies_outlined,
          title: '暂时无法读取影视库',
          message: _loadError!,
          action: OutlinedButton.icon(
            onPressed: _loading ? null : () => _loadFilms(reset: true),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_films.isEmpty) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.local_movies_outlined,
          title: _query.isNotEmpty
              ? '没有找到匹配影片'
              : _mode == 'continue'
              ? '没有待续播的影片'
              : '影视库还没有影片',
          message: _query.isNotEmpty ? '调整关键词后再搜索。' : '点击上传，把设备上的视频保存到 NAS。',
          action: _query.isEmpty
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
        final columns = (width / 176).floor().clamp(2, 8).toInt();
        final posterWidth = (width - 36 - (columns - 1) * 12) / columns;
        // The footer can have title, kind/duration, resume/codec status and
        // an admin edit action. The previous 78px allowance clipped real
        // cards by up to 26px on 320px screens with 200% text.
        final footerHeight = 92 * textScale + 12;
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(_pageInset, 2, _pageInset, 0),
          sliver: SliverGrid.builder(
            itemCount: _films.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 14,
              mainAxisExtent: posterWidth * 1.5 + footerHeight,
            ),
            itemBuilder: (context, index) {
              final film = _films[index];
              return CinemaFilmTile(
                api: widget.api,
                memoryCache: _posterCache,
                film: film,
                isAdmin: widget.isAdmin,
                selecting: _selecting,
                selected: _selectedFilmIds.contains(film.id),
                onToggle: () => _toggleFilmSelection(film),
                onOpen: () => _openFilm(film),
                onRename: () => _renameFilm(film),
              );
            },
          ),
        );
      },
    );
  }

  /// Netflix-inspired featured billboard sourced from the user's NAS library.
  Widget _featuredFilmBanner() {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 3.0)
        .toDouble();
    if (screenWidth < 420 && textScale > 1.5) return const SizedBox.shrink();
    final film = _resumeShelf.isNotEmpty
        ? _resumeShelf.first
        : _recentShelf.isNotEmpty
        ? _recentShelf.first
        : _films.isNotEmpty
        ? _films.first
        : null;
    if (film == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final wide = screenWidth >= 700;
    final matchScore = film.rating > 0
        ? (film.rating * 10).round().clamp(78, 99)
        : 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 6, _pageInset, 22),
      child: Container(
        key: const ValueKey('cinemaFeaturedBanner'),
        height: wide ? 268 + 180 * (textScale - 1) : null,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF0B0D13), Color(0xFF1A1E2B), Color(0xFF281822)],
            begin: Alignment.centerLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openFilm(film),
            child: Row(
              children: [
                if (wide)
                  SizedBox(
                    width: 186,
                    height: double.infinity,
                    child: AuthenticatedMediaImage(
                      api: widget.api,
                      memoryCache: _posterCache,
                      path: '/api/v2/cinema/${film.id}/poster',
                      fit: BoxFit.cover,
                      maxBytes: 4 * 1024 * 1024,
                      loadingBuilder: (_) => _continuePlaceholder(),
                      errorBuilder: (_, _, retry) =>
                          InkWell(onTap: retry, child: _continuePlaceholder()),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: wide ? 28 : 18,
                      vertical: wide ? 22 : 18,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE50914),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                film.canResume ? '继续观看' : '私人影院精选',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            if (matchScore > 0)
                              Text(
                                '$matchScore% 推荐 · ★ ${film.rating.toStringAsFixed(1)}',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: const Color(0xFF46D369),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          film.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (wide
                                      ? theme.textTheme.headlineMedium
                                      : theme.textTheme.titleLarge)
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (film.year > 0) '${film.year}',
                            film.isSeries ? '剧集' : '电影',
                            if (film.duration > 0)
                              formatMediaSeconds(film.duration),
                            if (film.videoCodec.isNotEmpty)
                              film.videoCodec.toUpperCase(),
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                        if (film.overview.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            film.overview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF0B0D13),
                              ),
                              onPressed: () => _openFilmPlayer(film),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(film.canResume ? '继续播放' : '播放'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _openFilm(film),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                              ),
                              icon: const Icon(Icons.info_outline_rounded),
                              label: const Text('影片详情'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topRatedRail() {
    if (_mode != 'all') return const SizedBox.shrink();
    final ranked = _films.where((f) => f.rating >= 7.0).toList()
      ..sort((a, b) => b.rating.compareTo(a.rating));
    if (ranked.length < 2) return const SizedBox.shrink();
    final top = ranked.take(10).toList();
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 4, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE50914),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    'TOP 10',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('高分口碑精选', style: theme.textTheme.titleLarge),
              ],
            ),
          ),
          SizedBox(
            height: 210,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: top.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final film = top[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _openFilm(film),
                  child: SizedBox(
                    width: 176,
                    child: Stack(
                      alignment: Alignment.bottomLeft,
                      children: [
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          width: 132,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: AuthenticatedMediaImage(
                              api: widget.api,
                              memoryCache: _posterCache,
                              path: '/api/v2/cinema/${film.id}/poster',
                              maxBytes: 4 * 1024 * 1024,
                              fit: BoxFit.cover,
                              loadingBuilder: (_) => _continuePlaceholder(),
                              errorBuilder: (_, _, retry) => InkWell(
                                onTap: retry,
                                child: _continuePlaceholder(),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          bottom: -8,
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 86,
                              height: 1.0,
                              fontWeight: FontWeight.w900,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.82,
                              ),
                              shadows: [
                                Shadow(
                                  color: theme.colorScheme.surface,
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _continueWatchingRail() {
    if (_mode != 'all') return const SizedBox.shrink();
    final films =
        (_shelvesLoaded
                ? _resumeShelf
                : _films.where((film) => film.canResume).toList())
            .take(6)
            .toList();
    if (films.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.5)
        .toDouble();
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 10, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 18, bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () => _changeMode('continue'),
                  child: const Text('查看全部'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 164 + 76 * (textScale - 1),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: films.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final film = films[index];
                final progress = film.duration > 0
                    ? (film.position / film.duration).clamp(0.0, 1.0).toDouble()
                    : 0.0;
                return SizedBox(
                  width: 292 + 76 * (textScale - 1),
                  child: Material(
                    color: const Color(0xff171d29),
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _openFilmPlayer(film),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 112,
                            height: double.infinity,
                            child: AuthenticatedMediaImage(
                              api: widget.api,
                              memoryCache: _posterCache,
                              path: '/api/v2/cinema/${film.id}/poster',
                              maxBytes: 4 * 1024 * 1024,
                              fit: BoxFit.cover,
                              loadingBuilder: (_) => _continuePlaceholder(),
                              errorBuilder: (_, _, retry) => InkWell(
                                onTap: retry,
                                child: _continuePlaceholder(),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    film.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    film.isSeries
                                        ? '第 ${film.season} 季 · 第 ${film.episode} 集'
                                        : '继续播放',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '剩余 ${formatMediaSeconds((film.duration - film.position).clamp(0, double.infinity).toDouble())}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 4,
                                      backgroundColor: Colors.white24,
                                      color: const Color(0xFFE50914),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentlyAddedRail() {
    if (_recentShelf.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.5)
        .toDouble();
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 6, 0, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('最近添加', style: theme.textTheme.titleLarge),
          ),
          SizedBox(
            // Match CinemaFilmTile's 2:3 cover plus its scaled footer. A
            // fixed-height shelf clipped at 200% accessibility text size.
            height: 240 + 92 * textScale + 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: _recentShelf.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final film = _recentShelf[index];
                return SizedBox(
                  width: 160,
                  child: CinemaFilmTile(
                    api: widget.api,
                    memoryCache: _posterCache,
                    enableHero: false,
                    film: film,
                    isAdmin: widget.isAdmin,
                    selecting: false,
                    selected: false,
                    onToggle: () => _toggleFilmSelection(film),
                    onOpen: () => _openFilm(film),
                    onRename: () => _renameFilm(film),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _continuePlaceholder() => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: const Center(child: Icon(Icons.movie_outlined, size: 26)),
  );
}
