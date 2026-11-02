import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';

void main() {
  testWidgets('keeps the static canvas isolated during nested route pushes', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final theme = buildIsleTheme(Brightness.light)
        .copyWith(platform: TargetPlatform.macOS);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: theme,
        builder: (context, child) => IsleCanvas(child: child!),
        home: const Scaffold(
          backgroundColor: Colors.transparent,
          body: SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const backgroundKey = ValueKey<String>('isle-canvas-background');
    final background = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(backgroundKey),
    );
    expect(background.debugNeedsPaint, isFalse);

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          backgroundColor: Colors.transparent,
          body: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == theme.colorScheme.surface,
      ),
      findsNothing,
      reason: 'The page transition must not cover the shared canvas in white.',
    );
    await tester.pump(const Duration(milliseconds: 80));

    final backgroundDuringTransition = tester
        .renderObject<RenderRepaintBoundary>(find.byKey(backgroundKey));
    expect(identical(backgroundDuringTransition, background), isTrue);
    expect(backgroundDuringTransition.debugNeedsPaint, isFalse);
  });
}
