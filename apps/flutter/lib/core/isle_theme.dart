import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_route.dart';
import 'isle_style.dart';
export 'isle_route.dart';
export 'isle_style.dart';
export 'isle_surface_widgets.dart';

Color _contrastOnColor(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark
    ? Colors.white
    : const Color(0xff111111);

ColorScheme _buildIsleColorScheme(
  Brightness brightness,
  IslePalette p, {
  required bool highContrast,
}) {
  final dark = brightness == Brightness.dark;
  final primary = p['accentPrimary'];
  final secondaryAccent = p['accentSecondary'];
  final onPrimary = _contrastOnColor(primary);
  final primaryContainer = Color.lerp(
    p['cardTop'],
    primary,
    dark ? 0.24 : 0.14,
  )!;
  final onPrimaryContainer = dark
      ? Color.lerp(primary, Colors.white, 0.65)!
      : Color.lerp(primary, const Color(0xff0a0a0a), 0.45)!;
  final tertiaryContainer = Color.lerp(
    p['cardTop'],
    secondaryAccent,
    dark ? 0.24 : 0.14,
  )!;
  final onTertiaryContainer = dark
      ? Color.lerp(secondaryAccent, Colors.white, 0.65)!
      : Color.lerp(secondaryAccent, const Color(0xff0a0a0a), 0.45)!;

  return ColorScheme.fromSeed(
    seedColor: primary,
    brightness: brightness,
    contrastLevel: highContrast ? 1 : 0,
  ).copyWith(
    primary: primary,
    onPrimary: onPrimary,
    surface: p['cardTop'],
    onSurface: p['textPrimary'],
    onSurfaceVariant: p['secondaryText'],
    surfaceContainerLowest: p['canvasTop'],
    surfaceContainerLow: p['cardItemTop'],
    surfaceContainer: p['cardItemBottom'],
    surfaceContainerHigh: p['cardHover'],
    surfaceContainerHighest: Color.lerp(
      p['cardHover'],
      p['rim'],
      dark ? 0.35 : 0.45,
    )!,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: p['secondaryText'],
    onSecondary: _contrastOnColor(p['secondaryText']),
    secondaryContainer: p['cardItemBottom'],
    onSecondaryContainer: p['textPrimary'],
    tertiary: secondaryAccent,
    onTertiary: _contrastOnColor(secondaryAccent),
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: onTertiaryContainer,
    error: p['error'],
    outline: Color.lerp(p['rim'], p['textSecondary'], dark ? 0.35 : 0.30)!,
    outlineVariant: p['rim'],
  );
}

AppBarTheme _buildIsleAppBarTheme(
  ThemeData base,
  ColorScheme colors,
  IsleThemeStyle style,
) {
  final p = style.palette;
  final dark = style.dark;
  return AppBarTheme(
    backgroundColor: Colors.transparent,
    foregroundColor: colors.onSurface,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    centerTitle: false,
    titleTextStyle: base.textTheme.titleMedium?.copyWith(
      color: colors.onSurface,
      fontFamily: style.preset.monospaceHeadings ? 'monospace' : null,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.25 + style.preset.headingLetterSpacingDelta,
    ),
    systemOverlayStyle: SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: p['canvasBottom'],
      systemNavigationBarIconBrightness: dark
          ? Brightness.light
          : Brightness.dark,
    ),
  );
}

InputDecorationTheme _buildIsleInputDecorationTheme(
  ColorScheme colors,
  IsleThemeStyle style,
  Color primary,
) {
  final p = style.palette;
  final outlineSide = BorderSide(
    color: style.rimBorderColor(),
    width: style.effectiveBorderWidth(),
  );
  final radius = style.borderRadiusFor(IsleRadius.control);
  return InputDecorationTheme(
    errorMaxLines: 4,
    filled: true,
    fillColor: p['cardItemTop'],
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    border: OutlineInputBorder(borderRadius: radius, borderSide: outlineSide),
    enabledBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: outlineSide,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(
        color: primary,
        width: style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal
            ? 2.2
            : 1.6,
      ),
    ),
  );
}

NavigationBarThemeData _buildIsleNavigationBarTheme(
  ColorScheme colors,
  IsleThemeStyle style,
) {
  final indicatorShape = style.preset.cornerStyle == IsleCornerStyle.sharp
      ? style.shapeFor(IsleRadius.sm)
      : const StadiumBorder();
  return NavigationBarThemeData(
    height: 56,
    backgroundColor: colors.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    indicatorColor: colors.primary.withValues(alpha: 0.14),
    indicatorShape: indicatorShape,
    iconTheme: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return IconThemeData(color: colors.primary, size: 22);
      }
      return IconThemeData(color: colors.onSurfaceVariant, size: 21);
    }),
    labelTextStyle: WidgetStateProperty.resolveWith((states) {
      final selected = states.contains(WidgetState.selected);
      return TextStyle(
        fontSize: 11,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? colors.primary : colors.onSurfaceVariant,
      );
    }),
  );
}

