import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'folder_albums_page.dart';
import 'media_batch_operations.dart';
import 'media_models.dart';
import 'photos_album_dialogs.dart';
import 'photos_batch_service.dart';
import 'photos_controller.dart';

/// Handles `BuildContext`-bound confirmation dialogs, pickers, SnackBars, and
/// haptics for gallery multi-select and batch operations, delegating all state
/// transitions and API work to [PhotosController].
class PhotosBatchActions {
  const PhotosBatchActions({
    required this.api,
    required this.controller,
    required this.isAdmin,
  });

  final LightIsleApi api;
  final PhotosController controller;
  final bool isAdmin;

  void toggleSelection(BuildContext context, PhotoAsset asset) {
    HapticFeedback.selectionClick();
    final warning = controller.batch.toggleSelection(
      asset,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
    );
    if (warning != null && context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(warning)));
    }
  }

  void toggleSectionSelection(
    BuildContext context,
    List<PhotoAsset> sectionItems,
  ) {
    if (controller.selection.batchBusy || sectionItems.isEmpty) return;
    HapticFeedback.selectionClick();
    final capped = controller.batch.toggleSectionSelection(sectionItems);
    if (capped && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('每次最多选择 ${PhotosBatchService.maxSelectionCount} 项媒体。'),
        ),
      );
    }
  }

  Future<bool> trashAssets(
    BuildContext context,
    List<PhotoAsset> assets,
  ) async {
    if (!controller.batch.validateTrashTargets(assets)) return false;
    final guard = controller.batch.captureGuard();
    final confirmed = await confirmAction(
      context,
      '移入回收站',
      '将选中的 ${assets.length} 个照片或视频原文件移入回收站？之后可在文件管理中恢复。',
      action: '移入回收站',
    );
    if (!confirmed || !context.mounted || !guard.isFeedCurrent) return false;
    return controller.batch.trashOriginals(assets, guard);
  }

  Future<void> batchTrashAssets(BuildContext context) async {
    final chosen = controller.batch.selectedLoadedAssets();
    if (chosen.length != controller.selection.selectedAssets.length) {
      controller.setActionFeedback('媒体列表已经变化，请重新选择。', isError: true);
      return;
    }
    await trashAssets(context, chosen);
  }

  Future<void> batchExport(BuildContext context) async {
    final selection = controller.selection;
    if (selection.batchBusy || selection.selectedAssets.isEmpty) return;
    final guard = controller.batch.captureGuard();
    final items = controller.batch.selectedLoadedAssets();
    if (items.length != guard.selectedIds.length ||
        items.any((item) => item.path.isEmpty)) {
      controller.setActionFeedback('媒体列表已变化，请重新选择。', isError: true);
      return;
    }
    final originals = <MediaBatchItem>[
      for (final item in items)
        (path: item.path, name: item.name, size: item.size),
    ];
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (mobile && originals.length > PhotosBatchService.maxMobileExportCount) {
      controller.setActionFeedback(
        '手机一次最多导出 ${PhotosBatchService.maxMobileExportCount} 项，请减少选择。',
        isError: true,
      );
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
      if (!confirmed || !context.mounted) return;
    }
    final directory = mobile
        ? null
        : await FilePicker.getDirectoryPath(dialogTitle: '选择批量媒体保存位置');
    if (!context.mounted ||
        (!mobile && (directory == null || directory.isEmpty))) {
      return;
    }
    if (!guard.isSelectionCurrent) {
      controller.setActionFeedback('共享目录或选择已变化，请重新选择需要导出的媒体。', isError: true);
      return;
    }
    if (mobile) {
      await controller.batch.exportMobile(items: originals, guard: guard);
    } else {
      await controller.batch.exportDesktop(
        items: originals,
        directory: directory!,
        guard: guard,
      );
    }
  }

  Future<void> batchShare(BuildContext context) async {
    final selection = controller.selection;
    if (selection.batchBusy || selection.selectedAssets.isEmpty) return;
    final guard = controller.batch.captureGuard();
    final items = controller.batch.selectedLoadedAssets();
    if (items.length != guard.selectedIds.length ||
        items.length > PhotosBatchService.maxShareCount ||
        items.any((item) => item.path.isEmpty)) {
      controller.setActionFeedback(
        '每次最多分享 ${PhotosBatchService.maxShareCount} 项，请重新选择。',
        isError: true,
      );
      return;
    }
    final confirmed = await confirmAction(
      context,
      '分享所选媒体？',
      '将为 ${items.length} 个原文件分别创建有效期 24 小时的公开下载链接。'
          '获得链接的人无需登录；链接仅在本次创建后提供，请妥善发送给收件人。',
      action: '创建并复制链接',
    );
    if (!confirmed || !context.mounted) return;
    if (!guard.isSelectionCurrent) {
      controller.setActionFeedback('共享目录或选择已变化，请重新选择需要分享的媒体。', isError: true);
      return;
    }
    await controller.batch.shareSelected(
      items: [for (final item in items) (path: item.path, label: item.name)],
      guard: guard,
      copyToClipboard: (text) => Clipboard.setData(ClipboardData(text: text)),
    );
  }

  Future<bool> removeSingleAssetFromCurrentAlbum(
    BuildContext context,
    PhotoAsset asset,
  ) async {
    final target = _resolveActiveRemovableAlbum();
    if (target == null) return false;
    final confirmed = await confirmAction(
      context,
      '从相册移出（保留原片）',
      '将“${asset.name}”从“${target.albumName}”中移出？这只会解除相册关联，不会删除 NAS 中的原始文件。',
      action: '移出相册',
    );
    if (!confirmed || !context.mounted || controller.isDisposed) return false;
    return controller.albums.removeSingleAssetFromCurrentAlbum(
      asset: asset,
      isPrivate: target.isPrivate,
      albumId: target.albumId,
      albumName: target.albumName,
    );
  }

  Future<void> batchRemoveFromCurrentAlbum(BuildContext context) async {
    final selection = controller.selection;
    if (selection.batchBusy || selection.selectedAssets.isEmpty) return;
    final target = _resolveActiveRemovableAlbum();
    if (target == null) return;
    final guard = controller.batch.captureGuard();
    final confirmed = await confirmAction(
      context,
      '从相册移出',
      '将选中的 ${guard.selectedIds.length} 项从“${target.albumName}”中移出？这只会解除相册关联，不会删除 NAS 中的原始照片或视频。',
      action: '移出相册',
    );
    if (!confirmed || !context.mounted) return;
    if (!guard.isSelectionCurrent) {
      controller.setActionFeedback('共享目录或选择已变化，未执行移出操作。', isError: true);
      return;
    }
    await controller.batch.removeSelectedFromCurrentAlbum(
      isPrivate: target.isPrivate,
      albumId: target.albumId,
      guard: guard,
    );
  }

  Future<void> batchAddToAlbum(BuildContext context) async {
    final selection = controller.selection;
    if (selection.batchBusy || selection.selectedAssets.isEmpty) return;
    final selectedAssets = controller.batch.selectedLoadedAssets();
    final selectedIds = [for (final item in selectedAssets) item.id];
    final guard = controller.batch.captureGuard(
      selectedIds: selectedIds.toSet(),
    );

    final choice = await showPhotosBatchAlbumSheet(
      context,
      privateAlbums: controller.catalog.privateAlbums,
    );
    if (choice == null || !context.mounted) return;
    if (!guard.isSelectionCurrent) {
      controller.setActionFeedback('共享目录或选择已变化，请重新选择需要整理的媒体。', isError: true);
      return;
    }
    if (choice == kPhotosBatchFolderAlbumChoice) {
      final canMoveAll = selectedAssets.every(
        (asset) => isAdmin || asset.canWrite,
      );
      final folderChoice = await Navigator.of(context)
          .push<FolderAlbumSelection>(
            buildIslePageRoute(
              builder: (_) => FolderAlbumsPage(
                api: api,
                sources: selectedAssets,
                canMove: canMoveAll,
              ),
            ),
          );
      if (!context.mounted || folderChoice == null || !guard.isFeedCurrent) {
        return;
      }
      await controller.completeBatchFolderAlbum(
        moved: folderChoice.moved,
        completedCount: folderChoice.completedCount,
        albumName: folderChoice.name,
      );
      return;
    }
    await controller.batch.addSelectedToPrivateAlbum(
      albumId: choice,
      assetIds: selectedIds,
      guard: guard,
    );
  }

  ({bool isPrivate, int albumId, String albumName})?
  _resolveActiveRemovableAlbum() {
    final privateAlbumId = controller.scope.activePrivateAlbum;
    final sharedAlbumId = isAdmin ? controller.scope.activeAlbum : 0;
    if (privateAlbumId <= 0 && sharedAlbumId <= 0) return null;
    final isPrivate = privateAlbumId > 0;
    final albumId = isPrivate ? privateAlbumId : sharedAlbumId;
    final albumName =
        (isPrivate
            ? controller.currentPrivateAlbum?.name
            : controller.currentAlbum?.name) ??
        '当前相册';
    return (isPrivate: isPrivate, albumId: albumId, albumName: albumName);
  }
}
