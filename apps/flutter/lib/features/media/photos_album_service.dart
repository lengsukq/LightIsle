import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'photo_album_repository.dart';
import 'photos_page_state_models.dart';

/// Coordinates shared, private, and folder-backed album catalog refreshes as
/// well as single-asset favorite and album membership mutations.
class PhotosAlbumService {
  PhotosAlbumService({
    required this._api,
    required this._repository,
    required this._catalog,
    required this._scope,
    required this._feed,
    required this._isAdmin,
    required this._isAlive,
    required this._notify,
    required this._reloadAssets,
  });

  final LightIsleApi _api;
  final PhotoAlbumRepository _repository;
  final PhotosAlbumCatalogState _catalog;
  final PhotosFilterScopeState _scope;
  final PhotosLibraryFeedState _feed;
  final bool Function() _isAdmin;
  final bool Function() _isAlive;
  final VoidCallback _notify;
  final Future<void> Function({required bool reset}) _reloadAssets;

  Future<void> refreshSharedAlbums() async {
    final generation = ++_catalog.sharedGeneration;
    try {
      final albums = await _repository.list(PhotoAlbumScope.shared);
      if (!_isAlive() || generation != _catalog.sharedGeneration) return;
      _catalog.sharedAlbums = albums;
      _notify();
    } catch (_) {
      // Keep previously loaded album navigation visible if a refresh fails.
    }
  }

  Future<void> refreshFolderAlbums() async {
    try {
      final result = await _api.get('/api/v2/photos/folder-albums');
      if (!_isAlive()) return;
      _catalog.folderAlbums = objectList(result['albums']);
      _notify();
    } catch (_) {
      // Folder albums are optional when no personal photo directory is assigned.
    }
  }

  Future<void> refreshPrivateAlbums() async {
    final generation = ++_catalog.privateGeneration;
    if (_isAlive()) {
      _catalog.privateRefreshing = true;
      _notify();
    }
    try {
      final albums = await _repository.list(PhotoAlbumScope.personal);
      if (!_isAlive() || generation != _catalog.privateGeneration) return;
      _catalog.privateAlbums = albums;
      _catalog.privateFailure = null;
      _notify();
    } catch (error) {
      if (_isAlive() && generation == _catalog.privateGeneration) {
        _catalog.privateFailure = error;
        _notify();
      }
    } finally {
      if (_isAlive() && generation == _catalog.privateGeneration) {
        _catalog.privateRefreshing = false;
        _notify();
      }
    }
  }

  Future<PhotoAsset> toggleSharedFavorite(PhotoAsset asset) async {
    if (!_isAdmin() && !asset.canWrite) {
      throw StateError('当前账号对此媒体只有查看权限。');
    }
    final favorite = !asset.favorite;
    await _api.send(
      'POST',
      '/api/v2/photos/${asset.id}/favorite',
      body: <String, Object>{'favorite': favorite},
    );
    final updated = asset.withFavorite(favorite);
    if (!_isAlive()) return updated;
    final index = _feed.assets.indexWhere((item) => item.id == asset.id);
    if (index >= 0) {
      if (_scope.favoritesOnly && !favorite) {
        _feed.assets.removeAt(index);
      } else {
        _feed.assets[index] = updated;
      }
    }
    _feed.setActionFeedback(favorite ? '已加入共享收藏。' : '已从共享收藏移除。');
    _notify();
    return updated;
  }

  Future<PhotoAsset> togglePersonalFavorite(PhotoAsset asset) async {
    final favorite = !asset.personalFavorite;
    await _api.send(
      'POST',
      '/api/v2/photos/${asset.id}/personal-favorite',
      body: <String, Object>{'favorite': favorite},
    );
    final updated = asset.withPersonalFavorite(favorite);
    if (!_isAlive()) return updated;
    final index = _feed.assets.indexWhere((item) => item.id == asset.id);
    if (index >= 0) {
      if (_scope.personalFavoritesOnly && !favorite) {
        _feed.assets.removeAt(index);
      } else {
        _feed.assets[index] = updated;
      }
    }
    _feed.setActionFeedback(favorite ? '已加入我的收藏。' : '已从我的收藏移除。');
    _notify();
    return updated;
  }

  Future<void> saveAlbum({
    required PhotoAlbumScope albumScope,
    required String name,
    MediaAlbum? existing,
  }) async {
    _catalog.busy = true;
    _notify();
    try {
      await _repository.save(albumScope, name: name, albumId: existing?.id);
      if (!_isAlive()) return;
      final isPrivate = albumScope == PhotoAlbumScope.personal;
      _feed.setActionFeedback(
        isPrivate
            ? (existing == null ? '私人相册已创建，仅当前账号可见。' : '私人相册名称已更新。')
            : (existing == null ? '相册已创建。' : '相册名称已更新。'),
      );
      _notify();
      if (isPrivate) {
        await refreshPrivateAlbums();
      } else {
        await refreshSharedAlbums();
      }
    } catch (error) {
      if (_isAlive()) {
        _feed.setActionFeedback(mediaErrorLabel(error), isError: true);
        _notify();
      }
    } finally {
      if (_isAlive()) {
        _catalog.busy = false;
        _notify();
      }
    }
  }

