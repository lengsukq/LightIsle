import 'package:flutter/material.dart';

import 'isle_style.dart';

/// Built-in visual theme presets for the LightIsle Flutter client.
enum IsleThemePresetId {
  warmGallery('warm_gallery', '温润画廊', '现代暖白石膏与深海青釉，克制留白与柔润层次', '默认'),
  nordicGlass('nordic_glass', '极光玻璃', '银雾铂金与暗曜液态玻璃，通透折射与柔和极光', '通透'),
  swissEditorial('swiss_editorial', '瑞士印刷', '现代黑白极简、精准发丝线框与国际朱红点睛', '极简'),
  neoBrutalPop('neo_brutal_pop', '新粗野波普', '现代工作室波普撞色、利落墨线与硬朗立体投影', '个性'),
  cyberTerminal('cyber_terminal', '赛博终端', '碳黑精密仪表台、微距工程网格与翡翠信号光', '极客');

  const IsleThemePresetId(
    this.storageKey,
    this.displayName,
    this.tagline,
    this.badgeLabel,
  );

  final String storageKey;
  final String displayName;
  final String tagline;
  final String badgeLabel;

  static IsleThemePresetId fromStorageKey(String? raw) {
    if (raw == null || raw.isEmpty) return IsleThemePresetId.warmGallery;
    for (final value in values) {
      if (value.storageKey == raw) return value;
    }
    return IsleThemePresetId.warmGallery;
  }
}

/// Ambient canvas backdrop style rendered by [IsleCanvas].
enum IsleCanvasBackdrop {
  warmGlow,
  auroraGlow,
  flatRule,
  dotMatrix,
  techGrid,
}

/// Primary card and container surface material treatment.
enum IsleSurfaceMaterial {
  paperEmbossed,
  frostedGlass,
  flatHairline,
  neoBrutal,
  terminalGlow,
}

/// Corner geometry language applied to surfaces, controls, and dialogs.
enum IsleCornerStyle { squircle, rounded, sharp }

/// Immutable definition of one complete visual theme preset across five
/// dimensions: palette, canvas backdrop, surface material, corner geometry,
/// and elevation/typography personality.
class IsleThemePreset {
  const IsleThemePreset({
    required this.id,
    required this.canvasBackdrop,
    required this.surfaceMaterial,
    required this.cornerStyle,
    required this.radiusScale,
    required this.borderWidth,
    required this.lightColors,
    required this.darkColors,
    this.monospaceHeadings = false,
    this.headingLetterSpacingDelta = 0.0,
    this.shadowHardOffset = Offset.zero,
  });

  final IsleThemePresetId id;
  final IsleCanvasBackdrop canvasBackdrop;
  final IsleSurfaceMaterial surfaceMaterial;
  final IsleCornerStyle cornerStyle;
  final double radiusScale;
  final double borderWidth;
  final Map<String, Color> lightColors;
  final Map<String, Color> darkColors;
  final bool monospaceHeadings;
  final double headingLetterSpacingDelta;
  final Offset shadowHardOffset;

  String get displayName => id.displayName;
  String get tagline => id.tagline;
  String get badgeLabel => id.badgeLabel;

  Map<String, Color> paletteFor(bool dark) => dark ? darkColors : lightColors;

  List<Color> previewSwatches(bool dark) {
    final p = paletteFor(dark);
    return <Color>[
      p['canvasTop']!,
      p['cardTop']!,
      p['accentPrimary']!,
      p['accentSecondary']!,
    ];
  }
}

/// Registry of all 5 curated LightIsle visual theme presets (2026 modernized).
abstract final class IsleThemePresets {
  static const IsleThemePreset warmGallery = IsleThemePreset(
    id: IsleThemePresetId.warmGallery,
    canvasBackdrop: IsleCanvasBackdrop.warmGlow,
    surfaceMaterial: IsleSurfaceMaterial.paperEmbossed,
    cornerStyle: IsleCornerStyle.squircle,
    radiusScale: 1.0,
    borderWidth: 1.0,
    headingLetterSpacingDelta: -0.05,
    lightColors: IsleGalleryColors.light,
    darkColors: IsleGalleryColors.dark,
  );

