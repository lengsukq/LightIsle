import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'external_file_opener.dart';
import 'file_export_service.dart';
import 'file_models.dart';
import 'file_name_validation.dart';
import 'file_upload_service.dart';
import 'file_upload_stream.dart';
import 'files_page_state_models.dart';
import 'files_path_utils.dart';
import 'upload_task_center.dart';

typedef FilesOverwriteConfirmer =
    Future<bool> Function({
      required String fileName,
      required String alternativeName,
    });

/// Coordinates resumable uploads, external-app opening, and local/mobile
/// downloads without holding a [BuildContext].
class FilesTransferCoordinator {
  FilesTransferCoordinator({
    required this.dir,
    required this.prefs,
    required this.transfers,
    required this.readApi,
    required this.readAccountName,
    required this.readUploadOnly,
    required this.readOnUploaded,
    required this.readTaskCenter,
    required this.readMobileExportOverride,
    required this.readExportDirectoryFactory,
    required this.readExportDirectoryCleanup,
    required this.isDisposed,
    required this.onChanged,
    required this.refreshCurrentView,
  }) {
    rebuildUploadService();
  }

  final FilesDirectoryState dir;
  final FilesDisplayPrefsState prefs;
  final FilesSelectionAndTransferState transfers;
  final LightIsleApi Function() readApi;
  final String Function() readAccountName;
  final bool Function() readUploadOnly;
  final VoidCallback? Function() readOnUploaded;
  final UploadTaskCenter? Function() readTaskCenter;
  final bool? Function() readMobileExportOverride;
  final Future<Directory> Function(Directory parent)? Function()
  readExportDirectoryFactory;
  final Future<void> Function(Directory directory)? Function()
  readExportDirectoryCleanup;
  final bool Function() isDisposed;
  final VoidCallback onChanged;
  final Future<void> Function() refreshCurrentView;

  late FileUploadService _uploadService;

  void rebuildUploadService() {
    _uploadService = FileUploadService(
      api: readApi(),
      accountName: readAccountName(),
      allowAutoRename: () => prefs.uploadAutoRename,
      onChanged: onChanged,
      onUploaded: () => readOnUploaded()?.call(),
      formatError: userFacingError,
    );
  }

  List<FileUploadJob> get uploadJobs =>
      readTaskCenter()?.jobs ?? transfers.uploadJobs;

  bool get hasActiveLocalUploads => transfers.uploadJobs.any(
    (job) =>
        job.status == FileUploadStatus.checking ||
        job.status == FileUploadStatus.uploading ||
        job.status == FileUploadStatus.paused,
  );

  bool needsCancelConfirmation(FileUploadJob job) =>
      job.status == FileUploadStatus.uploading ||
      (job.status == FileUploadStatus.paused && job.offset > 0) ||
      job.uploadId != null;

  void handleTaskCenterChange() {
    if (isDisposed()) return;
    final api = readApi();
    final finished =
        readTaskCenter()?.jobs
            .where(
              (job) =>
                  job.status == FileUploadStatus.complete &&
                  job.rootIdentity == api.selectedRoot?.identity &&
                  (job.actualDestination.startsWith('${dir.path}/') ||
                      dir.path == '.'),
            )
            .toSet() ??
        <FileUploadJob>{};
    final hasNew = finished
        .difference(transfers.observedCompletedUploads)
        .isNotEmpty;
    transfers.observedCompletedUploads
      ..clear()
      ..addAll(finished);
    onChanged();
    if (hasNew && !readUploadOnly() && !dir.loading) {
      unawaited(refreshCurrentView());
    }
  }

