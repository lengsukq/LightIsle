import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'lightisle_api.dart';
import 'media_image_memory_cache.dart';

/// Four primary client cache categories managed by LightIsle.
enum IsleCacheCategory {
  thumbnails(
    id: 'thumbnails',
    label: '相册与文件缩略图',
    subtitle: '照片网格、相册封面、大图预览及文件列表缩略图',
    maxMemoryBytes: 96 * 1024 * 1024,
    maxMemoryEntries: 1200,
    maxDiskBytes: 512 * 1024 * 1024,
    maxDiskEntries: 6000,
  ),
  posters(
    id: 'posters',
    label: '影视海报与剧照',
    subtitle: '影视巨幕、海报墙、剧集封面、历史记录与详情海报',
    maxMemoryBytes: 64 * 1024 * 1024,
    maxMemoryEntries: 600,
    maxDiskBytes: 256 * 1024 * 1024,
    maxDiskEntries: 3000,
  ),
  mapTiles(
    id: 'map_tiles',
    label: '足迹地图与瓦片',
    subtitle: '天地图、OpenStreetMap 与自定义底图瓦片及聚合预览',
    maxMemoryBytes: 48 * 1024 * 1024,
    maxMemoryEntries: 500,
    maxDiskBytes: 256 * 1024 * 1024,
    maxDiskEntries: 5000,
  ),
  metadata(
    id: 'metadata',
    label: '页面列表与元数据快照',
    subtitle: '相册筛选视图、影视分类列表、足迹坐标点与目录速览快照',
    maxMemoryBytes: 16 * 1024 * 1024,
    maxMemoryEntries: 400,
    maxDiskBytes: 32 * 1024 * 1024,
    maxDiskEntries: 800,
  );

  const IsleCacheCategory({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.maxMemoryBytes,
    required this.maxMemoryEntries,
    required this.maxDiskBytes,
    required this.maxDiskEntries,
  });

  final String id;
  final String label;
  final String subtitle;
  final int maxMemoryBytes;
  final int maxMemoryEntries;
  final int maxDiskBytes;
  final int maxDiskEntries;
}

class IsleCacheCategoryStats {
  const IsleCacheCategoryStats({
    required this.category,
    required this.memoryBytes,
    required this.memoryEntries,
    required this.diskBytes,
    required this.diskEntries,
  });

  final IsleCacheCategory category;
  final int memoryBytes;
  final int memoryEntries;
  final int diskBytes;
  final int diskEntries;

  int get effectiveBytes => diskBytes > memoryBytes ? diskBytes : memoryBytes;
  int get effectiveEntries =>
      diskEntries > memoryEntries ? diskEntries : memoryEntries;
}

class IsleCacheReport {
  const IsleCacheReport({
    required this.categories,
    this.offlinePhotoBytes = 0,
    this.offlinePhotoCount = 0,
    this.offlineVideoBytes = 0,
    this.offlineVideoCount = 0,
  });

  final Map<IsleCacheCategory, IsleCacheCategoryStats> categories;
  final int offlinePhotoBytes;
  final int offlinePhotoCount;
  final int offlineVideoBytes;
  final int offlineVideoCount;

  int get totalTemporaryBytes =>
      categories.values.fold<int>(0, (sum, item) => sum + item.effectiveBytes);

  int get totalTemporaryEntries => categories.values.fold<int>(
    0,
    (sum, item) => sum + item.effectiveEntries,
  );

  int get totalOfflineBytes => offlinePhotoBytes + offlineVideoBytes;
  int get totalAllBytes => totalTemporaryBytes + totalOfflineBytes;
}

class _BucketStore {
  _BucketStore(this.category);

  final IsleCacheCategory category;
  final LinkedHashMap<String, Uint8List> memory =
      LinkedHashMap<String, Uint8List>();
  int memoryBytes = 0;

  Uint8List? getMemory(String key) {
    final value = memory.remove(key);
    if (value != null) {
      memory[key] = value;
    }
    return value;
  }

  void putMemory(String key, Uint8List bytes) {
    if (bytes.isEmpty || bytes.lengthInBytes > category.maxMemoryBytes) {
      return;
    }
    final old = memory.remove(key);
    if (old != null) {
      memoryBytes -= old.lengthInBytes;
    }
    while (memory.isNotEmpty &&
        (memory.length >= category.maxMemoryEntries ||
            memoryBytes + bytes.lengthInBytes > category.maxMemoryBytes)) {
      final oldestKey = memory.keys.first;
      final removed = memory.remove(oldestKey);
      if (removed != null) {
        memoryBytes -= removed.lengthInBytes;
      }
    }
    memory[key] = bytes;
    memoryBytes += bytes.lengthInBytes;
  }