  static const IsleThemePreset nordicGlass = IsleThemePreset(
    id: IsleThemePresetId.nordicGlass,
    canvasBackdrop: IsleCanvasBackdrop.auroraGlow,
    surfaceMaterial: IsleSurfaceMaterial.frostedGlass,
    cornerStyle: IsleCornerStyle.squircle,
    radiusScale: 1.12,
    borderWidth: 1.0,
    headingLetterSpacingDelta: -0.1,
    lightColors: <String, Color>{
      'canvasTop': Color(0xfff3f5fa),
      'canvasBottom': Color(0xffe9eef7),
      'cardTop': Color(0xffffffff),
      'cardBottom': Color(0xfffafbfd),
      'cardHover': Color(0xfff1f5fc),
      'cardItemTop': Color(0xfff8fafe),
      'cardItemBottom': Color(0xfff0f4fb),
      'chrome': Color(0xfff6f8fc),
      'rim': Color(0xffd7dfec),
      'shadow': Color(0xff0f172a),
      'surfaceBase': Color(0xfff3f5fa),
      'surfaceElevated': Color(0xffffffff),
      'surfaceGlassFallback': Color(0xfff7f9fd),
      'textPrimary': Color(0xff0e131f),
      'textSecondary': Color(0xff4b566b),
      'secondaryText': Color(0xff4b566b),
      'textTertiary': Color(0xff7f8ca3),
      'textDisabled': Color(0xffbac4d6),
      'accentPrimary': Color(0xff0a66ff),
      'accentSecondary': Color(0xff6e56cf),
      'brandBlue': Color(0xff0a66ff),
      'brandCyan': Color(0xff0891b2),
      'brandViolet': Color(0xff6e56cf),
      'brandIndigo': Color(0xff4f46e5),
      'brandAmber': Color(0xffd97706),
      'brandTerracotta': Color(0xffe15b64),
      'brandSage': Color(0xff059669),
      'brandRose': Color(0xffdb2777),
      'success': Color(0xff059669),
      'warning': Color(0xffd97706),
      'error': Color(0xffdc2626),
      'warningText': Color(0xff9a5204),
      'errorText': Color(0xffb91c1c),
      'successText': Color(0xff047857),
    },
    darkColors: <String, Color>{
      'canvasTop': Color(0xff080a0f),
      'canvasBottom': Color(0xff0e1119),
      'cardTop': Color(0xff161a24),
      'cardBottom': Color(0xff12151e),
      'cardHover': Color(0xff1d2230),
      'cardItemTop': Color(0xff1a1f2b),
      'cardItemBottom': Color(0xff141822),
      'chrome': Color(0xff10131c),
      'rim': Color(0xff2b3245),
      'shadow': Color(0xff000000),
      'surfaceBase': Color(0xff080a0f),
      'surfaceElevated': Color(0xff181c27),
      'surfaceGlassFallback': Color(0xff141822),
      'textPrimary': Color(0xfff4f7fc),
      'textSecondary': Color(0xff9ca7bc),
      'secondaryText': Color(0xff9ca7bc),
      'textTertiary': Color(0xff6c778e),
      'textDisabled': Color(0xff454e61),
      'accentPrimary': Color(0xff5ba4ff),
      'accentSecondary': Color(0xffa78bfa),
      'brandBlue': Color(0xff5ba4ff),
      'brandCyan': Color(0xff38d9e9),
      'brandViolet': Color(0xffa78bfa),
      'brandIndigo': Color(0xff818cf8),
      'brandAmber': Color(0xfffbbf24),
      'brandTerracotta': Color(0xfff87171),
      'brandSage': Color(0xff34d399),
      'brandRose': Color(0xfff472b6),
      'success': Color(0xff34d399),
      'warning': Color(0xfffbbf24),
      'error': Color(0xfff87171),
      'warningText': Color(0xfffde68a),
      'errorText': Color(0xfffecaca),
      'successText': Color(0xff6ee7b7),
    },
  );

