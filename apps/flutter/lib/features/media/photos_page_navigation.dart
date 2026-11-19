part of 'photos_page.dart';

extension _PhotosPageNavigation on _PhotosPageState {
  void _handleSystemBack(bool didPop, Object? result) {
    if (didPop || _selection.batchBusy) return;
    if (_selection.selecting) {
      _updateState(_selection.clear);
    } else if (_scope.showSearch) {
      _scope.searchTimer?.cancel();
      _scope.searchController.clear();
      _updateState(() {
        _scope.query = '';
        _scope.searchMode = PhotoSearchMode.all;
        _scope.showSearch = false;
      });
      _loadAssets(reset: true);
    } else if (!_fullTimelineSelected) {
      _updateState(_scope.clearSearchAndFacets);
      _selectView();
    }
  }

  Future<void> _openPhotoMap() async {
    final selected = await Navigator.of(context).push<PhotoAsset>(
      buildIslePageRoute<PhotoAsset>(
        builder: (_) => PhotoMapPage(api: widget.api),
      ),
    );
    if (mounted && selected != null) await _openAsset(selected);
  }

  Future<void> _upload() async {
    final count = await openFileUpload(
      context,
      api: widget.api,
      isAdmin: widget.isAdmin,
      directory: widget.uploadDirectory,
      type: FileType.media,
      title: '上传照片与视频',
      taskCenter: widget.taskCenter,
      accountName: widget.accountName,
    );
    if (!mounted || count == 0) return;
    String? indexingError;
    if (widget.isAdmin && !_scan.scanning) {
      await _startScan();
      if (_feed.actionIsError) indexingError = _feed.actionMessage;
    }
    if (!mounted) return;
    _updateState(() {
      _feed.setActionFeedback(
        '已上传 $count 项。${indexingError == null ? '索引更新后会显示在全部照片中，可下拉刷新。' : '媒体整理暂未开始：$indexingError'}',
        isError: indexingError != null,
      );
      _scope.setCollectionScope(
        personId: _scope.activePersonId,
        personName: _scope.activePersonName,
      );
      _scope.clearSearchAndFacets(closeSearchBar: true);
    });
    await _loadAssets(reset: true);
  }

  void _photoAction(String value) {
    switch (value) {
      case 'gridDensity':
        _updateState(() => _feed.comfortableGrid = !_feed.comfortableGrid);
      case 'select':
        _updateState(() {
          _selection.selecting = !_selection.selecting;
          _selection.selectedAssets.clear();
        });
      case 'map':
        _openPhotoMap();
      case 'people':
        unawaited(_openPeoplePage());
      case 'similarCleanup':
        unawaited(_openSimilarCleanupPage());
      case 'offline':
        if (widget.offlineAccountId.isEmpty) {
          _updateState(
            () =>
                _feed.setActionFeedback('当前服务器未提供稳定账号 ID，升级 NAS 后才能安全使用离线照片库。'),
          );
        } else {
          Navigator.of(context).push(
            buildIslePageRoute<void>(
              builder: (_) => OfflinePhotosPage(
                api: widget.api,
                accountId: widget.offlineAccountId,
              ),
            ),
          );
        }
      case 'files':
        openFileManager(
          context,
          api: widget.api,
          isAdmin: widget.isAdmin,
          directory: widget.uploadDirectory,
          title: '照片文件',
        );
      case 'month':
        _chooseTimelineMonth();
      case 'today':
        _selectView(onThisDay: true);
      case 'sharedFavorites':
        _selectView(favorites: true);
      case 'scan':
        _startScan();
      case 'refresh':
        _loadAssets(reset: true);
        _refreshAlbums();
        _refreshPrivateAlbums();
      case 'all':
      case 'photo':
      case 'live':
      case 'video':
        _updateState(() => _scope.mediaType = value == 'all' ? '' : value);
        _loadAssets(reset: true);
      case 'renamePrivate':
        _createOrRenamePrivateAlbum(album: _currentPrivateAlbum!);
      case 'deletePrivate':
        _deletePrivateAlbum(_currentPrivateAlbum!);
      case 'renameShared':
        _createOrRenameAlbum(album: _currentAlbum!);
      case 'deleteShared':
        _deleteAlbum(_currentAlbum!);
      case 'backup':
        unawaited(_openMobilePhotoBackup());
    }
  }

