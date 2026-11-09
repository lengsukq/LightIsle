import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
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

    // Verify top chapter bar and hero stage share exact left/right alignment
    // and all pills share the exact same vertical center.
    final preludeCenter = tester.getCenter(find.text('序幕'));
    final ch1Center = tester.getCenter(find.text('01 原生核心'));
    final tourCenter = tester.getCenter(
      find.byKey(const Key('aboutAutoTourButton')),
    );
    expect((preludeCenter.dy - ch1Center.dy).abs(), lessThan(0.5));
    expect((preludeCenter.dy - tourCenter.dy).abs(), lessThan(0.5));
    expect(find.text('GitHub 源码仓库'), findsOneWidget);
    expect(find.text('源码公开 · 非商业许可'), findsOneWidget);
    expect(find.text('lengsukq/LightIsle'), findsOneWidget);
    expect(find.text('访问代码仓库'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('Mac 原生管理端独立运行'), findsOneWidget);
    expect(find.text('原片由用户自主防护'), findsOneWidget);
    expect(find.text('轻量透明，无企业级冗余'), findsOneWidget);
    expect(find.text('回忆精选与多维时间线'), findsOneWidget);
    expect(find.text('巨幕海报墙与智能刮削'), findsOneWidget);

    await tester.tap(find.text('复制链接'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('PolyForm Noncommercial 1.0.0'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('PolyForm Noncommercial 1.0.0'), findsOneWidget);
    expect(
      find.textContaining('Required Notice: Copyright (c) 2026 lengsukq'),
      findsOneWidget,
    );
  });

  testWidgets(
    'AboutPage supports continuous video-like reel, chapter jump and auto-tour',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.dark),
          home: const IsleCanvas(child: AboutPage(continuousReel: true)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('aboutHeroReelCanvas')), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isTrue);

      // Tap chapter pill to smoothly jump down the showcase page
      await tester.tap(find.text('02 光影图库'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.pixels, greaterThan(400));

      // Toggle auto-tour to advance scroll continuously like a video
      final beforeAutoTour = scrollable.position.pixels;
      await tester.tap(find.byKey(const Key('aboutAutoTourButton')));
      await tester.pump();
      expect(find.text('暂停巡礼'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(scrollable.position.pixels, greaterThan(beforeAutoTour));

      await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets(
    'AboutPage adapts cards cleanly across Mobile (375), iPad (768) and PC (1280)',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 1. Mobile (375x812): single-row top bar + 2 posters visible so each card has generous width
      tester.view.physicalSize = const Size(375, 812);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: const IsleCanvas(child: AboutPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final mobilePreludeDy = tester.getCenter(find.text('序幕')).dy;
      final mobileCh1Dy = tester.getCenter(find.text('01 原生核心')).dy;
      final mobileTourDy = tester
          .getCenter(find.byKey(const Key('aboutAutoTourButton')))
          .dy;
      expect((mobilePreludeDy - mobileCh1Dy).abs(), lessThan(0.5));
      expect((mobilePreludeDy - mobileTourDy).abs(), lessThan(0.5));
      expect(find.text('TMDB · 豆瓣 · NFO 自动刮削'), findsOneWidget);
      expect(find.text('深海归屿'), findsOneWidget);
      expect(find.text('镰仓物语'), findsOneWidget);
      expect(find.text('星际漫游'), findsNothing);

      // 2. iPad (768x1024): 4 posters visible + 2-column Bento layout
      tester.view.physicalSize = const Size(768, 1024);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('深海归屿'), findsOneWidget);
      expect(find.text('星际漫游'), findsOneWidget);
      expect(find.text('原生核心守护'), findsOneWidget);

      // 3. PC (1280x800): 3-column Bento grid + 4 posters + Hero HUD
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final card0Center = tester.getCenter(find.text('Mac 原生管理端独立运行'));
      final card1Center = tester.getCenter(find.text('原片由用户自主防护'));
      final card2Center = tester.getCenter(find.text('轻量透明，无企业级冗余'));
      expect((card0Center.dy - card1Center.dy).abs(), lessThan(2.0));
      expect((card1Center.dy - card2Center.dy).abs(), lessThan(2.0));
    },
  );
}
