import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/offline_video_store.dart';

class _OfflineApi extends LightIsleApi {
  _OfflineApi(super.url);
  int calls = 0;
  bool invalidSize = false;

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    expect(path, '/api/v2/files/content');
    expect(query?['path'], 'videos/trip.mp4');
    calls++;
    final bytes = utf8.encode(invalidSize ? 'too short' : 'movie bytes!');
    onProgress?.call(bytes.length, bytes.length);
    await File(destination).writeAsBytes(bytes, flush: true);
  }
}

CinemaFilm _movie({int size = 12}) => CinemaFilm.fromJson(<String, dynamic>{
  'id': 23,
  'title': 'Travel Movie',
  'path': 'videos/trip.mp4',
  'size': size,
});

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'lightisle-offline-test-',
    );
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'persistent offline files are isolated by account and root generation',
    () async {
      final api = _OfflineApi('http://127.0.0.1');
      final owner = OfflineVideoStore(
        api: api,
        accountName: 'owner',
        applicationDirectory: temporary,
      );
      final copy = await owner.save(_movie());
      expect(api.calls, 1);
      expect((await owner.list()).single.title, 'Travel Movie');
      expect(await (await owner.fileFor(copy)).readAsString(), 'movie bytes!');
      expect(copy.sha256, isNotNull);
      await owner.save(_movie());
      expect(api.calls, 1, reason: 'same file must not redownload');
      final other = OfflineVideoStore(
        api: api,
        accountName: 'another-user',
        applicationDirectory: temporary,
      );
      expect(await other.list(), isEmpty);
      expect(() => other.fileFor(copy), throwsA(isA<StateError>()));
      final originalScope = owner.scopeId;
      api.selectRoot(
        const LightIsleRoot(
          id: 'volume',
          name: 'Hard Drive',
          generation: 4,
          online: true,
        ),
      );
      final anotherRoot = OfflineVideoStore(
        api: api,
        accountName: 'owner',
        applicationDirectory: temporary,
      );
      expect(await anotherRoot.list(), isEmpty);
      expect(owner.scopeId, originalScope);
      expect(anotherRoot.scopeId, isNot(originalScope));
      await expectLater(owner.save(_movie()), throwsA(isA<StateError>()));
      api.close();
    },
  );

  test('failed integrity check cleans up downloaded file and index', () async {
    final api = _OfflineApi('http://127.0.0.1')..invalidSize = true;
    final store = OfflineVideoStore(
      api: api,
      accountName: 'user',
      applicationDirectory: temporary,
    );
    await expectLater(store.save(_movie()), throwsA(isA<FormatException>()));
    expect(await store.list(), isEmpty);
    api.close();
  });

  test(
    'same-size tampering is detected before playback and repaired on save',
    () async {
      final api = _OfflineApi('http://127.0.0.1');
      final store = OfflineVideoStore(
        api: api,
        accountName: 'user',
        applicationDirectory: temporary,
      );
      final original = await store.save(_movie());
      final file = await store.fileFor(original);
      await file.writeAsString('tampered????', flush: true);
      await expectLater(store.fileFor(original), throwsFormatException);
      final fresh = await store.save(_movie());
      expect(api.calls, 2);
      expect(await (await store.fileFor(fresh)).readAsString(), 'movie bytes!');
      api.close();
    },
  );

  test(
    'manual cleanup removes orphan media but keeps catalogued files',
    () async {
      final api = _OfflineApi('http://127.0.0.1');
      final store = OfflineVideoStore(
        api: api,
        accountName: 'user',
        applicationDirectory: temporary,
      );
      final video = await store.save(_movie());
      final actual = await store.fileFor(video);
      final orphan = File('${actual.parent.path}/${'0' * 64}.mp4');
      await orphan.writeAsString('unreferenced', flush: true);
      expect(await store.cleanupUnusedFiles(), 1);
      expect(await actual.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
      await store.clear();
      expect(await store.list(), isEmpty);
      api.close();
    },
  );

  test('oversized or invalid media is denied before contacting NAS', () async {
    final api = _OfflineApi('http://127.0.0.1');
    final store = OfflineVideoStore(
      api: api,
      accountName: 'user',
      applicationDirectory: temporary,
    );
    await expectLater(
      store.save(_movie(size: OfflineVideoStore.maxSingleBytes + 1)),
      throwsA(isA<StateError>()),
    );
    expect(api.calls, 0);
    api.close();
  });

  test('deleting offline media removes only the scoped local copy', () async {
    final api = _OfflineApi('http://127.0.0.1');
    final store = OfflineVideoStore(
      api: api,
      accountName: 'user',
      applicationDirectory: temporary,
    );
    final saved = await store.save(_movie());
    final file = await store.fileFor(saved);
    await store.remove(saved);
    expect(await store.list(), isEmpty);
    expect(await file.exists(), isFalse);
    api.close();
  });

  test('malicious catalog paths are ignored and never opened', () async {
    expect(
      () => OfflineVideo.fromJson({
        'fileName': '../../outside',
        'remotePath': 'x.mp4',
        'title': 'test',
        'size': 1,
        'savedAt': DateTime.now().toIso8601String(),
      }),
      throwsFormatException,
    );
  });
}
