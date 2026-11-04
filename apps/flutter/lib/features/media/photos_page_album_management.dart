part of 'photos_page.dart';

extension _PhotosPageAlbumManagement on _PhotosPageState {
  Widget _albumCards(
    BuildContext sheetContext,
    List<MediaAlbum> albums, {
    required bool private,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          constraints.maxWidth >= 660 &&
              MediaQuery.textScalerOf(context).scale(14) < 21
          ? 3
          : constraints.maxWidth >= 320 &&
                MediaQuery.textScalerOf(context).scale(14) < 21
          ? 2
          : 1;
      final cardWidth = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final album in albums)
            SizedBox(
              width: cardWidth,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.pop(
                    sheetContext,
                    '${private ? 'private' : 'shared'}:${album.id}',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AspectRatio(
                        aspectRatio: 1.55,
                        child: album.coverAssetId > 0
                            ? AuthenticatedMediaImage(
                                api: widget.api,
                                path:
                                    '/api/v2/photos/${album.coverAssetId}/thumbnail',
                                fit: BoxFit.cover,
                                maxBytes: 4 * 1024 * 1024,
                                loadingBuilder: (_) =>
                                    _albumCoverPlaceholder(private),
                                errorBuilder: (_, _, retry) => Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _albumCoverPlaceholder(private),
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: IconButton(
                                        tooltip: '重试相册封面',
                                        onPressed: retry,
                                        icon: const Icon(Icons.refresh),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : _albumCoverPlaceholder(private),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        child: Text(
                          '${album.name} · ${album.count}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _albumCoverPlaceholder(bool private) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Center(
      child: Icon(
        private ? Icons.photo_library_rounded : Icons.collections_rounded,
        size: 32,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Future<void> _refreshAlbums() async {
    final generation = ++_albumsGeneration;
    try {
      final albums = await _albumRepository.list(PhotoAlbumScope.shared);
      if (!mounted || generation != _albumsGeneration) return;
      _updateState(() => _albums = albums);
    } catch (_) {
      // Keep previously loaded album navigation visible if a refresh fails.
    }
  }

  Future<void> _refreshPrivateAlbums() async {
    final generation = ++_privateAlbumsGeneration;
    try {
      final albums = await _albumRepository.list(PhotoAlbumScope.personal);
      if (!mounted || generation != _privateAlbumsGeneration) return;
      _updateState(() => _privateAlbums = albums);
    } catch (error) {
      if (mounted && generation == _privateAlbumsGeneration) {
        _updateState(() {
          _actionMessage = '私人相册加载失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    }
  }

  Future<PhotoAsset> _toggleFavorite(PhotoAsset asset) async {
    if (!widget.isAdmin && !asset.canWrite) {
      throw StateError('当前账号对此媒体只有查看权限。');
    }
    final favorite = !asset.favorite;
    await widget.api.send(
      'POST',
      '/api/v2/photos/${asset.id}/favorite',
      body: <String, Object>{'favorite': favorite},
    );
    if (!mounted) return asset.withFavorite(favorite);
    final updated = asset.withFavorite(favorite);
    _updateState(() {
      final index = _assets.indexWhere((item) => item.id == asset.id);
      if (index >= 0) {
        if (_favoritesOnly && !favorite) {
          _assets.removeAt(index);
        } else {
          _assets[index] = updated;
        }
      }
      _actionMessage = favorite ? '已加入共享收藏。' : '已从共享收藏移除。';
      _actionIsError = false;
    });
    return updated;
  }

  Future<PhotoAsset> _togglePersonalFavorite(PhotoAsset asset) async {
    final favorite = !asset.personalFavorite;
    await widget.api.send(
      'POST',
      '/api/v2/photos/${asset.id}/personal-favorite',
      body: <String, Object>{'favorite': favorite},
    );
    final updated = asset.withPersonalFavorite(favorite);
    if (!mounted) return updated;
    _updateState(() {
      final index = _assets.indexWhere((item) => item.id == asset.id);
      if (index >= 0) {
        if (_personalFavoritesOnly && !favorite) {
          _assets.removeAt(index);
        } else {
          _assets[index] = updated;
        }
      }
      _actionMessage = favorite ? '已加入我的收藏。' : '已从我的收藏移除。';
      _actionIsError = false;
    });
    return updated;
  }

  Future<void> _createOrRenameAlbum({MediaAlbum? album}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlbumNameDialog(initialName: album?.name ?? ''),
    );
    if (name == null || !mounted) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.save(
        PhotoAlbumScope.shared,
        name: name,
        albumId: album?.id,
      );
      if (!mounted) return;
      _updateState(() {
        _actionMessage = album == null ? '相册已创建。' : '相册名称已更新。';
        _actionIsError = false;
      });
      await _refreshAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _createOrRenamePrivateAlbum({MediaAlbum? album}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          AlbumNameDialog(initialName: album?.name ?? '', privateAlbum: true),
    );
    if (name == null || !mounted) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.save(
        PhotoAlbumScope.personal,
        name: name,
        albumId: album?.id,
      );
      if (!mounted) return;
      _updateState(() {
        _actionMessage = album == null ? '私人相册已创建，仅当前账号可见。' : '私人相册名称已更新。';
        _actionIsError = false;
      });
      await _refreshPrivateAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _deleteAlbum(MediaAlbum album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除相册？'),
        content: Text('只会删除“${album.name}”及其中的关联。原始照片和视频会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除相册'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.delete(PhotoAlbumScope.shared, album.id);
      if (!mounted) return;
      if (_activeAlbum == album.id) {
        _activeAlbum = 0;
        _favoritesOnly = false;
      }
      _updateState(() {
        _actionMessage = '相册已删除，原始媒体仍保留。';
        _actionIsError = false;
      });
      await Future.wait([_refreshAlbums(), _loadAssets(reset: true)]);
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _deletePrivateAlbum(MediaAlbum album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除私人相册？'),
        content: Text('只会删除“${album.name}”及其中的关联。原始照片、视频和共享相册都会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除私人相册'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.delete(PhotoAlbumScope.personal, album.id);
      if (!mounted) return;
      final wasCurrent = _activePrivateAlbum == album.id;
      if (wasCurrent) _activePrivateAlbum = 0;
      _updateState(() {
        _actionMessage = '私人相册已删除，原始媒体和共享相册仍保留。';
        _actionIsError = false;
      });
      await Future.wait([
        _refreshPrivateAlbums(),
        if (wasCurrent) _loadAssets(reset: true),
      ]);
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _addToAlbum(int albumId, int assetId) async {
    if (!widget.isAdmin || albumId < 1) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.addItem(
        PhotoAlbumScope.shared,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      _updateState(() {
        _actionMessage = '已加入相册。';
        _actionIsError = false;
      });
      await _refreshAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _removeFromAlbum(int albumId, int assetId) async {
    if (!widget.isAdmin || albumId < 1) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.removeItem(
        PhotoAlbumScope.shared,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      _updateState(() {
        _actionMessage = '已从相册移出，原始媒体仍保留。';
        _actionIsError = false;
      });
      await Future.wait([_refreshAlbums(), _loadAssets(reset: true)]);
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _addToPrivateAlbum(int albumId, int assetId) async {
    if (albumId < 1) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.addItem(
        PhotoAlbumScope.personal,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      _updateState(() {
        _actionMessage = '已加入我的私人相册。';
        _actionIsError = false;
      });
      await _refreshPrivateAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _removeFromPrivateAlbum(int albumId, int assetId) async {
    if (albumId < 1) return;
    _updateState(() => _albumBusy = true);
    try {
      await _albumRepository.removeItem(
        PhotoAlbumScope.personal,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      final wasCurrent = _activePrivateAlbum == albumId;
      if (wasCurrent) _assets.removeWhere((item) => item.id == assetId);
      _updateState(() {
        _actionMessage = '已从私人相册移出，原始媒体仍保留。';
        _actionIsError = false;
      });
      await Future.wait([
        _refreshPrivateAlbums(),
        if (wasCurrent) _loadAssets(reset: true),
      ]);
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _albumBusy = false);
    }
  }

  Future<void> _browseAlbums() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '我的相册',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: '关闭相册',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '把珍贵照片整理成自己的收藏集',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建私人相册'),
                  onPressed: _albumBusy
                      ? null
                      : () => Navigator.pop(context, 'createPrivate'),
                ),
                if (widget.isAdmin)
                  TextButton.icon(
                    icon: const Icon(Icons.people_outline_rounded),
                    label: const Text('新建相册'),
                    onPressed: _albumBusy
                        ? null
                        : () => Navigator.pop(context, 'createShared'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text('我的私人相册', style: Theme.of(context).textTheme.titleMedium),
            Text('仅当前账号可见', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            if (_privateAlbums.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('还没有私人相册，可创建一个来整理照片。'),
              ),
            _albumCards(context, _privateAlbums, private: true),
            const SizedBox(height: 24),
            Text('共享相册', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            if (_albums.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('还没有共享相册。'),
              ),
            _albumCards(context, _albums, private: false),
          ],
        ),
      ),
    );
    if (!mounted || value == null) return;
    if (value == 'createPrivate') {
      await _createOrRenamePrivateAlbum();
    } else if (value == 'createShared') {
      await _createOrRenameAlbum();
    } else if (value.startsWith('private:')) {
      _selectView(privateAlbumId: int.parse(value.split(':').last));
    } else {
      _selectView(albumId: int.parse(value.split(':').last));
    }
  }
}
