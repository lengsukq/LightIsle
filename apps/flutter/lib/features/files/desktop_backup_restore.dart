import 'dart:async';
import 'dart:io';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'desktop_backup_engine.dart';
import 'desktop_backup_ignore.dart';
import 'desktop_backup_models.dart';
import 'file_name_validation.dart';
import 'photo_backup_hash.dart';

export 'desktop_backup_restore_dialog.dart';

const int _maxDirectRestoreSha256Bytes = 2 << 30;

enum DesktopRestoreConflictStrategy {
  missingOnly,
  backupAndOverwrite;

  String get title => switch (this) {
    DesktopRestoreConflictStrategy.missingOnly => '仅下载本地缺失文件（推荐）',
    DesktopRestoreConflictStrategy.backupAndOverwrite =>
      '覆盖前本地先保留 .lightisle-bak 备份',
  };

  String get subtitle => switch (this) {
    DesktopRestoreConflictStrategy.missingOnly => '跳过所有本地已存在文件，绝不改动本机现有内容',
    DesktopRestoreConflictStrategy.backupAndOverwrite =>
      '差异文件先重命名为 <文件名>.lightisle-bak 再写入新版，绝不删除本地多余文件',
  };
}

enum DesktopRestoreItemStatus {
  missingLocally,
  conflictDifferent,
  identicalLocally,
  skippedNonFile,
}

class DesktopRestoreEntry {
  const DesktopRestoreEntry({
    required this.relativePath,
    required this.remotePath,
    required this.remoteSize,
    required this.status,
    this.localSize,
  });

  final String relativePath;
  final String remotePath;
  final int remoteSize;
  final DesktopRestoreItemStatus status;
  final int? localSize;
}

class DesktopRestorePlan {
  const DesktopRestorePlan({
    required this.task,
    required this.resolvedLocalRoot,
    required this.entries,
    required this.localOnlyCount,
  });

  final DesktopBackupTask task;
  final String resolvedLocalRoot;
  final List<DesktopRestoreEntry> entries;
  final int localOnlyCount;

  List<DesktopRestoreEntry> get missingItems => entries
      .where((e) => e.status == DesktopRestoreItemStatus.missingLocally)
      .toList(growable: false);
  List<DesktopRestoreEntry> get conflictItems => entries
      .where((e) => e.status == DesktopRestoreItemStatus.conflictDifferent)
      .toList(growable: false);
  List<DesktopRestoreEntry> get identicalItems => entries
      .where((e) => e.status == DesktopRestoreItemStatus.identicalLocally)
      .toList(growable: false);

  List<DesktopRestoreEntry> actionableFor(
    DesktopRestoreConflictStrategy strategy,
  ) => switch (strategy) {
    DesktopRestoreConflictStrategy.missingOnly => missingItems,
    DesktopRestoreConflictStrategy.backupAndOverwrite => [
      ...missingItems,
      ...conflictItems,
    ],
  };

  int totalBytesFor(DesktopRestoreConflictStrategy strategy) => actionableFor(
    strategy,
  ).fold(0, (sum, item) => sum + item.remoteSize);
}

class DesktopRestoreProgress {
  const DesktopRestoreProgress({
    required this.phase,
    required this.completedFiles,
    required this.totalFiles,
    this.currentFile = '',
  });

  final String phase;
  final int completedFiles;
  final int totalFiles;
  final String currentFile;
}

class DesktopRestoreResult {
  const DesktopRestoreResult({
    required this.downloaded,
    required this.backedUpAndReplaced,
    required this.skippedExisting,
    required this.verifiedSha256Count,
    required this.failures,
    required this.cancelled,
  });

  final int downloaded;
  final int backedUpAndReplaced;
  final int skippedExisting;
  final int verifiedSha256Count;
  final List<DesktopBackupFailure> failures;
  final bool cancelled;

  String formatSummary() => [
    if (cancelled) '已取消',
    '下载 $downloaded',
    if (backedUpAndReplaced > 0) '备份后更新 $backedUpAndReplaced',
    if (skippedExisting > 0) '跳过已有 $skippedExisting',
    if (verifiedSha256Count > 0) 'SHA-256 核验 $verifiedSha256Count',
    if (failures.isNotEmpty) '失败 ${failures.length}',
  ].join(' · ');
}