  static const IsleThemePreset swissEditorial = IsleThemePreset(
    id: IsleThemePresetId.swissEditorial,
    canvasBackdrop: IsleCanvasBackdrop.flatRule,
    surfaceMaterial: IsleSurfaceMaterial.flatHairline,
    cornerStyle: IsleCornerStyle.sharp,
    radiusScale: 0.45,
    borderWidth: 1.0,
    headingLetterSpacingDelta: -0.2,
    lightColors: <String, Color>{
      'canvasTop': Color(0xfffafafa),
      'canvasBottom': Color(0xfff5f5f6),
      'cardTop': Color(0xffffffff),
      'cardBottom': Color(0xffffffff),
      'cardHover': Color(0xfff4f4f5),
      'cardItemTop': Color(0xfff8f8f9),
      'cardItemBottom': Color(0xfff4f4f5),
      'chrome': Color(0xffffffff),
      'rim': Color(0xffe4e4e7),
      'shadow': Color(0xff09090b),
      'surfaceBase': Color(0xfffafafa),
      'surfaceElevated': Color(0xffffffff),
      'surfaceGlassFallback': Color(0xffffffff),
      'textPrimary': Color(0xff09090b),
      'textSecondary': Color(0xff52525b),
      'secondaryText': Color(0xff52525b),
      'textTertiary': Color(0xff8b8b94),
      'textDisabled': Color(0xffc4c4cc),
      'accentPrimary': Color(0xffe5381a), // International Vermilion
      'accentSecondary': Color(0xff18181b),
      'brandBlue': Color(0xff1d4ed8),
      'brandCyan': Color(0xff0e7490),
      'brandViolet': Color(0xff6d28d9),
      'brandIndigo': Color(0xff312e81),
      'brandAmber': Color(0xffb45309),
      'brandTerracotta': Color(0xffe5381a),
      'brandSage': Color(0xff15803d),
      'brandRose': Color(0xffbe123c),
      'success': Color(0xff15803d),
      'warning': Color(0xffb45309),
      'error': Color(0xffdc2626),
      'warningText': Color(0xff92400e),
      'errorText': Color(0xffb91c1c),
      'successText': Color(0xff166534),
    },
    darkColors: <String, Color>{
      'canvasTop': Color(0xff09090b),
      'canvasBottom': Color(0xff09090b),
      'cardTop': Color(0xff121215),
      'cardBottom': Color(0xff121215),
      'cardHover': Color(0xff1c1c21),
      'cardItemTop': Color(0xff18181c),
      'cardItemBottom': Color(0xff141418),
      'chrome': Color(0xff0d0d10),
      'rim': Color(0xff27272a),
      'shadow': Color(0xff000000),
      'surfaceBase': Color(0xff09090b),
      'surfaceElevated': Color(0xff141418),
      'surfaceGlassFallback': Color(0xff121215),
      'textPrimary': Color(0xfffafafa),
      'textSecondary': Color(0xffa1a1aa),
      'secondaryText': Color(0xffa1a1aa),
      'textTertiary': Color(0xff71717a),
      'textDisabled': Color(0xff46464d),
      'accentPrimary': Color(0xffff5733), // Signal Vermilion
      'accentSecondary': Color(0xffe4e4e7),
      'brandBlue': Color(0xff60a5fa),
      'brandCyan': Color(0xff22d3ee),
      'brandViolet': Color(0xffc084fc),
      'brandIndigo': Color(0xff818cf8),
      'brandAmber': Color(0xfff59e0b),
      'brandTerracotta': Color(0xffff5733),
      'brandSage': Color(0xff4ade80),
      'brandRose': Color(0xfffb7185),
      'success': Color(0xff4ade80),
      'warning': Color(0xfffbbf24),
      'error': Color(0xfff87171),
      'warningText': Color(0xfffde047),
      'errorText': Color(0xfffca5a5),
      'successText': Color(0xff86efac),
    },
  );

