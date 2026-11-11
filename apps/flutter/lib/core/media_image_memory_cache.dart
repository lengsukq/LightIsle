import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'isle_cache_manager.dart';
import 'lightisle_api.dart';

/// A bounded, in-memory (and optionally disk-backed) cache owned by a media
/// viewing session or shared via [IsleCacheManager].
class MediaImageMemoryCache {
  MediaImageMemoryCache({
    this.maxBytes = 96 * 1024 * 1024,
    this.maxEntries = 1000,
    this.category = IsleCacheCategory.thumbnails,
    this.enableDiskPersistence = false,
    this.registerInCategoryStats = true,
  }) : assert(maxBytes > 0),
       assert(maxEntries > 0) {
    if (registerInCategoryStats) {
      IsleCacheManager.instance.registerImageCache(category, this);
    }
  }

  final int maxBytes;
  final int maxEntries;
  final IsleCacheCategory category;
  final bool enableDiskPersistence;
  final bool registerInCategoryStats;
  final LinkedHashMap<_MediaImageKey, Uint8List> _entries =
      LinkedHashMap<_MediaImageKey, Uint8List>();
  final Map<String, _MediaImageKey> _diskKeyIndex = <String, _MediaImageKey>{};
  final Map<_MediaImageKey, Future<Uint8List>> _inFlight = {};
  int _usedBytes = 0;
  bool _disposed = false;

  int get usedBytes => _usedBytes;
  int get entryCount => _entries.length;

  _MediaImageKey _key(
    LightIsleApi api,
    String path,
    Map<String, String>? query,
    int maxResponseBytes,
  ) => _MediaImageKey(
    IsleCacheManager.scopeKeyFor(api),
    path,
    Uri(queryParameters: SplayTreeMap<String, String>.of(query ?? {})).query,
    maxResponseBytes,
  );

  Uint8List? get(
    LightIsleApi api,
    String path,
    Map<String, String>? query,
    int maxResponseBytes,
  ) {
    if (_disposed) return null;
    final key = _key(api, path, query, maxResponseBytes);
    final bytes = _entries.remove(key);
    if (bytes != null) _entries[key] = bytes; // Most recently accessed.
    return bytes;
  }

  /// Looks up L1 memory bytes by raw disk key without duplicating into buckets.
  Uint8List? getByDiskKey(String rawDiskKey) {
    if (_disposed) return null;
    final key = _diskKeyIndex[rawDiskKey];
    if (key == null) return null;
    final bytes = _entries.remove(key);
    if (bytes != null) _entries[key] = bytes;
    return bytes;
  }

  String _diskKey(_MediaImageKey key) =>
      '${key.scopeKey}|${key.path}|${key.query}|${key.maxResponseBytes}';

  void _storeInMemory(_MediaImageKey key, Uint8List bytes) {
    if (_disposed || bytes.isEmpty || bytes.lengthInBytes > maxBytes) return;
    final old = _entries.remove(key);
    if (old != null) _usedBytes -= old.lengthInBytes;
    while (_entries.isNotEmpty &&
        (_entries.length >= maxEntries ||
            _usedBytes + bytes.lengthInBytes > maxBytes)) {
      final oldestKey = _entries.keys.first;
      _diskKeyIndex.remove(_diskKey(oldestKey));
      _usedBytes -= _entries.remove(oldestKey)!.lengthInBytes;
    }
    _entries[key] = bytes;
    _diskKeyIndex[_diskKey(key)] = key;
    _usedBytes += bytes.lengthInBytes;
  }

  Future<Uint8List> load(
    LightIsleApi api,
    String path,
    Map<String, String>? query,
    int maxResponseBytes,
    Future<Uint8List> Function() fetch,
  ) {
    if (_disposed) return Future.error(StateError('图片会话已关闭'));
    final key = _key(api, path, query, maxResponseBytes);
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return Future.value(cached);
    }
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final diskKey = _diskKey(key);
    final checkDisk =
        enableDiskPersistence &&
        IsleCacheManager.instance.hasDiskCacheConfigured;
    // Retain an in-progress request even if its original image widget is
    // disposed while the user quickly swipes to another page.
    late final Future<Uint8List> pending;
    if (!checkDisk) {
      pending = Future<Uint8List>.sync(fetch)
          .then((bytes) {
            _storeInMemory(key, bytes);
            return bytes;
          })
          .whenComplete(() {
            if (identical(_inFlight[key], pending)) _inFlight.remove(key);
          });
      _inFlight[key] = pending;
      return pending;
    }

    pending =
        () async {
          final diskBytes = await IsleCacheManager.instance.getBytes(
            category,
            diskKey,
          );
          if (diskBytes != null && diskBytes.isNotEmpty) {
            _storeInMemory(key, diskBytes);
            return diskBytes;
          }
          final bytes = await Future<Uint8List>.sync(fetch);
          _storeInMemory(key, bytes);
          if (!_disposed && bytes.isNotEmpty) {
            unawaited(
              IsleCacheManager.instance.putBytes(category, diskKey, bytes),
            );
          }
          return bytes;
        }().whenComplete(() {
          if (identical(_inFlight[key], pending)) _inFlight.remove(key);
        });
    _inFlight[key] = pending;
    return pending;
  }

  void invalidate(
    LightIsleApi api,
    String path,
    Map<String, String>? query,
    int maxResponseBytes,
  ) {
    final key = _key(api, path, query, maxResponseBytes);
    final old = _entries.remove(key);
    if (old != null) _usedBytes -= old.lengthInBytes;
    final diskKey = _diskKey(key);
    _diskKeyIndex.remove(diskKey);
    if (enableDiskPersistence) {
      unawaited(IsleCacheManager.instance.remove(category, diskKey));
    }
  }

  void clear() {
    _entries.clear();
    _diskKeyIndex.clear();
    _usedBytes = 0;
  }

  void dispose() {
    _disposed = true;
    if (registerInCategoryStats) {
      IsleCacheManager.instance.unregisterImageCache(category, this);
    }
    _entries.clear();
    _diskKeyIndex.clear();
    _inFlight.clear();
    _usedBytes = 0;
  }
}

class _MediaImageKey {
  const _MediaImageKey(
    this.scopeKey,
    this.path,
    this.query,
    this.maxResponseBytes,
  );

  final String scopeKey;
  final String path;
  final String query;
  final int maxResponseBytes;

  @override
  bool operator ==(Object other) =>
      other is _MediaImageKey &&
      scopeKey == other.scopeKey &&
      path == other.path &&
      query == other.query &&
      maxResponseBytes == other.maxResponseBytes;

  @override
  int get hashCode => Object.hash(scopeKey, path, query, maxResponseBytes);
}
