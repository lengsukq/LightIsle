import 'package:flutter/material.dart';

import 'isle_style.dart';

/// Built-in visual theme presets for the LightIsle Flutter client.
enum IsleThemePresetId {
  warmGallery('warm_gallery', '温润画廊', '宣纸米白与黛青陶土，温润超椭圆浮雕质感', '默认'),
  nordicGlass('nordic_glass', '极光玻璃', '冷雾深空与极光弥散光晕，通透磨砂液态玻璃', '通透'),
  swissEditorial('swiss_editorial', '瑞士印刷', '极简高对比纸面、利落小圆角与国际橙红单点缀', '极简'),
  neoBrutalPop('neo_brutal_pop', '新粗野波普', '大胆撞色、粗实线硬边框与零模糊偏移投影', '个性'),
  cyberTerminal('cyber_terminal', '赛博终端', '工程网格底纹、锐利微圆角与荧光仪表台质感', '极客');

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

/// Registry of all 5 curated LightIsle visual theme presets.
abstract final class IsleThemePresets {
  static const IsleThemePreset warmGallery = IsleThemePreset(
    id: IsleThemePresetId.warmGallery,
    canvasBackdrop: IsleCanvasBackdrop.warmGlow,
    surfaceMaterial: IsleSurfaceMaterial.paperEmbossed,
    cornerStyle: IsleCornerStyle.squircle,
    radiusScale: 1.0,
    borderWidth: 1.0,
    lightColors: IsleGalleryColors.light,
    darkColors: IsleGalleryColors.dark,
  );

