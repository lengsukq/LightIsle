import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'offline_scope.dart';

/// Immutable copies of photo originals, isolated by NAS origin, pinned TLS
/// identity, stable account ID and physical root generation. No cookies,
/// authenticated URLs or credentials are written into the manifest.
class OfflinePhotoStore {
  OfflinePhotoStore({
    required this.api,
    required String accountId,
    this.applicationDirectory,
  }) : _rootIdentity = api.selectedRoot?.identity ?? 'default',
       _accountId = accountId,
       scopeId = _scope(api, accountId);

  static const maxPhotoBytes = 512 * 1024 * 1024;
  static const maxLibraryBytes = 2 * 1024 * 1024 * 1024;
  static final _saving = <String>{};
  static final _safeFile = RegExp(r'^[a-f0-9]{64}\.[a-z0-9]{2,6}$');
  static const extensions = {
    'jpg',
    'jpeg',
    'png',
    'heic',
    'heif',
    'webp',
    'gif',
    'tif',
    'tiff',
    'dng',
    'cr2',
    'cr3',
    'nef',
    'arw',
    'raf',
    'rw2',
    'orf',
    'pef',
  };

  final LightIsleApi api;
  final Directory? applicationDirectory;
  final String _rootIdentity;
  final String _accountId;
  final String scopeId;

  static String _profileKey(LightIsleApi api, String accountId) => sha256
      .convert(
        utf8.encode(
          '${api.uri('/').origin}\n${api.certificateFingerprint ?? ''}\n$accountId',
        ),
      )
      .toString();

  static Future<File> _profileFile(
    LightIsleApi api,
    String accountId,
    Directory? directory,
  ) async {
    final root = directory ?? await getApplicationSupportDirectory();
    final profiles = Directory(
      '${root.path}${Platform.pathSeparator}'
      'offline-photos${Platform.pathSeparator}profiles',
    );
    await profiles.create(recursive: true);
    return File(
      '${profiles.path}${Platform.pathSeparator}'
      '${_profileKey(api, accountId)}.json',
    );
  }

  /// Only root identities with a locally saved original appear here. This
  /// catalog is keyed to the secure-vault user's stable ID and TLS identity.
  /// It can be read without a network request during a cold-start outage.
  static Future<List<OfflinePhotoSource>> savedLocations({
    required LightIsleApi api,
    required String accountId,
    Directory? applicationDirectory,
  }) async {
    _scope(api, accountId);
    final file = await _profileFile(api, accountId, applicationDirectory);
    if (!await file.exists()) return [];
    if (await file.length() > 64 * 1024) {
      throw const FormatException('离线照片存储位置索引过大');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['roots'] is! List) {
      throw const FormatException('离线存储位置索引无效');
    }
    final result = <OfflinePhotoSource>[];
    for (final row in decoded['roots'] as List) {
      if (row is! Map) continue;
      try {
        final id = row['id'];
        final name = row['name'];
        final generation = row['generation'];
        if (id == '' && generation == 0 && name == '默认存储位置') {
          result.add(const OfflinePhotoSource(name: '默认存储位置'));
        } else if (id is String &&
            name is String &&
            generation is int &&
            generation > 0) {
          final root = LightIsleRoot.fromJson({
            'rootID': id,
            'generation': generation,
            'name': name,
            'online': true,
          });
          result.add(OfflinePhotoSource(name: root.name, root: root));
        }
      } on FormatException {
        // Ignore corrupt or forged remote root names, never arbitrary paths.
      }
    }
    return result;
  }

