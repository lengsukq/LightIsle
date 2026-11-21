part of 'cinema_page.dart';

extension _CinemaPageHomeRails on _CinemaPageState {
  Widget _featuredFilmBanner() {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 3.0)
        .toDouble();
    if (screenWidth < 420 && textScale > 1.5) return const SizedBox.shrink();
    final film = _catalog.resumeShelf.isNotEmpty
        ? _catalog.resumeShelf.first
        : _catalog.recentShelf.isNotEmpty
        ? _catalog.recentShelf.first
        : _catalog.films.isNotEmpty
        ? _catalog.films.first
        : null;
    if (film == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final wide = screenWidth >= 600;
    final desktop = screenWidth >= 1024;
    final matchScore = film.rating > 0
        ? (film.rating * 10).round().clamp(78, 99)
        : 0;
    final showSidePoster = wide || screenWidth >= 340;
    final posterWidth = desktop ? 176.0 : (wide ? 148.0 : 96.0);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _pageInset,
        4,
        _pageInset,
        desktop ? 18 : (wide ? 14 : 10),
      ),
      child: Container(
        key: const ValueKey('cinemaFeaturedBanner'),
        constraints: showSidePoster
            ? BoxConstraints(
                minHeight: (desktop ? 248 : (wide ? 210 : 152)) + 170 * (textScale - 1),
              )
            : null,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: wide ? IsleRadius.brHero : IsleRadius.brCard,
          border: Border.all(
            color: const Color(0xFFE07A56).withValues(alpha: 0.24),
            width: 1.0,
          ),
          gradient: const LinearGradient(
            colors: [Color(0xFF141318), Color(0xFF1E1A1E), Color(0xFF281D1B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x52000000),
              blurRadius: 26,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openFilm(film),
            child: Stack(
              children: [
                Positioned(
                  right: -40,
                  top: -40,
                  bottom: -40,
                  width: desktop ? 420 : 240,
                  child: Opacity(
                    opacity: desktop ? 0.16 : 0.11,
                    child: CinemaPosterImage.film(
                      api: widget.api,
                      film: film,
                      memoryCache: _posterCache,
                      fit: BoxFit.cover,
                      maxBytes: 4 * 1024 * 1024,
                      loadingBuilder: (_) => const SizedBox.shrink(),
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                if (showSidePoster)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: posterWidth,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CinemaPosterImage.film(
                          api: widget.api,
                          film: film,
                          memoryCache: _posterCache,
                          fit: BoxFit.cover,
                          maxBytes: 4 * 1024 * 1024,
                          loadingBuilder: (_) => _continuePlaceholder(),
                          errorBuilder: (_, _, retry) => InkWell(
                            onTap: retry,
                            child: _continuePlaceholder(),
                          ),
                        ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              stops: [0.68, 1.0],
                              colors: [Colors.transparent, Color(0xFF18161A)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.only(left: showSidePoster ? posterWidth : 0),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: desktop ? 28 : (wide ? 20 : 16),
                      vertical: desktop ? 22 : (wide ? 16 : 14),
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
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD95A38),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                film.canResume ? '继续放映' : '剧场银幕精选',
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
                                  color: const Color(0xFFF4C165),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                          ],
                        ),
                        SizedBox(height: desktop ? 10 : 7),
                        Text(
                          film.displayTitle,
                          maxLines: wide ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (desktop
                                      ? theme.textTheme.headlineMedium
                                      : wide
                                      ? theme.textTheme.titleLarge
                                      : theme.textTheme.titleMedium)
                                  ?.copyWith(
                                    color: const Color(0xFFF6F3EC),
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.45,
                                  ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          [
                            if (film.year > 0) '${film.year}',
                            film.isSeries
                                ? (formatCinemaSeasonEpisodeCode(
                                        film,
                                      ).isNotEmpty
                                      ? formatCinemaSeasonEpisodeCode(film)
                                      : '剧集')
                                : '电影',
                            if (film.duration > 0)
                              formatMediaSeconds(film.duration),
                            if (film.videoCodec.isNotEmpty)
                              film.videoCodec.toUpperCase(),
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFC8C2B8),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (film.overview.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 680),
                            child: Text(
                              film.overview,
                              maxLines: desktop ? 3 : (wide ? 2 : 1),
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFFB5AFA4),
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                        SizedBox(height: desktop ? 14 : 11),
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFF6F3EC),
                                foregroundColor: const Color(0xFF141316),
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 9,
                                ),
                              ),
                              onPressed: () => _openFilmPlayer(film),
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 18,
                              ),
                              label: Text(
                                film.canResume
                                    ? formatCinemaResumeCtaLabel(film)
                                    : '立即放映',
                              ),
                            ),
                            OutlinedButton.icon(
                              key: const ValueKey('cinemaFeaturedDetails'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFF6F3EC),
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.24),
                                ),
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 9,
                                ),
                              ),
                              onPressed: () => _openFilmDetails(film),
                              icon: const Icon(
                                Icons.info_outline_rounded,
                                size: 17,
                              ),
                              label: const Text('详情与简介'),
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
    if (_catalog.mode != 'all' ||
        !shouldShowCinemaDiscoveryRails(
          _catalog.films.length,
          _catalog.nextCursor,
        )) {
      return const SizedBox.shrink();
    }
    final ranked = _catalog.films.where((f) => f.rating >= 7.0).toList()
      ..sort((a, b) => b.rating.compareTo(a.rating));
    if (ranked.length < 2) return const SizedBox.shrink();
    final top = ranked.take(10).toList();
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 2, 0, compact ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4C165).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: const Color(0xFFF4C165).withValues(alpha: 0.35),
                    ),
                  ),
                  child: const Text(
                    'TOP 10',
                    style: TextStyle(
                      color: Color(0xFFF4C165),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '高分口碑典藏',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: compact ? 168 : 202,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: top.length,
              separatorBuilder: (_, _) => SizedBox(width: compact ? 10 : 14),
              itemBuilder: (context, index) {
                final film = top[index];
                return InkWell(
                  borderRadius: IsleRadius.brSm,
                  onTap: () => _openFilm(film),
                  child: SizedBox(
                    width: compact ? 140 : 170,
                    child: Stack(
                      alignment: Alignment.bottomLeft,
                      children: [
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          width: compact ? 108 : 130,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: IsleRadius.brSm,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.14),
                                width: 1.0,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: CinemaPosterImage.film(
                              api: widget.api,
                              film: film,
                              memoryCache: _posterCache,
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
                              fontSize: compact ? 64 : 82,
                              height: 1.0,
                              fontWeight: FontWeight.w900,
                              color: const Color(
                                0xFFF4C165,
                              ).withValues(alpha: 0.86),
                              shadows: const [
                                Shadow(color: Color(0xDD0D0D10), blurRadius: 9),
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
    if (_catalog.mode != 'all') return const SizedBox.shrink();
    final films =
        (_catalog.shelvesLoaded
                ? _catalog.resumeShelf
                : _catalog.films.where((film) => film.canResume).toList())
            .take(6)
            .toList();
    if (films.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.5)
        .toDouble();
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 2, 0, compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 18, bottom: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _changeMode('continue'),
                  child: const Text('查看全部'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: (compact ? 142 : 158) + 84 * (textScale - 1),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: films.length,
              separatorBuilder: (_, _) => const SizedBox(width: 11),
              itemBuilder: (context, index) {
                final film = films[index];
                final progress = film.duration > 0
                    ? (film.position / film.duration).clamp(0.0, 1.0).toDouble()
                    : 0.0;
                return Container(
                  width: (compact ? 256 : 292) + 74 * (textScale - 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF19181D),
                    borderRadius: IsleRadius.brMd,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.11),
                      width: 1.0,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _openFilmPlayer(film),
                      child: Row(
                        children: [
                          SizedBox(
                            width: compact ? 88 : 104,
                            height: double.infinity,
                            child: CinemaPosterImage.film(
                              api: widget.api,
                              film: film,
                              memoryCache: _posterCache,
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
                              padding: EdgeInsets.all(compact ? 10 : 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          film.displayTitle,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                color: const Color(0xFFF6F3EC),
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      IconButton(
                                        key: ValueKey(
                                          'cinemaContinueRemove_${film.id}',
                                        ),
                                        tooltip: '移出继续观看',
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 26,
                                          minHeight: 26,
                                        ),
                                        onPressed: () =>
                                            unawaited(_clearFilmProgress(film)),
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 15,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Spacer(),
                                  Text(
                                    film.isSeries
                                        ? '${formatCinemaSeasonEpisodeCode(film)} · 第 ${film.season} 季第 ${film.episode} 集'
                                        : '继续放映',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFFB5AFA4),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Builder(
                                    builder: (_) {
                                      final remaining =
                                          formatCinemaRemainingText(film);
                                      return Text(
                                        remaining.isEmpty
                                            ? '已看 ${formatMediaSeconds(film.position)}'
                                            : '剩余 $remaining',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: const Color(0xFFC8C2B8),
                                            ),
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 3.5,
                                      backgroundColor: Colors.white24,
                                      color: const Color(0xFFD95A38),
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
    if (_catalog.recentShelf.isEmpty ||
        !shouldShowCinemaDiscoveryRails(
          _catalog.films.length,
          _catalog.nextCursor,
        )) {
      return const SizedBox.shrink();
    }
    final duplicateKeys = duplicateCinemaTitleKeys(_catalog.recentShelf);
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.5)
        .toDouble();
    final cardWidth = compact && textScale <= 1.25 ? 128.0 : 156.0;
    final footerHeight = 98 * textScale + 16;
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 4, 0, compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '最近添加',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox(
            height: cardWidth * 1.5 + footerHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: _catalog.recentShelf.length,
              separatorBuilder: (_, _) => SizedBox(width: compact ? 10 : 12),
              itemBuilder: (context, index) {
                final film = _catalog.recentShelf[index];
                return SizedBox(
                  width: cardWidth,
                  child: CinemaFilmTile(
                    api: widget.api,
                    memoryCache: _posterCache,
                    enableHero: false,
                    film: film,
                    folderBadge: cinemaDisambiguationBadge(film, duplicateKeys),
                    isAdmin: widget.isAdmin,
                    selecting: false,
                    selected: false,
                    onToggle: () => _toggleFilmSelection(film),
                    onOpen: () => _openFilm(film),
                    onDetails: () => _openFilmDetails(film),
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

  Widget _continuePlaceholder() => const ColoredBox(
    color: Color(0xFF1F1E24),
    child: Center(
      child: Icon(Icons.movie_outlined, size: 26, color: Colors.white54),
    ),
  );
}
