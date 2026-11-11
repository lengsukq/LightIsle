import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/mobile_photo_backup_page.dart';
import 'package:lightisle/features/media/photos_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StreamPhotoMockApi extends LightIsleApi {
  _StreamPhotoMockApi() : super('http://127.0.0.1:1');

  int uploadsCreated = 0;
  int chunksUploaded = 0;
  int prepareShouldNeverRun = 0;
  String? activePath;
  int activeSize = 0;
  int activeOffset = 0;
  final BytesBuilder _received = BytesBuilder(copy: false);
  final Map<String, ({int size, String sha256, List<String> chunkDigests})>
  remoteFiles = {};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots') {
      return {
        'roots': [
          {
            'rootID': 'mobile_root',
            'name': '照片盘',
            'generation': 3,
            'online': true,
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
            'category': 'photos',
            'rootID': 'mobile_root',
            'rootGeneration': 3,
            'relativePath': 'Users/u7/photos',
          },
        ],
      };
    }
    if (path.endsWith('/files')) {
      return {'path': query?['path'] ?? '.', 'entries': []};
    }
    if (path.contains('/photos')) {
      return {'items': [], 'nextCursor': 0};
    }
    if (path.endsWith('/albums') || path.endsWith('/private-albums')) {
      return {'albums': []};
    }
    if (path.contains('/uploads/')) {
      return {
        'id': 'up-stream-1',
        'path': activePath,
        'size': activeSize,
        'offset': activeOffset,
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path.endsWith('/files/folders')) {
      return {'created': true};
    }
    if (path.endsWith('/uploads')) {
      uploadsCreated++;
      final req = body! as Map;
      activePath = req['path'].toString();
      activeSize = req['size'] as int;
      activeOffset = 0;
      _received.clear();
      return {
        'id': 'up-stream-1',
        'path': activePath,
        'size': activeSize,
        'offset': 0,
      };
    }
    if (path.endsWith('/complete')) {
      final bytes = _received.takeBytes();
      final chunks = <String>[];
      const step = 4 * 1024 * 1024;
      for (var i = 0; i < bytes.length; i += step) {
        final end = (i + step < bytes.length) ? i + step : bytes.length;
        chunks.add(
          sha256.convert(Uint8List.sublistView(bytes, i, end)).toString(),
        );
      }
      remoteFiles[activePath!] = (
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        chunkDigests: chunks,
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
    chunksUploaded++;
    var count = 0;
    await for (final part in data) {
      _received.add(part);
      count += part.length;
    }
    expect(count, length);
    expect(offset, activeOffset);
    activeOffset += count;
    return {
      'id': id,
      'path': activePath,
      'size': activeSize,
      'offset': activeOffset,
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
    final stored = remoteFiles[path];
    if (stored == null || stored.size != expectedSize) return false;
    if (chunkSHA256s != null && chunkSHA256s.isNotEmpty) {
      if (chunkSHA256s.length != stored.chunkDigests.length) return false;
      for (var i = 0; i < chunkSHA256s.length; i++) {
        if (chunkSHA256s[i] != stored.chunkDigests[i]) return false;
      }
    }
    return stored.sha256 == expectedSHA256;
  }

  @override
  Future<bool> remoteFileHasSize(String path, int expectedSize) async =>
      remoteFiles[path]?.size == expectedSize;
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

  testWidgets(
    'Android zero-copy stream uploads multi-chunk media via inspectAndHash + readChunk without prepare and isolates camera vs all scope',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = _StreamPhotoMockApi()
        ..selectRoot(
          const LightIsleRoot(
            id: 'mobile_root',
            name: '照片盘',
            generation: 3,
            online: true,
          ),
        );
      addTearDown(api.close);

      // Build a 5 MiB payload (2 chunks: 4 MiB + 1 MiB)
      final videoBytes = Uint8List(5 * 1024 * 1024);
      for (var i = 0; i < videoBytes.length; i++) {
        videoBytes[i] = (i * 31 + 7) & 0xff;
      }
      final chunk0 = sha256
          .convert(Uint8List.sublistView(videoBytes, 0, 4 * 1024 * 1024))
          .toString();
      final chunk1 = sha256
          .convert(
            Uint8List.sublistView(
              videoBytes,
              4 * 1024 * 1024,
              videoBytes.length,
            ),
          )
          .toString();
      final totalDigest = sha256.convert(videoBytes).toString();

      final seenScopes = <String>[];
      var prepareCalled = 0;
      var inspectCalled = 0;
      var readChunkCalls = 0;

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
                expect(args['allowLargeOriginals'], true);
                final scope = args['albumScope']?.toString() ?? 'camera';
                seenScopes.add(scope);
                return {
                  'supportsStream': true,
                  'version': 'ms:10',
                  'nextCursor': '',
                  'items': scope == 'camera'
                      ? [
                          {
                            'id': '501',
                            'name': 'VID_20261111.mp4',
                            'modified': 1793000000,
                            'size': videoBytes.length,
                            'generation': 12,
                          },
                        ]
                      : <Map<String, Object>>[],
                };
              case 'inspectAndHash':
                inspectCalled++;
                return {
                  'size': videoBytes.length,
                  'modified': 1793000000,
                  'generation': 12,
                  'sha256': totalDigest,
                  'chunkDigests': [chunk0, chunk1],
                };
              case 'readChunk':
                readChunkCalls++;
                final offset = args['offset'] as int;
                final length = args['length'] as int;
                return Uint8List.sublistView(
                  videoBytes,
                  offset,
                  offset + length,
                );
              case 'prepare':
                prepareCalled++;
                throw StateError('prepare must never be called in stream mode');
              default:
                return true;
            }
          });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: MobilePhotoBackupPage(
            api: api,
            accountName: 'leo',
            baseDirectory: 'Users/u7/photos',
            androidPlatformOverride: true,
            iosPlatformOverride: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Fresh install defaults to 'camera' scope
      expect(find.textContaining('仅相机拍摄'), findsWidgets);

      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 350));
      });
      await tester.pumpAndSettle();

      expect(seenScopes, ['camera']);
      expect(prepareCalled, 0);
      expect(inspectCalled, 1);
      expect(readChunkCalls, 2);
      expect(api.uploadsCreated, 1);
      expect(api.chunksUploaded, 2);
      expect(find.textContaining('已检查至相册末尾'), findsOneWidget);

      // Switch to 'all' scope -> isolated cursor & state
      await tester.ensureVisible(find.text('全部手机媒体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部手机媒体'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('检查并备份最近照片'));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
      expect(seenScopes.last, 'all');
    },
  );

  testWidgets(
    'PhotosPage mobile header shows PhotoBackupStatusPill and SettingsPage adapts entry by platform',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = _StreamPhotoMockApi()
        ..selectRoot(
          const LightIsleRoot(
            id: 'mobile_root',
            name: '照片盘',
            generation: 3,
            online: true,
          ),
        );
      addTearDown(api.close);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: PhotosPage(
                api: api,
                isAdmin: false,
                accountName: 'leo',
                canBackup: true,
                backupDirectory: 'Users/u7/photos',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('photoBackupStatusPill')),
          findsOneWidget,
        );

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
        expect(
          find.byKey(const ValueKey('settingsDesktopFolderBackupTile')),
          findsNothing,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
