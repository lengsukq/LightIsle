part of 'cinema_page.dart';

extension _CinemaPageHomeRails on _CinemaPageState {
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
    final wide = screenWidth >= 600;
    final matchScore = film.rating > 0
        ? (film.rating * 10).round().clamp(78, 99)
        : 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 4, _pageInset, wide ? 16 : 12),
      child: Container(
        key: const ValueKey('cinemaFeaturedBanner'),
        height: wide ? 228 + 160 * (textScale - 1) : null,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(wide ? 20 : 16),
          gradient: const LinearGradient(
            colors: [Color(0xFF0B0D13), Color(0xFF1A1E2B), Color(0xFF281822)],
            begin: Alignment.centerLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 16,
              offset: const Offset(0, 6),
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
                    width: 156,
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
                      horizontal: wide ? 22 : 14,
                      vertical: wide ? 16 : 12,
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
                                vertical: 2,
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
                        const SizedBox(height: 6),
                        Text(
                          film.title,
                          maxLines: wide ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (wide
                                      ? theme.textTheme.headlineSmall
                                      : theme.textTheme.titleMedium)
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                        const SizedBox(height: 4),
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
                          const SizedBox(height: 6),
                          Text(
                            film.overview,
                            maxLines: wide ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF0B0D13),
                                visualDensity: wide ? null : VisualDensity.compact,
                              ),
                              onPressed: () => _openFilmPlayer(film),
                              icon: const Icon(Icons.play_arrow_rounded, size: 18),
                              label: Text(film.canResume ? '继续播放' : '播放'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _openFilm(film),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                visualDensity: wide ? null : VisualDensity.compact,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                              ),
                              icon: const Icon(Icons.info_outline_rounded, size: 17),
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
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 2, 0, compact ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
                Text('高分口碑精选', style: theme.textTheme.titleMedium),
              ],
            ),
          ),
          SizedBox(
            height: compact ? 168 : 204,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: top.length,
              separatorBuilder: (_, _) => SizedBox(width: compact ? 10 : 14),
              itemBuilder: (context, index) {
                final film = top[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _openFilm(film),
                  child: SizedBox(
                    width: compact ? 142 : 172,
                    child: Stack(
                      alignment: Alignment.bottomLeft,
                      children: [
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          width: compact ? 108 : 130,
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
                              fontSize: compact ? 68 : 84,
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
    final compact = MediaQuery.sizeOf(context).width < 600;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.5)
        .toDouble();
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 4, 0, compact ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 18, bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
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
            height: (compact ? 136 : 158) + 76 * (textScale - 1),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: films.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final film = films[index];
                final progress = film.duration > 0
                    ? (film.position / film.duration).clamp(0.0, 1.0).toDouble()
                    : 0.0;
                return SizedBox(
                  width: (compact ? 256 : 288) + 76 * (textScale - 1),
                  child: Material(
                    color: const Color(0xff171d29),
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _openFilmPlayer(film),
                      child: Row(
                        children: [
                          SizedBox(
                            width: compact ? 92 : 108,
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
                              padding: EdgeInsets.all(compact ? 10 : 12),
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
                                  const SizedBox(height: 3),
                                  Text(
                                    '剩余 ${formatMediaSeconds((film.duration - film.position).clamp(0, double.infinity).toDouble())}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
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
    final compact = MediaQuery.sizeOf(context).width < 600;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.5)
        .toDouble();
    final cardWidth = compact && textScale <= 1.25 ? 128.0 : 156.0;
    final footerHeight = 88 * textScale + 16;
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 4, 0, compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('最近添加', style: theme.textTheme.titleMedium),
          ),
          SizedBox(
            // Match CinemaFilmTile's 2:3 cover plus its scaled footer. A
            // fixed-height shelf clipped at 200% accessibility text size.
            height: cardWidth * 1.5 + footerHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: _recentShelf.length,
              separatorBuilder: (_, _) => SizedBox(width: compact ? 10 : 12),
              itemBuilder: (context, index) {
                final film = _recentShelf[index];
                return SizedBox(
                  width: cardWidth,
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
