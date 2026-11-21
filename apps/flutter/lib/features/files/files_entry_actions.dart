import 'package:flutter/foundation.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../media/media_models.dart';
import 'file_destination_dialog.dart';
import 'file_models.dart';
import 'file_preview_support.dart';
import 'files_page_state_models.dart';
import 'files_path_utils.dart';

final class FilesCinemaLookupOutcome {
  const FilesCinemaLookupOutcome({required this.stale, this.film});

  final bool stale;
  final CinemaFilm? film;
}

final class FilesTextPreviewOutcome {
  const FilesTextPreviewOutcome({this.text, this.error});

  final String? text;
  final String? error;
}

/// Executes single-entry file mutations (create folder, move/copy, rename,
/// trash, restore, purge, extract ZIP) and preview data loading without
/// holding a [BuildContext].
class FilesEntryActionsCoordinator {
  const FilesEntryActionsCoordinator({
    required this.dir,
    required this.transfers,
    required this.readApi,
    required this.canWriteItem,
    required this.canPurgeTrashItem,
    required this.isDisposed,
    required this.isBrowserRequestCurrent,
    required this.onChanged,
    required this.refreshCurrentView,
    required this.loadTrash,
  });

  final FilesDirectoryState dir;
  final FilesSelectionAndTransferState transfers;
  final LightIsleApi Function() readApi;
  final bool Function(FileEntry item) canWriteItem;
  final bool Function(TrashEntry item) canPurgeTrashItem;
  final bool Function() isDisposed;
  final bool Function(int generation, String rootIdentity)
  isBrowserRequestCurrent;
  final VoidCallback onChanged;
  final Future<void> Function() refreshCurrentView;
  final Future<void> Function() loadTrash;

  Future<void> createFolder(String name) async {
    if (!dir.canWrite) return;
    final path = joinRelativeFilePath(dir.path, name);
    dir.error = null;
    onChanged();
    try {
      await readApi().send(
        'POST',
        '/api/v2/files/folders',
        body: {'path': path},
      );
      await refreshCurrentView();
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '新建文件夹失败：${userFacingError(error)}';
        onChanged();
      }
    }
  }

  Future<String?> operateEntry(
    FileEntry item, {
    required String action,
    required FileDestinationSelection selection,
  }) async {
    if (action == 'move' && !canWriteItem(item)) return null;
    if (item.isFolder && selection.path.startsWith('${item.path}/')) {
      dir.error = '不能将文件夹移动或复制到自己的子目录中。';
      onChanged();
      return null;
    }
    dir.error = null;
    onChanged();
    try {
      final result = await readApi().send(
        'POST',
        '/api/v2/files/operations',
        body: <String, Object>{
          'action': action,
          'from': item.path,
          'to': selection.path,
          'conflict': selection.conflict,
        },
      );
      if (isDisposed()) return null;
      await refreshCurrentView();
      if (isDisposed()) return null;
      return result['skipped'] == true
          ? '目标已存在，已安全跳过'
          : '操作完成：${result['finalTo']?.toString() ?? selection.path}';
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '文件操作失败：${userFacingError(error)}';
        onChanged();
      }
      return null;
    }
  }

  Future<void> renameEntry(FileEntry item, String newName) async {
    if (!canWriteItem(item) || newName == item.name) return;
    final slash = item.path.lastIndexOf('/');
    final destination = slash < 0
        ? newName
        : '${item.path.substring(0, slash)}/$newName';
    try {
      await readApi().send(
        'POST',
        '/api/v2/files/operations',
        body: {
          'action': 'move',
          'from': item.path,
          'to': destination,
          'conflict': '',
        },
      );
      if (!isDisposed()) await refreshCurrentView();
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '重命名失败：${userFacingError(error)}';
        onChanged();
      }
    }
  }

  Future<void> trashEntry(FileEntry item) async {
    if (!canWriteItem(item)) return;
    dir.error = null;
    onChanged();
    try {
      await readApi().send(
        'DELETE',
        '/api/v2/files',
        query: {'path': item.path},
      );
      await refreshCurrentView();
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '未能确认移入回收站的结果：${userFacingError(error)}';
        onChanged();
      }
    }
  }

  Future<void> restoreTrashEntry(TrashEntry item) async {
    try {
      await readApi().send(
        'POST',
        '/api/v2/files/trash/${Uri.encodeComponent(item.id)}/restore',
      );
      await loadTrash();
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '未能确认恢复结果：${userFacingError(error)}';
        onChanged();
      }
    }
  }

  Future<void> purgeTrashEntry(TrashEntry item) async {
    if (!canPurgeTrashItem(item)) return;
    try {
      await readApi().send(
        'DELETE',
        '/api/v2/files/trash/${Uri.encodeComponent(item.id)}',
      );
      await loadTrash();
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '未能确认永久删除结果：${userFacingError(error)}';
        onChanged();
      }
    }
  }

  Future<String?> extractZip(FileEntry item) async {
    if (!canWriteItem(item) || dir.loading || transfers.batchBusy) return null;
    dir.loading = true;
    dir.error = null;
    onChanged();
    try {
      final result = await readApi().send(
        'POST',
        '/api/v2/files/extract',
        body: {'path': item.path},
      );
      if (isDisposed()) return null;
      await refreshCurrentView();
      if (isDisposed()) return null;
      return result['targetPath']?.toString() ?? item.name;
    } catch (error) {
      if (!isDisposed()) {
        dir.loading = false;
        dir.error = '解压失败：${userFacingError(error)}';
        onChanged();
      }
      return null;
    }
  }

  Future<FilesCinemaLookupOutcome> lookupCinemaFilmForPreview(
    FileEntry item,
  ) async {
    final generation = dir.loadGeneration;
    final rootIdentity = dir.rootIdentity;
    final directory = dir.path;
    CinemaFilm? film;
    try {
      final response = await readApi().get(
        '/api/v2/cinema/lookup',
        query: {'path': item.path},
      );
      final parsed = CinemaFilm.fromJson(response);
      if (parsed.id > 0) film = parsed;
    } catch (_) {
      film = null;
    }
    if (!isBrowserRequestCurrent(generation, rootIdentity) ||
        directory != dir.path) {
      return const FilesCinemaLookupOutcome(stale: true);
    }
    return FilesCinemaLookupOutcome(stale: false, film: film);
  }

  Future<FilesTextPreviewOutcome?> loadTextPreview(FileEntry item) async {
    final generation = dir.loadGeneration;
    final rootIdentity = dir.rootIdentity;
    final directory = dir.path;
    String? decodedText;
    String? failure;
    try {
      final data = await readApi().bytes(
        '/api/v2/files/preview',
        query: {'path': item.path},
        maxBytes: kFilesMaxTextPreviewSize,
      );
      decodedText = decodePreviewText(data);
    } catch (error) {
      failure = error is FormatException
          ? '无法识别文本编码，原文件未更改。可尝试其他编辑器。'
          : userFacingError(error);
    }
    if (!isBrowserRequestCurrent(generation, rootIdentity) ||
        directory != dir.path) {
      return null;
    }
    return FilesTextPreviewOutcome(text: decodedText, error: failure);
  }
}
