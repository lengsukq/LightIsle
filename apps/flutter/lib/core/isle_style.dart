import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'generated_isle_tokens.dart';
import 'isle_theme_presets.dart';
export 'generated_isle_tokens.dart';
export 'isle_theme_controller.dart';
export 'isle_theme_presets.dart';

/// Unified corner-radius scale for the LightIsle Flutter client.
abstract final class IsleRadius {
  static const double xs = IsleTokens.radiusXs; // 8.0
  static const double sm = IsleTokens.radiusSm; // 12.0
  static const double control = 13.0;
  static const double md = IsleTokens.radiusMd; // 16.0
  static const double item = 18.0;
  static const double lg = IsleTokens.radiusLg; // 22.0
  static const double card = 20.0;
  static const double hero = 26.0;
  static const double xl = IsleTokens.radiusXl; // 30.0
  static const double sheet = 28.0;
  static const double pill = IsleTokens.radiusPill; // 9999.0

  static const BorderRadius brXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brControl = BorderRadius.all(
    Radius.circular(control),
  );
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brItem = BorderRadius.all(Radius.circular(item));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brCard = BorderRadius.all(Radius.circular(card));
  static const BorderRadius brHero = BorderRadius.all(Radius.circular(hero));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius brSheet = BorderRadius.all(Radius.circular(sheet));
  static const BorderRadius brPill = BorderRadius.all(Radius.circular(pill));

  static BorderRadius circular(double radius) => BorderRadius.circular(radius);
}

/// Adaptive geometry builders that follow the active [IsleThemePreset].
abstract final class IsleShapes {
  static const bool useContinuousCorners = true;
  static const double squircleSmoothing = 2.15;