  static const IsleThemePreset neoBrutalPop = IsleThemePreset(
    id: IsleThemePresetId.neoBrutalPop,
    canvasBackdrop: IsleCanvasBackdrop.dotMatrix,
    surfaceMaterial: IsleSurfaceMaterial.neoBrutal,
    cornerStyle: IsleCornerStyle.rounded,
    radiusScale: 0.55,
    borderWidth: 1.75,
    shadowHardOffset: Offset(4, 4),
    lightColors: <String, Color>{
      'canvasTop': Color(0xfffaf6ee), // Modern Studio Cream
      'canvasBottom': Color(0xfff3ede0),
      'cardTop': Color(0xffffffff),
      'cardBottom': Color(0xffffffff),
      'cardHover': Color(0xfffdfbf7),
      'cardItemTop': Color(0xfffaf8f3),
      'cardItemBottom': Color(0xfff4efe4),
      'chrome': Color(0xfffaf6ee),
      'rim': Color(0xff18181b),
      'shadow': Color(0xff18181b),
      'surfaceBase': Color(0xfffaf6ee),
      'surfaceElevated': Color(0xffffffff),
      'surfaceGlassFallback': Color(0xffffffff),
      'textPrimary': Color(0xff141417),
      'textSecondary': Color(0xff45433e),
      'secondaryText': Color(0xff45433e),
      'textTertiary': Color(0xff757168),
      'textDisabled': Color(0xffada89d),
      'accentPrimary': Color(0xff3b5bdb), // Electric Studio Indigo
      'accentSecondary': Color(0xfff43f5e), // Pop Berry Coral
      'brandBlue': Color(0xff3b5bdb),
      'brandCyan': Color(0xff0891b2),
      'brandViolet': Color(0xff7c3aed),
      'brandIndigo': Color(0xff4f46e5),
      'brandAmber': Color(0xffd97706),
      'brandTerracotta': Color(0xfff97316),
      'brandSage': Color(0xff059669),
      'brandRose': Color(0xfff43f5e),
      'success': Color(0xff059669),
      'warning': Color(0xffd97706),
      'error': Color(0xffe11d48),
      'warningText': Color(0xff92400e),
      'errorText': Color(0xffbe123c),
      'successText': Color(0xff047857),
    },
    darkColors: <String, Color>{
      'canvasTop': Color(0xff111118), // Midnight Studio Ink
      'canvasBottom': Color(0xff0c0c12),
      'cardTop': Color(0xff1a1a25),
      'cardBottom': Color(0xff1a1a25),
      'cardHover': Color(0xff232333),
      'cardItemTop': Color(0xff20202e),
      'cardItemBottom': Color(0xff171722),
      'chrome': Color(0xff161620),
      'rim': Color(0xffd8d4c8),
      'shadow': Color(0xff050508),
      'surfaceBase': Color(0xff111118),
      'surfaceElevated': Color(0xff1e1e2b),
      'surfaceGlassFallback': Color(0xff1a1a25),
      'textPrimary': Color(0xfffaf8f2),
      'textSecondary': Color(0xffc5c2d4),
      'secondaryText': Color(0xffc5c2d4),
      'textTertiary': Color(0xff8e8aa3),
      'textDisabled': Color(0xff5c5870),
      'accentPrimary': Color(0xfffacc15), // Pop Citrine
      'accentSecondary': Color(0xfffb7185), // Pop Rose
      'brandBlue': Color(0xff748ffc),
      'brandCyan': Color(0xff22d3ee),
      'brandViolet': Color(0xffc084fc),
      'brandIndigo': Color(0xff818cf8),
      'brandAmber': Color(0xfffacc15),
      'brandTerracotta': Color(0xfffb923c),
      'brandSage': Color(0xff34d399),
      'brandRose': Color(0xfffb7185),
      'success': Color(0xff34d399),
      'warning': Color(0xfffacc15),
      'error': Color(0xfffb7185),
      'warningText': Color(0xfffef08a),
      'errorText': Color(0xfffecdd3),
      'successText': Color(0xff6ee7b7),
    },
  );

