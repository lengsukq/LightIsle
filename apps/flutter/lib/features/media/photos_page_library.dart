part of 'photos_page.dart';

extension _PhotosPageLibrary on _PhotosPageState {
  Future<void> _loadAssets({required bool reset, int? startCursor}) async {
    if (!reset &&
        (_feed.loading || _feed.loadingMore || _feed.nextCursor == 0)) {
      return;
    }
    final generation = ++_feed.generation;
    final cursor = reset ? (startCursor ?? 0) : _feed.nextCursor;
    final query = _scope.buildQueryParameters(
      limit: _PhotosPageState._pageSize,
      cursor: cursor,
    );
    final cacheKey = Uri(queryParameters: query).query;
    final scopeKey =
        '${identityHashCode(widget.api)}:${widget.api.selectedRoot?.identity ?? ''}:$cacheKey';

    MediaPageResult<PhotoAsset>? cachedPage;
    if (reset && startCursor == null) {
      final cached = IsleDataCache.instance.getJsonMap(
        widget.api,
        'photos',
        cacheKey,
      );
      if (cached != null) {
        cachedPage = MediaPageResult.parse<PhotoAsset>(
          cached,
          itemsKey: 'assets',
          fromJson: PhotoAsset.fromJson,
        );
      }
    }

    _updateState(() {
      if (reset) {
        if (cachedPage != null) {
          _feed.assets
            ..clear()
            ..addAll(cachedPage.items);
          _feed.nextCursor = cachedPage.nextCursor;
          _feed.activeScopeKey = scopeKey;
          _timeline.activeFirstIndex = 0;
          _feed.loadError = null;
          _feed.loading = false;
        } else {
          final sameScope =
              startCursor == null &&
              _feed.activeScopeKey == scopeKey &&
              _feed.assets.isNotEmpty;
          // Preserve existing gallery rows during same-scope pull-to-refresh
          // and fast timeline seeks so the screen never flashes empty.
          if (startCursor == null && !sameScope) {
            _feed.assets.clear();
            _feed.nextCursor = 0;
            _timeline.activeFirstIndex = 0;
          }
          _feed.activeScopeKey = scopeKey;
          _feed.loadError = null;
          _feed.loading = true;
        }
      } else {
        _feed.loadingMore = true;
      }
    });
    try {
      final response = await widget.api.get('/api/v2/photos', query: query);
      if (!mounted || generation != _feed.generation) return;
      if (reset && startCursor == null) {
        IsleDataCache.instance.putJsonMap(
          widget.api,
          'photos',
          cacheKey,
          response,
        );
      }
      final page = MediaPageResult.parse<PhotoAsset>(
        response,
        itemsKey: 'assets',
        fromJson: PhotoAsset.fromJson,
      );
      _updateState(() {
        if (reset) {
          _feed.assets
            ..clear()
            ..addAll(page.items);
        } else {
          _feed.assets.addAll(page.items);
        }
        _feed.nextCursor = page.nextCursor;
        _feed.loadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _feed.generation) return;
      _updateState(() => _feed.loadError = mediaErrorLabel(error));
    } finally {
      if (mounted && generation == _feed.generation) {
        _updateState(() {
          _feed.loading = false;
          _feed.loadingMore = false;
        });
      }
    }
  }

  Future<void> _refreshStatus() async {
    final generation = ++_scan.generation;
    try {
      final response = await widget.api.get('/api/v2/photos/status');
      if (!mounted || generation != _scan.generation) return;
      final status = MediaScanStatus.fromJson(response['status']);
      final finished = _scanPoller.observe(status);
      _updateState(() {
        _scan.status = status;
        _scan.scanning = status.running;
        _scan.scanError = status.lastError.isEmpty
            ? null
            : mediaErrorLabel(status.lastError);
      });
      if (finished) {
        await Future.wait([
          _loadAssets(reset: true),
          _refreshAlbums(),
          _refreshPrivateAlbums(),
          _refreshTimelineIndex(),
        ]);
      }
    } catch (_) {
      // Authentication and service health are handled by the application shell.
    }
  }

  Future<void> _startScan() async {
    _updateState(_feed.clearActionFeedback);
    try {
      await widget.api.send('POST', '/api/v2/photos/scan');
      if (!mounted) return;
      _updateState(() => _feed.setActionFeedback('媒体扫描已开始。'));
      await _refreshStatus();
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
    }
  }

  Future<void> _selectView({
    int albumId = 0,
    bool favorites = false,
    bool personalFavorites = false,
    int privateAlbumId = 0,
    String folderPath = '',
    String folderName = '',
    bool onThisDay = false,
  }) async {
    if (_scope.activeAlbum == albumId &&
        _scope.favoritesOnly == favorites &&
        _scope.personalFavoritesOnly == personalFavorites &&
        _scope.activePrivateAlbum == privateAlbumId &&
        _scope.activeFolderPath == folderPath &&
        _scope.onThisDay == onThisDay &&
        _scope.activePersonId == 0) {
      return;
    }
    _updateState(() {
      _selection.clear();
      _scope.setCollectionScope(
        albumId: albumId,
        privateAlbumId: privateAlbumId,
        folderPath: folderPath,
        folderName: folderName,
        favorites: favorites,
        personalFavorites: personalFavorites,
        onThisDayView: onThisDay,
      );
      _feed.clearActionFeedback();
    });
    await _loadAssets(reset: true);
  }

  bool get _fullTimelineSelected => _scope.isFullTimelineSelected;

  Future<void> _openAsset(PhotoAsset asset) async {
    if (_selection.selecting) {
      _toggleSelection(asset);
      return;
    }
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<void>(
      PhotoGalleryViewer.route(
        (_) => PhotoGalleryViewer(
          api: widget.api,
          memoryCache: _photoCache,
          offlineAccountId: widget.offlineAccountId,
          assets: List<PhotoAsset>.of(_feed.assets),
          initialIndex: _feed.assets.indexWhere((item) => item.id == asset.id),
          canEditSharedFavorite: (item) => widget.isAdmin || item.canWrite,
          onSharedFavorite: _toggleFavorite,
          onPersonalFavorite: _togglePersonalFavorite,
          onDelete: (asset) => _trashAssets([asset]),
          onFolderAlbum: _addAssetToFolder,
          currentAlbumName:
              _currentPrivateAlbum?.name ?? _currentAlbum?.name ?? '',
          onRemoveFromCurrentAlbum:
              (_scope.activePrivateAlbum > 0 ||
                  (widget.isAdmin && _scope.activeAlbum > 0))
              ? _removeSingleAssetFromCurrentAlbum
              : null,
          onDetails: _showAssetDetails,
          onSyncAsset: (id) {
            for (final item in _feed.assets) {
              if (item.id == id) return item;
            }
            return null;
          },
          onLoadMore: () async {
            if (_feed.nextCursor > 0 && !_feed.loading && !_feed.loadingMore) {
              await _loadAssets(reset: false);
            }
            return List<PhotoAsset>.of(_feed.assets);
          },
        ),
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
    IconData? icon,
    VoidCallback? onDeleted,
  }) => MediaFilterChip(
    label: label,
    selected: selected,
    onSelected: onSelected,
    icon: icon,
    onDeleted: onDeleted,
  );

  Widget _buildGrid() {
    if (_feed.loading && _feed.assets.isEmpty) {
      return const SliverToBoxAdapter(
        child: IsleLoadingState(
          padding: EdgeInsets.all(48),
          label: '正在加载时光相册…',
        ),
      );
    }
    if (_feed.assets.isEmpty && _feed.loadError != null) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.photo_library_outlined,
          title: '暂时无法读取图库',
          message: _feed.loadError!,
          action: OutlinedButton.icon(
            onPressed: _feed.loading ? null : () => _loadAssets(reset: true),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_feed.assets.isEmpty) return _buildEmptyLibrarySliver();

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final columns = _computeGridColumns(width);
        final gridSpacing = _feed.comfortableGrid ? 6.0 : 2.0;
        final tileRadius = _feed.comfortableGrid ? 10.0 : 2.0;
        final gridHorizontalInset = _feed.comfortableGrid ? _pageInset : 2.0;
        final sections = _groupAssetsByMonth();
        final compact = width < IsleLayout.compactPageWidth;
        return SliverMainAxisGroup(
          slivers: [
            for (final section in sections) ...[
              _buildMonthHeaderSliver(
                context,
                section,
                isFirst: identical(section, sections.first),
                compact: compact,
              ),
              _buildMonthAssetGridSliver(
                section,
                columns: columns,
                gridSpacing: gridSpacing,
                tileRadius: tileRadius,
                horizontalInset: gridHorizontalInset,
              ),
            ],
          ],
        );
      },
    );
  }