  /// Pure continuous superellipse without theme-preset scaling (used internally
  /// by [IsleThemeStyle.shapeFor]).
  static OutlinedBorder rawSquircle(
    double radius, {
    BorderSide side = BorderSide.none,
  }) {
    if (radius >= 900) {
      return StadiumBorder(side: side);
    }
    if (!useContinuousCorners) {
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: side,
      );
    }
    return ContinuousRectangleBorder(
      borderRadius: BorderRadius.circular(radius * squircleSmoothing),
      side: side,
    );
  }

  static OutlinedBorder squircle(
    double radius, {
    BorderSide side = BorderSide.none,
  }) => IsleThemeStyle(
    preset: IslePalette.activePreset,
    dark: false,
  ).shapeFor(radius, side: side);

  static OutlinedBorder xs({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.xs, side: side);
  static OutlinedBorder sm({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.sm, side: side);
  static OutlinedBorder control({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.control, side: side);
  static OutlinedBorder interactive({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.control, side: side);
  static OutlinedBorder md({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.md, side: side);
  static OutlinedBorder menu({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.item, side: side);
  static OutlinedBorder item({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.item, side: side);
  static OutlinedBorder card({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.card, side: side);
  static OutlinedBorder hero({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.hero, side: side);
  static OutlinedBorder sheet({BorderSide side = BorderSide.none}) =>
      squircle(IsleRadius.sheet, side: side);
  static OutlinedBorder pill({BorderSide side = BorderSide.none}) =>
      StadiumBorder(side: side);
}

/// Unified spacing and layout tokens with generous gallery breathing room.
abstract final class IsleSpace {
  static const double xxs = IsleTokens.space1; // 4.0
  static const double xs = IsleTokens.space2; // 8.0
  static const double sm = IsleTokens.space3; // 12.0
  static const double md = IsleTokens.space4; // 16.0
  static const double lg = IsleTokens.space5; // 20.0
  static const double xl = IsleTokens.space6; // 24.0
  static const double xxl = IsleTokens.space8; // 32.0
  static const double xxxl = IsleTokens.space10; // 40.0
  static const double section = 24.0;

  static const EdgeInsets cardPadding = EdgeInsets.all(16);
  static const EdgeInsets cardPaddingCompact = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 12,
  );
  static const EdgeInsets dialogPadding = EdgeInsets.fromLTRB(22, 20, 22, 18);
  static const EdgeInsets chipPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 7,
  );
  static const EdgeInsets pillButtonPadding = EdgeInsets.symmetric(
    horizontal: 13,
    vertical: 7,
  );
  static const EdgeInsets floatingDockMargin = EdgeInsets.fromLTRB(
    12,
    4,
    12,
    6,
  );
}

/// Unified motion durations, spring curves, and non-overlapping transition intervals.
abstract final class IsleMotion {
  static const Duration pressDown = Duration(milliseconds: 95);
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 165);
  static const Duration modalExit = Duration(milliseconds: 185);
  static const Duration quick = Duration(milliseconds: 220);
  static const Duration routeExit = Duration(milliseconds: 220);
  static const Duration pressRelease = Duration(milliseconds: 250);
  static const Duration normal = Duration(milliseconds: 260);
  static const Duration modalEnter = Duration(milliseconds: 270);
  static const Duration tabSwitch = Duration(milliseconds: 280);
  static const Duration navigation = Duration(milliseconds: 300);
  static const Duration routeEnter = Duration(milliseconds: 310);
  static const Duration reveal = Duration(milliseconds: 340);
  static const Duration authSwitch = Duration(milliseconds: 350);

  static const Curve curve = Cubic(0.22, 1.0, 0.36, 1.0);
  static const Curve exitCurve = Cubic(0.4, 0.0, 0.85, 0.25);
  static const Cubic silk = Cubic(0.22, 1.0, 0.36, 1.0);
  static const Cubic fluid = Cubic(0.25, 1.0, 0.5, 1.0);
  static const Cubic spring = Cubic(0.2, 0.95, 0.3, 1.0);
  static const Cubic gentleSpring = Cubic(0.16, 1.0, 0.3, 1.0);
  static const Cubic responsiveSpring = Cubic(0.2, 0.95, 0.3, 1.0);

  static const Interval tabExitInterval = Interval(
    0.0,
    0.28,
    curve: Cubic(0.4, 0.0, 0.85, 0.25),
  );
  static const Interval tabEnterInterval = Interval(
    0.20,
    1.0,
    curve: Cubic(0.16, 1.0, 0.3, 1.0),
  );

  static const double tabSlideDistance = 0.016;
  static const double tabVerticalLift = 0.014;
  static const double tabScaleBegin = 0.990;
  static const double pressScale = 0.980;
  static const double hoverScale = 1.004;

  static bool reducedMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Warm Gallery & Frosted Alabaster material parameters.
abstract final class IsleGlass {
  static const double sigmaSubtle = 14.0;
  static const double sigmaRegular = 26.0;
  static const double sigmaIntense = 36.0;

  static final ui.ImageFilter filterSubtle = ui.ImageFilter.blur(
    sigmaX: sigmaSubtle,
    sigmaY: sigmaSubtle,
  );
  static final ui.ImageFilter filterRegular = ui.ImageFilter.blur(
    sigmaX: sigmaRegular,
    sigmaY: sigmaRegular,
  );
  static final ui.ImageFilter filterIntense = ui.ImageFilter.blur(
    sigmaX: sigmaIntense,
    sigmaY: sigmaIntense,
  );

  static Color regularTint(bool dark, Color surface) =>
      surface.withValues(alpha: dark ? 0.80 : 0.86);

  static Color rawGalleryRimBorderColor(
    bool dark, {
    bool isGlass = false,
    bool hovered = false,
  }) {
    if (isGlass) {
      return dark
          ? const Color(0xfff5f2eb).withValues(alpha: hovered ? 0.22 : 0.13)
          : const Color(0xff1c1917).withValues(alpha: hovered ? 0.14 : 0.085);
    }
    return dark
        ? const Color(0xfff5f2eb).withValues(alpha: hovered ? 0.19 : 0.105)
        : const Color(0xff1c1917).withValues(alpha: hovered ? 0.15 : 0.085);
  }

  static Color rimBorderColor(
    bool dark, {
    bool isGlass = false,
    bool hovered = false,
  }) => IsleThemeStyle(
    preset: IslePalette.activePreset,
    dark: dark,
  ).rimBorderColor(isGlass: isGlass, hovered: hovered);

  static Color rawGallerySpecularLipColor(bool dark) => dark
      ? const Color(0xfffffaf0).withValues(alpha: 0.13)
      : Colors.white.withValues(alpha: 0.94);

  static Color specularLipColor(bool dark) => IsleThemeStyle(
    preset: IslePalette.activePreset,
    dark: dark,
  ).specularLipColor();

  static Color specularBorder(bool dark) => rimBorderColor(dark, isGlass: true);

  static Color hairlineBorder(bool dark) =>
      rimBorderColor(dark, isGlass: false);

  static LinearGradient cardGradient(bool dark, {Color? accent}) {
    final palette = IslePalette(dark);
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        palette['cardTop'].withValues(alpha: dark ? 0.92 : 0.98),
        accent != null
            ? Color.lerp(
                palette['cardBottom'],
                accent,
                dark ? 0.09 : 0.045,
              )!.withValues(alpha: dark ? 0.88 : 0.95)
            : palette['cardBottom'].withValues(alpha: dark ? 0.88 : 0.95),
      ],
    );
  }

  static LinearGradient embossedGradient(
    bool dark,
    IslePalette palette, {
    bool hovered = false,
    Color? tint,
  }) {
    final baseTop = hovered
        ? Color.lerp(palette['cardTop'], palette['cardHover'], 0.55)!
        : palette['cardTop'];
    final baseBottom = hovered
        ? Color.lerp(palette['cardBottom'], palette['cardHover'], 0.45)!
        : palette['cardBottom'];
    if (tint != null) {
      final overlay = tint.withValues(alpha: dark ? 0.11 : 0.055);
      return LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.alphaBlend(overlay, baseTop),
          Color.alphaBlend(overlay, baseBottom),
        ],
      );
    }
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [baseTop, baseBottom],
    );
  }
}

/// Adaptive shadow recipes that follow the active [IsleThemePreset].
abstract final class IsleShadows {
  static const Color _warmInk = Color(0xff1c1917);

  static List<BoxShadow> rawGallerySubtle(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.24)
          : _warmInk.withValues(alpha: 0.032),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> rawGalleryCard(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.26)
          : _warmInk.withValues(alpha: 0.028),
      blurRadius: 2.5,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.36)
          : _warmInk.withValues(alpha: 0.052),
      blurRadius: 18,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> rawGalleryRaised(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.32)
          : _warmInk.withValues(alpha: 0.042),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.48)
          : _warmInk.withValues(alpha: 0.088),
      blurRadius: 26,
      offset: const Offset(0, 10),
    ),
  ];

  static List<BoxShadow> rawGalleryFloating(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.52)
          : _warmInk.withValues(alpha: 0.095),
      blurRadius: 32,
      offset: const Offset(0, 12),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.24)
          : _warmInk.withValues(alpha: 0.036),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> subtle(bool dark) => IsleThemeStyle(
    preset: IslePalette.activePreset,
    dark: dark,
  ).subtleShadows();

  static List<BoxShadow> card(bool dark) => IsleThemeStyle(
    preset: IslePalette.activePreset,
    dark: dark,
  ).cardShadows();

  static List<BoxShadow> raised(bool dark) => IsleThemeStyle(
    preset: IslePalette.activePreset,
    dark: dark,
  ).cardShadows(hovered: true);

  static List<BoxShadow> floating(bool dark) => IsleThemeStyle(
    preset: IslePalette.activePreset,
    dark: dark,
  ).floatingShadows();

  static List<BoxShadow> glow(Color color, {double opacity = 0.20}) => [
    BoxShadow(
      color: color.withValues(alpha: opacity),
      blurRadius: 26,
      spreadRadius: 0.5,
      offset: const Offset(0, 8),
    ),
  ];
}

