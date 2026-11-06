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

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
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
