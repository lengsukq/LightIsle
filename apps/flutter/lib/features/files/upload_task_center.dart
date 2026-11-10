import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'file_upload_service.dart';
import 'file_upload_stream.dart';

/// An authenticated, session-scoped upload queue, independent of widgets.
/// Each task uses its own root-pinned API to prevent navigation between
/// physical disks from redirecting in-flight upload chunks.
class UploadTaskCenter extends ChangeNotifier {
  UploadTaskCenter({
    required this.api,
    required this.accountName,
    required this.userId,
    required this.isAdmin,
  });

  final LightIsleApi api;
  final String accountName;
  final int userId;
  final bool isAdmin;
  final List<FileUploadJob> _jobs = [];
  final Map<FileUploadJob, LightIsleApi> _clients = {};
  final Map<FileUploadJob, LightIsleRoot?> _roots = {};
  final Map<FileUploadJob, bool> _autoRename = {};
  final Set<FileUploadJob> _invalidTarget = {};
  final Set<FileUploadJob> _abortingJobs = {};
  bool _working = false;
  bool _closed = false;
  bool _restored = false;
  Future<void> _saving = Future<void>.value();

  List<FileUploadJob> get jobs => List.unmodifiable(_jobs);
  int get unfinished => _jobs
      .where(
        (job) =>
            job.status != FileUploadStatus.complete &&
            job.status != FileUploadStatus.cancelled,
      )
      .length;

  bool canRetry(FileUploadJob job) =>
      !_closed &&
      _jobs.contains(job) &&
      job.status == FileUploadStatus.failed &&
      !_invalidTarget.contains(job);

  bool isAborting(FileUploadJob job) =>
      _abortingJobs.contains(job) ||
      (job.cancelRequested &&
          job.status != FileUploadStatus.cancelled &&
          job.status != FileUploadStatus.complete);

  String get _storageKey {
    final digest = sha256.convert(
      utf8.encode('${api.uri('/').origin}\u0000$userId\u0000$accountName'),
    );
    return 'lightisle.upload.queue.v1.$digest';
  }

  /// Rebind an expired picker URI. An existing remote session is only reused
  /// if the streaming service verifies the same SHA-256 fingerprint.
  Future<bool> reselect(FileUploadJob job, PlatformFile replacement) async {
    if (_closed ||
        !_jobs.contains(job) ||
        job.status != FileUploadStatus.failed ||
        _invalidTarget.contains(job)) {
      return false;
    }
    final oldLength = await job.file.length();
    final newLength = await replacement.length();
    if (job.file.name != replacement.name ||
        newLength == null ||
        oldLength == null ||
        newLength != oldLength) {
      job.error = '请选择原文件（名称和大小必须一致）。';
      notifyListeners();
      return false;
    }
    job.file = replacement;
    job.prepareRetry();
    job.status = FileUploadStatus.checking;
    job.error = null;
    notifyListeners();
    await _save();
    unawaited(_pump());
    return true;
  }

