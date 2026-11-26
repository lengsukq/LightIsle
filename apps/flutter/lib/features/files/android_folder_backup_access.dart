import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../core/user_facing_error.dart';
import 'desktop_backup_engine.dart';
import 'desktop_backup_ignore.dart';
import 'desktop_backup_models.dart';
import 'file_name_validation.dart';
import 'photo_backup_hash.dart';

/// Android SAF (`ACTION_OPEN_DOCUMENT_TREE` + `DocumentsContract`) folder
/// access adapter for one-way incremental backup.
class AndroidFolderBackupAccess extends DesktopDirectoryAccess {
  const AndroidFolderBackupAccess({this.channel = defaultChannel});

  static const MethodChannel defaultChannel = MethodChannel(
    'lightisle/android-folders',
  );

  final MethodChannel channel;

  @override
  bool get supportsWatch => false;

  @override
  bool get supportsRestore => false;

  @override
  Future<DesktopPickedFolder?> pickDirectory() async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'pickDirectory',
      );
      if (result == null) return null;
      final treeUri = result['treeUri']?.toString().trim() ?? '';
      if (treeUri.isEmpty) return null;
      final displayPath = result['displayPath']?.toString().trim();
      final displayName = result['displayName']?.toString().trim();
      final labelPath = (displayPath != null && displayPath.isNotEmpty)
          ? displayPath
          : (displayName != null && displayName.isNotEmpty ? displayName : null);
      return DesktopPickedFolder(
        path: treeUri,
        displayPath: labelPath,
      );
    } on PlatformException catch (error) {
      throw StateError(
        error.message?.isNotEmpty == true
            ? error.message!
            : '无法打开系统文件夹选择器，请重试。',
      );
    } on MissingPluginException {
      throw StateError('当前 Android 版本尚未挂载本机文件夹备份通道，请更新客户端后重试。');
    }
  }

  @override
  Future<DesktopDirectoryLease> startAccess(DesktopBackupTask task) async {
    final treeUri = task.localPath.trim();
    if (!treeUri.startsWith('content://')) {
      throw StateError('Android 文件夹授权地址无效，请编辑任务重新选择文件夹。');
    }
    try {
      final info = await channel.invokeMapMethod<String, dynamic>(
        'checkAccess',
        <String, Object?>{'treeUri': treeUri},
      );
      if (info == null || info['accessible'] != true) {
        throw StateError('Android 文件夹读取授权已失效或目录已移除，请编辑任务重新选择文件夹。');
      }
    } on PlatformException catch (error) {
      throw StateError(
        error.message?.isNotEmpty == true
            ? error.message!
            : 'Android 文件夹读取授权已失效，请编辑任务重新选择文件夹。',
      );
    } on MissingPluginException {
      throw StateError('当前 Android 版本尚未挂载本机文件夹备份通道，请更新客户端后重试。');
    }
    return DesktopDirectoryLease(
      resolvedPath: treeUri,
      source: AndroidSafFolderSource(channel: channel, treeUri: treeUri),
      stop: () async {},
    );
  }
}

/// Zero-copy streaming folder source backed by Android `DocumentsContract` and
/// `ContentResolver.openInputStream`.
class AndroidSafFolderSource extends BackupFolderSource {
  AndroidSafFolderSource({
    required this.channel,
    required this.treeUri,
  });

  final MethodChannel channel;
  final String treeUri;
  final Set<String> _activeRequestIds = <String>{};

