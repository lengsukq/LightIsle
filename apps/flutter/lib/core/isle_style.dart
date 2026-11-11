import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'generated_isle_tokens.dart';
export 'generated_isle_tokens.dart';

/// Unified corner-radius scale for the entire LightIsle Flutter app.
/// Modify values here to adjust roundness across all cards, controls, and modals.
abstract final class IsleRadius {
  static const double xs = IsleTokens.radiusXs; // 8.0
  static const double sm = IsleTokens.radiusSm; // 12.0
  static const double control = 14.0;
  static const double md = IsleTokens.radiusMd; // 16.0
  static const double item = 20.0;
  static const double lg = IsleTokens.radiusLg; // 22.0
  static const double card = 24.0;
  static const double hero = 28.0;
  static const double xl = IsleTokens.radiusXl; // 30.0
  static const double sheet = 32.0;
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

/// iOS continuous superellipse (squircle) geometry builders.
/// Adjust [squircleSmoothing] or [useContinuousCorners] in one place to tune
/// corner curvature across the entire app.
abstract final class IsleShapes {
  static const bool useContinuousCorners = true;
  static const double squircleSmoothing = 2.15;

  static OutlinedBorder squircle(
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

/// Unified spacing and layout tokens.
abstract final class IsleSpace {
  static const double xxs = IsleTokens.space1; // 4.0
  static const double xs = IsleTokens.space2; // 8.0
  static const double sm = IsleTokens.space3; // 12.0
  static const double md = IsleTokens.space4; // 16.0
  static const double lg = IsleTokens.space5; // 20.0
  static const double xl = IsleTokens.space6; // 24.0
  static const double xxl = IsleTokens.space8; // 32.0
  static const double xxxl = IsleTokens.space10; // 40.0
  static const double section = 28.0;

  static const EdgeInsets cardPadding = EdgeInsets.all(20);
  static const EdgeInsets cardPaddingCompact = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 12,
  );
  static const EdgeInsets dialogPadding = EdgeInsets.fromLTRB(24, 22, 24, 20);
  static const EdgeInsets chipPadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 8,
  );
  static const EdgeInsets pillButtonPadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 8,
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
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration quick = Duration(milliseconds: 220);
  static const Duration normal = Duration(milliseconds: 260);
  static const Duration tabSwitch = Duration(milliseconds: 280);
  static const Duration navigation = Duration(milliseconds: 300);
  static const Duration reveal = Duration(milliseconds: 340);

  static const Curve curve = Curves.easeOutCubic;
  static const Curve exitCurve = Curves.easeOutCubic;
  static const Cubic fluid = Cubic(0.25, 1.0, 0.5, 1.0);
  static const Cubic spring = Cubic(0.2, 0.9, 0.3, 1.0);
  static const Cubic gentleSpring = Cubic(0.16, 1.0, 0.3, 1.0);
  static const Cubic responsiveSpring = Cubic(0.2, 0.9, 0.3, 1.0);

  /// Two-stage non-overlapping intervals for tab and sub-view transitions:
  /// outgoing view fades out quickly in 0..32%, incoming view glides in 16..100%.
  static const Interval tabExitInterval = Interval(
    0.0,
    0.32,
    curve: Curves.easeOutCubic,
  );
  static const Interval tabEnterInterval = Interval(
    0.16,
    1.0,
    curve: Cubic(0.2, 0.9, 0.3, 1.0),
  );

  static const double tabSlideDistance = 0.014;
  static const double tabScaleBegin = 0.988;
  static const double pressScale = 0.972;
}

/// Liquid Glass material parameters (blur sigmas, tints, specular rims).
abstract final class IsleGlass {
  static const double sigmaSubtle = 14.0;
  static const double sigmaClear = 18.0;
  static const double sigmaRegular = 28.0;
  static const double sigmaIntense = 36.0;

