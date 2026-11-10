import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/lightisle_api.dart';
import 'file_models.dart';
import 'file_name_validation.dart';
import 'file_upload_stream.dart';
import 'upload_resume_store.dart';

const int _maxUploadSize = 32 * 1024 * 1024 * 1024;
const int _uploadChunkSize = 4 * 1024 * 1024;

/// The server-owned upload session, sha256 stream, authoritative resume offset
/// and root-generation checks are independent of the FilesPage's navigation.
/// No File/Widget/BuildContext is held. A root mismatch fails closed.
class FileUploadService {
  FileUploadService({
    required this.api,
    required this.accountName,
    required this.allowAutoRename,
    required this.onChanged,
    required this.onUploaded,
    required this.formatError,
    UploadResumeStore? resumeStore,
  }) : _uploadResumeStore = resumeStore ?? UploadResumeStore();

  final LightIsleApi api;
  final String accountName;
  final bool Function() allowAutoRename;
  final VoidCallback onChanged;
  final VoidCallback? onUploaded;
  final String Function(Object) formatError;
  final UploadResumeStore _uploadResumeStore;

  Future<void> run(FileUploadJob job) => _runUpload(job);

  Future<void> abort(FileUploadJob job) => _abortUpload(job);

  Future<void> _runUpload(FileUploadJob job) async {
    FileRangeReader? reader;
    job.error = null;
    job.status = FileUploadStatus.checking;
    job.offset = 0;
    onChanged();
    try {
      final size = await job.file.length();
      if (size == null || size < 0) {
        throw const FormatException('无法读取文件大小。');
      }
      if (size > _maxUploadSize) {
        throw const FormatException('文件超过 32 GiB 的上传上限。');
      }
      final digest = await _fingerprint(job, size);
      _checkCancelled(job);
      if (job.digest != null && job.digest != digest) {
        throw const FormatException('重新选择的文件内容与原上传任务不一致，请选择原文件。');
      }
      job.digest = digest;
      job.identityKey = _uploadPreferenceKey(job.destination, size, digest);

      var state = await _resumeOrBeginUpload(job, size);
      job.uploadId = state['id']?.toString();
      var offset = fileModelAsInt(state['offset']);
      if (job.uploadId == null ||
          job.uploadId!.isEmpty ||
          fileModelAsInt(state['size']) != size ||
          !_acceptUploadPath(job, state) ||
          offset < 0 ||
          offset > size) {
        throw const FormatException('服务端返回的上传状态与所选文件不匹配。');
      }
      job.offset = offset;
      job.status = FileUploadStatus.uploading;
      onChanged();
      reader = FileRangeReader(job);

      while (offset < size) {
        await _waitForResume(job);
        _checkCancelled(job);
        final length = math.min(_uploadChunkSize, size - offset);
        try {
          state = await api.uploadChunk(
            job.uploadId!,
            reader.readRange(offset, length),
            length,
            offset,
          );
        } catch (error) {
          // The server may have committed this chunk even when its response
          // was lost. Re-read the authoritative offset before retrying.
          final latest = await _readUploadState(job.uploadId!);
          if (latest == null) rethrow;
          final latestOffset = fileModelAsInt(latest['offset']);
          if (latestOffset <= offset) rethrow;
          state = latest;
        }
        var nextOffset = fileModelAsInt(state['offset']);
        if (nextOffset <= offset || nextOffset > size) {
          final latest = await _readUploadState(job.uploadId!);
          if (latest == null) throw const FormatException('无法确认服务端上传进度。');
          nextOffset = fileModelAsInt(latest['offset']);
          if (nextOffset <= offset || nextOffset > size) {
            throw const FormatException('服务端上传进度没有前进，请重试。');
          }
        }
        offset = nextOffset;
        job.offset = offset;
        onChanged();
      }
      await _waitForResume(job);
      _checkCancelled(job);
      await api.send(
        'POST',
        '/api/v2/uploads/${Uri.encodeComponent(job.uploadId!)}/complete',
      );
      await _removeUploadPreference(job.identityKey);
      job.status = FileUploadStatus.complete;
      job.offset = size;
      onUploaded?.call();
    } on FileUploadCancelled {
      job.status = FileUploadStatus.cancelled;
      await _abortUpload(job);
    } catch (error) {
      if (job.cancelRequested) {
        job.status = FileUploadStatus.cancelled;
        await _abortUpload(job);
      } else {
        job.status = FileUploadStatus.failed;
        job.error = formatError(error) +
            (job.creationRequested && job.uploadId == null
                ? '；未能确认服务端是否创建任务，请联系管理员检查未完成上传和容量预占。'
                : '');
      }
    } finally {
      await reader?.close();
    }
    onChanged();
  }

  Future<String> _fingerprint(FileUploadJob job, int size) async {
    job.hashingBytes = 0;
    final stream = job.file.readAsByteStream().map((chunk) {
      _checkCancelled(job);
      job.hashingBytes += chunk.length;
      if (size > 0 && job.hashingBytes % (4 * 1024 * 1024) < chunk.length) {
        onChanged();
      }
      return chunk;
    });
    final digest = await sha256.bind(stream).first;
    if (job.hashingBytes != size) {
      throw const FormatException('文件大小在校验期间发生变化，请重新选择文件。');
    }
    return digest.toString();
  }