  int _computeGridColumns(double width) {
    final baseColumns = width < 340
        ? 3
        : width < 600
        ? 4
        : width < 760
        ? 5
        : width < 960
        ? 6
        : (width / 138).floor().clamp(6, 10);
    // Thumbnails are image-based, not text-based; increasing system font size
    // must not turn the gallery back into a sparse file list.
    return _feed.comfortableGrid ? (baseColumns - 1).clamp(2, 8) : baseColumns;
  }

  List<_AssetMonthSection> _groupAssetsByMonth() {
    // Monthly sections keep the flat newest-first grid but give each month a
    // header, mirroring the web timeline.
    final sections = <_AssetMonthSection>[];
    for (final asset in _feed.assets) {
      final key = _assetMonthKey(asset.takenAt);
      if (sections.isEmpty || sections.last.key != key) {
        sections.add(_AssetMonthSection(key, formatMediaMonth(asset.takenAt)));
      }
      sections.last.items.add(asset);
    }
    return sections;
  }

  Widget _buildEmptyLibrarySliver() {
    final album = _currentAlbum;
    final privateAlbum = _currentPrivateAlbum;
    final hasActiveScope =
        _scope.activeFolderPath.isNotEmpty ||
        album != null ||
        privateAlbum != null ||
        _scope.favoritesOnly ||
        _scope.personalFavoritesOnly ||
        _scope.onThisDay;
    final (title, message) = _resolveEmptyLibraryCopy(
      album: album,
      privateAlbum: privateAlbum,
    );
    return SliverToBoxAdapter(
      child: MediaEmptyState(
        icon: Icons.photo_library_outlined,
        title: title,
        message: message,
        action: hasActiveScope
            ? TextButton.icon(
                onPressed: () => _selectView(),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('浏览全部照片'),
              )
            : FilledButton.icon(
                onPressed: _upload,
                icon: const Icon(Icons.add_rounded),
                label: const Text('上传照片与视频'),
              ),
      ),
    );
  }

