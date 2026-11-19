part of 'cinema_page.dart';

extension _CinemaLibraryControls on _CinemaPageState {
  Widget _cinemaNavigation() {
    final showFilters =
        (!_isRootCinemaView || _catalog.query.trim().isNotEmpty) &&
        (_subpages.isRootView || _subpages.showSeries) &&
        !_selection.selecting;

    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _viewChip(
                  '首页',
                  Icons.home_outlined,
                  _isRootCinemaView,
                  () => _switchToFilmMode('all'),
                ),
                const SizedBox(width: 6),
                _viewChip(
                  '电影',
                  Icons.movie_outlined,
                  _subpages.isRootView && _catalog.mode == 'movie',
                  () => _switchToFilmMode('movie'),
                ),
                const SizedBox(width: 6),
                _viewChip(
                  '剧集',
                  Icons.video_library_rounded,
                  _subpages.showSeries,
                  () {
                    _updateState(() {
                      _subpages.showSeries = true;
                      _subpages.showHistory = false;
                      _selection.clear();
                    });
                    unawaited(_loadSeries());
                    if (widget.isAdmin) unawaited(_refreshScrape());
                  },
                ),
                const SizedBox(width: 6),
                _viewChip(
                  '继续观看',
                  Icons.play_circle_outline_rounded,
                  _subpages.isRootView && _catalog.mode == 'continue',
                  () => _switchToFilmMode('continue'),
                ),
                const SizedBox(width: 6),
                _viewChip(
                  '观看历史',
                  Icons.history_rounded,
                  _subpages.showHistory,
                  () {
                    _updateState(() {
                      _subpages.showHistory = true;
                      _subpages.showSeries = false;
                      _selection.clear();
                      if (_catalog.searchController.text.isEmpty) {
                        _catalog.showSearch = false;
                      }
                    });
                    unawaited(_loadHistory());
                  },
                ),
                const SizedBox(width: 6),
                _viewChip(
                  '待匹配',
                  Icons.auto_fix_high_outlined,
                  _subpages.isRootView && _catalog.mode == 'unmatched',
                  () {
                    _switchToFilmMode('unmatched');
                    if (widget.isAdmin) unawaited(_refreshScrape());
                  },
                ),
                if (_subpages.showHistory || _catalog.mode == 'continue') ...[
                  const SizedBox(width: 6),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _switchToFilmMode('all'),
                    child: const Text('返回首页'),
                  ),
                ],
              ],
            ),
          ),
          IsleAnimatedExpand(
            expanded: showFilters,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _buildWatchedAndSortBar(context),
            ),
          ),
          IsleAnimatedExpand(
            expanded: _catalog.showSearch && !_subpages.showHistory,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: IsleSearchBar(
                controller: _catalog.searchController,
                autofocus: true,
                onChanged: _searchChanged,
                maxLength: 120,
                hintText: '搜索影片或剧集',
                showClear: true,
                clearTooltip: '关闭搜索',
                onClear: () {
                  _catalog.searchController.clear();
                  _searchChanged('');
                  _updateState(() => _catalog.showSearch = false);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWatchedAndSortBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        MediaFilterChip(
          label: '全部',
          selected: _catalog.watched == 'all',
          onSelected: () => _changeWatched('all'),
        ),
        MediaFilterChip(
          label: '未看',
          selected: _catalog.watched == 'unwatched',
          onSelected: () => _changeWatched('unwatched'),
        ),
        MediaFilterChip(
          label: '已看',
          selected: _catalog.watched == 'watched',
          onSelected: () => _changeWatched('watched'),
        ),
        const SizedBox(width: 2),
        Tooltip(
          message: '切换影院排序方式',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : scheme.surface,
              borderRadius: IsleRadius.brPill,
              border: Border.all(
                color: IsleGlass.rimBorderColor(isDark),
                width: 1.0,
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('cinemaSortDropdown'),
                value: _catalog.sort,
                isDense: true,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                icon: const Icon(Icons.sort_rounded, size: 15),
                items: const [
                  DropdownMenuItem(value: 'recent', child: Text('最近添加')),
                  DropdownMenuItem(value: 'rating', child: Text('评分最高')),
                  DropdownMenuItem(value: 'year', child: Text('年份最新')),
                  DropdownMenuItem(value: 'title', child: Text('片名顺序')),
                ],
                onChanged: (value) {
                  if (value != null) _changeSort(value);
                },
              ),
            ),
          ),
        ),
        if (_catalog.watched != 'all' || _catalog.sort != 'recent')
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () {
              _updateState(() {
                _catalog.watched = 'all';
                _catalog.sort = 'recent';
              });
              if (_subpages.showSeries) {
                unawaited(_loadSeries());
              } else {
                unawaited(_loadFilms(reset: true));
              }
            },
            child: const Text('重置筛选'),
          ),
      ],
    );
  }

  Widget _buildHeaderTrailingActions(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '搜索影片',
          onPressed: () {
            if (_catalog.showSearch) {
              _catalog.searchController.clear();
              _searchChanged('');
              _updateState(() => _catalog.showSearch = false);
            } else {
              _updateState(() {
                _catalog.showSearch = true;
                _subpages.showHistory = false;
              });
            }
          },
          icon: const Icon(Icons.search_rounded),
        ),
        if (_subpages.isRootView)
          IconButton(
            key: const Key('cinema-select-toggle'),
            visualDensity: VisualDensity.compact,
            tooltip: _selection.selecting ? '结束多选' : '多选影片',
            onPressed: _selection.batchBusy
                ? null
                : () {
                    if (_selection.selecting) {
                      _endFilmSelection();
                    } else {
                      _updateState(() => _selection.selecting = true);
                    }
                  },
            icon: Icon(
              _selection.selecting
                  ? Icons.close_rounded
                  : Icons.checklist_rounded,
            ),
            color: _selection.selecting
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '上传视频',
          onPressed: _upload,
          icon: const Icon(Icons.add_rounded),
        ),
        _buildOverflowMenuButton(),
      ],
    );
  }

  Widget _buildOverflowMenuButton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      tooltip: '更多影院操作',
      onSelected: _cinemaAction,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 214, maxWidth: 264),
      shape: IsleShapes.menu(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      itemBuilder: (_) => [
        isleActionMenuItem(
          value: 'refresh',
          icon: Icons.refresh_rounded,
          label: '刷新影视库',
        ),
        isleActionMenuItem(
          value: 'offline',
          icon: Icons.offline_pin_outlined,
          label: '我的离线影片库',
        ),
        isleActionMenuItem(
          value: 'local',
          icon: Icons.play_circle_outline_rounded,
          label: '播放本地视频（离线）',
        ),
        isleActionMenuItem(
          value: 'dav',
          icon: Icons.tv_rounded,
          label: 'Infuse / Apple TV 接入',
        ),
        isleActionMenuItem(
          value: 'files',
          icon: Icons.folder_open_outlined,
          label: '管理视频文件',
        ),
        if (widget.isAdmin) ...[
          const PopupMenuDivider(),
          isleActionMenuItem(
            value: 'scan',
            enabled: !_indexing.scanning,
            icon: Icons.sync_rounded,
            label: _indexing.scanning ? '扫描中' : '扫描影视库',
          ),
        ],
      ],
    );
  }

  Widget _buildSelectionToolbar() {
    final allPageSelected = _catalog.films
        .take(50)
        .every((film) => _selection.selectedFilmIds.contains(film.id));
    final canTrashSelected =
        _selectedFilms.isNotEmpty &&
        _selectedFilms.every((film) => widget.isAdmin || film.canWrite);

    return IsleAnimatedExpand(
      expanded: _selection.selecting && _subpages.isRootView,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 10),
        child: MediaSelectionActionBar(
          label: '已选 ${_selection.selectedFilmIds.length} 项',
          actions: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _selection.batchBusy || _catalog.films.isEmpty
                  ? null
                  : _selectVisibleFilms,
              icon: const Icon(Icons.select_all_rounded, size: 16),
              label: Text(allPageSelected ? '取消全选' : '全选当前页'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed:
                  _selection.batchBusy || _selection.selectedFilmIds.isEmpty
                  ? null
                  : _batchSaveFilms,
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('保存原文件'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed:
                  _selection.batchBusy || _selection.selectedFilmIds.isEmpty
                  ? null
                  : _batchShareFilms,
              icon: const Icon(Icons.ios_share_outlined, size: 16),
              label: const Text('分享'),
            ),
            if (canTrashSelected)
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed:
                    _selection.batchBusy || _selection.selectedFilmIds.isEmpty
                    ? null
                    : _batchTrashFilms,
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('移入回收站'),
              ),
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: _selection.batchBusy ? null : _endFilmSelection,
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }
}