/// Screen size tiers & responsive layout helpers.
enum IsleViewportTier { compact, medium, expanded }

abstract final class IsleLayout {
  static const double compactPageWidth = 600;
  static const double mediumPageWidth = 1024;
  static const double desktopRailWidth = 760;
  static const double tabletRailWidth = 840;
  static const double settingsWidth = 760;
  static const double secondaryPageWidth = 960;
  static const double workbenchMaxWidth = 1240;

  static IsleViewportTier tierForWidth(double width) {
    if (width < compactPageWidth) return IsleViewportTier.compact;
    if (width < mediumPageWidth) return IsleViewportTier.medium;
    return IsleViewportTier.expanded;
  }

  static double pageInset(double availableWidth) {
    if (availableWidth < compactPageWidth) return 12;
    if (availableWidth < 1024) return 18;
    return 24;
  }

  static double pageTopInset(double availableWidth) {
    if (availableWidth < compactPageWidth) return 8;
    if (availableWidth < 1024) return 14;
    return 18;
  }

  static bool useRail({
    required double width,
    required double height,
    required bool desktop,
  }) =>
      width >= (desktop ? desktopRailWidth : tabletRailWidth) &&
      height >= (desktop ? 460 : 600);

  static bool extendedRail({
    required double width,
    required double textScale,
    required bool expanded,
  }) => expanded && width >= 1120 && textScale <= 1.45;

