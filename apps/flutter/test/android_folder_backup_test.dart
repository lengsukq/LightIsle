import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/android_folder_backup_access.dart';
import 'package:lightisle/features/files/desktop_backup_engine.dart';
import 'package:lightisle/features/files/desktop_backup_models.dart';
import 'package:lightisle/features/files/desktop_folder_backup_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AndroidBackupNasApi extends LightIsleApi {
  _AndroidBackupNasApi() : super('http://127.0.0.1:1');

  int rootGeneration = 1;
  bool rootOnline = true;
  bool quotaFull = false;
  int uploadCalls = 0;
  int shaProbeCalls = 0;

  final Set<String> folders = <String>{'.', 'AndroidBackup'};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, Uint8List> trashed = <String, Uint8List>{};
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
            'name': '主盘',
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
    if (quotaFull) {
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
      uploadCalls++;
      final req = body! as Map;
      final id = req['uploadID']?.toString() ?? 'u-$uploadCalls';
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
    if (method == 'DELETE' && path.endsWith('/files')) {
      final target = query!['path']!;
      final removed = files.remove(target);
      if (removed != null) trashed[target] = removed;
      return {'deleted': true};
    }
    if (method == 'POST' && path.endsWith('/files/operations')) {
      final req = body! as Map;
      final from = req['from'].toString();
      final to = req['to'].toString();
      files[to] = files.remove(from)!;
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
    await for (final chunk in data) {
      up.bytes.add(chunk);
    }
    return {'id': id, 'path': up.path, 'size': up.size, 'offset': up.bytes.length};
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

class _VirtualSafEntry {
  _VirtualSafEntry({
    required this.docUri,
    required this.relativePath,
    required this.fileName,
    required this.bytes,
    required this.modifiedMs,
  });

  final String docUri;
  final String relativePath;
  final String fileName;
  Uint8List bytes;
  int modifiedMs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const treeUri =
      'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FWeiXin';

  late _AndroidBackupNasApi api;
  late Map<String, _VirtualSafEntry> safEntries;
  late bool accessGranted;
  late bool simulateMidReadChange;
  late int hashCalls;
  late int readChunkCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _AndroidBackupNasApi();
    accessGranted = true;
    simulateMidReadChange = false;
    hashCalls = 0;
    readChunkCalls = 0;
    safEntries = <String, _VirtualSafEntry>{
      'doc://1': _VirtualSafEntry(
        docUri: 'doc://1',
        relativePath: 'invoice.pdf',
        fileName: 'invoice.pdf',
        bytes: Uint8List.fromList('pdf-content-v1'.codeUnits),
        modifiedMs: 1700000000000,
      ),
      'doc://2': _VirtualSafEntry(
        docUri: 'doc://2',
        relativePath: 'sub/notes.txt',
        fileName: 'notes.txt',
        bytes: Uint8List.fromList('hello android saf'.codeUnits),
        modifiedMs: 1700000001000,
      ),
    };

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidFolderBackupAccess.defaultChannel, (
          call,
        ) async {
          final args = (call.arguments as Map?) ?? const {};
          switch (call.method) {
            case 'pickDirectory':
              return <String, Object?>{
                'treeUri': treeUri,
                'displayName': 'WeiXin',
                'displayPath': '内部存储/Download/WeiXin',
              };
            case 'checkAccess':
              if (!accessGranted) {
                throw PlatformException(
                  code: 'folder_access_revoked',
                  message: 'Android 文件夹读取授权已失效，请编辑任务重新选择文件夹。',
                );
              }
              return <String, Object?>{
                'accessible': true,
                'displayName': 'WeiXin',
                'displayPath': '内部存储/Download/WeiXin',
              };
            case 'scanDirectory':
              return <String, Object?>{
                'files': [
                  for (final e in safEntries.values)
                    <String, Object?>{
                      'documentId': e.docUri,
                      'documentUri': e.docUri,
                      'relativePath': e.relativePath,
                      'parentRelativeDir': e.relativePath.contains('/')
                          ? e.relativePath.substring(
                              0,
                              e.relativePath.lastIndexOf('/'),
                            )
                          : '',
                      'fileName': e.fileName,
                      'size': e.bytes.length,
                      'modifiedMs': e.modifiedMs,
                    },
                ],
                'failures': const <Object>[],
                'skippedIgnored': 1,
                'skippedOversized': 0,
                'skippedSymlinks': 0,
              };
            case 'statFile':
              final entry = safEntries[args['documentUri']?.toString()];
              if (entry == null) return null;
              return <String, Object?>{
                'size': entry.bytes.length,
                'modifiedMs': entry.modifiedMs,
              };
            case 'hashFile':
              hashCalls++;
              final entry = safEntries[args['documentUri']?.toString()]!;
              return <String, Object?>{
                'sha256': sha256.convert(entry.bytes).toString(),
                'size': entry.bytes.length,
                'modifiedMs': entry.modifiedMs,
                'chunkDigests': const <String>[],
              };
            case 'readChunk':
              readChunkCalls++;
              if (simulateMidReadChange) {
                simulateMidReadChange = false;
                throw PlatformException(
                  code: 'folder_source_changed',
                  message: '文件在上传期间发生变化',
                );
              }
              final entry = safEntries[args['documentUri']?.toString()]!;
              final offset = (args['offset'] as num).toInt();
              final length = (args['length'] as num).toInt();
              return Uint8List.sublistView(entry.bytes, offset, offset + length);
            case 'cancelRequest':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    api.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AndroidFolderBackupAccess.defaultChannel,
          null,
        );
  });

  test('Android SAF folder backup streams upload, hits fast skip, handles 2-phase replace, mid-read change, and revoked grant', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      const platformAccess = PlatformDesktopDirectoryAccess();
      expect(platformAccess.supportsWatch, isFalse);
      expect(platformAccess.supportsRestore, isFalse);

      final picked = await platformAccess.pickDirectory();
      expect(picked, isNotNull);
      expect(picked!.path, treeUri);
      expect(picked.displayPath, '内部存储/Download/WeiXin');

      final controller = DesktopBackupController(
        api: api,
        userId: 7,
        accountName: 'leo',
        directoryAccess: platformAccess,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.upsertTask(
        DesktopBackupTask(
          id: 'android-wx',
          label: '微信下载',
          localPath: picked.path,
          localDisplayPath: picked.displayPath,
          rootId: 'nas_main',
          rootGeneration: 1,
          rootName: '主盘',
          remoteBasePath: 'AndroidBackup',
          ignorePresets: const ['temp'],
        ),
      );

      // Run 1: streaming upload from SAF
      final run1 = await controller.runTask('android-wx');
      expect(run1, isNotNull);
      expect(run1!.uploadedNew, 2);
      expect(run1.failedCount, 0);
      expect(hashCalls, 2);
      expect(readChunkCalls, 2);
      expect(
        String.fromCharCodes(api.files['AndroidBackup/invoice.pdf']!),
        'pdf-content-v1',
      );
      expect(
        String.fromCharCodes(api.files['AndroidBackup/sub/notes.txt']!),
        'hello android saf',
      );

      // Run 2: fast skip -> zero uploads, zero native hash calls, zero SHA probes
      final prevUploads = api.uploadCalls;
      final prevHashes = hashCalls;
      final prevProbes = api.shaProbeCalls;
      final run2 = await controller.runTask('android-wx');
      expect(run2!.skippedUnchanged, 2);
      expect(api.uploadCalls, prevUploads);
      expect(hashCalls, prevHashes);
      expect(api.shaProbeCalls, prevProbes);

      // Modify doc://1 and simulate mid-read source change -> safe failure, old NAS file intact
      safEntries['doc://1']!.bytes = Uint8List.fromList('pdf-content-v2'.codeUnits);
      safEntries['doc://1']!.modifiedMs += 5000;
      simulateMidReadChange = true;

      final run3 = await controller.runTask('android-wx');
      expect(run3!.failedCount, 1);
      expect(
        String.fromCharCodes(api.files['AndroidBackup/invoice.pdf']!),
        'pdf-content-v1',
      );

      // Retry failure -> 2-phase trashAndReplace completes cleanly
      final run4 = await controller.runTask('android-wx', retryFailuresOnly: true);
      expect(run4!.updatedReplaced, 1);
      expect(run4.failedCount, 0);
      expect(
        String.fromCharCodes(api.files['AndroidBackup/invoice.pdf']!),
        'pdf-content-v2',
      );
      expect(
        String.fromCharCodes(api.trashed['AndroidBackup/invoice.pdf']!),
        'pdf-content-v1',
      );

      // Revoked SAF permission -> fails closed with actionable Chinese error
      accessGranted = false;
      final run5 = await controller.runTask('android-wx');
      expect(run5, isNull);
      expect(controller.tasks.single.lastError, contains('授权已失效'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android SettingsPage shows BOTH mobile photo backup and local folder backup entries', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SettingsPage(
              api: api,
              identity: const {'id': 7, 'username': 'leo', 'role': 'member'},
              onLogout: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settingsMobilePhotoBackupTile')),
        findsOneWidget,
      );
      final folderTile = find.byKey(
        const ValueKey('settingsDesktopFolderBackupTile'),
      );
      expect(folderTile, findsOneWidget);

      await tester.tap(folderTile);
      await tester.pumpAndSettle();

      expect(find.byType(DesktopFolderBackupPage), findsOneWidget);
      expect(find.text('本机文件夹单向增量备份'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
