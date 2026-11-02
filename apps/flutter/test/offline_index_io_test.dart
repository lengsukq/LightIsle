import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/offline_index_io.dart';

void main() {
  test(
    'photo and video indexes retain their existing on-disk formats',
    () async {
      final root = await Directory.systemTemp.createTemp('lightisle-manifest-');
      addTearDown(() => root.delete(recursive: true));
      final photo = File('${root.path}/photo.json');
      final video = File('${root.path}/video.json');
      await writeOfflineIndexAtomically(photo, {
        'version': 1,
        'photos': [
          {'fileName': 'example.jpg'},
        ],
      }, temporarySuffix: '.tmp');
      await writeOfflineIndexAtomically(video, {
        'version': 1,
        'videos': [
          {'fileName': 'example.mp4'},
        ],
      }, temporarySuffix: '.new');
      expect(jsonDecode(await photo.readAsString())['photos'], hasLength(1));
      expect(jsonDecode(await video.readAsString())['videos'], hasLength(1));
      expect(await File('${photo.path}.tmp').exists(), isFalse);
      expect(await File('${video.path}.new').exists(), isFalse);

      await writeOfflineIndexAtomically(photo, {
        'version': 1,
        'photos': [],
      }, temporarySuffix: '.tmp');
      expect(jsonDecode(await photo.readAsString())['photos'], isEmpty);
    },
  );

  test('invalid JSON payload cannot overwrite an existing index', () async {
    final root = await Directory.systemTemp.createTemp('lightisle-manifest-');
    addTearDown(() => root.delete(recursive: true));
    final index = File('${root.path}/index.json');
    await index.writeAsString('{"version":1,"photos":[]}');
    await expectLater(
      writeOfflineIndexAtomically(index, <String, Object>{
        'photos': Object(),
      }, temporarySuffix: '.tmp'),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(await index.readAsString(), '{"version":1,"photos":[]}');
    expect(await File('${index.path}.tmp').exists(), isFalse);
    await expectLater(
      writeOfflineIndexAtomically(index, {}, temporarySuffix: '../outside'),
      throwsFormatException,
    );
  });
}