  static bool compactToolbar(double width, double textScale) =>
      width < 440 || (width < 620 && textScale > 1.35);

  /// High contrast / reduced-motion users should not pay for a blurred dock.
  static bool opaqueNavigation(BuildContext context) =>
      (MediaQuery.maybeHighContrastOf(context) ?? false) ||
      IsleMotion.reducedMotion(context);
}

/// Curated Warm Editorial Gallery palette ("温润画廊质感") exclusive to Flutter.
/// Replaces the cold blue-on-white SaaS palette with warm parchment linen,
/// pure gallery paper cards, deep mineral teal-ink, terracotta, ochre, and sage.
abstract final class IsleGalleryColors {
  static const Map<String, Color> light = <String, Color>{
    'canvasTop': Color(0xfff7f5f0),
    'canvasBottom': Color(0xffefece4),
    'cardTop': Color(0xffffffff),
    'cardBottom': Color(0xfffcfbf8),
    'cardHover': Color(0xfff4f0e8),
    'cardItemTop': Color(0xfffaf8f3),
    'cardItemBottom': Color(0xfff2efe7),
    'chrome': Color(0xfff6f4ee),
    'rim': Color(0xffe3ded4),
    'shadow': Color(0xff1c1917),
    'surfaceBase': Color(0xfff6f4ee),
    'surfaceElevated': Color(0xffffffff),
    'surfaceGlassFallback': Color(0xfff5f3ed),
    'textPrimary': Color(0xff181715),
    'textSecondary': Color(0xff635e57),
    'secondaryText': Color(0xff635e57),
    'textTertiary': Color(0xff948d84),
    'textDisabled': Color(0xffc7c1b8),
    'accentPrimary': Color(0xff1f5162), // Deep Mineral Teal-Ink (黛青墨色)
    'accentSecondary': Color(0xffb85d3b), // Warm Terracotta (陶土暖橘)
    'brandBlue': Color(0xff1f5162),
    'brandCyan': Color(0xff1d6f72),
    'brandViolet': Color(0xff6d4c7d),
    'brandIndigo': Color(0xff3c4f76),
    'brandAmber': Color(0xffb86b19),
    'brandTerracotta': Color(0xffc25934),
    'brandSage': Color(0xff216e53),
    'brandRose': Color(0xffb53858),
    'success': Color(0xff1f7a56),
    'warning': Color(0xffc27816),
    'error': Color(0xffc93b3b),
    'warningText': Color(0xff8c4f00),
    'errorText': Color(0xffa62932),
    'successText': Color(0xff166644),
  };

  static const Map<String, Color> dark = <String, Color>{
    'canvasTop': Color(0xff111110),
    'canvasBottom': Color(0xff171614),
    'cardTop': Color(0xff1f1e1b),
    'cardBottom': Color(0xff191816),
    'cardHover': Color(0xff292723),
    'cardItemTop': Color(0xff24231f),
    'cardItemBottom': Color(0xff1b1a17),
    'chrome': Color(0xff181715),
    'rim': Color(0xff36332d),
    'shadow': Color(0xff000000),
    'surfaceBase': Color(0xff121210),
    'surfaceElevated': Color(0xff1f1e1b),
    'surfaceGlassFallback': Color(0xff181715),
    'textPrimary': Color(0xfff5f2ec),
    'textSecondary': Color(0xffa8a198),
    'secondaryText': Color(0xffa8a198),
    'textTertiary': Color(0xff78726a),
    'textDisabled': Color(0xff524d47),
    'accentPrimary': Color(0xff72bccb), // Luminous Celadon
    'accentSecondary': Color(0xffe08a67), // Soft Terracotta
    'brandBlue': Color(0xff72bccb),
    'brandCyan': Color(0xff64c7be),
    'brandViolet': Color(0xffc39ce0),
    'brandIndigo': Color(0xff9ab0e6),
    'brandAmber': Color(0xffeab057),
    'brandTerracotta': Color(0xffe58b68),
    'brandSage': Color(0xff67c99e),
    'brandRose': Color(0xffeb829c),
    'success': Color(0xff4ac28e),
    'warning': Color(0xfff0b44c),
    'error': Color(0xfff07575),
    'warningText': Color(0xfff4c675),
    'errorText': Color(0xffffaba8),
    'successText': Color(0xff77d6ab),
  };
}

