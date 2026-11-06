part of 'photos_page.dart';

extension _PhotosPageAlbumManagement on _PhotosPageState {
  Widget _albumCards(
    BuildContext sheetContext,
    List<MediaAlbum> albums, {
    required bool private,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      // A cover is a small collection tile, not a card that expands to fill
      // a column. In particular, one album must never become a giant cover.
      final columns = ((constraints.maxWidth + 12) / 176).floor().clamp(1, 8);
      final available = (constraints.maxWidth - (columns - 1) * 12) / columns;
      final cardWidth = available.clamp(1.0, 168.0);
      return Wrap(
        spacing: 12,
        runSpacing: 16,
        children: [
          for (final album in albums)
            SizedBox(
              key: ValueKey(
                'albumCard_${private ? 'private' : 'shared'}_${album.id}',
              ),
              width: cardWidth,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(
                    sheetContext,
                    '${private ? 'private' : 'shared'}:${album.id}',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 1.22,
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
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              album.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${album.count} 项 · ${private ? '仅自己可见' : '家庭共享'}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
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

  Widget _albumCoverPlaceholder(bool private) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerLow,
            scheme.primaryContainer.withValues(alpha: .55),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          private ? Icons.photo_library_outlined : Icons.collections_outlined,
          size: 27,
          color: scheme.primary.withValues(alpha: .8),
        ),
      ),
    );
  }

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
    if (mounted) {
      _updateState(() => _privateAlbumsRefreshing = true);
    }
    try {
      final albums = await _albumRepository.list(PhotoAlbumScope.personal);
      if (!mounted || generation != _privateAlbumsGeneration) return;
      _updateState(() {
        _privateAlbums = albums;
        _privateAlbumsFailure = null;
      });
    } catch (error) {
      if (mounted && generation == _privateAlbumsGeneration) {
        _updateState(() => _privateAlbumsFailure = error);
      }
    } finally {
      if (mounted && generation == _privateAlbumsGeneration) {
        _updateState(() => _privateAlbumsRefreshing = false);
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
    // Albums are a destination, not a temporary picker floating above the
    // timeline. Keep a proper back stack and preserve the timeline underneath.
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (context) => StatefulBuilder(
          builder: (context, refreshPage) => Scaffold(
            key: const ValueKey('photoAlbumsPage'),
            appBar: const IsleAppBar(title: Text('相册')),
            body: SafeArea(child: _albumOverviewBody(context, refreshPage)),
          ),
        ),
      ),
    );
    if (!mounted || value == null) return;
    if (value.startsWith('folder:')) {
      final path = Uri.decodeComponent(value.substring('folder:'.length));
      _selectView(folderPath: path, folderName: path.split('/').last);
    } else if (value.startsWith('private:')) {
      _selectView(privateAlbumId: int.parse(value.split(':').last));
    } else if (value.startsWith('shared:')) {
      _selectView(albumId: int.parse(value.split(':').last));
    }
  }

  Widget _albumOverviewBody(BuildContext pageContext, StateSetter refreshPage) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final sideBySide = constraints.maxWidth >= 600 && textScale < 1.6;
        final inlineActions = constraints.maxWidth >= 570 && textScale < 1.4;
        final inset = constraints.maxWidth >= 600 ? 28.0 : 16.0;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;

        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '我的相册',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '按主题整理照片，也可以与家人分享',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('文件夹相册'),
              onPressed: _albumBusy
                  ? null
                  : () async {
                      final root = widget.api.selectedRoot?.identity;
                      final album = await Navigator.of(pageContext)
                          .push<FolderAlbumSelection>(
                            MaterialPageRoute(
                              builder: (_) => FolderAlbumsPage(api: widget.api),
                            ),
                          );
                      if (pageContext.mounted &&
                          album != null &&
                          widget.api.selectedRoot?.identity == root) {
                        Navigator.pop(
                          pageContext,
                          'folder:${Uri.encodeComponent(album.path)}',
                        );
                      }
                    },
            ),
          ],
        );

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              key: const ValueKey('photoAlbumOverviewList'),
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 36),
              children: [
                if (inlineActions)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: heading),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: actions,
                        ),
                      ),
                    ],
                  )
                else ...[
                  heading,
                  const SizedBox(height: 12),
                  actions,
                ],
                if (_actionIsError && _actionMessage != null) ...[
                  const SizedBox(height: 12),
                  MediaStatusBanner(message: _actionMessage!, isError: true),
                ],
                const SizedBox(height: 22),
                if (sideBySide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _albumOverviewSection(
                          pageContext,
                          refreshPage,
                          private: true,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _albumOverviewSection(
                          pageContext,
                          refreshPage,
                          private: false,
                        ),
                      ),
                    ],
                  )
                else ...[
                  _albumOverviewSection(
                    pageContext,
                    refreshPage,
                    private: true,
                  ),
                  const SizedBox(height: 16),
                  _albumOverviewSection(
                    pageContext,
                    refreshPage,
                    private: false,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _albumOverviewSection(
    BuildContext pageContext,
    StateSetter refreshPage, {
    required bool private,
  }) {
    final scheme = Theme.of(pageContext).colorScheme;
    final albums = private ? _privateAlbums : _albums;
    return Container(
      key: ValueKey(private ? 'privateAlbumSection' : 'sharedAlbumSection'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: .55),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _albumSectionHeading(
            pageContext,
            private ? '旧版私人相册' : '旧版共享相册',
            albums.length,
            private ? '仅自己可见' : '家庭成员共享',
          ),
          const SizedBox(height: 14),
          if (private && _privateAlbumsFailure != null)
            MediaStatusBanner(
              message: '私人相册暂时无法读取：${mediaErrorLabel(_privateAlbumsFailure!)}',
              isError: true,
              trailing: TextButton(
                onPressed: _privateAlbumsRefreshing
                    ? null
                    : () async {
                        await _refreshPrivateAlbums();
                        if (pageContext.mounted) refreshPage(() {});
                      },
                child: const Text('重试'),
              ),
            )
          else if (albums.isEmpty)
            _emptyAlbumSection(
              pageContext,
              private
                  ? Icons.lock_outline_rounded
                  : Icons.people_outline_rounded,
              private ? '没有旧版私人相册' : '没有旧版共享相册',
              private
                  ? '新建相册使用真实文件夹'
                  : widget.isAdmin
                  ? '现有共享相册会继续保留'
                  : '家庭共享相册将显示在这里',
            )
          else
            _albumCards(pageContext, albums, private: private),
        ],
      ),
    );
  }

  Widget _albumSectionHeading(
    BuildContext context,
    String title,
    int count,
    String description,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Flexible(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      const SizedBox(height: 3),
      Text(
        description,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  Widget _emptyAlbumSection(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}