  static const IsleThemePreset cyberTerminal = IsleThemePreset(
    id: IsleThemePresetId.cyberTerminal,
    canvasBackdrop: IsleCanvasBackdrop.techGrid,
    surfaceMaterial: IsleSurfaceMaterial.terminalGlow,
    cornerStyle: IsleCornerStyle.sharp,
    radiusScale: 0.40,
    borderWidth: 1.0,
    monospaceHeadings: false,
    headingLetterSpacingDelta: -0.05,
    lightColors: <String, Color>{
      'canvasTop': Color(0xfff2f5f4), // Crisp Laboratory Slate
      'canvasBottom': Color(0xffe9eeec),
      'cardTop': Color(0xffffffff),
      'cardBottom': Color(0xfff9fbfa),
      'cardHover': Color(0xffeff4f2),
      'cardItemTop': Color(0xfff5f8f6),
      'cardItemBottom': Color(0xffedf2f0),
      'chrome': Color(0xfff6f9f8),
      'rim': Color(0xffcfdcd6),
      'shadow': Color(0xff0a221a),
      'surfaceBase': Color(0xfff2f5f4),
      'surfaceElevated': Color(0xffffffff),
      'surfaceGlassFallback': Color(0xfff6f9f8),
      'textPrimary': Color(0xff0c1915),
      'textSecondary': Color(0xff3f574e),
      'secondaryText': Color(0xff3f574e),
      'textTertiary': Color(0xff70887f),
      'textDisabled': Color(0xffa8bab3),
      'accentPrimary': Color(0xff059669), // Precision Emerald
      'accentSecondary': Color(0xffd97706), // Telemetry Amber
      'brandBlue': Color(0xff0284c7),
      'brandCyan': Color(0xff0891b2),
      'brandViolet': Color(0xff7c3aed),
      'brandIndigo': Color(0xff4f46e5),
      'brandAmber': Color(0xffd97706),
      'brandTerracotta': Color(0xffea580c),
      'brandSage': Color(0xff059669),
      'brandRose': Color(0xffe11d48),
      'success': Color(0xff059669),
      'warning': Color(0xffd97706),
      'error': Color(0xffdc2626),
      'warningText': Color(0xff92400e),
      'errorText': Color(0xffb91c1c),
      'successText': Color(0xff047857),
    },
    darkColors: <String, Color>{
      'canvasTop': Color(0xff090c0b), // Carbon Obsidian
      'canvasBottom': Color(0xff0d1210),
      'cardTop': Color(0xff111715),
      'cardBottom': Color(0xff0e1412),
      'cardHover': Color(0xff17201d),
      'cardItemTop': Color(0xff141c19),
      'cardItemBottom': Color(0xff101714),
      'chrome': Color(0xff0c110f),
      'rim': Color(0xff23362e),
      'shadow': Color(0xff000000),
      'surfaceBase': Color(0xff090c0b),
      'surfaceElevated': Color(0xff141c19),
      'surfaceGlassFallback': Color(0xff0e1412),
      'textPrimary': Color(0xffecf5f1),
      'textSecondary': Color(0xff8ba89c),
      'secondaryText': Color(0xff8ba89c),
      'textTertiary': Color(0xff5a756a),
      'textDisabled': Color(0xff364a42),
      'accentPrimary': Color(0xff34d399), // Luminous Cyber Emerald
      'accentSecondary': Color(0xfff59e0b), // Signal Amber
      'brandBlue': Color(0xff38bdf8),
      'brandCyan': Color(0xff22d3ee),
      'brandViolet': Color(0xffa78bfa),
      'brandIndigo': Color(0xff818cf8),
      'brandAmber': Color(0xfff59e0b),
      'brandTerracotta': Color(0xfffb923c),
      'brandSage': Color(0xff34d399),
      'brandRose': Color(0xfffb7185),
      'success': Color(0xff34d399),
      'warning': Color(0xfff59e0b),
      'error': Color(0xfff87171),
      'warningText': Color(0xfffde68a),
      'errorText': Color(0xfffecaca),
      'successText': Color(0xff6ee7b7),
    },
  );

  static const List<IsleThemePreset> all = <IsleThemePreset>[
    warmGallery,
    nordicGlass,
    swissEditorial,
    neoBrutalPop,
    cyberTerminal,
  ];

