import 'dart:convert';
import 'dart:typed_data';

import 'isle_cache_manager.dart';
import 'lightisle_api.dart';

/// Session-scoped Stale-While-Revalidate (SWR) metadata cache backed by
/// [IsleCacheManager] under [IsleCacheCategory.metadata].
class IsleDataCache {
  IsleDataCache._();

  static final IsleDataCache instance = IsleDataCache._();

  static String _buildKey(
    LightIsleApi api,
    String namespace,
    String subKey,
  ) {
    final session = identityHashCode(api);
    final rootId = api.selectedRoot?.identity ?? 'default';
    return 'swr:$session:$rootId:$namespace:$subKey';
  }

  /// Read a cached JSON map synchronously from L1 memory.
  Map<String, dynamic>? getJsonMap(
    LightIsleApi api,
    String namespace,
    String subKey,
  ) {
    final raw = IsleCacheManager.instance.getMemoryBytes(
      IsleCacheCategory.metadata,
      _buildKey(api, namespace, subKey),
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
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
    try {
      final encoded = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      IsleCacheManager.instance.putBytes(
        IsleCacheCategory.metadata,
        _buildKey(api, namespace, subKey),
        encoded,
        persistToDisk: persistToDisk,
      );
    } catch (_) {}
  }

  /// Read a cached JSON list synchronously from L1 memory.
  List<dynamic>? getJsonList(
    LightIsleApi api,
    String namespace,
    String subKey,
  ) {
    final raw = IsleCacheManager.instance.getMemoryBytes(
      IsleCacheCategory.metadata,
      _buildKey(api, namespace, subKey),
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is List<dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  /// Store a JSON list in L1 memory under metadata.
  void putJsonList(
    LightIsleApi api,
    String namespace,
    String subKey,
    List<dynamic> payload, {
    bool persistToDisk = false,
  }) {
    try {
      final encoded = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      IsleCacheManager.instance.putBytes(
        IsleCacheCategory.metadata,
        _buildKey(api, namespace, subKey),
        encoded,
        persistToDisk: persistToDisk,
      );
    } catch (_) {}
  }

  /// Invalidate a specific cached entry.
  void invalidate(LightIsleApi api, String namespace, String subKey) {
    IsleCacheManager.instance.remove(
      IsleCacheCategory.metadata,
      _buildKey(api, namespace, subKey),
    );
  }
}
