import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/isle_cache_manager.dart';
import '../../core/lightisle_api.dart';

/// flutter_map's network image pipeline must use LightIsleApi to preserve
/// session-cookie authentication AND certificate-fingerprint pinning. Never
/// export the session cookie to a generic image provider or place it in URLs.
class NasMapTileClient extends http.BaseClient {
  NasMapTileClient(this.api);
  final LightIsleApi api;

  String _cacheKey(String path) =>
      'tile:${identityHashCode(api)}:${IsleCacheManager.scopeKeyFor(api)}:$path';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    final allowed = api.uri('/api/v2/map/status');
    if (request.method != 'GET' ||
        url.scheme != allowed.scheme ||
        url.host != allowed.host ||
        url.port != allowed.port ||
        !RegExp(r'^/api/v2/map/tiles/tianditu/(vec|cva)/(\d+)/(\d+)/(\d+)$')
            .hasMatch(url.path) ||
        url.hasQuery ||
        url.hasFragment) {
      throw http.ClientException('不允许的地图瓦片请求');
    }
    final key = _cacheKey(url.path);
    final cached = await IsleCacheManager.instance.getBytes(
      IsleCacheCategory.mapTiles,
      key,
    );
    if (cached != null && cached.isNotEmpty) {
      return http.StreamedResponse(
        Stream<List<int>>.value(cached),
        200,
        contentLength: cached.length,
        headers: const {'content-type': 'image/png'},
      );
    }
    try {
      final bytes = await api.bytes(url.path, maxBytes: 1024 * 1024);
      if (bytes.isNotEmpty) {
        unawaited(
          IsleCacheManager.instance.putBytes(
            IsleCacheCategory.mapTiles,
            key,
            bytes,
          ),
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        200,
        contentLength: bytes.length,
        headers: const {'content-type': 'image/png'},
      );
    } catch (_) {
      throw http.ClientException('NAS 地图瓦片读取失败，请检查网络及 Mac 地图服务配置。');
    }
  }
}

/// Caching HTTP client for public/custom tile layers (OpenStreetMap, custom URL).
class CachedPublicMapTileClient extends http.BaseClient {
  CachedPublicMapTileClient([http.Client? inner])
    : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    final key = 'pubtile:$url';
    if (request.method == 'GET') {
      final cached = await IsleCacheManager.instance.getBytes(
        IsleCacheCategory.mapTiles,
        key,
      );
      if (cached != null && cached.isNotEmpty) {
        return http.StreamedResponse(
          Stream<List<int>>.value(cached),
          200,
          contentLength: cached.length,
          headers: const {'content-type': 'image/png'},
        );
      }
    }
    final response = await _inner.send(request);
    if (response.statusCode == 200 && request.method == 'GET') {
      final bytes = await response.stream.toBytes();
      if (bytes.isNotEmpty && bytes.length <= 1024 * 1024) {
        unawaited(
          IsleCacheManager.instance.putBytes(
            IsleCacheCategory.mapTiles,
            key,
            Uint8List.fromList(bytes),
          ),
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        response.statusCode,
        contentLength: bytes.length,
        headers: response.headers,
      );
    }
    return response;
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
