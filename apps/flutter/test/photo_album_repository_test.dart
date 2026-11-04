import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/photo_album_repository.dart';

class _AlbumApi extends LightIsleApi {
  _AlbumApi() : super('http://localhost:16666');

  final requests = <(String, String, Object?)>[];
  Future<void> Function(String, String, Object?)? onSend;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add(('GET', path, null));
    return {
      'albums': [
        {'id': 7, 'name': '测试相册', 'count': 3},
        'ignored',
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    requests.add((method, path, body));
    if (onSend != null) await onSend!(method, path, body);
    return {};
  }
}

void main() {
  test('shared and private album lists have distinct API scopes', () async {
    final api = _AlbumApi();
    addTearDown(api.close);
    final repository = PhotoAlbumRepository(api);
    final shared = await repository.list(PhotoAlbumScope.shared);
    final personal = await repository.list(PhotoAlbumScope.personal);
    expect(shared.single.name, '测试相册');
    expect(personal.single.id, 7);
    expect(api.requests.map((entry) => entry.$2), [
      '/api/v2/photos/albums',
      '/api/v2/photos/private-albums',
    ]);
    expect(() => shared.clear(), throwsUnsupportedError);
  });

  test('create and rename use the correct owner-scoped routes', () async {
    final api = _AlbumApi();
    addTearDown(api.close);
    final repository = PhotoAlbumRepository(api);
    await repository.save(PhotoAlbumScope.personal, name: '相册');
    await repository.save(PhotoAlbumScope.shared, name: '重命名', albumId: 4);
    expect(api.requests.map((request) => request.$1), ['POST', 'PATCH']);
    expect(api.requests.map((request) => request.$2), [
      '/api/v2/photos/private-albums',
      '/api/v2/photos/albums/4',
    ]);
    expect(api.requests.first.$3, {'name': '相册'});
  });

  test('delete and membership operations never delete source media', () async {
    final api = _AlbumApi();
    addTearDown(api.close);
    final repository = PhotoAlbumRepository(api);
    await repository.addItem(PhotoAlbumScope.personal, albumId: 3, assetId: 17);
    await repository.removeItem(
      PhotoAlbumScope.personal,
      albumId: 3,
      assetId: 17,
    );
    await repository.delete(PhotoAlbumScope.shared, 3);
    expect(api.requests.map((request) => '${request.$1} ${request.$2}'), [
      'POST /api/v2/photos/private-albums/3/items',
      'DELETE /api/v2/photos/private-albums/3/items/17',
      'DELETE /api/v2/photos/albums/3',
    ]);
    expect(api.requests.first.$3, {'assetId': 17});
    expect(
      api.requests.every((request) => !request.$2.contains('/files/')),
      isTrue,
    );
  });

  test('malformed identifiers cannot reach server', () async {
    final api = _AlbumApi();
    addTearDown(api.close);
    final repository = PhotoAlbumRepository(api);
    await expectLater(
      repository.save(PhotoAlbumScope.personal, name: 'bad', albumId: -1),
      throwsArgumentError,
    );
    await expectLater(
      repository.delete(PhotoAlbumScope.shared, 0),
      throwsArgumentError,
    );
    await expectLater(
      repository.addItem(PhotoAlbumScope.shared, albumId: 1, assetId: -1),
      throwsArgumentError,
    );
    expect(api.requests, isEmpty);
  });

  test(
    'batch private album add stops remaining writes after root switch',
    () async {
      final api = _AlbumApi();
      addTearDown(api.close);
      var current = true;
      api.onSend = (_, _, _) async => current = false;
      final result = await PhotoAlbumRepository(api).addManyToPrivateAlbum(
        albumId: 3,
        assetIds: [10, 11, 12],
        stillCurrent: () => current,
      );
      expect(result.completed, 1);
      expect(result.cancelled, true);
      expect(result.error, isNull);
      expect(api.requests, hasLength(1));
      expect(api.requests.single.$3, {'assetId': 10});
    },
  );

  test(
    'batch errors report partial success without additional writes',
    () async {
      final api = _AlbumApi();
      addTearDown(api.close);
      api.onSend = (_, _, body) async {
        if ((body as Map)['assetId'] == 11) {
          throw StateError('account permission changed');
        }
      };
      final result = await PhotoAlbumRepository(api).addManyToPrivateAlbum(
        albumId: 3,
        assetIds: [10, 11, 12],
        stillCurrent: () => true,
      );
      expect(result.completed, 1);
      expect(result.cancelled, false);
      expect(result.error, isA<StateError>());
      expect(api.requests, hasLength(2));
    },
  );

  test(
    'batch rejects oversized or invalid selection before any writes',
    () async {
      final api = _AlbumApi();
      addTearDown(api.close);
      await expectLater(
        PhotoAlbumRepository(api).addManyToPrivateAlbum(
          albumId: 3,
          assetIds: List.filled(51, 10),
          stillCurrent: () => true,
        ),
        throwsArgumentError,
      );
      expect(api.requests, isEmpty);
    },
  );
}
