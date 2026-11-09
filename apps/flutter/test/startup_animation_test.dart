import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/widgets.dart';
import 'package:lightisle/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildCurtain({
    bool dark = false,
    bool exiting = false,
    bool disableAnimations = false,
    bool highContrast = false,
  }) {
    return MaterialApp(
      theme: buildIsleTheme(
        dark ? Brightness.dark : Brightness.light,
        highContrast: highContrast,
      ),
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: disableAnimations,
          highContrast: highContrast,
        ),
        child: StartupCurtain(exiting: exiting),
      ),
    );
  }

  testWidgets('StartupCurtain renders brand mark, title, tagline and shimmer bar', (
    tester,
  ) async {
    await tester.pumpWidget(buildCurtain());

    // Advance to mid animation
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('轻屿 LightIsle'), findsOneWidget);
    expect(find.text('让每一份珍藏，自在归屿'), findsOneWidget);
    expect(find.byType(IsleBrandMark), findsOneWidget);
    expect(find.bySemanticsLabel('正在连接轻屿'), findsOneWidget);

    // Let animation complete
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('轻屿 LightIsle'), findsOneWidget);
    expect(find.text('让每一份珍藏，自在归屿'), findsOneWidget);
  });

  testWidgets('StartupCurtain respects reduced motion without animation lag', (
    tester,
  ) async {
    await tester.pumpWidget(buildCurtain(disableAnimations: true));
    await tester.pump();

    // With animations disabled, all elements are immediately rendered
    expect(find.text('轻屿 LightIsle'), findsOneWidget);
    expect(find.text('让每一份珍藏，自在归屿'), findsOneWidget);
    expect(find.byType(IsleBrandMark), findsOneWidget);
    expect(find.bySemanticsLabel('正在连接轻屿'), findsOneWidget);
  });

  testWidgets('StartupCurtain adapts to dark theme and high contrast', (
    tester,
  ) async {
    await tester.pumpWidget(buildCurtain(dark: true, highContrast: true));
    await tester.pump(const Duration(milliseconds: 1000));

    expect(find.text('轻屿 LightIsle'), findsOneWidget);
    expect(find.bySemanticsLabel('正在连接轻屿'), findsOneWidget);
  });

  testWidgets('StartupCurtain animates exit scale smoothly', (
    tester,
  ) async {
    await tester.pumpWidget(buildCurtain(exiting: false));
    await tester.pump(const Duration(milliseconds: 1000));

    // Now trigger exit
    await tester.pumpWidget(buildCurtain(exiting: true));
    await tester.pump(const Duration(milliseconds: 200));

    final animatedScaleFinder = find.byType(AnimatedScale);
    expect(animatedScaleFinder, findsWidgets);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('轻屿 LightIsle'), findsOneWidget);
  });

  testWidgets('IsleLoadingState renders Liquid Glass orb and optional label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.dark),
        home: const Scaffold(
          body: IsleLoadingState(label: '正在同步设备与空间状态…'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在同步设备与空间状态…'), findsOneWidget);
  });
}
