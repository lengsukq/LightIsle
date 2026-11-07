import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/missing_media_page.dart';

class _MissingApi extends LightIsleApi {
  _MissingApi() : super('http://127.0.0.1:16666');
  final calls = <String>[];
  bool manageable = true;
  bool resolved = false;
  String scan = 'not_checked';
  bool scanBusy = false;
  Completer<Map<String, dynamic>>? pendingPhotos;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
    if (path.endsWith('/photos') && pendingPhotos != null) {
      final pending = pendingPhotos!;
      pendingPhotos = null;
      return pending.future;
    }
    return {
      'items': path.endsWith('/photos') && !resolved
          ? [
              {
                'id': 7,
                'path': 'Users/u2/photos/a.jpg',
                'reason': 'identity_unverified',
                'data': ['favorites'],
                'canManage': manageable,
              },
            ]
          : [],
      'nextCursor': '',
      'scan': {'state': scan},
    };
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add('$method $path');
    if (path.endsWith('/attach') && body is Map && body['confirm'] == true) {
      resolved = true;
    }
    if (path.endsWith('/recheck')) {
      if (scanBusy) {
        throw const LightIsleApiException(
          code: 'scan_running',
          message: 'scan_running',
        );
      }
      scan = 'running';
    }
    return {};
  }
}

const _rootA = LightIsleRoot(
  id: 'root-a',
  name: 'A',
  generation: 1,
  online: true,
);
const _rootB = LightIsleRoot(
  id: 'root-b',
  name: 'B',
  generation: 1,
  online: true,
);

void main() {
  testWidgets('failed scan is shown even when no missing record is known', (
    tester,
  ) async {
    final api = _MissingApi()
      ..resolved = true
      ..scan = 'failed'
      ..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('上次检查未完成'), findsNWidgets(2));
    expect(find.textContaining('当前没有已发现的缺失记录'), findsNWidgets(2));
  });

  testWidgets('owner confirms before linking old data to a current file', (
    tester,
  ) async {
    final api = _MissingApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Users/u2/photos/a.jpg'), findsOneWidget);
    await tester.tap(find.byTooltip('处理缺失媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关联当前文件'));
    await tester.pumpAndSettle();
    expect(api.calls.where((item) => item.startsWith('POST')), isEmpty);
    await tester.tap(find.text('确认关联'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /api/v2/missing-media/photos/7/attach'));
    expect(find.text('Users/u2/photos/a.jpg'), findsNothing);
  });

  testWidgets('root switch during confirmation prevents the write', (
    tester,
  ) async {
    final api = _MissingApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('处理缺失媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃旧记录'));
    await tester.pumpAndSettle();
    api.selectRoot(_rootB);
    await tester.tap(find.text('放弃记录'));
    await tester.pumpAndSettle();
    expect(api.calls.where((item) => item.startsWith('DELETE')), isEmpty);
  });

  testWidgets(
    'switching away and back during confirmation still prevents the write',
    (tester) async {
      final api = _MissingApi()..selectRoot(_rootA);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('处理缺失媒体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃旧记录'));
      await tester.pumpAndSettle();
      api.selectRoot(_rootB);
      api.selectRoot(_rootA);
      await tester.tap(find.text('放弃记录'));
      await tester.pumpAndSettle();
      expect(api.calls.where((item) => item.startsWith('DELETE')), isEmpty);
    },
  );

  testWidgets('a slow refresh cannot restore an already linked record', (
    tester,
  ) async {
    final api = _MissingApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    final slow = Completer<Map<String, dynamic>>();
    api.pendingPhotos = slow;
    await tester.tap(find.text('刷新').first);
    await tester.pump();
    await tester.tap(find.byTooltip('处理缺失媒体'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('关联当前文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('确认关联'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.calls, contains('POST /api/v2/missing-media/photos/7/attach'));
    expect(find.text('Users/u2/photos/a.jpg'), findsNothing);
    slow.complete({
      'items': [
        {
          'id': 7,
          'path': 'Users/u2/photos/a.jpg',
          'reason': 'identity_unverified',
          'data': ['favorites'],
          'canManage': true,
        },
      ],
      'nextCursor': '',
      'scan': {'state': 'finished'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Users/u2/photos/a.jpg'), findsNothing);
  });

  testWidgets('a recheck refreshes the list when scanning finishes', (
    tester,
  ) async {
    final api = _MissingApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新检查').first);
    await tester.pump();
    expect(find.textContaining('完成后列表会自动更新'), findsOneWidget);
    expect(find.textContaining('检查正在进行'), findsOneWidget);
    api.scan = 'finished';
    api.resolved = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Users/u2/photos/a.jpg'), findsNothing);
    expect(find.textContaining('最近一次检查已结束'), findsOneWidget);
  });

  testWidgets('recheck polling pauses in the background', (tester) async {
    final api = _MissingApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新检查').first);
    await tester.pump();
    final before = api.calls.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 6));
    expect(api.calls.length, before);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    api.scan = 'finished';
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.calls.length, greaterThan(before));
  });

  testWidgets('an already running scan is tracked until completion', (
    tester,
  ) async {
    final api = _MissingApi()
      ..scanBusy = true
      ..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新检查').first);
    await tester.pump();
    expect(find.textContaining('检查正在进行，完成后列表会自动更新'), findsOneWidget);
    api.scan = 'finished';
    api.resolved = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Users/u2/photos/a.jpg'), findsNothing);
  });

  testWidgets(
    'read-only owner sees an explanation and cannot change metadata',
    (tester) async {
      final api = _MissingApi()
        ..manageable = false
        ..selectRoot(_rootA);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(home: MissingMediaPage(api: api, isAdmin: false)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('当前没有写入权限'), findsOneWidget);
      final menu = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      expect(menu.enabled, isFalse);
    },
  );
}