  (String, String) _resolveEmptyLibraryCopy({
    required MediaAlbum? album,
    required MediaAlbum? privateAlbum,
  }) {
    if (_scope.activeFolderPath.isNotEmpty) {
      return ('文件夹相册还没有媒体', '可以在文件管理中放入照片，或在照片预览中选择复制或移动到此相册。');
    }
    if (album != null) {
      return ('此相册还没有媒体', '在全部照片中打开一项媒体，选择此相册并加入。');
    }
    if (privateAlbum != null) {
      return ('私人相册还没有媒体', '此清单仅当前账号可见。打开全部照片，选择私人相册并加入媒体。');
    }
    if (_scope.favoritesOnly) {
      return ('还没有共享收藏', '打开一项你有权编辑的媒体并加入共享收藏。');
    }
    if (_scope.personalFavoritesOnly) {
      return ('还没有个人收藏', '预览自己有权限查看的照片，点星形图标保存到仅自己可见的收藏。');
    }
    if (_scope.onThisDay) {
      return ('往年今天还没有照片', '今天拍摄的往年照片会出现在这里，试试浏览全部照片。');
    }
    if (_scope.query.isNotEmpty) {
      return ('没有找到匹配的照片', '试试其他文件名，或清除搜索条件。');
    }
    if (widget.hasOtherRoots) {
      return (
        '这里还没有照片或视频',
        '点击上传保存照片。若迁移前的照片在原存储目录（如「图库 / PhonePhotos」），原数据未丢失，可在顶部切换存储目录查看。',
      );
    }
    return ('这里还没有照片或视频', '点击上传，把设备里的照片与视频保存到 NAS。');
  }