  Future<void> _openMobilePhotoBackup() async {
    if (!widget.canBackup || widget.backupDirectory == 'PhonePhotos') {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final goStorage = await showIsleDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(
              color: IsleGlass.rimBorderColor(isDark),
              width: 1.0,
            ),
          ),
          title: const Text('尚未开启个人照片空间'),
          content: const Text(
            '手机相册备份需要先为当前账号分配在线的个人「照片」存储位置。'
            '若你刚刚手动切换了共享硬盘，请先切回个人照片空间后再开启备份。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('前往存储空间'),
            ),
          ],
        ),
      );
      if (goStorage == true && mounted) {
        await Navigator.of(context).push(
          buildIslePageRoute<void>(
            builder: (_) =>
                StoragePage(api: widget.api, isAdmin: widget.isAdmin),
          ),
        );
      }
      return;
    }
    await Navigator.of(context).push(
      buildIslePageRoute<void>(
        builder: (_) => MobilePhotoBackupPage(
          api: widget.api,
          accountName: widget.accountName,
          baseDirectory: widget.backupDirectory,
        ),
      ),
    );
  }

  Widget _photoNavigation() {
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildNavigationChipStrip(),
          if (_currentPrivateAlbum != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '私人相册 · 仅当前账号可见',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          _buildExpandableSearchBar(),
          IsleAnimatedExpand(
            expanded: _scope.hasActiveQueryOrFacets,
            child: _buildActiveFilterSummary(context),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveFilterSummary(BuildContext context) {
    final parts = <String>[
      if (_scope.query.isNotEmpty) '关键词 “${_scope.query}”',
      if (_scope.cameraFilter.isNotEmpty) _scope.cameraFilter,
      if (_scope.locationFilter.isNotEmpty)
        _scope.locationFilter == '1' ? '含定位' : '无定位',
      if (_scope.yearFilter > 0) '${_scope.yearFilter} 年',
      if (_scope.takenFromFilter > 0 || _scope.takenToFilter > 0)
        _formatCustomDateRangeLabel(),
      if (_scope.mediaType == 'photo') '仅照片',
      if (_scope.mediaType == 'live') '实况照片',
      if (_scope.mediaType == 'video') '仅视频',
    ];
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    final rose = palette['brandRose'];
    return Container(
      key: const Key('photoFilterSummaryBanner'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: IsleDecorations.recessedWell(context, radius: 10),
      child: Row(
        children: [
          Icon(Icons.filter_alt_outlined, size: 15, color: rose),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '当前筛选：${parts.join(' · ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () {
              _updateState(() => _scope.clearSearchAndFacets());
              _loadAssets(reset: true);
            },
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 26),
              padding: const EdgeInsets.symmetric(horizontal: 7),
            ),
            child: const Text('清除条件', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _actionPillChip({
    required String label,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    return ActionChip(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: isBrutal
          ? palette['cardTop']
          : isDark
          ? palette['cardItemTop'].withValues(alpha: 0.85)
          : palette['cardTop'].withValues(alpha: 0.95),
      side: BorderSide(
        color: style.rimBorderColor(),
        width: isBrutal ? 1.5 : 1.0,
      ),
      shape: isSharp ? style.shapeFor(IsleRadius.sm) : const StadiumBorder(),
      avatar: Icon(icon, size: 15, color: colors.onSurfaceVariant),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: colors.onSurface,
        ),
      ),
      onPressed: onPressed,
    );
  }

  Widget _buildNavigationChipStrip() {
    final selectedAlbum = _currentPrivateAlbum ?? _currentAlbum;
    final wide = MediaQuery.sizeOf(context).width >= 960;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _filterChip(
            label: '全部照片',
            selected: _scope.isUnscopedCollection,
            onSelected: () => _selectView(),
          ),
          const SizedBox(width: 6),
          _filterChip(
            label: _scope.activeFolderName.isNotEmpty
                ? _scope.activeFolderName
                : selectedAlbum == null
                ? '相册'
                : selectedAlbum.name,
            selected:
                selectedAlbum != null || _scope.activeFolderPath.isNotEmpty,
            icon: Icons.photo_album_outlined,
            onSelected: _browseAlbums,
            onDeleted:
                selectedAlbum != null || _scope.activeFolderPath.isNotEmpty
                ? () => _selectView()
                : null,
          ),
          const SizedBox(width: 6),
          _filterChip(
            label: '我的收藏',
            icon: Icons.star_outline,
            selected: _scope.personalFavoritesOnly,
            onSelected: () =>
                _selectView(personalFavorites: !_scope.personalFavoritesOnly),
          ),
          const SizedBox(width: 6),
          _filterChip(
            label: _scope.activePersonId > 0 ? _scope.activePersonName : '人物',
            icon: Icons.face_retouching_natural_outlined,
            selected: _scope.activePersonId > 0,
            onSelected: _openPeoplePage,
            onDeleted: _scope.activePersonId > 0 ? () => _selectView() : null,
          ),
          const SizedBox(width: 6),
          _actionPillChip(
            tooltip: '按相机型号、定位、年份筛选',
            icon: Icons.tune_rounded,
            label: '筛选',
            onPressed: _openExifFilterSheet,
          ),
          if (wide) ...[
            const SizedBox(width: 10),
            Container(
              width: 1,
              height: 18,
              color: IsleGlass.rimBorderColor(
                Theme.of(context).brightness == Brightness.dark,
              ),
            ),
            const SizedBox(width: 10),
            _filterChip(
              label: '实况 Live',
              icon: Icons.motion_photos_on_outlined,
              selected: _scope.mediaType == 'live',
              onSelected: () {
                _updateState(
                  () =>
                      _scope.mediaType = _scope.mediaType == 'live' ? '' : 'live',
                );
                _loadAssets(reset: true);
              },
            ),
            const SizedBox(width: 6),
            _filterChip(
              label: '仅视频',
              icon: Icons.videocam_outlined,
              selected: _scope.mediaType == 'video',
              onSelected: () {
                _updateState(
                  () => _scope.mediaType = _scope.mediaType == 'video'
                      ? ''
                      : 'video',
                );
                _loadAssets(reset: true);
              },
            ),
          ],
          ..._buildActiveFacetChips(),
        ],
      ),
    );
  }

  List<Widget> _buildActiveFacetChips() {
    final style = IsleThemeStyle.of(context);
    final borderColor = style.rimBorderColor();
    final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;
    Widget facetChip(String text, VoidCallback onClear) => InputChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: isSharp ? style.shapeFor(IsleRadius.sm) : const StadiumBorder(),
      side: BorderSide(color: borderColor, width: style.effectiveBorderWidth()),
      label: Text(text, style: const TextStyle(fontSize: 12)),
      onDeleted: onClear,
    );

    return [
      if (_scope.cameraFilter.isNotEmpty) ...[
        const SizedBox(width: 6),
        facetChip(_scope.cameraFilter, () {
          _updateState(() => _scope.cameraFilter = '');
          _loadAssets(reset: true);
        }),
      ],
      if (_scope.locationFilter.isNotEmpty) ...[
        const SizedBox(width: 6),
        facetChip(_scope.locationFilter == '1' ? '含定位' : '无定位', () {
          _updateState(() => _scope.locationFilter = '');
          _loadAssets(reset: true);
        }),
      ],
      if (_scope.yearFilter > 0) ...[
        const SizedBox(width: 6),
        facetChip('${_scope.yearFilter} 年', () {
          _updateState(() => _scope.yearFilter = 0);
          _loadAssets(reset: true);
        }),
      ],
      if (_scope.takenFromFilter > 0 || _scope.takenToFilter > 0) ...[
        const SizedBox(width: 6),
        facetChip(_formatCustomDateRangeLabel(), () {
          _updateState(() {
            _scope.takenFromFilter = 0;
            _scope.takenToFilter = 0;
          });
          _loadAssets(reset: true);
        }),
      ],
      if (_scope.favoritesOnly ||
          _scope.onThisDay ||
          (_scope.mediaType.isNotEmpty &&
              MediaQuery.sizeOf(context).width < 960)) ...[
        const SizedBox(width: 6),
        facetChip(
          _scope.favoritesOnly
              ? '共享收藏'
              : _scope.onThisDay
              ? '那年今天'
              : _scope.mediaType == 'photo'
              ? '仅照片'
              : _scope.mediaType == 'live'
              ? '实况照片'
              : '仅视频',
          () {
            _updateState(() => _scope.mediaType = '');
            _selectView();
          },
        ),
      ],
    ];
  }

  Widget _buildExpandableSearchBar() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);

    return IsleAnimatedExpand(
      expanded: _scope.showSearch,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IsleSearchBar(
              controller: _scope.searchController,
              autofocus: true,
              maxLength: 64,
              hintText: _scope.searchMode.hintText,
              showClear: true,
              clearTooltip: '关闭搜索',
              onChanged: (value) {
                _scope.searchTimer?.cancel();
                _scope.searchTimer = Timer(
                  const Duration(milliseconds: 350),
                  () {
                    if (!mounted) return;
                    _updateState(() => _scope.query = value.trim());
                    _loadAssets(reset: true);
                  },
                );
              },
              onClear: () {
                _scope.searchTimer?.cancel();
                _scope.searchController.clear();
                _updateState(() {
                  _scope.query = '';
                  _scope.searchMode = PhotoSearchMode.all;
                  _scope.showSearch = false;
                });
                _loadAssets(reset: true);
              },
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final mode in PhotoSearchMode.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: const StadiumBorder(),
                        side: BorderSide(
                          color: _scope.searchMode == mode
                              ? colors.primary.withValues(alpha: 0.45)
                              : borderColor,
                          width: 1.0,
                        ),
                        label: Text(
                          mode.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _scope.searchMode == mode,
                        onSelected: (_) {
                          if (_scope.searchMode == mode) return;
                          _updateState(() => _scope.searchMode = mode);
                          if (_scope.query.isNotEmpty) {
                            _loadAssets(reset: true);
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatCustomDateRangeLabel() {
    String fmt(int sec) {
      final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000).toLocal();
      return '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
    }

    if (_scope.takenFromFilter > 0 && _scope.takenToFilter > 0) {
      return '${fmt(_scope.takenFromFilter)}–${fmt(_scope.takenToFilter)}';
    }
    if (_scope.takenFromFilter > 0) return '${fmt(_scope.takenFromFilter)} 起';
    return '至 ${fmt(_scope.takenToFilter)}';
  }

  Widget _buildMemoriesCarousel() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final isFlat = style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact = screenWidth < IsleLayout.compactPageWidth;
    final desktop = screenWidth >= IsleLayout.desktopRailWidth;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;

    final stories =
        <
          ({
            String keyId,
            String title,
            IconData icon,
            Color accent,
            VoidCallback onTap,
          })
        >[
          (
            keyId: 'memoryOnThisDay',
            title: '那年今日',
            icon: Icons.auto_awesome_rounded,
            accent: palette['brandViolet'],
            onTap: () => _selectView(onThisDay: true),
          ),
          (
            keyId: 'memoryPersonalStars',
            title: '星标精选',
            icon: Icons.star_rounded,
            accent: palette['brandAmber'],
            onTap: () => _selectView(personalFavorites: true),
          ),
          (
            keyId: 'memorySharedHearts',
            title: '家庭佳作',
            icon: Icons.favorite_rounded,
            accent: palette['brandRose'],
            onTap: () => _selectView(favorites: true),
          ),
          (
            keyId: 'memoryLivePhotos',
            title: '实况瞬间',
            icon: Icons.motion_photos_on_rounded,
            accent: palette['brandTerracotta'],
            onTap: () {
              _updateState(() => _scope.mediaType = 'live');
              _loadAssets(reset: true);
            },
          ),
          (
            keyId: 'memoryVideos',
            title: '动态影像',
            icon: Icons.play_circle_fill_rounded,
            accent: palette['brandBlue'],
            onTap: () {
              _updateState(() => _scope.mediaType = 'video');
              _loadAssets(reset: true);
            },
          ),
          (
            keyId: 'memoryMapFootprints',
            title: '足迹地图',
            icon: Icons.explore_rounded,
            accent: palette['brandSage'],
            onTap: _openPhotoMap,
          ),
        ];

    final cardHeight = largeText
        ? 86.0
        : desktop
        ? 68.0
        : compact
        ? 58.0
        : 64.0;
    final cardWidth = desktop
        ? 162.0
        : compact
        ? 118.0
        : 140.0;

    return Padding(
      key: const ValueKey('googlePhotosMemoriesCarousel'),
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: cardHeight,
        child: ListView.separated(
          padding: EdgeInsets.symmetric(horizontal: _pageInset),
          scrollDirection: Axis.horizontal,
          itemCount: stories.length,
          separatorBuilder: (_, _) => SizedBox(width: compact ? 8 : 10),
          itemBuilder: (context, index) {
            final story = stories[index];
            final cardTop = Color.alphaBlend(
              story.accent.withValues(alpha: isDark ? 0.14 : 0.08),
              palette['cardTop'],
            );
            final cardBottom = Color.alphaBlend(
              story.accent.withValues(alpha: isDark ? 0.05 : 0.025),
              palette['cardBottom'],
            );
            final cardRadius = style.borderRadiusFor(IsleRadius.item);
            return SizedBox(
              width: cardWidth,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: ValueKey(story.keyId),
                  borderRadius: cardRadius,
                  onTap: story.onTap,
                  child: Ink(
                    decoration: BoxDecoration(
                      borderRadius: cardRadius,
                      color: isBrutal || isFlat ? cardTop : null,
                      gradient: isBrutal || isFlat
                          ? null
                          : LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [cardTop, cardBottom],
                            ),
                      border: Border.all(
                        color: isBrutal
                            ? style.rimBorderColor()
                            : story.accent.withValues(
                                alpha: isDark ? 0.32 : 0.22,
                              ),
                        width: style.effectiveBorderWidth(),
                      ),
                      boxShadow: style.subtleShadows(),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 10 : 12,
                        vertical: compact ? 8 : 10,
                      ),
                      child: Row(
                        children: [
                          IsleSquircleBadge(
                            icon: story.icon,
                            color: story.accent,
                            size: compact ? 26 : 30,
                            iconSize: compact ? 14.5 : 16,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              story.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onSurface,
                                fontSize: compact ? 12.5 : 13.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openExifFilterSheet() async {
    if (_scope.facetCameras.isEmpty && _scope.facetYears.isEmpty) {
      await _refreshFacets();
    }
    if (!mounted) return;
    final selection = await showPhotoExifFilterSheet(
      context,
      facetCameras: _scope.facetCameras,
      facetYears: _scope.facetYears,
      cameraFilter: _scope.cameraFilter,
      locationFilter: _scope.locationFilter,
      yearFilter: _scope.yearFilter,
      takenFromFilter: _scope.takenFromFilter,
      takenToFilter: _scope.takenToFilter,
    );
    if (selection == null || !mounted) return;
    _updateState(() {
      _scope.cameraFilter = selection.camera;
      _scope.locationFilter = selection.location;
      _scope.yearFilter = selection.year;
      _scope.takenFromFilter = selection.takenFrom;
      _scope.takenToFilter = selection.takenTo;
    });
    await _loadAssets(reset: true);
  }
}