  static IsleThemePreset byId(IsleThemePresetId id) => switch (id) {
    IsleThemePresetId.warmGallery => warmGallery,
    IsleThemePresetId.nordicGlass => nordicGlass,
    IsleThemePresetId.swissEditorial => swissEditorial,
    IsleThemePresetId.neoBrutalPop => neoBrutalPop,
    IsleThemePresetId.cyberTerminal => cyberTerminal,
  };
}

/// Active visual theme extension attached to [ThemeData.extensions].
class IsleThemeStyle extends ThemeExtension<IsleThemeStyle> {
  const IsleThemeStyle({
    required this.preset,
    required this.dark,
    this.highContrast = false,
  });

  final IsleThemePreset preset;
  final bool dark;
  final bool highContrast;

  IsleThemePresetId get presetId => preset.id;

  IslePalette get palette => IslePalette(dark, preset: preset);

  bool get prefersGlassSurface =>
      preset.surfaceMaterial == IsleSurfaceMaterial.frostedGlass;

  bool get showSpecularLip =>
      preset.surfaceMaterial == IsleSurfaceMaterial.paperEmbossed ||
      preset.surfaceMaterial == IsleSurfaceMaterial.frostedGlass;

  double resolveRadius(double baseRadius) {
    if (baseRadius >= 900) return baseRadius;
    final scaled = baseRadius * preset.radiusScale;
    return scaled.clamp(4.0, 32.0);
  }

  BorderRadius borderRadiusFor(double baseRadius) {
    if (baseRadius >= 900) return IsleRadius.brPill;
    return BorderRadius.circular(resolveRadius(baseRadius));
  }

