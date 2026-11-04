import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/widgets.dart';
import 'package:lightisle/features/settings/about_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';

class _TestApi extends LightIsleApi {
  _TestApi() : super('http://127.0.0.1:16666');
}

void main() {
  testWidgets('AboutPage displays hero, GitHub card and data principles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: const IsleCanvas(child: AboutPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关于轻屿'), findsOneWidget);
    expect(find.text('轻屿 LightIsle'), findsOneWidget);
    expect(find.text('GitHub 开源仓库'), findsOneWidget);
    expect(find.text('lengsukq/LightIsle'), findsOneWidget);
    expect(find.text('访问代码仓库'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('Mac 原生管理端独立运行'), findsOneWidget);
    expect(find.text('原片由用户自主防护'), findsOneWidget);
    expect(find.text('轻量透明，无企业级冗余'), findsOneWidget);

    await tester.tap(find.text('复制链接'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('SettingsPage navigates to AboutPage smoothly', (tester) async {
    final api = _TestApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: IsleCanvas(
          child: SettingsPage(
            api: api,
            identity: {'username': 'test-user', 'role': 'member'},
            onLogout: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entryFinder = find.text('关于轻屿 LightIsle');
    await tester.scrollUntilVisible(
      entryFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(entryFinder, findsOneWidget);

    await tester.tap(entryFinder);
    await tester.pumpAndSettle();

    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('访问代码仓库'), findsOneWidget);
  });
}
