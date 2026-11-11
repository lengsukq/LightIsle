import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'isle_cache_manager.dart';
import 'lightisle_api.dart';

class _CachedJsonEntry {
  const _CachedJsonEntry(this.value, this.estimatedBytes);

  final Object value;
  final int estimatedBytes;
}

/// Session-scoped Stale-While-Revalidate (SWR) metadata cache.
///
/// When `persistToDisk == false` (the default), entries live directly in a
/// bounded in-memory LRU map without repeated JSON encode/decode round-trips.
class IsleDataCache {
  IsleDataCache._();

  static final IsleDataCache instance = IsleDataCache._();

  final LinkedHashMap<String, _CachedJsonEntry> _memory =
      LinkedHashMap<String, _CachedJsonEntry>();
  int _memoryBytes = 0;

  int get memoryEntryCount => _memory.length;
  int get memoryBytes => _memoryBytes;

  static String _buildKey(LightIsleApi api, String namespace, String subKey) =>
      'swr:${IsleCacheManager.scopeKeyFor(api)}:$namespace:$subKey';

  static Object? _cloneValue(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _cloneValue(entry.value),
      };
    }
    if (value is List) {
      return <dynamic>[for (final item in value) _cloneValue(item)];
    }
    return value;
  }

  static int _estimateBytes(Object? value, [int depth = 0]) {
    if (value == null || value is bool || value is num) return 16;
    if (value is String) return 24 + value.length * 2;
    if (depth > 4) return 64;
    if (value is List) {
      var sum = 32;
      for (final item in value) {
        sum += _estimateBytes(item, depth + 1);
      }
      return sum;
    }
    if (value is Map) {
      var sum = 48;
      for (final entry in value.entries) {
        sum += 24 + entry.key.toString().length * 2;
        sum += _estimateBytes(entry.value, depth + 1);
      }
      return sum;
    }
    return 32;
  }

  void _putMemory(String key, Object cloned, int estBytes) {
    final maxEntries = IsleCacheCategory.metadata.maxMemoryEntries;
    final maxBytes = IsleCacheCategory.metadata.maxMemoryBytes;
    if (estBytes > maxBytes) return;
    final old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.estimatedBytes;
    while (_memory.isNotEmpty &&
        (_memory.length >= maxEntries || _memoryBytes + estBytes > maxBytes)) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey);
      if (removed != null) _memoryBytes -= removed.estimatedBytes;
    }
    _memory[key] = _CachedJsonEntry(cloned, estBytes);
    _memoryBytes += estBytes;
  }

  Object? _getMemory(String key) {
    final hit = _memory.remove(key);
    if (hit == null) return null;
    _memory[key] = hit;
    return _cloneValue(hit.value);
  }

  /// Read a cached JSON map synchronously from L1 memory (with L2 fallback).
  Map<String, dynamic>? getJsonMap(
    LightIsleApi api,
    String namespace,
    String subKey,
  ) {
    final key = _buildKey(api, namespace, subKey);
    final mem = _getMemory(key);
    if (mem is Map<String, dynamic>) return mem;
    final raw = IsleCacheManager.instance.getBytesSync(
      IsleCacheCategory.metadata,
      key,
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      final map = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map ? Map<String, dynamic>.from(decoded) : null);
      if (map != null) {
        final cloned = _cloneValue(map) as Map<String, dynamic>;
        _putMemory(key, cloned, raw.lengthInBytes);
        return _cloneValue(cloned) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Store a JSON map in L1 memory (and optionally L2 disk) under metadata.
  void putJsonMap(
    LightIsleApi api,
    String namespace,
    String subKey,
    Map<String, dynamic> payload, {
    bool persistToDisk = false,
  }) {
    final key = _buildKey(api, namespace, subKey);
    final cloned = _cloneValue(payload) as Map<String, dynamic>;
    _putMemory(key, cloned, _estimateBytes(cloned));
    if (!persistToDisk) return;
    try {
      final encoded = Uint8List.fromList(utf8.encode(jsonEncode(cloned)));
      unawaited(
        IsleCacheManager.instance.putBytes(
          IsleCacheCategory.metadata,
          key,
          encoded,
          persistToDisk: true,
          skipMemoryBucket: true,
        ),
      );
    } catch (_) {}
  }

  /// Read a cached JSON list synchronously from L1 memory (with L2 fallback).
  List<dynamic>? getJsonList(
    LightIsleApi api,
    String namespace,
    String subKey,
  ) {
    final key = _buildKey(api, namespace, subKey);
    final mem = _getMemory(key);
    if (mem is List<dynamic>) return mem;
    final raw = IsleCacheManager.instance.getBytesSync(
      IsleCacheCategory.metadata,
      key,
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is List<dynamic>) {
        final cloned = _cloneValue(decoded) as List<dynamic>;
        _putMemory(key, cloned, raw.lengthInBytes);
        return _cloneValue(cloned) as List<dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Store a JSON list in L1 memory (and optionally L2 disk) under metadata.
  void putJsonList(
    LightIsleApi api,
    String namespace,
    String subKey,
    List<dynamic> payload, {
    bool persistToDisk = false,
  }) {
    final key = _buildKey(api, namespace, subKey);
    final cloned = _cloneValue(payload) as List<dynamic>;
    _putMemory(key, cloned, _estimateBytes(cloned));
    if (!persistToDisk) return;
    try {
      final encoded = Uint8List.fromList(utf8.encode(jsonEncode(cloned)));
      unawaited(
        IsleCacheManager.instance.putBytes(
          IsleCacheCategory.metadata,
          key,
          encoded,
          persistToDisk: true,
          skipMemoryBucket: true,
        ),
      );
    } catch (_) {}
  }

  /// Invalidate a specific cached entry.
  void invalidate(LightIsleApi api, String namespace, String subKey) {
    final key = _buildKey(api, namespace, subKey);
    final removed = _memory.remove(key);
    if (removed != null) {
      _memoryBytes -= removed.estimatedBytes;
      if (_memoryBytes < 0) _memoryBytes = 0;
    }
    unawaited(
      IsleCacheManager.instance.remove(IsleCacheCategory.metadata, key),
    );
  }

  /// Clears all in-memory SWR entries (called on logout, account switch, or
  /// memory pressure).
  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }
}
