import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'isle_data_cache.dart';
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

class _DiskFileMeta {
  _DiskFileMeta(this.size, this.modifiedMs);

  int size;
  int modifiedMs;
}

class _DiskCategoryIndex {
  final LinkedHashMap<String, _DiskFileMeta> files =
      LinkedHashMap<String, _DiskFileMeta>();
  int totalBytes = 0;
  bool initialized = false;

  void clear() {
    files.clear();
    totalBytes = 0;
    initialized = false;
  }
}

/// Unified L1 memory + L2 local disk cache manager for the Flutter client.
class IsleCacheManager extends ChangeNotifier {
  IsleCacheManager._() {
    for (final cat in IsleCacheCategory.values) {
      _buckets[cat] = _BucketStore(cat);
      _diskIndexes[cat] = _DiskCategoryIndex();
    }
  }

  static final IsleCacheManager instance = IsleCacheManager._();

  final Map<IsleCacheCategory, _BucketStore> _buckets = {};
  final Map<IsleCacheCategory, _DiskCategoryIndex> _diskIndexes = {};
  final Map<IsleCacheCategory, Future<void>> _diskChains = {};
  final Map<IsleCacheCategory, Set<MediaImageMemoryCache>> _imageCaches = {
    for (final cat in IsleCacheCategory.values) cat: <MediaImageMemoryCache>{},
  };

  static final bool _isFlutterTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  /// Thumbnails and posters keep bytes exclusively in [MediaImageMemoryCache]
  /// (`sharedThumbnails` / `sharedPosters`), avoiding 2x RAM & 2x reporting.
  static bool _usesBucketMemory(IsleCacheCategory category) =>
      category != IsleCacheCategory.thumbnails &&
      category != IsleCacheCategory.posters;

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

  /// Dedicated small memory-only cache for full-resolution viewer originals so
  /// 20-64 MiB originals never evict thumbnails or pollute L2 disk cache.
  late final MediaImageMemoryCache sharedOriginals = MediaImageMemoryCache(
    maxBytes: 48 * 1024 * 1024,
    maxEntries: 3,
    category: IsleCacheCategory.thumbnails,
    enableDiskPersistence: false,
    registerInCategoryStats: false,
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
    _diskChains.clear();
    for (final idx in _diskIndexes.values) {
      idx.clear();
    }
  }

  /// Whether an L2 disk directory is configured or discoverable.
  bool get hasDiskCacheConfigured =>
      _overrideDiskRoot != null || (!_isFlutterTest && !_diskProbeFailed);

  @visibleForTesting
  Future<void> flushDiskQueueForTesting() =>
      Future.wait(_diskChains.values.toList());

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

  /// Deterministic, collision-safe scope string that survives cold restarts
  /// for the same session while isolating user switches, origins, pins & roots.
  static String scopeKeyFor(LightIsleApi api, [String extraScope = '']) {
    final session = api.cacheScopeId;
    final origin = api.uri('/').origin;
    final cert = api.certificateFingerprint ?? '';
    final rootId = api.selectedRoot?.identity ?? 'default';
    return '$session|$origin|$cert|$rootId|$extraScope';
  }

  static String _hashKey(String rawKey) =>
      sha256.convert(utf8.encode(rawKey)).toString();

  // Production runs 100% async dart:io; under FLUTTER_TEST, WidgetTester's
  // FakeAsync zone intercepts timers/microtasks and deadlocks real OS I/O
  // futures unless synchronous fallbacks are used in tests.
  static Future<bool> _dirExists(Directory d) =>
      _isFlutterTest ? Future<bool>.value(d.existsSync()) : d.exists();
  static Future<void> _dirCreate(Directory d) async => _isFlutterTest
      ? d.createSync(recursive: true)
      : await d.create(recursive: true);
  static Future<List<FileSystemEntity>> _dirList(Directory d) => _isFlutterTest
      ? Future<List<FileSystemEntity>>.value(d.listSync(followLinks: false))
      : d.list(followLinks: false).toList();
  static Future<bool> _fileExists(File f) =>
      _isFlutterTest ? Future<bool>.value(f.existsSync()) : f.exists();
  static Future<Uint8List> _fileRead(File f) => _isFlutterTest
      ? Future<Uint8List>.value(f.readAsBytesSync())
      : f.readAsBytes();
  static Future<void> _fileWrite(File f, Uint8List bytes) async =>
      _isFlutterTest
      ? f.writeAsBytesSync(bytes, flush: false)
      : await f.writeAsBytes(bytes, flush: false);
  static Future<FileStat> _fileStat(File f) =>
      _isFlutterTest ? Future<FileStat>.value(f.statSync()) : f.stat();
  static Future<void> _fileDelete(File f) async =>
      _isFlutterTest ? f.deleteSync() : await f.delete();

