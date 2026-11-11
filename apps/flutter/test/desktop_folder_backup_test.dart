import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/desktop_backup_engine.dart';
import 'package:lightisle/features/files/desktop_backup_models.dart';
import 'package:lightisle/features/files/desktop_folder_backup_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _InMemoryNasApi extends LightIsleApi {
  _InMemoryNasApi() : super('http://127.0.0.1:1');

  int rootGeneration = 1;
  bool rootOnline = true;
  bool failNextStagingUpload = false;
  int uploadBeginCalls = 0;
  int shaProbeCalls = 0;
  int trashDeleteCalls = 0;
  int moveOperationCalls = 0;

  final Set<String> folders = <String>{
    '.',
    'Users',
    'Users/u7',
    'Users/u7/files',
  };
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, Uint8List> trashedFiles = <String, Uint8List>{};
  final Map<String, ({String path, int size, BytesBuilder bytes})> _uploads =
      <String, ({String path, int size, BytesBuilder bytes})>{};

  static String _parentOf(String relPath) {
    final slash = relPath.lastIndexOf('/');
    return slash < 0 ? '.' : relPath.substring(0, slash);
  }

  static String _nameOf(String relPath) {
    final slash = relPath.lastIndexOf('/');
    return slash < 0 ? relPath : relPath.substring(slash + 1);
  }

  String _nextAvailableRename(String requested) {
    if (!files.containsKey(requested) && !folders.contains(requested)) {
      return requested;
    }
    final dir = _parentOf(requested);
    final base = _nameOf(requested);
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    for (var n = 1; n < 100; n++) {
      final candidateName = '$stem ($n)$ext';
      final candidate = dir == '.' ? candidateName : '$dir/$candidateName';
      if (!files.containsKey(candidate) && !folders.contains(candidate)) {
        return candidate;
      }
    }
    throw StateError('Unable to rename $requested');
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
    if (path == '/api/v2/me/storage') {
      return {
        'userId': 7,
        'enforcement': 'pending',
        'locations': [
          {
            'category': 'files',
            'rootID': 'nas_main',
            'rootGeneration': rootGeneration,
            'relativePath': 'Users/u7/files',
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
      final entries = <Map<String, Object>>[];
      for (final folder in folders) {
        if (folder != '.' && _parentOf(folder) == dir) {
          entries.add({
            'name': _nameOf(folder),
            'path': folder,
            'type': 'folder',
            'size': 0,
          });
        }
      }
      for (final entry in files.entries) {
        if (_parentOf(entry.key) == dir) {
          entries.add({
            'name': _nameOf(entry.key),
            'path': entry.key,
            'type': 'file',
            'size': entry.value.length,
          });
        }
      }
      return {
        'path': dir,
        'canWrite': true,
        'entries': entries,
        'nextCursor': '',
      };
    }
    if (path.contains('/uploads/')) {
      final id = path.split('/').last;
      final up = _uploads[id];
      if (up == null) {
        throw const LightIsleApiException(
          code: 'not_found',
          message: '上传任务不存在',
          statusCode: 404,
        );
      }
      return {
        'id': id,
        'path': up.path,
        'size': up.size,
        'offset': up.bytes.length,
      };
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
    if (method == 'POST' && path.endsWith('/files/folders')) {
      final target = (body! as Map)['path'].toString();
      if (folders.contains(target) || files.containsKey(target)) {
        throw const LightIsleApiException(
          code: 'conflict',
          message: '已存在',
          statusCode: 409,
        );
      }
      folders.add(target);
      return {'created': true, 'path': target};
    }
    if (method == 'POST' && path.endsWith('/uploads')) {
      uploadBeginCalls++;
      final req = body! as Map;
      final rawPath = req['path'].toString();
      if (failNextStagingUpload && rawPath.contains('_sync_')) {
        failNextStagingUpload = false;
        throw const LightIsleApiException(
          code: 'network_error',
          message: '模拟暂存上传网络中断',
          statusCode: 503,
        );
      }
      final onConflict = req['onConflict']?.toString() ?? '';
      final resolved = onConflict == 'rename'
          ? _nextAvailableRename(rawPath)
          : rawPath;
      if (onConflict.isEmpty &&
          (files.containsKey(resolved) || folders.contains(resolved))) {
        throw const LightIsleApiException(
          code: 'destination_exists',
          message: '目标位置已存在同名文件',
          statusCode: 409,
        );
      }
      final id = req['uploadID']?.toString() ?? 'up-$uploadBeginCalls';
      final size = req['size'] as int;
      _uploads[id] = (
        path: resolved,
        size: size,
        bytes: BytesBuilder(copy: false),
      );
      return {'id': id, 'path': resolved, 'size': size, 'offset': 0};
    }
    if (method == 'POST' && path.endsWith('/complete')) {
      final parts = path.split('/');
      final id = parts[parts.length - 2];
      final up = _uploads.remove(id)!;
      final data = up.bytes.takeBytes();
      expect(data.length, up.size);
      if (files.containsKey(up.path)) {
        throw const LightIsleApiException(
          code: 'destination_exists',
          message: '目标冲突',
          statusCode: 409,
        );
      }
      files[up.path] = data;
      return {'completed': true, 'path': up.path};
    }
    if (method == 'DELETE' && path.endsWith('/files')) {
      trashDeleteCalls++;
      final target = query!['path']!;
      final removed = files.remove(target);
      if (removed == null) {
        throw const LightIsleApiException(
          code: 'not_found',
          message: '不存在',
          statusCode: 404,
        );
      }
      trashedFiles[target] = removed;
      return {'deleted': true};
    }
    if (method == 'POST' && path.endsWith('/files/operations')) {
      moveOperationCalls++;
      final req = body! as Map;
      expect(req['action'], 'move');
      final from = req['from'].toString();
      final to = req['to'].toString();
      if (files.containsKey(to)) {
        throw const LightIsleApiException(
          code: 'destination_exists',
          message: '目标已存在',
          statusCode: 409,
        );
      }
      final moved = files.remove(from);
      if (moved == null) {
        throw const LightIsleApiException(
          code: 'not_found',
          message: '来源不存在',
          statusCode: 404,
        );
      }
      files[to] = moved;
      return {'moved': true};
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
    final up = _uploads[id]!;
    expect(offset, up.bytes.length);
    var got = 0;
    await for (final part in data) {
      up.bytes.add(part);
      got += part.length;
    }
    expect(got, length);
    return {
      'id': id,
      'path': up.path,
      'size': up.size,
      'offset': up.bytes.length,
    };
  }

  @override
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String expectedSHA256, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) async {
    shaProbeCalls++;
    final data = files[path];
    if (data == null || data.length != expectedSize) return false;
    return sha256.convert(data).toString() == expectedSHA256;
  }
}

class _FakeDirectoryAccess extends DesktopDirectoryAccess {
  _FakeDirectoryAccess(this.pickedPath);

  String pickedPath;
  String? bookmark = 'bm-v1';
  int stopCalls = 0;

  @override
  Future<DesktopPickedFolder?> pickDirectory() async =>
      DesktopPickedFolder(path: pickedPath, bookmarkBase64: bookmark);

  @override
  Future<DesktopDirectoryLease> startAccess(DesktopBackupTask task) async =>
      DesktopDirectoryLease(
        resolvedPath: task.localPath,
        stop: () async {
          stopCalls++;
        },
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _InMemoryNasApi api;
  late _FakeDirectoryAccess dirAccess;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('lightisle-desktop-sync-');
    api = _InMemoryNasApi();
    dirAccess = _FakeDirectoryAccess(tempDir.path);
  });

  tearDown(() async {
    api.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  DesktopBackupTask makeTask({
    DesktopConflictPolicy conflictPolicy =
        DesktopConflictPolicy.trashAndReplace,
    bool ignoreHidden = true,
  }) => DesktopBackupTask(
    id: 'task-docs',
    label: '工作文档',
    localPath: tempDir.path,
    bookmarkBase64: 'bm-v1',
    rootId: 'nas_main',
    rootGeneration: 1,
    rootName: '家庭主盘',
    remoteBasePath: 'Users/u7/files/WorkDocs',
    conflictPolicy: conflictPolicy,
    ignoreHidden: ignoreHidden,
  );

  test('one-way incremental sync: initial tree upload, fast (size,mtime) skip, 2-phase trashAndReplace, interrupted network safety, symlink & junk filtering, and no remote delete', () async {
    // Populate local folder with nested files, 0-byte file, junk, dotfile, and symlink
    await File('${tempDir.path}/readme.md').writeAsString('hello v1');
    await Directory('${tempDir.path}/sub/deep').create(recursive: true);
    await File('${tempDir.path}/sub/deep/empty.txt').writeAsBytes(const []);
    await File('${tempDir.path}/.DS_Store').writeAsString('junk');
    await File('${tempDir.path}/.secret_env').writeAsString('hidden');
    await File('${tempDir.path}/.lightisle-stage').writeAsString('reserved');
    final externalTarget = await Directory.systemTemp.createTemp(
      'lightisle-symlink-target-',
    );
    addTearDown(() async {
      if (await externalTarget.exists()) {
        await externalTarget.delete(recursive: true);
      }
    });
    await File('${externalTarget.path}/outside.txt').writeAsString('outside');
    await Link('${tempDir.path}/linked_outside')
        .create('${externalTarget.path}/outside.txt');

    final controller = DesktopBackupController(
      api: api,
      userId: 7,
      accountName: 'leo',
      directoryAccess: dirAccess,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.upsertTask(makeTask());

    // Run 1: Initial upload
    final run1 = await controller.runTask('task-docs');
    expect(run1, isNotNull);
    expect(run1!.uploadedNew, 2);
    expect(run1.updatedReplaced, 0);
    expect(run1.skippedUnchanged, 0);
    expect(run1.skippedSymlinks, 1);
    expect(run1.failedCount, 0);
    expect(dirAccess.stopCalls, 1);

    expect(
      String.fromCharCodes(api.files['Users/u7/files/WorkDocs/readme.md']!),
      'hello v1',
    );
    expect(api.files['Users/u7/files/WorkDocs/sub/deep/empty.txt'], isEmpty);
    expect(api.files.containsKey('Users/u7/files/WorkDocs/.DS_Store'), false);
    expect(api.files.containsKey('Users/u7/files/WorkDocs/.secret_env'), false);
    expect(
      api.files.containsKey('Users/u7/files/WorkDocs/linked_outside'),
      false,
    );

    // Run 2: Unchanged local files -> fast-path skip with ZERO uploads & ZERO SHA probes
    final uploadsBeforeRun2 = api.uploadBeginCalls;
    final probesBeforeRun2 = api.shaProbeCalls;
    final run2 = await controller.runTask('task-docs');
    expect(run2!.uploadedNew, 0);
    expect(run2.updatedReplaced, 0);
    expect(run2.skippedUnchanged, 2);
    expect(api.uploadBeginCalls, uploadsBeforeRun2);
    expect(api.shaProbeCalls, probesBeforeRun2);

    // Modify readme.md locally, and simulate network drop during staging upload:
    // Old file on NAS MUST remain intact ("hello v1")!
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File('${tempDir.path}/readme.md').writeAsString('hello v2 updated');
    api.failNextStagingUpload = true;

    final interruptedRun = await controller.runTask('task-docs');
    expect(interruptedRun!.failedCount, 1);
    expect(
      String.fromCharCodes(api.files['Users/u7/files/WorkDocs/readme.md']!),
      'hello v1',
      reason: 'failed staging upload must never corrupt or delete existing NAS file',
    );
    expect(api.trashedFiles, isEmpty);

    // Retry failures only -> completes 2-phase trashAndReplace!
    final retryRun = await controller.runTask(
      'task-docs',
      retryFailuresOnly: true,
    );
    expect(retryRun!.updatedReplaced, 1);
    expect(retryRun.failedCount, 0);
    expect(api.trashDeleteCalls, 1);
    expect(api.moveOperationCalls, 1);
    expect(
      String.fromCharCodes(
        api.trashedFiles['Users/u7/files/WorkDocs/readme.md']!,
      ),
      'hello v1',
    );
    expect(
      String.fromCharCodes(api.files['Users/u7/files/WorkDocs/readme.md']!),
      'hello v2 updated',
    );

    // Delete local file -> one-way backup MUST preserve NAS copy!
    await File('${tempDir.path}/sub/deep/empty.txt').delete();
    final afterLocalDelete = await controller.runTask('task-docs');
    expect(afterLocalDelete!.failedCount, 0);
    expect(
      api.files.containsKey('Users/u7/files/WorkDocs/sub/deep/empty.txt'),
      true,
      reason: 'one-way backup must never delete remote files',
    );
  });

  test('keepBoth conflict policy renames modified file without duplicating on repeat run, and root offline/generation mismatch fails closed', () async {
    final doc = File('${tempDir.path}/budget.txt');
    await doc.writeAsString('2026-Q1');

    final controller = DesktopBackupController(
      api: api,
      userId: 7,
      accountName: 'leo',
      directoryAccess: dirAccess,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.upsertTask(
      makeTask(conflictPolicy: DesktopConflictPolicy.keepBoth),
    );

    await controller.runTask('task-docs');
    expect(
      String.fromCharCodes(api.files['Users/u7/files/WorkDocs/budget.txt']!),
      '2026-Q1',
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await doc.writeAsString('2026-Q2-revised');
    final updateRun = await controller.runTask('task-docs');
    expect(updateRun!.updatedReplaced, 1);
    expect(
      String.fromCharCodes(api.files['Users/u7/files/WorkDocs/budget.txt']!),
      '2026-Q1',
    );
    expect(
      String.fromCharCodes(
        api.files['Users/u7/files/WorkDocs/budget (1).txt']!,
      ),
      '2026-Q2-revised',
    );

    // Subsequent run without local edits must hit fast skip, NOT create budget (2).txt!
    final repeatRun = await controller.runTask('task-docs');
    expect(repeatRun!.updatedReplaced, 0);
    expect(repeatRun.skippedUnchanged, 1);
    expect(
      api.files.containsKey('Users/u7/files/WorkDocs/budget (2).txt'),
      false,
    );

    // Simulate physical disk replacement (rootGeneration advances from 1 -> 2): must fail closed!
    api.rootGeneration = 2;
    final mismatchResult = await controller.runTask('task-docs');
    expect(mismatchResult, isNull);
    expect(controller.tasks.single.lastError, contains('代际已变更'));

    // Simulate target disk offline: must fail closed!
    api.rootGeneration = 1;
    api.rootOnline = false;
    final offlineResult = await controller.runTask('task-docs');
    expect(offlineResult, isNull);
    expect(controller.tasks.single.lastError, contains('当前离线'));
  });

  testWidgets(
    'Desktop SettingsPage shows DesktopFolderBackupPage entry and opens task list cleanly',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: SettingsPage(
                api: api,
                identity: const {'id': 7, 'username': 'leo', 'role': 'admin'},
                onLogout: () async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final tile = find.byKey(
          const ValueKey('settingsDesktopFolderBackupTile'),
        );
        expect(tile, findsOneWidget);
        expect(
          find.byKey(const ValueKey('settingsMobilePhotoBackupTile')),
          findsNothing,
        );

        await tester.tap(tile);
        await tester.pumpAndSettle();

        expect(find.byType(DesktopFolderBackupPage), findsOneWidget);
        expect(find.text('本机文件夹单向增量备份'), findsOneWidget);
        expect(find.text('添加第一个备份文件夹'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test('PlatformDesktopDirectoryAccess aligns macOS startAccess/stopAccess contract for non-sandbox empty accessId and stale refreshedBookmark', () async {
    const channel = MethodChannel('lightisle/desktop-folders');
    final stoppedIds = <String>[];
    var nextAccessId = '';
    String? nextRefreshedBookmark;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?) ?? const {};
          switch (call.method) {
            case 'startAccess':
              expect(args['path'], tempDir.path);
              return <String, Object?>{
                'accessId': nextAccessId,
                'path': tempDir.path,
                'refreshedBookmark': ?nextRefreshedBookmark,
              };
            case 'stopAccess':
              stoppedIds.add(args['accessId'].toString());
              return true;
            default:
              return null;
          }
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      const access = PlatformDesktopDirectoryAccess();
      // 1. Non-sandboxed build returns empty accessId -> succeeds & stop is a no-op
      final nonSandboxLease = await access.startAccess(makeTask());
      expect(nonSandboxLease.resolvedPath, tempDir.path);
      expect(nonSandboxLease.refreshedBookmarkBase64, isNull);
      await nonSandboxLease.stop();
      expect(stoppedIds, isEmpty);

      // 2. Sandboxed build with stale bookmark returns accessId + refreshedBookmark
      nextAccessId = 'scope-uuid-42';
      nextRefreshedBookmark = 'bm-v2-refreshed';
      final sandboxLease = await access.startAccess(makeTask());
      expect(sandboxLease.resolvedPath, tempDir.path);
      expect(sandboxLease.refreshedBookmarkBase64, 'bm-v2-refreshed');
      await sandboxLease.stop();
      expect(stoppedIds, ['scope-uuid-42']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
