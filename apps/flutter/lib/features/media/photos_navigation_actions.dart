import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../files/files_page.dart';
import '../files/mobile_photo_backup_page.dart';
import '../files/upload_task_center.dart';
import '../settings/storage_page.dart';
import 'folder_albums_page.dart';
import 'media_models.dart';
import 'offline_photos_page.dart';
import 'photo_ai_models.dart';
import 'photo_album_repository.dart';
import 'photo_detail_dialog.dart';
import 'photo_exif_filter_sheet.dart';
import 'photo_gallery_viewer.dart';
import 'photo_map_page.dart';
import 'photo_people_section.dart';
import 'photo_similar_cleanup_sheet.dart';
import 'photo_timeline_scrubber.dart';
import 'photos_album_dialogs.dart';
import 'photos_album_overview_page.dart';
import 'photos_batch_actions.dart';
import 'photos_controller.dart';

/// Coordinates `BuildContext`-bound navigation, viewers, sheets, and overflow
/// menu dispatch for [PhotosPage].
class PhotosNavigationActions {
  const PhotosNavigationActions({
    required this.api,
    required this.controller,
    required this.batchActions,
    required this.isAdmin,
    required this.accountName,
    required this.offlineAccountId,
    required this.backupDirectory,
    required this.canBackup,
    required this.uploadDirectory,
    this.taskCenter,
  });

  static const double _wideDrawerBreakpoint = 800.0;
  static const double _detailDrawerWidth = 392.0;
  static const Color _drawerBarrierColor = Color(0x66141210);

  final LightIsleApi api;
  final PhotosController controller;
  final PhotosBatchActions batchActions;
  final bool isAdmin;
  final String accountName;
  final String offlineAccountId;
  final String backupDirectory;
  final bool canBackup;
  final String uploadDirectory;
  final UploadTaskCenter? taskCenter;

  Future<void> openAsset(BuildContext context, PhotoAsset asset) async {
    if (controller.selection.selecting) {
      batchActions.toggleSelection(context, asset);
      return;
    }
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<void>(
      PhotoGalleryViewer.route(
        (_) => PhotoGalleryViewer(
          api: api,
          memoryCache: controller.photoCache,
          offlineAccountId: offlineAccountId,
          assets: List<PhotoAsset>.of(controller.feed.assets),
          initialIndex: controller.feed.assets.indexWhere(
            (item) => item.id == asset.id,
          ),
          canEditSharedFavorite: (item) => isAdmin || item.canWrite,
          onSharedFavorite: controller.albums.toggleSharedFavorite,
          onPersonalFavorite: controller.albums.togglePersonalFavorite,
          onDelete: (target) => batchActions.trashAssets(context, [target]),
          onFolderAlbum: (target) => addAssetToFolder(context, target),
          currentAlbumName: controller.currentAlbumName,
          onRemoveFromCurrentAlbum: controller.canRemoveFromCurrentAlbum
              ? (target) => batchActions.removeSingleAssetFromCurrentAlbum(
                  context,
                  target,
                )
              : null,
          onDetails: (target) => showAssetDetails(context, target),
          onSyncAsset: controller.findAssetById,
          onLoadMore: () async {
            final feed = controller.feed;
            if (feed.nextCursor > 0 && !feed.loading && !feed.loadingMore) {
              await controller.loadAssets(reset: false);
            }
            return List<PhotoAsset>.of(controller.feed.assets);
          },
        ),
      ),
    );
  }

  Future<bool> addAssetToFolder(BuildContext context, PhotoAsset asset) async {
    final root = api.selectedRoot?.identity;
    final result = await Navigator.of(context).push<FolderAlbumSelection>(
      buildIslePageRoute(
        builder: (_) => FolderAlbumsPage(
          api: api,
          source: asset,
          canMove: isAdmin || asset.canWrite,
        ),
      ),
    );
    if (!context.mounted ||
        controller.isDisposed ||
        result == null ||
        root == null ||
        api.selectedRoot?.identity != root) {
      return false;
    }
    controller.setActionFeedback(
      result.moved ? '照片已移动到相册，图库正在更新。' : '照片已复制到相册，图库正在更新。',
    );
    await controller.loadAssets(reset: true);
    return result.moved;
  }

  Future<void> showAssetDetails(BuildContext context, PhotoAsset asset) async {
    void jumpToScene(String label) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (!context.mounted || controller.isDisposed) return;
      controller.jumpToSceneSearch(label);
    }