  void removeMemory(String key) {
    final old = memory.remove(key);
    if (old != null) {
      memoryBytes -= old.lengthInBytes;
      if (memoryBytes < 0) memoryBytes = 0;
    }
  }

  void clearMemory() {
    memory.clear();
    memoryBytes = 0;
  }
}

/// Unified L1 memory + L2 local disk cache manager for the Flutter client.
class IsleCacheManager extends ChangeNotifier {
  IsleCacheManager._() {
    for (final cat in IsleCacheCategory.values) {
      _buckets[cat] = _BucketStore(cat);
    }
  }

  static final IsleCacheManager instance = IsleCacheManager._();

  final Map<IsleCacheCategory, _BucketStore> _buckets = {};
  final Map<IsleCacheCategory, Set<MediaImageMemoryCache>> _imageCaches = {
    for (final cat in IsleCacheCategory.values) cat: <MediaImageMemoryCache>{},
  };

  static final bool _isFlutterTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  Directory? _overrideDiskRoot;
  Directory? _resolvedDiskRoot;
  bool _diskProbeFailed = false;
  bool _diskProbeInFlight = false;

  late final MediaImageMemoryCache sharedThumbnails = MediaImageMemoryCache(
    maxBytes: IsleCacheCategory.thumbnails.maxMemoryBytes,
    maxEntries: IsleCacheCategory.thumbnails.maxMemoryEntries,
    category: IsleCacheCategory.thumbnails,
    enableDiskPersistence: true,
  );

  late final MediaImageMemoryCache sharedPosters = MediaImageMemoryCache(
    maxBytes: IsleCacheCategory.posters.maxMemoryBytes,
    maxEntries: IsleCacheCategory.posters.maxMemoryEntries,
    category: IsleCacheCategory.posters,
    enableDiskPersistence: true,
  );

  MediaImageMemoryCache imageCacheForPath(String path) {
    final normalized = path.toLowerCase();
    if (normalized.contains('/cinema/') || normalized.contains('/poster')) {
      return sharedPosters;
    }
    return sharedThumbnails;
  }

  @visibleForTesting
  void setDiskRootForTesting(Directory? dir) {
    _overrideDiskRoot = dir;
    _resolvedDiskRoot = dir;
    _diskProbeFailed = false;
  }

  void registerImageCache(
    IsleCacheCategory category,
    MediaImageMemoryCache cache,
  ) {
    _imageCaches[category]?.add(cache);
  }

  void unregisterImageCache(
    IsleCacheCategory category,
    MediaImageMemoryCache cache,
  ) {
    _imageCaches[category]?.remove(cache);
  }

  static String scopeKeyFor(LightIsleApi api, [String extraScope = '']) {
    final session = identityHashCode(api);
    final origin = api.uri('/').origin;
    final cert = api.certificateFingerprint ?? '';
    final rootId = api.selectedRoot?.identity ?? 'default';
    return '$session|$origin|$cert|$rootId|$extraScope';
  }

  static String _hashKey(String rawKey) =>
      sha256.convert(utf8.encode(rawKey)).toString();

  void _warmDiskRootIfNeeded() {
    if (_isFlutterTest ||
        _overrideDiskRoot != null ||
        _resolvedDiskRoot != null ||
        _diskProbeFailed ||
        _diskProbeInFlight) {
      return;
    }
    _diskProbeInFlight = true;
    getApplicationSupportDirectory()
        .then((dir) {
          _resolvedDiskRoot = dir;
        })
        .catchError((_) {
          _diskProbeFailed = true;
        })
        .whenComplete(() {
          _diskProbeInFlight = false;
        });
  }

