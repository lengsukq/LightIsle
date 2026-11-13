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
    final generation = ++_catalog.sharedGeneration;
    try {
      final albums = await _albumRepository.list(PhotoAlbumScope.shared);
      if (!mounted || generation != _catalog.sharedGeneration) return;
      _updateState(() => _catalog.sharedAlbums = albums);
    } catch (_) {
      // Keep previously loaded album navigation visible if a refresh fails.
    }
  }

  Future<void> _refreshFolderAlbums() async {
    try {
      final result = await widget.api.get('/api/v2/photos/folder-albums');
      if (!mounted) return;
      final list = objectList(result['albums']);
      _updateState(() => _catalog.folderAlbums = list);
    } catch (_) {
      // Folder albums are optional in environments without assigned personal photo dirs.
    }
  }

  Future<void> _refreshPrivateAlbums() async {
    final generation = ++_catalog.privateGeneration;
    if (mounted) {
      _updateState(() => _catalog.privateRefreshing = true);
    }
    try {
      final albums = await _albumRepository.list(PhotoAlbumScope.personal);
      if (!mounted || generation != _catalog.privateGeneration) return;
      _updateState(() {
        _catalog.privateAlbums = albums;
        _catalog.privateFailure = null;
      });
    } catch (error) {
      if (mounted && generation == _catalog.privateGeneration) {
        _updateState(() => _catalog.privateFailure = error);
      }
    } finally {
      if (mounted && generation == _catalog.privateGeneration) {
        _updateState(() => _catalog.privateRefreshing = false);
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
      final index = _feed.assets.indexWhere((item) => item.id == asset.id);
      if (index >= 0) {
        if (_scope.favoritesOnly && !favorite) {
          _feed.assets.removeAt(index);
        } else {
          _feed.assets[index] = updated;
        }
      }
      _feed.setActionFeedback(favorite ? '已加入共享收藏。' : '已从共享收藏移除。');
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
      final index = _feed.assets.indexWhere((item) => item.id == asset.id);
      if (index >= 0) {
        if (_scope.personalFavoritesOnly && !favorite) {
          _feed.assets.removeAt(index);
        } else {
          _feed.assets[index] = updated;
        }
      }
      _feed.setActionFeedback(favorite ? '已加入我的收藏。' : '已从我的收藏移除。');
    });
    return updated;
  }

  Future<void> _createOrRenameAlbum({MediaAlbum? album}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlbumNameDialog(initialName: album?.name ?? ''),
    );
    if (name == null || !mounted) return;
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.save(
        PhotoAlbumScope.shared,
        name: name,
        albumId: album?.id,
      );
      if (!mounted) return;
      _updateState(
        () => _feed.setActionFeedback(album == null ? '相册已创建。' : '相册名称已更新。'),
      );
      await _refreshAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
    }
  }

  Future<void> _createOrRenamePrivateAlbum({MediaAlbum? album}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          AlbumNameDialog(initialName: album?.name ?? '', privateAlbum: true),
    );
    if (name == null || !mounted) return;
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.save(
        PhotoAlbumScope.personal,
        name: name,
        albumId: album?.id,
      );
      if (!mounted) return;
      _updateState(
        () => _feed.setActionFeedback(
          album == null ? '私人相册已创建，仅当前账号可见。' : '私人相册名称已更新。',
        ),
      );
      await _refreshPrivateAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
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
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.delete(PhotoAlbumScope.shared, album.id);
      if (!mounted) return;
      if (_scope.activeAlbum == album.id) {
        _scope.activeAlbum = 0;
        _scope.favoritesOnly = false;
      }
      _updateState(() => _feed.setActionFeedback('相册已删除，原始媒体仍保留。'));
      await Future.wait([_refreshAlbums(), _loadAssets(reset: true)]);
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
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
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.delete(PhotoAlbumScope.personal, album.id);
      if (!mounted) return;
      final wasCurrent = _scope.activePrivateAlbum == album.id;
      if (wasCurrent) _scope.activePrivateAlbum = 0;
      _updateState(() => _feed.setActionFeedback('私人相册已删除，原始媒体和共享相册仍保留。'));
      await Future.wait([
        _refreshPrivateAlbums(),
        if (wasCurrent) _loadAssets(reset: true),
      ]);
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
    }
  }

  Future<void> _addToAlbum(int albumId, int assetId) async {
    if (!widget.isAdmin || albumId < 1) return;
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.addItem(
        PhotoAlbumScope.shared,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      _updateState(() => _feed.setActionFeedback('已加入相册。'));
      await _refreshAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
    }
  }

  Future<void> _removeFromAlbum(int albumId, int assetId) async {
    if (!widget.isAdmin || albumId < 1) return;
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.removeItem(
        PhotoAlbumScope.shared,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      _updateState(() => _feed.setActionFeedback('已从相册移出，原始媒体仍保留。'));
      await Future.wait([_refreshAlbums(), _loadAssets(reset: true)]);
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
    }
  }

  Future<void> _addToPrivateAlbum(int albumId, int assetId) async {
    if (albumId < 1) return;
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.addItem(
        PhotoAlbumScope.personal,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      _updateState(() => _feed.setActionFeedback('已加入我的私人相册。'));
      await _refreshPrivateAlbums();
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
    }
  }

  Future<void> _removeFromPrivateAlbum(int albumId, int assetId) async {
    if (albumId < 1) return;
    _updateState(() => _catalog.busy = true);
    try {
      await _albumRepository.removeItem(
        PhotoAlbumScope.personal,
        albumId: albumId,
        assetId: assetId,
      );
      if (!mounted) return;
      final wasCurrent = _scope.activePrivateAlbum == albumId;
      if (wasCurrent) _feed.assets.removeWhere((item) => item.id == assetId);
      _updateState(() => _feed.setActionFeedback('已从私人相册移出，原始媒体仍保留。'));
      await Future.wait([
        _refreshPrivateAlbums(),
        if (wasCurrent) _loadAssets(reset: true),
      ]);
    } catch (error) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(error), isError: true),
        );
      }
      rethrow;
    } finally {
      if (mounted) _updateState(() => _catalog.busy = false);
    }
  }

  Future<void> _browseAlbums() async {
    // Albums are a destination, not a temporary picker floating above the
    // timeline. Keep a proper back stack and preserve the timeline underneath.
    final value = await Navigator.of(context).push<String>(
      buildIslePageRoute<String>(
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
    if (value == 'collection:personalFavorites') {
      _selectView(personalFavorites: true);
    } else if (value == 'collection:sharedFavorites') {
      _selectView(favorites: true);
    } else if (value == 'collection:onThisDay') {
      _selectView(onThisDay: true);
    } else if (value == 'collection:map') {
      unawaited(_openPhotoMap());
    } else if (value.startsWith('folder:')) {
      final path = Uri.decodeComponent(value.substring('folder:'.length));
      _selectView(folderPath: path, folderName: path.split('/').last);
    } else if (value.startsWith('private:')) {
      _selectView(privateAlbumId: int.parse(value.split(':').last));
    } else if (value.startsWith('shared:')) {
      _selectView(albumId: int.parse(value.split(':').last));
    }
  }
}

class AlbumNameDialog extends StatefulWidget {
  const AlbumNameDialog({
    this.initialName = '',
    this.privateAlbum = false,
    super.key,
  });

  final String initialName;
  final bool privateAlbum;

  @override
  State<AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<AlbumNameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final length = name.runes.length;
    if (length == 0) {
      setState(() => _error = '请输入相册名称。');
      return;
    }
    if (length > 60 || RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(name)) {
      setState(() => _error = '相册名称需为 1–60 个字符，且不能包含控制字符。');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initialName.isEmpty
          ? widget.privateAlbum
                ? '新建私人相册'
                : '新建相册'
          : widget.privateAlbum
          ? '修改私人相册名称'
          : '修改相册名称',
    ),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 120,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: '相册名称',
        errorText: _error,
        helperText: '最多 60 个字符',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(widget.initialName.isEmpty ? '创建' : '保存'),
      ),
    ],
  );
}
