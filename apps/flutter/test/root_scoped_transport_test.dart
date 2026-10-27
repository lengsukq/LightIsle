import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';

void main() {
  test('root selection maps only root-scoped APIs and restores legacy paths', () {
    final api = LightIsleApi('http://127.0.0.1:16666');
    addTearDown(api.close);
    final root = LightIsleRoot.fromJson({
      'rootID': 'root_01', 'name': '外置盘', 'generation': 3, 'online': true,
    });
    api.selectRoot(root);
    expect(api.uri('/api/v2/files').path, '/api/v2/roots/root_01/files');
    expect(api.uri('/api/v2/files').queryParameters['rootGeneration'], '3');
    expect(api.uri('/api/v2/files/preview').path,
        '/api/v2/roots/root_01/files/preview');
    expect(api.uri('/api/v2/uploads/abc/complete').path,
        '/api/v2/roots/root_01/uploads/abc/complete');
    expect(api.uri('/api/v2/photos/geo').path,
        '/api/v2/roots/root_01/photos/geo');
    expect(api.uri('/api/v2/cinema/5/stream').path,
        '/api/v2/roots/root_01/cinema/5/stream');
    expect(api.uri('/api/v2/me/storage').path, '/api/v2/me/storage');
    expect(api.uri('/api/v2/downloads').path, '/api/v2/downloads');
    expect(api.uri('/api/v2/roots').path, '/api/v2/roots');
    api.selectRoot(null);
    expect(api.uri('/api/v2/files').path, '/api/v2/files');
  });

  test('root write carries generation header while unrelated APIs do not', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final observed = <String>[];
    server.listen((request) async {
      observed.add('${request.method} ${request.uri.path} '
          '${request.headers.value('X-LightIsle-Root-Generation') ?? '-'}');
      await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(<String, Object>{'ok': true}));
      await request.response.close();
    });
    final api = LightIsleApi('http://127.0.0.1:${server.port}');
    addTearDown(api.close);
    api.selectRoot(const LightIsleRoot(id: 'disk1', name: '硬盘',
        generation: 7, online: true));
    await api.send('POST', '/api/v2/files/folders', body: {'path': 'demo'});
    await api.get('/api/v2/me/storage');
    // Admin assignment can target a different root than the displayed one.
    await api.assignStorageRoot(
      '/api/v2/roots/other_root/users/12/storage/files', 11,
    );
    expect(observed, <String>[
      'POST /api/v2/roots/disk1/files/folders 7',
      'GET /api/v2/me/storage -',
      'PUT /api/v2/roots/other_root/users/12/storage/files 11',
    ]);
  });
}
