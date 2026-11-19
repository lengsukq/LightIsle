import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/features/settings/appearance_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    IslePalette.activePreset = IsleThemePresets.warmGallery;
  });

  test('buildIsleTheme attaches distinct IsleThemeStyle for all 5 presets', () {
    final primaryLightColors = <Color>{};
    final surfaceMaterials = <IsleSurfaceMaterial>{};
    final backdrops = <IsleCanvasBackdrop>{};

    for (final preset in IsleThemePresets.all) {
      final lightTheme = buildIsleTheme(Brightness.light, presetId: preset.id);
      final darkTheme = buildIsleTheme(Brightness.dark, presetId: preset.id);

      final lightStyle = lightTheme.extension<IsleThemeStyle>();
      final darkStyle = darkTheme.extension<IsleThemeStyle>();

      expect(lightStyle, isNotNull);
      expect(darkStyle, isNotNull);
      expect(lightStyle!.presetId, preset.id);
      expect(darkStyle!.presetId, preset.id);
      expect(lightStyle.dark, isFalse);
      expect(darkStyle.dark, isTrue);

      primaryLightColors.add(lightTheme.colorScheme.primary);
      surfaceMaterials.add(preset.surfaceMaterial);
      backdrops.add(preset.canvasBackdrop);
    }

    expect(primaryLightColors.length, 5);
    expect(surfaceMaterials.length, 5);
    expect(backdrops.length, 5);
  });

  test('shared primitives and Cinema theme adapt to active preset without recursion', () {
    IslePalette.activePreset = IsleThemePresets.neoBrutalPop;
    expect(IsleShapes.card(), isA<RoundedRectangleBorder>());
    expect(IsleShadows.card(false).single.blurRadius, 0);
    expect(IsleShadows.card(false).single.offset, const Offset(4, 4));

    IslePalette.activePreset = IsleThemePresets.swissEditorial;
    expect(IsleShadows.card(false), isEmpty);

    final inheritedCyber = buildIsleTheme(
      Brightness.light,
      presetId: IsleThemePresetId.cyberTerminal,
    );
    final cinemaTheme = buildIsleCinemaTheme(inheritedCyber);
    expect(cinemaTheme.brightness, Brightness.light);
    expect(
      cinemaTheme.extension<IsleThemeStyle>()?.presetId,
      IsleThemePresetId.cyberTerminal,
    );
  });

  test('IsleThemeController persists preset and themeMode in SharedPreferences', () async {
    final controller = IsleThemeController();
    await controller.load();
    expect(controller.presetId, IsleThemePresetId.warmGallery);
    expect(controller.themeMode, ThemeMode.system);

    await controller.setPreset(IsleThemePresetId.neoBrutalPop);
    await controller.setThemeMode(ThemeMode.dark);
    expect(IslePalette.activePreset.id, IsleThemePresetId.neoBrutalPop);

    final reloaded = IsleThemeController();
    await reloaded.load();
    expect(reloaded.presetId, IsleThemePresetId.neoBrutalPop);
    expect(reloaded.themeMode, ThemeMode.dark);

    await reloaded.reset();
    expect(reloaded.presetId, IsleThemePresetId.warmGallery);
    expect(reloaded.themeMode, ThemeMode.system);
  });

  testWidgets('AppearancePage switches themes and brightness modes live', (
    tester,
  ) async {
    final controller = IsleThemeController();
    await controller.load();

    await tester.pumpWidget(
      IsleThemeScope(
        controller: controller,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            themeMode: controller.themeMode,
            theme: buildIsleTheme(
              Brightness.light,
              presetId: controller.presetId,
            ),
            darkTheme: buildIsleTheme(
              Brightness.dark,
              presetId: controller.presetId,
            ),
            builder: (context, child) => IsleCanvas(child: child!),
            home: const AppearancePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('温润画廊'), findsOneWidget);
    expect(find.text('极光玻璃'), findsOneWidget);
    expect(find.text('瑞士印刷'), findsOneWidget);
    expect(find.text('新粗野波普'), findsOneWidget);
    expect(find.text('赛博终端'), findsOneWidget);

    final cyberCard = find.byKey(const Key('themePresetCard_cyber_terminal'));
    await tester.scrollUntilVisible(cyberCard, 200);
    await tester.tap(cyberCard);
    await tester.pumpAndSettle();

    expect(controller.presetId, IsleThemePresetId.cyberTerminal);
    expect(
      Theme.of(tester.element(find.byType(AppearancePage)))
          .extension<IsleThemeStyle>()!
          .presetId,
      IsleThemePresetId.cyberTerminal,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('appearanceThemeModeSelector')),
      -200,
    );
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(controller.themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(AppearancePage))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.byKey(const Key('appearanceResetButton')));
    await tester.pumpAndSettle();

    expect(controller.presetId, IsleThemePresetId.warmGallery);
    expect(controller.themeMode, ThemeMode.system);
  });
}
