import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/android_photo_backup_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

class _PhotoApi extends LightIsleApi {
  _PhotoApi() : super('http://127.0.0.1');
  @override
  Map<String, String> get mediaHeaders => const {
    HttpHeaders.cookieHeader:
        'lightisle_session=testsession_012345678901234567890123456789',
  };

  final Map<String, int> backed = {};
  final Map<String, String> digestByPath = {};
  Map<String, dynamic>? upload;
  var created = 0;
  var completed = 0;
  var loseCompletionOnce = false;
  var sizeProbeCalls = 0;
  var uploadChunkCalls = 0;
  Future<bool> Function(String, int, String)? remoteHashHandler;
  Future<bool> Function(String, int)? remoteSizeHandler;
  Future<Map<String, dynamic>> Function(String, Map<String, String>?)?
  uploadStateHandler;

  @override
  Future<bool> remoteFileHasSize(String path, int expectedSize) async {
    sizeProbeCalls++;
    final handler = remoteSizeHandler;
    if (handler != null) return handler(path, expectedSize);
    return backed[path] == expectedSize;
  }

  @override
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String digest, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) async {
    final handler = remoteHashHandler;
    if (handler != null) return handler(path, expectedSize, digest);
    return backed[path] == expectedSize && digestByPath[path] == digest;
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path == '/api/v1/files/folders') return {'created': true};
    if (path == '/api/v1/uploads') {
      created++;
      final info = body! as Map<String, dynamic>;
      upload = {
        'id': 'test-session-$created',
        'path': info['path'],
        'size': info['size'],
        'offset': 0,
      };
      return Map.from(upload!);
    }
    if (path.endsWith('/complete')) {
      completed++;
      backed[upload!['path'] as String] = upload!['size'] as int;
      final hash = sha256.convert([10, 20, 30, 40, 50, 60]).toString();
      digestByPath[upload!['path'] as String] = hash;
      if (loseCompletionOnce) {
        loseCompletionOnce = false;
        throw StateError('lost response after server commit');
      }
      return {'completed': true};
    }
    throw StateError('Unexpected write $method $path');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v1/files') return {'path': query?['path'], 'entries': []};
    if (path.startsWith('/api/v1/uploads/')) {
      final handler = uploadStateHandler;
      if (handler != null) return handler(path, query);
      if (upload != null) return Map.from(upload!);
    }
    throw StateError('Unexpected read $path');
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int offset,
  ) async {
    uploadChunkCalls++;
    if (upload == null || upload!['id'] != id || upload!['offset'] != offset) {
      throw StateError('bad upload resume');
    }
    var read = 0;
    await for (final block in data) {
      read += block.length;
    }
    if (read != length) throw StateError('chunk content length mismatch');
    upload!['offset'] = offset + read;
    return Map.from(upload!);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lightisle/photos');
  const background = MethodChannel('lightisle/photos-background');
  late _PhotoApi api;
  late Directory temporary;
  var prepared = 0;
  var listed = 0;
  var granted = true;
  var nextPages = false;
  var generation = 3;
  var storeVersion = 'v1';
  var backgroundEnabled = false;
  var backgroundSessionMatches = false;
  var backgroundConfigured = 0;
  var backgroundStatusReads = 0;
  var backgroundScanRequests = 0;
  var photoPermissionCalls = 0;
  Completer<Map<String, dynamic>>? nextBackgroundStatusReply;
  final backgroundArguments = <String, Map<String, dynamic>>{};
  final prepareArguments = <Map<String, dynamic>>[];
  final cancelledRequestIds = <String>[];
  final releasedPaths = <String>[];
  Future<Map<String, dynamic>?> Function(Map<String, dynamic>)? prepareHandler;
  Future<Map<String, dynamic>> Function(Map<dynamic, dynamic>)? listHandler;
  Future<void> Function(String)? releaseHandler;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = _PhotoApi();
    temporary = await Directory.systemTemp.createTemp('lightisle-photo-test-');
    await File('${temporary.path}/original.jpg')
        .writeAsBytes([10, 20, 30, 40, 50, 60]);
    prepared = 0;
    listed = 0;
    granted = true;
    nextPages = false;
    generation = 3;
    storeVersion = 'v1';
    backgroundEnabled = false;
    backgroundSessionMatches = false;
    backgroundConfigured = 0;
    backgroundStatusReads = 0;
    backgroundScanRequests = 0;
    photoPermissionCalls = 0;
    nextBackgroundStatusReply = null;
    backgroundArguments.clear();
    prepareArguments.clear();
    cancelledRequestIds.clear();
    releasedPaths.clear();
    prepareHandler = null;
    listHandler = null;
    releaseHandler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(background, (call) async {
          switch (call.method) {
            case 'status':
              backgroundStatusReads++;
              final pendingStatus = nextBackgroundStatusReply;
              if (pendingStatus != null) {
                nextBackgroundStatusReply = null;
                return pendingStatus.future;
              }
              return {
                'enabled': backgroundEnabled,
                'sessionMatches': backgroundSessionMatches,
                'last': '等待 Wi-Fi',
                'workState': backgroundEnabled ? 'enqueued' : 'none',
              };
            case 'enqueueScan':
              backgroundScanRequests++;
              backgroundArguments[call.method] = (call.arguments as Map)
                  .cast<String, dynamic>();
              return {
                'enabled': true,
                'sessionMatches': true,
                'last': '等待 Wi-Fi',
                'workState': 'enqueued',
                'scanRequestAccepted': true,
              };
            case 'enable':
              backgroundConfigured++;
              final args = (call.arguments as Map).cast<String, dynamic>();
              backgroundArguments[call.method] = args;
              expect(args['cookie'], contains('lightisle_session='));
              expect(args['deviceId'], matches(RegExp(r'^[a-f0-9]{24}$')));
              backgroundEnabled = true;
              backgroundSessionMatches = true;
              return {
                'enabled': true,
                'sessionMatches': true,
                'last': '已安排后台备份',
                'workState': 'enqueued',
              };
            case 'disable':
              backgroundArguments[call.method] = (call.arguments as Map)
                  .cast<String, dynamic>();
              backgroundEnabled = false;
              backgroundSessionMatches = false;
              return {
                'enabled': false,
                'sessionMatches': false,
                'last': '已关闭后台备份',
                'workState': 'none',
              };
            default:
              throw PlatformException(code: 'unknown_background_request');
          }
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'permission':
              photoPermissionCalls++;
              return granted;
            case 'requestPermission':
              photoPermissionCalls++;
              return granted;
            case 'isWifi':
              return true;
            case 'list':
              listed++;
              final customList = listHandler;
              if (customList != null) {
                return customList(call.arguments as Map<dynamic, dynamic>);
              }
              if (nextPages) {
                final before = (call.arguments as Map)['beforeId'];
                return <String, dynamic>{
                  'items': <Object>[],
                  'nextCursor': before == null ? '120' : '',
                  'version': storeVersion,
                };
              }
              return <String, dynamic>{
                'items': [
                  {
                    'id': '234',
                    'name': 'original.jpg',
                    'modified': 100,
                    'size': 6,
                    'generation': generation,
                  },
                ],
                'nextCursor': '',
                'version': storeVersion,
              };
            case 'prepare':
              prepared++;
              final args = (call.arguments as Map).cast<String, dynamic>();
              prepareArguments.add(args);
              final handler = prepareHandler;
              return handler == null
                  ? {'path': '${temporary.path}/original.jpg', 'size': 6}
                  : await handler(args);
            case 'cancelPrepare':
              final args = (call.arguments as Map).cast<String, dynamic>();
              cancelledRequestIds.add(args['requestId'] as String);
              return true;
            case 'release':
              final path = (call.arguments as Map)['path'] as String;
              releasedPaths.add(path);
              await releaseHandler?.call(path);
              return true;
            default:
              throw PlatformException(code: 'unexpected_call');
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(background, null);
    api.close();
    await temporary.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: AndroidPhotoBackupPage(
          api: api,
          accountName: 'owner',
          androidPlatformOverride: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() async {
      // Start the whole source-reading operation in the real dart:io zone,
      // not fake async, otherwise File.openRead's completion never fires.
      await tester.tap(find.text('检查并备份最近照片'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  Future<void> startUntil(WidgetTester tester, Completer<void> entered) async {
    await open(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('检查并备份最近照片'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(
      entered.isCompleted,
      isTrue,
      reason: 'operation did not reach its delayed probe',
    );
  }

  Future<void> waitForPausedRun(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.text('暂停').evaluate().isEmpty &&
          find.textContaining('已暂停').evaluate().isNotEmpty) {
        return;
      }
    }
    fail('foreground backup did not settle into paused state');
  }

  testWidgets(
    'background backup requires separate explicit confirmation and can be disabled',
    (tester) async {
      await open(tester);
      expect(backgroundConfigured, 0);
      await tester.tap(find.text('系统后台自动备份（每 6 小时检查）'));
      await tester.pumpAndSettle();
      expect(find.text('开启系统后台照片备份？'), findsOneWidget);
      expect(backgroundConfigured, 0);
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();
      expect(backgroundConfigured, 1);
      expect(backgroundEnabled, true);
      expect(
        find.textContaining('系统任务：已排队，等待 Wi-Fi、电量和系统调度条件'),
        findsOneWidget,
      );
      await tester.tap(find.text('系统后台自动备份（每 6 小时检查）'));
      await tester.pumpAndSettle();
      expect(backgroundEnabled, false);
      expect(backgroundArguments['disable']?['server'], 'http://127.0.0.1');
      expect(
        backgroundArguments['disable']?['cookie'],
        contains('lightisle_session='),
      );
    },
  );

  testWidgets(
    'a pending status read cannot overwrite a later background configuration result',
    (tester) async {
      await open(tester);
      final staleStatus = Completer<Map<String, dynamic>>();
      nextBackgroundStatusReply = staleStatus;
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      expect(backgroundStatusReads, 2);

      await tester.tap(find.text('系统后台自动备份（每 6 小时检查）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();
      expect(find.text('立即检查后台备份'), findsOneWidget);

      staleStatus.complete({
        'enabled': false,
        'sessionMatches': false,
        'last': '旧状态读取',
        'workState': 'none',
      });
      await tester.pumpAndSettle();

      expect(find.text('立即检查后台备份'), findsOneWidget);
      expect(find.textContaining('旧状态读取'), findsNothing);
    },
  );

  testWidgets(
    'resuming refreshes system task status when foreground auto-check is off',
    (tester) async {
      await open(tester);
      final beforeResume = backgroundStatusReads;
      expect(listed, 0);

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();

      expect(backgroundStatusReads, beforeResume + 1);
      expect(
        listed,
        0,
        reason: 'system status refresh is independent of photo scanning',
      );
      expect(find.textContaining('系统任务：当前没有排队或执行中的任务'), findsOneWidget);
    },
  );

  testWidgets(
    'manual background check uses the existing queue without new permission or foreground scan',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('系统后台自动备份（每 6 小时检查）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();

      final permissionCallsBeforeRequest = photoPermissionCalls;
      await tester.tap(find.text('立即检查后台备份'));
      await tester.pumpAndSettle();

      expect(backgroundScanRequests, 1);
      expect(backgroundArguments['enqueueScan']?['server'], 'http://127.0.0.1');
      expect(
        backgroundArguments['enqueueScan']?['cookie'],
        contains('lightisle_session='),
      );
      expect(photoPermissionCalls, permissionCallsBeforeRequest);
      expect(
        backgroundConfigured,
        1,
        reason: 'manual check must not re-enable the schedule',
      );
      expect(
        listed,
        0,
        reason: 'manual system check must not start the foreground scan',
      );
      expect(find.textContaining('已提交后台检查'), findsOneWidget);
    },
  );

  testWidgets(
    'a background grant from another login session cannot expose the check action',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('系统后台自动备份（每 6 小时检查）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();
      backgroundSessionMatches = false;

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();

      expect(find.text('立即检查后台备份'), findsNothing);
      expect(find.textContaining('当前登录会话与后台备份授权不一致'), findsOneWidget);
      expect(backgroundScanRequests, 0);
      expect(
        backgroundConfigured,
        1,
        reason: 'status refresh must not reauthorize a session',
      );
    },
  );

  testWidgets(
    'NAS same-sized bytes with wrong SHA256 are never counted as verified',
    (tester) async {
      await open(tester);
      await start(tester);
      expect(api.completed, 1);
      api.digestByPath.updateAll((_, _) => '0' * 64);
      await start(tester);
      expect(find.textContaining('备份中断'), findsOneWidget);
      expect(find.textContaining('跳过 1 张'), findsNothing);
      expect(
        api.created,
        1,
        reason: 'never overwrite a same-path NAS object whose hash differs from the phone',
      );
    },
  );

  testWidgets(
    'MediaStore reset invalidates generation fast-skip even with same id size and timestamp',
    (tester) async {
      await open(tester);
      await start(tester);
      expect(prepared, 1);
      storeVersion = 'v2';
      await start(tester);
      expect(
        prepared,
        2,
        reason: 'MediaStore database generation reset must not allow false success cache hits',
      );
      expect(
        api.created,
        1,
        reason: 'unchanged actual bytes still need no duplicate upload',
      );
    },
  );

  testWidgets(
    'backs up once and avoids copying or hashing unchanged pictures again',
    (tester) async {
      await open(tester);
      await start(tester);
      expect(api.created, 1);
      expect(api.completed, 1);
      expect(prepared, 1);
      expect(find.textContaining('新增 1 张'), findsOneWidget);
      await start(tester);
      expect(api.created, 1);
      expect(prepared, 1, reason: 'unchanged media must skip native copy');
      expect(find.textContaining('跳过 1 张'), findsOneWidget);
    },
  );

  testWidgets(
    'an unreadable original is recorded while later items and pages continue, then retries',
    (tester) async {
      var failFirstPrepare = true;
      final rows = <Map<String, dynamic>>[
        {
          'id': '234',
          'name': 'icloud-original.jpg',
          'modified': 100,
          'size': 6,
          'generation': 3,
        },
        {
          'id': '235',
          'name': 'page-one.jpg',
          'modified': 101,
          'size': 6,
          'generation': 3,
        },
        {
          'id': '120',
          'name': 'page-two.jpg',
          'modified': 102,
          'size': 6,
          'generation': 3,
        },
      ];
      listHandler = (arguments) async {
        final before = arguments['beforeId'];
        if (before == null) {
          return {
            'items': rows.take(2).toList(),
            'nextCursor': '120',
            'version': storeVersion,
          };
        }
        expect(before, '120');
        return {
          'items': <Map<String, dynamic>>[rows.last],
          'nextCursor': '',
          'version': storeVersion,
        };
      };
      prepareHandler = (arguments) async {
        if (arguments['id'] == '234' && failFirstPrepare) {
          throw PlatformException(
            code: 'photo_export_failed',
            message: 'iCloud original is not downloaded',
          );
        }
        return {'path': '${temporary.path}/original.jpg', 'size': 6};
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: AndroidPhotoBackupPage(
            api: api,
            accountName: 'owner',
            androidPlatformOverride: false,
            iosPlatformOverride: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await start(tester);

      expect(
        listed,
        2,
        reason: 'a local source failure must not block the next page',
      );
      expect(
        api.created,
        2,
        reason: 'both readable later originals must upload',
      );
      expect(find.textContaining('1 项读取失败，已登记待重试，未标记完整。'), findsOneWidget);
      expect(find.textContaining('新增 2 张'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getKeys().where((key) => key.endsWith('.lastCompleteAt')),
        isEmpty,
      );

      failFirstPrepare = false;
      listed = 0;
      await start(tester);

      expect(listed, 2, reason: 'a fresh scan must revisit the failed item');
      expect(
        api.created,
        3,
        reason: 'the failed original should upload on retry',
      );
      expect(find.textContaining('已检查至相册末尾'), findsOneWidget);
      expect(find.textContaining('读取失败'), findsNothing);
      final completeKey = preferences.getKeys().singleWhere(
        (key) => key.endsWith('.lastCompleteAt'),
      );
      expect(preferences.getInt(completeKey), isNotNull);

      final failureKeys = preferences
          .getKeys()
          .where((key) => key.contains('.failures.'))
          .toSet();
      expect(failureKeys.length, 3);
      storeVersion = 'v2';
      listed = 0;
      await start(tester);
      expect(
        preferences
            .getKeys()
            .where((key) => key.contains('.failures.'))
            .toSet(),
        failureKeys,
        reason: 'snapshot changes must replace the scoped failure set, not add keys',
      );
    },
  );

  testWidgets(
    'failure registry is capped at 512 and preserves the omitted failure count',
    (tester) async {
      final rows = List<Map<String, dynamic>>.generate(
        513,
        (index) => {
          'id': '${1000 + index}',
          'name': 'unavailable-$index.jpg',
          'modified': 1,
          'size': 6,
          'generation': 0,
        },
      );
      listHandler = (_) async => {
        'items': rows,
        'nextCursor': '',
        'version': storeVersion,
      };
      prepareHandler = (_) async =>
          throw PlatformException(code: 'photo_prepare_failed');

      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(seconds: 3));
      });
      await tester.pumpAndSettle();

      expect(prepared, 513);
      expect(find.textContaining('513 项读取失败'), findsOneWidget);
      expect(find.textContaining('其中 1 项超过本机 512 条失败记录上限'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      final storageKey = preferences.getKeys().singleWhere(
        (key) => key.endsWith('.failures.photos'),
      );
      final encoded = preferences.getString(storageKey)!;
      expect((jsonDecode(encoded) as List).length, 512);
      expect(preferences.getInt('$storageKey.omitted'), 1);
      expect(
        preferences.getKeys().where((key) => key.endsWith('.lastCompleteAt')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'a native permission revocation stops the page without advancing its cursor',
    (tester) async {
      listHandler = (arguments) async => {
        'items': [
          {
            'id': '234',
            'name': 'first.jpg',
            'modified': 100,
            'size': 6,
            'generation': 0,
          },
          {
            'id': '235',
            'name': 'second.jpg',
            'modified': 101,
            'size': 6,
            'generation': 0,
          },
        ],
        'nextCursor': '120',
        'version': storeVersion,
      };
      prepareHandler = (_) async =>
          throw PlatformException(code: 'photo_permission_required');

      await open(tester);
      await start(tester);

      expect(listed, 1);
      expect(prepared, 1);
      expect(api.created, 0);
      expect(find.textContaining('备份中断'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getKeys().where((key) => key.endsWith('.cursor')),
        isEmpty,
      );
      expect(
        preferences.getKeys().where((key) => key.endsWith('.lastCompleteAt')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'lost complete response resumes from durable NAS file without reuploading',
    (tester) async {
      api.loseCompletionOnce = true;
      await open(tester);
      await start(tester);
      expect(api.created, 1);
      expect(find.textContaining('备份中断'), findsOneWidget);
      await start(tester);
      expect(api.created, 1);
      expect(find.textContaining('跳过 1 张'), findsOneWidget);
      expect(prepared, 2);
    },
  );

  testWidgets(
    'older Android without generation rehashes original before skip',
    (tester) async {
      generation = 0;
      await open(tester);
      await start(tester);
      expect(api.created, 1);
      await start(tester);
      expect(api.created, 1);
      expect(
        prepared,
        2,
        reason: 'without generation token a same-size/mmtime replacement must be rehashed',
      );
    },
  );

  testWidgets(
    'consumes more than one native page without extra manual tapping',
    (tester) async {
      nextPages = true;
      await open(tester);
      await start(tester);
      expect(listed, 2);
      expect(find.textContaining('已检查至相册末尾'), findsOneWidget);
      expect(api.created, 0);
    },
  );

  testWidgets(
    'refuses partial/no Android photo access before reading or sending',
    (tester) async {
      granted = false;
      await open(tester);
      await start(tester);
      expect(listed, 0);
      expect(api.created, 0);
      expect(find.textContaining('需要在 Android 系统设置中授权访问所有照片'), findsOneWidget);
    },
  );

  testWidgets(
    'pause during a stale cached-hash probe prevents the next native prepare',
    (tester) async {
      const deviceId = 'cccccccccccccccccccccccc';
      final digest = sha256.convert([10, 20, 30, 40, 50, 60]).toString();
      final versionId = sha256
          .convert('v1'.codeUnits)
          .toString()
          .substring(0, 16);
      SharedPreferences.setMockInitialValues({
        'lightisle.photoBackup.installationId': deviceId,
        'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.sent.234.100.6.3.$versionId':
            digest,
      });
      final probeStarted = Completer<void>();
      final probeReply = Completer<bool>();
      api.remoteHashHandler = (_, _, _) {
        if (!probeStarted.isCompleted) probeStarted.complete();
        return probeReply.future;
      };

      await startUntil(tester, probeStarted);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await tester.runAsync(() async {
        probeReply.complete(false);
      });
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await waitForPausedRun(tester);

      expect(prepared, 0);
      expect(api.created, 0);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );

  testWidgets(
    'pause during the final SHA probe prevents a new upload session',
    (tester) async {
      final probeStarted = Completer<void>();
      final probeReply = Completer<bool>();
      api.remoteHashHandler = (_, _, _) {
        if (!probeStarted.isCompleted) probeStarted.complete();
        return probeReply.future;
      };

      await startUntil(tester, probeStarted);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await tester.runAsync(() async {
        probeReply.complete(false);
      });
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await waitForPausedRun(tester);

      expect(prepared, 1);
      expect(api.sizeProbeCalls, 0);
      expect(api.created, 0);
      expect(releasedPaths, ['${temporary.path}/original.jpg']);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );

  testWidgets(
    'pause while resuming an existing upload session prevents chunk writes',
    (tester) async {
      const deviceId = 'dddddddddddddddddddddddd';
      final digest = sha256.convert([10, 20, 30, 40, 50, 60]).toString();
      SharedPreferences.setMockInitialValues({
        'lightisle.photoBackup.installationId': deviceId,
        'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.upload.234.100.$digest':
            'existing-session',
      });
      final sessionReadStarted = Completer<void>();
      final sessionReadReply = Completer<Map<String, dynamic>>();
      api.uploadStateHandler = (path, _) {
        expect(path, '/api/v1/uploads/existing-session');
        if (!sessionReadStarted.isCompleted) sessionReadStarted.complete();
        return sessionReadReply.future;
      };

      await startUntil(tester, sessionReadStarted);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await tester.runAsync(() async {
        sessionReadReply.complete({
          'id': 'existing-session',
          'path':
              'PhonePhotos/$deviceId/photo_234_100_${digest.substring(0, 16)}.jpg',
          'size': 6,
          'offset': 0,
        });
      });
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await waitForPausedRun(tester);

      expect(api.created, 0);
      expect(api.uploadChunkCalls, 0);
      expect(releasedPaths, ['${temporary.path}/original.jpg']);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );

  testWidgets(
    'background backup can be enabled after manually pausing the foreground run',
    (tester) async {
      final prepareStarted = Completer<void>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      prepareHandler = (_) {
        if (!prepareStarted.isCompleted) prepareStarted.complete();
        return prepareReply.future;
      };

      await startUntil(tester, prepareStarted);
      await tester.tap(find.text('暂停'));
      await tester.pump();
      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await waitForPausedRun(tester);

      expect(releasedPaths, ['${temporary.path}/original.jpg']);
      expect(api.created, 0);
      expect(find.textContaining('已暂停'), findsOneWidget);

      await tester.tap(find.text('系统后台自动备份（每 6 小时检查）'));
      await tester.pumpAndSettle();
      expect(find.text('开启系统后台照片备份？'), findsOneWidget);
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();

      expect(backgroundConfigured, 1);
      expect(backgroundEnabled, isTrue);
    },
  );

  testWidgets(
    'pausing during native prepare cancels by request id and releases a late temp file',
    (tester) async {
      final prepareStarted = Completer<void>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      prepareHandler = (_) {
        if (!prepareStarted.isCompleted) prepareStarted.complete();
        return prepareReply.future;
      };
      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(prepareStarted.isCompleted, isTrue);

      final requestId = prepareArguments.single['requestId'] as String;
      expect(requestId, isNotEmpty);
      await tester.tap(find.text('暂停'));
      await tester.pump();
      expect(cancelledRequestIds, [requestId]);
      expect(find.textContaining('等待当前系统或网络请求结束'), findsOneWidget);

      // Model the native copy finishing just as cancellation arrives. The page
      // must discard this result before hashing/uploading, then release its file.
      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();

      expect(api.created, 0);
      expect(releasedPaths, ['${temporary.path}/original.jpg']);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );

  testWidgets(
    'resume during cancellation queues a new foreground pass after cleanup',
    (tester) async {
      const deviceId = 'aaaaaaaaaaaaaaaaaaaaaaaa';
      SharedPreferences.setMockInitialValues({
        'lightisle.photoBackup.installationId': deviceId,
        'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.onForeground':
            true,
      });
      final firstPrepareStarted = Completer<void>();
      final secondPrepareStarted = Completer<void>();
      final secondPrepareReply = Completer<Map<String, dynamic>?>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      final releaseStarted = Completer<void>();
      final releaseGate = Completer<void>();
      prepareHandler = (_) {
        if (prepareArguments.length == 1) {
          firstPrepareStarted.complete();
          return prepareReply.future;
        }
        if (prepareArguments.length == 2) {
          secondPrepareStarted.complete();
          return secondPrepareReply.future;
        }
        throw StateError('Unexpected third prepare');
      };
      releaseHandler = (_) async {
        if (!releaseStarted.isCompleted) releaseStarted.complete();
        await releaseGate.future;
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: AndroidPhotoBackupPage(
            api: api,
            accountName: 'owner',
            androidPlatformOverride: true,
          ),
        ),
      );
      await tester.runAsync(
        () => firstPrepareStarted.future.timeout(const Duration(seconds: 3)),
      );

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      expect(cancelledRequestIds, [prepareArguments.first['requestId']]);

      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => releaseStarted.future.timeout(const Duration(seconds: 3)),
      );
      expect(
        prepareArguments,
        hasLength(1),
        reason: 'the next pass waits for old temp cleanup',
      );

      releaseGate.complete();
      await tester.runAsync(
        () => secondPrepareStarted.future.timeout(const Duration(seconds: 3)),
      );
      expect(
        prepareArguments,
        hasLength(2),
        reason: 'a rapid resume must not be lost while cancellation unwinds',
      );
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      expect(cancelledRequestIds, [
        prepareArguments[0]['requestId'],
        prepareArguments[1]['requestId'],
      ]);
      secondPrepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(releasedPaths, hasLength(2));
      expect(api.created, 0);
    },
  );

  testWidgets('manual pause after a rapid resume clears the queued rerun', (
    tester,
  ) async {
    const deviceId = 'bbbbbbbbbbbbbbbbbbbbbbbb';
    SharedPreferences.setMockInitialValues({
      'lightisle.photoBackup.installationId': deviceId,
      'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.onForeground':
          true,
    });
    final prepareStarted = Completer<void>();
    final prepareReply = Completer<Map<String, dynamic>?>();
    final releaseFinished = Completer<void>();
    prepareHandler = (_) {
      if (!prepareStarted.isCompleted) prepareStarted.complete();
      return prepareReply.future;
    };
    releaseHandler = (_) async {
      if (!releaseFinished.isCompleted) releaseFinished.complete();
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: AndroidPhotoBackupPage(
          api: api,
          accountName: 'owner',
          androidPlatformOverride: true,
        ),
      ),
    );
    await tester.runAsync(
      () => prepareStarted.future.timeout(const Duration(seconds: 3)),
    );
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump();
    expect(cancelledRequestIds, [prepareArguments.single['requestId']]);

    await tester.tap(find.text('暂停'));
    await tester.pump();
    prepareReply.complete({
      'path': '${temporary.path}/original.jpg',
      'size': 6,
    });
    await tester.runAsync(
      () => releaseFinished.future.timeout(const Duration(seconds: 3)),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(prepareArguments, hasLength(1));
    expect(api.created, 0);
  });

  testWidgets(
    'disposing the page cancels an active native prepare and releases its late result',
    (tester) async {
      final prepareStarted = Completer<void>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      prepareHandler = (_) {
        if (!prepareStarted.isCompleted) prepareStarted.complete();
        return prepareReply.future;
      };
      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(prepareStarted.isCompleted, isTrue);
      final requestId = prepareArguments.single['requestId'] as String;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(cancelledRequestIds, [requestId]);
      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );

      expect(api.created, 0);
      expect(releasedPaths, ['${temporary.path}/original.jpg']);
    },
  );
}
