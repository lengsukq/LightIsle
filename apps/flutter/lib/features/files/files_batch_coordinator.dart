import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'file_batch_operations.dart';
import 'file_export_service.dart';
import 'file_models.dart';
import 'file_selection_snapshot.dart';
import 'files_page_state_models.dart';

final class FilesBatchTransferGuard {
  const FilesBatchTransferGuard({
    required this.action,
    required this.rootIdentity,
    required this.sourceDirectory,
    required this.paths,
    required this.items,
    required this.requireWritable,
  });

  final String action;
  final String rootIdentity;
  final String sourceDirectory;
  final List<String> paths;
  final List<FileEntry> items;
  final bool requireWritable;
}

final class FilesBatchTrashGuard {
  const FilesBatchTrashGuard({
    required this.rootIdentity,
    required this.sourceDirectory,
    required this.paths,
  });

  final String rootIdentity;
  final String sourceDirectory;
  final List<String> paths;
}

/// Coordinates multi-selection state and batch move/copy/save/trash operations
/// without holding any [BuildContext].
class FilesBatchCoordinator {
  FilesBatchCoordinator({
    required this.dir,
    required this.transfers,
    required this.readApi,
    required this.canWriteItem,
    required this.isDisposed,
    required this.onChanged,
    required this.refreshCurrentView,
  });

  final FilesDirectoryState dir;
  final FilesSelectionAndTransferState transfers;
  final LightIsleApi Function() readApi;
  final bool Function(FileEntry item) canWriteItem;
  final bool Function() isDisposed;
  final VoidCallback onChanged;
  final Future<void> Function() refreshCurrentView;

  FileBatchOperations get _batchOperations => FileBatchOperations(readApi());

  String get _liveRootIdentity =>
      readApi().selectedRoot?.identity ?? 'default';

  FileSelectionSnapshot get selectionSnapshot => FileSelectionSnapshot(
    loadedEntries: dir.entries,
    selectedPaths: transfers.selectedPaths,
    canWrite: canWriteItem,
  );

  bool isSelectionStillCurrent(
    String rootIdentity,
    String directory,
    List<String> paths, {
    bool requireWritable = true,
  }) =>
      dir.rootIdentity == rootIdentity &&
      _liveRootIdentity == rootIdentity &&
      dir.path == directory &&
      transfers.selectedPaths.length == paths.length &&
      transfers.selectedPaths.containsAll(paths) &&
      (requireWritable
          ? selectionSnapshot.writableSelection
          : selectionSnapshot.fullyLoaded);

  void toggleSelectingMode() {
    transfers.selecting = !transfers.selecting;
    transfers.selectedPaths.clear();
    transfers.selectionAnchorPath = null;
    onChanged();
  }

  void clearSelectedPaths() {
    transfers.selectedPaths.clear();
    onChanged();
  }

  void exitSelectionMode() {
    transfers.clearSelection();
    onChanged();
  }

  void startSelectingItem(FileEntry item) {
    transfers.selecting = true;
    onChanged();
    toggleSelected(item, !transfers.selectedPaths.contains(item.path));
  }

  void selectWithShiftClick(FileEntry item) {
    if (transfers.selectionAnchorPath != null &&
        dir.entries.any(
          (entry) => entry.path == transfers.selectionAnchorPath,
        )) {
      selectRangeTo(item);
      return;
    }
    transfers.selecting = true;
    onChanged();
    toggleSelected(item, true, shiftPressed: false);
  }

  void toggleSelected(
    FileEntry item,
    bool? selected, {
    bool? shiftPressed,
  }) {
    final useShift = shiftPressed ?? HardwareKeyboard.instance.isShiftPressed;
    if (useShift &&
        transfers.selectionAnchorPath != null &&
        dir.entries.any(
          (entry) => entry.path == transfers.selectionAnchorPath,
        )) {
      selectRangeTo(item);
      return;
    }
    if (selected == true &&
        !transfers.selectedPaths.contains(item.path) &&
        transfers.selectedPaths.length >= FileSelectionSnapshot.maxSelection) {
      dir.error = '每次最多选择 50 项文件。';
      onChanged();
      return;
    }
    if (selected == true) {
      transfers.selectedPaths.add(item.path);
      transfers.selectionAnchorPath = item.path;
    } else {
      transfers.selectedPaths.remove(item.path);
    }
    dir.error = null;
    onChanged();
  }

