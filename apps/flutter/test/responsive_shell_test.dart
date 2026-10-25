import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/main.dart';
import 'package:lightisle/features/settings/settings_page.dart';

import 'client_shell_test.dart' show FixtureApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!const bool.fromEnvironment('LIGHTISLE_CAPTURE_VISUALS')) return;
    final body = FontLoader('IsleVisualBody')
      ..addFont(
        File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
            .readAsBytes()
            .then((v) => ByteData.sublistView(v)),
      );
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${File('/opt/homebrew/bin/flutter').resolveSymbolicLinksSync().replaceFirst(RegExp(r'/bin/flutter$'), '')}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((v) => ByteData.sublistView(v)),
      );
    await body.load();
    await icons.load();
  });
  for (final size in <Size>[
    const Size(320, 568),
    const Size(600, 840),
    const Size(1024, 480),
    const Size(1280, 800),
    const Size(1920, 1080),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('all sections adapt to $size with ${scale}x text', (
        tester,
      ) async {
        final api = FixtureApi();
        final captureKey = GlobalKey();
        addTearDown(api.close);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: const bool.fromEnvironment('LIGHTISLE_CAPTURE_VISUALS')
                  ? visualTheme()
                  : buildIsleTheme(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: IsleCanvas(child: child!),
              ),
              home: ClientShell(
                api: api,
                identity: const {'username': 'local_owner', 'role': 'admin'},
                onLogout: () async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Overview at $size / $scale',
        );
        await capture(tester, captureKey, size, scale, 'overview');
        for (final label in ['文件', '图库', '影视', '设置']) {
          final rail = find.byType(NavigationRail).evaluate().isNotEmpty;
          final destination = rail
              ? find.descendant(
                  of: find.byType(NavigationRail),
                  matching: find.text(label),
                )
              : find.widgetWithText(NavigationDestination, label);
          await tester.tap(destination);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$label at $size / $scale',
          );
          await capture(tester, captureKey, size, scale, label);
        }
        await tester.scrollUntilVisible(
          find.text('账号与目录授权'),
          180,
          scrollable: find
              .descendant(
                of: find.byType(SettingsPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        // Animated tiles may be built while still clipped behind the bottom
        // navigation bar at short heights. Ensure the target is genuinely
        // visible before tapping; this is especially important at 320x568.
        await tester.ensureVisible(find.text('账号与目录授权'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('账号与目录授权'));
        await tester.pumpAndSettle();
        expect(find.byType(AccountsPage), findsOneWidget);
        await tester.ensureVisible(find.text('创建账号'));
        await tester.tap(find.text('创建账号'));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Account dialog at $size / $scale',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}

Future<void> capture(
  WidgetTester tester,
  GlobalKey key,
  Size size,
  double scale,
  String name,
) async {
  if (!const bool.fromEnvironment('LIGHTISLE_CAPTURE_VISUALS')) return;
  if (scale != 1 || (size.width != 320 && size.width != 1280)) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory(
      '../../.qa-agent/modules/flutter/tasks/native-smoke/evidence/flutter-renders',
    );
    await directory.create(recursive: true);
    await File('${directory.path}/${size.width.toInt()}-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

ThemeData visualTheme() {
  final base = buildIsleTheme(Brightness.light);
  TextStyle font(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'IsleVisualBody');
  ButtonStyle button(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStatePropertyAll(font(base.textTheme.labelLarge)),
      );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'IsleVisualBody'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: font(base.appBarTheme.titleTextStyle),
    ),
    navigationRailTheme: base.navigationRailTheme.copyWith(
      selectedLabelTextStyle: font(
        base.navigationRailTheme.selectedLabelTextStyle,
      ),
      unselectedLabelTextStyle: font(base.textTheme.labelMedium),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      labelTextStyle: WidgetStatePropertyAll(font(base.textTheme.labelSmall)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: button(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button(base.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button(base.textButtonTheme.style),
    ),
  );
}
