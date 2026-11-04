import 'dart:collection';
import 'dart:typed_data';

import 'lightisle_api.dart';

/// A bounded, in-memory cache owned by one media viewing session.
///
/// The owning route disposes this cache when it closes. Nothing is persisted,
/// shared with a different authenticated API client, or retained across
/// different viewing sessions.
class MediaImageMemoryCache {
  MediaImageMemoryCache({
    this.maxBytes = 96 * 1024 * 1024,
    this.maxEntries = 24,
  }) : assert(maxBytes > 0),
       assert(maxEntries > 0);

  final int maxBytes;
  final int maxEntries;
  final LinkedHashMap<_MediaImageKey, Uint8List> _entries =
      LinkedHashMap<_MediaImageKey, Uint8List>();
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
    api,
    api.selectedRoot?.identity ?? 'default',
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

    // Retain an in-progress request even if its original image widget is
    // disposed while the user quickly swipes to another page.
    late final Future<Uint8List> pending;
    pending = Future<Uint8List>.sync(fetch)
        .then((bytes) {
          if (!_disposed &&
              bytes.isNotEmpty &&
              bytes.lengthInBytes <= maxBytes) {
            final old = _entries.remove(key);
            if (old != null) _usedBytes -= old.lengthInBytes;
            while (_entries.isNotEmpty &&
                (_entries.length >= maxEntries ||
                    _usedBytes + bytes.lengthInBytes > maxBytes)) {
              final oldestKey = _entries.keys.first;
              _usedBytes -= _entries.remove(oldestKey)!.lengthInBytes;
            }
            _entries[key] = bytes;
            _usedBytes += bytes.lengthInBytes;
          }
          return bytes;
        })
        .whenComplete(() {
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
    final old = _entries.remove(_key(api, path, query, maxResponseBytes));
    if (old != null) _usedBytes -= old.lengthInBytes;
  }

  void dispose() {
    _disposed = true;
    _entries.clear();
    _inFlight.clear();
    _usedBytes = 0;
  }
}

class _MediaImageKey {
  const _MediaImageKey(
    this.api,
    this.rootIdentity,
    this.path,
    this.query,
    this.maxResponseBytes,
  );

  final LightIsleApi api;
  final String rootIdentity;
  final String path;
  final String query;
  final int maxResponseBytes;

  @override
  bool operator ==(Object other) =>
      other is _MediaImageKey &&
      identical(api, other.api) &&
      rootIdentity == other.rootIdentity &&
      path == other.path &&
      query == other.query &&
      maxResponseBytes == other.maxResponseBytes;

  @override
  int get hashCode => Object.hash(
    identityHashCode(api),
    rootIdentity,
    path,
    query,
    maxResponseBytes,
  );
}
