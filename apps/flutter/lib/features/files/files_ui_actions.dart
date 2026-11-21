import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../media/cinema_detail_dialog.dart';
import '../media/media_models.dart';
import '../media/photo_gallery_viewer.dart';
import '../settings/admin_smb_page.dart';
import '../settings/dav_page.dart';
import 'downloads_page.dart';
import 'duplicate_files_page.dart';
import 'file_destination_dialog.dart';
import 'file_entry_visuals.dart';
import 'file_media_playlist.dart';
import 'file_models.dart';
import 'file_pdf_preview.dart';
import 'file_preview_support.dart';
import 'file_share_dialog.dart';
import 'file_text_preview_dialog.dart';
import 'file_upload_stream.dart';
import 'files_controller.dart';
import 'files_dialogs.dart';
import 'files_item_tiles.dart';
import 'upload_task_center_page.dart';

typedef FilesUploadRouteOpener =
    Future<int> Function(
      BuildContext context, {
      required String directory,
      required FileType type,
      required String title,
    });

/// UI interaction coordinator bridging user gestures, dialogs, navigation, and
/// SnackBars with [FilesController].
class FilesUiActions {
  const FilesUiActions({
    required this.controller,
    required this.openUploadRoute,
  });

  final FilesController controller;
  final FilesUploadRouteOpener openUploadRoute;

  Future<void> openDownloads(BuildContext context) async {
    await Navigator.of(context).push(
      buildIslePageRoute<void>(
        builder: (_) => DownloadsPage(
          api: controller.api,
          initialDestination: controller.dir.path,
        ),
      ),
    );
    if (context.mounted && !controller.isDisposed) {
      await controller.loadFiles();
    }
  }

  Future<void> openDuplicates(BuildContext context) async {
    final trashed = await Navigator.of(context).push<bool>(
      buildIslePageRoute<bool>(
        builder: (_) => DuplicateFilesPage(
          api: controller.api,
          initialPath: controller.dir.path,
        ),
      ),
    );
    if (trashed == true && context.mounted && !controller.isDisposed) {
      await controller.loadFiles();
    }
  }

  void openWebDavMount(BuildContext context) {
    final canonicalId = controller.accountId?.trim();
    Navigator.of(context).push<void>(
      buildIslePageRoute<void>(
        builder: (_) => DavPage(
          api: controller.api,
          accountId: canonicalId != null && canonicalId.isNotEmpty
              ? canonicalId
              : null,
        ),
      ),
    );
  }

  void openSmbMount(BuildContext context) {
    if (!controller.isAdmin) return;
    Navigator.of(context).push<void>(
      buildIslePageRoute<void>(
        builder: (_) => AdminSmbPage(api: controller.api),
      ),
    );
  }

  void openUploadTaskCenter(BuildContext context) {
    final center = controller.taskCenter;
    if (center == null) return;
    Navigator.of(context).push<void>(
      buildIslePageRoute<void>(
        builder: (_) => UploadTaskCenterPage(center: center),
      ),
    );
  }

  Future<void> chooseUploadSource(BuildContext context) async {
    if (!controller.dir.canWrite || controller.transfers.uploadBusy) return;
    final type = await showFilesUploadSourceSheet(context);
    if (!context.mounted || type == null) return;
    await openUploadRoute(
      context,
      directory: controller.dir.path,
      type: type,
      title: type == FileType.media ? '上传照片与视频' : '上传文件',
    );
    if (context.mounted && !controller.isDisposed) {
      await controller.loadFiles();
    }
  }

  Future<void> createFolder(BuildContext context) async {
    if (!controller.dir.canWrite) return;
    final name = await showFilesCreateFolderDialog(context);
    if (!context.mounted || name == null) return;
    await controller.createFolder(name);
  }

