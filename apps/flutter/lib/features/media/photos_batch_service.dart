import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/lightisle_api.dart';
import 'media_batch_operations.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'photo_album_repository.dart';
import 'photos_page_state_models.dart';

/// Captures the active root identity, feed generation, and optional selected
/// asset IDs when a batch operation begins so mutations halt safely on drift.
class PhotosBatchGuard {
  PhotosBatchGuard({
    required this.rootIdentity,
    required this.feedGeneration,
    required this.selectedIds,
    required this._isAlive,
    required this._currentRootIdentity,
    required this._currentFeedGeneration,
    required this._currentSelectedIds,
  });

  final String rootIdentity;
  final int feedGeneration;
  final Set<int> selectedIds;

  final bool Function() _isAlive;
  final String Function() _currentRootIdentity;
  final int Function() _currentFeedGeneration;
  final Set<int> Function() _currentSelectedIds;

  bool get isFeedCurrent =>
      _isAlive() &&
      _currentFeedGeneration() == feedGeneration &&
      _currentRootIdentity() == rootIdentity;

  bool get isSelectionCurrent =>
      isFeedCurrent && setEquals(_currentSelectedIds(), selectedIds);
}

/// Manages gallery multi-select state and root-guarded batch mutations
/// without holding a [BuildContext].
class PhotosBatchService {
  PhotosBatchService({
    required this._api,
    required this._albumRepository,
    required this._batchOperations,
    required this._selection,
    required this._feed,
    required this._isAdmin,
    required this._isAlive,
    required this._notify,
    required this._reloadAssets,
    required this._togglePersonalFavorite,
    required this._refreshSharedAlbums,
    required this._refreshPrivateAlbums,
  });

  static const int maxSelectionCount = 50;
  static const int maxMobileExportCount = 20;
  static const int maxShareCount = 10;

  final LightIsleApi _api;
  final PhotoAlbumRepository _albumRepository;
  final MediaBatchOperations _batchOperations;
  final PhotosSelectionState _selection;
  final PhotosLibraryFeedState _feed;
  final bool Function() _isAdmin;
  final bool Function() _isAlive;
  final VoidCallback _notify;
  final Future<void> Function({required bool reset}) _reloadAssets;
  final Future<PhotoAsset> Function(PhotoAsset asset) _togglePersonalFavorite;
  final Future<void> Function() _refreshSharedAlbums;
  final Future<void> Function() _refreshPrivateAlbums;

  String get _currentRootIdentity => _api.selectedRoot?.identity ?? 'default';

  PhotosBatchGuard captureGuard({Set<int>? selectedIds}) => PhotosBatchGuard(
    rootIdentity: _currentRootIdentity,
    feedGeneration: _feed.generation,
    selectedIds: Set<int>.unmodifiable(
      selectedIds ?? _selection.selectedAssets,
    ),
    isAlive: _isAlive,
    currentRootIdentity: () => _currentRootIdentity,
    currentFeedGeneration: () => _feed.generation,
    currentSelectedIds: () => _selection.selectedAssets,
  );

  void selectVisiblePhotos() {
    if (_selection.batchBusy) return;
    final visible = _feed.assets
        .take(maxSelectionCount)
        .map((asset) => asset.id)
        .toSet();
    _selection.selecting = true;
    if (visible.every(_selection.selectedAssets.contains)) {
      _selection.selectedAssets.removeAll(visible);
    } else {
      _selection.selectedAssets
        ..clear()
        ..addAll(visible);
    }
    _notify();
  }

  /// Toggles selection for all loaded assets in [sectionItems].
  /// Returns `true` when the 50-item cap was reached.
  bool toggleSectionSelection(List<PhotoAsset> sectionItems) {
    if (_selection.batchBusy || sectionItems.isEmpty) return false;
    final ids = sectionItems
        .take(maxSelectionCount)
        .map((asset) => asset.id)
        .toList();
    final allSelected = ids.every(_selection.selectedAssets.contains);
    var capped = false;
    if (allSelected) {
      _selection.selectedAssets.removeAll(ids);
      if (_selection.selectedAssets.isEmpty) _selection.selecting = false;
    } else {
      _selection.selecting = true;
      for (final id in ids) {
        if (_selection.selectedAssets.length >= maxSelectionCount) {
          capped = true;
          break;
        }
        _selection.selectedAssets.add(id);
      }
      if (sectionItems.length > maxSelectionCount) capped = true;
    }
    _notify();
    return capped;
  }