  Widget _buildMonthHeaderSliver(
    BuildContext context,
    _AssetMonthSection section, {
    required bool isFirst,
    required bool compact,
  }) {
    final allSectionSelected = section.items
        .take(50)
        .every((item) => _selection.selectedAssets.contains(item.id));
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        key: isFirst ? _timeline.firstMonthHeadingKey : null,
        padding: EdgeInsets.fromLTRB(
          _pageInset,
          compact ? 10 : 16,
          _pageInset,
          compact ? 6 : 8,
        ),
        child: Row(
          children: [
            Semantics(
              button: true,
              label: '全选 ${section.title}',
              child: InkWell(
                key: ValueKey('selectMonth_${section.key}'),
                borderRadius: BorderRadius.circular(20),
                onTap: _selection.batchBusy
                    ? null
                    : () => _toggleSectionSelection(section.items),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(
                        allSectionSelected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: allSectionSelected
                            ? scheme.primary
                            : scheme.onSurfaceVariant.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Text(
                section.title,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${section.items.length} 项',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthAssetGridSliver(
    _AssetMonthSection section, {
    required int columns,
    required double gridSpacing,
    required double tileRadius,
    required double horizontalInset,
  }) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: horizontalInset),
      sliver: SliverGrid.builder(
        itemCount: section.items.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gridSpacing,
          mainAxisSpacing: gridSpacing,
          childAspectRatio: 1,
        ),
        itemBuilder: (context, index) => _buildPhotoGridTile(
          context,
          section.items[index],
          tileRadius: tileRadius,
        ),
      ),
    );
  }

  Widget _buildPhotoGridTile(
    BuildContext context,
    PhotoAsset asset, {
    required double tileRadius,
  }) {
    final isSelected = _selection.selectedAssets.contains(asset.id);
    return Semantics(
      button: true,
      label:
          '${asset.name}, ${asset.isVideo ? '视频' : '照片'}，${formatMediaDate(asset.takenAt)}${asset.personalFavorite ? '，我的收藏' : ''}${asset.favorite ? '，共享收藏' : ''}',
      child: InkWell(
        onTap: () {
          if (_selection.selecting ||
              HardwareKeyboard.instance.isShiftPressed) {
            _toggleSelection(asset);
            return;
          }
          _openAsset(asset);
        },
        onLongPress: () => _toggleSelection(asset),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(tileRadius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Hero(
                tag: 'photo_thumb_${asset.id}',
                child: _buildAssetThumbnailSurface(context, asset),
              ),
              if (_selection.selecting)
                _buildTileSelectionBadge(context, isSelected: isSelected)
              else if (asset.isLivePhoto)
                Positioned(
                  top: 5,
                  left: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.motion_photos_on_rounded,
                            color: Color(0xFF9CDCF5),
                            size: 11,
                          ),
                          SizedBox(width: 3),
                          Text(
                            'LIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (asset.isVideo) _buildTileVideoBadge(asset),
              if (asset.favorite || asset.personalFavorite)
                _buildTileFavoriteBadges(asset),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAssetThumbnailSurface(BuildContext context, PhotoAsset asset) {
    final scheme = Theme.of(context).colorScheme;
    if (asset.isRaw) {
      return Container(
        color: scheme.surfaceContainerLow,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined, size: 26),
              Text(
                'RAW',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      );
    }
    return AuthenticatedMediaImage(
      api: widget.api,
      memoryCache: _photoCache,
      path: '/api/v2/photos/${asset.id}/thumbnail',
      maxBytes: 4 * 1024 * 1024,
      fit: BoxFit.cover,
      loadingBuilder: (_) => Container(color: scheme.surfaceContainerLow),
      errorBuilder: (_, _, retry) => Container(
        color: scheme.surfaceContainerHigh,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Icon(
                asset.isVideo
                    ? Icons.movie_outlined
                    : Icons.image_not_supported_outlined,
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  tooltip: '重试缩略图',
                  visualDensity: VisualDensity.compact,
                  onPressed: retry,
                  icon: const Icon(Icons.refresh, size: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTileSelectionBadge(
    BuildContext context, {
    required bool isSelected,
  }) {
    return Positioned(
      top: 5,
      left: 5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.black54,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(
            isSelected ? Icons.check_rounded : Icons.circle_outlined,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildTileVideoBadge(PhotoAsset asset) {
    return Positioned(
      right: 5,
      bottom: 5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 14,
              ),
              if (asset.durationSeconds > 0) ...[
                const SizedBox(width: 2),
                Text(
                  formatMediaSeconds(asset.durationSeconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTileFavoriteBadges(PhotoAsset asset) {
    return Positioned(
      top: 7,
      right: 7,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (asset.personalFavorite)
            const Icon(
              Icons.star,
              color: Color(0xFFFFD76C),
              size: 17,
              shadows: [Shadow(blurRadius: 5, color: Colors.black54)],
            ),
          if (asset.favorite && asset.personalFavorite)
            const SizedBox(width: 4),
          if (asset.favorite)
            const Icon(
              Icons.favorite,
              color: Colors.white,
              size: 18,
              shadows: [Shadow(blurRadius: 5, color: Colors.black54)],
            ),
        ],
      ),
    );
  }
}