class DesktopRestoreCancelled implements Exception {
  const DesktopRestoreCancelled();
}

enum _RestoreOutcome { downloaded, backedUpAndReplaced, skipped }

/// Manual one-way restore from NAS target folder back to the local desktop
/// directory. Never deletes any extra local files.
class DesktopBackupRestoreService {
  DesktopBackupRestoreService({
    required this.api,
    required this.directoryAccess,
    this.store,
  });

  static const int _maxDepth = 64;
  static const int _maxRemoteEntries = 50000;
  static int _tempCounter = 0;

  final LightIsleApi api;
  final DesktopDirectoryAccess directoryAccess;
  final DesktopBackupStore? store;

  Future<DesktopRestorePlan> buildPlan(
    DesktopBackupTask task, {
    void Function(DesktopRestoreProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (task.isAndroidSafSource || !directoryAccess.supportsRestore) {
      throw StateError('当前平台不支持直接还原到本机目录。');
    }
    void checkActive() {
      if (isCancelled?.call() == true) throw const DesktopRestoreCancelled();
    }

    onProgress?.call(
      const DesktopRestoreProgress(phase: '正在核验 NAS 目标硬盘与本地授权…', completedFiles: 0, totalFiles: 0),
    );
    final verifiedRoot = await _verifyTargetRoot(task);
    checkActive();

    return _withSession(task, verifiedRoot, (client, localRoot) async {
      onProgress?.call(
        const DesktopRestoreProgress(phase: '正在扫描 NAS 备份目录…', completedFiles: 0, totalFiles: 0),
      );
      final remoteFiles = <({String relPath, String remotePath, int size})>[];
      await _walkRemoteTree(client, task.remoteBasePath, '', 0, remoteFiles, checkActive);
      final cachedIndex = store != null
          ? await store!.loadFileIndex(task.id)
          : const <String, DesktopBackupFileRecord>{};

      final entries = <DesktopRestoreEntry>[];
      final remoteRelSet = <String>{};
      for (var i = 0; i < remoteFiles.length; i++) {
        checkActive();
        final rf = remoteFiles[i];
        remoteRelSet.add(rf.relPath);
        onProgress?.call(
          DesktopRestoreProgress(
            phase: '正在对比本机文件 (${i + 1}/${remoteFiles.length})',
            completedFiles: i,
            totalFiles: remoteFiles.length,
            currentFile: rf.relPath,
          ),
        );
        entries.add(await _classifyEntry(client, localRoot, rf, cachedIndex, checkActive));
      }
      final localOnly = await _countLocalOnly(localRoot, remoteRelSet, checkActive);
      return DesktopRestorePlan(
        task: task,
        resolvedLocalRoot: localRoot,
        entries: List<DesktopRestoreEntry>.unmodifiable(entries),
        localOnlyCount: localOnly,
      );
    });
  }

  Future<DesktopRestoreEntry> _classifyEntry(
    LightIsleApi client,
    String localRoot,
    ({String relPath, String remotePath, int size}) rf,
    Map<String, DesktopBackupFileRecord> cachedIndex,
    void Function() checkActive,
  ) async {
    final localPath = _resolveLocalPath(localRoot, rf.relPath);
    final entityType = await FileSystemEntity.type(localPath, followLinks: false);
    if (entityType == FileSystemEntityType.notFound) {
      return DesktopRestoreEntry(
        relativePath: rf.relPath, remotePath: rf.remotePath, remoteSize: rf.size,
        status: DesktopRestoreItemStatus.missingLocally,
      );
    }
    if (entityType != FileSystemEntityType.file) {
      return DesktopRestoreEntry(
        relativePath: rf.relPath, remotePath: rf.remotePath, remoteSize: rf.size,
        status: DesktopRestoreItemStatus.skippedNonFile,
      );
    }
    final localFile = File(localPath);
    final stat = await localFile.stat();
    if (stat.size != rf.size) {
      return DesktopRestoreEntry(
        relativePath: rf.relPath, remotePath: rf.remotePath, remoteSize: rf.size,
        localSize: stat.size, status: DesktopRestoreItemStatus.conflictDifferent,
      );
    }
    final cached = cachedIndex[rf.relPath];
    final mtimeMs = stat.modified.millisecondsSinceEpoch;
    final bool isIdentical;
    if (cached != null &&
        stat.size <= _maxDirectRestoreSha256Bytes &&
        cached.size == stat.size &&
        cached.modifiedMs == mtimeMs &&
        cached.remoteName == null) {
      isIdentical = await client.remoteFileMatchesSHA256(
        rf.remotePath,
        rf.size,
        cached.sha256,
        checkActive: checkActive,
      );
    } else {
      final hash = await hashLocalBackupFile(
        localFile,
        stat.size,
        checkActive: checkActive,
      );
      isIdentical = await client.remoteFileMatchesSHA256(
        rf.remotePath,
        rf.size,
        hash.digest,
        chunkSHA256s: hash.chunkDigests,
        checkActive: checkActive,
      );
    }
    return DesktopRestoreEntry(
      relativePath: rf.relPath, remotePath: rf.remotePath, remoteSize: rf.size, localSize: stat.size,
      status: isIdentical ? DesktopRestoreItemStatus.identicalLocally : DesktopRestoreItemStatus.conflictDifferent,
    );
  }

  Future<DesktopRestoreResult> executeRestore(
    DesktopRestorePlan plan, {
    required DesktopRestoreConflictStrategy strategy,
    bool verifySha256 = true,
    void Function(DesktopRestoreProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    void checkActive() {
      if (isCancelled?.call() == true) throw const DesktopRestoreCancelled();
    }

    final targets = plan.actionableFor(strategy);
    var skippedExisting = strategy == DesktopRestoreConflictStrategy.missingOnly ? plan.conflictItems.length : 0;
    if (targets.isEmpty) {
      return DesktopRestoreResult(
        downloaded: 0, backedUpAndReplaced: 0, skippedExisting: skippedExisting,
        verifiedSha256Count: 0, failures: const <DesktopBackupFailure>[], cancelled: false,
      );
    }

    final verifiedRoot = await _verifyTargetRoot(plan.task);
    checkActive();
    var downloaded = 0;
    var backedUp = 0;
    var verifiedCount = 0;
    final failures = <DesktopBackupFailure>[];
    var cancelled = false;

    await _withSession(plan.task, verifiedRoot, (client, localRoot) async {
      for (var i = 0; i < targets.length; i++) {
        if (isCancelled?.call() == true) { cancelled = true; break; }
        final entry = targets[i];
        onProgress?.call(
          DesktopRestoreProgress(
            phase: '正在还原 (${i + 1}/${targets.length})',
            completedFiles: i, totalFiles: targets.length, currentFile: entry.relativePath,
          ),
        );
        final targetFile = File(_resolveLocalPath(localRoot, entry.relativePath));
        final tempFile = File('${targetFile.path}.lightisle-restore-$pid-${++_tempCounter}.part');
        try {
          final outcome = await _restoreSingleFile(
            client, entry, targetFile, tempFile, strategy, verifySha256, checkActive,
          );
          if (outcome.verified) verifiedCount++;
          switch (outcome.kind) {
            case _RestoreOutcome.downloaded:
              downloaded++;
            case _RestoreOutcome.backedUpAndReplaced:
              backedUp++;
            case _RestoreOutcome.skipped:
              skippedExisting++;
          }
        } on DesktopRestoreCancelled {
          cancelled = true;
          break;
        } catch (error) {
          failures.add(
            DesktopBackupFailure(
              relativePath: entry.relativePath,
              reason: userFacingError(error),
              failedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        } finally {
          try { if (await tempFile.exists()) await tempFile.delete(); } catch (_) {}
        }
      }
    });

    return DesktopRestoreResult(
      downloaded: downloaded, backedUpAndReplaced: backedUp, skippedExisting: skippedExisting,
      verifiedSha256Count: verifiedCount, failures: List<DesktopBackupFailure>.unmodifiable(failures), cancelled: cancelled,
    );
  }

  Future<({_RestoreOutcome kind, bool verified})> _restoreSingleFile(
    LightIsleApi client,
    DesktopRestoreEntry entry,
    File targetFile,
    File tempFile,
    DesktopRestoreConflictStrategy strategy,
    bool verifySha256,
    void Function() checkActive,
  ) async {
    final existingType = await FileSystemEntity.type(targetFile.path, followLinks: false);
    if (existingType != FileSystemEntityType.notFound && existingType != FileSystemEntityType.file) {
      throw StateError('本机目标位置是文件夹或符号链接，未覆盖。');
    }
    if (existingType == FileSystemEntityType.file && strategy == DesktopRestoreConflictStrategy.missingOnly) {
      return (kind: _RestoreOutcome.skipped, verified: false);
    }

    await targetFile.parent.create(recursive: true);
    await client.download('/api/v2/files/content', tempFile.path, query: <String, String>{'path': entry.remotePath});
    checkActive();

    var verified = false;
    if (verifySha256) {
      final stat = await tempFile.stat();
      final hash = await hashLocalBackupFile(tempFile, stat.size, checkActive: checkActive);
      final ok = await client.remoteFileMatchesSHA256(
        entry.remotePath, stat.size, hash.digest, chunkSHA256s: hash.chunkDigests, checkActive: checkActive,
      );
      if (!ok) throw StateError('下载文件 SHA-256 校验不一致，已放弃写入以保护本机文件。');
      verified = true;
    }

    if (await FileSystemEntity.type(targetFile.path, followLinks: false) == FileSystemEntityType.file) {
      if (strategy == DesktopRestoreConflictStrategy.missingOnly) {
        return (kind: _RestoreOutcome.skipped, verified: verified);
      }
      final bakPath = await _reserveBackupPath(targetFile.path);
      await targetFile.rename(bakPath);
      try {
        await tempFile.rename(targetFile.path);
      } catch (_) {
        try {
          if (!await targetFile.exists() && await File(bakPath).exists()) await File(bakPath).rename(targetFile.path);
        } catch (_) {}
        rethrow;
      }
      return (kind: _RestoreOutcome.backedUpAndReplaced, verified: verified);
    }
    await tempFile.rename(targetFile.path);
    return (kind: _RestoreOutcome.downloaded, verified: verified);
  }

  Future<T> _withSession<T>(
    DesktopBackupTask task,
    LightIsleRoot verifiedRoot,
    Future<T> Function(LightIsleApi client, String localRoot) body,
  ) async {
    final lease = await directoryAccess.startAccess(task);
    LightIsleApi? isolated;
    final prevRoot = api.selectedRoot;
    var mutatedShared = false;
    try {
      final snapshot = api.sessionSnapshot;
      final LightIsleApi client;
      if (snapshot != null) {
        isolated = LightIsleApi.fromSessionSnapshot(snapshot)..selectRoot(verifiedRoot);
        client = isolated;
      } else {
        api.selectRoot(verifiedRoot);
        mutatedShared = true;
        client = api;
      }
      return await body(client, lease.resolvedPath);
    } finally {
      await lease.stop();
      isolated?.close();
      if (mutatedShared) api.selectRoot(prevRoot);
    }
  }

  Future<LightIsleRoot> _verifyTargetRoot(DesktopBackupTask task) async {
    final response = await api.get('/api/v2/roots');
    final raw = response['roots'];
    if (raw is! List) throw StateError('无法读取 NAS 存储卷列表，请检查服务器状态。');
    final roots = raw.whereType<Map>().map((m) => LightIsleRoot.fromJson(Map<String, dynamic>.from(m))).toList(growable: false);
    final byId = roots.where((r) => r.id == task.rootId).firstOrNull;
    if (byId == null) throw StateError('原备份硬盘「${task.rootName}」已解除登记，无法还原。');
    if (byId.generation != task.rootGeneration) throw StateError('原备份硬盘「${task.rootName}」代际已变更，已停止还原以避免串盘。');
    if (!byId.online) throw StateError('原备份硬盘「${task.rootName}」当前离线，请连接后重试。');
    return byId;
  }

  Future<void> _walkRemoteTree(
    LightIsleApi client,
    String baseRemotePath,
    String relPrefix,
    int depth,
    List<({String relPath, String remotePath, int size})> out,
    void Function() checkActive,
  ) async {
    if (depth > _maxDepth || out.length >= _maxRemoteEntries) return;
    final remoteFolder = _joinRemote(baseRemotePath, relPrefix);
    var cursor = '';
    for (var page = 0; page < 200; page++) {
      checkActive();
      final Map<String, dynamic> data;
      try {
        data = await client.get(
          '/api/v2/files',
          query: <String, String>{'path': remoteFolder, 'limit': '200', if (cursor.isNotEmpty) 'cursor': cursor},
        );
      } on LightIsleApiException catch (error) {
        if (error.statusCode == HttpStatus.notFound && relPrefix.isEmpty) return;
        rethrow;
      }
      for (final raw in (data['entries'] as List? ?? const []).whereType<Map>()) {
        checkActive();
        final name = raw['name']?.toString() ?? '';
        final type = raw['type']?.toString() ?? '';
        final size = (raw['size'] as num?)?.toInt() ?? 0;
        if (name.isEmpty ||
            name == '.' ||
            name == '..' ||
            isLightIsleInternalArtifactName(name) ||
            validateFileName(name) != null) {
          continue;
        }
        final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
        if (type == 'folder') {
          await _walkRemoteTree(client, baseRemotePath, relPath, depth + 1, out, checkActive);
        } else if (type == 'file' && out.length < _maxRemoteEntries) {
          out.add((relPath: relPath, remotePath: _joinRemote(baseRemotePath, relPath), size: size));
        }
      }
      cursor = data['nextCursor']?.toString() ?? '';
      if (cursor.isEmpty) break;
    }
  }

  Future<int> _countLocalOnly(String localRootPath, Set<String> remoteRelPaths, void Function() checkActive) async {
    var count = 0;
    Future<void> walk(Directory dir, String prefix, int depth) async {
      if (depth > _maxDepth) return;
      checkActive();
      final List<FileSystemEntity> children;
      try { children = await dir.list(followLinks: false).toList(); } catch (_) { return; }
      for (final entity in children) {
        checkActive();
        final name = entity.path.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).lastOrNull;
        if (name == null || isLightIsleInternalArtifactName(name)) continue;
        final type = await FileSystemEntity.type(entity.path, followLinks: false);
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        if (type == FileSystemEntityType.directory) {
          await walk(Directory(entity.path), rel, depth + 1);
        } else if (type == FileSystemEntityType.file && !remoteRelPaths.contains(rel)) {
          count++;
        }
      }
    }

    await walk(Directory(localRootPath), '', 0);
    return count;
  }

  static String _joinRemote(String base, String child) {
    final clean = base.trim().isEmpty ? '.' : base.trim();
    return (child.isEmpty || child == '.') ? clean : (clean == '.' ? child : '$clean/$child');
  }

  static String _resolveLocalPath(String localRoot, String relPath) {
    final segments = relPath.split('/');
    for (final s in segments) {
      if (s.isEmpty || s == '.' || s == '..' || s.contains('\\')) {
        throw StateError('检测到不安全的远端相对路径：$relPath');
      }
    }
    final sep = Platform.pathSeparator;
    final root = localRoot.endsWith(sep) ? localRoot.substring(0, localRoot.length - 1) : localRoot;
    return '$root$sep${segments.join(sep)}';
  }

  static Future<String> _reserveBackupPath(String originalPath) async {
    final first = '$originalPath.lightisle-bak';
    if (await FileSystemEntity.type(first, followLinks: false) == FileSystemEntityType.notFound) return first;
    for (var i = 1; i < 1000; i++) {
      final candidate = '$originalPath.lightisle-bak.$i';
      if (await FileSystemEntity.type(candidate, followLinks: false) == FileSystemEntityType.notFound) return candidate;
    }
    return '$originalPath.lightisle-bak.${DateTime.now().millisecondsSinceEpoch}';
  }
}
