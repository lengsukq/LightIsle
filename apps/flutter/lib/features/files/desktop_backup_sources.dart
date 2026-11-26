import 'dart:io';
import 'dart:math';

import '../../core/user_facing_error.dart';
import 'desktop_backup_ignore.dart';
import 'desktop_backup_models.dart';
import 'file_name_validation.dart';
import 'photo_backup_hash.dart';

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
    this.truncated = false,
  });

  final List<BackupScannedFile> files;
  final List<DesktopBackupFailure> failures;
  final int skippedSymlinks;
  final int skippedIgnored;
  final int skippedOversized;
  final bool truncated;
}

/// Abstract read-only source interface shared by Desktop filesystem folders
/// and Android SAF document trees so both reuse the exact same incremental
/// verification and two-phase replacement pipeline.
abstract class BackupFolderSource {
  const BackupFolderSource();

  /// Requests immediate cancellation of any in-flight native scan/hash/read
  /// operation owned by this source.
  void cancelActiveRequest() {}

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
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
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
      : hashLocalBackupFile(
          item.localFile!,
          expectedSize,
          checkActive: checkActive,
        );

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
    if (before.type != FileSystemEntityType.file ||
        before.size != expectedSize) {
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