/// Shared LightIsle palette resolved to the active [IsleThemePreset].
class IslePalette {
  const IslePalette(this.dark, {this.preset});
  final bool dark;
  final IsleThemePreset? preset;

  /// Tracks the currently selected global preset so legacy `IslePalette(dark)`
  /// call sites without a [BuildContext] still follow theme switches.
  static IsleThemePreset activePreset = IsleThemePresets.warmGallery;

  IsleThemePreset get effectivePreset => preset ?? activePreset;

  Map<String, Color> get colors => effectivePreset.paletteFor(dark);
  Map<String, Color> get fluid => effectivePreset.paletteFor(dark);
  Color operator [](String name) =>
      fluid[name] ??
      colors[name] ??
      (dark ? IsleGalleryColors.dark[name] : IsleGalleryColors.light[name]) ??
      (dark ? IsleTokens.colorDark[name] : IsleTokens.colorLight[name])!;

  static IslePalette of(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<IsleThemeStyle>();
    if (ext != null) return ext.palette;
    return IslePalette(theme.brightness == Brightness.dark);
  }
}

/// Reusable container & control decoration factories.
abstract final class IsleDecorations {
  static BoxDecoration capsuleControl(
    BuildContext context, {
    bool selected = false,
    Color? accent,
    bool prominent = false,
    bool danger = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final style = IsleThemeStyle.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final tone = danger ? colors.error : (accent ?? colors.primary);
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;
    final borderRadius = isSharp
        ? style.borderRadiusFor(IsleRadius.control)
        : IsleRadius.brPill;

    if (prominent) {
      return BoxDecoration(
        color: isBrutal ? tone : null,
        gradient: isBrutal
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tone,
                  Color.lerp(tone, dark ? Colors.white : Colors.black, 0.12)!,
                ],
              ),
        borderRadius: borderRadius,
        border: Border.all(
          color: isBrutal
              ? style.rimBorderColor()
              : Colors.white.withValues(alpha: dark ? 0.22 : 0.28),
          width: isBrutal ? style.effectiveBorderWidth() : 0.85,
        ),
        boxShadow: highContrast
            ? const []
            : isBrutal
            ? style.subtleShadows()
            : [
                BoxShadow(
                  color: tone.withValues(alpha: dark ? 0.28 : 0.20),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      );
    }

    final palette = style.palette;
    final bg = selected || danger
        ? tone.withValues(alpha: dark ? 0.22 : 0.13)
        : (dark
              ? palette['cardItemTop'].withValues(alpha: 0.88)
              : palette['cardTop'].withValues(alpha: 0.96));
    final border = highContrast
        ? (selected || danger ? tone : colors.outline)
        : isBrutal
        ? style.rimBorderColor()
        : (selected || danger
              ? tone.withValues(alpha: dark ? 0.48 : 0.34)
              : style.rimBorderColor());

    return BoxDecoration(
      color: bg,
      borderRadius: borderRadius,
      border: Border.all(
        color: border,
        width: highContrast
            ? 1.2
            : isBrutal
            ? style.effectiveBorderWidth()
            : (selected ? 1.0 : 0.9),
      ),
      boxShadow: highContrast || selected || danger
          ? null
          : style.subtleShadows(),
    );
  }

  static BoxDecoration recessedWell(
    BuildContext context, {
    double radius = IsleRadius.md,
  }) {
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    return BoxDecoration(
      color: palette['cardItemBottom'],
      borderRadius: style.borderRadiusFor(radius),
      border: Border.all(
        color: style.rimBorderColor(),
        width: style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal
            ? 1.5
            : 0.85,
      ),
    );
  }

  static BoxDecoration iconBadge(
    Color color, {
    double radius = IsleRadius.sm,
    List<Color>? gradient,
    bool shadow = false,
  }) => BoxDecoration(
    color: gradient == null ? color : null,
    gradient: gradient != null
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          )
        : null,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: shadow
        ? [
            BoxShadow(
              color: (gradient?.last ?? color).withValues(alpha: 0.24),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ]
        : null,
  );
}
