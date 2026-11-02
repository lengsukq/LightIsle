import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/files/photo_backup_hash.dart';

void main() {
  test('original photo is hashed in a bounded pass with chunk digest', () async {
    final temp = await Directory.systemTemp.createTemp('lightisle-hash-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/photo.jpg');
    final source = List<int>.generate(503, (i) => i & 0xff);
    await file.writeAsBytes(source);
    var calls = 0;
    final result = await hashBackupPhoto(file, source.length,
        checkActive: () => calls++);
    expect(result.digest, sha256.convert(source).toString());
    expect(result.chunkDigests, [sha256.convert(source).toString()]);
    expect(calls, greaterThan(1));
  });

  test('size mismatch or cancellation never produces a success marker',
      () async {
    final temp = await Directory.systemTemp.createTemp('lightisle-hash-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/photo.jpg');
    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      hashBackupPhoto(file, 4, checkActive: () {}),
      throwsA(isA<PhotoSourceChanged>()),
    );
    await expectLater(
      hashBackupPhoto(file, 3, checkActive: () => throw StateError('cancel')),
      throwsStateError,
    );
  });
}
