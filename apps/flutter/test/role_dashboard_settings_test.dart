import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';

import 'client_shell_test.dart' show FixtureApi;

void main() {
  for (final (size, scale) in <(Size, double)>[
    (const Size(320, 568), 2),
    (const Size(1024, 800), 1),
  ]) {
    for (final admin in [false, true]) {
      testWidgets(
        '${admin ? 'admin' : 'member'} sees only role-specific settings at $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = FixtureApi();
          addTearDown(api.close);
          await tester.pumpWidget(MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: IsleCanvas(child: child!),
            ),
            home: SettingsPage(
              api: api,
              identity: {
                'username': admin ? 'owner' : 'member',
                'role': admin ? 'admin' : 'member',
              },
              onLogout: () async {},
            ),
          ));
          await tester.pumpAndSettle();
          expect(find.text(admin ? '家庭与存储' : '我的空间'), findsOneWidget);
          expect(find.text('账号与目录授权'),
              admin ? findsOneWidget : findsNothing);
          expect(find.text('我的存储空间'),
              admin ? findsNothing : findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('连接详情'));
          await tester.pumpAndSettle();
          expect(find.text('当前服务器'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          if (admin) {
            await tester.scrollUntilVisible(
              find.text('安全审计'),
              160,
              scrollable: find.byType(Scrollable).first,
            );
            expect(find.text('安全审计'), findsOneWidget);
          } else {
            expect(find.text('安全审计'), findsNothing);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
      testWidgets(
        '${admin ? 'admin' : 'member'} dashboard uses role-specific data at $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = FixtureApi();
          addTearDown(api.close);
          await tester.pumpWidget(MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: IsleCanvas(child: child!),
            ),
            home: Scaffold(
              body: OverviewPage(api: api, isAdmin: admin,
                  onNavigate: (_) {}),
            ),
          ));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text(admin ? '这台 Mac' : '我的家庭空间'), findsOneWidget);
          if (admin) {
            expect(api.calls, contains('/api/v2/system'));
            expect(api.calls, contains('/api/v2/tasks'));
            expect(api.calls, isNot(contains('/api/v2/me/storage')));
          } else {
            expect(api.calls, contains('/api/v2/me/storage'));
            expect(api.calls, isNot(contains('/api/v2/system')));
            expect(api.calls, isNot(contains('/api/v2/tasks')));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
