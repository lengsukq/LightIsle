import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/features/auth/login_flow_background.dart';
import 'package:lightisle/features/auth/login_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget app({
    double scale = 1,
    Brightness brightness = Brightness.light,
    double keyboardInset = 0,
    bool reduceMotion = true,
  }) => MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        viewInsets: EdgeInsets.only(bottom: keyboardInset),
        disableAnimations: reduceMotion,
      ),
      child: child!,
    ),
    home: LoginPage(onSignedIn: (_, _) {}),
  );

  for (final (size, scale) in <(Size, double)>[
    (const Size(320, 480), 2),
    (const Size(375, 812), 1),
    (const Size(720, 400), 1.5),
    (const Size(768, 1024), 1),
    (const Size(1280, 800), 1),
    (const Size(1920, 1080), 1.5),
  ]) {
    testWidgets('borderless login fits $size at $scale text scale', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(app(scale: scale));
      await tester.pumpAndSettle();
      expect(find.byType(LoginFlowBackground), findsOneWidget);
      expect(find.byType(IsleSurface), findsNothing);
      expect(find.byType(Form), findsOneWidget);
      expect(find.byType(IsleBrandMark), findsOneWidget);
      expect(find.byKey(const Key('loginScrollView')), findsOneWidget);
      final wide = size.width >= 960 && size.height >= 580 && scale <= 1.45;
      expect(find.text('欢迎回来'), wide ? findsOneWidget : findsNothing);

      await tester.ensureVisible(find.text('连接并登录'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('keyboard inset keeps the login button accessible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(keyboardInset: 300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('连接并登录'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the background moves without blocking form controls', (
    tester,
  ) async {
    await tester.pumpWidget(app(reduceMotion: false));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('loginFlowCanvas')), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion prevents continuous scheduled frames', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(reduceMotion: true, brightness: Brightness.dark),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginFlowBackground), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
