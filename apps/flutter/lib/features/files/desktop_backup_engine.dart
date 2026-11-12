import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'desktop_backup_models.dart';
import 'file_name_validation.dart';
import 'photo_backup_hash.dart';

part 'desktop_backup_sync.dart';

class DesktopDirectoryLease {
  const DesktopDirectoryLease({
    required this.resolvedPath,
    this.refreshedBookmarkBase64,
    required this.stop,
  });

  final String resolvedPath;
  final String? refreshedBookmarkBase64;
  final Future<void> Function() stop;
}

class DesktopPickedFolder {
  const DesktopPickedFolder({required this.path, this.bookmarkBase64});

  final String path;
  final String? bookmarkBase64;
}

abstract class DesktopDirectoryAccess {
  const DesktopDirectoryAccess();

  Future<DesktopPickedFolder?> pickDirectory();
  Future<DesktopDirectoryLease> startAccess(DesktopBackupTask task);
}

class PlatformDesktopDirectoryAccess extends DesktopDirectoryAccess {
  const PlatformDesktopDirectoryAccess();

  static const MethodChannel _channel = MethodChannel(
    'lightisle/desktop-folders',
  );

  @override
  Future<DesktopPickedFolder?> pickDirectory() async {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'pickDirectory',
      );
      if (result == null) return null;
      final path = result['path']?.toString() ?? '';
      if (path.isEmpty) return null;
      final bookmark = result['bookmark']?.toString();
      return DesktopPickedFolder(
        path: path,
        bookmarkBase64: bookmark != null && bookmark.isNotEmpty
            ? bookmark
            : null,
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
    final bookmark = task.bookmarkBase64;
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'startAccess',
        <String, Object?>{'bookmark': bookmark ?? '', 'path': task.localPath},
      );
      final path = result?['path']?.toString() ?? '';
      if (path.isEmpty) {
        throw StateError('无法恢复本机文件夹授权，请编辑任务重新选择文件夹。');
      }
      final accessId = result?['accessId']?.toString() ?? '';
      String? refreshed = result?['refreshedBookmark']?.toString();
      if ((refreshed == null || refreshed.isEmpty) &&
          result?['stale'] == true) {
        refreshed = result?['bookmark']?.toString();
      }
      return DesktopDirectoryLease(
        resolvedPath: path,
        refreshedBookmarkBase64: refreshed != null && refreshed.isNotEmpty
            ? refreshed
            : null,
        stop: () async {
          if (accessId.isEmpty) return;
          try {
            await _channel.invokeMethod<bool>('stopAccess', <String, Object?>{
              'accessId': accessId,
            });
          } catch (error) {
            debugPrint('PlatformDesktopDirectoryAccess.stopAccess failed: $error');
          }
        },
      );
    }
    final dir = Directory(task.localPath);
    if (!await dir.exists()) {
      throw StateError('本机源文件夹不存在或无权读取：${task.localPath}');
    }
    return DesktopDirectoryLease(
      resolvedPath: task.localPath,
      stop: () async {},
    );
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
    required this.failedCount,
    required this.cancelled,
  });

  final int uploadedNew;
  final int updatedReplaced;
  final int skippedUnchanged;
  final int skippedSymlinks;
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
      if (skippedSymlinks > 0) '跳过符号链接 $skippedSymlinks',
      if (failedCount > 0) '失败 $failedCount',
    ];
    return parts.join(' · ');
  }
}

class _CancelledDesktopBackup implements Exception {
  const _CancelledDesktopBackup();
}

class _LocalScanItem {
  const _LocalScanItem({
    required this.file,
    required this.relativePath,
    required this.parentRelativeDir,
    required this.fileName,
  });

  final File file;
  final String relativePath;
  final String parentRelativeDir;
  final String fileName;
}

enum _FileSyncOutcome { uploadedNew, updated, skipped }

/// Controller & engine for desktop local-folder one-way incremental backup.
/// Lives either at page scope or shell scope so an in-app schedule can trigger
/// silent incremental checks when no manual run is active.
class DesktopBackupController extends ChangeNotifier {
  DesktopBackupController({
    required this.api,
    required this.userId,
    required this.accountName,
    DesktopDirectoryAccess? directoryAccess,
  }) : _directoryAccess =
           directoryAccess ?? const PlatformDesktopDirectoryAccess(),
       store = DesktopBackupStore(
         serverOrigin: api.uri('/').origin,
         userId: userId,
         accountName: accountName,
       );

  static const Set<String> _ignoredJunkNames = <String>{
    '.DS_Store',
    'Thumbs.db',
    'desktop.ini',
    '.Spotlight-V100',
    '.Trashes',
    '.fseventsd',
    '.TemporaryItems',
    'Icon\r',
  };

  final LightIsleApi api;
  final int userId;
  final String accountName;
  final DesktopDirectoryAccess _directoryAccess;
  final DesktopBackupStore store;

  List<DesktopBackupTask> _tasks = const <DesktopBackupTask>[];
  DesktopBackupSchedule _schedule = DesktopBackupSchedule.off;
  DesktopBackupProgress? _activeProgress;
  bool _running = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  Timer? _scheduleTimer;

  List<DesktopBackupTask> get tasks => _tasks;
  DesktopBackupSchedule get schedule => _schedule;
  DesktopBackupProgress? get activeProgress => _activeProgress;
  bool get running => _running;
  DesktopDirectoryAccess get directoryAccess => _directoryAccess;

  Future<void> initialize({bool enableTimer = false}) async {
    final loadedTasks = await store.loadTasks();
    final loadedSchedule = await store.loadSchedule();
    if (_disposed) return;
    _tasks = loadedTasks;
    _schedule = loadedSchedule;
    if (enableTimer) _rearmTimer();
    notifyListeners();
  }

  Future<void> reloadFromStore({bool updateTimer = false}) async {
    final loadedTasks = await store.loadTasks();
    final loadedSchedule = await store.loadSchedule();
    if (_disposed) return;
    _tasks = loadedTasks;
    _schedule = loadedSchedule;
    if (updateTimer) _rearmTimer();
    notifyListeners();
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
    notifyListeners();
  }

  Future<void> deleteTask(String taskId) async {
    if (_running && _activeProgress?.taskId == taskId) {
      throw StateError('该任务正在运行，请先暂停后再移除。');
    }
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

      return await _executeSync(
        client: client,
        task: task,
        localRootPath: lease.resolvedPath,
        onlyPaths: onlyPaths,
        startedAtMs: startedAt,
      );
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
      if (!_disposed) notifyListeners();
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
    super.dispose();
  }
}
