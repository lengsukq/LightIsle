import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/files/file_upload_stream.dart';

final class _MemoryFile extends PlatformFile {
  _MemoryFile(this.name, List<int> bytes) : data = Uint8List.fromList(bytes);

  @override
  final String name;
  final Uint8List data;

  @override
  Uri get uri => Uri(scheme: 'memory', path: name);
  @override
  Never get xFile => throw UnimplementedError();

  @override
  int lengthSync() => data.length;
  @override
  Future<int> length() async => data.length;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

FileUploadJob job(List<int> content) => FileUploadJob(
  file: _MemoryFile('sample.bin', content),
  destination: 'member/files/sample.bin',
  rootIdentity: 'root-A:1',
);

void main() {
  test('pausing and resuming releases the only pending gate', () async {
    final upload = job([1, 2, 3]);
    upload.status = FileUploadStatus.uploading;
    upload.togglePause();
    expect(upload.status, FileUploadStatus.paused);
    var waitNotifications = 0;
    final future = upload.waitForResume(onWaiting: () => waitNotifications++);
    await Future<void>.delayed(Duration.zero);
    expect(waitNotifications, 1);
    upload.togglePause();
    await future;
    expect(upload.status, FileUploadStatus.uploading);
    expect(upload.pauseRequested, false);
  });

  test('cancel during pause wakes the worker and cannot commit', () async {
    final upload = job([1, 2, 3]);
    upload.status = FileUploadStatus.uploading;
    upload.togglePause();
    final expectation = expectLater(
      upload.waitForResume(),
      throwsA(isA<FileUploadCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    upload.requestCancel();
    await expectation;
    expect(upload.cancelRequested, true);
    expect(upload.pauseRequested, false);
    upload.prepareRetry();
    expect(upload.cancelRequested, false);
    expect(upload.pauseRequested, false);
  });

  test('range reader repositions and refuses cancelled downloads', () async {
    final upload = job([1, 2, 3, 4, 5, 6, 7]);
    upload.status = FileUploadStatus.uploading;
    final reader = FileRangeReader(upload);
    addTearDown(reader.close);
    final middle = await reader.readRange(2, 3).toList();
    expect(middle.expand((v) => v).toList(), [3, 4, 5]);
    final start = await reader.readRange(0, 2).toList();
    expect(start.expand((v) => v).toList(), [1, 2]);
    upload.requestCancel();
    await expectLater(
      reader.readRange(2, 1).toList(),
      throwsA(isA<FileUploadCancelled>()),
    );
  });
}
