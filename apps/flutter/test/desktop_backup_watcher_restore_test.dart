import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/desktop_backup_engine.dart';
import 'package:lightisle/features/files/desktop_backup_models.dart';
import 'package:lightisle/features/files/desktop_backup_restore.dart';
import 'package:lightisle/features/files/desktop_backup_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RestoreAndWatchNasApi extends LightIsleApi {
  _RestoreAndWatchNasApi() : super('http://127.0.0.1:1');

  int rootGeneration = 1;
  bool rootOnline = true;
  bool simulateQuotaFull = false;
  bool corruptNextDownload = false;

  final Set<String> folders = <String>{'.', 'WorkDocs', 'WorkDocs/sub'};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, ({String path, int size, BytesBuilder bytes})> _uploads =
      <String, ({String path, int size, BytesBuilder bytes})>{};

  static String _parentOf(String p) {
    final idx = p.lastIndexOf('/');
    return idx < 0 ? '.' : p.substring(0, idx);
  }

  static String _nameOf(String p) {
    final idx = p.lastIndexOf('/');
    return idx < 0 ? p : p.substring(idx + 1);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots') {
      return {
        'roots': [
          {
            'rootID': 'nas_main',
            'name': '家庭主盘',
            'generation': rootGeneration,
            'online': rootOnline,
            'isDefault': true,
          },
        ],
      };
    }
    if (path == '/api/v2/files' || path.endsWith('/files')) {
      final dir = query?['path'] ?? '.';
      if (!folders.contains(dir)) {
        throw const LightIsleApiException(
          code: 'not_found',
          message: '目录不存在',
          statusCode: 404,
        );
      }
      final entries = <Map<String, Object>>[
        for (final f in folders)
          if (f != '.' && _parentOf(f) == dir)
            {'name': _nameOf(f), 'path': f, 'type': 'folder', 'size': 0},
        for (final e in files.entries)
          if (_parentOf(e.key) == dir)
            {
              'name': _nameOf(e.key),
              'path': e.key,
              'type': 'file',
              'size': e.value.length,
            },
      ];
      return {'path': dir, 'canWrite': true, 'entries': entries, 'nextCursor': ''};
    }
    if (path.contains('/uploads/')) {
      final id = path.split('/').last;
      final up = _uploads[id];
      if (up == null) {
        throw const LightIsleApiException(
          code: 'not_found',
          message: '不存在',
          statusCode: 404,
        );
      }
      return {'id': id, 'path': up.path, 'size': up.size, 'offset': up.bytes.length};
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (simulateQuotaFull) {
      throw const LightIsleApiException(
        code: 'storage_quota_exceeded',
        message: '个人空间已满',
        statusCode: 507,
      );
    }
    if (method == 'POST' && path.endsWith('/files/folders')) {
      folders.add((body! as Map)['path'].toString());
      return {'created': true};
    }
    if (method == 'POST' && path.endsWith('/uploads')) {
      final req = body! as Map;
      final id = req['uploadID']?.toString() ?? 'u-${_uploads.length}';
      final target = req['path'].toString();
      final size = req['size'] as int;
      _uploads[id] = (path: target, size: size, bytes: BytesBuilder(copy: false));
      return {'id': id, 'path': target, 'size': size, 'offset': 0};
    }
    if (method == 'POST' && path.endsWith('/complete')) {
      final parts = path.split('/');
      final id = parts[parts.length - 2];
      final up = _uploads.remove(id)!;
      files[up.path] = up.bytes.takeBytes();
      return {'completed': true, 'path': up.path};
    }
    throw StateError('Unexpected $method $path');
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int offset,
  ) async {
    if (simulateQuotaFull) {
      throw const LightIsleApiException(
        code: 'storage_quota_exceeded',
        message: '个人空间已满',
        statusCode: 507,
      );
    }
    final up = _uploads[id]!;
    await for (final chunk in data) {
      up.bytes.add(chunk);
    }
    return {'id': id, 'path': up.path, 'size': up.size, 'offset': up.bytes.length};
  }

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    final remotePath = query?['path'] ?? '';
    final bytes = files[remotePath];
    if (bytes == null) {
      throw const LightIsleApiException(
        code: 'not_found',
        message: '远端文件不存在',
        statusCode: 404,
      );
    }
    final payload = corruptNextDownload
        ? Uint8List.fromList(List<int>.filled(bytes.length, 0x58))
        : bytes;
    corruptNextDownload = false;
    final out = File(destination);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(payload, flush: true);
    onProgress?.call(payload.length, payload.length);
  }

  @override
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String expectedSHA256, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) async {
    final data = files[path];
    if (data == null || data.length != expectedSize) return false;
    return sha256.convert(data).toString() == expectedSHA256;
  }
}

