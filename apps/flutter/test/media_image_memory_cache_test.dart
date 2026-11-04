import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/media_image_memory_cache.dart';

void main() {
  late LightIsleApi api;
  setUp(() => api = LightIsleApi('http://127.0.0.1'));
  tearDown(() => api.close());

  test(
    'reuses cached bytes and evicts least recently used under limit',
    () async {
      final cache = MediaImageMemoryCache(maxBytes: 9, maxEntries: 3);
      addTearDown(cache.dispose);
      var calls = 0;
      Future<Uint8List> fetch(int size) async {
        calls++;
        return Uint8List(size);
      }

      final first = await cache.load(
        api,
        '/photo',
        {'path': 'a'},
        64,
        () => fetch(4),
      );
      await cache.load(api, '/photo', {'path': 'b'}, 64, () => fetch(4));
      expect(
        identical(cache.get(api, '/photo', {'path': 'a'}, 64), first),
        isTrue,
      );
      await cache.load(api, '/photo', {'path': 'c'}, 64, () => fetch(4));

      expect(cache.get(api, '/photo', {'path': 'b'}, 64), isNull);
      expect(cache.get(api, '/photo', {'path': 'a'}, 64), same(first));
      expect(cache.entryCount, 2);
      expect(cache.usedBytes, 8);
      await cache.load(api, '/photo', {'path': 'a'}, 64, () => fetch(4));
      expect(calls, 3);
    },
  );

  test('coalesces overlapping loads even with reordered query keys', () async {
    final cache = MediaImageMemoryCache(maxBytes: 20);
    addTearDown(cache.dispose);
    final completer = Completer<Uint8List>();
    var calls = 0;
    Future<Uint8List> fetch() {
      calls++;
      return completer.future;
    }

    final a = cache.load(
      api,
      '/photo',
      {'path': 'a', 'size': '2048'},
      100,
      fetch,
    );
    final b = cache.load(
      api,
      '/photo',
      {'size': '2048', 'path': 'a'},
      100,
      fetch,
    );
    expect(calls, 1);
    completer.complete(Uint8List(5));
    expect(await a, same(await b));
    expect(cache.entryCount, 1);
  });

  test('failed requests do not poison cache and retry fetches again', () async {
    final cache = MediaImageMemoryCache();
    addTearDown(cache.dispose);
    var calls = 0;
    Future<Uint8List> fetch() async {
      calls++;
      if (calls == 1) throw StateError('temporary failure');
      return Uint8List(3);
    }

    await expectLater(
      cache.load(api, '/photo', {'path': 'a'}, 64, fetch),
      throwsStateError,
    );
    await cache.load(api, '/photo', {'path': 'a'}, 64, fetch);
    expect(calls, 2);
  });

  test('does not share across sessions or authenticated API clients', () async {
    final otherApi = LightIsleApi('http://127.0.0.1');
    addTearDown(otherApi.close);
    final cache = MediaImageMemoryCache(maxBytes: 20);
    var calls = 0;
    Future<Uint8List> fetch() async {
      calls++;
      return Uint8List(2);
    }

    await cache.load(api, '/photo', {'path': 'a'}, 64, fetch);
    await cache.load(otherApi, '/photo', {'path': 'a'}, 64, fetch);
    expect(calls, 2);
    cache.dispose();
    expect(cache.usedBytes, 0);
    expect(cache.entryCount, 0);
    expect(cache.get(api, '/photo', {'path': 'a'}, 64), isNull);
  });

  test('late completion after closing a session is not retained', () async {
    final cache = MediaImageMemoryCache(maxBytes: 20);
    final completer = Completer<Uint8List>();
    final pending = cache.load(
      api,
      '/photo',
      {'path': 'a'},
      64,
      () => completer.future,
    );
    cache.dispose();
    completer.complete(Uint8List(8));
    await pending;
    expect(cache.usedBytes, 0);
    expect(cache.entryCount, 0);
  });
}