  Future<void> _recordLocation() async {
    final location = OfflinePhotoSource(
      name: api.selectedRoot?.name ?? '默认存储位置',
      root: api.selectedRoot,
    );
    final sources = await savedLocations(
      api: api,
      accountId: _accountId,
      applicationDirectory: applicationDirectory,
    );
    if (sources.any((s) => s.identity == location.identity)) return;
    final file = await _profileFile(api, _accountId, applicationDirectory);
    final temporary = File('${file.path}.new');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'roots': [...sources, location]
              .map(
                (s) => {
                  'id': s.root?.id ?? '',
                  'generation': s.root?.generation ?? 0,
                  'name': s.name,
                },
              )
              .toList(),
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static String _scope(LightIsleApi api, String accountId) {
    if (!RegExp(r'^uid:[1-9][0-9]*$').hasMatch(accountId)) {
      throw StateError('服务器未提供稳定账号编号，无法安全使用离线照片库');
    }
    return offlineMediaScopeId(api, accountId);
  }

  void _checkRoot() {
    if ((api.selectedRoot?.identity ?? 'default') != _rootIdentity) {
      throw StateError('硬盘已切换，不能将原盘照片保存到新盘离线库');
    }
  }

  Future<Directory> _dir() async {
    final base = applicationDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}offline-photos'
      '${Platform.pathSeparator}$scopeId',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _manifest() async =>
      File('${(await _dir()).path}${Platform.pathSeparator}index.json');

  Future<List<OfflinePhoto>> list() async {
    final index = await _manifest();
    if (!await index.exists()) return [];
    if (await index.length() > 2 * 1024 * 1024) {
      throw const FormatException('离线照片目录索引过大');
    }
    final decoded = jsonDecode(await index.readAsString());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['photos'] is! List) {
      throw const FormatException('离线照片目录索引损坏');
    }
    final dir = await _dir();
    final result = <OfflinePhoto>[];
    for (final item in decoded['photos'] as List) {
      if (item is! Map) continue;
      try {
        final photo = OfflinePhoto.fromJson(item);
        final file = File(
          '${dir.path}${Platform.pathSeparator}${photo.fileName}',
        );
        if (await file.exists() && await file.length() == photo.size) {
          result.add(photo);
        }
      } on FormatException {
        // Reject tampered manifest paths instead of reading outside scope.
      }
    }
    return result;
  }

