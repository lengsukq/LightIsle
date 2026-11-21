import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/settings_page.dart';

class _TestApi extends LightIsleApi {
  _TestApi() : super('http://127.0.0.1:16666');
}

void main() {
  testWidgets(
    'AboutPage displays version, principles, repo card, licenses, and diagnostics',
    (tester) async {
      final api = _TestApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: IsleCanvas(child: AboutPage(api: api)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('关于轻屿'), findsOneWidget);
      expect(find.text('轻屿 LightIsle'), findsOneWidget);
      expect(find.text('v${AboutPage.appVersion}'), findsOneWidget);
      expect(find.text('Mac 原生管理端独立运行'), findsOneWidget);
      expect(find.text('原片由用户自主防护'), findsOneWidget);
      expect(find.text('轻量透明，无企业级冗余'), findsOneWidget);
      expect(find.text('GitHub 源码仓库'), findsOneWidget);
      expect(find.text('源码公开 · 非商业许可'), findsOneWidget);
      expect(find.text('lengsukq/LightIsle'), findsOneWidget);
      expect(find.text('访问代码仓库'), findsOneWidget);
      expect(find.text('复制链接'), findsOneWidget);

      await tester.tap(find.text('复制链接'));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);

      await tester.scrollUntilVisible(
        find.textContaining('PolyForm Noncommercial 1.0.0'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('开源与第三方许可'), findsOneWidget);
      expect(find.text('脱敏排障诊断报告'), findsOneWidget);
      expect(find.textContaining('PolyForm Noncommercial 1.0.0'), findsOneWidget);
      expect(
        find.textContaining('Required Notice: Copyright (c) 2026 lengsukq'),
        findsOneWidget,
      );
    },
  );

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
    await tester.ensureVisible(entryFinder);
    await tester.pumpAndSettle();
    expect(entryFinder, findsOneWidget);

    await tester.tap(entryFinder);
    await tester.pumpAndSettle();

    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('访问代码仓库'), findsOneWidget);
  });

  testWidgets('AboutPage survives 320px width and 200% text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2.0),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: const IsleCanvas(child: AboutPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('AboutPage adapts cleanly across Mobile, iPad and Desktop', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in const [
      Size(375, 812),
      Size(768, 1024),
      Size(1280, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.dark),
          home: const IsleCanvas(child: AboutPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('轻屿 LightIsle'), findsOneWidget);
      expect(find.text('GitHub 源码仓库'), findsOneWidget);
    }
  });
}