  static final ui.ImageFilter filterSubtle = ui.ImageFilter.blur(
    sigmaX: sigmaSubtle,
    sigmaY: sigmaSubtle,
  );
  static final ui.ImageFilter filterClear = ui.ImageFilter.blur(
    sigmaX: sigmaClear,
    sigmaY: sigmaClear,
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
      surface.withValues(alpha: dark ? 0.72 : 0.76);

  static Color dockTint(bool dark, Color surface) =>
      surface.withValues(alpha: dark ? 0.76 : 0.80);

  static Color clearTint(bool dark) => dark
      ? const Color(0xff0b101d).withValues(alpha: 0.46)
      : Colors.white.withValues(alpha: 0.56);

  static Color rimBorderColor(
    bool dark, {
    bool isGlass = false,
    bool hovered = false,
  }) {
    if (isGlass) {
      return dark
          ? Colors.white.withValues(alpha: hovered ? 0.26 : 0.16)
          : Colors.white.withValues(alpha: hovered ? 0.92 : 0.78);
    }
    return dark
        ? Colors.white.withValues(alpha: hovered ? 0.18 : 0.10)
        : const Color(0xff0f172a).withValues(alpha: hovered ? 0.10 : 0.055);
  }

  static Color specularLipColor(bool dark) =>
      Colors.white.withValues(alpha: dark ? 0.18 : 0.78);

  static Color specularBorder(bool dark) => rimBorderColor(dark, isGlass: true);

  static Color hairlineBorder(bool dark) =>
      rimBorderColor(dark, isGlass: false);

  static LinearGradient cardGradient(bool dark, {Color? accent}) {
    final palette = IslePalette(dark);
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        palette['cardTop'].withValues(alpha: dark ? 0.84 : 0.90),
        accent != null
            ? Color.lerp(
                palette['cardBottom'],
                accent,
                dark ? 0.08 : 0.04,
              )!.withValues(alpha: dark ? 0.78 : 0.84)
            : palette['cardBottom'].withValues(alpha: dark ? 0.78 : 0.84),
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
      final overlay = tint.withValues(alpha: dark ? 0.10 : 0.05);
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

/// Multi-stop ambient + key shadow recipes matching iOS and macOS Liquid Glass hierarchy.
abstract final class IsleShadows {
  static List<BoxShadow> subtle(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.22)
          : const Color(0xff0f172a).withValues(alpha: 0.03),
      blurRadius: 10,
      offset: const Offset(0, 3),
    ),
  ];

  static List<BoxShadow> card(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.26)
          : const Color(0xff0f172a).withValues(alpha: 0.032),
      blurRadius: 5,
      offset: const Offset(0, 1.5),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.36)
          : const Color(0xff0f172a).withValues(alpha: 0.058),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> raised(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.34)
          : const Color(0xff0f172a).withValues(alpha: 0.048),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.48)
          : const Color(0xff0f172a).withValues(alpha: 0.10),
      blurRadius: 32,
      offset: const Offset(0, 12),
    ),
  ];

  static List<BoxShadow> floating(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.52)
          : const Color(0xff0f172a).withValues(alpha: 0.10),
      blurRadius: 34,
      offset: const Offset(0, 12),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.24)
          : const Color(0xff0f172a).withValues(alpha: 0.038),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> glow(Color color, {double opacity = 0.22}) => [
    BoxShadow(
      color: color.withValues(alpha: opacity),
      blurRadius: 32,
      spreadRadius: 2,
      offset: const Offset(0, 8),
    ),
  ];
}

/// Size decisions use the actual body constraints, not the full display.
abstract final class IsleLayout {
  static const double compactPageWidth = 600;
  static const double desktopRailWidth = 760;
  static const double tabletRailWidth = 840;
  static const double settingsWidth = 720;
  static const double secondaryPageWidth = 860;

  static double pageInset(double availableWidth) {
    if (availableWidth < compactPageWidth) return 12;
    if (availableWidth < 1024) return 18;
    return 24;
  }

  static double pageTopInset(double availableWidth) {
    if (availableWidth < compactPageWidth) return 10;
    if (availableWidth < 1024) return 16;
    return 20;
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
      MediaQuery.highContrastOf(context) ||
      MediaQuery.disableAnimationsOf(context);

  static int responsiveColumns(
    double availableWidth, {
    double minWidth = 320,
    int maxColumns = 2,
    double textScale = 1.0,
  }) {
    final adjusted = minWidth * (textScale > 1.3 ? 1.25 : 1.0);
    return (availableWidth / adjusted).floor().clamp(1, maxColumns).toInt();
  }
}

/// Shared LightIsle brand colors. Functional surfaces stay quiet around media.
class IslePalette {
  const IslePalette(this.dark);
  final bool dark;
  Map<String, Color> get colors =>
      dark ? IsleTokens.colorDark : IsleTokens.colorLight;
  Map<String, Color> get fluid =>
      dark ? IsleTokens.nativeDark : IsleTokens.nativeLight;
  Color operator [](String name) => fluid[name] ?? colors[name]!;
  static IslePalette of(BuildContext context) =>
      IslePalette(Theme.of(context).brightness == Brightness.dark);
}

/// Reusable container & control decoration factories so business pages never
/// hardcode ad-hoc BoxDecorations.
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
    final highContrast = MediaQuery.highContrastOf(context);
    final tone = danger ? colors.error : (accent ?? colors.primary);

    if (prominent) {
      return BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tone,
            Color.lerp(tone, dark ? Colors.white : Colors.black, 0.10)!,
          ],
        ),
        borderRadius: IsleRadius.brPill,
        border: Border.all(
          color: Colors.white.withValues(alpha: dark ? 0.22 : 0.32),
          width: 0.75,
        ),
        boxShadow: highContrast
            ? const []
            : [
                BoxShadow(
                  color: tone.withValues(alpha: dark ? 0.30 : 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      );
    }

    final bg = selected || danger
        ? tone.withValues(alpha: dark ? 0.22 : 0.12)
        : (dark
              ? Colors.white.withValues(alpha: 0.07)
              : colors.surface.withValues(alpha: 0.82));
    final border = highContrast
        ? (selected || danger ? tone : colors.outline)
        : (selected || danger
              ? tone.withValues(alpha: dark ? 0.42 : 0.26)
              : IsleGlass.rimBorderColor(dark));

    return BoxDecoration(
      color: bg,
      borderRadius: IsleRadius.brPill,
      border: Border.all(
        color: border,
        width: highContrast ? 1.2 : (selected ? 1.0 : 0.75),
      ),
      boxShadow: selected && !highContrast
          ? [
              BoxShadow(
                color: tone.withValues(alpha: dark ? 0.18 : 0.10),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ]
          : null,
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
              color: (gradient?.last ?? color).withValues(alpha: 0.26),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ]
        : null,
  );
}
