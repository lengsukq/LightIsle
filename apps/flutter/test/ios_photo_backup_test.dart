import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/mobile_photo_backup_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _IOSPhotoAPI extends LightIsleApi {
  _IOSPhotoAPI() : super('http://127.0.0.1:1');
  int uploads = 0;
  int completions = 0;
  String? destination;
  int? size;
  int offset = 0;
  String? finalDigest;
  final List<int> _buffer = <int>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots/ios_photos/files') {
      return {'path': query?['path'], 'entries': []};
    }
    if (path.startsWith('/api/v2/roots/ios_photos/uploads/')) {
      return {
        'id': 'temporary-1',
        'path': destination,
        'size': size,
        'offset': offset,
      };
    }
    throw StateError('Unexpected GET');
  }

  @override
  Future<bool> remoteFileHasSize(String path, int expectedSize) async => false;
  @override
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String digest, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) async =>
      completions > 0 &&
      path == destination &&
      expectedSize == size &&
      digest == finalDigest;
  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots/ios_photos/files/folders') {
      return {'created': true};
    }
    if (path == '/api/v2/roots/ios_photos/uploads') {
      uploads++;
      final request = body! as Map;
      destination = request['path'].toString();
      size = request['size'] as int;
      offset = 0;
      _buffer.clear();
      return {
        'id': 'temporary-1',
        'path': destination,
        'size': size,
        'offset': offset,
      };
    }
    if (path.endsWith('/complete')) {
      completions++;
      finalDigest = sha256.convert(_buffer).toString();
      return {'completed': true};
    }
    throw StateError('Unexpected POST $path');
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int currentOffset,
  ) async {
    var received = 0;
    await for (final bytes in data) {
      _buffer.addAll(bytes);
      received += bytes.length;
    }
    expect(received, length);
    expect(currentOffset, offset);
    offset += received;
    return {'offset': offset, 'id': id, 'path': destination, 'size': size};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const photos = MethodChannel('lightisle/photos');
  const background = MethodChannel('lightisle/photos-background');
  late Directory temporary;
  late _IOSPhotoAPI api;
  var reads = 0;
  var prepared = 0;
  var backgroundCalls = 0;
  var released = 0;
  var videoMode = false;
  var optedInOnList = false;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temporary = await Directory.systemTemp.createTemp('lightisle-ios-photo-');
    await File('${temporary.path}/image.heic')
        .writeAsBytes([10, 20, 30, 40, 50, 60]);
    await File('${temporary.path}/clip.mov')
        .writeAsBytes([10, 20, 30, 40, 50, 60]);
    api = _IOSPhotoAPI();
    api.selectRoot(
      const LightIsleRoot(
        id: 'ios_photos',
        name: 'iOS 相册盘',
        generation: 2,
        online: true,
      ),
    );
    reads = 0;
    prepared = 0;
    backgroundCalls = 0;
    released = 0;
    videoMode = false;
    optedInOnList = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(background, (call) async {
          backgroundCalls++;
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, (call) async {
          switch (call.method) {
            case 'permission':
              return true;
            case 'isWifi':
              return true;
            case 'list':
              reads++;
              optedInOnList = (call.arguments as Map)['includeVideos'] == true;
              return {
                'items': [
                  {
                    'id': videoMode
                        ? 'v.aW9zLXNhbXBsZS1hc3NldA'
                        : 'aW9zLXNhbXBsZS1hc3NldA',
                    'name': videoMode ? 'clip.mov' : 'image.heic',
                    'modified': 1792890000,
                    'size': 0,
                    'generation': 0,
                  },
                ],
                'nextCursor': '',
                'version': 'ios:1:snapshot',
              };
            case 'prepare':
              prepared++;
              return {
                'path':
                    '${temporary.path}/${videoMode ? "clip.mov" : "image.heic"}',
                'size': 6,
              };
            case 'release':
              released++;
              return true;
            case 'cancelPrepare':
              return true;
            default:
              throw StateError('Unknown bridge call ${call.method}');
          }
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(background, null);
    api.close();
    await temporary.delete(recursive: true);
  });
  testWidgets(
    'iOS foreground original backup uses prepared size, SHA256, no Android background',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MobilePhotoBackupPage(
            api: api,
            accountName: 'owner',
            baseDirectory: 'Users/u7/photos',
            androidPlatformOverride: false,
            iosPlatformOverride: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('iOS 照片前台备份'), findsOneWidget);
      expect(find.text('系统后台自动备份（每 6 小时检查）'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(optedInOnList, false);
      expect(prepared, 1);
      expect(api.uploads, 1);
      expect(api.completions, 1);
      expect(api.size, 6);
      expect(api.destination, contains('photo_'));
      expect(api.destination, endsWith('.heic'));
      expect(released, 1);
      expect(backgroundCalls, 0);
      expect(find.textContaining('已检查至相册末尾'), findsOneWidget);
    },
  );
  testWidgets(
    'iOS video backup requires an explicit foreground toggle; no WorkManager',
    (tester) async {
      videoMode = true;
      await tester.pumpWidget(
        MaterialApp(
          home: MobilePhotoBackupPage(
            api: api,
            accountName: 'owner',
            baseDirectory: 'Users/u7/photos',
            androidPlatformOverride: false,
            iosPlatformOverride: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('同时备份视频'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同时备份视频'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('检查并备份最近照片'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(optedInOnList, true);
      expect(api.completions, 1);
      expect(api.destination, endsWith('.mov'));
      expect(backgroundCalls, 0);
      expect(released, 1);
    },
  );

  testWidgets(
    'iOS non-zero assetGeneration skips prepare on repeat scan and re-uploads on edit',
    (tester) async {
      var assetGeneration = 987654321;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(photos, (call) async {
            switch (call.method) {
              case 'permission':
              case 'isWifi':
              case 'release':
              case 'cancelPrepare':
                return true;
              case 'list':
                reads++;
                return {
                  'items': [
                    {
                      'id': 'r.ABC123',
                      'name': 'camera.heic',
                      'modified': 1792890000,
                      'size': 0,
                      'generation': assetGeneration,
                    },
                  ],
                  'nextCursor': '',
                  'version': 'ios:2:snapshot',
                };
              case 'prepare':
                prepared++;
                return {'path': '${temporary.path}/image.heic', 'size': 6};
              default:
                throw StateError('Unknown bridge call ${call.method}');
            }
          });

      await tester.pumpWidget(
        MaterialApp(
          home: MobilePhotoBackupPage(
            api: api,
            accountName: 'owner',
            baseDirectory: 'Users/u7/photos',
            androidPlatformOverride: false,
            iosPlatformOverride: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // First scan exports once and stores "$digest:$size" under safeID "r.ABC123"
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(prepared, 1);
      expect(api.uploads, 1);

      // Second scan with identical generation hits Fast Path -> zero new prepare!
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(
        prepared,
        1,
        reason: 'iOS Fast Path must skip native PHAssetResource export',
      );
      expect(api.uploads, 1);
      expect(find.textContaining('已备份跳过 1 张'), findsOneWidget);

      // Simulate user editing the photo on iOS -> assetGeneration & bytes advance
      assetGeneration = 987654999;
      await tester.runAsync(() async {
        await File('${temporary.path}/image.heic')
            .writeAsBytes([10, 20, 30, 40, 50, 99]);
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(prepared, 2, reason: 'edited assetGeneration must re-export');
      expect(api.uploads, 2);
    },
  );

  testWidgets(
    'iOS icloud_download_required reports cloud-only count and passes allowICloudDownload when enabled',
    (tester) async {
      bool? lastAllowICloud;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(photos, (call) async {
            switch (call.method) {
              case 'permission':
              case 'isWifi':
              case 'release':
              case 'cancelPrepare':
                return true;
              case 'list':
                return {
                  'items': [
                    {
                      'id': 'cloud_asset_1',
                      'name': 'IMG_9999.HEIC',
                      'modified': 1792890000,
                      'size': 0,
                      'generation': 42,
                    },
                  ],
                  'nextCursor': '',
                  'version': 'ios:3:snapshot',
                };
              case 'prepare':
                final args = call.arguments as Map;
                lastAllowICloud = args['allowICloudDownload'] == true;
                if (!lastAllowICloud!) {
                  throw PlatformException(
                    code: 'icloud_download_required',
                    message: '照片原片在 iCloud 云端尚未下载到本机',
                  );
                }
                return {'path': '${temporary.path}/image.heic', 'size': 6};
              default:
                throw StateError('Unknown bridge call ${call.method}');
            }
          });

      await tester.pumpWidget(
        MaterialApp(
          home: MobilePhotoBackupPage(
            api: api,
            accountName: 'owner',
            baseDirectory: 'Users/u7/photos',
            androidPlatformOverride: false,
            iosPlatformOverride: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(lastAllowICloud, false);
      expect(api.uploads, 0);
      expect(find.textContaining('含 1 项 iCloud 云端未下载原片'), findsOneWidget);

      // Enable Wi-Fi iCloud download switch and retry
      await tester.ensureVisible(find.text('Wi-Fi 下允许下载 iCloud 原片后备份'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wi-Fi 下允许下载 iCloud 原片后备份'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('检查并备份最近照片'));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(lastAllowICloud, true);
      expect(api.uploads, 1);
      expect(api.completions, 1);
    },
  );
}
