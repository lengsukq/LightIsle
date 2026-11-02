import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/settings_page.dart';

class _GrantApi extends LightIsleApi {
  _GrantApi({bool rootScoped = false}) : super('http://127.0.0.1') {
    if (rootScoped) {
      selectRoot(
        const LightIsleRoot(
          id: 'drive-one',
          name: '家庭盘',
          generation: 3,
          online: true,
        ),
      );
    }
  }

  Map<String, dynamic>? savedGrant;
  Map<String, String>? lastGrantQuery;
  Map<String, String>? lastListQuery;
  String? lastGrantPath;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots') {
      return {
        'roots': [
          {
            'rootID': 'drive-one',
            'name': '家庭盘',
            'generation': 3,
            'online': true,
          },
          {
            'rootID': 'drive-two',
            'name': '影视盘',
            'generation': 5,
            'online': true,
          },
        ],
      };
    }
    if (path == '/api/v2/users/7/file-grants' ||
        path == '/api/v2/roots/drive-one/users/7/file-grants' ||
        path == '/api/v2/roots/drive-two/users/7/file-grants') {
      lastListQuery = query;
      return {'grants': <Object>[]};
    }
    if (path == '/api/v2/files') {
      final folder = query?['path'] ?? '.';
      return {
        'entries': folder == '.'
            ? [
                {'name': '家庭照片', 'path': '家庭照片', 'type': 'folder'},
              ]
            : <Object>[],
        'canWrite': true,
        'nextCursor': '',
      };
    }
    throw StateError('unexpected GET: $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    expect(method, 'PUT');
    expect(
      path,
      selectedRoot == null
          ? '/api/v2/users/7/file-grants'
          : '/api/v2/roots/${selectedRoot!.id}/users/7/file-grants',
    );
    lastGrantPath = path;
    lastGrantQuery = query;
    savedGrant = Map<String, dynamic>.from(body! as Map);
    return {};
  }
}

void main() {
  testWidgets(
    'logout offers explicit offline retention instead of silently wiping files',
    (tester) async {
      final api = _GrantApi();
      addTearDown(api.close);
      var signedOut = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              api: api,
              identity: const {'id': 7, 'username': '家人', 'role': 'member'},
              onLogout: () async => signedOut = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('退出登录 / 切换服务器'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录 / 切换服务器'));
      await tester.pumpAndSettle();
      expect(find.text('保留离线文件并退出'), findsOneWidget);
      expect(find.text('清理当前离线库并退出'), findsOneWidget);
      await tester.tap(find.text('保留离线文件并退出'));
      await tester.pumpAndSettle();
      expect(signedOut, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('family administrator can choose a folder without typing paths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2300);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = _GrantApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: GrantsPage(api: api, user: const {'id': 7, 'username': '家人'}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('浏览并选择文件夹'), findsOneWidget);
    await tester.tap(find.text('浏览并选择文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('选择授权文件夹'), findsOneWidget);
    await tester.tap(find.text('家庭照片').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '使用此文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：家庭照片'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '保存授权'));
    await tester.pumpAndSettle();
    expect(api.savedGrant, {'path': '家庭照片', 'canWrite': false});
    expect(tester.takeException(), isNull);
  });

  testWidgets('multi-root folder grants are pinned to the selected disk', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2300);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = _GrantApi(rootScoped: true);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: GrantsPage(api: api, user: const {'id': 7, 'username': '家人'}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('当前授权范围：家庭盘'), findsOneWidget);
    expect(api.lastListQuery, {'rootGeneration': '3'});
    await tester.tap(find.text('浏览并选择文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('家庭照片').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '使用此文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存授权'));
    await tester.pumpAndSettle();
    expect(api.savedGrant, {'path': '家庭照片', 'canWrite': false});
    expect(api.lastGrantQuery, {'rootGeneration': '3'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('disk switch cannot silently save grants to another root', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2300);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = _GrantApi(rootScoped: true);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: GrantsPage(api: api, user: const {'id': 7, 'username': '家人'}),
      ),
    );
    await tester.pumpAndSettle();
    api.selectRoot(null);
    await tester.tap(find.widgetWithText(FilledButton, '保存授权'));
    await tester.pumpAndSettle();
    expect(api.savedGrant, isNull);
    expect(find.textContaining('硬盘已切换'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'select disk inside family ACL and return without changing shell disk',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2300);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final api = _GrantApi(rootScoped: true);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: GrantsPage(api: api, user: const {'id': 7, 'username': '家人'}),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('影视盘').last);
      await tester.pumpAndSettle();
      expect(api.selectedRoot?.id, 'drive-two');
      expect(api.lastListQuery, {'rootGeneration': '5'});
      await tester.tap(find.text('浏览并选择文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('家庭照片').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '使用此文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存授权'));
      await tester.pumpAndSettle();
      expect(api.lastGrantPath, '/api/v2/roots/drive-two/users/7/file-grants');
      expect(api.lastGrantQuery, {'rootGeneration': '5'});
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(api.selectedRoot?.id, 'drive-one');
      expect(tester.takeException(), isNull);
    },
  );
}