  static String _newRequestId() {
    final rng = Random.secure();
    return List<String>.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _cancelNativeRequestAsync(String requestId) {
    unawaited(
      channel
          .invokeMethod<bool>(
            'cancelRequest',
            <String, Object?>{'requestId': requestId},
          )
          .catchError((Object _) => false),
    );
  }

  @override
  void cancelActiveRequest() {
    final pending = _activeRequestIds.toList(growable: false);
    for (final requestId in pending) {
      _cancelNativeRequestAsync(requestId);
    }
  }

  @override
  Future<BackupScanResult> scan({
    required DesktopBackupTask task,
    required DesktopBackupIgnoreMatcher matcher,
    Set<String>? onlyPaths,
    required void Function() checkActive,
  }) async {
    checkActive();
    final requestId = _newRequestId();
    _activeRequestIds.add(requestId);
    final Map<String, dynamic>? raw;
    try {
      raw = await channel.invokeMapMethod<String, dynamic>(
        'scanDirectory',
        <String, Object?>{
          'treeUri': treeUri,
          'ignoreHidden': task.ignoreHidden,
          'ignorePatterns': matcher.effectivePatterns,
          'maxFileSizeBytes': matcher.maxFileSizeBytes,
          'requestId': requestId,
        },
      );
    } on PlatformException catch (error) {
      checkActive();
      throw StateError(
        error.message?.isNotEmpty == true
            ? error.message!
            : '扫描 Android 文件夹失败：${userFacingError(error)}',
      );
    } finally {
      _activeRequestIds.remove(requestId);
    }
    try {
      checkActive();
    } catch (_) {
      _cancelNativeRequestAsync(requestId);
      rethrow;
    }
    if (raw == null) {
      throw StateError('扫描 Android 文件夹返回空结果，请检查目录授权后重试。');
    }

    final files = <BackupScannedFile>[];
    final failures = <DesktopBackupFailure>[];
    var skippedIgnored = (raw['skippedIgnored'] as num?)?.toInt() ?? 0;
    var skippedOversized = (raw['skippedOversized'] as num?)?.toInt() ?? 0;
    final skippedSymlinks = (raw['skippedSymlinks'] as num?)?.toInt() ?? 0;
    final truncated = raw['truncated'] == true;

    final rawFailures = raw['failures'];
    if (rawFailures is List) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final entry in rawFailures.whereType<Map>()) {
        final path = entry['relativePath']?.toString() ?? '';
        final reason = entry['reason']?.toString() ?? '读取失败';
        if (path.isNotEmpty) {
          failures.add(
            DesktopBackupFailure(
              relativePath: path,
              reason: reason,
              failedAtMs: nowMs,
            ),
          );
        }
      }
    }

