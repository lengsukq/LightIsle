import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/offline_photo_store.dart';
import 'package:lightisle/features/media/media_models.dart';

class _PhotosApi extends LightIsleApi {
  _PhotosApi() : super('http://127.0.0.1');
  int downloads = 0;
  bool broken = false;

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    expect(path, '/api/v2/files/content');
    expect(query?['path'], 'Photos/original.dng');
    downloads++;
    final bytes = utf8.encode(broken ? 'bad' : 'RAW ORIGINAL BYTES');
    onProgress?.call(bytes.length, bytes.length);
    await File(destination).writeAsBytes(bytes, flush: true);
  }
}

PhotoAsset _photo({int size = 18}) => PhotoAsset.fromJson({
  'id': 5,
  'type': 'photo',
  'name': 'original.dng',
  'path': 'Photos/original.dng',
  'size': size,
  'takenAt': 1793456789,
});

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lightisle-offline-photo-');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'RAW original saved byte-for-byte and remains accessible offline',
    () async {
      final api = _PhotosApi();
      final store = OfflinePhotoStore(
        api: api,
        accountId: 'uid:15',
        applicationDirectory: temp,
      );
      final saved = await store.save(_photo());
      final sources = await OfflinePhotoStore.savedLocations(
        api: api,
        accountId: 'uid:15',
        applicationDirectory: temp,
      );
      expect(sources.single.identity, 'default');
      expect(saved.previewable, isFalse);
      expect((await store.list()).single.title, 'original.dng');
      expect(
        await (await store.fileFor(saved)).readAsString(),
        'RAW ORIGINAL BYTES',
      );
      await store.save(_photo());
      expect(
        api.downloads,
        1,
        reason: 'verified local original must be reused',
      );
      api.close();
    },
  );

  test(
    'separate accounts and root generations cannot access each other',
    () async {
      final api = _PhotosApi();
      final owner = OfflinePhotoStore(
        api: api,
        accountId: 'uid:15',
        applicationDirectory: temp,
      );
      final saved = await owner.save(_photo());
      final other = OfflinePhotoStore(
        api: api,
        accountId: 'uid:16',
        applicationDirectory: temp,
      );
      expect(await other.list(), isEmpty);
      await expectLater(other.fileFor(saved), throwsA(isA<StateError>()));
      api.selectRoot(
        const LightIsleRoot(
          id: 'another-disk',
          name: 'B',
          generation: 9,
          online: true,
        ),
      );
      final anotherRoot = OfflinePhotoStore(
        api: api,
        accountId: 'uid:15',
        applicationDirectory: temp,
      );
      expect(anotherRoot.scopeId, isNot(owner.scopeId));
      expect(await anotherRoot.list(), isEmpty);
      await anotherRoot.save(_photo());
      final known = await OfflinePhotoStore.savedLocations(
        api: api,
        accountId: 'uid:15',
        applicationDirectory: temp,
      );
      expect(
        known.map((s) => s.identity),
        containsAll(['default', 'another-disk:9']),
      );
      expect(
        await OfflinePhotoStore.savedLocations(
          api: api,
          accountId: 'uid:16',
          applicationDirectory: temp,
        ),
        isEmpty,
      );
      await expectLater(owner.save(_photo()), throwsA(isA<StateError>()));
      api.close();
    },
  );

  test('truncated download leaves no successful offline entry', () async {
    final api = _PhotosApi()..broken = true;
    final store = OfflinePhotoStore(
      api: api,
      accountId: 'uid:15',
      applicationDirectory: temp,
    );
    await expectLater(store.save(_photo()), throwsA(isA<FormatException>()));
    expect(await store.list(), isEmpty);
    api.close();
  });

  test(
    'same-sized tampering is detected, re-saving repairs the original',
    () async {
      final api = _PhotosApi();
      final store = OfflinePhotoStore(
        api: api,
        accountId: 'uid:15',
        applicationDirectory: temp,
      );
      final saved = await store.save(_photo());
      final original = await store.fileFor(saved);
      await original.writeAsString('BAD ORIGINAL BYTES');
      await expectLater(store.fileFor(saved), throwsFormatException);
      final fresh = await store.save(_photo());
      expect(api.downloads, 2);
      expect(
        await (await store.fileFor(fresh)).readAsString(),
        'RAW ORIGINAL BYTES',
      );
      api.close();
    },
  );

  test(
    'delete and clear are restricted to this NAS-account-root scope',
    () async {
      final api = _PhotosApi();
      final first = OfflinePhotoStore(
        api: api,
        accountId: 'uid:15',
        applicationDirectory: temp,
      );
      final second = OfflinePhotoStore(
        api: api,
        accountId: 'uid:16',
        applicationDirectory: temp,
      );
      final a = await first.save(_photo());
      await second.save(_photo());
      await first.remove(a);
      expect(await first.list(), isEmpty);
      expect(await second.list(), hasLength(1));
      await first.clear();
      expect(await second.list(), hasLength(1));
      api.close();
    },
  );

  test('invalid manifest paths never escape app-private directory', () {
    expect(
      () => OfflinePhoto.fromJson({
        'fileName': '../../secret.dng',
        'remotePath': 'Photos/original.dng',
        'title': 'secret',
        'size': 18,
        'savedAt': DateTime.now().toIso8601String(),
        'sha256': 'a' * 64,
      }),
      throwsFormatException,
    );
    expect(
      () => OfflinePhotoStore(
        api: _PhotosApi(),
        accountId: 'nickname',
        applicationDirectory: temp,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
