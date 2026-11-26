import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/mobile_photo_backup_page.dart';
import 'package:lightisle/features/files/photo_backup_prefs_schema.dart';
import 'package:lightisle/features/files/photo_backup_verified_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AlbumReleaseMockApi extends LightIsleApi {
  _AlbumReleaseMockApi() : super('http://127.0.0.1:1');

  bool rootOnline = true;
  int activeRootGeneration = 5;
  final List<String> createdFolders = <String>[];
  final List<String> sha256Queries = <String>[];
  final Map<String, ({int size, String sha256})> remoteFiles = {};

  String? _uploadPath;
  int _uploadSize = 0;
  int _uploadOffset = 0;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  @override
  Map<String, String> get mediaHeaders => const {
    HttpHeaders.cookieHeader:
        'lightisle_session=testsession_012345678901234567890123456789',
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots') {
      return {
        'roots': [
          {
            'rootID': 'disk_main',
            'name': '照片盘',
            'generation': activeRootGeneration,
            'online': rootOnline,
          },
        ],
      };
    }
    if (path == '/api/v2/roots/disk_main/files') {
      return {'path': query?['path'] ?? '.', 'entries': []};
    }
    if (path == '/api/v2/roots/disk_main/files/sha256') {
      final requestedPath = query?['path'] ?? '';
      sha256Queries.add(requestedPath);
      final reqGen = int.tryParse(query?['rootGeneration'] ?? '');
      if (!rootOnline) {
        throw const LightIsleApiException(
          statusCode: 503,
          code: 'root_unavailable',
          message: '硬盘离线',
        );
      }
      if (reqGen != activeRootGeneration) {
        throw const LightIsleApiException(
          statusCode: 409,
          code: 'root_generation_changed',
          message: '硬盘已更换',
        );
      }
      final stored = remoteFiles[requestedPath];
      if (stored == null) {
        throw const LightIsleApiException(
          statusCode: 404,
          code: 'not_found',
          message: '文件不存在',
        );
      }
      return {
        'algorithm': 'sha256',
        'sha256': stored.sha256,
        'size': stored.size,
      };
    }
    if (path.startsWith('/api/v2/roots/disk_main/uploads/')) {
      return {
        'id': 'up-1',
        'path': _uploadPath,
        'size': _uploadSize,
        'offset': _uploadOffset,
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
    if (path == '/api/v2/roots/disk_main/files/folders') {
      createdFolders.add((body! as Map)['path'].toString());
      return {'created': true};
    }
    if (path == '/api/v2/roots/disk_main/uploads') {
      final req = body! as Map;
      _uploadPath = req['path'].toString();
      _uploadSize = req['size'] as int;
      _uploadOffset = 0;
      _buffer.clear();
      return {
        'id': 'up-1',
        'path': _uploadPath,
        'size': _uploadSize,
        'offset': 0,
      };
    }
    if (path.endsWith('/complete')) {
      final bytes = _buffer.takeBytes();
      remoteFiles[_uploadPath!] = (
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
      return {'completed': true};
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
    await for (final block in data) {
      _buffer.add(block);
      _uploadOffset += block.length;
    }
    return {
      'id': id,
      'path': _uploadPath,
      'size': _uploadSize,
      'offset': _uploadOffset,
    };
  }

  @override
  Future<bool> remoteFileHasSize(String path, int expectedSize) async =>
      remoteFiles[path]?.size == expectedSize;

  @override
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String expectedSHA256, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) async {
    final stored = remoteFiles[path];
    return stored != null &&
        stored.size == expectedSize &&
        stored.sha256 == expectedSHA256;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const photosChannel = MethodChannel('lightisle/photos');
  const backgroundChannel = MethodChannel('lightisle/photos-background');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photosChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundChannel, null);
  });

  group('PhotoBackupPrefsSchema', () {
    test('migrates legacy organizeByYearMonth and resolves all 4 organize modes', () async {
      const schema = PhotoBackupPrefsSchema(
        origin: 'http://127.0.0.1:8080',
        accountName: 'alice',
        deviceId: 'aabbccddeeff001122334455',
        rootIdentity: 'disk_1:2',
        baseDirectory: 'Users/u1/photos',
      );
      SharedPreferences.setMockInitialValues({
        schema.organizeByYearMonthKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        schema.resolveOrganizeMode(prefs),
        PhotoBackupPrefsSchema.organizeYearMonth,
      );

      final ts = DateTime(2026, 7, 15, 10, 0).millisecondsSinceEpoch ~/ 1000;
      expect(
        PhotoBackupPrefsSchema.resolveTargetDirectory(
          'Users/u1/photos/dev1',
          organizeMode: PhotoBackupPrefsSchema.organizeFlat,
          modified: ts,
          albumName: 'Camera',
        ),
        'Users/u1/photos/dev1',
      );
      expect(
        PhotoBackupPrefsSchema.resolveTargetDirectory(
          'Users/u1/photos/dev1',
          organizeMode: PhotoBackupPrefsSchema.organizeYearMonth,
          modified: ts,
          albumName: 'Camera',
        ),
        'Users/u1/photos/dev1/2026/07',
      );
      expect(
        PhotoBackupPrefsSchema.resolveTargetDirectory(
          'Users/u1/photos/dev1',
          organizeMode: PhotoBackupPrefsSchema.organizeByAlbum,
          modified: ts,
          albumName: '../旅行:京都/2026',
        ),
        'Users/u1/photos/dev1/_旅行_京都_2026',
      );
      expect(
        PhotoBackupPrefsSchema.resolveTargetDirectory(
          'Users/u1/photos/dev1',
          organizeMode: PhotoBackupPrefsSchema.organizeByAlbumYearMonth,
          modified: ts,
          albumName: '家庭合影',
        ),
        'Users/u1/photos/dev1/家庭合影/2026/07',
      );
    });

    test('isolates state prefix per album scope and album selection signature', () {
      const schema = PhotoBackupPrefsSchema(
        origin: 'http://127.0.0.1',
        accountName: 'alice',
        deviceId: '11223344556677889900aabb',
        rootIdentity: 'disk_1:2',
        baseDirectory: 'Users/u1/photos',
      );
      final p1 = schema.scopedStatePrefix(
        PhotoBackupPrefsSchema.albumScopeSelected,
        selectedAlbumIds: const ['101', '202'],
      );
      final p2 = schema.scopedStatePrefix(
        PhotoBackupPrefsSchema.albumScopeSelected,
        selectedAlbumIds: const ['202', '101'],
      );
      final p3 = schema.scopedStatePrefix(
        PhotoBackupPrefsSchema.albumScopeExcluded,
        selectedAlbumIds: const ['101', '202'],
      );
      expect(p1, p2);
      expect(p1, isNot(p3));
      expect(
        schema.scopedStatePrefix(PhotoBackupPrefsSchema.albumScopeCamera),
        '${schema.scope}.camera',
      );
    });
  });

  group('PhotoBackupVerifiedLedger', () {
    const schemaA = PhotoBackupPrefsSchema(
      origin: 'http://127.0.0.1',
      accountName: 'alice',
      deviceId: 'aaaaaaaaaaaaaaaaaaaaaaaa',
      rootIdentity: 'disk_a:1',
      baseDirectory: 'Users/u1/photos',
    );
    const schemaB = PhotoBackupPrefsSchema(
      origin: 'http://127.0.0.1',
      accountName: 'alice',
      deviceId: 'aaaaaaaaaaaaaaaaaaaaaaaa',
      rootIdentity: 'disk_a:2',
      baseDirectory: 'Users/u1/photos',
    );

    VerifiedPhotoBackupRecord makeRecord(
      String id, {
      required int sizeBytes,
      required int capturedAtMs,
      required int backedUpAtMs,
      bool isVideo = false,
      String albumName = 'Camera',
    }) => VerifiedPhotoBackupRecord(
      assetId: id,
      remotePath: 'Users/u1/photos/dev/photo_$id.jpg',
      sha256: 'a' * 64,
      sizeBytes: sizeBytes,
      capturedAtMs: capturedAtMs,
      backedUpAtMs: backedUpAtMs,
      isVideo: isVideo,
      albumName: albumName,
    );

    test('isolates by rootIdentity and enforces bounded cap', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const ledger = PhotoBackupVerifiedLedger(maxEntries: 2);

      await ledger.upsert(
        prefs,
        schemaA,
        makeRecord('1', sizeBytes: 100, capturedAtMs: 1000, backedUpAtMs: 10),
      );
      await ledger.upsert(
        prefs,
        schemaA,
        makeRecord('2', sizeBytes: 200, capturedAtMs: 2000, backedUpAtMs: 20),
      );
      await ledger.upsert(
        prefs,
        schemaA,
        makeRecord('3', sizeBytes: 300, capturedAtMs: 3000, backedUpAtMs: 30),
      );

      final itemsA = ledger.read(prefs, schemaA);
      expect(itemsA.map((e) => e.assetId).toList(), ['3', '2']);
      expect(ledger.read(prefs, schemaB), isEmpty);
    });

    test('filters by retention age, video type, and album name', () {
      final now = DateTime(2026, 11, 26);
      final records = [
        makeRecord(
          'recent',
          sizeBytes: 100,
          capturedAtMs: now.subtract(const Duration(days: 5)).millisecondsSinceEpoch,
          backedUpAtMs: now.millisecondsSinceEpoch,
          albumName: 'Camera',
        ),
        makeRecord(
          'month_old_video',
          sizeBytes: 500,
          capturedAtMs: now.subtract(const Duration(days: 45)).millisecondsSinceEpoch,
          backedUpAtMs: now.millisecondsSinceEpoch,
          isVideo: true,
          albumName: '旅行',
        ),
        makeRecord(
          'quarter_old',
          sizeBytes: 300,
          capturedAtMs: now.subtract(const Duration(days: 120)).millisecondsSinceEpoch,
          backedUpAtMs: now.millisecondsSinceEpoch,
          albumName: '旅行',
        ),
      ];

      expect(
        PhotoBackupVerifiedLedger.filterRecords(
          records,
          filter: SpaceReleaseFilter.olderThan30Days,
          now: now,
        ).map((e) => e.assetId),
        ['month_old_video', 'quarter_old'],
      );
      expect(
        PhotoBackupVerifiedLedger.filterRecords(
          records,
          filter: SpaceReleaseFilter.olderThan90Days,
          now: now,
        ).map((e) => e.assetId),
        ['quarter_old'],
      );
      expect(
        PhotoBackupVerifiedLedger.filterRecords(
          records,
          filter: SpaceReleaseFilter.videosOnly,
          now: now,
        ).map((e) => e.assetId),
        ['month_old_video'],
      );
      expect(
        PhotoBackupVerifiedLedger.filterRecords(
          records,
          filter: SpaceReleaseFilter.byAlbum,
          albumName: '旅行',
          now: now,
        ).map((e) => e.assetId),
        ['month_old_video', 'quarter_old'],
      );
    });
  });

  group('MobilePhotoBackupPage album selection and verified space release', () {
    testWidgets(
      'selects albums via picker, backs up byAlbumYearMonth, and manually releases only SHA-256 verified items',
      (tester) async {
        const deviceId = '1234567890abcdef12345678';
        SharedPreferences.setMockInitialValues({
          PhotoBackupPrefsSchema.installationIdKey: deviceId,
        });
        final api = _AlbumReleaseMockApi()
          ..selectRoot(
            const LightIsleRoot(
              id: 'disk_main',
              name: '照片盘',
              generation: 5,
              online: true,
            ),
          );
        addTearDown(api.close);

        final photoBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final photoDigest = sha256.convert(photoBytes).toString();
        final capturedSec =
            DateTime(2026, 3, 10, 12, 0).millisecondsSinceEpoch ~/ 1000;

        String? lastListScope;
        List<String>? lastListAlbumIds;
        final deleteRequests = <List<String>>[];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              backgroundChannel,
              (_) async => {'enabled': false, 'sessionMatches': false},
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(photosChannel, (call) async {
              final args = (call.arguments as Map?) ?? const {};
              switch (call.method) {
                case 'permission':
                case 'requestPermission':
                case 'isWifi':
                  return true;
                case 'listAlbums':
                  return {
                    'albums': [
                      {
                        'id': '1001',
                        'name': '旅行日记',
                        'relativePath': 'Pictures/Travel',
                        'count': 12,
                        'totalBytes': 24000,
                        'coverAssetId': '801',
                        'isCamera': false,
                        'kind': 'bucket',
                      },
                      {
                        'id': '1002',
                        'name': 'Screenshots',
                        'relativePath': 'Pictures/Screenshots',
                        'count': 5,
                        'totalBytes': 5000,
                        'coverAssetId': '802',
                        'isCamera': false,
                        'kind': 'bucket',
                      },
                    ],
                  };
                case 'list':
                  lastListScope = args['albumScope']?.toString();
                  lastListAlbumIds = (args['selectedAlbumIds'] as List?)
                      ?.map((e) => e.toString())
                      .toList();
                  return {
                    'supportsStream': true,
                    'version': 'ms:20',
                    'nextCursor': '',
                    'items': [
                      {
                        'id': '801',
                        'name': 'IMG_TRIP.jpg',
                        'modified': capturedSec,
                        'size': photoBytes.length,
                        'generation': 7,
                        'bucketId': '1001',
                        'bucketName': '旅行日记',
                        'isVideo': false,
                      },
                    ],
                  };
                case 'inspectAndHash':
                  return {
                    'size': photoBytes.length,
                    'modified': capturedSec,
                    'generation': 7,
                    'sha256': photoDigest,
                    'chunkDigests': const <String>[],
                  };
                case 'readChunk':
                  final offset = args['offset'] as int;
                  final length = args['length'] as int;
                  return Uint8List.sublistView(
                    photoBytes,
                    offset,
                    offset + length,
                  );
                case 'requestDeleteAssets':
                  final ids = (args['assetIds'] as List)
                      .map((e) => e.toString())
                      .toList();
                  deleteRequests.add(ids);
                  return {
                    'deleted': true,
                    'cancelled': false,
                    'deletedCount': ids.length,
                    'alreadyMissingCount': 0,
                  };
                default:
                  return true;
              }
            });

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: MobilePhotoBackupPage(
              api: api,
              accountName: 'owner',
              baseDirectory: 'Users/u7/photos',
              androidPlatformOverride: true,
              iosPlatformOverride: false,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Pick album "旅行日记"
        await tester.ensureVisible(
          find.byKey(const ValueKey('selectPhotoAlbumsTile')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('selectPhotoAlbumsTile')));
        await tester.pumpAndSettle();
        expect(find.text('旅行日记'), findsOneWidget);
        await tester.tap(find.text('旅行日记'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用相簿规则'));
        await tester.pumpAndSettle();

        // Switch organize mode to byAlbumYearMonth
        await tester.ensureVisible(
          find.byKey(const ValueKey('photoOrganizeModeDropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('photoOrganizeModeDropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('按相簿与年月（<相簿名>/YYYY/MM）').last);
        await tester.pumpAndSettle();

        // Run backup
        await tester.ensureVisible(find.text('检查并备份最近照片'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('检查并备份最近照片'));
          await Future<void>.delayed(const Duration(milliseconds: 350));
        });
        await tester.pumpAndSettle();

        expect(lastListScope, 'selected');
        expect(lastListAlbumIds, ['1001']);
        expect(
          api.remoteFiles.keys.single,
          contains('Users/u7/photos/$deviceId/旅行日记/2026/03/photo_801_'),
        );

        // Inject a corrupted remote record into ledger to verify mixed-batch safety
        final prefs = await SharedPreferences.getInstance();
        const schema = PhotoBackupPrefsSchema(
          origin: 'http://127.0.0.1:1',
          accountName: 'owner',
          deviceId: deviceId,
          rootIdentity: 'disk_main:5',
          baseDirectory: 'Users/u7/photos',
        );
        await const PhotoBackupVerifiedLedger().upsert(
          prefs,
          schema,
          VerifiedPhotoBackupRecord(
            assetId: '999',
            remotePath: 'Users/u7/photos/$deviceId/missing.jpg',
            sha256: 'b' * 64,
            sizeBytes: 123,
            capturedAtMs: capturedSec * 1000,
            backedUpAtMs: DateTime.now().millisecondsSinceEpoch,
            isVideo: false,
            albumName: '旅行日记',
          ),
        );

        // Re-open page so ledger picks up both 801 (valid) and 999 (missing on NAS)
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: MobilePhotoBackupPage(
              key: const ValueKey('reloadedBackupPage'),
              api: api,
              accountName: 'owner',
              baseDirectory: 'Users/u7/photos',
              androidPlatformOverride: true,
              iosPlatformOverride: false,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open manual space release sheet
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('manualSpaceReleaseButton')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('manualSpaceReleaseButton')),
        );
        await tester.pumpAndSettle();

        // Execute verify & release -> ONLY '801' should be submitted to OS delete; '999' safely skipped!
        await tester.runAsync(() async {
          await tester.tap(find.textContaining('核验并请求系统释放'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();

        expect(api.sha256Queries, hasLength(2));
        expect(deleteRequests, [
          ['801'],
        ]);
        expect(find.textContaining('已安全跳过并保留本机原片（1 项）'), findsOneWidget);
        expect(find.textContaining('已由系统确认释放 1 项本地原片'), findsWidgets);
      },
    );

    testWidgets(
      'blocks local deletion when physical root is offline or replaced',
      (tester) async {
        const deviceId = 'abcdef1234567890abcdef12';
        const schema = PhotoBackupPrefsSchema(
          origin: 'http://127.0.0.1:1',
          accountName: 'owner',
          deviceId: deviceId,
          rootIdentity: 'disk_main:5',
          baseDirectory: 'Users/u7/photos',
        );
        SharedPreferences.setMockInitialValues({
          PhotoBackupPrefsSchema.installationIdKey: deviceId,
        });
        final prefs = await SharedPreferences.getInstance();
        await const PhotoBackupVerifiedLedger().upsert(
          prefs,
          schema,
          VerifiedPhotoBackupRecord(
            assetId: '777',
            remotePath: 'Users/u7/photos/$deviceId/photo_777.jpg',
            sha256: 'c' * 64,
            sizeBytes: 512,
            capturedAtMs: DateTime(2025, 1, 1).millisecondsSinceEpoch,
            backedUpAtMs: DateTime.now().millisecondsSinceEpoch,
            isVideo: false,
            albumName: 'Camera',
          ),
        );

        final api = _AlbumReleaseMockApi()
          ..selectRoot(
            const LightIsleRoot(
              id: 'disk_main',
              name: '照片盘',
              generation: 5,
              online: true,
            ),
          )
          ..activeRootGeneration = 6; // Disk replaced!
        addTearDown(api.close);

        var deleteCalled = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              backgroundChannel,
              (_) async => {'enabled': false, 'sessionMatches': false},
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(photosChannel, (call) async {
              if (call.method == 'requestDeleteAssets') {
                deleteCalled++;
                return {'deleted': true, 'deletedCount': 1};
              }
              return true;
            });

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: MobilePhotoBackupPage(
              api: api,
              accountName: 'owner',
              baseDirectory: 'Users/u7/photos',
              androidPlatformOverride: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('manualSpaceReleaseButton')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('manualSpaceReleaseButton')),
        );
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          await tester.tap(find.textContaining('核验并请求系统释放'));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pumpAndSettle();

        expect(deleteCalled, 0);
        expect(find.textContaining('已离线或已更换'), findsOneWidget);
      },
    );

    testWidgets(
      'auto-prompt space release defaults to off and triggers OS confirmation flow after clean backup when enabled',
      (tester) async {
        const deviceId = 'fedcba9876543210fedcba98';
        SharedPreferences.setMockInitialValues({
          PhotoBackupPrefsSchema.installationIdKey: deviceId,
        });
        final api = _AlbumReleaseMockApi()
          ..selectRoot(
            const LightIsleRoot(
              id: 'disk_main',
              name: '照片盘',
              generation: 5,
              online: true,
            ),
          );
        addTearDown(api.close);

        final bytes = Uint8List.fromList([9, 8, 7, 6]);
        final digest = sha256.convert(bytes).toString();
        final oldCapturedSec = DateTime.now()
            .subtract(const Duration(days: 60))
            .millisecondsSinceEpoch ~/ 1000;
        final deleteRequests = <List<String>>[];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              backgroundChannel,
              (_) async => {'enabled': false, 'sessionMatches': false},
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(photosChannel, (call) async {
              final args = (call.arguments as Map?) ?? const {};
              switch (call.method) {
                case 'permission':
                case 'isWifi':
                  return true;
                case 'list':
                  return {
                    'supportsStream': true,
                    'version': 'ms:30',
                    'nextCursor': '',
                    'items': [
                      {
                        'id': '555',
                        'name': 'OLD_IMG.jpg',
                        'modified': oldCapturedSec,
                        'size': bytes.length,
                        'generation': 3,
                        'bucketId': '10',
                        'bucketName': 'Camera',
                        'isVideo': false,
                      },
                    ],
                  };
                case 'inspectAndHash':
                  return {
                    'size': bytes.length,
                    'modified': oldCapturedSec,
                    'generation': 3,
                    'sha256': digest,
                    'chunkDigests': const <String>[],
                  };
                case 'readChunk':
                  return bytes;
                case 'requestDeleteAssets':
                  final ids = (args['assetIds'] as List)
                      .map((e) => e.toString())
                      .toList();
                  deleteRequests.add(ids);
                  return {
                    'deleted': true,
                    'cancelled': false,
                    'deletedCount': ids.length,
                    'alreadyMissingCount': 0,
                  };
                default:
                  return true;
              }
            });

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: MobilePhotoBackupPage(
              api: api,
              accountName: 'owner',
              baseDirectory: 'Users/u7/photos',
              androidPlatformOverride: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Toggle auto-prompt switch on -> confirm dialog appears
        final switchFinder = find.byKey(
          const ValueKey('autoPromptSpaceReleaseSwitch'),
        );
        await tester.scrollUntilVisible(
          switchFinder,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(switchFinder);
        await tester.pumpAndSettle();
        expect(find.text('开启备份后自动发起释放确认？'), findsOneWidget);
        await tester.tap(find.text('确认开启'));
        await tester.pumpAndSettle();

        // Run clean backup -> auto-triggers space release sheet + online SHA-256 + OS confirmation
        await tester.scrollUntilVisible(
          find.text('检查并备份最近照片'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('检查并备份最近照片'));
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await tester.pumpAndSettle();

        expect(deleteRequests, [
          ['555'],
        ]);
        expect(find.textContaining('备份完成 · 安全释放本地空间'), findsOneWidget);
      },
    );
  });
}
