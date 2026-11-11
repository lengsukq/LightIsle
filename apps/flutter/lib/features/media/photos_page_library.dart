part of 'photos_page.dart';

extension _PhotosPageLibrary on _PhotosPageState {
  Future<void> _loadAssets({required bool reset, int? startCursor}) async {
    if (!reset && (_loading || _loadingMore || _nextCursor == 0)) return;
    final generation = ++_listGeneration;
    final cursor = reset ? (startCursor ?? 0) : _nextCursor;
    _updateState(() {
      if (reset) {
        // A fast seek must not blank the current gallery until the target
        // month is actually received. Normal refreshes still reset promptly.
        if (startCursor == null) {
          _assets.clear();
          _nextCursor = 0;
          _timelineActiveFirstIndex = 0;
        }
        _loadError = null;
        _loading = true;
      } else {
        _loadingMore = true;
      }
    });

    final query = <String, String>{
      'limit': '${_PhotosPageState._pageSize}',
      'cursor': '$cursor',
    };
    if (_activeAlbum > 0) query['album'] = '$_activeAlbum';
    if (_activePrivateAlbum > 0) {
      query['privateAlbum'] = '$_activePrivateAlbum';
    }
    if (_activeFolderPath.isNotEmpty) query['directory'] = _activeFolderPath;
    if (_favoritesOnly) query['favorites'] = '1';
    if (_personalFavoritesOnly) query['personal'] = '1';
    if (_onThisDay) query['onThisDay'] = '1';
    if (_query.isNotEmpty) query['q'] = _query;
    if (_mediaType.isNotEmpty) query['type'] = _mediaType;
    if (_cameraFilter.isNotEmpty) query['camera'] = _cameraFilter;
    if (_locationFilter.isNotEmpty) query['hasLocation'] = _locationFilter;
    if (_yearFilter > 0) {
      final from = DateTime(_yearFilter, 1, 1).millisecondsSinceEpoch ~/ 1000;
      final to =
          DateTime(_yearFilter, 12, 31, 23, 59, 59).millisecondsSinceEpoch ~/
          1000;
      query['takenFrom'] = '$from';
      query['takenTo'] = '$to';
    } else {
      if (_takenFromFilter > 0) query['takenFrom'] = '$_takenFromFilter';
      if (_takenToFilter > 0) query['takenTo'] = '$_takenToFilter';
    }
    final cacheKey = Uri(queryParameters: query).query;
    if (reset && startCursor == null) {
      final cached = IsleDataCache.instance.getJsonMap(
        widget.api,
        'photos',
        cacheKey,
      );
      if (cached != null) {
        final cachedPage = MediaPageResult.parse<PhotoAsset>(
          cached,
          itemsKey: 'assets',
          fromJson: PhotoAsset.fromJson,
        );
        _updateState(() {
          _assets
            ..clear()
            ..addAll(cachedPage.items);
          _nextCursor = cachedPage.nextCursor;
          _loading = false;
        });
      }
    }
    try {
      final response = await widget.api.get('/api/v2/photos', query: query);
      if (!mounted || generation != _listGeneration) return;
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
          _assets
            ..clear()
            ..addAll(page.items);
        } else {
          _assets.addAll(page.items);
        }
        _nextCursor = page.nextCursor;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _listGeneration) return;
      _updateState(() => _loadError = mediaErrorLabel(error));
    } finally {
      if (mounted && generation == _listGeneration) {
        _updateState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _refreshStatus() async {
    final generation = ++_statusGeneration;
    try {
      final response = await widget.api.get('/api/v2/photos/status');
      if (!mounted || generation != _statusGeneration) return;
      final status = MediaScanStatus.fromJson(response['status']);
      final finished = _scanPoller.observe(status);
      _updateState(() {
        _scanStatus = status;
        _scanning = status.running;
        _scanError = status.lastError.isEmpty
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
    _updateState(() {
      _actionMessage = null;
      _actionIsError = false;
    });
    try {
      await widget.api.send('POST', '/api/v2/photos/scan');
      if (!mounted) return;
      _updateState(() {
        _actionMessage = '媒体扫描已开始。';
        _actionIsError = false;
      });
      await _refreshStatus();
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
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
    if (_activeAlbum == albumId &&
        _favoritesOnly == favorites &&
        _personalFavoritesOnly == personalFavorites &&
        _activePrivateAlbum == privateAlbumId &&
        _activeFolderPath == folderPath &&
        _onThisDay == onThisDay) {
      return;
    }
    _updateState(() {
      _selecting = false;
      _selectedAssets.clear();
      _activeAlbum = albumId;
      _activePrivateAlbum = privateAlbumId;
      _activeFolderPath = folderPath;
      _activeFolderName = folderName;
      _favoritesOnly = favorites;
      _personalFavoritesOnly = personalFavorites;
      _onThisDay = onThisDay;
      _actionMessage = null;
      _actionIsError = false;
    });
    await _loadAssets(reset: true);
  }

  bool get _fullTimelineSelected =>
      _activeAlbum == 0 &&
      _activePrivateAlbum == 0 &&
      _activeFolderPath.isEmpty &&
      !_favoritesOnly &&
      !_personalFavoritesOnly &&
      !_onThisDay &&
      _query.isEmpty &&
      _mediaType.isEmpty &&
      _cameraFilter.isEmpty &&
      _locationFilter.isEmpty &&
      _yearFilter == 0 &&
      _takenFromFilter == 0 &&
      _takenToFilter == 0;

  Future<void> _refreshFacets() async {
    try {
      final response = await widget.api.get('/api/v2/photos/facets');
      if (!mounted) return;
      final cameras = (response['cameras'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      final years = (response['years'] as List<dynamic>? ?? const [])
          .map((e) => int.tryParse(e.toString()) ?? 0)
          .where((e) => e >= 1970)
          .toList();
      _updateState(() {
        _facetCameras = cameras;
        _facetYears = years;
      });
    } catch (_) {
      if (mounted) {
        _updateState(() {
          _facetCameras = const [];
          _facetYears = const [];
        });
      }
    }
  }

  Future<void> _refreshTimelineIndex() async {
    final generation = ++_timelineIndexGeneration;
    try {
      final response = await widget.api.get('/api/v2/photos/timeline');
      if (!mounted || generation != _timelineIndexGeneration) return;
      _updateState(
        () => _timelineMonths = PhotoTimelineMonth.parse(response['months']),
      );
    } catch (error) {
      // Timeline loading is secondary to browsing. Existing month picker
      // reports a recoverable error when the user explicitly asks for it.
      if (mounted && generation == _timelineIndexGeneration) {
        _updateState(() => _timelineMonths = const []);
      }
    }
  }

  Future<void> _jumpToTimelineMonth(PhotoTimelineMonth month) async {
    if (!_fullTimelineSelected || _loading || _loadingMore) return;
    await _loadAssets(reset: true, startCursor: month.firstIndex);
    if (!mounted || _loadError != null) return;
    _updateState(() => _timelineActiveFirstIndex = month.firstIndex);
    if (_timelineScroll.hasClients) {
      _timelineScroll.jumpTo(0);
      // Scroll the selected month's heading into view, not just the page
      // toolbar. The month is already the first page after a server cursor
      // seek; it may otherwise remain below the fold on a small phone.
      await WidgetsBinding.instance.endOfFrame;
      final heading = _firstMonthHeadingKey.currentContext;
      if (mounted && heading != null && heading.mounted) {
        await Scrollable.ensureVisible(heading, alignment: .08);
      }
    }
  }

  Future<void> _chooseTimelineMonth() async {
    if (!_fullTimelineSelected || _loading) return;
    if (_timelineMonths.isEmpty) await _refreshTimelineIndex();
    if (!mounted) return;
    if (_timelineMonths.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂时无法读取拍摄年月，请检查网络并重试。')));
      return;
    }
    final month = await showModalBottomSheet<PhotoTimelineMonth>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .65,
          child: Column(
            children: [
              const ListTile(
                title: Text('跳转到拍摄年月'),
                subtitle: Text('可直接跳转至尚未加载的历史照片，不必逐页滚动。'),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _timelineMonths.length,
                  itemBuilder: (context, index) {
                    final month = _timelineMonths[index];
                    return ListTile(
                      leading: const Icon(Icons.calendar_month_outlined),
                      title: Text(month.label),
                      trailing: Text('${month.count} 项'),
                      onTap: () => Navigator.pop(sheetContext, month),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (month != null && mounted) await _jumpToTimelineMonth(month);
  }

  Future<void> _openAsset(PhotoAsset asset) async {
    if (_selecting) {
      _toggleSelection(asset);
      return;
    }
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PhotoGalleryViewer(
          api: widget.api,
          memoryCache: _photoCache,
          offlineAccountId: widget.offlineAccountId,
          assets: List<PhotoAsset>.of(_assets),
          initialIndex: _assets.indexWhere((item) => item.id == asset.id),
          canEditSharedFavorite: (item) => widget.isAdmin || item.canWrite,
          onSharedFavorite: _toggleFavorite,
          onPersonalFavorite: _togglePersonalFavorite,
          onDelete: (asset) => _trashAssets([asset]),
          onFolderAlbum: _addAssetToFolder,
          onDetails: _showAssetDetails,
          onSyncAsset: (id) {
            for (final item in _assets) {
              if (item.id == id) return item;
            }
            return null;
          },
          onLoadMore: () async {
            if (_nextCursor > 0 && !_loading && !_loadingMore) {
              await _loadAssets(reset: false);
            }
            return List<PhotoAsset>.of(_assets);
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
    if (_loading && _assets.isEmpty) {
      return const SliverToBoxAdapter(
        child: IsleLoadingState(
          padding: EdgeInsets.all(48),
          label: '正在加载时光相册…',
        ),
      );
    }
    if (_assets.isEmpty && _loadError != null) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.photo_library_outlined,
          title: '暂时无法读取图库',
          message: _loadError!,
          action: OutlinedButton.icon(
            onPressed: _loading ? null : () => _loadAssets(reset: true),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_assets.isEmpty) {
      final album = _currentAlbum;
      final privateAlbum = _currentPrivateAlbum;
      final title = _activeFolderPath.isNotEmpty
          ? '文件夹相册还没有媒体'
          : album != null
          ? '此相册还没有媒体'
          : privateAlbum != null
          ? '私人相册还没有媒体'
          : _favoritesOnly
          ? '还没有共享收藏'
          : _personalFavoritesOnly
          ? '还没有个人收藏'
          : _onThisDay
          ? '往年今天还没有照片'
          : _query.isNotEmpty
          ? '没有找到匹配的照片'
          : '这里还没有照片或视频';
      final message = _activeFolderPath.isNotEmpty
          ? '可以在文件管理中放入照片，或在照片预览中选择复制或移动到此相册。'
          : album != null
          ? '在全部照片中打开一项媒体，选择此相册并加入。'
          : privateAlbum != null
          ? '此清单仅当前账号可见。打开全部照片，选择私人相册并加入媒体。'
          : _favoritesOnly
          ? '打开一项你有权编辑的媒体并加入共享收藏。'
          : _personalFavoritesOnly
          ? '预览自己有权限查看的照片，点星形图标保存到仅自己可见的收藏。'
          : _onThisDay
          ? '今天拍摄的往年照片会出现在这里，试试浏览全部照片。'
          : _query.isNotEmpty
          ? '试试其他文件名，或清除搜索条件。'
          : widget.hasOtherRoots
          ? '点击上传保存照片。若迁移前的照片在原存储目录（如「图库 / PhonePhotos」），原数据未丢失，可在顶部切换存储目录查看。'
          : '点击上传，把设备里的照片与视频保存到 NAS。';
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.photo_library_outlined,
          title: title,
          message: message,
          action:
              (_activeFolderPath.isNotEmpty ||
                  album != null ||
                  privateAlbum != null ||
                  _favoritesOnly ||
                  _personalFavoritesOnly ||
                  _onThisDay)
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

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final baseColumns = width < 340
            ? 3
            : width < 600
            ? 4
            : width < 760
            ? 5
            : width < 960
            ? 6
            : (width / 138).floor().clamp(6, 10);
        // Thumbnails are image-based, not text-based; increasing system font
        // size must not turn the gallery back into a sparse file list.
        final columns = _comfortableGrid
            ? (baseColumns - 1).clamp(2, 8)
            : baseColumns;
        final gridSpacing = _comfortableGrid ? 6.0 : 2.0;
        final tileRadius = _comfortableGrid ? 10.0 : 2.0;
        final gridHorizontalInset = _comfortableGrid ? _pageInset : 2.0;
        // Monthly sections keep the flat newest-first grid but give each
        // month a header, mirroring the web timeline.
        final sections = <_AssetMonthSection>[];
        for (final asset in _assets) {
          final key = _assetMonthKey(asset.takenAt);
          if (sections.isEmpty || sections.last.key != key) {
            sections.add(
              _AssetMonthSection(key, formatMediaMonth(asset.takenAt)),
            );
          }
          sections.last.items.add(asset);
        }
        return SliverMainAxisGroup(
          slivers: [
            for (final section in sections) ...[
              SliverToBoxAdapter(
                child: Padding(
                  key: identical(section, sections.first)
                      ? _firstMonthHeadingKey
                      : null,
                  padding: EdgeInsets.fromLTRB(
                    _pageInset,
                    width < IsleLayout.compactPageWidth ? 10 : 16,
                    _pageInset,
                    width < IsleLayout.compactPageWidth ? 6 : 8,
                  ),
                  child: Row(
                    children: [
                      Semantics(
                        button: true,
                        label: '全选 ${section.title}',
                        child: InkWell(
                          key: ValueKey('selectMonth_${section.key}'),
                          borderRadius: BorderRadius.circular(20),
                          onTap: _batchBusy
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
                                  section.items
                                          .take(50)
                                          .every(
                                            (item) => _selectedAssets.contains(
                                              item.id,
                                            ),
                                          )
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  size: 20,
                                  color:
                                      section.items
                                          .take(50)
                                          .every(
                                            (item) => _selectedAssets.contains(
                                              item.id,
                                            ),
                                          )
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant
                                            .withValues(alpha: 0.65),
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
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: gridHorizontalInset),
                sliver: SliverGrid.builder(
                  itemCount: section.items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: gridSpacing,
                    mainAxisSpacing: gridSpacing,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, index) {
                    final asset = section.items[index];
                    return Semantics(
                      button: true,
                      label:
                          '${asset.name}, ${asset.isVideo ? '视频' : '照片'}，${formatMediaDate(asset.takenAt)}${asset.personalFavorite ? '，我的收藏' : ''}${asset.favorite ? '，共享收藏' : ''}',
                      child: InkWell(
                        onTap: () => _openAsset(asset),
                        onLongPress: () => _toggleSelection(asset),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(tileRadius),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Hero(
                                tag: 'photo_thumb_${asset.id}',
                                child: asset.isRaw
                                    ? Container(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerLow,
                                        child: const Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons
                                                    .insert_drive_file_outlined,
                                                size: 26,
                                              ),
                                              Text(
                                                'RAW',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : AuthenticatedMediaImage(
                                        api: widget.api,
                                        memoryCache: _photoCache,
                                        path:
                                            '/api/v2/photos/${asset.id}/thumbnail',
                                        maxBytes: 4 * 1024 * 1024,
                                        fit: BoxFit.cover,
                                        loadingBuilder: (context) => Container(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerLow,
                                        ),
                                        errorBuilder: (context, error, retry) =>
                                            Container(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHigh,
                                              child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  Center(
                                                    child: Icon(
                                                      asset.isVideo
                                                          ? Icons.movie_outlined
                                                          : Icons
                                                                .image_not_supported_outlined,
                                                    ),
                                                  ),
                                                  Positioned(
                                                    left: 0,
                                                    top: 0,
                                                    child: DecoratedBox(
                                                      decoration:
                                                          const BoxDecoration(
                                                            color:
                                                                Colors.black54,
                                                            shape:
                                                                BoxShape.circle,
                                                          ),
                                                      child: IconButton(
                                                        tooltip: '重试缩略图',
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        onPressed: retry,
                                                        icon: const Icon(
                                                          Icons.refresh,
                                                          size: 16,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                      ),
                              ),
                              if (_selecting)
                                Positioned(
                                  top: 5,
                                  left: 5,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: _selectedAssets.contains(asset.id)
                                          ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                          : Colors.black54,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Icon(
                                        _selectedAssets.contains(asset.id)
                                            ? Icons.check_rounded
                                            : Icons.circle_outlined,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              if (asset.isVideo)
                                Positioned(
                                  right: 5,
                                  bottom: 5,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 18,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 6,
                                            color: Colors.black87,
                                          ),
                                        ],
                                      ),
                                      if (asset.durationSeconds > 0)
                                        Text(
                                          formatMediaSeconds(
                                            asset.durationSeconds,
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            shadows: [
                                              Shadow(
                                                blurRadius: 6,
                                                color: Colors.black87,
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              if (asset.favorite || asset.personalFavorite)
                                Positioned(
                                  top: 7,
                                  right: 7,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (asset.personalFavorite)
                                        Icon(
                                          Icons.star,
                                          color: Color(0xFFFFD76C),
                                          size: 17,
                                          shadows: [
                                            Shadow(
                                              blurRadius: 5,
                                              color: Colors.black54,
                                            ),
                                          ],
                                        ),
                                      if (asset.favorite &&
                                          asset.personalFavorite)
                                        const SizedBox(width: 4),
                                      if (asset.favorite)
                                        Icon(
                                          Icons.favorite,
                                          color: Colors.white,
                                          size: 18,
                                          shadows: [
                                            Shadow(
                                              blurRadius: 5,
                                              color: Colors.black54,
                                            ),
                                          ],
                                        ),
                                    ],
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
          ],
        );
      },
    );
  }
}