  Future<void> deleteAlbum({
    required PhotoAlbumScope albumScope,
    required MediaAlbum album,
  }) async {
    _catalog.busy = true;
    _notify();
    try {
      await _repository.delete(albumScope, album.id);
      if (!_isAlive()) return;
      if (albumScope == PhotoAlbumScope.personal) {
        final wasCurrent = _scope.activePrivateAlbum == album.id;
        if (wasCurrent) _scope.activePrivateAlbum = 0;
        _feed.setActionFeedback('私人相册已删除，原始媒体和共享相册仍保留。');
        _notify();
        await Future.wait([
          refreshPrivateAlbums(),
          if (wasCurrent) _reloadAssets(reset: true),
        ]);
      } else {
        if (_scope.activeAlbum == album.id) {
          _scope.activeAlbum = 0;
          _scope.favoritesOnly = false;
        }
        _feed.setActionFeedback('相册已删除，原始媒体仍保留。');
        _notify();
        await Future.wait([refreshSharedAlbums(), _reloadAssets(reset: true)]);
      }
    } catch (error) {
      if (_isAlive()) {
        _feed.setActionFeedback(mediaErrorLabel(error), isError: true);
        _notify();
      }
    } finally {
      if (_isAlive()) {
        _catalog.busy = false;
        _notify();
      }
    }
  }

  Future<void> addToAlbum({
    required PhotoAlbumScope albumScope,
    required int albumId,
    required int assetId,
  }) async {
    final isPrivate = albumScope == PhotoAlbumScope.personal;
    if ((!isPrivate && !_isAdmin()) || albumId < 1) return;
    _catalog.busy = true;
    _notify();
    try {
      await _repository.addItem(albumScope, albumId: albumId, assetId: assetId);
      if (!_isAlive()) return;
      _feed.setActionFeedback(isPrivate ? '已加入我的私人相册。' : '已加入相册。');
      _notify();
      if (isPrivate) {
        await refreshPrivateAlbums();
      } else {
        await refreshSharedAlbums();
      }
    } catch (error) {
      if (_isAlive()) {
        _feed.setActionFeedback(mediaErrorLabel(error), isError: true);
        _notify();
      }
      rethrow;
    } finally {
      if (_isAlive()) {
        _catalog.busy = false;
        _notify();
      }
    }
  }

  Future<void> removeFromAlbum({
    required PhotoAlbumScope albumScope,
    required int albumId,
    required int assetId,
  }) async {
    final isPrivate = albumScope == PhotoAlbumScope.personal;
    if ((!isPrivate && !_isAdmin()) || albumId < 1) return;
    _catalog.busy = true;
    _notify();
    try {
      await _repository.removeItem(
        albumScope,
        albumId: albumId,
        assetId: assetId,
      );
      if (!_isAlive()) return;
      if (isPrivate) {
        final wasCurrent = _scope.activePrivateAlbum == albumId;
        if (wasCurrent) {
          _feed.assets.removeWhere((item) => item.id == assetId);
        }
        _feed.setActionFeedback('已从私人相册移出，原始媒体仍保留。');
        _notify();
        await Future.wait([
          refreshPrivateAlbums(),
          if (wasCurrent) _reloadAssets(reset: true),
        ]);
      } else {
        _feed.setActionFeedback('已从相册移出，原始媒体仍保留。');
        _notify();
        await Future.wait([refreshSharedAlbums(), _reloadAssets(reset: true)]);
      }
    } catch (error) {
      if (_isAlive()) {
        _feed.setActionFeedback(mediaErrorLabel(error), isError: true);
        _notify();
      }
      rethrow;
    } finally {
      if (_isAlive()) {
        _catalog.busy = false;
        _notify();
      }
    }
  }

  Future<bool> removeSingleAssetFromCurrentAlbum({
    required PhotoAsset asset,
    required bool isPrivate,
    required int albumId,
    required String albumName,
  }) async {
    await _repository.removeItem(
      isPrivate ? PhotoAlbumScope.personal : PhotoAlbumScope.shared,
      albumId: albumId,
      assetId: asset.id,
    );
    if (!_isAlive()) return true;
    _feed.assets.removeWhere((item) => item.id == asset.id);
    _feed.setActionFeedback('已将“${asset.name}”从“$albumName”移出，原片仍保留。');
    _notify();
    if (isPrivate) {
      await refreshPrivateAlbums();
    } else {
      await refreshSharedAlbums();
    }
    return true;
  }
}
