import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'android_folder_backup_access.dart';
import 'desktop_backup_ignore.dart';
import 'desktop_backup_models.dart';
import 'desktop_backup_watcher.dart';
import 'file_name_validation.dart';
import 'photo_backup_hash.dart';

part 'desktop_backup_sync.dart';

class BackupScannedFile {
  const BackupScannedFile({
    required this.relativePath,
    required this.parentRelativeDir,
    required this.fileName,
    required this.size,
    required this.modifiedMs,
    this.localFile,
    this.sourceUri,
  });

  final String relativePath;
  final String parentRelativeDir;
  final String fileName;
  final int size;
  final int modifiedMs;
  final File? localFile;
  final String? sourceUri;
}

class BackupScanResult {
  const BackupScanResult({
    required this.files,
    required this.failures,
    this.skippedSymlinks = 0,
    this.skippedIgnored = 0,
    this.skippedOversized = 0,
  });

  final List<BackupScannedFile> files;
  final List<DesktopBackupFailure> failures;
  final int skippedSymlinks;
  final int skippedIgnored;
  final int skippedOversized;
}

/// Abstract read-only source interface shared by Desktop filesystem folders
/// and Android SAF document trees so both reuse the exact same incremental
/// verification and two-phase replacement pipeline.
abstract class BackupFolderSource {
  const BackupFolderSource();

  Future<BackupScanResult> scan({
    required DesktopBackupTask task,
    required DesktopBackupIgnoreMatcher matcher,
    Set<String>? onlyPaths,
    required void Function() checkActive,
  });

  Future<({int size, int modifiedMs})?> statFile(
    BackupScannedFile item, {
    required void Function() checkActive,
  });

  Future<PhotoHashResult> hashFile(
    BackupScannedFile item, {
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  });

  Stream<List<int>> readChunk(
    BackupScannedFile item, {
    required int offset,
    required int length,
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  });

  Future<void> verifyUnchangedBeforeComplete(
    BackupScannedFile item, {
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  });
}

class LocalFilesystemFolderSource extends BackupFolderSource {
  const LocalFilesystemFolderSource(this.rootPath);

  final String rootPath;