  /// Toggles [asset] in the current selection (supporting Shift range select).
  /// Returns a cap warning string when the user hits the 50-item ceiling.
  String? toggleSelection(PhotoAsset asset, {required bool shiftPressed}) {
    String? capWarning;
    _selection.selecting = true;
    final anchorId = _selection.selectionAnchorId;
    if (shiftPressed && anchorId != null && anchorId != asset.id) {
      final anchorIndex = _feed.assets.indexWhere((a) => a.id == anchorId);
      final targetIndex = _feed.assets.indexWhere((a) => a.id == asset.id);
      if (anchorIndex >= 0 && targetIndex >= 0) {
        final start = anchorIndex < targetIndex ? anchorIndex : targetIndex;
        final end = anchorIndex > targetIndex ? anchorIndex : targetIndex;
        var capped = false;
        for (var i = start; i <= end; i++) {
          final id = _feed.assets[i].id;
          if (_selection.selectedAssets.contains(id)) continue;
          if (_selection.selectedAssets.length >= maxSelectionCount) {
            capped = true;
            break;
          }
          _selection.selectedAssets.add(id);
        }
        _selection.selectionAnchorId = asset.id;
        if (capped) {
          capWarning = '每次最多选择 $maxSelectionCount 项媒体，已选取前 $maxSelectionCount 项。';
        }
        _notify();
        return capWarning;
      }
    }
    if (_selection.selectedAssets.contains(asset.id)) {
      _selection.selectedAssets.remove(asset.id);
    } else if (_selection.selectedAssets.length < maxSelectionCount) {
      _selection.selectedAssets.add(asset.id);
      _selection.selectionAnchorId = asset.id;
    } else {
      capWarning = '每次最多选择 $maxSelectionCount 项媒体。';
    }
    _notify();
    return capWarning;
  }

  List<PhotoAsset> selectedLoadedAssets() => <PhotoAsset>[
    for (final item in _feed.assets)
      if (_selection.selectedAssets.contains(item.id)) item,
  ];

  bool validateTrashTargets(List<PhotoAsset> assets) {
    if (_selection.batchBusy ||
        assets.isEmpty ||
        assets.length > maxSelectionCount ||
        assets.any((asset) => !_isAdmin() && !asset.canWrite)) {
      if (_isAlive()) {
        _feed.setActionFeedback(
          '仅可删除当前目录中有写入权限的文件，每次最多 $maxSelectionCount 项。',
          isError: true,
        );
        _notify();
      }
      return false;
    }
    return true;
  }

  Future<bool> trashOriginals(
    List<PhotoAsset> assets,
    PhotosBatchGuard guard,
  ) async {
    final paths = List<String>.unmodifiable(assets.map((a) => a.path));
    _selection.batchBusy = true;
    _notify();
    try {
      final result = await _batchOperations.trashOriginals(
        paths: paths,
        stillCurrent: () => guard.isFeedCurrent,
      );
      if (!_isAlive()) return false;
      if (!guard.isFeedCurrent || result.cancelled) {
        _feed.setActionFeedback(
          '存储根已变化，已停止后续操作；请返回原硬盘核对回收站。',
          isError: true,
        );
        _notify();
        return false;
      }
      _selection.clear();
      _feed.setActionFeedback(
        result.needsRootCheck
            ? '已确认 ${result.completed}/${assets.length} 项移入回收站。硬盘连接发生变化，部分操作结果不确定；请重新连接原硬盘，检查原目录和回收站后再重试。'
            : '已移入回收站 ${result.completed}/${assets.length} 项。',
        isError: result.error != null,
      );
      _notify();
      await _reloadAssets(reset: true);
      return result.error == null && result.completed == assets.length;
    } catch (error) {
      if (_isAlive() && guard.isFeedCurrent) {
        _feed.setActionFeedback(
          '未能确认移入回收站的结果：${mediaErrorLabel(error)}',
          isError: true,
        );
        _notify();
      }
      return false;
    } finally {
      if (_isAlive()) {
        _selection.batchBusy = false;
        _notify();
      }
    }
  }

  Future<void> favoriteSelected() async {
    if (_selection.batchBusy || _selection.selectedAssets.isEmpty) return;
    final selectedItems = selectedLoadedAssets();
    if (selectedItems.isEmpty) return;
    final unmark = selectedItems.every((item) => item.personalFavorite);
    final targets = unmark
        ? selectedItems
        : selectedItems.where((item) => !item.personalFavorite).toList();
    _selection.batchBusy = true;
    _notify();
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
    if (!_isAlive()) return;
    _selection.clear();
    _selection.batchBusy = false;
    _feed.setActionFeedback(
      error == null
          ? (unmark ? '已将 $done 项移出我的收藏。' : '已将 $done 项加入我的收藏。')
          : '已完成 $done 项，其他项目未处理：$error',
      isError: error != null,
    );
    _notify();
  }