  Future<Map<String, dynamic>> _resumeOrBeginUpload(
    FileUploadJob job,
    int size,
  ) async {
    final identityKey = job.identityKey!;
    final activeId = job.uploadId;
    if (activeId != null && activeId.isNotEmpty) {
      final activeState = await _readUploadState(activeId);
      if (activeState != null &&
          _acceptUploadPath(job, activeState) &&
          fileModelAsInt(activeState['size']) == size) {
        return activeState;
      }
      job.uploadId = null;
    }
    // The NAS owns the durable upload record; local preferences are hints.
    final savedId = await _uploadResumeStore.read(identityKey);
    if (savedId != null && savedId.isNotEmpty) {
      final savedState = await _readUploadState(savedId);
      if (savedState != null &&
          _acceptUploadPath(job, savedState) &&
          fileModelAsInt(savedState['size']) == size) {
        job.uploadId = savedId;
        return savedState;
      }
      await _removeUploadPreference(identityKey);
    }
    _checkCancelled(job);
    job.creationRequested = true;
    final random = math.Random.secure();
    final requestedID = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    job.uploadId = requestedID;
    await _uploadResumeStore.write(identityKey, requestedID);
    _checkCancelled(job);
    Map<String, dynamic> state;
    try {
      state = await api.send(
        'POST',
        '/api/v2/uploads',
        body: {
          'path': job.destination,
          'size': size,
          'onConflict': allowAutoRename() ? 'rename' : '',
          'uploadID': requestedID,
        },
      );
    } catch (_) {
      _checkCancelled(job);
      final recovered = await _readUploadState(requestedID);
      if (recovered == null) rethrow;
      state = recovered;
    }
    final id = state['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const FormatException('服务器没有返回上传任务编号。');
    }
    job.uploadId = id;
    if (!_acceptUploadPath(job, state) ||
        fileModelAsInt(state['size']) != size) {
      throw const FormatException('服务器返回的上传位置无效，请刷新目录后重试。');
    }
    await _uploadResumeStore.write(identityKey, id);
    return state;
  }

  bool _acceptUploadPath(FileUploadJob job, Map<String, dynamic> state) {
    final path = state['path'];
    if (path is! String || validateRelativePath(path) != null) return false;
    final slash = job.destination.lastIndexOf('/');
    final directory = slash < 0 ? '' : job.destination.substring(0, slash + 1);
    if (!path.startsWith(directory) ||
        path.substring(directory.length).contains('/')) {
      return false;
    }
    if (validateFileName(path.substring(directory.length)) != null) {
      return false;
    }
    // The NAS can safely rename a duplicate inside this directory. Never
    // adopt a server path in another folder when resuming an upload.
    job.serverDestination = path;
    return true;
  }

  Future<Map<String, dynamic>?> _readUploadState(String id) async {
    try {
      return await api.get('/api/v2/uploads/${Uri.encodeComponent(id)}');
    } catch (error) {
      if (error is LightIsleApiException && error.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> _waitForResume(FileUploadJob job) async {
    await job.waitForResume(onWaiting: onChanged);
    _checkCancelled(job);
  }

  void _checkCancelled(FileUploadJob job) {
    if (job.cancelRequested || job.rootIdentity != api.selectedRoot?.identity) {
      throw const FileUploadCancelled();
    }
  }

  Future<void> _abortUpload(FileUploadJob job) async {
    // Root switches must never send an old upload ID to the new disk. The
    // original server-side session remains durable until revisited/expired.
    if (job.rootIdentity != api.selectedRoot?.identity) {
      job.error = '已停止上传，但原硬盘已切换，请回到原硬盘检查未完成上传和容量预占。';
      return;
    }
    final id = job.uploadId;
    var aborted = (id == null || id.isEmpty) && !job.creationRequested;
    if (id != null && id.isNotEmpty) {
      try {
        await api.send('DELETE', '/api/v2/uploads/${Uri.encodeComponent(id)}');
        aborted = true;
      } catch (_) {
        // The server still owns the durable staging record if the connection
        // drops. The matching identity remains available for retry.
      }
    }
    if (aborted) {
      job.creationRequested = false;
      job.error = null;
      await _removeUploadPreference(job.identityKey);
    } else {
      job.error = '已停止上传，但未能确认服务端清理结果，请联系管理员检查未完成上传和容量预占。';
    }
  }

  Future<void> _removeUploadPreference(String? key) async {
    await _uploadResumeStore.remove(key);
  }

  String _uploadPreferenceKey(String destination, int size, String digest) {
    final identity = sha256.convert(
      utf8.encode(
        '${api.uri('/').origin}\u0000${api.selectedRoot?.identity ?? 'legacy'}\u0000$accountName\u0000$destination\u0000$size\u0000$digest',
      ),
    );
    return 'lightisle_upload_v3_$identity';
  }
}
