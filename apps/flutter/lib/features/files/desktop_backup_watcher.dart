import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/user_facing_error.dart';
import 'desktop_backup_engine.dart';
import 'desktop_backup_ignore.dart';
import 'desktop_backup_models.dart';

/// Lightweight filesystem change event decoupled from sealed `FileSystemEvent`
/// so watchers can be unit-tested deterministically.
class DesktopWatchEvent {
  const DesktopWatchEvent({required this.path, this.isDirectory = false});

  final String path;
  final bool isDirectory;
}

typedef WatchDirectoryStreamFactory =
    Stream<DesktopWatchEvent> Function(String directoryPath);

/// Manages recursive filesystem watchers with 30-second debounce coalescing for
/// desktop backup tasks that enable [DesktopBackupTask.watchOnChange].
///
/// Only runs while the desktop client is open; safely releases leases and
/// subscriptions on permission loss, directory removal, root offline, or
/// storage exhaustion.
class DesktopBackupWatcher {
  DesktopBackupWatcher({
    required this.directoryAccess,
    required this.onTriggerBackup,
    this.onStateChanged,
    this.debounceDuration = defaultDebounceDuration,
    WatchDirectoryStreamFactory? watchStreamFactory,
  }) : _watchStreamFactory = watchStreamFactory ?? _defaultWatchStream;

  static const Duration defaultDebounceDuration = Duration(seconds: 30);

  static Stream<DesktopWatchEvent> _defaultWatchStream(String path) =>
      Directory(path)
          .watch(recursive: true)
          .map((e) => DesktopWatchEvent(path: e.path, isDirectory: e.isDirectory));

  final DesktopDirectoryAccess directoryAccess;
  final Future<void> Function(String taskId) onTriggerBackup;
  final VoidCallback? onStateChanged;
  final Duration debounceDuration;
  final WatchDirectoryStreamFactory _watchStreamFactory;

  final Map<String, _TaskWatcherHandle> _handles =
      <String, _TaskWatcherHandle>{};
  final Map<String, String> _watcherErrors = <String, String>{};
  final Set<String> _pendingWhileBusy = <String>{};
  bool _disposed = false;

  Set<String> get activeTaskIds => Set<String>.unmodifiable(_handles.keys);
  Map<String, String> get errors => Map<String, String>.unmodifiable(
    _watcherErrors,
  );

  bool isWatching(String taskId) => _handles.containsKey(taskId);
  String? errorFor(String taskId) => _watcherErrors[taskId];

  Future<void> syncTasks(List<DesktopBackupTask> tasks) async {
    if (_disposed || !directoryAccess.supportsWatch) {
      await stopAll();
      return;
    }
    final desired = <String, DesktopBackupTask>{
      for (final task in tasks)
        if (task.enabled && task.watchOnChange && !task.isAndroidSafSource)
          task.id: task,
    };

    var changed = false;
    for (final id in _handles.keys
        .where((id) => !desired.containsKey(id))
        .toList(growable: false)) {
      await _disposeHandle(id);
      _watcherErrors.remove(id);
      _pendingWhileBusy.remove(id);
      changed = true;
    }
    _watcherErrors.removeWhere((id, _) => !desired.containsKey(id));

    for (final task in desired.values) {
      if (_disposed) break;
      final existing = _handles[task.id];
      final signature = _taskWatchSignature(task);
      if (existing != null && existing.signature == signature) continue;
      if (existing != null) {
        await _disposeHandle(task.id);
        changed = true;
      }
      await _startTaskWatcher(task, signature);
      changed = true;
    }
    if (changed && !_disposed) onStateChanged?.call();
  }

  Future<void> releaseTask(String taskId, {String? reason}) async {
    final hadHandle = _handles.containsKey(taskId);
    final prevError = _watcherErrors[taskId];
    await _disposeHandle(taskId);
    _pendingWhileBusy.remove(taskId);
    if (reason != null && reason.trim().isNotEmpty) {
      _watcherErrors[taskId] = reason.trim();
    } else {
      _watcherErrors.remove(taskId);
    }
    if ((hadHandle || prevError != _watcherErrors[taskId]) && !_disposed) {
      onStateChanged?.call();
    }
  }

  void deferWhileBusy(String taskId) {
    if (_disposed || !_handles.containsKey(taskId)) return;
    _pendingWhileBusy.add(taskId);
  }

  String? takeNextDeferredTaskId() {
    if (_disposed || _pendingWhileBusy.isEmpty) return null;
    final next = _pendingWhileBusy.first;
    _pendingWhileBusy.remove(next);
    return _handles.containsKey(next) ? next : takeNextDeferredTaskId();
  }

  Future<void> stopAll() async {
    for (final id in _handles.keys.toList(growable: false)) {
      await _disposeHandle(id);
    }
    _pendingWhileBusy.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopAll();
    _watcherErrors.clear();
  }

