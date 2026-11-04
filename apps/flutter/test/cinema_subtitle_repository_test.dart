import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_subtitle_repository.dart';

const _vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello world\n';

class _SubtitleApi extends LightIsleApi {
  _SubtitleApi() : super('http://localhost:16666');

  final calls = <(String, Map<String, String>?, int?)>[];

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    calls.add((path, query, maxBytes));
    return Uint8List.fromList(utf8.encode(_vtt));
  }
}

void main() {
  test(
    'embedded, automatic and named subtitle tracks use correct endpoints',
    () async {
      final api = _SubtitleApi();
      addTearDown(api.close);
      final subtitles = CinemaSubtitleRepository(api);
      expect((await subtitles.load(12, 'emb:2')).length, 1);
      expect((await subtitles.load(12, 'auto')).length, 1);
      expect((await subtitles.load(12, 'zh')).length, 1);
      expect(api.calls.map((call) => call.$1), [
        '/api/v2/cinema/12/embedded-subtitles',
        '/api/v2/cinema/12/subtitles',
        '/api/v2/cinema/12/subtitles',
      ]);
      expect(api.calls.map((call) => call.$3), [1 << 20, 1 << 20, 1 << 20]);
      expect(api.calls[0].$2, {'track': '2'});
      expect(api.calls[1].$2, isNull);
      expect(api.calls[2].$2, {'lang': 'zh'});
    },
  );

  test('off is instant and does not create a network request', () async {
    final api = _SubtitleApi();
    addTearDown(api.close);
    expect(await CinemaSubtitleRepository(api).load(1, 'off'), isEmpty);
    expect(api.calls, isEmpty);
  });

  test(
    'local file import remains session only with an immutable cue list',
    () async {
      final api = _SubtitleApi();
      addTearDown(api.close);
      final subtitles = CinemaSubtitleRepository(
        api,
        pickLocal: () async => (name: 'custom.vtt', contents: _vtt),
      );
      final selected = await subtitles.importLocal();
      expect(selected?.name, 'custom.vtt');
      expect(selected?.cues, hasLength(1));
      expect(() => selected!.cues.clear(), throwsUnsupportedError);
      expect(api.calls, isEmpty);
    },
  );

  test(
    'cancelled or empty local subtitle import cannot change the player',
    () async {
      final api = _SubtitleApi();
      addTearDown(api.close);
      expect(
        await CinemaSubtitleRepository(
          api,
          pickLocal: () async => null,
        ).importLocal(),
        isNull,
      );
      await expectLater(
        CinemaSubtitleRepository(
          api,
          pickLocal: () async => (name: 'empty.vtt', contents: ''),
        ).importLocal(),
        throwsFormatException,
      );
    },
  );
}