  void selectRangeTo(FileEntry target) {
    final entries = dir.entries;
    final anchorPath = transfers.selectionAnchorPath;
    final anchorIndex = anchorPath == null
        ? -1
        : entries.indexWhere((entry) => entry.path == anchorPath);
    final targetIndex = entries.indexWhere(
      (entry) => entry.path == target.path,
    );
    if (anchorIndex < 0 || targetIndex < 0) {
      toggleSelected(
        target,
        !transfers.selectedPaths.contains(target.path),
        shiftPressed: false,
      );
      return;
    }
    final start = anchorIndex < targetIndex ? anchorIndex : targetIndex;
    final end = anchorIndex > targetIndex ? anchorIndex : targetIndex;
    final additions = entries
        .sublist(start, end + 1)
        .map((entry) => entry.path)
        .toList(growable: false);
    final next = {...transfers.selectedPaths};
    var truncated = false;
    for (final path in additions) {
      if (next.contains(path)) continue;
      if (next.length >= FileSelectionSnapshot.maxSelection) {
        truncated = true;
        break;
      }
      next.add(path);
    }
    transfers.selecting = true;
    transfers.selectedPaths
      ..clear()
      ..addAll(next);
    dir.error = truncated ? '已按 Shift 区间选择，单次最多选择 50 项文件。' : null;
    onChanged();
  }

  void toggleSelectAllVisible({bool enterSelectionMode = false}) {
    final selection = selectionSnapshot;
    if (selection.visiblePaths.isEmpty) return;
    if (enterSelectionMode) {
      transfers.selecting = true;
    }
    transfers.selectedPaths
      ..clear()
      ..addAll(selection.toggledVisible());
    onChanged();
  }

  void requestBatchStop() {
    if (transfers.batchStopRequested) return;
    transfers.batchStopRequested = true;
    onChanged();
  }

  FilesBatchTransferGuard? prepareBatchTransfer(String action) {
    if (transfers.batchBusy || dir.loading || transfers.selectedPaths.isEmpty) {
      return null;
    }
    final selection = selectionSnapshot;
    final byPath = {for (final item in dir.entries) item.path: item};
    final paths = transfers.selectedPaths.toList(growable: false);
    final requireWritable = action != 'copy';
    if (requireWritable && !selection.writableSelection) {
      dir.error = '选择已变更或包含只读项目，请刷新目录再试。';
      onChanged();
      return null;
    }
    if (!selection.fullyLoaded) {
      dir.error = '选择已变更，请刷新目录再试。';
      onChanged();
      return null;
    }
    return FilesBatchTransferGuard(
      action: action,
      rootIdentity: _liveRootIdentity,
      sourceDirectory: dir.path,
      paths: paths,
      items: [for (final path in paths) byPath[path]!],
      requireWritable: requireWritable,
    );
  }

  FileBatchTransferPlan? planBatchTransfer(
    FilesBatchTransferGuard guard,
    String destinationPath,
  ) {
    if (!isSelectionStillCurrent(
      guard.rootIdentity,
      guard.sourceDirectory,
      guard.paths,
      requireWritable: guard.requireWritable,
    )) {
      dir.error = '共享目录或选择已变化，请刷新后重新选择文件。';
      onChanged();
      return null;
    }
    final plan = FileBatchOperations.planTransfer(
      action: guard.action,
      items: guard.items,
      destination: destinationPath,
    );
    if (plan.invalidPaths.isNotEmpty) {
      dir.error =
          '有 ${plan.invalidPaths.length} 个项目的目标为原位置或自身子目录，请重新选择其他目录。';
      onChanged();
      return null;
    }
    return plan;
  }

