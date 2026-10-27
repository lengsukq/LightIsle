import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/main.dart';
import 'package:lightisle/features/settings/account_security_page.dart';
import 'package:lightisle/features/settings/admin_activity_page.dart';

class ActivityApi extends LightIsleApi {
  ActivityApi() : super('http://127.0.0.1:16666');
  final writes = <({String method, String path, Object? body})>[];
  final reads = <({String path, Map<String, String>? query})>[];
  Future<Map<String, dynamic>> Function(String, Map<String, String>?)? onGet;
  bool failPassword = false, failAuditPage = false, acknowledged = false;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    reads.add((path: path, query: query));
    if (onGet != null) return onGet!(path, query);
    if (path.endsWith('/sessions')) {
      return {
        'sessions': [
          {
            'id': 'current',
            'current': true,
            'createdAt': 1700000000,
            'expiresAt': 1800000000,
          },
          {
            'id': 'other',
            'current': false,
            'createdAt': 1700000100,
            'expiresAt': 1800000100,
          },
        ],
      };
    }
    if (path.endsWith('/audit')) {
      if (query?['before'] != null && failAuditPage) {
        throw StateError('审计分页暂时失败');
      }
      return {
        'events': [
          {
            'id': query?['before'] == null ? 20 : 19,
            'actorId': 1,
            'action': query?['before'] == null ? 'file_write' : 'upload_write',
            'outcome': 'success',
            'target': 'file',
            'createdAt': 1700000000,
          },
        ],
        'nextCursor': query?['before'] == null ? 20 : 0,
      };
    }
    if (path.endsWith('/alerts')) {
      return {
        'alerts': [
          {
            'code': 'storage.offline',
            'severity': 'critical',
            'message': '共享磁盘已离线',
            'active': true,
            'acknowledged': acknowledged,
            'firstSeen': 1700000000,
          },
        ],
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
    writes.add((method: method, path: path, body: body));
    if (path == '/api/v2/auth/password' && failPassword) {
      throw const LightIsleApiException(
        code: 'current_password_invalid',
        message: '当前密码不正确',
      );
    }
    if (path.endsWith('/acknowledge')) acknowledged = true;
    return {'changed': true};
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _fillPassword(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).at(0), 'old-password');
  await tester.enterText(find.byType(TextFormField).at(1), 'new-password-7391');
  await tester.enterText(find.byType(TextFormField).at(2), 'new-password-7391');
}

void main() {
  testWidgets(
    'password update requires confirmation and ends the local session only after success',
    (tester) async {
      final api = ActivityApi();
      addTearDown(api.close);
      var signedOut = false;
      await tester.pumpWidget(
        MaterialApp(
          home: AccountSecurityPage(
            api: api,
            onSignedOut: () async {
              signedOut = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _fillPassword(tester);
      await _tap(tester, find.text('更新密码'));
      await _tap(tester, find.text('取消'));
      expect(api.writes, isEmpty);
      await _tap(tester, find.text('更新密码'));
      await _tap(tester, find.widgetWithText(FilledButton, '更新密码').last);
      expect(api.writes.single.path, '/api/v2/auth/password');
      expect(api.writes.single.body, {
        'currentPassword': 'old-password',
        'newPassword': 'new-password-7391',
      });
      expect(signedOut, isTrue);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets('wrong current password keeps the page available for retry', (
    tester,
  ) async {
    final api = ActivityApi()..failPassword = true;
    addTearDown(api.close);
    var signedOut = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AccountSecurityPage(
          api: api,
          onSignedOut: () async {
            signedOut = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _fillPassword(tester);
    await _tap(tester, find.text('更新密码'));
    await _tap(tester, find.widgetWithText(FilledButton, '更新密码').last);
    expect(find.text('当前密码不正确'), findsOneWidget);
    expect(signedOut, isFalse);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller!
          .text,
      'old-password',
    );
  });

  testWidgets('revoking another session leaves current session intact', (
    tester,
  ) async {
    final api = ActivityApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: AccountSecurityPage(api: api, onSignedOut: () async {}),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.text('撤销此会话'));
    await _tap(tester, find.widgetWithText(FilledButton, '撤销会话'));
    expect(api.writes.single.path, '/api/v2/auth/sessions/other');
    expect(api.writes.single.method, 'DELETE');
    expect(find.text('当前会话'), findsOneWidget);
  });

  testWidgets(
    'member reset validates repeated password before calling recovery endpoint',
    (tester) async {
      final api = ActivityApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => ResetMemberPasswordDialog(
                    api: api,
                    user: const {'id': 2, 'username': 'member'},
                  ),
                ),
                child: const Text('打开恢复'),
              ),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('打开恢复'));
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'new-member-password',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'different-password',
      );
      await _tap(tester, find.text('重置密码'));
      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(api.writes, isEmpty);
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'new-member-password',
      );
      await _tap(tester, find.text('重置密码'));
      expect(api.writes.single.path, '/api/v2/users/2/password');
      expect(api.writes.single.body, {'password': 'new-member-password'});
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'audit pagination retains earlier entries after failure and retries its cursor',
    (tester) async {
      final api = ActivityApi()..failAuditPage = true;
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: AdminActivityPage(api: api, kind: AdminActivity.audit),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('文件管理操作 · 用户 #1'), findsOneWidget);
      await _tap(tester, find.text('查看更多审计记录'));
      expect(find.text('文件管理操作 · 用户 #1'), findsOneWidget);
      expect(api.reads.last.query?['before'], '20');
      api.failAuditPage = false;
      await _tap(tester, find.text('重试'));
      expect(find.text('文件续传操作 · 用户 #1'), findsOneWidget);
      expect(find.text('查看更多审计记录'), findsNothing);
    },
  );

  testWidgets(
    'alert acknowledgement retains the fault status; latest history filter wins',
    (tester) async {
      final api = ActivityApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: AdminActivityPage(api: api, kind: AdminActivity.alerts),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.text('确认已知晓'));
      expect(
        api.writes.single.path,
        '/api/v2/alerts/storage.offline/acknowledge',
      );
      expect(find.textContaining('已确认，异常仍存在'), findsOneWidget);
      expect(find.text('共享磁盘已离线'), findsOneWidget);
      final old = Completer<Map<String, dynamic>>(),
          latest = Completer<Map<String, dynamic>>();
      api.onGet = (_, query) =>
          query?['history'] == '1' ? old.future : latest.future;
      await tester.tap(find.text('包含已恢复的历史'));
      await tester.pump();
      await tester.tap(find.text('包含已恢复的历史'));
      await tester.pump();
      latest.complete({'alerts': []});
      await tester.pumpAndSettle();
      old.complete({
        'alerts': [
          {'message': '旧的历史结果'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('旧的历史结果'), findsNothing);
      expect(find.text('目前没有未恢复的异常记录。'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'account and admin pages fit 320×480 with 200% text in $brightness',
      (tester) async {
        final api = ActivityApi();
        addTearDown(api.close);
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pages = <Widget>[
          AccountSecurityPage(api: api, onSignedOut: () async {}),
          AdminActivityPage(api: api, kind: AdminActivity.audit),
          AdminActivityPage(api: api, kind: AdminActivity.alerts),
        ];
        for (final page in pages) {
          await tester.pumpWidget(
            MaterialApp(
              theme: isleTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: page,
            ),
          );
          await tester.pumpAndSettle();
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -1800),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '${page.runtimeType}');
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }
      },
    );
  }
}
