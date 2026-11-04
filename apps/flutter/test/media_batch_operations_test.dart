import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/media_batch_operations.dart';

class _BatchApi extends LightIsleApi {
  _BatchApi() : super('http://localhost:16666');

  final requests = <(String, String, Object?)>[];
  Future<Map<String, dynamic>> Function(String, String, Object?)? onSend;

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    requests.add((method, path, body));
    return await onSend?.call(method, path, body) ??
        {'token': 'share-${requests.length}'};
  }
}

void main() {
  test(
    'sharing creates independent 24-hour capabilities in selection order',
    () async {
      final api = _BatchApi();
      addTearDown(api.close);
      final result = await MediaBatchOperations(api).createShares(
        items: [
          (path: '图库/a.jpg', label: 'a.jpg'),
          (path: '影视/b.mp4', label: 'Movie B'),
        ],
        stillCurrent: () => true,
      );
      expect(result.completed, 2);
      expect(result.cancelled, false);
      expect(result.error, isNull);
      expect(result.links.first, contains('a.jpg:'));
      expect(result.links.last, contains('Movie B:'));
      expect(result.links.first, contains('share-1'));
      expect(result.links.last, contains('share-2'));
      expect(() => result.links.clear(), throwsUnsupportedError);
      expect(api.requests.map((request) => request.$3), [
        {'path': '图库/a.jpg', 'hours': 24},
        {'path': '影视/b.mp4', 'hours': 24},
      ]);
    },
  );

  test(
    'root change during a share response stops creating more links',
    () async {
      final api = _BatchApi();
      addTearDown(api.close);
      var current = true;
      api.onSend = (_, _, _) async {
        current = false;
        return {'token': 'obsolete-capability'};
      };
      final result = await MediaBatchOperations(api).createShares(
        items: [
          (path: 'old/a.jpg', label: 'a'),
          (path: 'old/b.jpg', label: 'b'),
        ],
        stillCurrent: () => current,
      );
      expect(result.cancelled, true);
      expect(result.completed, 0);
      expect(result.links, isEmpty);
      expect(api.requests, hasLength(1));
    },
  );

  test(
    'partial sharing error retains preceding links for manual recovery',
    () async {
      final api = _BatchApi();
      addTearDown(api.close);
      api.onSend = (_, _, body) async {
        if ((body as Map)['path'] == 'bad') {
          throw StateError('access denied');
        }
        return {'token': 'first'};
      };
      final result = await MediaBatchOperations(api).createShares(
        items: [
          (path: 'ok', label: 'ok'),
          (path: 'bad', label: 'bad'),
          (path: 'never', label: 'never'),
        ],
        stillCurrent: () => true,
      );
      expect(result.completed, 1);
      expect(result.error, isA<StateError>());
      expect(result.cancelled, false);
      expect(result.links, hasLength(1));
      expect(api.requests, hasLength(2));
    },
  );

  test('desktop save stops before next write on root switch', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    var current = true;
    final saved = <String>[];
    final result = await MediaBatchOperations(api).exportToDirectory(
      items: [
        (path: 'a.jpg', name: 'a.jpg', size: 10),
        (path: 'b.jpg', name: 'b.jpg', size: 20),
      ],
      directory: '/safe-output',
      stillCurrent: () => current,
      saveOriginal:
          ({
            required String path,
            required String name,
            required String directory,
          }) async {
            expect(directory, '/safe-output');
            saved.add(path);
            current = false;
            return 'saved';
          },
    );
    expect(result.completed, 1);
    expect(result.cancelled, true);
    expect(saved, ['a.jpg']);
  });

  test('desktop save keeps partial result when one file fails', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    final saved = <String>[];
    final result = await MediaBatchOperations(api).exportToDirectory(
      items: [
        (path: 'a.jpg', name: 'a.jpg', size: 10),
        (path: 'bad', name: 'bad', size: 20),
        (path: 'never', name: 'never', size: 30),
      ],
      directory: '/safe-output',
      stillCurrent: () => true,
      saveOriginal:
          ({
            required String path,
            required String name,
            required String directory,
          }) async {
            saved.add(path);
            if (path == 'bad') throw StateError('offline');
            return 'saved';
          },
    );
    expect(result.completed, 1);
    expect(result.error, isA<StateError>());
    expect(saved, ['a.jpg', 'bad']);
  });

  test('invalid batch never creates public sharing links', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    await expectLater(
      MediaBatchOperations(api).createShares(
        items: List.generate(11, (i) => (path: 'file$i', label: '$i')),
        stillCurrent: () => true,
      ),
      throwsArgumentError,
    );
    expect(api.requests, isEmpty);
  });

  test('mobile batch fails before invoking any picker on lost root', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    await expectLater(
      MediaBatchOperations(api).exportOnMobile(
        items: [(path: 'a.jpg', name: 'a.jpg', size: 15)],
        stillCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(api.requests, isEmpty);
  });

  test('gallery and cinema trash use a single bounded permission-checked batch', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    api.onSend = (method, path, body) async {
      expect(method, 'POST');
      expect(path, '/api/v2/files/batch');
      expect(body, {
        'action': 'trash',
        'paths': ['Photos/a.jpg', 'Movies/b.mp4'],
      });
      return {
        'results': [
          {'path': 'Photos/a.jpg', 'success': true},
          {'path': 'Movies/b.mp4', 'success': false},
        ],
      };
    };
    final result = await MediaBatchOperations(api).trashOriginals(
      paths: ['Photos/a.jpg', 'Movies/b.mp4'],
      stillCurrent: () => true,
    );
    expect(result.completed, 1);
    expect(result.cancelled, false);
    expect(result.error, isNotNull);
    expect(api.requests, hasLength(1));
  });

  test('trash refuses changed root and invalid duplicated paths', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    final cancelled = await MediaBatchOperations(api).trashOriginals(
      paths: ['photo.jpg'],
      stillCurrent: () => false,
    );
    expect(cancelled.cancelled, true);
    expect(api.requests, isEmpty);
    await expectLater(
      MediaBatchOperations(api).trashOriginals(
        paths: ['same.jpg', 'same.jpg'],
        stillCurrent: () => true,
      ),
      throwsArgumentError,
    );
    expect(api.requests, isEmpty);
  });
}
