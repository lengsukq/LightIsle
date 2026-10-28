import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/nas_map_tile_client.dart';

class _MapTileApi extends LightIsleApi {
  _MapTileApi() : super('http://127.0.0.1:16666');

  final List<String> fetched = [];

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    fetched.add(path);
    expect(maxBytes, 1024 * 1024);
    return Uint8List.fromList(const [137, 80, 78, 71, 13, 10, 26, 10]);
  }
}

void main() {
  test(
    'requests only approved NAS map tiles via authenticated LightIsleApi',
    () async {
      final api = _MapTileApi();
      final client = NasMapTileClient(api);
      final response = await client.send(
        http.Request(
          'GET',
          Uri.parse(
            'http://127.0.0.1:16666/api/v2/map/tiles/tianditu/vec/6/42/20',
          ),
        ),
      );
      expect(response.statusCode, 200);
      expect(await response.stream.toBytes(), hasLength(8));
      expect(api.fetched, ['/api/v2/map/tiles/tianditu/vec/6/42/20']);
      client.close();
    },
  );

  test(
    'rejects cross-origin, credential queries, arbitrary paths and writes',
    () async {
      final api = _MapTileApi();
      final client = NasMapTileClient(api);
      for (final request in [
        http.Request(
          'GET',
          Uri.parse('https://evil.test/api/v2/map/tiles/tianditu/vec/6/42/20'),
        ),
        http.Request(
          'GET',
          Uri.parse(
            'http://127.0.0.1:16666/api/v2/map/tiles/tianditu/vec/6/42/20?tk=secret',
          ),
        ),
        http.Request(
          'GET',
          Uri.parse(
            'http://127.0.0.1:16666/api/v2/map/tiles/tianditu/vec/6/42/20#fragment',
          ),
        ),
        http.Request(
          'GET',
          Uri.parse('http://127.0.0.1:16666/api/v2/photos/geo'),
        ),
        http.Request(
          'POST',
          Uri.parse(
            'http://127.0.0.1:16666/api/v2/map/tiles/tianditu/vec/6/42/20',
          ),
        ),
      ]) {
        await expectLater(
          client.send(request),
          throwsA(isA<http.ClientException>()),
        );
      }
      expect(api.fetched, isEmpty);
      client.close();
    },
  );
}