ThemeData buildIsleTheme(
  Brightness brightness, {
  IsleThemePresetId presetId = IsleThemePresetId.warmGallery,
  bool highContrast = false,
}) {
  final dark = brightness == Brightness.dark;
  final preset = IsleThemePresets.byId(presetId);
  final style = IsleThemeStyle(
    preset: preset,
    dark: dark,
    highContrast: highContrast,
  );
  final p = style.palette;
  final primary = p['accentPrimary'];
  final colors = _buildIsleColorScheme(
    brightness,
    p,
    highContrast: highContrast,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
  );
  final controlShape = style.shapeFor(IsleRadius.control);
  final headingFont = preset.monospaceHeadings ? 'monospace' : null;
  final delta = preset.headingLetterSpacingDelta;
  final isBrutal = preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
  final borderWidth = style.effectiveBorderWidth();

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    extensions: <ThemeExtension<dynamic>>[style],
    textTheme: base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontFamily: headingFont,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.9 + delta,
        color: colors.onSurface,
      ),
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontFamily: headingFont,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8 + delta,
        color: colors.onSurface,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontFamily: headingFont,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6 + delta,
        color: colors.onSurface,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontFamily: headingFont,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.45 + delta,
        color: colors.onSurface,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontFamily: headingFont,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4 + delta,
        color: colors.onSurface,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontFamily: headingFont,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25 + delta,
        color: colors.onSurface,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontFamily: headingFont,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.15 + delta,
        color: colors.onSurface,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14.5,
        height: 1.48,
        color: colors.onSurface,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        height: 1.42,
        color: colors.onSurfaceVariant,
      ),
    ),
    appBarTheme: _buildIsleAppBarTheme(base, colors, style),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: style.shapeFor(
        IsleRadius.card,
        side: BorderSide(color: style.rimBorderColor(), width: borderWidth),
      ),
    ),
    inputDecorationTheme: _buildIsleInputDecorationTheme(
      colors,
      style,
      primary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 40),
        elevation: 0,
        shape: isBrutal
            ? style.shapeFor(
                IsleRadius.control,
                side: BorderSide(color: style.rimBorderColor(), width: 1.8),
              )
            : controlShape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9.5),
        textStyle: TextStyle(
          fontFamily: headingFont,
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.15 + delta * 0.5,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 40),
        shape: controlShape,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        backgroundColor: isBrutal
            ? p['cardTop']
            : dark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.white.withValues(alpha: 0.72),
        foregroundColor: colors.onSurface,
        side: BorderSide(
          color: style.rimBorderColor(hovered: true),
          width: borderWidth,
        ),
        textStyle: TextStyle(
          fontFamily: headingFont,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.15 + delta * 0.5,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(42, 38),
        shape: controlShape,
        textStyle: TextStyle(
          fontFamily: headingFont,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(40, 40)),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(
        color: style.rimBorderColor(),
        width: isBrutal ? 1.5 : 0.9,
      ),
      backgroundColor: colors.surface,
      selectedColor: colors.primaryContainer,
      labelStyle: TextStyle(
        color: colors.onSurface,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
      shape: preset.cornerStyle == IsleCornerStyle.sharp
          ? style.shapeFor(IsleRadius.sm)
          : const StadiumBorder(),
    ),
    navigationBarTheme: _buildIsleNavigationBarTheme(colors, style),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.primaryContainer,
      indicatorShape: controlShape,
      selectedIconTheme: IconThemeData(color: colors.primary),
      selectedLabelTextStyle: TextStyle(
        color: colors.primary,
        fontWeight: FontWeight.w700,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: style.shapeFor(
        IsleRadius.sheet,
        side: BorderSide(
          color: style.rimBorderColor(isGlass: true),
          width: borderWidth,
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: style.shapeFor(
        IsleRadius.item,
        side: BorderSide(
          color: style.rimBorderColor(isGlass: true),
          width: borderWidth,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: const Color(0x66141210),
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(style.resolveRadius(IsleRadius.sheet)),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? p['cardHover'] : p['textPrimary'],
      contentTextStyle: TextStyle(
        color: dark ? p['textPrimary'] : p['cardTop'],
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
      ),
      shape: style.shapeFor(IsleRadius.item),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: colors.primaryContainer,
      borderRadius: style.borderRadiusFor(IsleRadius.xs),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      shape: controlShape,
    ),
    dividerTheme: DividerThemeData(
      color: style.rimBorderColor(),
      thickness: isBrutal ? 1.4 : 0.7,
      space: 14,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: islePageTransitionBuilders,
    ),
  );
}

/// Cinema view theme that follows the active [IsleThemePreset] and inherited
/// light/dark brightness instead of forcing a fixed all-black background,
/// while preserving any custom test font family.
ThemeData buildIsleCinemaTheme(
  ThemeData inherited, {
  bool highContrast = false,
}) {
  final activePresetId =
      inherited.extension<IsleThemeStyle>()?.presetId ??
      IslePalette.activePreset.id;
  final themed = buildIsleTheme(
    inherited.brightness,
    presetId: activePresetId,
    highContrast: highContrast,
  );
  final fontFamily = inherited.textTheme.bodyMedium?.fontFamily;
  if (fontFamily == null || fontFamily.isEmpty) return themed;
  return themed.copyWith(
    textTheme: themed.textTheme.apply(fontFamily: fontFamily),
    chipTheme: themed.chipTheme.copyWith(
      labelStyle: themed.chipTheme.labelStyle?.copyWith(fontFamily: fontFamily),
    ),
  );
}
