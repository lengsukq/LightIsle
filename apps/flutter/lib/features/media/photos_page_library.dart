part of 'photos_page.dart';

extension _PhotosPageLibrary on _PhotosPageState {
  Future<void> _loadAssets({required bool reset, int? startCursor}) async {
    if (!reset && (_loading || _loadingMore || _nextCursor == 0)) return;
    final generation = ++_listGeneration;
    final cursor = reset ? (startCursor ?? 0) : _nextCursor;
    _updateState(() {
      if (reset) {
        _assets.clear();
        _nextCursor = 0;
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
    if (_favoritesOnly) query['favorites'] = '1';
    if (_personalFavoritesOnly) query['personal'] = '1';
    if (_onThisDay) query['onThisDay'] = '1';
    if (_query.isNotEmpty) query['q'] = _query;
    if (_mediaType.isNotEmpty) query['type'] = _mediaType;
    try {
      final response = await widget.api.get('/api/v2/photos', query: query);
      if (!mounted || generation != _listGeneration) return;
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
        _scanError = status.lastError.isEmpty ? null : status.lastError;
      });
      if (finished) {
        await Future.wait([
          _loadAssets(reset: true),
          _refreshAlbums(),
          _refreshPrivateAlbums(),
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
    bool onThisDay = false,
  }) async {
    if (_activeAlbum == albumId &&
        _favoritesOnly == favorites &&
        _personalFavoritesOnly == personalFavorites &&
        _activePrivateAlbum == privateAlbumId &&
        _onThisDay == onThisDay) {
      return;
    }
    _updateState(() {
      _selecting = false;
      _selectedAssets.clear();
      _activeAlbum = albumId;
      _activePrivateAlbum = privateAlbumId;
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
      !_favoritesOnly &&
      !_personalFavoritesOnly &&
      !_onThisDay &&
      _query.isEmpty &&
      _mediaType.isEmpty;

  Future<void> _chooseTimelineMonth() async {
    if (!_fullTimelineSelected || _loading) return;
    List<Map<String, dynamic>> months;
    try {
      final response = await widget.api.get('/api/v2/photos/timeline');
      if (!mounted) return;
      final raw = response['months'];
      if (raw is! List) throw const FormatException('缺少年月索引。');
      months =
          [
            for (final value in raw)
              if (value is Map) Map<String, dynamic>.from(value),
          ].where((entry) {
            final year = entry['year'];
            final month = entry['month'];
            final offset = entry['firstIndex'];
            return year is int &&
                year >= 1970 &&
                year <= 9999 &&
                month is int &&
                month >= 1 &&
                month <= 12 &&
                offset is int &&
                offset >= 0;
          }).toList();
    } catch (error) {
      if (mounted) {
        _updateState(() => _loadError = '读取年月索引失败：${mediaErrorLabel(error)}');
      }
      return;
    }
    if (!mounted) return;
    if (months.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图库暂无可跳转的拍摄年月。')));
      return;
    }
    final cursor = await showModalBottomSheet<int>(
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
                  itemCount: months.length,
                  itemBuilder: (context, index) {
                    final month = months[index];
                    return ListTile(
                      leading: const Icon(Icons.calendar_month_outlined),
                      title: Text('${month['year']} 年 ${month['month']} 月'),
                      trailing: Text('${month['count'] ?? 0} 项'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        month['firstIndex'] as int,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (cursor == null || !mounted) return;
    await _loadAssets(reset: true, startCursor: cursor);
    if (mounted && _timelineScroll.hasClients) {
      _timelineScroll.jumpTo(0);
    }
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
          offlineAccountId: widget.offlineAccountId,
          assets: List<PhotoAsset>.of(_assets),
          initialIndex: _assets.indexWhere((item) => item.id == asset.id),
          canEditSharedFavorite: (item) => widget.isAdmin || item.canWrite,
          onSharedFavorite: _toggleFavorite,
          onPersonalFavorite: _togglePersonalFavorite,
          onDelete: (asset) => _trashAssets([asset]),
          onDetails: _showAssetDetails,
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

  Future<void> _showAssetDetails(PhotoAsset asset) async {
    await showDialog<void>(
      context: context,
      useSafeArea: true,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (context) => PhotoDetailDialog(
        api: widget.api,
        asset: asset,
        albums: _albums,
        privateAlbums: _privateAlbums,
        isAdmin: widget.isAdmin,
        currentAlbumId: _activeAlbum,
        currentPrivateAlbumId: _activePrivateAlbum,
        personalFavoritesOnly: _personalFavoritesOnly,
        canToggleFavorite: widget.isAdmin || asset.canWrite,
        onToggleFavorite: _toggleFavorite,
        onTogglePersonalFavorite: _togglePersonalFavorite,
        onAddToAlbum: _addToAlbum,
        onRemoveFromAlbum: _removeFromAlbum,
        onAddToPrivateAlbum: _addToPrivateAlbum,
        onRemoveFromPrivateAlbum: _removeFromPrivateAlbum,
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
    IconData? icon,
  }) => MediaFilterChip(
    label: label,
    selected: selected,
    onSelected: onSelected,
    icon: icon,
  );

  Widget _buildGrid() {
    if (_loading && _assets.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(56),
          child: Center(child: CircularProgressIndicator()),
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
      final title = album != null
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
      final message = album != null
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
          : '点击上传，把设备里的照片与视频保存到 NAS。';
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.photo_library_outlined,
          title: title,
          message: message,
          action:
              (album != null ||
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
        final baseColumns = width < 420
            ? 3
            : width < 680
            ? 4
            : width < 920
            ? 5
            : (width / 150).floor().clamp(5, 10);
        // Thumbnails are image-based, not text-based; increasing system font
        // size must not turn the gallery back into a sparse file list.
        final columns = baseColumns;
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
                  padding: EdgeInsets.fromLTRB(_pageInset, 22, _pageInset, 11),
                  child: Row(
                    children: [
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
                padding: const EdgeInsets.symmetric(horizontal: 2),
                sliver: SliverGrid.builder(
                  itemCount: section.items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
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
                          borderRadius: BorderRadius.circular(2),
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
