import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/photo_zoom_surface.dart';

void main() {
  Widget page({
    required VoidCallback onDown,
    VoidCallback? onUp,
    ValueChanged<bool>? onZoomChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: PhotoZoomSurface(
        onSwipeDown: onDown,
        onSwipeUp: onUp,
        onZoomChanged: onZoomChanged,
        child: const ColoredBox(color: Colors.red),
      ),
    ),
  );

  testWidgets('pull-down dismiss requires a deliberate vertical drag', (
    tester,
  ) async {
    var dismissed = 0;
    await tester.pumpWidget(page(onDown: () => dismissed++));
    final center = tester.getCenter(find.byType(PhotoZoomSurface));
    final small = await tester.startGesture(center);
    await small.moveBy(const Offset(0, 38));
    await small.up();
    await tester.pumpAndSettle();
    expect(dismissed, 0);

    final horizontal = await tester.startGesture(center);
    await horizontal.moveBy(const Offset(160, 15));
    await horizontal.up();
    await tester.pumpAndSettle();
    expect(dismissed, 0);

    final down = await tester.startGesture(center);
    await down.moveBy(const Offset(0, 160));
    await down.up();
    await tester.pumpAndSettle();
    expect(dismissed, 1);
  });

  testWidgets('swipe up opens information instead of dismissing', (
    tester,
  ) async {
    var dismissed = 0;
    var details = 0;
    await tester.pumpWidget(
      page(onDown: () => dismissed++, onUp: () => details++),
    );
    final center = tester.getCenter(find.byType(PhotoZoomSurface));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, -170));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(details, 1);
    expect(dismissed, 0);
  });

  testWidgets('second finger prevents accidental swipe dismiss', (
    tester,
  ) async {
    var dismissed = 0;
    await tester.pumpWidget(page(onDown: () => dismissed++));
    final center = tester.getCenter(find.byType(PhotoZoomSurface));
    final first = await tester.startGesture(center.translate(-24, 0));
    final second = await tester.startGesture(center.translate(24, 0));
    await first.moveBy(const Offset(0, 160));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(dismissed, 0);
  });

  testWidgets('double tap zoom keeps vertical panning inside the image', (
    tester,
  ) async {
    var dismissed = 0;
    var zoomed = false;
    await tester.pumpWidget(
      page(onDown: () => dismissed++, onZoomChanged: (value) => zoomed = value),
    );
    final center = tester.getCenter(find.byType(PhotoZoomSurface));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 90));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(zoomed, isTrue);

    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, 180));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(dismissed, 0);
  });

  testWidgets('two-finger pinch enlarges the photo without dismissing', (
    tester,
  ) async {
    var dismissed = 0;
    var zoomed = false;
    await tester.pumpWidget(
      page(onDown: () => dismissed++, onZoomChanged: (value) => zoomed = value),
    );
    final center = tester.getCenter(find.byType(PhotoZoomSurface));
    final first = await tester.startGesture(center.translate(-35, 0));
    final second = await tester.startGesture(center.translate(35, 0));
    await first.moveBy(const Offset(-90, 0));
    await tester.pump();
    await second.moveBy(const Offset(90, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(zoomed, isTrue);
    expect(dismissed, 0);
  });
}