  Future<void> pickUploads({FileType type = FileType.any}) async {
    if (!dir.canWrite || transfers.uploadBusy) return;
    transfers.uploadBusy = true;
    onChanged();
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: '选择要上传的文件',
        type: type,
        darwinOptions: const DarwinOptions(
          assetRepresentationMode: DarwinAssetRepresentationMode.current,
        ),
      );
    } catch (error) {
      if (!isDisposed()) {
        transfers.uploadBusy = false;
        dir.error = '无法打开文件选择器：${userFacingError(error)}';
        onChanged();
      }
      return;
    }
    if (isDisposed()) return;
    if (files.isEmpty) {
      transfers.uploadBusy = false;
      onChanged();
      return;
    }
    final api = readApi();
    final destinationDirectory = dir.path;
    final jobs = <FileUploadJob>[];
    for (final file in files) {
      final issue = validateFileName(file.name);
      if (issue != null) {
        dir.error = '“${file.name}”无法上传：$issue';
        onChanged();
        continue;
      }
      jobs.add(
        FileUploadJob(
          file: file,
          destination: joinRelativeFilePath(destinationDirectory, file.name),
          rootIdentity: api.selectedRoot?.identity,
        ),
      );
    }
    if (jobs.isEmpty) {
      transfers.uploadBusy = false;
      onChanged();
      return;
    }
    final center = readTaskCenter();
    if (center != null) {
      dir.error = null;
      onChanged();
      await center.enqueue(
        jobs.map((job) => job.file).toList(),
        directory: destinationDirectory,
        root: api.selectedRoot,
        autoRename: prefs.uploadAutoRename,
      );
      if (!isDisposed()) {
        transfers.uploadBusy = false;
        onChanged();
      }
      return;
    }
    transfers.uploadJobs.addAll(jobs);
    dir.error = null;
    onChanged();
    for (final job in jobs) {
      if (isDisposed() || job.cancelRequested) continue;
      await _uploadService.run(job);
    }
    if (!isDisposed()) {
      transfers.uploadBusy = false;
      onChanged();
      await refreshCurrentView();
    }
  }

  void togglePause(FileUploadJob job) {
    final center = readTaskCenter();
    if (center != null) {
      center.togglePause(job);
      return;
    }
    job.togglePause();
    onChanged();
  }

  Future<void> cancelUpload(FileUploadJob job, {bool discard = false}) async {
    final center = readTaskCenter();
    if (center != null) {
      center.cancel(job);
      return;
    }
    if (discard) {
      job.requestCancel();
      await _uploadService.abort(job);
      job.status = FileUploadStatus.cancelled;
      onChanged();
      return;
    }
    job.requestCancel();
    onChanged();
  }

  void cancelActiveUploads() {
    for (final job in transfers.uploadJobs) {
      if (job.status == FileUploadStatus.uploading ||
          job.status == FileUploadStatus.paused ||
          job.status == FileUploadStatus.checking) {
        job.requestCancel();
      }
    }
  }

  void abortAllAndClearBusy() {
    cancelActiveUploads();
    transfers.uploadBusy = false;
    onChanged();
  }

  Future<void> retryUpload(FileUploadJob job) async {
    final center = readTaskCenter();
    if (center != null) {
      center.retry(job);
      return;
    }
    if (transfers.uploadBusy) return;
    transfers.uploadBusy = true;
    job.prepareRetry();
    onChanged();
    await _uploadService.run(job);
    if (!isDisposed()) {
      transfers.uploadBusy = false;
      onChanged();
    }
  }

  void clearUploadJob(FileUploadJob job) {
    final center = readTaskCenter();
    if (center != null) {
      center.clearFinished();
      return;
    }
    transfers.uploadJobs.remove(job);
    onChanged();
  }

  Future<void> openExternal(FileEntry item) async {
    if (transfers.downloading.contains(item.path)) return;
    transfers.downloading.add(item.path);
    transfers.downloadProgress[item.path] = 0;
    transfers.downloadMessage = null;
    onChanged();
    try {
      final message = await ExternalFileOpener.open(
        api: readApi(),
        path: item.path,
        name: item.name,
        size: item.size,
        onProgress: (value) {
          if (isDisposed()) return;
          transfers.downloadProgress[item.path] = value;
          onChanged();
        },
      );
      if (!isDisposed()) {
        transfers.downloadMessage = message;
        onChanged();
      }
    } catch (error) {
      if (!isDisposed()) {
        transfers.downloadMessage =
            '无法通过其他应用打开：${userFacingError(error)}。可以改用“下载”保存原文件。';
        onChanged();
      }
    } finally {
      if (!isDisposed()) {
        transfers.downloading.remove(item.path);
        transfers.downloadProgress.remove(item.path);
        onChanged();
      }
    }
  }

  Future<void> downloadEntry(
    FileEntry item, {
    required FilesOverwriteConfirmer confirmSaveAsAlternative,
  }) async {
    if (transfers.downloading.contains(item.path)) return;
    final fileName = item.isFolder
        ? '${item.name}.zip'
        : item.name.split('/').last.split('\\').last;
    final nameIssue = validateFileName(fileName);
    if (nameIssue != null) {
      transfers.downloadMessage = '无法保存此文件：$nameIssue';
      onChanged();
      return;
    }

    final mobileExport =
        readMobileExportOverride() ??
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    Directory? temporaryDirectory;
    String? destination;
    try {
      if (mobileExport) {
        final temporaryRoot = await getTemporaryDirectory();
        final factory = readExportDirectoryFactory();
        temporaryDirectory =
            await (factory?.call(temporaryRoot) ??
                temporaryRoot.createTemp('lightisle-export-'));
        destination = joinNativeFilePath(temporaryDirectory.path, fileName);
      } else {
        final directory = await FilePicker.getDirectoryPath(
          dialogTitle: '选择文件保存目录',
        );
        if (isDisposed() || directory == null || directory.isEmpty) return;
        final normalizedDirectory = normalizeFilePickerPath(directory);
        destination = await _destinationWithoutOverwrite(
          normalizedDirectory,
          fileName,
          confirmSaveAsAlternative: confirmSaveAsAlternative,
        );
        if (destination == null) return;
      }
    } catch (error) {
      if (!isDisposed()) {
        transfers.downloadMessage = '无法准备下载位置：${userFacingError(error)}';
        onChanged();
      }
      return;
    }
    if (isDisposed()) {
      await _removeTemporaryDirectory(temporaryDirectory);
      return;
    }

    transfers.downloading.add(item.path);
    transfers.downloadProgress[item.path] = 0;
    transfers.downloadMessage = null;
    onChanged();
    try {
      await readApi().download(
        item.isFolder ? '/api/v2/files/archive' : '/api/v2/files/content',
        destination,
        query: {'path': item.path},
        onProgress: (received, total) {
          if (total <= 0 || isDisposed()) return;
          transfers.downloadProgress[item.path] = (received / total)
              .clamp(0, 1)
              .toDouble();
          onChanged();
        },
      );
      if (isDisposed()) return;
      if (mobileExport) {
        final exportResult = await fileExportChannel.invokeMethod<String>(
          'exportFile',
          {'path': destination, 'name': fileName},
        );
        if (!isDisposed()) {
          transfers.downloadMessage = exportResult == null
              ? '已取消导出，临时文件已清理。'
              : exportResult == 'shared'
              ? '已完成系统分享或保存。'
              : '已保存到所选位置：$exportResult';
          transfers.downloadProgress.remove(item.path);
          onChanged();
        }
      } else {
        transfers.downloadMessage = '已下载到：$destination';
        transfers.downloadProgress.remove(item.path);
        onChanged();
      }
    } catch (error) {
      if (!isDisposed()) {
        transfers.downloadMessage =
            '下载或导出失败：${friendlyFileDownloadError(error, archive: item.isFolder)}';
        transfers.downloadProgress.remove(item.path);
        onChanged();
      }
    } finally {
      await _removeTemporaryDirectory(temporaryDirectory);
      if (!isDisposed()) {
        transfers.downloading.remove(item.path);
        onChanged();
      }
    }
  }

  Future<String?> _destinationWithoutOverwrite(
    String directory,
    String fileName, {
    required FilesOverwriteConfirmer confirmSaveAsAlternative,
  }) async {
    final destination = joinNativeFilePath(directory, fileName);
    if (!await File(destination).exists()) return destination;
    final alternative = await nextAvailableLocalDestination(
      directory,
      fileName,
    );
    if (isDisposed()) return null;
    final saveCopy = await confirmSaveAsAlternative(
      fileName: fileName,
      alternativeName: nativeFileBasename(alternative),
    );
    return saveCopy ? alternative : null;
  }

  Future<void> _removeTemporaryDirectory(Directory? directory) async {
    if (directory == null) return;
    try {
      final cleanup = readExportDirectoryCleanup();
      if (cleanup != null) {
        await cleanup(directory);
      } else if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Temporary exports are private data; cleanup is best-effort on disk errors.
    }
  }
}