  Directory? _categoryDiskDirSync(IsleCacheCategory category) {
    final base = _overrideDiskRoot ?? (_isFlutterTest ? null : _resolvedDiskRoot);
    if (base == null) {
      _warmDiskRootIfNeeded();
      return null;
    }
    try {
      final dir = Directory(
        '${base.path}${Platform.pathSeparator}'
        'isle_cache_v2${Platform.pathSeparator}${category.id}',
      );
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _categoryDiskDir(IsleCacheCategory category) async {
    final syncDir = _categoryDiskDirSync(category);
    if (syncDir != null) return syncDir;
    if (_isFlutterTest || _diskProbeFailed) return null;
    try {
      _resolvedDiskRoot ??= await getApplicationSupportDirectory();
      return _categoryDiskDirSync(category);
    } catch (_) {
      _diskProbeFailed = true;
      return null;
    }
  }

  /// Synchronous L1 memory lookup.
  Uint8List? getMemoryBytes(IsleCacheCategory category, String key) {
    return _buckets[category]?.getMemory(key);
  }

  /// Synchronous L1 memory + L2 disk lookup when disk root is ready.
  Uint8List? getBytesSync(
    IsleCacheCategory category,
    String key, {
    bool checkDisk = true,
  }) {
    final mem = _buckets[category]?.getMemory(key);
    if (mem != null) return mem;
    if (!checkDisk) return null;
    try {
      final dir = _categoryDiskDirSync(category);
      if (dir == null) return null;
      final hashed = _hashKey(key);
      final file = File('${dir.path}${Platform.pathSeparator}$hashed.bin');
      if (!file.existsSync()) return null;
      final data = file.readAsBytesSync();
      if (data.isEmpty) {
        try {
          file.deleteSync();
        } catch (_) {}
        return null;
      }
      _buckets[category]?.putMemory(key, data);
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Store bytes in L1 memory and (optionally) L2 disk cache.
  Future<void> putBytes(
    IsleCacheCategory category,
    String key,
    Uint8List bytes, {
    bool persistToDisk = true,
  }) async {
    if (bytes.isEmpty) return;
    _buckets[category]?.putMemory(key, bytes);
    if (!persistToDisk) return;
    try {
      final dir = await _categoryDiskDir(category);
      if (dir == null) return;
      final hashed = _hashKey(key);
      final file = File('${dir.path}${Platform.pathSeparator}$hashed.bin');
      file.writeAsBytesSync(bytes, flush: false);
    } catch (_) {
      // Ignore disk write errors; memory cache still serves the session.
    }
  }

  /// Read bytes from L1 memory or L2 disk cache.
  Future<Uint8List?> getBytes(
    IsleCacheCategory category,
    String key, {
    bool checkDisk = true,
  }) async {
    final mem = _buckets[category]?.getMemory(key);
    if (mem != null) return mem;
    if (!checkDisk) return null;
    try {
      final dir = await _categoryDiskDir(category);
      if (dir == null) return null;
      final hashed = _hashKey(key);
      final file = File('${dir.path}${Platform.pathSeparator}$hashed.bin');
      if (!file.existsSync()) return null;
      final data = file.readAsBytesSync();
      if (data.isEmpty) {
        try {
          file.deleteSync();
        } catch (_) {}
        return null;
      }
      _buckets[category]?.putMemory(key, data);
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(IsleCacheCategory category, String key) async {
    _buckets[category]?.removeMemory(key);
    try {
      final dir = await _categoryDiskDir(category);
      if (dir == null) return;
      final hashed = _hashKey(key);
      final file = File('${dir.path}${Platform.pathSeparator}$hashed.bin');
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  /// Inspect current memory and disk usage across all 4 categories.
  Future<IsleCacheReport> inspect({
    int offlinePhotoBytes = 0,
    int offlinePhotoCount = 0,
    int offlineVideoBytes = 0,
    int offlineVideoCount = 0,
  }) async {
    final stats = <IsleCacheCategory, IsleCacheCategoryStats>{};
    for (final cat in IsleCacheCategory.values) {
      final bucket = _buckets[cat]!;
      var memBytes = bucket.memoryBytes;
      var memEntries = bucket.memory.length;
      final registered = _imageCaches[cat];
      if (registered != null) {
        for (final imgCache in registered) {
          memBytes += imgCache.usedBytes;
          memEntries += imgCache.entryCount;
        }
      }
      var diskBytes = 0;
      var diskEntries = 0;
      try {
        final dir = await _categoryDiskDir(cat);
        if (dir != null && dir.existsSync()) {
          for (final entity in dir.listSync(followLinks: false)) {
            if (entity is File && entity.path.endsWith('.bin')) {
              final stat = entity.statSync();
              if (stat.size > 0) {
                diskBytes += stat.size;
                diskEntries++;
              }
            }
          }
        }
      } catch (_) {}
      stats[cat] = IsleCacheCategoryStats(
        category: cat,
        memoryBytes: memBytes,
        memoryEntries: memEntries,
        diskBytes: diskBytes,
        diskEntries: diskEntries,
      );
    }
    return IsleCacheReport(
      categories: stats,
      offlinePhotoBytes: offlinePhotoBytes,
      offlinePhotoCount: offlinePhotoCount,
      offlineVideoBytes: offlineVideoBytes,
      offlineVideoCount: offlineVideoCount,
    );
  }

  /// Clear selected cache categories from both L1 memory and L2 disk.
  Future<void> clearCategories(Set<IsleCacheCategory> categories) async {
    for (final cat in categories) {
      _buckets[cat]?.clearMemory();
      final registered = _imageCaches[cat];
      if (registered != null) {
        for (final imgCache in registered.toList()) {
          imgCache.clear();
        }
      }
      try {
        final dir = await _categoryDiskDir(cat);
        if (dir != null && dir.existsSync()) {
          for (final entity in dir.listSync(followLinks: false)) {
            if (entity is File) {
              try {
                entity.deleteSync();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> clearAllTemporary() =>
      clearCategories(IsleCacheCategory.values.toSet());
}