  Future<void> operateEntry(
    BuildContext context,
    FileEntry item,
    String action,
  ) async {
    if (action == 'move' && !controller.canWriteItem(item)) return;
    final selection = await showIsleDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: controller.api,
        sourceName: item.name,
        sourcePath: item.path,
        action: action,
      ),
    );
    if (selection == null || !context.mounted) return;
    final message = await controller.operateEntry(
      item,
      action: action,
      selection: selection,
    );
    if (message != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> renameEntry(BuildContext context, FileEntry item) async {
    if (!controller.canWriteItem(item)) return;
    final name = await showFilesRenameDialog(
      context,
      initialName: item.name,
      isFolder: item.isFolder,
    );
    if (!context.mounted || name == null || name == item.name) return;
    await controller.renameEntry(item, name);
  }

  Future<void> trashEntry(BuildContext context, FileEntry item) async {
    if (!controller.canWriteItem(item)) return;
    final confirmed = await confirmAction(
      context,
      '移到回收站',
      '“${item.name}”会移入回收站，可以之后恢复。',
      action: '移入回收站',
    );
    if (!confirmed || !context.mounted) return;
    await controller.trashEntry(item);
  }

  Future<void> restoreTrashEntry(BuildContext context, TrashEntry item) async {
    final confirmed = await confirmAction(
      context,
      '恢复文件',
      '恢复到原位置“${item.originalPath}”。如果该路径已存在，文件不会被覆盖。',
      action: '恢复',
    );
    if (!confirmed || !context.mounted) return;
    await controller.restoreTrashEntry(item);
  }

  Future<void> purgeTrashEntry(BuildContext context, TrashEntry item) async {
    if (!controller.canPurgeTrashItem(item)) return;
    final confirmed = await confirmAction(
      context,
      '永久删除文件？',
      '“${item.name}”将被永久删除，此操作无法撤销。',
      action: '永久删除',
    );
    if (!confirmed || !context.mounted) return;
    await controller.purgeTrashEntry(item);
  }

  Future<void> extractZip(BuildContext context, FileEntry item) async {
    final target = await controller.extractZip(item);
    if (target != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已解压到：$target')));
    }
  }

  Future<void> shareFile(BuildContext context, FileEntry item) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FileShareDialog(
        api: controller.api,
        path: item.path,
        name: item.name,
        isFolder: item.isFolder,
      ),
    );
  }

  Future<void> downloadEntry(BuildContext context, FileEntry item) async {
    await controller.transfer.downloadEntry(
      item,
      confirmSaveAsAlternative:
          ({required fileName, required alternativeName}) async {
            if (!context.mounted) return false;
            return showFilesOverwriteConfirmDialog(
              context,
              fileName: fileName,
              alternativeName: alternativeName,
            );
          },
    );
  }

  Future<void> openExternal(FileEntry item) =>
      controller.transfer.openExternal(item);

  Future<void> previewEntry(BuildContext context, FileEntry item) async {
    final kind = classifyFilePreview(item.name);
    if (kind == FilePreviewKind.video) {
      final lookup = await controller.lookupCinemaFilmForPreview(item);
      if (!context.mounted || lookup.stale) return;
      if (lookup.film != null) {
        await _openCinemaPlayer(context, lookup.film!);
        return;
      }
    }
    if (kind == FilePreviewKind.image || kind == FilePreviewKind.video) {
      final playlist = FileMediaPlaylist.fromDirectory(
        controller.dir.entries,
        item,
      );
      await Navigator.of(context).push<void>(
        PhotoGalleryViewer.route(
          (_) => PhotoGalleryViewer(
            api: controller.api,
            assets: playlist.assets,
            initialIndex: playlist.initialIndex,
            fileBrowserMode: true,
            canEditSharedFavorite: (_) => false,
            onSharedFavorite: (asset) async => asset,
            onPersonalFavorite: (asset) async => asset,
            onDetails: (_) async {},
            onLoadMore: () async => playlist.assets,
          ),
        ),
      );
      return;
    }
    if (kind == FilePreviewKind.pdf) {
      await showDialog<void>(
        context: context,
        builder: (_) => FilePdfPreviewDialog(
          api: controller.api,
          item: item,
          onOpenExternal: () => unawaited(openExternal(item)),
          onDownload: () => unawaited(downloadEntry(context, item)),
        ),
      );
      return;
    }
    if (kind == FilePreviewKind.external) {
      controller.setDirectoryError('该文件暂不支持在线预览，请通过右侧更多菜单保存文件或使用其他应用打开。');
      return;
    }
    final outcome = await controller.loadTextPreview(item);
    if (outcome == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (_) => FileTextPreviewDialog(
        item: item,
        badge: FileEntryBadge(
          api: controller.api,
          item: item,
          failedThumbnails: controller.dir.failedThumbnails,
        ),
        text: outcome.text,
        error: outcome.error,
        onOpenExternal: () => unawaited(openExternal(item)),
        onDownload: () => unawaited(downloadEntry(context, item)),
      ),
    );
  }

  Future<void> _openCinemaPlayer(
    BuildContext context,
    CinemaFilm initialFilm,
  ) async {
    CinemaFilm? next = initialFilm;
    while (next != null && context.mounted) {
      final current = next;
      next = await Navigator.of(context).push<CinemaFilm>(
        buildIslePageRoute<CinemaFilm>(
          fullscreenDialog: true,
          builder: (_) => CinemaDetailDialog(
            api: controller.api,
            film: current,
            isAdmin: controller.isAdmin,
            accountName: controller.accountName,
            onRename: (renamed) async => renamed,
            onProgressUpdated: (_) {},
            playerOnly: true,
          ),
        ),
      );
    }
  }

  void openOrSelectEntry(BuildContext context, FileEntry item) {
    HapticFeedback.selectionClick();
    if (HardwareKeyboard.instance.isShiftPressed) {
      controller.batch.selectWithShiftClick(item);
      return;
    }
    if (controller.transfers.selecting) {
      controller.batch.toggleSelected(
        item,
        !controller.transfers.selectedPaths.contains(item.path),
      );
    } else if (item.isFolder) {
      unawaited(controller.loadFiles(target: item.path));
    } else {
      unawaited(previewEntry(context, item));
    }
  }

  void dispatchFileAction(
    BuildContext context,
    FileEntry item,
    String action,
  ) {
    switch (action) {
      case 'preview':
        unawaited(previewEntry(context, item));
      case 'openContainingFolder':
        unawaited(controller.openContainingFolder(item));
      case 'download':
        unawaited(downloadEntry(context, item));
      case 'openExternal':
        unawaited(openExternal(item));
      case 'share':
        unawaited(shareFile(context, item));
      case 'copy':
        unawaited(operateEntry(context, item, 'copy'));
      case 'move':
        unawaited(operateEntry(context, item, 'move'));
      case 'rename':
        unawaited(renameEntry(context, item));
      case 'extract':
        unawaited(extractZip(context, item));
      case 'trash':
        unawaited(trashEntry(context, item));
    }
  }

  Future<void> showFileContextMenu(
    BuildContext context,
    Offset globalPosition,
    FileEntry item,
  ) async {
    final selected = await showFilesItemContextMenu(
      context,
      globalPosition: globalPosition,
      item: item,
      writable: controller.canWriteItem(item),
      searching: controller.filter.searching,
    );
    if (selected != null && context.mounted) {
      dispatchFileAction(context, item, selected);
    }
  }

  Future<void> batchTransfer(BuildContext context, String action) async {
    final guard = controller.batch.prepareBatchTransfer(action);
    if (guard == null) return;
    final destination = await showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: controller.api,
        sourceName: '',
        sourcePath: guard.sourceDirectory == '.' ? '' : guard.sourceDirectory,
        action: action,
        directoryOnly: true,
      ),
    );
    if (destination == null || !context.mounted) return;
    final plan = controller.batch.planBatchTransfer(guard, destination.path);
    if (plan == null) return;
    final confirmed = await confirmAction(
      context,
      action == 'move' ? '批量移动文件' : '批量复制文件',
      '将 ${plan.items.length} 项${action == 'move' ? '移动' : '复制'}到'
      '“${destination.path == '.' ? '根目录' : destination.path}”？'
      '同名文件自动改名，原目标文件不会覆盖。'
      '中途失败时已完成的项目会保留，剩余项目可重试。',
      action: action == 'move' ? '开始移动' : '开始复制',
    );
    if (!confirmed || !context.mounted) return;
    final message = await controller.batch.executeConfirmedBatchTransfer(
      guard: guard,
      plan: plan,
      destinationPath: destination.path,
    );
    if (message != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> retryFailedBatchTransfer(BuildContext context) async {
    final message = await controller.batch.retryFailedBatchTransfer();
    if (message != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> batchSave(BuildContext context) async {
    final message = await controller.batch.batchSaveSelected();
    if (message != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> batchTrash(BuildContext context) async {
    final guard = controller.batch.prepareBatchTrash();
    if (guard == null) return;
    final confirmed = await confirmAction(
      context,
      '批量移到回收站',
      '将选中的 ${guard.paths.length} 项移到回收站？之后可以逐项恢复。',
      action: '移入回收站',
    );
    if (!confirmed || !context.mounted) return;
    await controller.batch.executeBatchTrash(guard);
  }

  Future<void> confirmAndCancelUpload(
    BuildContext context,
    FileUploadJob job, {
    bool discard = false,
  }) async {
    if (controller.transfer.needsCancelConfirmation(job)) {
      final approved = await confirmAction(
        context,
        '取消上传任务',
        '确认取消「${job.file.name}」？取消后将清理服务端已接收的临时分片，下次需重新上传。若仅需稍后继续，请使用「暂停上传」。',
        action: '确认取消',
        isDestructive: true,
      );
      if (!approved || !context.mounted) return;
    }
    await controller.transfer.cancelUpload(job, discard: discard);
  }

  void toggleUploadAutoRenameWithFeedback(BuildContext context) {
    controller.setUploadAutoRename(!controller.prefs.uploadAutoRename);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          controller.prefs.uploadAutoRename
              ? '上传时遇到同名文件会自动生成新名称，已保存到本机。'
              : '上传时遇到同名文件不会自动改名，已保存到本机。',
        ),
      ),
    );
  }

  Future<void> handleUploadViewPop(BuildContext context, bool didPop) async {
    if (didPop || controller.taskCenter != null) return;
    if (!controller.hasActiveLocalUploads) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await confirmAction(
      context,
      '结束本次上传？',
      '未完成的上传将取消，设备上的原文件会保留。',
      action: '结束上传',
    );
    if (!leave || !context.mounted) return;
    controller.transfer.abortAllAndClearBusy();
    Navigator.of(context).pop();
  }

  Future<void> copyPathToClipboard(BuildContext context, String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('下载路径已复制。')));
  }
}