  OutlinedBorder shapeFor(
    double baseRadius, {
    BorderSide side = BorderSide.none,
  }) {
    if (baseRadius >= 900) {
      return StadiumBorder(side: side);
    }
    final radius = resolveRadius(baseRadius);
    return switch (preset.cornerStyle) {
      IsleCornerStyle.squircle => IsleShapes.rawSquircle(radius, side: side),
      IsleCornerStyle.rounded || IsleCornerStyle.sharp =>
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: side,
        ),
    };
  }

  double effectiveBorderWidth({bool hovered = false}) {
    if (highContrast) return 1.5;
    if (preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal) {
      return hovered ? 2.0 : preset.borderWidth;
    }
    if (preset.surfaceMaterial == IsleSurfaceMaterial.terminalGlow) {
      return hovered ? 1.25 : 1.0;
    }
    return preset.borderWidth;
  }

  Color rimBorderColor({bool isGlass = false, bool hovered = false}) {
    final p = palette;
    if (highContrast) {
      return dark ? const Color(0xfffafafa) : const Color(0xff111111);
    }
    return switch (preset.surfaceMaterial) {
      IsleSurfaceMaterial.neoBrutal =>
        dark ? p['rim'].withValues(alpha: 0.78) : p['rim'],
      IsleSurfaceMaterial.flatHairline =>
        hovered ? p['accentPrimary'] : p['rim'],
      IsleSurfaceMaterial.terminalGlow =>
        hovered
            ? p['accentPrimary'].withValues(alpha: dark ? 0.56 : 0.52)
            : p['rim'].withValues(alpha: dark ? 0.72 : 0.85),
      IsleSurfaceMaterial.frostedGlass =>
        dark
            ? const Color(0xffe2ecff).withValues(
                alpha: hovered ? 0.24 : (isGlass ? 0.15 : 0.11),
              )
            : const Color(0xff0f172a).withValues(
                alpha: hovered ? 0.14 : (isGlass ? 0.08 : 0.072),
              ),
      IsleSurfaceMaterial.paperEmbossed => IsleGlass.rawGalleryRimBorderColor(
        dark,
        isGlass: isGlass,
        hovered: hovered,
      ),
    };
  }

  Color specularLipColor() {
    if (preset.surfaceMaterial == IsleSurfaceMaterial.frostedGlass) {
      return dark
          ? const Color(0xffebf3ff).withValues(alpha: 0.16)
          : Colors.white.withValues(alpha: 0.96);
    }
    return IsleGlass.rawGallerySpecularLipColor(dark);
  }

  List<BoxShadow> cardShadows({bool hovered = false}) {
    if (highContrast) return const [];
    final p = palette;
    return switch (preset.surfaceMaterial) {
      IsleSurfaceMaterial.flatHairline => const [],
      IsleSurfaceMaterial.neoBrutal => [
        BoxShadow(
          color: p['shadow'],
          blurRadius: 0,
          spreadRadius: 0,
          offset: hovered
              ? preset.shadowHardOffset + const Offset(2, 2)
              : preset.shadowHardOffset,
        ),
      ],
      IsleSurfaceMaterial.terminalGlow => [
        BoxShadow(
          color: dark
              ? (hovered
                    ? p['accentPrimary'].withValues(alpha: 0.18)
                    : Colors.black.withValues(alpha: 0.42))
              : p['shadow'].withValues(alpha: hovered ? 0.10 : 0.05),
          blurRadius: hovered ? 22 : 14,
          offset: Offset(0, hovered ? 8 : 5),
        ),
      ],
      IsleSurfaceMaterial.frostedGlass => [
        BoxShadow(
          color: p['shadow'].withValues(
            alpha: dark ? (hovered ? 0.48 : 0.36) : (hovered ? 0.10 : 0.055),
          ),
          blurRadius: hovered ? 32 : 22,
          offset: Offset(0, hovered ? 12 : 8),
        ),
      ],
      IsleSurfaceMaterial.paperEmbossed =>
        hovered
            ? IsleShadows.rawGalleryRaised(dark)
            : IsleShadows.rawGalleryCard(dark),
    };
  }

  List<BoxShadow> floatingShadows() {
    if (highContrast) return const [];
    final p = palette;
    return switch (preset.surfaceMaterial) {
      IsleSurfaceMaterial.flatHairline => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.50 : 0.09),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ],
      IsleSurfaceMaterial.neoBrutal => [
        BoxShadow(
          color: p['shadow'],
          blurRadius: 0,
          spreadRadius: 0,
          offset: const Offset(6, 6),
        ),
      ],
      IsleSurfaceMaterial.terminalGlow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.58 : 0.12),
          blurRadius: 26,
          offset: const Offset(0, 10),
        ),
      ],
      IsleSurfaceMaterial.frostedGlass || IsleSurfaceMaterial.paperEmbossed =>
        IsleShadows.rawGalleryFloating(dark),
    };
  }

  List<BoxShadow> subtleShadows() {
    if (highContrast) return const [];
    final p = palette;
    return switch (preset.surfaceMaterial) {
      IsleSurfaceMaterial.flatHairline => const [],
      IsleSurfaceMaterial.neoBrutal => [
        BoxShadow(
          color: p['shadow'],
          blurRadius: 0,
          spreadRadius: 0,
          offset: const Offset(2, 2),
        ),
      ],
      IsleSurfaceMaterial.terminalGlow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.28 : 0.04),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
      IsleSurfaceMaterial.frostedGlass || IsleSurfaceMaterial.paperEmbossed =>
        IsleShadows.rawGallerySubtle(dark),
    };
  }

  static IsleThemeStyle fallback(bool dark, {bool highContrast = false}) =>
      IsleThemeStyle(
        preset: IslePalette.activePreset,
        dark: dark,
        highContrast: highContrast,
      );

  static IsleThemeStyle of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<IsleThemeStyle>() ??
        fallback(
          theme.brightness == Brightness.dark,
          highContrast: MediaQuery.maybeHighContrastOf(context) ?? false,
        );
  }

  @override
  IsleThemeStyle copyWith({
    IsleThemePreset? preset,
    bool? dark,
    bool? highContrast,
  }) => IsleThemeStyle(
    preset: preset ?? this.preset,
    dark: dark ?? this.dark,
    highContrast: highContrast ?? this.highContrast,
  );

  @override
  IsleThemeStyle lerp(covariant ThemeExtension<IsleThemeStyle>? other, double t) {
    if (other is! IsleThemeStyle) return this;
    return t < 0.5 ? this : other;
  }
}
