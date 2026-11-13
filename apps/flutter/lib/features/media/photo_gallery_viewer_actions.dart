part of 'photo_gallery_viewer.dart';

extension _PhotoGalleryViewerActions on _PhotoGalleryViewerState {
  Future<void> _mediaAction(String action) async {
    if (_busy || !mounted) return;
    final asset = _current;
    switch (action) {
      case 'shared':
        if (widget.canEditSharedFavorite(asset)) {
          await _favorite(shared: true);
        }
      case 'export':
        await _exportCurrent();
      case 'offline':
        await _saveOfflinePhoto();
      case 'live':
        _stopSlideshow();
        _updateState(() => _livePlaying = !_livePlaying);
      case 'remove_album':
        final removeCallback = widget.onRemoveFromCurrentAlbum;
        if (removeCallback == null) return;
        _updateState(() {
          _busy = true;
          _error = null;
        });
        try {
          final removed = await removeCallback(asset);
          if (removed && mounted) _removeCurrentItem();
        } catch (error) {
          if (mounted) _updateState(() => _error = mediaErrorLabel(error));
        } finally {
          if (mounted) _updateState(() => _busy = false);
        }
      case 'trash':
        if (widget.onDelete == null || !widget.canEditSharedFavorite(asset)) {
          return;
        }
        _updateState(() {
          _busy = true;
          _error = null;
        });
        try {
          final deleted = await widget.onDelete!(asset);
          if (deleted && mounted) _removeCurrentItem();
        } catch (error) {
          if (mounted) _updateState(() => _error = mediaErrorLabel(error));
        } finally {
          if (mounted) _updateState(() => _busy = false);
        }
      case 'folder':
        final callback = widget.onFolderAlbum;
        if (callback == null) return;
        final moved = await callback(asset);
        if (moved && mounted) _removeCurrentItem();
    }
  }

  void _removeCurrentItem() {
    final removed = _current;
    _removedIds.add(removed.id);
    if (_items.length <= 1) {
      Navigator.of(context).pop();
      return;
    }
    _updateState(() {
      _items.removeAt(_index);
      if (_index >= _items.length) {
        _index = _items.length - 1;
      }
      _livePlaying = false;
      _currentZoomed = false;
    });
    if (_controller.hasClients) {
      _controller.jumpToPage(_index);
    }
    unawaited(_loadMore(forceCheck: true));
  }

  Future<void> _openFullDetailsAndSync() async {
    _stopSlideshow();
    final currentId = _current.id;
    await widget.onDetails(_current);
    if (!mounted || widget.onSyncAsset == null) return;
    final synced = widget.onSyncAsset!(currentId);
    if (synced == null) {
      _removeCurrentItem();
      return;
    }
    final idx = _items.indexWhere((item) => item.id == currentId);
    if (idx >= 0) {
      _updateState(() => _items[idx] = synced);
    }
  }

  void _inspectAsset(BuildContext context) {
    if (widget.fileBrowserMode) return;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    if (wide) {
      _stopSlideshow();
      _updateState(() => _showInfoSidebar = !_showInfoSidebar);
      return;
    }
    unawaited(_openFullDetailsAndSync());
  }

  Future<void> _nextVideo() async {
    if (!widget.fileBrowserMode || !_continuousVideo || !mounted) return;
    final next = _items.indexWhere((asset) => asset.isVideo, _index + 1);
    if (next < 0) return;
    await _navigate(next - _index);
  }

  void _showFilePlaylist() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.68,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('当前文件夹 · 图片与视频')),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _items.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: Icon(
                      _items[index].isVideo
                          ? Icons.movie_outlined
                          : Icons.image_outlined,
                    ),
                    title: Text(
                      _items[index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: index == _index,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      unawaited(_navigate(index - _index));
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveOfflinePhoto() async {
    if (_busy || _current.isVideo || widget.offlineAccountId.isEmpty) return;
    _stopSlideshow();
    final asset = _current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('离线保存照片原件？'),
        content: Text(
          '保存“${asset.name}”到本机专属离线照片库。'
          '最多 512 MiB/张、当前离线库最多 2 GiB；照片会保留原始格式，'
          'RAW/HEIC 可能无法在本机直接预览，但可以原样导出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存原件'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _updateState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = OfflinePhotoStore(
        api: widget.api,
        accountId: widget.offlineAccountId,
      );
      await store.save(asset);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('原片已保存到本机离线照片库，断网也可查看或导出。')),
        );
      }
    } catch (error) {
      if (mounted) _updateState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) _updateState(() => _busy = false);
    }
  }

  Future<void> _shareCurrent() async {
    _stopSlideshow();
    final asset = _current;
    try {
      await openMediaFileShare(
        context,
        api: widget.api,
        path: asset.path,
        name: asset.name,
      );
    } catch (error) {
      if (mounted) _updateState(() => _error = mediaErrorLabel(error));
    }
  }

  Future<void> _exportCurrent() async {
    if (_busy) return;
    _stopSlideshow();
    final asset = _current;
    _updateState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await exportMediaFile(
        widget.api,
        path: asset.path,
        name: asset.name,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result)));
      }
    } catch (error) {
      if (mounted) _updateState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) _updateState(() => _busy = false);
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_navigate(1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_navigate(-1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space &&
        !widget.fileBrowserMode &&
        !_current.isVideo) {
      _toggleSlideshow();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF && !widget.fileBrowserMode) {
      final shared =
          HardwareKeyboard.instance.isShiftPressed &&
          widget.canEditSharedFavorite(_current);
      unawaited(_favorite(shared: shared));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyI && !widget.fileBrowserMode) {
      _inspectAsset(context);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_livePlaying) {
        _updateState(() => _livePlaying = false);
        return KeyEventResult.handled;
      }
      if (_currentZoomed) {
        _updateState(() {
          _currentZoomed = false;
          _resetZoomNonce++;
        });
        return KeyEventResult.handled;
      }
      if (_showInfoSidebar) {
        _updateState(() => _showInfoSidebar = false);
        return KeyEventResult.handled;
      }
      _stopSlideshow();
      unawaited(Navigator.of(context).maybePop());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _loadMore({bool forceCheck = false}) async {
    if (_loadingMore || _index < _items.length - 5) return;
    _loadingMore = true;
    try {
      final next = await widget.onLoadMore();
      if (!mounted) return;
      final existingById = {for (final item in _items) item.id: item};
      final nextById = {for (final item in next) item.id: item};
      var changed = false;
      final merged = <PhotoAsset>[];
      for (final current in _items) {
        final refreshed = nextById[current.id];
        if (refreshed != null &&
            (refreshed.favorite != current.favorite ||
                refreshed.personalFavorite != current.personalFavorite)) {
          merged.add(refreshed);
          changed = true;
        } else {
          merged.add(current);
        }
      }
      for (final candidate in next) {
        if (_removedIds.contains(candidate.id) ||
            existingById.containsKey(candidate.id)) {
          continue;
        }
        merged.add(candidate);
        changed = true;
      }
      if (changed && mounted) {
        _updateState(() => _items = merged);
      }
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _favorite({required bool shared}) async {
    if (_busy) return;
    _updateState(() {
      _busy = true;
      _error = null;
    });
    try {
      final asset = _current;
      final updated = await (shared
          ? widget.onSharedFavorite(asset)
          : widget.onPersonalFavorite(asset));
      if (!mounted) return;
      final index = _items.indexWhere((item) => item.id == updated.id);
      if (index >= 0) _updateState(() => _items[index] = updated);
    } catch (error) {
      if (mounted) _updateState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) _updateState(() => _busy = false);
    }
  }
}