    void jumpToPerson(int personId, String personName) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (!context.mounted || controller.isDisposed) return;
      unawaited(
        controller.selectPerson(personId: personId, personName: personName),
      );
    }

    Widget details() => PhotoDetailDialog(
      api: api,
      asset: asset,
      albums: controller.catalog.sharedAlbums,
      privateAlbums: controller.catalog.privateAlbums,
      isAdmin: isAdmin,
      currentAlbumId: controller.scope.activeAlbum,
      currentPrivateAlbumId: controller.scope.activePrivateAlbum,
      canToggleFavorite: isAdmin || asset.canWrite,
      onToggleFavorite: controller.albums.toggleSharedFavorite,
      onTogglePersonalFavorite: controller.albums.togglePersonalFavorite,
      onAddToAlbum: (albumId, assetId) => controller.albums.addToAlbum(
        albumScope: PhotoAlbumScope.shared,
        albumId: albumId,
        assetId: assetId,
      ),
      onRemoveFromAlbum: (albumId, assetId) => controller.albums
          .removeFromAlbum(
            albumScope: PhotoAlbumScope.shared,
            albumId: albumId,
            assetId: assetId,
          ),
      onAddToPrivateAlbum: (albumId, assetId) => controller.albums.addToAlbum(
        albumScope: PhotoAlbumScope.personal,
        albumId: albumId,
        assetId: assetId,
      ),
      metadataOnly: true,
      onRemoveFromPrivateAlbum: (albumId, assetId) => controller.albums
          .removeFromAlbum(
            albumScope: PhotoAlbumScope.personal,
            albumId: albumId,
            assetId: assetId,
          ),
      onSelectSceneLabel: jumpToScene,
      onSelectPerson: jumpToPerson,
    );

    final wide = MediaQuery.sizeOf(context).width >= _wideDrawerBreakpoint;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (wide) {
      final reduced = IsleMotion.reducedMotion(context);
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭照片信息',
        barrierColor: _drawerBarrierColor,
        transitionDuration: reduced ? Duration.zero : IsleMotion.modalEnter,
        transitionBuilder: (dialogContext, animation, _, dialogChild) {
          if (IsleMotion.reducedMotion(dialogContext)) {
            return dialogChild;
          }
          return AnimatedBuilder(
            animation: animation,
            child: dialogChild,
            builder: (context, drawerChild) {
              final isReverse = animation.status == AnimationStatus.reverse;
              final t = animation.value.clamp(0.0, 1.0);
              final progress = isReverse
                  ? IsleMotion.exitCurve.transform(t)
                  : IsleMotion.gentleSpring.transform(t);
              final dx = (1.0 - progress) * (isReverse ? 28.0 : 48.0);
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(dx, 0),
                  child: drawerChild,
                ),
              );
            },
          );
        },
        pageBuilder: (dialogContext, _, _) => Align(
          alignment: Alignment.centerRight,
          child: SafeArea(
            child: Container(
              width: _detailDrawerWidth,
              height: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(dialogContext).colorScheme.surface,
                border: Border(
                  left: BorderSide(
                    color: IsleGlass.rimBorderColor(isDark),
                    width: 1.0,
                  ),
                ),
                boxShadow: IsleShadows.floating(isDark),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: details(),
              ),
            ),
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        shape: IsleShapes.sheet(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        builder: (_) =>
            FractionallySizedBox(heightFactor: 0.78, child: details()),
      );
    }
  }

  Future<void> browseAlbums(BuildContext context) async {
    final value = await Navigator.of(context).push<String>(
      buildIslePageRoute<String>(
        builder: (_) =>
            PhotosAlbumOverviewPage(api: api, controller: controller),
      ),
    );
    if (!context.mounted || controller.isDisposed || value == null) return;
    if (value == 'collection:personalFavorites') {
      unawaited(controller.selectView(personalFavorites: true));
    } else if (value == 'collection:sharedFavorites') {
      unawaited(controller.selectView(favorites: true));
    } else if (value == 'collection:onThisDay') {
      unawaited(controller.selectView(onThisDay: true));
    } else if (value == 'collection:map') {
      unawaited(openPhotoMap(context));
    } else if (value.startsWith('folder:')) {
      final path = Uri.decodeComponent(value.substring('folder:'.length));
      unawaited(
        controller.selectView(
          folderPath: path,
          folderName: path.split('/').last,
        ),
      );
    } else if (value.startsWith('private:')) {
      unawaited(
        controller.selectView(privateAlbumId: int.parse(value.split(':').last)),
      );
    } else if (value.startsWith('shared:')) {
      unawaited(
        controller.selectView(albumId: int.parse(value.split(':').last)),
      );
    }
  }

  Future<void> openPeoplePage(BuildContext context) async {
    final selected = await Navigator.of(context).push<PersonSummary>(
      buildIslePageRoute<PersonSummary>(
        builder: (_) => PhotoPeoplePage(api: api),
      ),
    );
    if (!context.mounted || controller.isDisposed || selected == null) return;
    await controller.selectPerson(
      personId: selected.id,
      personName: selected.displayName,
    );
  }

  Future<void> openSimilarCleanupPage(BuildContext context) async {
    final trashed = await Navigator.of(context).push<bool>(
      buildIslePageRoute<bool>(
        builder: (_) => PhotoSimilarCleanupPage(api: api),
      ),
    );
    if (trashed == true && context.mounted && !controller.isDisposed) {
      await Future.wait([
        controller.loadAssets(reset: true),
        controller.refreshStatus(),
      ]);
    }
  }

  Future<void> openPhotoMap(BuildContext context) async {
    final selected = await Navigator.of(context).push<PhotoAsset>(
      buildIslePageRoute<PhotoAsset>(builder: (_) => PhotoMapPage(api: api)),
    );
    if (context.mounted && !controller.isDisposed && selected != null) {
      await openAsset(context, selected);
    }
  }

  Future<void> openMobilePhotoBackup(BuildContext context) async {
    if (!canBackup || backupDirectory == 'PhonePhotos') {
      final goStorage = await showMobileBackupSpaceRequiredDialog(context);
      if (goStorage && context.mounted) {
        await Navigator.of(context).push(
          buildIslePageRoute<void>(
            builder: (_) => StoragePage(
              api: api,
              isAdmin: isAdmin,
              accountId: offlineAccountId.isEmpty ? null : offlineAccountId,
            ),
          ),
        );
      }
      return;
    }
    await Navigator.of(context).push(
      buildIslePageRoute<void>(
        builder: (_) => MobilePhotoBackupPage(
          api: api,
          accountName: accountName,
          baseDirectory: backupDirectory,
        ),
      ),
    );
  }

  Future<void> upload(BuildContext context) async {
    final count = await openFileUpload(
      context,
      api: api,
      isAdmin: isAdmin,
      directory: uploadDirectory,
      type: FileType.media,
      title: '上传照片与视频',
      taskCenter: taskCenter,
      accountName: accountName,
    );
    if (!context.mounted || controller.isDisposed || count == 0) return;
    String? indexingError;
    if (isAdmin && !controller.scan.scanning) {
      await controller.startScan();
      if (controller.feed.actionIsError) {
        indexingError = controller.feed.actionMessage;
      }
    }
    if (!context.mounted || controller.isDisposed) return;
    await controller.completeUpload(count, indexingError: indexingError);
  }

  Future<void> openExifFilterSheet(BuildContext context) async {
    final scope = controller.scope;
    if (scope.facetCameras.isEmpty && scope.facetYears.isEmpty) {
      await controller.refreshFacets();
    }
    if (!context.mounted || controller.isDisposed) return;
    final selection = await showPhotoExifFilterSheet(
      context,
      facetCameras: scope.facetCameras,
      facetYears: scope.facetYears,
      cameraFilter: scope.cameraFilter,
      locationFilter: scope.locationFilter,
      yearFilter: scope.yearFilter,
      takenFromFilter: scope.takenFromFilter,
      takenToFilter: scope.takenToFilter,
    );
    if (selection == null || !context.mounted || controller.isDisposed) return;
    await controller.applyExifFilter(selection);
  }

  Future<void> jumpToTimelineMonth(
    BuildContext context,
    PhotoTimelineMonth month,
  ) async {
    final loaded = await controller.loadTimelineMonth(month);
    if (!loaded || !context.mounted || controller.isDisposed) return;
    final scrollController = controller.timeline.scrollController;
    if (!scrollController.hasClients) return;
    scrollController.jumpTo(0);
    await WidgetsBinding.instance.endOfFrame;
    final heading = controller.timeline.firstMonthHeadingKey.currentContext;
    if (context.mounted && heading != null && heading.mounted) {
      await Scrollable.ensureVisible(heading, alignment: .08);
    }
  }

  Future<void> chooseTimelineMonth(BuildContext context) async {
    if (!controller.isFullTimelineSelected || controller.feed.loading) return;
    if (controller.timeline.months.isEmpty) {
      await controller.refreshTimelineIndex();
    }
    if (!context.mounted || controller.isDisposed) return;
    if (controller.timeline.months.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂时无法读取拍摄年月，请检查网络并重试。')),
      );
      return;
    }
    final month = await showPhotosTimelineMonthSheet(
      context,
      months: controller.timeline.months,
    );
    if (month != null && context.mounted) {
      await jumpToTimelineMonth(context, month);
    }
  }

  Future<void> createOrRenameAlbum(
    BuildContext context, {
    required PhotoAlbumScope albumScope,
    MediaAlbum? album,
  }) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlbumNameDialog(
        initialName: album?.name ?? '',
        privateAlbum: albumScope == PhotoAlbumScope.personal,
      ),
    );
    if (name == null || !context.mounted || controller.isDisposed) return;
    await controller.albums.saveAlbum(
      albumScope: albumScope,
      name: name,
      existing: album,
    );
  }

  Future<void> deleteAlbum(
    BuildContext context, {
    required PhotoAlbumScope albumScope,
    required MediaAlbum album,
  }) async {
    final confirmed = await showDeletePhotoAlbumDialog(
      context,
      album: album,
      isPrivate: albumScope == PhotoAlbumScope.personal,
    );
    if (!confirmed || !context.mounted || controller.isDisposed) return;
    await controller.albums.deleteAlbum(albumScope: albumScope, album: album);
  }

  void handleMenuAction(BuildContext context, String value) {
    switch (value) {
      case 'gridDensity':
        controller.toggleGridDensity();
      case 'select':
        controller.toggleSelectionMode(clearOnlyOnEnter: true);
      case 'map':
        unawaited(openPhotoMap(context));
      case 'people':
        unawaited(openPeoplePage(context));
      case 'similarCleanup':
        unawaited(openSimilarCleanupPage(context));
      case 'offline':
        if (offlineAccountId.isEmpty) {
          controller.setActionFeedback(
            '当前服务器未提供稳定账号 ID，升级 NAS 后才能安全使用离线照片库。',
          );
        } else {
          Navigator.of(context).push(
            buildIslePageRoute<void>(
              builder: (_) => OfflinePhotosPage(
                api: api,
                accountId: offlineAccountId,
              ),
            ),
          );
        }
      case 'files':
        openFileManager(
          context,
          api: api,
          isAdmin: isAdmin,
          directory: uploadDirectory,
          title: '照片文件',
          taskCenter: taskCenter,
          accountName: accountName,
          accountId: offlineAccountId.isEmpty ? null : offlineAccountId,
        );
      case 'month':
        unawaited(chooseTimelineMonth(context));
      case 'today':
        unawaited(controller.selectView(onThisDay: true));
      case 'sharedFavorites':
        unawaited(controller.selectView(favorites: true));
      case 'scan':
        unawaited(controller.startScan());
      case 'refresh':
        unawaited(controller.refreshLibraryAndAlbums());
      case 'all':
      case 'photo':
      case 'live':
      case 'video':
        controller.setMediaType(value);
      case 'renamePrivate':
        final album = controller.currentPrivateAlbum;
        if (album != null) {
          unawaited(
            createOrRenameAlbum(
              context,
              albumScope: PhotoAlbumScope.personal,
              album: album,
            ),
          );
        }
      case 'deletePrivate':
        final album = controller.currentPrivateAlbum;
        if (album != null) {
          unawaited(
            deleteAlbum(
              context,
              albumScope: PhotoAlbumScope.personal,
              album: album,
            ),
          );
        }
      case 'renameShared':
        final album = controller.currentAlbum;
        if (album != null) {
          unawaited(
            createOrRenameAlbum(
              context,
              albumScope: PhotoAlbumScope.shared,
              album: album,
            ),
          );
        }
      case 'deleteShared':
        final album = controller.currentAlbum;
        if (album != null) {
          unawaited(
            deleteAlbum(
              context,
              albumScope: PhotoAlbumScope.shared,
              album: album,
            ),
          );
        }
      case 'backup':
        unawaited(openMobilePhotoBackup(context));
    }
  }
}
