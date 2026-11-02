import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

const int photoHashChunkBytes = 4 * 1024 * 1024;
const int maxPhotoBackupBytes = 32 * 1024 * 1024 * 1024;

/// Fail closed if a native photo changes after the OS provided its file.
/// Never record success using size alone; verify hash and metadata in one
/// bounded streaming pass, checking cancellation and the selected root.
class PhotoSourceChanged implements Exception {
  const PhotoSourceChanged();
}

class PhotoHashResult {
  const PhotoHashResult(this.digest, this.chunkDigests);

  final String digest;
  final List<String> chunkDigests;
}

Future<PhotoHashResult> hashBackupPhoto(
  File source,
  int expectedSize, {
  required void Function() checkActive,
}) async {
  if (expectedSize <= 0 || expectedSize > maxPhotoBackupBytes) {
    throw const PhotoSourceChanged();
  }
  final before = await source.stat();
  if (before.type != FileSystemEntityType.file || before.size != expectedSize) {
    throw const PhotoSourceChanged();
  }
  final chunkHashes = <String>[];
  Stream<List<int>> readFixedChunks() async* {
    final handle = await source.open();
    try {
      var remaining = expectedSize;
      while (remaining > 0) {
        checkActive();
        final count = min(photoHashChunkBytes, remaining);
        final bytes = await handle.read(count);
        if (bytes.length != count) throw const PhotoSourceChanged();
        chunkHashes.add(sha256.convert(bytes).toString());
        remaining -= count;
        yield bytes;
      }
      if ((await handle.read(1)).isNotEmpty) {
        throw const PhotoSourceChanged();
      }
    } finally {
      await handle.close();
    }
  }

  final digest = await sha256.bind(readFixedChunks()).first;
  checkActive();
  final after = await source.stat();
  if (after.type != FileSystemEntityType.file ||
      after.size != expectedSize ||
      !after.modified.isAtSameMomentAs(before.modified)) {
    throw const PhotoSourceChanged();
  }
  return PhotoHashResult(
    digest.toString(),
    List<String>.unmodifiable(chunkHashes),
  );
}
