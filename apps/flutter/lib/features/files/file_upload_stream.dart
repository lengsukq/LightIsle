import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Session state and bounded random-access reads shared by file uploads.
/// UI and persistence stay in the caller; the reader never changes target
/// paths, user identity, root generations or server-side commit semantics.
enum FileUploadStatus {
  checking,
  uploading,
  paused,
  failed,
  complete,
  cancelled,
}

class FileUploadJob {
  FileUploadJob({
    required this.file,
    required this.destination,
    required this.rootIdentity,
  });

  /// The picker URI can be revoked after app restart. The user may reselect
  /// the same original file for a failed resumable task; digest verification
  /// remains mandatory before any existing server offset is reused.
  PlatformFile file;
  final String destination;
  String? serverDestination;
  String get actualDestination => serverDestination ?? destination;
  final String? rootIdentity;
  FileUploadStatus status = FileUploadStatus.checking;
  String? uploadId;
  bool creationRequested = false;
  String? identityKey;
  String? digest;
  String? error;
  int offset = 0;
  int hashingBytes = 0;
  bool pauseRequested = false;
  bool cancelRequested = false;
  Completer<void>? _pauseGate;

  /// The UI only requests a transition. The streaming task remains the sole
  /// owner of the actual server offset and final commit state.
  void togglePause() {
    if (status == FileUploadStatus.paused || pauseRequested) {
      pauseRequested = false;
      status = FileUploadStatus.uploading;
      _wake();
    } else if (status == FileUploadStatus.uploading) {
      pauseRequested = true;
      status = FileUploadStatus.paused;
    }
  }

  void requestCancel() {
    cancelRequested = true;
    pauseRequested = false;
    _wake();
  }

  void prepareRetry() {
    cancelRequested = false;
    pauseRequested = false;
    _wake();
  }

  Future<void> waitForResume({void Function()? onWaiting}) async {
    while (pauseRequested && !cancelRequested) {
      status = FileUploadStatus.paused;
      final gate = _pauseGate ??= Completer<void>();
      onWaiting?.call();
      await gate.future;
      if (identical(_pauseGate, gate)) _pauseGate = null;
    }
    if (cancelRequested) throw const FileUploadCancelled();
    if (status == FileUploadStatus.paused) {
      status = FileUploadStatus.uploading;
    }
  }

  void _wake() {
    final gate = _pauseGate;
    _pauseGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

class FileRangeReader {
  FileRangeReader(this.job);

  final FileUploadJob job;
  StreamIterator<Uint8List>? _iterator;
  Uint8List? _buffer;
  int _bufferOffset = 0;
  int _position = 0;

  Future<void> _start() async {
    _iterator ??= StreamIterator<Uint8List>(job.file.readAsByteStream());
  }

  Future<void> _seek(int target) async {
    await _iterator?.cancel();
    _iterator = StreamIterator<Uint8List>(job.file.readAsByteStream());
    _buffer = null;
    _bufferOffset = 0;
    _position = 0;
    var remaining = target;
    while (remaining > 0) {
      if (!await _nextBuffer()) {
        throw const FormatException('无法读取文件到服务端要求的上传位置。');
      }
      final available = _buffer!.length - _bufferOffset;
      final take = math.min(available, remaining);
      _bufferOffset += take;
      _position += take;
      remaining -= take;
    }
  }

  Future<bool> _nextBuffer() async {
    if (_buffer != null && _bufferOffset < _buffer!.length) return true;
    await _start();
    if (!await _iterator!.moveNext()) return false;
    _buffer = _iterator!.current;
    _bufferOffset = 0;
    if (_buffer!.isEmpty) return _nextBuffer();
    return true;
  }

  Stream<List<int>> readRange(int start, int length) async* {
    if (_position != start) await _seek(start);
    var remaining = length;
    while (remaining > 0) {
      if (job.cancelRequested) throw const FileUploadCancelled();
      if (!await _nextBuffer()) {
        throw const FormatException('无法重新读取文件内容，上传已暂停。');
      }
      final available = _buffer!.length - _bufferOffset;
      final take = math.min(available, remaining);
      await waitForUploadResume(job);
      if (job.cancelRequested) throw const FileUploadCancelled();
      final begin = _bufferOffset;
      _bufferOffset += take;
      _position += take;
      remaining -= take;
      yield begin == 0 && take == _buffer!.length
          ? _buffer!
          : _buffer!.sublist(begin, begin + take);
    }
  }

  Future<void> close() async {
    await _iterator?.cancel();
    _iterator = null;
  }
}

Future<void> waitForUploadResume(FileUploadJob job) async {
  await job.waitForResume();
}

class FileUploadCancelled implements Exception {
  const FileUploadCancelled();
}