  @override
  Future<BackupScanResult> scan({
    required DesktopBackupTask task,
    required DesktopBackupIgnoreMatcher matcher,
    Set<String>? onlyPaths,
    required void Function() checkActive,
  }) async {
    final files = <BackupScannedFile>[];
    final failures = <DesktopBackupFailure>[];
    var skippedSymlinks = 0;
    var skippedIgnored = 0;
    var skippedOversized = 0;

    Future<void> walkDirectory(Directory current, String relPrefix) async {
      checkActive();
      final List<FileSystemEntity> children;
      try {
        children = await current.list(followLinks: false).toList();
      } catch (error) {
        failures.add(
          DesktopBackupFailure(
            relativePath: relPrefix.isEmpty ? '.' : relPrefix,
            reason: '目录无法读取：${userFacingError(error)}',
            failedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        return;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in children) {
        checkActive();
        final name = _basename(entity.path);
        final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
        final type = await FileSystemEntity.type(entity.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          if (!matcher.shouldSkipSegmentName(name)) skippedSymlinks++;
          continue;
        }
        final isDir = type == FileSystemEntityType.directory;
        if (matcher.shouldIgnore(relPath, isDirectory: isDir)) {
          skippedIgnored++;
          continue;
        }
        final nameIssue = validateFileName(name);
        if (nameIssue != null) {
          failures.add(
            DesktopBackupFailure(
              relativePath: relPath,
              reason: '文件名不符合 NAS 规范：$nameIssue',
              failedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          continue;
        }
        if (isDir) {
          await walkDirectory(Directory(entity.path), relPath);
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        if (onlyPaths != null && !onlyPaths.contains(relPath)) continue;
        final file = File(entity.path);
        final FileStat stat;
        try {
          stat = await file.stat();
        } catch (error) {
          failures.add(
            DesktopBackupFailure(
              relativePath: relPath,
              reason: '无法读取文件信息：${userFacingError(error)}',
              failedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          continue;
        }
        if (matcher.exceedsSizeLimit(stat.size)) {
          skippedOversized++;
          continue;
        }
        final targetRel = task.remoteBasePath == '.'
            ? relPath
            : '${task.remoteBasePath}/$relPath';
        final pathIssue = validateRelativePath(targetRel);
        if (pathIssue != null) {
          failures.add(
            DesktopBackupFailure(
              relativePath: relPath,
              reason: '目标相对路径无效：$pathIssue',
              failedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          continue;
        }
        files.add(
          BackupScannedFile(
            relativePath: relPath,
            parentRelativeDir: relPrefix,
            fileName: name,
            size: stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            localFile: file,
          ),
        );
      }
    }

    await walkDirectory(Directory(rootPath), '');
    return BackupScanResult(
      files: files,
      failures: failures,
      skippedSymlinks: skippedSymlinks,
      skippedIgnored: skippedIgnored,
      skippedOversized: skippedOversized,
    );
  }

  @override
  Future<({int size, int modifiedMs})?> statFile(
    BackupScannedFile item, {
    required void Function() checkActive,
  }) async {
    checkActive();
    final file = item.localFile;
    if (file == null) return null;
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final stat = await file.stat();
    return (size: stat.size, modifiedMs: stat.modified.millisecondsSinceEpoch);
  }

  @override
  Future<PhotoHashResult> hashFile(
    BackupScannedFile item, {
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  }) => item.localFile == null
      ? Future<PhotoHashResult>.error(const PhotoSourceChanged())
      : hashLocalBackupFile(item.localFile!, expectedSize, checkActive: checkActive);

  @override
  Stream<List<int>> readChunk(
    BackupScannedFile item, {
    required int offset,
    required int length,
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  }) => item.localFile == null
      ? Stream<List<int>>.error(const PhotoSourceChanged())
      : item.localFile!.openRead(offset, offset + length);

  @override
  Future<void> verifyUnchangedBeforeComplete(
    BackupScannedFile item, {
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  }) async {
    checkActive();
    final file = item.localFile;
    if (file == null) throw const PhotoSourceChanged();
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file || before.size != expectedSize) {
      throw const PhotoSourceChanged();
    }
  }

  static String _basename(String fsPath) {
    var normalized = fsPath;
    while (normalized.length > 1 &&
        (normalized.endsWith('/') || normalized.endsWith('\\'))) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final slash = max(normalized.lastIndexOf('/'), normalized.lastIndexOf('\\'));
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }
}

class DesktopDirectoryLease {
  const DesktopDirectoryLease({
    required this.resolvedPath,
    this.refreshedBookmarkBase64,
    this.source,
    required this.stop,
  });

  final String resolvedPath;
  final String? refreshedBookmarkBase64;
  final BackupFolderSource? source;
  final Future<void> Function() stop;
}

class DesktopPickedFolder {
  const DesktopPickedFolder({
    required this.path,
    this.bookmarkBase64,
    this.displayPath,
  });

  final String path;
  final String? bookmarkBase64;
  final String? displayPath;
}

abstract class DesktopDirectoryAccess {
  const DesktopDirectoryAccess();

  bool get supportsWatch => true;
  bool get supportsRestore => true;

  Future<DesktopPickedFolder?> pickDirectory();
  Future<DesktopDirectoryLease> startAccess(DesktopBackupTask task);
}

class PlatformDesktopDirectoryAccess extends DesktopDirectoryAccess {
  const PlatformDesktopDirectoryAccess({
    AndroidFolderBackupAccess? androidAccess,
  }) : _androidAccess = androidAccess ?? const AndroidFolderBackupAccess();

  static const MethodChannel _channel = MethodChannel(
    'lightisle/desktop-folders',
  );

  final AndroidFolderBackupAccess _androidAccess;

  @override
  bool get supportsWatch => defaultTargetPlatform != TargetPlatform.android;

  @override
  bool get supportsRestore => defaultTargetPlatform != TargetPlatform.android;

  @override
  Future<DesktopPickedFolder?> pickDirectory() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _androidAccess.pickDirectory();
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final result = await _channel.invokeMapMethod<String, dynamic>('pickDirectory');
      final path = result?['path']?.toString() ?? '';
      if (path.isEmpty) return null;
      final bookmark = result?['bookmark']?.toString();
      return DesktopPickedFolder(
        path: path,
        bookmarkBase64: bookmark != null && bookmark.isNotEmpty ? bookmark : null,
      );
    }
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要单向备份到 NAS 的本机文件夹',
    );
    if (selected == null || selected.trim().isEmpty) return null;
    return DesktopPickedFolder(path: selected.trim());
  }

  @override
  Future<DesktopDirectoryLease> startAccess(DesktopBackupTask task) async {
    if (defaultTargetPlatform == TargetPlatform.android || task.isAndroidSafSource) {
      return _androidAccess.startAccess(task);
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'startAccess',
        <String, Object?>{'bookmark': task.bookmarkBase64 ?? '', 'path': task.localPath},
      );
      final path = result?['path']?.toString() ?? '';
      if (path.isEmpty) throw StateError('无法恢复本机文件夹授权，请编辑任务重新选择文件夹。');
      final accessId = result?['accessId']?.toString() ?? '';
      String? refreshed = result?['refreshedBookmark']?.toString();
      if ((refreshed == null || refreshed.isEmpty) && result?['stale'] == true) {
        refreshed = result?['bookmark']?.toString();
      }
      return DesktopDirectoryLease(
        resolvedPath: path,
        refreshedBookmarkBase64: refreshed != null && refreshed.isNotEmpty ? refreshed : null,
        stop: () async {
          if (accessId.isEmpty) return;
          try {
            await _channel.invokeMethod<bool>('stopAccess', <String, Object?>{'accessId': accessId});
          } catch (error) {
            debugPrint('PlatformDesktopDirectoryAccess.stopAccess failed: $error');
          }
        },
      );
    }
    if (!await Directory(task.localPath).exists()) {
      throw StateError('本机源文件夹不存在或无权读取：${task.localPath}');
    }
    return DesktopDirectoryLease(resolvedPath: task.localPath, stop: () async {});
  }
}

class DesktopBackupProgress {
  const DesktopBackupProgress({
    required this.taskId,
    required this.phase,
    required this.completedFiles,
    required this.totalFiles,
    this.currentFile = '',
  });

  final String taskId;
  final String phase;
  final int completedFiles;
  final int totalFiles;
  final String currentFile;
}

class DesktopBackupRunSummary {
  const DesktopBackupRunSummary({
    required this.uploadedNew,
    required this.updatedReplaced,
    required this.skippedUnchanged,
    required this.skippedSymlinks,
    this.skippedIgnored = 0,
    this.skippedOversized = 0,
    required this.failedCount,
    required this.cancelled,
  });

  final int uploadedNew;
  final int updatedReplaced;
  final int skippedUnchanged;
  final int skippedSymlinks;
  final int skippedIgnored;
  final int skippedOversized;
  final int failedCount;
  final bool cancelled;

  String formatLabel() {
    if (cancelled) {
      return '已暂停 · 本轮新增 $uploadedNew、更新 $updatedReplaced、快检跳过 $skippedUnchanged';
    }
    final parts = <String>[
      '新增 $uploadedNew',
      if (updatedReplaced > 0) '更新 $updatedReplaced',
      '未变跳过 $skippedUnchanged',
      if (skippedIgnored > 0) '规则过滤 $skippedIgnored',
      if (skippedOversized > 0) '超体积跳过 $skippedOversized',
      if (skippedSymlinks > 0) '跳过符号链接 $skippedSymlinks',
      if (failedCount > 0) '失败 $failedCount',
    ];
    return parts.join(' · ');
  }
}

class _CancelledDesktopBackup implements Exception {
  const _CancelledDesktopBackup();
}

enum _FileSyncOutcome { uploadedNew, updated, skipped }

/// Controller & engine for Desktop & Android local-folder one-way incremental
/// backup. Lives either at page scope or shell scope so an in-app schedule and
/// debounced filesystem watcher can trigger silent incremental checks when no
/// manual run is active.
class DesktopBackupController extends ChangeNotifier {
  DesktopBackupController({
    required this.api,
    required this.userId,
    required this.accountName,
    DesktopDirectoryAccess? directoryAccess,
    this.watcherDebounceDuration = DesktopBackupWatcher.defaultDebounceDuration,
    this.watchStreamFactory,
  }) : _directoryAccess =
           directoryAccess ?? const PlatformDesktopDirectoryAccess(),
       store = DesktopBackupStore(
         serverOrigin: api.uri('/').origin,
         userId: userId,
         accountName: accountName,
       );

  final LightIsleApi api;
  final int userId;
  final String accountName;
  final DesktopDirectoryAccess _directoryAccess;
  final Duration watcherDebounceDuration;
  final WatchDirectoryStreamFactory? watchStreamFactory;
  final DesktopBackupStore store;

  List<DesktopBackupTask> _tasks = const <DesktopBackupTask>[];
  DesktopBackupSchedule _schedule = DesktopBackupSchedule.off;
  DesktopBackupProgress? _activeProgress;
  bool _running = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  bool _watchersEnabled = false;
  Timer? _scheduleTimer;
  DesktopBackupWatcher? _watcher;

  List<DesktopBackupTask> get tasks => _tasks;
  String? get loadError => store.lastLoadError;
  DesktopBackupSchedule get schedule => _schedule;
  DesktopBackupProgress? get activeProgress => _activeProgress;
  bool get running => _running;
  DesktopDirectoryAccess get directoryAccess => _directoryAccess;

  bool isWatchingTask(String taskId) => _watcher?.isWatching(taskId) ?? false;
  String? watcherErrorFor(String taskId) => _watcher?.errorFor(taskId);

  Future<void> initialize({
    bool enableTimer = false,
    bool? enableWatchers,
  }) async {
    final loadedTasks = await store.loadTasks();
    final loadedSchedule = await store.loadSchedule();
    if (_disposed) return;
    _tasks = loadedTasks;
    _schedule = loadedSchedule;
    if (enableTimer) _rearmTimer();
    _watchersEnabled = enableWatchers ?? enableTimer;
    if (_watchersEnabled) {
      await _ensureWatcher().syncTasks(_tasks);
    }
    notifyListeners();
  }

  Future<void> reloadFromStore({bool updateTimer = false}) async {
    final loadedTasks = await store.loadTasks();
    final loadedSchedule = await store.loadSchedule();
    if (_disposed) return;
    _tasks = loadedTasks;
    _schedule = loadedSchedule;
    if (updateTimer) _rearmTimer();
    if (_watchersEnabled) {
      await _ensureWatcher().syncTasks(_tasks);
    }
    notifyListeners();
  }

  DesktopBackupWatcher _ensureWatcher() {
    return _watcher ??= DesktopBackupWatcher(
      directoryAccess: _directoryAccess,
      debounceDuration: watcherDebounceDuration,
      watchStreamFactory: watchStreamFactory,
      onTriggerBackup: _handleWatcherTriggeredBackup,
      onStateChanged: () {
        if (!_disposed) notifyListeners();
      },
    );
  }

  Future<void> _handleWatcherTriggeredBackup(String taskId) async {
    if (_disposed) return;
    if (_running) {
      _watcher?.deferWhileBusy(taskId);
      return;
    }
    await runTask(taskId);
  }

  void _rearmTimer() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    final interval = _schedule.interval;
    if (interval == null || _disposed) return;
    _scheduleTimer = Timer.periodic(interval, (_) {
      if (!_running && !_disposed) {
        unawaited(runAllEnabled());
      }
    });
  }

  Future<void> setSchedule(
    DesktopBackupSchedule next, {
    bool armTimer = false,
  }) async {
    await store.saveSchedule(next);
    if (_disposed) return;
    _schedule = next;
    if (armTimer) _rearmTimer();
    notifyListeners();
  }

  Future<void> upsertTask(DesktopBackupTask task) async {
    final current = List<DesktopBackupTask>.of(_tasks);
    final idx = current.indexWhere((t) => t.id == task.id);
    if (idx >= 0) {
      current[idx] = task;
    } else {
      current.add(task);
    }
    await store.saveTasks(current);
    if (_disposed) return;
    _tasks = List<DesktopBackupTask>.unmodifiable(current);
    if (_watchersEnabled) {
      await _ensureWatcher().syncTasks(_tasks);
    }
    notifyListeners();
  }

  Future<void> deleteTask(String taskId) async {
    if (_running && _activeProgress?.taskId == taskId) {
      throw StateError('该任务正在运行，请先暂停后再移除。');
    }
    await _watcher?.releaseTask(taskId);
    final next = _tasks.where((t) => t.id != taskId).toList(growable: false);
    await store.saveTasks(next);
    await store.removeTaskData(taskId);
    if (_disposed) return;
    _tasks = next;
    notifyListeners();
  }

  void requestCancel() {
    if (!_running) return;
    _cancelRequested = true;
    notifyListeners();
  }

  Future<void> runAllEnabled() async {
    if (_running || _disposed) return;
    final current = await store.loadTasks();
    if (_disposed) return;
    _tasks = current;
    for (final task in current) {
      if (_disposed || _cancelRequested) break;
      if (!task.enabled) continue;
      await runTask(task.id);
      if (_cancelRequested) break;
    }
    _cancelRequested = false;
  }

  Future<DesktopBackupRunSummary?> runTask(
    String taskId, {
    bool retryFailuresOnly = false,
  }) async {
    if (_running || _disposed) return null;
    final latestTasks = await store.loadTasks();
    if (_disposed) return null;
    _tasks = latestTasks;
    final taskIndex = _tasks.indexWhere((t) => t.id == taskId);
    if (taskIndex < 0) return null;
    var task = _tasks[taskIndex];

    Set<String>? onlyPaths;
    if (retryFailuresOnly) {
      final (existingFailures, _) = await store.loadFailures(task.id);
      if (existingFailures.isEmpty) return null;
      onlyPaths = existingFailures.map((f) => f.relativePath).toSet();
    }

    _running = true;
    _cancelRequested = false;
    _setProgress(
      DesktopBackupProgress(
        taskId: task.id,
        phase: '正在核验 NAS 目标硬盘与本地授权…',
        completedFiles: 0,
        totalFiles: 0,
      ),
    );

    DesktopDirectoryLease? lease;
    LightIsleApi? isolatedClient;
    final prevRoot = api.selectedRoot;
    var mutatedSharedRoot = false;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    String? releaseWatcherReason;

    try {
      final verifiedRoot = await _verifyTargetRoot(task);
      _checkActive();

      lease = await _directoryAccess.startAccess(task);
      _checkActive();
      if (lease.refreshedBookmarkBase64 != null) {
        task = task.copyWith(bookmarkBase64: lease.refreshedBookmarkBase64);
        await _persistTaskUpdate(task);
      }

      final snapshot = api.sessionSnapshot;
      final LightIsleApi client;
      if (snapshot != null) {
        isolatedClient = LightIsleApi.fromSessionSnapshot(snapshot)
          ..selectRoot(verifiedRoot);
        client = isolatedClient;
      } else {
        api.selectRoot(verifiedRoot);
        mutatedSharedRoot = true;
        client = api;
      }

      final source =
          lease.source ?? LocalFilesystemFolderSource(lease.resolvedPath);
      final (summary, quotaError) = await _executeSync(
        client: client,
        task: task,
        source: source,
        onlyPaths: onlyPaths,
        startedAtMs: startedAt,
      );
      if (quotaError != null) {
        releaseWatcherReason = quotaError;
      }
      return summary;
    } on _CancelledDesktopBackup {
      final updated = task.copyWith(
        lastRunAtMs: startedAt,
        lastSummary: '已手动暂停备份，下次运行将继续增量核验',
        clearError: true,
      );
      await _persistTaskUpdate(updated);
      return const DesktopBackupRunSummary(
        uploadedNew: 0,
        updatedReplaced: 0,
        skippedUnchanged: 0,
        skippedSymlinks: 0,
        failedCount: 0,
        cancelled: true,
      );
    } catch (error) {
      final message = userFacingError(error);
      releaseWatcherReason = message;
      final updated = task.copyWith(lastRunAtMs: startedAt, lastError: message);
      await _persistTaskUpdate(updated);
      return null;
    } finally {
      await lease?.stop();
      isolatedClient?.close();
      if (mutatedSharedRoot && !_disposed) {
        api.selectRoot(prevRoot);
      }
      _running = false;
      _cancelRequested = false;
      _activeProgress = null;
      if (releaseWatcherReason != null && !_disposed) {
        await _watcher?.releaseTask(
          task.id,
          reason: '变更监听已自动暂停：$releaseWatcherReason',
        );
      }
      if (!_disposed) {
        notifyListeners();
        final deferred = _watcher?.takeNextDeferredTaskId();
        if (deferred != null) {
          unawaited(runTask(deferred));
        }
      }
    }
  }

  Future<void> _persistTaskUpdate(DesktopBackupTask updated) async {
    final current = List<DesktopBackupTask>.of(_tasks);
    final index = current.indexWhere((t) => t.id == updated.id);
    if (index >= 0) {
      current[index] = updated;
      await store.saveTasks(current);
      if (!_disposed) {
        _tasks = List<DesktopBackupTask>.unmodifiable(current);
        notifyListeners();
      }
    }
  }

  void _setProgress(DesktopBackupProgress progress) {
    _activeProgress = progress;
    if (!_disposed) notifyListeners();
  }

  void _checkActive() {
    if (_cancelRequested || _disposed) {
      throw const _CancelledDesktopBackup();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRequested = true;
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    final watcher = _watcher;
    _watcher = null;
    if (watcher != null) {
      unawaited(watcher.dispose());
    }
    super.dispose();
  }
}
