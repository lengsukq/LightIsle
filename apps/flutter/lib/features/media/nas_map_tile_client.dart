import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/lightisle_api.dart';

/// flutter_map's network image pipeline must use LightIsleApi to preserve
/// session-cookie authentication AND certificate-fingerprint pinning. Never
/// export the session cookie to a generic image provider or place it in URLs.
class NasMapTileClient extends http.BaseClient {
  NasMapTileClient(this.api);
  final LightIsleApi api;

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
    try {
      final bytes = await api.bytes(url.path, maxBytes: 1024 * 1024);
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