  Future<T> _serializeDisk<T>(
    IsleCacheCategory category,
    Future<T> Function() action,
  ) {
    final previous = _diskChains[category] ?? Future<void>.value();
    final completer = Completer<T>();
    final next = previous.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _diskChains[category] = next;
    return completer.future;
  }

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
        .catchError((Object _) {
          _diskProbeFailed = true;
        })
        .whenComplete(() {
          _diskProbeInFlight = false;
        });
  }

  Directory? _categoryDiskDirPath(IsleCacheCategory category) {
    final base =
        _overrideDiskRoot ?? (_isFlutterTest ? null : _resolvedDiskRoot);
    if (base == null) {
      _warmDiskRootIfNeeded();
      return null;
    }
    return Directory(
      '${base.path}${Platform.pathSeparator}'
      'isle_cache_v2${Platform.pathSeparator}${category.id}',
    );
  }

  Future<Directory?> _categoryDiskDir(IsleCacheCategory category) async {
    var dir = _categoryDiskDirPath(category);
    if (dir == null) {
      if (_isFlutterTest || _diskProbeFailed) return null;
      try {
        _resolvedDiskRoot ??= await getApplicationSupportDirectory();
        dir = _categoryDiskDirPath(category);
      } catch (_) {
        _diskProbeFailed = true;
        return null;
      }
    }
    if (dir == null) return null;
    try {
      if (!await _dirExists(dir)) {
        await _dirCreate(dir);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureDiskIndexLoaded(
    IsleCacheCategory category,
    Directory dir,
  ) async {
    final idx = _diskIndexes[category]!;
    if (idx.initialized) return;
    idx.clear();
    final discovered = <(String, int, int)>[];
    try {
      if (await _dirExists(dir)) {
        for (final entity in await _dirList(dir)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.isEmpty
              ? ''
              : entity.uri.pathSegments.last;
          final validBin = RegExp(r'^[a-f0-9]{64}\.bin$').hasMatch(name);
          if (!validBin) {
            try {
              await _fileDelete(entity);
            } catch (_) {}
            continue;
          }
          try {
            final stat = await _fileStat(entity);
            if (stat.size <= 0 || stat.size > category.maxDiskBytes) {
              await _fileDelete(entity);
              continue;
            }
            discovered.add((
              name,
              stat.size,
              stat.modified.millisecondsSinceEpoch,
            ));
          } catch (_) {}
        }
      }
    } catch (_) {}
    discovered.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (name, size, modifiedMs) in discovered) {
      idx.files[name] = _DiskFileMeta(size, modifiedMs);
      idx.totalBytes += size;
    }
    idx.initialized = true;
    await _enforceDiskBudget(category, dir, idx);
  }

  Future<void> _enforceDiskBudget(
    IsleCacheCategory category,
    Directory dir,
    _DiskCategoryIndex idx,
  ) async {
    while (idx.files.isNotEmpty &&
        (idx.files.length > category.maxDiskEntries ||
            idx.totalBytes > category.maxDiskBytes)) {
      final oldestName = idx.files.keys.first;
      final removed = idx.files.remove(oldestName);
      if (removed != null) {
        idx.totalBytes -= removed.size;
        if (idx.totalBytes < 0) idx.totalBytes = 0;
      }
      try {
        final victim = File('${dir.path}${Platform.pathSeparator}$oldestName');
        if (await _fileExists(victim)) {
          await _fileDelete(victim);
        }
      } catch (_) {}
    }
  }

  /// Asynchronously prunes orphaned/zero-byte files and enforces disk LRU caps
  /// inside `isle_cache_v2/*` on startup without touching offline media stores.
  Future<void> pruneOrphanedDiskFiles() async {
    for (final cat in IsleCacheCategory.values) {
      await _serializeDisk(cat, () async {
        final dir = await _categoryDiskDir(cat);
        if (dir == null) return;
        _diskIndexes[cat]!.initialized = false;
        await _ensureDiskIndexLoaded(cat, dir);
      });
    }
  }

  Uint8List? _lookupImageMemoryByKey(IsleCacheCategory category, String key) {
    if (category == IsleCacheCategory.thumbnails) {
      return sharedThumbnails.getByDiskKey(key);
    }
    if (category == IsleCacheCategory.posters) {
      return sharedPosters.getByDiskKey(key);
    }
    return null;
  }

  /// Synchronous L1 memory lookup.
  Uint8List? getMemoryBytes(IsleCacheCategory category, String key) {
    if (!_usesBucketMemory(category)) {
      return _lookupImageMemoryByKey(category, key);
    }
    return _buckets[category]?.getMemory(key);
  }

  /// Synchronous L1 memory + L2 disk lookup when disk root is already warmed.
  Uint8List? getBytesSync(
    IsleCacheCategory category,
    String key, {
    bool checkDisk = true,
  }) {
    final mem = getMemoryBytes(category, key);
    if (mem != null) return mem;
    if (!checkDisk) return null;
    try {
      final dir = _categoryDiskDirPath(category);
      if (dir == null || !dir.existsSync()) return null;
      final hashed = _hashKey(key);
      final file = File('${dir.path}${Platform.pathSeparator}$hashed.bin');
      if (!file.existsSync()) return null;
      final data = file.readAsBytesSync();
      if (data.isEmpty) return null;
      if (_usesBucketMemory(category)) {
        _buckets[category]?.putMemory(key, data);
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Store bytes in L1 memory (for bucket-backed categories) and L2 disk cache.
  Future<void> putBytes(
    IsleCacheCategory category,
    String key,
    Uint8List bytes, {
    bool persistToDisk = true,
    bool skipMemoryBucket = false,
  }) async {
    if (bytes.isEmpty) return;
    if (!skipMemoryBucket && _usesBucketMemory(category)) {
      _buckets[category]?.putMemory(key, bytes);
    }
    if (!persistToDisk || bytes.lengthInBytes > category.maxDiskBytes) return;
    await _serializeDisk(category, () async {
      try {
        final dir = await _categoryDiskDir(category);
        if (dir == null) return;
        await _ensureDiskIndexLoaded(category, dir);
        final fileName = '${_hashKey(key)}.bin';
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        await _fileWrite(file, bytes);
        final idx = _diskIndexes[category]!;
        final prev = idx.files.remove(fileName);
        if (prev != null) {
          idx.totalBytes -= prev.size;
        }
        idx.files[fileName] = _DiskFileMeta(
          bytes.lengthInBytes,
          DateTime.now().millisecondsSinceEpoch,
        );
        idx.totalBytes += bytes.lengthInBytes;
        await _enforceDiskBudget(category, dir, idx);
      } catch (_) {
        // Ignore disk write errors; memory cache still serves the session.
      }
    });
  }

  /// Read bytes from L1 memory or L2 disk cache asynchronously.
  Future<Uint8List?> getBytes(
    IsleCacheCategory category,
    String key, {
    bool checkDisk = true,
  }) async {
    final mem = getMemoryBytes(category, key);
    if (mem != null) return mem;
    if (!checkDisk) return null;
    return _serializeDisk(category, () async {
      try {
        final dir = await _categoryDiskDir(category);
        if (dir == null) return null;
        await _ensureDiskIndexLoaded(category, dir);
        final fileName = '${_hashKey(key)}.bin';
        final idx = _diskIndexes[category]!;
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        if (!await _fileExists(file)) {
          final stale = idx.files.remove(fileName);
          if (stale != null) idx.totalBytes -= stale.size;
          return null;
        }
        final data = await _fileRead(file);
        if (data.isEmpty) {
          final stale = idx.files.remove(fileName);
          if (stale != null) idx.totalBytes -= stale.size;
          try {
            await _fileDelete(file);
          } catch (_) {}
          return null;
        }
        final existingMeta = idx.files.remove(fileName);
        if (existingMeta != null) {
          existingMeta.modifiedMs = DateTime.now().millisecondsSinceEpoch;
          idx.files[fileName] = existingMeta;
        }
        if (_usesBucketMemory(category)) {
          _buckets[category]?.putMemory(key, data);
        }
        return data;
      } catch (_) {
        return null;
      }
    });
  }

  Future<void> remove(IsleCacheCategory category, String key) async {
    if (_usesBucketMemory(category)) {
      _buckets[category]?.removeMemory(key);
    }
    await _serializeDisk(category, () async {
      try {
        final dir = await _categoryDiskDir(category);
        if (dir == null) return;
        final fileName = '${_hashKey(key)}.bin';
        final idx = _diskIndexes[category]!;
        final removed = idx.files.remove(fileName);
        if (removed != null) {
          idx.totalBytes -= removed.size;
          if (idx.totalBytes < 0) idx.totalBytes = 0;
        }
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        if (await _fileExists(file)) {
          await _fileDelete(file);
        }
      } catch (_) {}
    });
  }

  /// Inspect current memory and disk usage across all 4 categories cleanly
  /// without double-counting L1 image caches or blocking on sync disk stats.
  Future<IsleCacheReport> inspect({
    int offlinePhotoBytes = 0,
    int offlinePhotoCount = 0,
    int offlineVideoBytes = 0,
    int offlineVideoCount = 0,
  }) async {
    final stats = <IsleCacheCategory, IsleCacheCategoryStats>{};
    for (final cat in IsleCacheCategory.values) {
      var memBytes = 0;
      var memEntries = 0;
      if (_usesBucketMemory(cat)) {
        final bucket = _buckets[cat]!;
        memBytes += bucket.memoryBytes;
        memEntries += bucket.memory.length;
      }
      if (cat == IsleCacheCategory.metadata) {
        memBytes += IsleDataCache.instance.memoryBytes;
        memEntries += IsleDataCache.instance.memoryEntryCount;
      }
      final registered = _imageCaches[cat];
      if (registered != null) {
        for (final imgCache in registered) {
          memBytes += imgCache.usedBytes;
          memEntries += imgCache.entryCount;
        }
      }
      final (diskBytes, diskEntries) = await _serializeDisk(cat, () async {
        try {
          final dir = await _categoryDiskDir(cat);
          if (dir == null) return (0, 0);
          _diskIndexes[cat]!.initialized = false;
          await _ensureDiskIndexLoaded(cat, dir);
          final idx = _diskIndexes[cat]!;
          return (idx.totalBytes, idx.files.length);
        } catch (_) {
          return (0, 0);
        }
      });
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

  /// Clears all L1 memory caches (buckets, image caches, SWR data cache, and
  /// Flutter's decoded [ImageCache]) on logout, account switch, or OS pressure.
  void clearMemoryCaches() {
    for (final bucket in _buckets.values) {
      bucket.clearMemory();
    }
    for (final registered in _imageCaches.values) {
      for (final imgCache in registered.toList()) {
        imgCache.clear();
      }
    }
    sharedOriginals.clear();
    IsleDataCache.instance.clearMemory();
    try {
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.clear();
      imageCache.clearLiveImages();
    } catch (_) {
      // Safe when invoked in pure Dart tests without WidgetsFlutterBinding.
    }
    notifyListeners();
  }

  /// Clear selected cache categories from both L1 memory and L2 disk.
  Future<void> clearCategories(Set<IsleCacheCategory> categories) async {
    for (final cat in categories) {
      _buckets[cat]?.clearMemory();
      if (cat == IsleCacheCategory.metadata) {
        IsleDataCache.instance.clearMemory();
      }
      if (cat == IsleCacheCategory.thumbnails) {
        sharedOriginals.clear();
      }
      final registered = _imageCaches[cat];
      if (registered != null) {
        for (final imgCache in registered.toList()) {
          imgCache.clear();
        }
      }
      await _serializeDisk(cat, () async {
        _diskIndexes[cat]?.clear();
        try {
          final dir = await _categoryDiskDir(cat);
          if (dir != null && await _dirExists(dir)) {
            for (final entity in await _dirList(dir)) {
              if (entity is File) {
                try {
                  await _fileDelete(entity);
                } catch (_) {}
              }
            }
          }
          _diskIndexes[cat]?.initialized = true;
        } catch (_) {}
      });
    }
    notifyListeners();
  }

  Future<void> clearAllTemporary() =>
      clearCategories(IsleCacheCategory.values.toSet());
}