  Future<void> enqueue(
    List<PlatformFile> files, {
    required String directory,
    required LightIsleRoot? root,
    required bool autoRename,
  }) async {
    if (_closed) return;
    for (final file in files) {
      final job = FileUploadJob(
        file: file,
        destination: directory == '.' ? file.name : '$directory/${file.name}',
        rootIdentity: root?.identity,
      );
      _jobs.add(job);
      _roots[job] = root;
      _autoRename[job] = autoRename;
    }
    notifyListeners();
    await _save();
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_working || _closed) return;
    _working = true;
    try {
      for (final job in List<FileUploadJob>.of(_jobs)) {
        if (_closed) break;
        if (job.status != FileUploadStatus.checking || job.cancelRequested) {
          continue;
        }
        final snapshot = api.sessionSnapshot;
        // Production sessions use a dedicated client with an immutable root
        // selection. Test-only injected clients without a session can use the
        // original mock API.
        final client = snapshot == null
            ? api
            : LightIsleApi.fromSessionSnapshot(snapshot);
        if (!identical(client, api)) client.selectRoot(_roots[job]);
        _clients[job] = client;
        try {
          final service = FileUploadService(
            api: client,
            // Preserve the existing upload_resume_store key so upgrading
            // from the former page-owned uploader can find its partial Go
            // server upload. Server ownership still rejects other accounts.
            accountName: accountName,
            allowAutoRename: () => _autoRename[job] ?? false,
            onChanged: () {
              if (!_closed) notifyListeners();
            },
            onUploaded: null,
            formatError: userFacingError,
          );
          await service.run(job);
          // The Core now schedules a single generation-bound, debounced
          // media refresh after a durable upload commit for ALL authorized
          // users. An extra administrator-only scan per file needlessly
          // rescanned large libraries and made normal members wait longer.
        } finally {
          _clients.remove(job);
          if (!identical(client, api)) client.close();
          if (!_closed) {
            notifyListeners();
            await _save();
          }
        }
      }
    } finally {
      _working = false;
      if (!_closed &&
          _jobs.any(
            (job) =>
                job.status == FileUploadStatus.checking && !job.cancelRequested,
          )) {
        unawaited(_pump());
      }
    }
  }

  void togglePause(FileUploadJob job) {
    if (_closed || !_jobs.contains(job)) return;
    job.togglePause();
    notifyListeners();
  }

  void cancel(FileUploadJob job) {
    if (_closed || !_jobs.contains(job)) return;
    job.requestCancel();
    if (!_clients.containsKey(job)) {
      job.status = FileUploadStatus.cancelled;
      if (job.uploadId != null && !_invalidTarget.contains(job)) {
        unawaited(_abortIdleUpload(job, _roots[job]));
      }
    }
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _abortIdleUpload(
    FileUploadJob job,
    LightIsleRoot? pinnedRoot,
  ) async {
    if (job.rootIdentity != pinnedRoot?.identity) return;
    final snapshot = api.sessionSnapshot;
    // Avoid sending a stale upload ID to whichever disk happens to be active
    // in the shell. Without a restorable session, leave server cleanup to its
    // staging TTL rather than risk touching another physical root.
    if (snapshot == null && job.rootIdentity != api.selectedRoot?.identity) {
      return;
    }
    _abortingJobs.add(job);
    if (!_closed) notifyListeners();
    LightIsleApi? isolated;
    try {
      final client = snapshot == null
          ? api
          : (isolated = LightIsleApi.fromSessionSnapshot(snapshot));
      if (isolated != null) client.selectRoot(pinnedRoot);
      await FileUploadService(
        api: client,
        accountName: accountName,
        allowAutoRename: () => _autoRename[job] ?? false,
        onChanged: () {
          if (!_closed) notifyListeners();
        },
        onUploaded: null,
        formatError: userFacingError,
      ).abort(job);
    } catch (_) {
      // The server retains an expiring staged record if the cancellation
      // request cannot be confirmed. Never send the ID to another NAS root.
    } finally {
      _abortingJobs.remove(job);
      isolated?.close();
      if (!_closed) notifyListeners();
    }
  }

  void retry(FileUploadJob job) {
    if (_closed ||
        !_jobs.contains(job) ||
        job.status != FileUploadStatus.failed ||
        _invalidTarget.contains(job)) {
      return;
    }
    if (job.file.uri.scheme == 'file' &&
        !File.fromUri(job.file.uri).existsSync()) {
      job.error = '源文件已失效，请重新选择文件。';
      notifyListeners();
      return;
    }
    job.prepareRetry();
    job.status = FileUploadStatus.checking;
    notifyListeners();
    unawaited(_save());
    unawaited(_pump());
  }

  void clearFinished() {
    _jobs.removeWhere((job) {
      final completed =
          job.status == FileUploadStatus.complete ||
          job.status == FileUploadStatus.cancelled;
      if (completed) {
        _roots.remove(job);
        _autoRename.remove(job);
      }
      return completed;
    });
    notifyListeners();
    unawaited(_save());
  }

  /// Best-effort restart recovery. The actual upload offset and digest are
  /// always re-verified by FileUploadService against the Go server. FilePicker
  /// may return temporary/content URLs which the OS can revoke at any time.
  /// Missing source files stay visible as failures, never silently vanish.
  Future<void> restore(
    List<LightIsleRoot> roots,
    Map<String, dynamic> storagePolicy,
  ) async {
    if (_restored || _closed) return;
    _restored = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        _storageKey,
      );
      if (_closed) return;
      if (raw == null || raw.length > 180000) return;
      final records = jsonDecode(raw);
      if (records is! List) return;
      for (final record in records.take(60)) {
        if (_closed) return;
        if (record is! Map) continue;
        final name = record['name'];
        final source = record['source'];
        final destination = record['destination'];
        final size = record['size'];
        if (name is! String ||
            name.isEmpty ||
            source is! String ||
            destination is! String ||
            size is! int ||
            size < 0) {
          continue;
        }
        final uri = Uri.tryParse(source);
        final rootId = record['rootId'];
        final generation = record['generation'];
        final root = rootId is String && generation is int
            ? roots
                  .where(
                    (r) =>
                        r.id == rootId &&
                        r.generation == generation &&
                        r.online,
                  )
                  .firstOrNull
            : null;
        final allowed =
            (rootId == null || root != null) &&
            (isAdmin || _memberAllowed(destination, root, storagePolicy));
        final sourceOk =
            uri != null &&
            uri.scheme == 'file' &&
            await File.fromUri(uri).exists() &&
            await File.fromUri(uri).length() == size;
        final job = FileUploadJob(
          file: _SavedFile(name, uri, size),
          destination: destination,
          rootIdentity: root?.identity,
        );
        if (record['digest'] is String &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(record['digest'] as String)) {
          job.digest = record['digest'] as String;
        }
        _jobs.add(job);
        _roots[job] = root;
        _autoRename[job] = record['rename'] == true;
        if (!allowed || !sourceOk) {
          job.status = FileUploadStatus.failed;
          job.error = !allowed ? '存储盘或权限已变化，请重新选择目标目录。' : '源文件已失效，请重新选择该文件上传。';
          if (!allowed) _invalidTarget.add(job);
        }
      }
      notifyListeners();
      unawaited(_pump());
    } catch (_) {
      // No fallback to another root when old persisted state is corrupt.
    }
  }

  bool _memberAllowed(
    String path,
    LightIsleRoot? root,
    Map<String, dynamic> policy,
  ) {
    if (root == null || policy['userId'] != userId) return false;
    final locations = policy['locations'];
    if (locations is! List) return false;
    for (final record in locations) {
      if (record is! Map) continue;
      final category = record['category'];
      if (!{'files', 'photos', 'videos'}.contains(category)) continue;
      final prefix = 'Users/u$userId/$category';
      if (record['rootID'] == root.id &&
          record['rootGeneration'] == root.generation &&
          record['relativePath'] == prefix &&
          path.startsWith('$prefix/')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _save() {
    final pending = _saving;
    final next = Completer<void>();
    _saving = next.future;
    unawaited(() async {
      try {
        await pending;
        final records = <Map<String, Object?>>[];
        for (final job in _jobs) {
          if (job.status == FileUploadStatus.complete ||
              job.status == FileUploadStatus.cancelled) {
            continue;
          }
          final root = _roots[job];
          records.add({
            'name': job.file.name,
            'source': job.file.uri.toString(),
            'size': await job.file.length(),
            'destination': job.destination,
            'rootId': root?.id,
            'generation': root?.generation,
            'digest': job.digest,
            'rename': _autoRename[job] ?? false,
          });
        }
        await (await SharedPreferences.getInstance()).setString(
          _storageKey,
          jsonEncode(records.take(60).toList()),
        );
      } catch (_) {
        // The server-owned upload session remains the source of truth.
      } finally {
        next.complete();
      }
    }());
    return next.future;
  }

  @override
  void dispose() {
    _closed = true;
    // A route transition never disposes this controller; logout does.
    // Close dedicated connections so no authenticated transfer survives
    // logout. Leave remote staging to expire for future safe resume.
    for (final client in _clients.values) {
      if (!identical(client, api)) client.close();
    }
    super.dispose();
  }
}

final class _SavedFile extends PlatformFile {
  _SavedFile(this.name, this._uri, this._size);
  @override
  final String name;
  final Uri? _uri;
  final int _size;
  @override
  Uri get uri => _uri ?? Uri(scheme: 'missing', path: name);
  @override
  Never get xFile => throw UnsupportedError('Only a file stream is used');
  @override
  int lengthSync() => _size;
  @override
  Future<int> length() async => _size;
  @override
  Future<Uint8List> readAsBytes() => File.fromUri(uri).readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      File.fromUri(uri).openRead().map(Uint8List.fromList);
}
