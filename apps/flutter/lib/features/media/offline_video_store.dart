import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'offline_index_io.dart';
import 'offline_scope.dart';

/// App-private downloads isolated by NAS origin, account and physical-root
/// generation. A media session cookie or playback URL is never persisted.
class OfflineVideoStore {
  OfflineVideoStore({
    required LightIsleApi api,
    required String accountName,
    this.applicationDirectory,
  }) : api = api,
       accountName = accountName,
       _rootIdentity = api.selectedRoot?.identity ?? 'default',
       scopeId = _scopeFor(api, accountName);

  static const maxSingleBytes = 2 * 1024 * 1024 * 1024;
  static const maxLibraryBytes = 5 * 1024 * 1024 * 1024;
  static final Set<String> _activeDownloads = <String>{};
  final LightIsleApi api;
  final String accountName;
  final Directory? applicationDirectory;
  final String _rootIdentity;

  /// Frozen when the download begins. A root switch cannot change its target
  /// folder midway through an asynchronous NAS transfer.
  final String scopeId;
  static final RegExp _mediaFileName = RegExp(r'^[a-f0-9]{64}\.[a-z0-9]{1,8}$');

  void _checkRoot() {
    if ((api.selectedRoot?.identity ?? 'default') != _rootIdentity) {
      throw StateError('NAS 存储根已切换，请返回当前存储位置重新保存');
    }
  }

  static String _scopeFor(LightIsleApi api, String accountName) {
    if (accountName.trim().isEmpty) {
      throw StateError('无法确认当前账号，离线库不可用');
    }
    return offlineMediaScopeId(api, accountName);
  }

  Future<Directory> _directory() async {
    final support =
        applicationDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}offline-videos${Platform.pathSeparator}$scopeId',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _index() async =>
      File('${(await _directory()).path}${Platform.pathSeparator}index.json');