  Future<String?> executeConfirmedBatchTransfer({
    required FilesBatchTransferGuard guard,
    required FileBatchTransferPlan plan,
    required String destinationPath,
  }) async {
    if (!isSelectionStillCurrent(
      guard.rootIdentity,
      guard.sourceDirectory,
      guard.paths,
      requireWritable: guard.requireWritable,
    )) {
      dir.error = '共享目录或选择已变化，未开始批量操作。';
      onChanged();
      return null;
    }
    return _executeBatchTransferPlan(
      action: guard.action,
      plan: plan,
      destinationPath: destinationPath,
      rootIdentity: guard.rootIdentity,
      sourceDirectory: guard.sourceDirectory,
    );
  }

  Future<String?> retryFailedBatchTransfer() async {
    final retry = transfers.lastFailedBatchRetry;
    if (retry == null || transfers.batchBusy || dir.loading) return null;
    final byPath = {for (final item in dir.entries) item.path: item};
    final items = <FileEntry>[
      for (final path in retry.failedPaths)
        if (byPath[path] != null) byPath[path]!,
    ];
    if (items.isEmpty) {
      transfers.lastFailedBatchRetry = null;
      dir.error = '待重试的文件已不在当前目录，请刷新后重新选择。';
      onChanged();
      return null;
    }
    final plan = FileBatchOperations.planTransfer(
      action: retry.action,
      items: items,
      destination: retry.destination,
    );
    if (!plan.valid) {
      transfers.lastFailedBatchRetry = null;
      dir.error = '重试目标路径无效，请重新选择目标目录。';
      onChanged();
      return null;
    }
    return _executeBatchTransferPlan(
      action: retry.action,
      plan: plan,
      destinationPath: retry.destination,
      rootIdentity: _liveRootIdentity,
      sourceDirectory: dir.path,
    );
  }

  Future<String?> _executeBatchTransferPlan({
    required String action,
    required FileBatchTransferPlan plan,
    required String destinationPath,
    required String rootIdentity,
    required String sourceDirectory,
  }) async {
    transfers.batchBusy = true;
    transfers.batchStopRequested = false;
    transfers.batchActionLabel = action == 'move' ? '移动' : '复制';
    transfers.batchProgress = FileBatchProgress(
      index: 1,
      total: plan.items.length,
      currentName: plan.items.first.name,
    );
    transfers.lastFailedBatchRetry = null;
    dir.error = null;
    onChanged();
    try {
      final result = await _batchOperations.transfer(
        action: action,
        plan: plan,
        destination: destinationPath,
        stillCurrent: () =>
            !isDisposed() &&
            dir.rootIdentity == rootIdentity &&
            dir.path == sourceDirectory &&
            _liveRootIdentity == rootIdentity,
        stopRequested: () => transfers.batchStopRequested,
        onProgress: (progress) {
          if (isDisposed()) return;
          transfers.batchProgress = progress;
          onChanged();
        },
      );
      if (isDisposed() ||
          dir.rootIdentity != rootIdentity ||
          dir.path != sourceDirectory ||
          _liveRootIdentity != rootIdentity) {
        return null;
      }
      await refreshCurrentView();
      if (isDisposed() ||
          dir.rootIdentity != rootIdentity ||
          _liveRootIdentity != rootIdentity) {
        return null;
      }
      transfers.selectedPaths
        ..clear()
        ..addAll(result.failedPaths);
      if (result.failedPaths.isEmpty) {
        transfers.lastFailedBatchRetry = null;
        dir.error = null;
      } else {
        transfers.lastFailedBatchRetry = (
          action: action,
          destination: destinationPath,
          failedPaths: result.failedPaths,
        );
        final reasons = result.failures
            .take(3)
            .map((failure) => '${failure.path}（${failure.reason}）')
            .join('；');
        final more = result.failures.length > 3
            ? ' 等 ${result.failures.length} 项'
            : '';
        final prefix = result.stoppedByUser
            ? '已手动停止后续项，已完成 ${result.completed} 项，剩余 ${result.failedPaths.length} 项未执行'
            : '已完成 ${result.completed} 项，${result.failedPaths.length} 项未完成';
        dir.error = '$prefix：$reasons$more；未完成项目仍保留选择，可点击「仅重试失败项」。';
      }
      onChanged();
      return '批量${action == 'move' ? '移动' : '复制'}已完成 ${result.completed}/${plan.items.length} 项。';
    } finally {
      if (!isDisposed()) {
        transfers.batchBusy = false;
        transfers.batchProgress = null;
        transfers.batchStopRequested = false;
        onChanged();
      }
    }
  }