    final rawFiles = raw['files'];
    if (rawFiles is List) {
      for (final entry in rawFiles.whereType<Map>()) {
        checkActive();
        final relPath = DesktopBackupIgnoreMatcher.normalizeRelativePath(
          entry['relativePath']?.toString() ?? '',
        );
        final fileName = entry['fileName']?.toString() ?? '';
        final documentUri = entry['documentUri']?.toString() ?? '';
        final size = (entry['size'] as num?)?.toInt() ?? -1;
        final modifiedMs = (entry['modifiedMs'] as num?)?.toInt() ?? 0;
        if (relPath.isEmpty || fileName.isEmpty || documentUri.isEmpty) {
          continue;
        }
        // Defense-in-depth: apply Dart ignore & size rules on top of Kotlin.
        if (matcher.shouldIgnore(relPath, isDirectory: false)) {
          skippedIgnored++;
          continue;
        }
        if (size < 0) {
          failures.add(
            DesktopBackupFailure(
              relativePath: relPath,
              reason: '无法获取文件大小，请检查本机存储状态。',
              failedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          continue;
        }
        if (matcher.exceedsSizeLimit(size)) {
          skippedOversized++;
          continue;
        }
        if (onlyPaths != null && !onlyPaths.contains(relPath)) continue;

        final nameIssue = validateFileName(fileName);
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

        final slash = relPath.lastIndexOf('/');
        final parentDir = slash < 0 ? '' : relPath.substring(0, slash);
        files.add(
          BackupScannedFile(
            relativePath: relPath,
            parentRelativeDir: parentDir,
            fileName: fileName,
            size: size,
            modifiedMs: modifiedMs,
            sourceUri: documentUri,
          ),
        );
      }
    }

    return BackupScanResult(
      files: files,
      failures: failures,
      skippedSymlinks: skippedSymlinks,
      skippedIgnored: skippedIgnored,
      skippedOversized: skippedOversized,
      truncated: truncated,
    );
  }

  @override
  Future<({int size, int modifiedMs})?> statFile(
    BackupScannedFile item, {
    required void Function() checkActive,
  }) async {
    checkActive();
    final docUri = item.sourceUri;
    if (docUri == null || docUri.isEmpty) return null;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'statFile',
        <String, Object?>{'treeUri': treeUri, 'documentUri': docUri},
      );
      if (result == null) return null;
      final size = (result['size'] as num?)?.toInt();
      final modifiedMs = (result['modifiedMs'] as num?)?.toInt();
      if (size == null || size < 0 || modifiedMs == null) return null;
      return (size: size, modifiedMs: modifiedMs);
    } on PlatformException catch (error) {
      if (error.code == 'folder_source_changed' || error.code == 'not_found') {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<PhotoHashResult> hashFile(
    BackupScannedFile item, {
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  }) async {
    checkActive();
    final docUri = item.sourceUri;
    if (docUri == null || docUri.isEmpty) {
      throw const PhotoSourceChanged();
    }
    final requestId = _newRequestId();
    _activeRequestIds.add(requestId);
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'hashFile',
        <String, Object?>{
          'treeUri': treeUri,
          'documentUri': docUri,
          'expectedSize': expectedSize,
          'expectedModifiedMs': expectedModifiedMs,
          'requestId': requestId,
        },
      );
      checkActive();
      final digest = result?['sha256']?.toString() ?? '';
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw StateError('无法计算本地文件 SHA-256 摘要，请重试。');
      }
      final rawChunks = result?['chunkDigests'];
      final chunks = rawChunks is List
          ? rawChunks.map((e) => e.toString()).toList(growable: false)
          : const <String>[];
      return PhotoHashResult(digest, chunks);
    } on PlatformException catch (error) {
      checkActive();
      if (error.code == 'folder_source_changed') {
        throw const PhotoSourceChanged();
      }
      throw StateError(
        error.message?.isNotEmpty == true ? error.message! : '流式读取本机文件校验失败。',
      );
    } catch (_) {
      _cancelNativeRequestAsync(requestId);
      rethrow;
    } finally {
      _activeRequestIds.remove(requestId);
    }
  }

  @override
  Stream<List<int>> readChunk(
    BackupScannedFile item, {
    required int offset,
    required int length,
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  }) async* {
    checkActive();
    final docUri = item.sourceUri;
    if (docUri == null || docUri.isEmpty) {
      throw const PhotoSourceChanged();
    }
    if (length == 0) return;
    final requestId = _newRequestId();
    _activeRequestIds.add(requestId);
    try {
      final bytes = await channel.invokeMethod<Uint8List>(
        'readChunk',
        <String, Object?>{
          'treeUri': treeUri,
          'documentUri': docUri,
          'offset': offset,
          'length': length,
          'expectedSize': expectedSize,
          'expectedModifiedMs': expectedModifiedMs,
          'requestId': requestId,
        },
      );
      checkActive();
      if (bytes == null || bytes.length != length) {
        throw const PhotoSourceChanged();
      }
      yield bytes;
    } on PlatformException catch (error) {
      checkActive();
      if (error.code == 'folder_source_changed') {
        throw const PhotoSourceChanged();
      }
      throw StateError(
        error.message?.isNotEmpty == true ? error.message! : '读取本机文件分片失败。',
      );
    } catch (_) {
      _cancelNativeRequestAsync(requestId);
      rethrow;
    } finally {
      _activeRequestIds.remove(requestId);
    }
  }

  @override
  Future<void> verifyUnchangedBeforeComplete(
    BackupScannedFile item, {
    required int expectedSize,
    required int expectedModifiedMs,
    required void Function() checkActive,
  }) async {
    final latest = await statFile(item, checkActive: checkActive);
    if (latest == null ||
        latest.size != expectedSize ||
        latest.modifiedMs != expectedModifiedMs) {
      throw const PhotoSourceChanged();
    }
  }
}