  Future<void> removeSelectedFromCurrentAlbum({
    required bool isPrivate,
    required int albumId,
    required PhotosBatchGuard guard,
  }) async {
    _selection.batchBusy = true;
    _notify();
    final removedIds = <int>{};
    String? error;
    for (final id in guard.selectedIds) {
      if (!guard.isSelectionCurrent) break;
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
    if (!_isAlive()) return;
    _feed.assets.removeWhere((item) => removedIds.contains(item.id));
    _selection.clear();
    _selection.batchBusy = false;
    _feed.setActionFeedback(
      error == null
          ? '已将 ${removedIds.length} 项移出相册，原始媒体仍保留。'
          : '已移出 ${removedIds.length} 项，其余未处理：$error',
      isError: error != null,
    );
    _notify();
    if (isPrivate) {
      await _refreshPrivateAlbums();
    } else {
      await _refreshSharedAlbums();
    }
  }

  Future<void> addSelectedToPrivateAlbum({
    required int albumId,
    required List<int> assetIds,
    required PhotosBatchGuard guard,
  }) async {
    _selection.batchBusy = true;
    _notify();
    final result = await _albumRepository.addManyToPrivateAlbum(
      albumId: albumId,
      assetIds: assetIds,
      stillCurrent: () => guard.isFeedCurrent,
    );
    if (!_isAlive()) return;
    if (!guard.isFeedCurrent) {
      _selection.batchBusy = false;
      _feed.setActionFeedback(
        '共享目录已变化，已停止后续相册操作；请回原目录核对已完成的项目。',
        isError: true,
      );
      _notify();
      return;
    }
    final error = result.error == null ? null : mediaErrorLabel(result.error!);
    _selection.clear();
    _selection.batchBusy = false;
    _feed.setActionFeedback(
      result.cancelled
          ? '操作已取消，已完成 ${result.completed} 项。'
          : error == null
          ? '已将 ${result.completed} 项加入私人相册。'
          : '已完成 ${result.completed} 项，其他项目未处理：$error',
      isError: error != null || result.cancelled,
    );
    _notify();
    await _refreshPrivateAlbums();
  }

  Future<void> exportMobile({
    required List<MediaBatchItem> items,
    required PhotosBatchGuard guard,
  }) async {
    _selection.batchBusy = true;
    _notify();
    try {
      final message = await _batchOperations.exportOnMobile(
        items: items,
        stillCurrent: () => guard.isSelectionCurrent,
        onProgress: (finished, total, name) {
          if (guard.isSelectionCurrent) {
            _feed.setActionFeedback('正在准备批量导出 $finished/$total 项：$name');
            _notify();
          }
        },
      );
      if (guard.isSelectionCurrent) {
        _feed.setActionFeedback(message);
        _notify();
      }
    } catch (error) {
      if (_isAlive()) {
        _feed.setActionFeedback(
          '批量导出失败：${mediaErrorLabel(error)}',
          isError: true,
        );
        _notify();
      }
    } finally {
      if (_isAlive()) {
        _selection.batchBusy = false;
        _notify();
      }
    }
  }

  Future<void> exportDesktop({
    required List<MediaBatchItem> items,
    required String directory,
    required PhotosBatchGuard guard,
  }) async {
    _selection.batchBusy = true;
    _notify();
    try {
      final result = await _batchOperations.exportToDirectory(
        items: items,
        directory: directory,
        stillCurrent: () => guard.isSelectionCurrent,
      );
      if (!_isAlive()) return;
      final stillValid = guard.isSelectionCurrent;
      _feed.setActionFeedback(
        result.cancelled || !stillValid
            ? '共享目录已变化，已完成 ${result.completed} 项，剩余操作已停止。'
            : result.error == null
            ? '已保存 ${result.completed} 项原文件到所选文件夹。'
            : '已保存 ${result.completed} 项，剩余文件未处理：${mediaErrorLabel(result.error!)}',
        isError: result.cancelled || result.error != null || !stillValid,
      );
      _notify();
    } catch (error) {
      if (_isAlive()) {
        _feed.setActionFeedback(
          '批量导出失败：${mediaErrorLabel(error)}',
          isError: true,
        );
        _notify();
      }
    } finally {
      if (_isAlive()) {
        _selection.batchBusy = false;
        _notify();
      }
    }
  }

  Future<void> shareSelected({
    required List<MediaShareItem> items,
    required PhotosBatchGuard guard,
    required Future<void> Function(String text) copyToClipboard,
  }) async {
    _selection.batchBusy = true;
    _notify();
    try {
      final result = await _batchOperations.createShares(
        items: items,
        stillCurrent: () => guard.isSelectionCurrent,
      );
      if (!_isAlive()) return;
      if (result.cancelled || !guard.isSelectionCurrent) {
        _feed.setActionFeedback(
          '共享目录已变化，后续分享已停止。若已创建链接，请在原硬盘的分享列表中撤销。',
          isError: true,
        );
        _notify();
        return;
      }
      String? failure = result.error == null
          ? null
          : mediaErrorLabel(result.error!);
      if (result.links.isNotEmpty) {
        try {
          await copyToClipboard(result.links.join('\n'));
        } catch (_) {
          failure ??= '无法复制链接到剪贴板，请进入文件分享列表撤销后重试。';
        }
      }
      if (!_isAlive() || !guard.isSelectionCurrent) return;
      _feed.setActionFeedback(
        failure == null
            ? '已创建并复制 ${result.completed} 条限时下载链接。'
            : '已创建 ${result.completed} 条链接。$failure',
        isError: failure != null,
      );
      _notify();
    } catch (error) {
      if (_isAlive()) {
        _feed.setActionFeedback(
          '批量分享失败：${mediaErrorLabel(error)}',
          isError: true,
        );
        _notify();
      }
    } finally {
      if (_isAlive()) {
        _selection.batchBusy = false;
        _notify();
      }
    }
  }
}