class _TrackedDirectoryAccess extends DesktopDirectoryAccess {
  _TrackedDirectoryAccess(this.path);

  final String path;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<DesktopPickedFolder?> pickDirectory() async =>
      DesktopPickedFolder(path: path);

  @override
  Future<DesktopDirectoryLease> startAccess(DesktopBackupTask task) async {
    startCalls++;
    return DesktopDirectoryLease(
      resolvedPath: task.localPath,
      stop: () async {
        stopCalls++;
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _RestoreAndWatchNasApi api;
  late _TrackedDirectoryAccess access;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('li-watch-restore-');
    api = _RestoreAndWatchNasApi();
    access = _TrackedDirectoryAccess(tempDir.path);
  });

  tearDown(() async {
    api.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  DesktopBackupTask makeTask({bool watchOnChange = true}) => DesktopBackupTask(
    id: 'task-1',
    label: '工作文档',
    localPath: tempDir.path,
    rootId: 'nas_main',
    rootGeneration: 1,
    rootName: '家庭主盘',
    remoteBasePath: 'WorkDocs',
    ignorePresets: const ['dev', 'temp'],
    watchOnChange: watchOnChange,
  );

  group('DesktopBackupWatcher', () {
    test('coalesces burst events via debounce, ignores filtered paths, and releases lease on stream error', () async {
      final streamController = StreamController<DesktopWatchEvent>.broadcast();
      addTearDown(streamController.close);

      final triggered = <String>[];
      final watcher = DesktopBackupWatcher(
        directoryAccess: access,
        debounceDuration: const Duration(milliseconds: 60),
        watchStreamFactory: (_) => streamController.stream,
        onTriggerBackup: (taskId) async {
          triggered.add(taskId);
        },
      );
      addTearDown(watcher.dispose);

      await watcher.syncTasks([makeTask(watchOnChange: true)]);
      expect(watcher.isWatching('task-1'), isTrue);
      expect(access.startCalls, 1);

      // Ignored paths must NOT trigger a backup.
      streamController.add(
        DesktopWatchEvent(path: '${tempDir.path}/node_modules/pkg/a.js'),
      );
      streamController.add(DesktopWatchEvent(path: '${tempDir.path}/.DS_Store'));
      streamController.add(DesktopWatchEvent(path: '${tempDir.path}/draft.tmp'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(triggered, isEmpty);

      // Burst of 3 real edits within debounce window -> coalesced to 1 trigger.
      streamController.add(DesktopWatchEvent(path: '${tempDir.path}/notes.md'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      streamController.add(DesktopWatchEvent(path: '${tempDir.path}/notes.md'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      streamController.add(DesktopWatchEvent(path: '${tempDir.path}/spec.md'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(triggered, ['task-1']);

      // Stream error (permission revoked / directory unmounted) -> safe release.
      streamController.addError(const FileSystemException('Permission denied'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(watcher.isWatching('task-1'), isFalse);
      expect(watcher.errorFor('task-1'), contains('变更监听已自动暂停'));
      expect(access.stopCalls, 1);
    });

    test('DesktopBackupController releases watcher on root offline and quota exhaustion', () async {
      final streamController = StreamController<DesktopWatchEvent>.broadcast();
      addTearDown(streamController.close);

      await File('${tempDir.path}/doc.txt').writeAsString('hello');

      final controller = DesktopBackupController(
        api: api,
        userId: 7,
        accountName: 'leo',
        directoryAccess: access,
        watcherDebounceDuration: const Duration(milliseconds: 40),
        watchStreamFactory: (_) => streamController.stream,
      );
      addTearDown(controller.dispose);
      await controller.initialize(enableWatchers: true);
      await controller.upsertTask(makeTask(watchOnChange: true));
      expect(controller.isWatchingTask('task-1'), isTrue);

      // Simulate quota full -> run triggers circuit breaker AND releases watcher.
      api.simulateQuotaFull = true;
      await controller.runTask('task-1');
      expect(controller.isWatchingTask('task-1'), isFalse);
      expect(controller.watcherErrorFor('task-1'), contains('配额或磁盘空间已满'));

      // Re-saving task re-arms watcher; root going offline releases it again.
      api.simulateQuotaFull = false;
      await controller.upsertTask(makeTask(watchOnChange: true));
      expect(controller.isWatchingTask('task-1'), isTrue);

      api.rootOnline = false;
      await controller.runTask('task-1');
      expect(controller.isWatchingTask('task-1'), isFalse);
      expect(controller.watcherErrorFor('task-1'), contains('当前离线'));
    });
  });

  group('DesktopBackupRestoreService', () {
    test('plans diff accurately, restores missing-only and backup-before-overwrite, verifies SHA-256, and never deletes local-only files', () async {
      // Seed NAS files
      api.files['WorkDocs/same.txt'] = Uint8List.fromList('identical'.codeUnits);
      api.files['WorkDocs/missing.txt'] = Uint8List.fromList('from-nas'.codeUnits);
      api.files['WorkDocs/sub/conflict.txt'] =
          Uint8List.fromList('nas-v2!!'.codeUnits); // same 8-byte length as local-v1!

      // Seed local directory: identical file, differing same-size file, and local-only file
      await File('${tempDir.path}/same.txt').writeAsString('identical');
      await Directory('${tempDir.path}/sub').create(recursive: true);
      await File('${tempDir.path}/sub/conflict.txt').writeAsString('local-v1');
      await File('${tempDir.path}/local_only.txt').writeAsString('never delete');

      final service = DesktopBackupRestoreService(
        api: api,
        directoryAccess: access,
      );
      final task = makeTask(watchOnChange: false);

      final plan = await service.buildPlan(task);
      expect(plan.identicalItems.map((e) => e.relativePath), ['same.txt']);
      expect(plan.missingItems.map((e) => e.relativePath), ['missing.txt']);
      expect(
        plan.conflictItems.map((e) => e.relativePath),
        ['sub/conflict.txt'],
      );
      expect(plan.localOnlyCount, 1);

      // 1. missingOnly strategy: downloads missing.txt, leaves conflict.txt untouched
      final missingRes = await service.executeRestore(
        plan,
        strategy: DesktopRestoreConflictStrategy.missingOnly,
        verifySha256: true,
      );
      expect(missingRes.downloaded, 1);
      expect(missingRes.backedUpAndReplaced, 0);
      expect(missingRes.skippedExisting, 1);
      expect(missingRes.verifiedSha256Count, 1);
      expect(missingRes.failures, isEmpty);
      expect(await File('${tempDir.path}/missing.txt').readAsString(), 'from-nas');
      expect(
        await File('${tempDir.path}/sub/conflict.txt').readAsString(),
        'local-v1',
      );
      expect(
        await File('${tempDir.path}/local_only.txt').readAsString(),
        'never delete',
      );

      // 2. SHA-256 corruption check during backupAndOverwrite -> must NOT overwrite local file
      final plan2 = await service.buildPlan(task);
      expect(plan2.missingItems, isEmpty);
      expect(plan2.conflictItems.length, 1);

      api.corruptNextDownload = true;
      final corruptRes = await service.executeRestore(
        plan2,
        strategy: DesktopRestoreConflictStrategy.backupAndOverwrite,
        verifySha256: true,
      );
      expect(corruptRes.failures.length, 1);
      expect(corruptRes.failures.single.reason, contains('SHA-256'));
      expect(
        await File('${tempDir.path}/sub/conflict.txt').readAsString(),
        'local-v1',
      );
      expect(
        await File('${tempDir.path}/sub/conflict.txt.lightisle-bak').exists(),
        isFalse,
      );

      // 3. Normal backupAndOverwrite -> preserves .lightisle-bak and writes NAS version
      final replaceRes = await service.executeRestore(
        plan2,
        strategy: DesktopRestoreConflictStrategy.backupAndOverwrite,
        verifySha256: true,
      );
      expect(replaceRes.backedUpAndReplaced, 1);
      expect(replaceRes.verifiedSha256Count, 1);
      expect(replaceRes.failures, isEmpty);
      expect(
        await File('${tempDir.path}/sub/conflict.txt').readAsString(),
        'nas-v2!!',
      );
      expect(
        await File('${tempDir.path}/sub/conflict.txt.lightisle-bak')
            .readAsString(),
        'local-v1',
      );
      expect(
        await File('${tempDir.path}/local_only.txt').readAsString(),
        'never delete',
        reason: 'restore must never delete extra local files',
      );
    });

    test('restore fails closed when target root generation changes', () async {
      api.rootGeneration = 2;
      final service = DesktopBackupRestoreService(
        api: api,
        directoryAccess: access,
      );
      await expectLater(
        service.buildPlan(makeTask(watchOnChange: false)),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('代际已变更')),
        ),
      );
    });
  });
}