  Future<void> _startTaskWatcher(
    DesktopBackupTask task,
    String signature,
  ) async {
    DesktopDirectoryLease? lease;
    try {
      lease = await directoryAccess.startAccess(task);
      if (_disposed) {
        await lease.stop();
        return;
      }
      final rootPath = lease.resolvedPath;
      String? canonicalRoot;
      try {
        canonicalRoot = Directory(rootPath).resolveSymbolicLinksSync();
      } catch (_) {
        canonicalRoot = null;
      }
      final handle = _TaskWatcherHandle(
        taskId: task.id,
        signature: signature,
        rootPrefixes: _buildRootPrefixes(rootPath, canonicalRoot),
        matcher: DesktopBackupIgnoreMatcher.fromTask(task),
        lease: lease,
      );
      handle.attach(
        _watchStreamFactory(rootPath).listen(
          (event) => _handleEvent(handle, event),
          onError: (Object error) {
            unawaited(
              releaseTask(
                task.id,
                reason: '变更监听已自动暂停（目录权限或路径不可访问）：${userFacingError(error)}',
              ),
            );
          },
          onDone: () {
            if (!_disposed && identical(_handles[task.id], handle)) {
              unawaited(
                releaseTask(
                  task.id,
                  reason: '本地目录监听已结束，请检查目录是否被移除或重新保存任务。',
                ),
              );
            }
          },
          cancelOnError: true,
        ),
      );
      _handles[task.id] = handle;
      _watcherErrors.remove(task.id);
    } catch (error) {
      if (lease != null) {
        try {
          await lease.stop();
        } catch (_) {}
      }
      _watcherErrors[task.id] = '变更监听未能启动：${userFacingError(error)}';
    }
  }

  void _handleEvent(_TaskWatcherHandle handle, DesktopWatchEvent event) {
    if (_disposed || !identical(_handles[handle.taskId], handle)) return;
    final relPath = _extractRelativePath(event.path, handle.rootPrefixes);
    if (relPath != null &&
        relPath.isNotEmpty &&
        handle.matcher.shouldIgnore(relPath, isDirectory: event.isDirectory)) {
      return;
    }
    handle.debounceTimer?.cancel();
    handle.debounceTimer = Timer(debounceDuration, () {
      if (_disposed || !identical(_handles[handle.taskId], handle)) return;
      handle.debounceTimer = null;
      unawaited(onTriggerBackup(handle.taskId));
    });
  }

  Future<void> _disposeHandle(String taskId) async {
    final handle = _handles.remove(taskId);
    if (handle == null) return;
    await handle.close();
  }

  static String _taskWatchSignature(DesktopBackupTask task) => [
    task.localPath,
    task.bookmarkBase64 ?? '',
    task.ignoreHidden ? '1' : '0',
    task.ignorePresets.join(','),
    task.customIgnorePatterns.join('\n'),
    '${task.maxFileSizeMiB}',
  ].join('\u0000');

  static List<String> _buildRootPrefixes(
    String resolvedPath,
    String? canonicalPath,
  ) {
    String norm(String raw) {
      var p = raw.replaceAll('\\', '/');
      while (p.length > 1 && p.endsWith('/')) {
        p = p.substring(0, p.length - 1);
      }
      return p;
    }

    final prefixes = <String>[norm(resolvedPath)];
    if (canonicalPath != null && canonicalPath.isNotEmpty) {
      final canon = norm(canonicalPath);
      if (!prefixes.contains(canon)) prefixes.add(canon);
    }
    return prefixes;
  }

  static String? _extractRelativePath(
    String eventPath,
    List<String> rootPrefixes,
  ) {
    final normalized = eventPath.replaceAll('\\', '/');
    for (final prefix in rootPrefixes) {
      if (normalized == prefix) return '';
      if (normalized.startsWith('$prefix/')) {
        return normalized.substring(prefix.length + 1);
      }
    }
    return null;
  }
}

class _TaskWatcherHandle {
  _TaskWatcherHandle({
    required this.taskId,
    required this.signature,
    required this.rootPrefixes,
    required this.matcher,
    required this.lease,
  });

  final String taskId;
  final String signature;
  final List<String> rootPrefixes;
  final DesktopBackupIgnoreMatcher matcher;
  final DesktopDirectoryLease lease;
  StreamSubscription<DesktopWatchEvent>? _subscription;
  Timer? debounceTimer;

  void attach(StreamSubscription<DesktopWatchEvent> sub) {
    _subscription = sub;
  }

  Future<void> close() async {
    debounceTimer?.cancel();
    debounceTimer = null;
    final sub = _subscription;
    _subscription = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (error) {
        debugPrint('DesktopBackupWatcher cancel failed for $taskId: $error');
      }
    }
    try {
      await lease.stop();
    } catch (error) {
      debugPrint('DesktopBackupWatcher lease stop failed for $taskId: $error');
    }
  }
}