  Future<void> _write(List<OfflinePhoto> items) async {
    final index = await _manifest();
    final part = File('${index.path}.tmp');
    try {
      await part.writeAsString(
        jsonEncode({
          'version': 1,
          'photos': items.map((p) => p.toJson()).toList(),
        }),
        flush: true,
      );
      await part.rename(index.path);
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  Future<OfflinePhoto> save(
    PhotoAsset asset, {
    void Function(int received, int total)? onProgress,
  }) async {
    _checkRoot();
    if (!_saving.add(scopeId)) throw StateError('正在保存其他离线照片，请稍后重试');
    try {
      if (asset.isVideo || asset.size < 1 || asset.size > maxPhotoBytes) {
        throw StateError('只可离线保存大小已确认且不超过 512 MiB 的照片原件');
      }
      final extension = asset.name.split('.').last.toLowerCase();
      if (!extensions.contains(extension)) {
        throw StateError('不支持将此格式存入离线照片库');
      }
      final items = await list();
      _checkRoot();
      final existing = items.where((p) => p.remotePath == asset.path).toList();
      if (existing.isNotEmpty && existing.first.size == asset.size) {
        try {
          await fileFor(existing.first);
          return existing.first;
        } on FormatException {
          // Corrupted local copies must be refreshed.
        }
      }
      final used = items
          .where((p) => p.remotePath != asset.path)
          .fold<int>(0, (total, item) => total + item.size);
      if (used + asset.size > maxLibraryBytes) {
        throw StateError('离线照片库最多使用 2 GiB，请先清理本机副本');
      }
      final name =
          '${sha256.convert(utf8.encode('${asset.path}\n${asset.size}'))}.$extension';
      final photo = OfflinePhoto(
        fileName: name,
        remotePath: asset.path,
        title: asset.name,
        size: asset.size,
        savedAt: DateTime.now().toUtc(),
        sha256: '',
      );
      final dir = await _dir();
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      // Never download directly over a catalogued photo. If the transfer
      // fails midway, the previously saved original must remain untouched.
      final staged = File('${file.path}.download');
      try {
        if (await staged.exists()) await staged.delete();
        // The transport writes a private file. Hash it after receipt and
        // publish to the manifest only on complete, root-pinned success.
        await api.download(
          '/api/v2/files/content',
          staged.path,
          query: {'path': asset.path},
          onProgress: (received, total) {
            if (received > asset.size || total > maxPhotoBytes) {
              throw StateError('服务器传输的原片超过确认大小，已停止保存');
            }
            onProgress?.call(received, total);
          },
        );
        if (await staged.length() != asset.size) {
          throw const FormatException('离线照片文件大小不符');
        }
        final digest = (await sha256.bind(staged.openRead()).first).toString();
        _checkRoot();
        final saved = photo.withDigest(digest);
        await _recordLocation();
        await staged.rename(file.path);
        await _write([
          ...items.where((p) => p.remotePath != asset.path),
          saved,
        ]);
        for (final old in existing) {
          if (old.fileName == name) continue;
          final stale = File(
            '${dir.path}${Platform.pathSeparator}${old.fileName}',
          );
          if (await stale.exists()) await stale.delete();
        }
        return saved;
      } catch (_) {
        if (await staged.exists()) await staged.delete();
        rethrow;
      }
    } finally {
      _saving.remove(scopeId);
    }
  }

  Future<File> fileFor(OfflinePhoto photo) async {
    final items = await list();
    if (!items.any(
      (p) =>
          p.remotePath == photo.remotePath &&
          p.fileName == photo.fileName &&
          p.sha256 == photo.sha256,
    )) {
      throw StateError('该照片不属于当前账号和存储位置的离线库');
    }
    final file = File(
      '${(await _dir()).path}${Platform.pathSeparator}${photo.fileName}',
    );
    if ((await sha256.bind(file.openRead()).first).toString() != photo.sha256) {
      throw const FormatException('离线照片校验失败，请删除后重新保存');
    }
    return file;
  }

  Future<void> remove(OfflinePhoto photo) async {
    if (_saving.contains(scopeId)) {
      throw StateError('正在保存照片，无法删除离线库');
    }
    final listNow = await list();
    if (!listNow.any(
      (p) => p.fileName == photo.fileName && p.remotePath == photo.remotePath,
    )) {
      return;
    }
    final file = File(
      '${(await _dir()).path}${Platform.pathSeparator}${photo.fileName}',
    );
    if (await file.exists()) await file.delete();
    await _write(listNow.where((p) => p.fileName != photo.fileName).toList());
  }

  Future<void> clear() async {
    if (_saving.contains(scopeId)) throw StateError('正在保存照片，不能清空');
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
    // A cleared root should not reappear as an empty location in the
    // cold-start offline picker. Other root identities must be retained.
    final existing = await savedLocations(
      api: api,
      accountId: _accountId,
      applicationDirectory: applicationDirectory,
    );
    final retained = existing
        .where((s) => s.identity != _rootIdentity)
        .toList();
    if (retained.length == existing.length) return;
    final file = await _profileFile(api, _accountId, applicationDirectory);
    final replacement = File('${file.path}.new');
    try {
      await replacement.writeAsString(
        jsonEncode({
          'version': 1,
          'roots': retained
              .map(
                (s) => {
                  'id': s.root?.id ?? '',
                  'generation': s.root?.generation ?? 0,
                  'name': s.name,
                },
              )
              .toList(),
        }),
        flush: true,
      );
      await replacement.rename(file.path);
    } finally {
      if (await replacement.exists()) await replacement.delete();
    }
  }
}

class OfflinePhotoSource {
  const OfflinePhotoSource({required this.name, this.root});
  final String name;
  final LightIsleRoot? root;
  String get identity => root?.identity ?? 'default';
}

class OfflinePhoto {
  const OfflinePhoto({
    required this.fileName,
    required this.remotePath,
    required this.title,
    required this.size,
    required this.savedAt,
    required this.sha256,
  });
  final String fileName;
  final String remotePath;
  final String title;
  final int size;
  final DateTime savedAt;
  final String sha256;

  bool get previewable {
    final ext = fileName.split('.').last;
    return {'jpg', 'jpeg', 'png', 'gif', 'webp'}.contains(ext);
  }

  OfflinePhoto withDigest(String digest) => OfflinePhoto(
    fileName: fileName,
    remotePath: remotePath,
    title: title,
    size: size,
    savedAt: savedAt,
    sha256: digest,
  );
  Map<String, Object> toJson() => {
    'fileName': fileName,
    'remotePath': remotePath,
    'title': title,
    'size': size,
    'savedAt': savedAt.toIso8601String(),
    'sha256': sha256,
  };
  factory OfflinePhoto.fromJson(Map source) {
    final name = source['fileName'];
    final path = source['remotePath'];
    final title = source['title'];
    final size = source['size'];
    final saved = DateTime.tryParse(source['savedAt']?.toString() ?? '');
    final digest = source['sha256'];
    if (name is! String ||
        !OfflinePhotoStore._safeFile.hasMatch(name) ||
        !OfflinePhotoStore.extensions.contains(name.split('.').last) ||
        path is! String ||
        path.isEmpty ||
        title is! String ||
        title.isEmpty ||
        size is! int ||
        size < 1 ||
        size > OfflinePhotoStore.maxPhotoBytes ||
        saved == null ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('无效离线照片记录');
    }
    return OfflinePhoto(
      fileName: name,
      remotePath: path,
      title: title,
      size: size,
      savedAt: saved,
      sha256: digest,
    );
  }
}