  Future<String?> batchSaveSelected() async {
    if (dir.loading || transfers.batchBusy || transfers.selectedPaths.isEmpty) {
      return null;
    }
    final selection = selectionSnapshot;
    if (!selection.fullyLoaded) {
      dir.error = '文件列表已变化，请重新选择。';
      onChanged();
      return null;
    }
    if (!selection.canExportFiles) {
      dir.error = '批量保存暂不支持文件夹，请只选择文件。';
      onChanged();
      return null;
    }
    final selected = selection.selectedEntries;
    transfers.batchBusy = true;
    dir.error = null;
    onChanged();
    try {
      final message = await exportSelectedFiles(
        readApi(),
        items: [
          for (final item in selected)
            (path: item.path, name: item.name, size: item.size),
        ],
      );
      if (isDisposed()) return null;
      return message;
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '批量保存失败：${userFacingError(error)}';
        onChanged();
      }
      return null;
    } finally {
      if (!isDisposed()) {
        transfers.batchBusy = false;
        onChanged();
      }
    }
  }

  FilesBatchTrashGuard? prepareBatchTrash() {
    final paths = transfers.selectedPaths.toList(growable: false);
    if (paths.isEmpty) return null;
    if (paths.length > FileSelectionSnapshot.maxSelection) {
      dir.error = '每次最多选择 50 项移入回收站。';
      onChanged();
      return null;
    }
    if (!selectionSnapshot.writableSelection) {
      dir.error = '所选项目包含只读或已变更的项目，请刷新后重试。';
      onChanged();
      return null;
    }
    return FilesBatchTrashGuard(
      rootIdentity: _liveRootIdentity,
      sourceDirectory: dir.path,
      paths: paths,
    );
  }

  Future<void> executeBatchTrash(FilesBatchTrashGuard guard) async {
    if (!isSelectionStillCurrent(
      guard.rootIdentity,
      guard.sourceDirectory,
      guard.paths,
    )) {
      dir.error = '共享目录或选择已变化，未执行批量删除。';
      onChanged();
      return;
    }
    dir.error = null;
    onChanged();
    try {
      final result = await _batchOperations.trash(guard.paths);
      if (isDisposed() ||
          dir.rootIdentity != guard.rootIdentity ||
          _liveRootIdentity != guard.rootIdentity) {
        return;
      }
      await refreshCurrentView();
      if (isDisposed() ||
          dir.rootIdentity != guard.rootIdentity ||
          _liveRootIdentity != guard.rootIdentity) {
        return;
      }
      if (result.failureCount > 0) {
        transfers.selectedPaths.addAll(result.failedPaths);
        dir.error = result.needsRootCheck
            ? '已确认 ${result.succeeded} 项移入回收站。硬盘连接发生变化，部分操作结果不确定；请重新连接原硬盘，检查原目录和回收站后再重试。'
            : result.needsTrashCheck
            ? '已确认 ${result.succeeded} 项移入回收站。检测到文件已变化，后续操作已停止；请检查原目录和回收站。'
            : '${result.failureCount} 项移入回收站失败，${result.succeeded} 项已完成。请检查权限后重试。';
        onChanged();
      } else if (result.receivedCount != guard.paths.length) {
        dir.error = '服务端没有返回完整的操作结果，请刷新目录确认文件状态。';
        onChanged();
      }
    } catch (error) {
      if (!isDisposed()) {
        dir.error = '批量操作失败：${userFacingError(error)}';
        onChanged();
      }
    }
  }
}