  Future<List<OfflineVideo>> list() async {
    final index = await _index();
    if (!await index.exists()) return [];
    final content = await index.readAsString();
    if (content.length > 2 * 1024 * 1024) throw const FormatException('离线索引过大');
    final decoded = jsonDecode(content);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['videos'] is! List) {
      throw const FormatException('离线索引格式无效');
    }
    final dir = await _directory();
    final videos = <OfflineVideo>[];
    for (final item in decoded['videos'] as List) {
      if (item is! Map) continue;
      try {
        final video = OfflineVideo.fromJson(item);
        final file = File(
          '${dir.path}${Platform.pathSeparator}${video.fileName}',
        );
        if (await file.exists() && await file.length() == video.size) {
          videos.add(video);
        }
      } on FormatException {
        // Do not open malformed paths from a damaged index.
      }
    }
    return videos;
  }

  /// SHA-256 is checked when an offline file is opened, not on every list
  /// refresh (which might otherwise read 5 GiB of video into the CPU).
  Future<String> _hashFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<int> cleanupUnusedFiles() async {
    if (_activeDownloads.contains(scopeId)) {
      throw StateError('当前离线库正在保存影片，请完成后再清理');
    }
    final dir = await _directory();
    final index = await _index();
    final contents = await index.exists() ? await index.readAsString() : '';
    final raw = contents.isEmpty ? null : jsonDecode(contents);
    if (raw != null &&
        (raw is! Map || raw['version'] != 1 || raw['videos'] is! List)) {
      throw const FormatException('离线索引损坏，停止清理以防误删');
    }
    final referenced = <String>{};
    if (raw is Map) {
      for (final item in raw['videos'] as List) {
        if (item is! Map) continue;
        try {
          referenced.add(OfflineVideo.fromJson(item).fileName);
        } on FormatException {
          // Invalid entries cannot authorize any file for retention.
        }
      }
    }
    var removed = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (_mediaFileName.hasMatch(name) && !referenced.contains(name)) {
        await entity.delete();
        removed++;
      }
    }
    return removed;
  }

  Future<void> clear() async {
    if (_activeDownloads.contains(scopeId)) {
      throw StateError('当前离线库正在保存影片，请完成后再清空');
    }
    final dir = await _directory();
    // Only the active scope's SHA-256-named subdirectory is removed, never
    // unrelated accounts or other physical roots.
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> _write(List<OfflineVideo> videos) async {
    final index = await _index();
    await writeOfflineIndexAtomically(index, {
      'version': 1,
      'videos': videos.map((v) => v.toJson()).toList(),
    }, temporarySuffix: '.new');
  }

  Future<OfflineVideo> save(
    CinemaFilm film, {
    void Function(int received, int total)? onProgress,
  }) async {
    _checkRoot();
    if (!_activeDownloads.add(scopeId)) {
      throw StateError('当前离线库已有下载任务，请完成后重试');
    }
    try {
      if (film.size <= 0 || film.size > maxSingleBytes) {
        throw StateError('仅支持离线保存大小已确认且不超过 2 GiB 的影片');
      }
      if (film.path.isEmpty || film.title.isEmpty) {
        throw StateError('影片缺少有效路径或名称');
      }
      final items = await list();
      _checkRoot();
      final existing = items.where((v) => v.remotePath == film.path).toList();
      if (existing.isNotEmpty && existing.first.size == film.size) {
        try {
          await fileFor(existing.first);
          return existing.first;
        } on FormatException {
          // Same-size file with different content must be downloaded again.
        }
      }
      final totalBytes = items.fold<int>(0, (sum, item) => sum + item.size);
      if (totalBytes + film.size > maxLibraryBytes) {
        throw StateError('离线库存储上限为 5 GiB，请删除已缓存影片后再试');
      }
      final basename = film.path.split('/').last;
      final dot = basename.lastIndexOf('.');
      final ext = dot > 0 ? basename.substring(dot).toLowerCase() : '.mp4';
      final suffix = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext)
          ? ext
          : '.video';
      final hash = sha256
          .convert(utf8.encode('${film.path}\n${film.size}'))
          .toString();
      final video = OfflineVideo(
        fileName: '$hash$suffix',
        remotePath: film.path,
        title: film.title,
        size: film.size,
        savedAt: DateTime.now().toUtc(),
      );
      final dir = await _directory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}${video.fileName}',
      );
      if (await file.exists()) await file.delete();
      try {
        await api.download(
          '/api/v2/files/content',
          file.path,
          query: {'path': film.path},
          onProgress: (received, total) {
            if (received > film.size || total > maxSingleBytes) {
              throw StateError('离线文件超出确认的大小，下载已停止');
            }
            onProgress?.call(received, total);
          },
        );
        if (await file.length() != film.size) {
          throw const FormatException('下载后的文件大小与服务器记录不一致');
        }
        final digest = await _hashFile(file);
        _checkRoot();
        final next =
            items.where((item) => item.remotePath != film.path).toList()
              ..add(video.copyWithDigest(digest));
        await _write(next);
        for (final item in existing) {
          if (item.fileName != video.fileName) {
            final stale = File(
              '${dir.path}${Platform.pathSeparator}${item.fileName}',
            );
            if (await stale.exists()) await stale.delete();
          }
        }
        return video.copyWithDigest(digest);
      } catch (_) {
        if (await file.exists()) await file.delete();
        rethrow;
      }
    } finally {
      _activeDownloads.remove(scopeId);
    }
  }

  Future<File> fileFor(OfflineVideo video) async {
    final scope = await list();
    if (!scope.any(
      (v) => v.fileName == video.fileName && v.remotePath == video.remotePath,
    )) {
      throw StateError('影片不属于当前账号或存储根的离线库');
    }
    final file = File(
      '${(await _directory()).path}${Platform.pathSeparator}${video.fileName}',
    );
    if (video.sha256 != null && await _hashFile(file) != video.sha256) {
      throw const FormatException('离线影片完整性校验失败，请删除副本并重新保存');
    }
    return file;
  }

  Future<void> remove(OfflineVideo video) async {
    final items = await list();
    if (!items.any(
      (v) => v.fileName == video.fileName && v.remotePath == video.remotePath,
    )) {
      return;
    }
    final file = File(
      '${(await _directory()).path}${Platform.pathSeparator}${video.fileName}',
    );
    if (await file.exists()) await file.delete();
    await _write(
      items.where((item) => item.fileName != video.fileName).toList(),
    );
  }
}

class OfflineVideo {
  const OfflineVideo({
    required this.fileName,
    required this.remotePath,
    required this.title,
    required this.size,
    required this.savedAt,
    this.sha256,
  });

  final String fileName;
  final String remotePath;
  final String title;
  final int size;
  final DateTime savedAt;
  final String? sha256;

  OfflineVideo copyWithDigest(String digest) => OfflineVideo(
    fileName: fileName,
    remotePath: remotePath,
    title: title,
    size: size,
    savedAt: savedAt,
    sha256: digest,
  );

  factory OfflineVideo.fromJson(Map json) {
    final fileName = json['fileName'];
    final remotePath = json['remotePath'];
    final title = json['title'];
    final size = json['size'];
    final date = DateTime.tryParse(json['savedAt']?.toString() ?? '');
    final contentHash = json['sha256'];
    if (fileName is! String ||
        !RegExp(r'^[a-f0-9]{64}\.[a-z0-9]{1,8}$').hasMatch(fileName) ||
        remotePath is! String ||
        remotePath.isEmpty ||
        title is! String ||
        title.isEmpty ||
        size is! int ||
        size < 1 ||
        size > OfflineVideoStore.maxSingleBytes ||
        (contentHash != null &&
            (contentHash is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash))) ||
        date == null) {
      throw const FormatException('无效的离线影片记录');
    }
    return OfflineVideo(
      fileName: fileName,
      remotePath: remotePath,
      title: title,
      size: size,
      savedAt: date,
      sha256: contentHash as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'fileName': fileName,
    'remotePath': remotePath,
    'title': title,
    'size': size,
    'savedAt': savedAt.toIso8601String(),
    'sha256': sha256,
  };
}