  static const IsleThemePreset nordicGlass = IsleThemePreset(
    id: IsleThemePresetId.nordicGlass,
    canvasBackdrop: IsleCanvasBackdrop.auroraGlow,
    surfaceMaterial: IsleSurfaceMaterial.frostedGlass,
    cornerStyle: IsleCornerStyle.squircle,
    radiusScale: 1.18,
    borderWidth: 1.05,
    headingLetterSpacingDelta: -0.1,
    lightColors: <String, Color>{
      'canvasTop': Color(0xffedf4ff),
      'canvasBottom': Color(0xffe1ecfb),
      'cardTop': Color(0xffffffff),
      'cardBottom': Color(0xfff4f8ff),
      'cardHover': Color(0xffe9f2ff),
      'cardItemTop': Color(0xfff6faff),
      'cardItemBottom': Color(0xffeaf2fe),
      'chrome': Color(0xfff1f6ff),
      'rim': Color(0xffcad9f0),
      'shadow': Color(0xff13223b),
      'surfaceBase': Color(0xffedf4ff),
      'surfaceElevated': Color(0xffffffff),
      'surfaceGlassFallback': Color(0xfff0f5ff),
      'textPrimary': Color(0xff0f1c2e),
      'textSecondary': Color(0xff4c5e78),
      'secondaryText': Color(0xff4c5e78),
      'textTertiary': Color(0xff7d90ad),
      'textDisabled': Color(0xffb8c7dc),
      'accentPrimary': Color(0xff1d63e6),
      'accentSecondary': Color(0xff7c4dff),
      'brandBlue': Color(0xff1d63e6),
      'brandCyan': Color(0xff0891b2),
      'brandViolet': Color(0xff7c4dff),
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
      'canvasTop': Color(0xff070d19),
      'canvasBottom': Color(0xff0c1528),
      'cardTop': Color(0xff142038),
      'cardBottom': Color(0xff0e182c),
      'cardHover': Color(0xff1b2b4a),
      'cardItemTop': Color(0xff172540),
      'cardItemBottom': Color(0xff101b30),
      'chrome': Color(0xff0e172a),
      'rim': Color(0xff30466b),
      'shadow': Color(0xff02050a),
      'surfaceBase': Color(0xff070d19),
      'surfaceElevated': Color(0xff142038),
      'surfaceGlassFallback': Color(0xff101a2e),
      'textPrimary': Color(0xfff1f6ff),
      'textSecondary': Color(0xff9bb0cf),
      'secondaryText': Color(0xff9bb0cf),
      'textTertiary': Color(0xff6b80a3),
      'textDisabled': Color(0xff425472),
      'accentPrimary': Color(0xff5ea6ff),
      'accentSecondary': Color(0xffa78bfa),
      'brandBlue': Color(0xff5ea6ff),
      'brandCyan': Color(0xff38d9e9),
      'brandViolet': Color(0xffb392ff),
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
    radiusScale: 0.32,
    borderWidth: 1.0,
    headingLetterSpacingDelta: -0.25,
    lightColors: <String, Color>{
      'canvasTop': Color(0xfffafafa),
      'canvasBottom': Color(0xfff4f4f4),
      'cardTop': Color(0xffffffff),
      'cardBottom': Color(0xffffffff),
      'cardHover': Color(0xfff2f2f2),
      'cardItemTop': Color(0xfff7f7f7),
      'cardItemBottom': Color(0xfff0f0f0),
      'chrome': Color(0xffffffff),
      'rim': Color(0xffd4d4d4),
      'shadow': Color(0xff000000),
      'surfaceBase': Color(0xfffafafa),
      'surfaceElevated': Color(0xffffffff),
      'surfaceGlassFallback': Color(0xffffffff),
      'textPrimary': Color(0xff0a0a0a),
      'textSecondary': Color(0xff525252),
      'secondaryText': Color(0xff525252),
      'textTertiary': Color(0xff8a8a8a),
      'textDisabled': Color(0xffc4c4c4),
      'accentPrimary': Color(0xffe53912), // International Swiss Red-Orange
      'accentSecondary': Color(0xff111111),
      'brandBlue': Color(0xff175cd3),
      'brandCyan': Color(0xff0e7490),
      'brandViolet': Color(0xff5b21b6),
      'brandIndigo': Color(0xff312e81),
      'brandAmber': Color(0xffb45309),
      'brandTerracotta': Color(0xffe53912),
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
      'canvasTop': Color(0xff0a0a0a),
      'canvasBottom': Color(0xff0a0a0a),
      'cardTop': Color(0xff141414),
      'cardBottom': Color(0xff141414),
      'cardHover': Color(0xff1f1f1f),
      'cardItemTop': Color(0xff1a1a1a),
      'cardItemBottom': Color(0xff121212),
      'chrome': Color(0xff0f0f0f),
      'rim': Color(0xff2e2e2e),
      'shadow': Color(0xff000000),
      'surfaceBase': Color(0xff0a0a0a),
      'surfaceElevated': Color(0xff141414),
      'surfaceGlassFallback': Color(0xff121212),
      'textPrimary': Color(0xfffafafa),
      'textSecondary': Color(0xffa3a3a3),
      'secondaryText': Color(0xffa3a3a3),
      'textTertiary': Color(0xff737373),
      'textDisabled': Color(0xff4a4a4a),
      'accentPrimary': Color(0xffff552e), // Luminous International Orange
      'accentSecondary': Color(0xffe5e5e5),
      'brandBlue': Color(0xff60a5fa),
      'brandCyan': Color(0xff22d3ee),
      'brandViolet': Color(0xffc084fc),
      'brandIndigo': Color(0xff818cf8),
      'brandAmber': Color(0xfff59e0b),
      'brandTerracotta': Color(0xffff552e),
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
    radiusScale: 0.42,
    borderWidth: 2.0,
    shadowHardOffset: Offset(4, 4),
    lightColors: <String, Color>{
      'canvasTop': Color(0xfffff6d6), // Warm Pop Cream
      'canvasBottom': Color(0xfffff0bd),
      'cardTop': Color(0xffffffff),
      'cardBottom': Color(0xffffffff),
      'cardHover': Color(0xfffffae8),
      'cardItemTop': Color(0xfffff9e3),
      'cardItemBottom': Color(0xfffff2c6),
      'chrome': Color(0xfffff7d9),
      'rim': Color(0xff141414),
      'shadow': Color(0xff141414),
      'surfaceBase': Color(0xfffff6d6),
      'surfaceElevated': Color(0xffffffff),
      'surfaceGlassFallback': Color(0xffffffff),
      'textPrimary': Color(0xff121212),
      'textSecondary': Color(0xff3f3d36),
      'secondaryText': Color(0xff3f3d36),
      'textTertiary': Color(0xff6e6a5e),
      'textDisabled': Color(0xffa8a293),
      'accentPrimary': Color(0xff2e5bff), // Electric Cobalt
      'accentSecondary': Color(0xffff4d79), // Pop Coral Pink
      'brandBlue': Color(0xff2e5bff),
      'brandCyan': Color(0xff00a896),
      'brandViolet': Color(0xff8b3dff),
      'brandIndigo': Color(0xff3b3bff),
      'brandAmber': Color(0xffe08e00),
      'brandTerracotta': Color(0xffff5722),
      'brandSage': Color(0xff009e60),
      'brandRose': Color(0xffff3b6b),
      'success': Color(0xff009e60),
      'warning': Color(0xffe08e00),
      'error': Color(0xffe5243b),
      'warningText': Color(0xff8f5700),
      'errorText': Color(0xffb8142a),
      'successText': Color(0xff007043),
    },
    darkColors: <String, Color>{
      'canvasTop': Color(0xff181726), // Deep Pop Indigo Ink
      'canvasBottom': Color(0xff131220),
      'cardTop': Color(0xff232136),
      'cardBottom': Color(0xff232136),
      'cardHover': Color(0xff2d2a45),
      'cardItemTop': Color(0xff29263f),
      'cardItemBottom': Color(0xff1e1c30),
      'chrome': Color(0xff1e1c30),
      'rim': Color(0xfff7f3e3),
      'shadow': Color(0xff06050b),
      'surfaceBase': Color(0xff181726),
      'surfaceElevated': Color(0xff232136),
      'surfaceGlassFallback': Color(0xff232136),
      'textPrimary': Color(0xfffffbf0),
      'textSecondary': Color(0xffcbc5df),
      'secondaryText': Color(0xffcbc5df),
      'textTertiary': Color(0xff948db3),
      'textDisabled': Color(0xff635d7d),
      'accentPrimary': Color(0xffffd836), // Pop Acid Yellow
      'accentSecondary': Color(0xffff6b9d), // Neon Bubblegum
      'brandBlue': Color(0xff6e92ff),
      'brandCyan': Color(0xff34e8d4),
      'brandViolet': Color(0xffc084ff),
      'brandIndigo': Color(0xff8d8bff),
      'brandAmber': Color(0xffffd836),
      'brandTerracotta': Color(0xffff7849),
      'brandSage': Color(0xff3ce39a),
      'brandRose': Color(0xffff6b9d),
      'success': Color(0xff3ce39a),
      'warning': Color(0xffffd836),
      'error': Color(0xffff5c74),
      'warningText': Color(0xffffe77a),
      'errorText': Color(0xffffa1af),
      'successText': Color(0xff7ff0be),
    },
  );

  static const IsleThemePreset cyberTerminal = IsleThemePreset(
    id: IsleThemePresetId.cyberTerminal,
    canvasBackdrop: IsleCanvasBackdrop.techGrid,
    surfaceMaterial: IsleSurfaceMaterial.terminalGlow,
    cornerStyle: IsleCornerStyle.sharp,
    radiusScale: 0.24,
    borderWidth: 1.0,
    monospaceHeadings: true,
    headingLetterSpacingDelta: 0.35,
    lightColors: <String, Color>{
      'canvasTop': Color(0xffecf4ef), // Retro Phosphor Paper
      'canvasBottom': Color(0xffe2eee6),
      'cardTop': Color(0xfff7fbf8),
      'cardBottom': Color(0xfff0f7f2),
      'cardHover': Color(0xffe6f2ea),
      'cardItemTop': Color(0xffedf6f0),
      'cardItemBottom': Color(0xffe4efe8),
      'chrome': Color(0xffeef6f1),
      'rim': Color(0xff9fc4ae),
      'shadow': Color(0xff0b3826),
      'surfaceBase': Color(0xffecf4ef),
      'surfaceElevated': Color(0xfff7fbf8),
      'surfaceGlassFallback': Color(0xfff2f8f4),
      'textPrimary': Color(0xff0b2218),
      'textSecondary': Color(0xff335746),
      'secondaryText': Color(0xff335746),
      'textTertiary': Color(0xff628574),
      'textDisabled': Color(0xff9bb5a8),
      'accentPrimary': Color(0xff007a4d), // Deep Matrix Emerald
      'accentSecondary': Color(0xffc97a00), // CRT Amber
      'brandBlue': Color(0xff0077a8),
      'brandCyan': Color(0xff00838f),
      'brandViolet': Color(0xff6d44b8),
      'brandIndigo': Color(0xff2c5ea8),
      'brandAmber': Color(0xffc97a00),
      'brandTerracotta': Color(0xffd84315),
      'brandSage': Color(0xff007a4d),
      'brandRose': Color(0xffc2185b),
      'success': Color(0xff007a4d),
      'warning': Color(0xffc97a00),
      'error': Color(0xffc62828),
      'warningText': Color(0xff8c5400),
      'errorText': Color(0xffa61d1d),
      'successText': Color(0xff00603c),
    },
    darkColors: <String, Color>{
      'canvasTop': Color(0xff060c0a), // Deep Phosphor Void
      'canvasBottom': Color(0xff0a1410),
      'cardTop': Color(0xff0e1b16),
      'cardBottom': Color(0xff0a1410),
      'cardHover': Color(0xff14261f),
      'cardItemTop': Color(0xff11211b),
      'cardItemBottom': Color(0xff0b1712),
      'chrome': Color(0xff0a1410),
      'rim': Color(0xff1e4736),
      'shadow': Color(0xff000000),
      'surfaceBase': Color(0xff060c0a),
      'surfaceElevated': Color(0xff0e1b16),
      'surfaceGlassFallback': Color(0xff0b1612),
      'textPrimary': Color(0xffe0ffef),
      'textSecondary': Color(0xff7ec4a3),
      'secondaryText': Color(0xff7ec4a3),
      'textTertiary': Color(0xff4c876c),
      'textDisabled': Color(0xff2d5241),
      'accentPrimary': Color(0xff00e68a), // Phosphor Terminal Green
      'accentSecondary': Color(0xffffb300), // Amber Console Signal
      'brandBlue': Color(0xff38d2ff),
      'brandCyan': Color(0xff00e5cc),
      'brandViolet': Color(0xffb78cff),
      'brandIndigo': Color(0xff6fa8ff),
      'brandAmber': Color(0xffffb300),
      'brandTerracotta': Color(0xffff7043),
      'brandSage': Color(0xff00e68a),
      'brandRose': Color(0xffff5c8a),
      'success': Color(0xff00e68a),
      'warning': Color(0xffffb300),
      'error': Color(0xffff5252),
      'warningText': Color(0xffffd166),
      'errorText': Color(0xffff9b9b),
      'successText': Color(0xff69f0ae),
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
    return scaled.clamp(3.0, 34.0);
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
      return hovered ? 2.25 : preset.borderWidth;
    }
    if (preset.surfaceMaterial == IsleSurfaceMaterial.terminalGlow) {
      return hovered ? 1.35 : 1.0;
    }
    return preset.borderWidth;
  }

  Color rimBorderColor({bool isGlass = false, bool hovered = false}) {
    final p = palette;
    if (highContrast) {
      return dark ? const Color(0xfffafafa) : const Color(0xff111111);
    }
    return switch (preset.surfaceMaterial) {
      IsleSurfaceMaterial.neoBrutal => p['rim'],
      IsleSurfaceMaterial.flatHairline =>
        hovered ? p['accentPrimary'] : p['rim'],
      IsleSurfaceMaterial.terminalGlow =>
        hovered
            ? p['accentPrimary'].withValues(alpha: dark ? 0.72 : 0.65)
            : p['rim'].withValues(alpha: dark ? 0.85 : 0.90),
      IsleSurfaceMaterial.frostedGlass =>
        dark
            ? const Color(0xffeaf2ff).withValues(
                alpha: hovered ? 0.30 : (isGlass ? 0.20 : 0.16),
              )
            : Colors.white.withValues(
                alpha: hovered ? 0.92 : (isGlass ? 0.78 : 0.68),
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
          ? const Color(0xffd6e9ff).withValues(alpha: 0.24)
          : Colors.white.withValues(alpha: 0.98);
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
          color: p['accentPrimary'].withValues(
            alpha: dark ? (hovered ? 0.24 : 0.12) : (hovered ? 0.14 : 0.06),
          ),
          blurRadius: hovered ? 18 : 10,
          spreadRadius: hovered ? 0.5 : 0,
          offset: Offset.zero,
        ),
      ],
      IsleSurfaceMaterial.frostedGlass => [
        BoxShadow(
          color: p['shadow'].withValues(
            alpha: dark ? (hovered ? 0.44 : 0.32) : (hovered ? 0.12 : 0.07),
          ),
          blurRadius: hovered ? 30 : 20,
          offset: Offset(0, hovered ? 12 : 7),
        ),
      ],
      IsleSurfaceMaterial.paperEmbossed =>
        hovered ? IsleShadows.rawGalleryRaised(dark) : IsleShadows.rawGalleryCard(dark),
    };
  }

  List<BoxShadow> floatingShadows() {
    if (highContrast) return const [];
    final p = palette;
    return switch (preset.surfaceMaterial) {
      IsleSurfaceMaterial.flatHairline => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.45 : 0.08),
          blurRadius: 12,
          offset: const Offset(0, 4),
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
          color: p['accentPrimary'].withValues(alpha: dark ? 0.22 : 0.12),
          blurRadius: 22,
          offset: const Offset(0, 6),
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
          color: p['accentPrimary'].withValues(alpha: dark ? 0.14 : 0.06),
          blurRadius: 8,
          offset: Offset.zero,
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
