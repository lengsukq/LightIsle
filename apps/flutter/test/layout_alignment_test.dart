import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
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
          matching: find.text('文件'),
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
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
      expect(find.byType(NavigationDestination), findsNWidgets(5));

      await tester.tap(find.byType(NavigationDestination).at(1));
      // Real file rows can contain a live progress indicator. Allow the
      // transition to finish without waiting for every perpetual animation.
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      for (final index in [2, 3, 4, 0]) {
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
    expect(IsleLayout.pageInset(580), 16);
    expect(IsleLayout.pageInset(760), 24);
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
      expect(IsleTokens.controlRadius, 10);
    },
  );
}
