part of 'photos_page.dart';

extension _PhotosPageBatchActions on _PhotosPageState {
  Future<bool> _trashAssets(List<PhotoAsset> assets) async {
    if (_batchBusy ||
        assets.isEmpty ||
        assets.length > 50 ||
        assets.any((asset) => !widget.isAdmin && !asset.canWrite)) {
      if (mounted) {
        _updateState(() {
          _actionMessage = '仅可删除当前目录中有写入权限的文件，每次最多 50 项。';
          _actionIsError = true;
        });
      }
      return false;
    }
    final root = widget.api.selectedRoot?.identity ?? 'default';
    final generation = _listGeneration;
    final paths = List<String>.unmodifiable(assets.map((a) => a.path));
    bool current() =>
        mounted &&
        generation == _listGeneration &&
        (widget.api.selectedRoot?.identity ?? 'default') == root;
    final confirmed = await confirmAction(
      context,
      '移入回收站',
      '将选中的 ${assets.length} 个照片或视频原文件移入回收站？之后可在文件管理中恢复。',
      action: '移入回收站',
    );
    if (!confirmed || !current()) return false;
    _updateState(() => _batchBusy = true);
    try {
      final result = await MediaBatchOperations(widget.api)
          .trashOriginals(paths: paths, stillCurrent: current);
      if (!mounted) return false;
      if (!current() || result.cancelled) {
        _updateState(() {
          _actionMessage = '存储根已变化，已停止后续操作；请返回原硬盘核对回收站。';
          _actionIsError = true;
        });
        return false;
      }
      _updateState(() {
        _selectedAssets.clear();
        _selecting = false;
        _actionMessage = result.needsRootCheck
            ? '已确认 ${result.completed}/${assets.length} 项移入回收站。硬盘连接发生变化，部分操作结果不确定；请重新连接原硬盘，检查原目录和回收站后再重试。'
            : '已移入回收站 ${result.completed}/${assets.length} 项。';
        _actionIsError = result.error != null;
      });
      await _loadAssets(reset: true);
      return result.error == null && result.completed == assets.length;
    } catch (error) {
      if (mounted && current()) {
        _updateState(() {
          _actionMessage = '未能确认移入回收站的结果：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
      return false;
    } finally {
      if (mounted) _updateState(() => _batchBusy = false);
    }
  }

  Future<void> _batchTrashAssets() async {
    final chosen = _assets
        .where((a) => _selectedAssets.contains(a.id))
        .toList();
    if (chosen.length != _selectedAssets.length) {
      _updateState(() {
        _actionMessage = '媒体列表已经变化，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    await _trashAssets(chosen);
  }

  void _selectVisiblePhotos() {
    if (_batchBusy) return;
    final visible = _assets.take(50).map((asset) => asset.id).toSet();
    _updateState(() {
      _selecting = true;
      if (visible.every(_selectedAssets.contains)) {
        _selectedAssets.removeAll(visible);
      } else {
        _selectedAssets
          ..clear()
          ..addAll(visible);
      }
    });
  }

  void _toggleSectionSelection(List<PhotoAsset> sectionItems) {
    if (_batchBusy || sectionItems.isEmpty) return;
    HapticFeedback.selectionClick();
    final ids = sectionItems.take(50).map((asset) => asset.id).toList();
    final allSelected = ids.every(_selectedAssets.contains);
    var capped = false;
    _updateState(() {
      if (allSelected) {
        _selectedAssets.removeAll(ids);
        if (_selectedAssets.isEmpty) _selecting = false;
      } else {
        _selecting = true;
        for (final id in ids) {
          if (_selectedAssets.length >= 50) {
            capped = true;
            break;
          }
          _selectedAssets.add(id);
        }
        if (sectionItems.length > 50) capped = true;
      }
    });
    if (capped && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('每次最多选择 50 项媒体。')),
      );
    }
  }

  bool _batchSelectionCurrent(
    String rootIdentity,
    int listGeneration,
    Set<int> selectedIds,
  ) =>
      mounted &&
      _listGeneration == listGeneration &&
      (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity &&
      setEquals(_selectedAssets, selectedIds);

  Future<void> _batchExport() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final selected = Set<int>.unmodifiable(_selectedAssets);
    final items = _assets.where((item) => selected.contains(item.id)).toList();
    if (items.length != selected.length ||
        items.any((item) => item.path.isEmpty)) {
      _updateState(() {
        _actionMessage = '媒体列表已变化，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final generation = _listGeneration;
    bool current() =>
        _batchSelectionCurrent(rootIdentity, generation, selected);
    final originals = <MediaBatchItem>[
      for (final item in items)
        (path: item.path, name: item.name, size: item.size),
    ];
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (mobile && originals.length > 20) {
      _updateState(() {
        _actionMessage = '手机一次最多导出 20 项，请减少选择。';
        _actionIsError = true;
      });
      return;
    }
    if (mobile) {
      final confirmed = await confirmAction(
        context,
        '批量导出原文件',
        '将临时下载 ${items.length} 个原文件到本机，'
            '然后 Android 只选择一次系统保存文件夹，iOS 只显示一次系统分享面板。'
            '总大小不得超过 2 GiB，取消或结束会清理本机临时副本。',
        action: '继续导出',
      );
      if (!confirmed || !mounted) return;
    }
    final directory = mobile
        ? null
        : await FilePicker.getDirectoryPath(dialogTitle: '选择批量媒体保存位置');
    if (!mounted || (!mobile && (directory == null || directory.isEmpty))) {
      return;
    }
    if (!current()) {
      _updateState(() {
        _actionMessage = '共享目录或选择已变化，请重新选择需要导出的媒体。';
        _actionIsError = true;
      });
      return;
    }
    _updateState(() => _batchBusy = true);
    try {
      if (mobile) {
        final message = await MediaBatchOperations(widget.api).exportOnMobile(
          items: originals,
          stillCurrent: current,
          onProgress: (finished, total, name) {
            if (current()) {
              _updateState(() {
                _actionMessage = '正在准备批量导出 $finished/$total 项：$name';
                _actionIsError = false;
              });
            }
          },
        );
        if (current()) {
          _updateState(() {
            _actionMessage = message;
            _actionIsError = false;
          });
        }
      } else {
        final result = await MediaBatchOperations(widget.api).exportToDirectory(
          items: originals,
          directory: directory!,
          stillCurrent: current,
        );
        if (!mounted) return;
        _updateState(() {
          _actionMessage = result.cancelled || !current()
              ? '共享目录已变化，已完成 ${result.completed} 项，剩余操作已停止。'
              : result.error == null
              ? '已保存 ${result.completed} 项原文件到所选文件夹。'
              : '已保存 ${result.completed} 项，剩余文件未处理：${mediaErrorLabel(result.error!)}';
          _actionIsError =
              result.cancelled || result.error != null || !current();
        });
      }
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = '批量导出失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _batchBusy = false);
    }
  }

  Future<void> _batchShare() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final selected = Set<int>.unmodifiable(_selectedAssets);
    final items = _assets.where((item) => selected.contains(item.id)).toList();
    if (items.length != selected.length ||
        items.length > 10 ||
        items.any((item) => item.path.isEmpty)) {
      _updateState(() {
        _actionMessage = '每次最多分享 10 项，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final generation = _listGeneration;
    bool current() =>
        _batchSelectionCurrent(rootIdentity, generation, selected);
    final confirmed = await confirmAction(
      context,
      '分享所选媒体？',
      '将为 ${items.length} 个原文件分别创建有效期 24 小时的公开下载链接。'
          '获得链接的人无需登录；链接仅在本次创建后提供，请妥善发送给收件人。',
      action: '创建并复制链接',
    );
    if (!confirmed || !mounted) return;
    if (!current()) {
      _updateState(() {
        _actionMessage = '共享目录或选择已变化，请重新选择需要分享的媒体。';
        _actionIsError = true;
      });
      return;
    }
    _updateState(() => _batchBusy = true);
    try {
      final result = await MediaBatchOperations(widget.api).createShares(
        items: [for (final item in items) (path: item.path, label: item.name)],
        stillCurrent: current,
      );
      if (!mounted) return;
      if (result.cancelled || !current()) {
        _updateState(() {
          _actionMessage = '共享目录已变化，后续分享已停止。若已创建链接，请在原硬盘的分享列表中撤销。';
          _actionIsError = true;
        });
        return;
      }
      String? failure = result.error == null
          ? null
          : mediaErrorLabel(result.error!);
      if (result.links.isNotEmpty) {
        try {
          await Clipboard.setData(ClipboardData(text: result.links.join('\n')));
        } catch (_) {
          failure ??= '无法复制链接到剪贴板，请进入文件分享列表撤销后重试。';
        }
      }
      if (!mounted || !current()) return;
      _updateState(() {
        _actionMessage = failure == null
            ? '已创建并复制 ${result.completed} 条限时下载链接。'
            : '已创建 ${result.completed} 条链接。$failure';
        _actionIsError = failure != null;
      });
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = '批量分享失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _batchBusy = false);
    }
  }

  void _toggleSelection(PhotoAsset asset) {
    HapticFeedback.selectionClick();
    _updateState(() {
      _selecting = true;
      if (_selectedAssets.contains(asset.id)) {
        _selectedAssets.remove(asset.id);
      } else if (_selectedAssets.length < 50) {
        _selectedAssets.add(asset.id);
      } else {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('每次最多选择 50 项媒体。')));
      }
    });
  }

  Future<void> _batchFavorite() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final selectedItems = _assets
        .where((item) => _selectedAssets.contains(item.id))
        .toList();
    if (selectedItems.isEmpty) return;
    final unmark = selectedItems.every((item) => item.personalFavorite);
    final targets = unmark
        ? selectedItems
        : selectedItems.where((item) => !item.personalFavorite).toList();
    _updateState(() => _batchBusy = true);
    var done = 0;
    String? error;
    for (final asset in targets) {
      try {
        await _togglePersonalFavorite(asset);
        done++;
      } catch (failure) {
        error = mediaErrorLabel(failure);
        break;
      }
    }
    if (!mounted) return;
    _updateState(() {
      _selectedAssets.clear();
      _selecting = false;
      _batchBusy = false;
      _actionMessage = error == null
          ? (unmark ? '已将 $done 项移出我的收藏。' : '已将 $done 项加入我的收藏。')
          : '已完成 $done 项，其他项目未处理：$error';
      _actionIsError = error != null;
    });
  }

  Future<void> _batchRemoveFromCurrentAlbum() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final privateAlbumId = _activePrivateAlbum;
    final sharedAlbumId = widget.isAdmin ? _activeAlbum : 0;
    if (privateAlbumId <= 0 && sharedAlbumId <= 0) return;
    final isPrivate = privateAlbumId > 0;
    final albumId = isPrivate ? privateAlbumId : sharedAlbumId;
    final albumName =
        (isPrivate ? _currentPrivateAlbum?.name : _currentAlbum?.name) ?? '当前相册';
    final selected = Set<int>.unmodifiable(_selectedAssets);
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final generation = _listGeneration;
    bool current() =>
        _batchSelectionCurrent(rootIdentity, generation, selected);

    final confirmed = await confirmAction(
      context,
      '从相册移出',
      '将选中的 ${selected.length} 项从“$albumName”中移出？这只会解除相册关联，不会删除 NAS 中的原始照片或视频。',
      action: '移出相册',
    );
    if (!confirmed || !mounted) return;
    if (!current()) {
      _updateState(() {
        _actionMessage = '共享目录或选择已变化，未执行移出操作。';
        _actionIsError = true;
      });
      return;
    }

    _updateState(() => _batchBusy = true);
    final removedIds = <int>{};
    String? error;
    for (final id in selected) {
      if (!current()) break;
      try {
        await _albumRepository.removeItem(
          isPrivate ? PhotoAlbumScope.personal : PhotoAlbumScope.shared,
          albumId: albumId,
          assetId: id,
        );
        removedIds.add(id);
      } catch (failure) {
        error = mediaErrorLabel(failure);
        break;
      }
    }
    if (!mounted) return;
    _updateState(() {
      _assets.removeWhere((item) => removedIds.contains(item.id));
      _selectedAssets.clear();
      _selecting = false;
      _batchBusy = false;
      _actionMessage = error == null
          ? '已将 ${removedIds.length} 项移出相册，原始媒体仍保留。'
          : '已移出 ${removedIds.length} 项，其余未处理：$error';
      _actionIsError = error != null;
    });
    if (isPrivate) {
      await _refreshPrivateAlbums();
    } else {
      await _refreshAlbums();
    }
  }

  Future<void> _batchAddToPrivateAlbum() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final listGeneration = _listGeneration;
    final selectedAssets = <PhotoAsset>[
      for (final item in _assets)
        if (_selectedAssets.contains(item.id)) item,
    ];
    final selectedIds = [for (final item in selectedAssets) item.id];
    bool stillCurrent() =>
        mounted &&
        _listGeneration == listGeneration &&
        (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity;
    final choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Text('整理到相册', style: Theme.of(sheetContext).textTheme.titleLarge),
            const SizedBox(height: 10),
            ListTile(
              key: const ValueKey('batchToFolderAlbumTile'),
              leading: const Icon(Icons.folder_special_outlined),
              title: const Text('文件夹相册（复制或移动）'),
              subtitle: const Text('整理到照片目录中的真实文件夹，支持新建相册与家庭共享'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.pop(sheetContext, -1),
            ),
            if (_privateAlbums.isNotEmpty) ...[
              const Divider(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  '旧版私人相册',
                  style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final album in _privateAlbums)
                ListTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: Text(album.name),
                  subtitle: Text('${album.count} 项 · 仅自己可见'),
                  onTap: () => Navigator.pop(sheetContext, album.id),
                ),
            ],
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (!stillCurrent() || !setEquals(_selectedAssets, selectedIds.toSet())) {
      _updateState(() {
        _actionMessage = '共享目录或选择已变化，请重新选择需要整理的媒体。';
        _actionIsError = true;
      });
      return;
    }
    if (choice == -1) {
      final canMoveAll = selectedAssets.every(
        (asset) => widget.isAdmin || asset.canWrite,
      );
      final selection = await Navigator.of(context).push<FolderAlbumSelection>(
        MaterialPageRoute(
          builder: (_) => FolderAlbumsPage(
            api: widget.api,
            sources: selectedAssets,
            canMove: canMoveAll,
          ),
        ),
      );
      if (!mounted || selection == null || !stillCurrent()) return;
      _updateState(() {
        _selectedAssets.clear();
        _selecting = false;
        _actionMessage = selection.moved
            ? '已将 ${selection.completedCount} 项移动到文件夹相册“${selection.name}”。'
            : '已将 ${selection.completedCount} 项复制到文件夹相册“${selection.name}”。';
        _actionIsError = false;
      });
      await Future.wait([_loadAssets(reset: true), _refreshFolderAlbums()]);
      return;
    }
    final albumId = choice;
    _updateState(() => _batchBusy = true);
    final result = await _albumRepository.addManyToPrivateAlbum(
      albumId: albumId,
      assetIds: selectedIds,
      stillCurrent: stillCurrent,
    );
    if (!mounted) return;
    if (!stillCurrent()) {
      _updateState(() {
        _batchBusy = false;
        _actionMessage = '共享目录已变化，已停止后续相册操作；请回原目录核对已完成的项目。';
        _actionIsError = true;
      });
      return;
    }
    final error = result.error == null ? null : mediaErrorLabel(result.error!);
    _updateState(() {
      _selectedAssets.clear();
      _selecting = false;
      _batchBusy = false;
      _actionMessage = result.cancelled
          ? '操作已取消，已完成 ${result.completed} 项。'
          : error == null
          ? '已将 ${result.completed} 项加入私人相册。'
          : '已完成 ${result.completed} 项，其他项目未处理：$error';
      _actionIsError = error != null || result.cancelled;
    });
    await _refreshPrivateAlbums();
  }
}
