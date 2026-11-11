import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/widgets.dart';
import 'package:lightisle/features/files/files_page.dart';
import 'package:lightisle/main.dart';

import 'client_shell_test.dart' show FixtureApi;

class _WritableFixtureApi extends FixtureApi {
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/files') {
      return {
        'canWrite': true,
        'nextCursor': '',
        'entries': [
          {
            'name': 'Family travel media and original photos',
            'path': 'Family travel media and original photos',
            'type': 'folder',
            'size': 0,
            'canWrite': true,
          },
          {
            'name': '家庭长文件名和大字体展示_2026年11月.mp4',
            'path': '家庭长文件名和大字体展示_2026年11月.mp4',
            'type': 'file',
            'size': 1024000000,
            'canWrite': true,
          },
        ],
      };
    }
    return super.get(path, query: query);
  }
}

void main() {
  for (final (size, scale) in <(Size, double)>[
    (const Size(320, 640), 2),
    (const Size(620, 750), 1.4),
    (const Size(1280, 800), 1),
  ]) {
    testWidgets('macOS unified toolbar fits $size at ${scale}x', (
      tester,
    ) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = previous);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FixtureApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: ClientShell(
            api: api,
            identity: const {'username': 'owner', 'role': 'admin'},
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = find.byKey(const ValueKey('macUnifiedToolbar'));
      expect(toolbar, findsOneWidget);
      expect(tester.getSize(toolbar).height, 52);
      expect(find.byType(AppBar), findsNothing);
      final rootPicker = find.byKey(const ValueKey('shellRootPickerSurface'));
      expect(rootPicker, findsOneWidget);
      expect(tester.getTopLeft(rootPicker).dx, greaterThan(90));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('macAccountButton'))).dx,
        greaterThan(tester.getTopLeft(rootPicker).dx),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(rootPicker);
      await tester.pumpAndSettle();
      expect(find.text('刷新共享目录状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = previous;
    });
  }

  testWidgets('macOS unified account and sidebar controls remain usable', (
    tester,
  ) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = previous);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FixtureApi();
    addTearDown(api.close);
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          builder: (context, child) => IsleCanvas(child: child!),
          home: ClientShell(
            api: api,
            identity: const {'username': 'owner', 'role': 'admin'},
            onLogout: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('LIGHTISLE_CAPTURE_MAC_TOOLBAR')) {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final screenshot = await boundary.toImage();
        final data = await screenshot.toByteData(
          format: ui.ImageByteFormat.png,
        );
        final folder = Directory('../../build/flutter-mobile-review');
        await folder.create(recursive: true);
        await File('${folder.path}/mac-unified-toolbar.png')
            .writeAsBytes(data!.buffer.asUint8List());
        screenshot.dispose();
      });
    }
    expect(find.byTooltip('展开侧栏'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('macSidebarToggle')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('macAccountButton')));
    await tester.pumpAndSettle();
    expect(find.text('家庭与存储'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previous;
  });

  testWidgets(
    'macOS client uses a collapsible rail, retaining the active tab',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = previous);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = FixtureApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: ClientShell(
            api: api,
            identity: const {'username': 'owner', 'role': 'admin'},
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(IsleFloatingRailDock)).height,
        lessThan(320),
      );
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isFalse,
      );
      await tester.tap(find.byTooltip('展开侧栏'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isTrue,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('相册'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        1,
      );
      await tester.tap(find.byTooltip('收起侧栏'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isFalse,
      );
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = previous;
    },
  );

  testWidgets(
    'file toolbar keeps upload and new-folder controls on a small phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _WritableFixtureApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: FilesPage(api: api, isAdmin: true, accountName: 'owner'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('上传文件'), findsOneWidget);
      expect(find.byTooltip('新建文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'compact UI remains functional at 320px with 200% text and accessibility',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = previous);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _WritableFixtureApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light, highContrast: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              highContrast: true,
              disableAnimations: true,
            ),
            child: IsleCanvas(child: child!),
          ),
          home: ClientShell(
            api: api,
            identity: const {'username': 'owner', 'role': 'admin'},
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        find.descendant(
          of: find.byType(IsleFloatingBottomNavDock),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.padding == const EdgeInsets.fromLTRB(12, 4, 12, 6),
          ),
        ),
        findsOneWidget,
      );
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
      expect(find.byType(NavigationDestination), findsNWidgets(4));

      await tester.tap(find.byType(NavigationDestination).at(1));
      // Real file rows can contain a live progress indicator. Allow the
      // transition to finish without waiting for every perpetual animation.
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      for (final index in [2, 3, 0]) {
        await tester.tap(find.byType(NavigationDestination).at(index));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.takeException(),
          isNull,
          reason: 'section $index overflow',
        );
      }
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = previous;
    },
  );

  test('shared breakpoints respect available pane space and text size', () {
    expect(IsleLayout.pageInset(580), 12);
    expect(IsleLayout.pageInset(760), 18);
    expect(IsleLayout.pageInset(1080), 24);
    expect(IsleLayout.useRail(width: 1024, height: 480, desktop: true), isTrue);
    expect(
      IsleLayout.useRail(width: 1024, height: 420, desktop: true),
      isFalse,
    );
    expect(
      IsleLayout.useRail(width: 800, height: 840, desktop: false),
      isFalse,
    );
    expect(
      IsleLayout.extendedRail(width: 1280, textScale: 2, expanded: true),
      isFalse,
    );
    expect(
      IsleLayout.extendedRail(width: 1280, textScale: 1, expanded: false),
      isFalse,
    );
    expect(IsleLayout.compactToolbar(288, 2), isTrue);
    expect(IsleLayout.compactToolbar(568, 1), isFalse);
  });

  test(
    'Flutter surfaces and colors are the same nativeMac semantic tokens',
    () {
      for (final dark in [false, true]) {
        final palette = IslePalette(dark);
        final native = dark ? IsleTokens.nativeDark : IsleTokens.nativeLight;
        for (final key in [
          'canvasTop',
          'canvasBottom',
          'cardTop',
          'cardHover',
          'brandBlue',
          'brandCyan',
          'brandViolet',
          'brandIndigo',
        ]) {
          expect(
            palette[key],
            native[key],
            reason: 'nativeMac: $key, dark=$dark',
          );
        }
        final theme = buildIsleTheme(dark ? Brightness.dark : Brightness.light);
        expect(theme.colorScheme.surface, native['cardTop']);
      }
      expect(IsleTokens.cardRadius, 20);
      expect(IsleTokens.heroRadius, 24);
      expect(IsleTokens.itemRadius, 18);
      expect(IsleTokens.controlRadius, 12);
    },
  );

  testWidgets(
    'IsleAppBar clears macOS window controls on pushed secondary pages',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = previous);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => const Scaffold(
                          appBar: IsleAppBar(title: Text('账号与目录授权')),
                          body: SizedBox.expand(),
                        ),
                      ),
                    );
                  },
                  child: const Text('前往二级页'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('前往二级页'));
      await tester.pumpAndSettle();

      final backButtonFinder = find.byType(BackButton);
      expect(backButtonFinder, findsOneWidget);
      // macOS traffic lights occupy 0..75pt; back button must sit comfortably beyond them.
      final backButtonOffset = tester.getTopLeft(backButtonFinder);
      expect(backButtonOffset.dx, greaterThanOrEqualTo(78));

      final titleOffset = tester.getTopLeft(find.text('账号与目录授权'));
      expect(titleOffset.dx, greaterThan(backButtonOffset.dx));
      debugDefaultTargetPlatformOverride = previous;
    },
  );

  testWidgets(
    'unified style tokens, Liquid Glass controls, and non-overlapping tab switcher work cohesively',
    (tester) async {
      expect(IsleRadius.card, greaterThanOrEqualTo(20));
      expect(IsleRadius.hero, greaterThan(IsleRadius.card));
      expect(IsleRadius.pill, greaterThan(9000));
      expect(IsleShapes.card(), isA<ContinuousRectangleBorder>());
      expect(IsleShapes.pill(), isA<StadiumBorder>());

      var activeIndex = 0;
      var expanded = false;
      final searchController = TextEditingController();
      addTearDown(searchController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Column(
                children: [
                  IslePillButton(
                    label: '切换标签',
                    icon: Icons.swap_horiz_rounded,
                    variant: IslePillVariant.primary,
                    onPressed: () => setState(() {
                      activeIndex = (activeIndex + 1) % 3;
                      expanded = !expanded;
                    }),
                  ),
                  IsleCapsuleChip(
                    label: '全部照片',
                    selected: activeIndex == 1,
                    onSelected: () => setState(() => activeIndex = 1),
                  ),
                  IsleAnimatedExpand(
                    expanded: expanded,
                    child: IsleSearchBar(
                      controller: searchController,
                      hintText: '搜索测试',
                      showClear: true,
                      onClear: () => searchController.clear(),
                    ),
                  ),
                  Expanded(
                    child: IsleFluidTabSwitcher(
                      index: activeIndex,
                      children: const [
                        Center(child: Text('Tab 0')),
                        Center(child: Text('Tab 1')),
                        Center(child: Text('Tab 2')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Tab 0'), findsOneWidget);
      expect(find.text('搜索测试'), findsNothing);

      // Trigger first switch and interrupt mid-animation with a second switch.
      await tester.tap(find.text('切换标签'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('搜索测试'), findsOneWidget);

      await tester.tap(find.text('切换标签'));
      await tester.pumpAndSettle();
      expect(find.text('Tab 2'), findsOneWidget);
      expect(find.text('搜索测试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
