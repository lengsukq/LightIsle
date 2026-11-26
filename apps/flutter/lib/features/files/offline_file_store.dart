import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lightisle_api.dart';
import '../media/offline_index_io.dart';
import '../media/offline_scope.dart';
import 'file_models.dart';

class OfflineFileEntry {
  const OfflineFileEntry({
    required this.rootId,
    required this.generation,
    required this.path,
    required this.name,
    required this.fileName,
    required this.localPath,
    required this.sizeBytes,
    required this.sha256,
    required this.savedAt,
  });

  final String rootId;
  final int generation;
  final String path;
  final String name;
  final String fileName;
  final String localPath;
  final int sizeBytes;
  final String sha256;
  final DateTime savedAt;

  static final RegExp _safeFileName = RegExp(r'^[a-f0-9]{64}(\.[a-z0-9]{1,10})?$');
  static final RegExp _safeDigest = RegExp(r'^[a-f0-9]{64}$');

  Map<String, dynamic> toJson() => {
    'rootId': rootId,
    'generation': generation,
    'path': path,
    'name': name,
    'fileName': fileName,
    'localPath': localPath,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'savedAt': savedAt.toUtc().toIso8601String(),
  };

  factory OfflineFileEntry.fromJson(
    Map<dynamic, dynamic> json, {
    required String scopeDirPath,
  }) {
    final fileName = json['fileName']?.toString() ?? '';
    final path = json['path']?.toString() ?? '';
    final name = json['name']?.toString() ?? '';
    final digest = json['sha256']?.toString() ?? '';
    final sizeBytes = (json['sizeBytes'] as num?)?.toInt() ?? -1;
    if (!_safeFileName.hasMatch(fileName) ||
        !_safeDigest.hasMatch(digest) ||
        path.isEmpty ||
        name.isEmpty ||
        sizeBytes < 0) {
      throw const FormatException('离线文件索引条目无效');
    }
    final resolvedLocal = '$scopeDirPath${Platform.pathSeparator}$fileName';
    final savedAtRaw = json['savedAt']?.toString();
    return OfflineFileEntry(
      rootId: json['rootId']?.toString() ?? '',
      generation: (json['generation'] as num?)?.toInt() ?? 0,
      path: path,
      name: name,
      fileName: fileName,
      localPath: resolvedLocal,
      sizeBytes: sizeBytes,
      sha256: digest,
      savedAt: (savedAtRaw != null ? DateTime.tryParse(savedAtRaw) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

class OfflineFileVaultStats {
  const OfflineFileVaultStats({required this.count, required this.totalBytes});

  final int count;
  final int totalBytes;
}

/// App-private offline document/file vault isolated by NAS origin, pinned TLS
/// fingerprint, account identity, and physical root generation.
///
/// Stored outside temporary caches (`offline-files/<scopeId>/`) so clearing
/// temporary thumbnail/poster/metadata caches can never delete user-saved
/// offline files.
class OfflineFileStore {
  OfflineFileStore({
    required this.api,
    required this.accountIdentity,
    this.applicationDirectory,
  }) : _rootId = api.selectedRoot?.id ?? '',
       _generation = api.selectedRoot?.generation ?? 0,
       _rootIdentity = api.selectedRoot?.identity ?? 'default',
       scopeId = _computeScope(api, accountIdentity);

  static const int maxSingleFileBytes = 512 * 1024 * 1024;
  static const int maxVaultBytes = 4 * 1024 * 1024 * 1024;
  static final Set<String> _activeSaves = <String>{};

  final LightIsleApi api;
  final String accountIdentity;
  final Directory? applicationDirectory;
  final String _rootId;
  final int _generation;
  final String _rootIdentity;
  final String scopeId;

  static String _computeScope(LightIsleApi api, String accountIdentity) {
    final normalized = accountIdentity.trim();
    if (normalized.isEmpty) {
      throw StateError('无法确认当前账号，离线文件箱不可用');
    }
    return offlineMediaScopeId(api, normalized);
  }

  void _checkRoot() {
    if ((api.selectedRoot?.identity ?? 'default') != _rootIdentity) {
      throw StateError('硬盘存储位置已切换，请重新打开当前目录后再离线保存');
    }
  }

  Future<Directory> _directory() async {
    final support =
        applicationDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}offline-files'
      '${Platform.pathSeparator}$scopeId',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _indexFile() async =>
      File('${(await _directory()).path}${Platform.pathSeparator}index.json');

  Future<List<OfflineFileEntry>> list() async {
    final index = await _indexFile();
    if (!await index.exists()) return const [];
    if (await index.length() > 4 * 1024 * 1024) {
      throw const FormatException('离线文件箱索引过大');
    }
    final decoded = jsonDecode(await index.readAsString());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['files'] is! List) {
      throw const FormatException('离线文件箱索引格式无效');
    }
    final dir = await _directory();
    final entries = <OfflineFileEntry>[];
    for (final raw in decoded['files'] as List) {
      if (raw is! Map) continue;
      try {
        final entry = OfflineFileEntry.fromJson(raw, scopeDirPath: dir.path);
        final file = File(entry.localPath);
        if (await file.exists() && await file.length() == entry.sizeBytes) {
          entries.add(entry);
        }
      } on FormatException {
        // Ignore tampered or malformed entries safely.
      }
    }
    entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return entries;
  }

  Future<OfflineFileVaultStats> stats() async {
    final items = await list();
    var total = 0;
    for (final item in items) {
      total += item.sizeBytes;
    }
    return OfflineFileVaultStats(count: items.length, totalBytes: total);
  }

  Future<bool> containsPath(String remotePath) async {
    final items = await list();
    return items.any((item) => item.path == remotePath);
  }

  Future<void> _writeManifest(List<OfflineFileEntry> items) async {
    final index = await _indexFile();
    await writeOfflineIndexAtomically(index, {
      'version': 1,
      'files': items.map((e) => e.toJson()).toList(),
    }, temporarySuffix: '.tmp');
  }

  Future<String> _hashFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  String _safeExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    final ext = fileName.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(ext) ? ext : '';
  }

  Future<OfflineFileEntry> save(
    FileEntry item, {
    void Function(int received, int total)? onProgress,
  }) async {
    _checkRoot();
    if (item.isFolder || item.path.trim().isEmpty || item.name.trim().isEmpty) {
      throw StateError('只能将单个文件保存到离线文件箱');
    }
    if (item.size < 0 || item.size > maxSingleFileBytes) {
      throw StateError('仅支持将不超过 512 MiB 的文件保存到离线文件箱');
    }
    if (!_activeSaves.add(scopeId)) {
      throw StateError('离线文件箱正在保存其他文件，请稍后重试');
    }
    try {
      final existingItems = await list();
      _checkRoot();
      final totalExisting = existingItems.fold<int>(
        0,
        (sum, e) => sum + (e.path == item.path ? 0 : e.sizeBytes),
      );
      if (totalExisting + item.size > maxVaultBytes) {
        throw StateError('离线文件箱容量上限为 4 GiB，请先移除部分离线文件');
      }

      final dir = await _directory();
      final ext = _safeExtension(item.name);
      final hashKey = sha256
          .convert(
            utf8.encode(
              '$_rootId\n$_generation\n${item.path}\n${DateTime.now().microsecondsSinceEpoch}',
            ),
          )
          .toString();
      final fileName = '$hashKey$ext';
      final target = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (await target.exists()) await target.delete();

      try {
        await api.download(
          '/api/v2/files/content',
          target.path,
          query: {'path': item.path},
          onProgress: (received, total) {
            if (received > maxSingleFileBytes || total > maxSingleFileBytes) {
              throw StateError('文件超出离线保存单文件上限（512 MiB），已停止');
            }
            onProgress?.call(received, total);
          },
        );
        final actualSize = await target.length();
        if (item.size > 0 && actualSize != item.size) {
          throw const FormatException('离线保存的文件大小与服务器记录不一致');
        }
        final digest = await _hashFile(target);
        _checkRoot();

        final entry = OfflineFileEntry(
          rootId: _rootId,
          generation: _generation,
          path: item.path,
          name: item.name,
          fileName: fileName,
          localPath: target.path,
          sizeBytes: actualSize,
          sha256: digest,
          savedAt: DateTime.now().toUtc(),
        );
        final previousMatches = existingItems
            .where((e) => e.path == item.path)
            .toList();
        final next = existingItems.where((e) => e.path != item.path).toList()
          ..insert(0, entry);
        await _writeManifest(next);
        for (final stale in previousMatches) {
          if (stale.fileName != entry.fileName) {
            final staleFile = File(stale.localPath);
            if (await staleFile.exists()) await staleFile.delete();
          }
        }
        return entry;
      } catch (_) {
        if (await target.exists()) await target.delete();
        rethrow;
      }
    } finally {
      _activeSaves.remove(scopeId);
    }
  }

  /// Validates membership, local existence, byte size, and SHA-256 digest
  /// before handing the local file path to a viewer or OS application.
  Future<File> fileFor(OfflineFileEntry entry) async {
    final items = await list();
    final matched = items.where(
      (item) =>
          item.fileName == entry.fileName &&
          item.path == entry.path &&
          item.sha256 == entry.sha256,
    );
    if (matched.isEmpty) {
      throw StateError('该离线文件不属于当前账号或存储位置');
    }
    final file = File(matched.first.localPath);
    if (!await file.exists()) {
      throw StateError('离线文件已丢失，请联网后重新保存');
    }
    if (await file.length() != entry.sizeBytes) {
      throw const FormatException('离线文件大小异常，已中止打开');
    }
    final actualDigest = await _hashFile(file);
    if (actualDigest != entry.sha256) {
      throw const FormatException('离线文件完整性校验失败，请移除后重新保存');
    }
    return file;
  }

  Future<void> remove(OfflineFileEntry entry) async {
    if (_activeSaves.contains(scopeId)) {
      throw StateError('正在保存离线文件，请稍后再移除');
    }
    final items = await list();
    final next = items
        .where(
          (item) =>
              !(item.fileName == entry.fileName && item.path == entry.path),
        )
        .toList();
    await _writeManifest(next);
    final file = File(entry.localPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> clear() async {
    if (_activeSaves.contains(scopeId)) {
      throw StateError('正在保存离线文件，请稍后再清空');
    }
    final dir = await _directory();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
