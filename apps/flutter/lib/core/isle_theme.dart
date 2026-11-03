import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'generated_isle_tokens.dart';
export 'generated_isle_tokens.dart';

abstract final class IsleMotion {
  static const fast = Duration(milliseconds: 180);
  static const quick = Duration(milliseconds: 220);
  static const normal = Duration(milliseconds: 300);
  static const navigation = Duration(milliseconds: 320);
  static const reveal = Duration(milliseconds: 350);
  static const curve = Curves.easeOutCubic;
  static const fluid = Curves.easeOutCubic;
  static const spring = Curves.easeOutCubic;
  static const responsiveSpring = Curves.easeOutCubic;
}

/// Layered shadow recipes shared by cards and floating chrome. Two layers
/// (ambient + key) read softer than one heavy blur; dark mode deepens the key
/// layer instead of darkening surfaces.
abstract final class IsleShadows {
  static List<BoxShadow> card(bool dark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.14 : 0.030),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.20 : 0.055),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> raised(bool dark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.20 : 0.045),
      blurRadius: 8,
      offset: const Offset(0, 3),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.28 : 0.09),
      blurRadius: 28,
      offset: const Offset(0, 12),
    ),
  ];

  static List<BoxShadow> floating(bool dark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.40 : 0.10),
      blurRadius: 28,
      offset: const Offset(0, 10),
    ),
  ];
}

/// Size decisions use the actual body constraints, not the full display.
/// A rail reduces the remaining page width on small desktop windows.
abstract final class IsleLayout {
  static const double compactPageWidth = 600;
  static const double desktopRailWidth = 760;
  static const double tabletRailWidth = 840;

  /// Grouped settings read best as a focused native pane, not a wide grid.
  static const double settingsWidth = 720;

  static double pageInset(double availableWidth) =>
      availableWidth < compactPageWidth ? 16 : 24;

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

ThemeData buildIsleTheme(Brightness brightness, {bool highContrast = false}) {
  final dark = brightness == Brightness.dark;
  final p = IslePalette(dark);
  final primary = p['accentPrimary'];
  final colors =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        contrastLevel: highContrast ? 1 : 0,
      ).copyWith(
        primary: primary,
        onPrimary: dark ? const Color(0xff101b30) : Colors.white,
        surface: p['cardTop'],
        onSurface: p['textPrimary'],
        onSurfaceVariant: dark
            ? const Color(0xffa6b5ca)
            : const Color(0xff52647e),
        surfaceContainerLowest: p['canvasTop'],
        surfaceContainerLow: p['canvasTop'],
        surfaceContainer: p['cardItemBottom'],
        surfaceContainerHigh: p['cardHover'],
        surfaceContainerHighest: dark
            ? const Color(0xff353c59)
            : const Color(0xffe5eaf6),
        primaryContainer: dark
            ? const Color(0xff1c3260)
            : const Color(0xffe8efff),
        onPrimaryContainer: dark
            ? const Color(0xffc6d9ff)
            : const Color(0xff1746a2),
        outline: dark ? const Color(0xff667b98) : const Color(0xff7386a3),
        outlineVariant: p['rim'],
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(IsleTokens.controlRadius + 2),
  );
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 15,
        height: 1.45,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
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
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(IsleTokens.cardRadius),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.2),
          width: 0.4,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      errorMaxLines: 4,
      filled: true,
      fillColor: colors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(IsleTokens.controlRadius + 2),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(IsleTokens.controlRadius + 2),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(IsleTokens.controlRadius + 2),
        borderSide: BorderSide(color: primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        foregroundColor: colors.onSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide.none,
      backgroundColor: colors.surface,
      selectedColor: colors.primaryContainer,
      labelStyle: TextStyle(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(IsleTokens.controlRadius),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 62,
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: colors.primary.withValues(alpha: 0.12),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: colors.primary, size: 24);
        }
        return IconThemeData(color: colors.onSurfaceVariant, size: 24);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: colors.primary,
          );
        }
        return TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: colors.onSurfaceVariant,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.primaryContainer,
      selectedIconTheme: IconThemeData(color: colors.primary),
      selectedLabelTextStyle: TextStyle(
        color: colors.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: colors.primaryContainer,
      borderRadius: BorderRadius.circular(6),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: shape,
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant,
      thickness: .7,
      space: 20,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(
          backgroundColor: Colors.transparent,
        ),
      },
    ),
  );
}

/// A static canvas avoids perpetual background work and keeps photos in focus.
class IsleCanvas extends StatelessWidget {
  const IsleCanvas({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          key: const ValueKey<String>('isle-canvas-background'),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette['canvasTop'], palette['canvasBottom']],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!MediaQuery.highContrastOf(context))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(1.0, -0.9),
                            radius: 1.5,
                            colors: [
                              palette['brandCyan'].withValues(alpha: .055),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!MediaQuery.highContrastOf(context))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(-1.0, 1.0),
                            radius: 1.7,
                            colors: [
                              palette['brandViolet'].withValues(alpha: .045),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Base card: layered shadow + hairline rim. Interactive surfaces gain a
/// quiet hover lift (brighter tint + raised shadow) and a brief press scale;
/// reduced-motion users get the plain surface with the default ripple only.
class IsleSurface extends StatefulWidget {
  const IsleSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin = EdgeInsets.zero,
    this.radius = IsleTokens.cardRadius,
    this.onTap,
    this.tint,
  });
  final Widget child;
  final EdgeInsetsGeometry padding, margin;
  final double radius;
  final VoidCallback? onTap;
  final Color? tint;
  @override
  State<IsleSurface> createState() => _IsleSurfaceState();
}

class _IsleSurfaceState extends State<IsleSurface> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final animate =
        widget.onTap != null && !MediaQuery.disableAnimationsOf(context);
    final hovered = animate && _hovered;
    final pressed = animate && _pressed;
    final base = widget.tint ?? colors.surface;
    final content = Padding(padding: widget.padding, child: widget.child);
    return Padding(
      padding: widget.margin,
      child: AnimatedScale(
        scale: pressed ? 0.98 : 1.0,
        duration: IsleMotion.fast,
        curve: IsleMotion.curve,
        child: AnimatedContainer(
          duration: IsleMotion.fast,
          curve: IsleMotion.curve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            color: hovered
                ? Color.lerp(base, colors.surfaceContainerHigh, 0.5)
                : base,
            border: Border.all(
              color: MediaQuery.highContrastOf(context)
                  ? colors.outline
                  : colors.outlineVariant.withValues(
                      alpha: hovered ? 0.16 : 0.08,
                    ),
              width: MediaQuery.highContrastOf(context) ? 1.2 : 0.35,
            ),
            boxShadow: hovered
                ? IsleShadows.raised(isDark)
                : IsleShadows.card(isDark),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: Material(
              type: MaterialType.transparency,
              child: widget.onTap == null
                  ? content
                  : InkWell(
                      onTap: widget.onTap,
                      onHover: animate
                          ? (h) => setState(() => _hovered = h)
                          : null,
                      onTapDown: animate
                          ? (_) => setState(() => _pressed = true)
                          : null,
                      onTapUp: animate
                          ? (_) => setState(() => _pressed = false)
                          : null,
                      onTapCancel: animate
                          ? () => setState(() => _pressed = false)
                          : null,
                      child: content,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class IsleBrandMark extends StatelessWidget {
  const IsleBrandMark({super.key, this.size = 48});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '轻屿标志',
    image: true,
    child: Image.asset(
      'assets/brand-icon.png',
      width: size,
      height: size,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => Icon(
        Icons.water_drop_outlined,
        size: size,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// Page titles and primary actions remain visible on every screen size.
class IslePageHeader extends StatelessWidget {
  const IslePageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon,
    this.trailing,
  });
  final String title, subtitle;
  final IconData? icon;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final compact = constraints.maxWidth < 440;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final nativeLike = constraints.maxWidth >= 700;
      final texts = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: compact
                ? theme.textTheme.titleLarge?.copyWith(fontSize: 22)
                : theme.textTheme.headlineSmall,
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style:
                  (compact
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
            ),
          ],
        ],
      );
      final heading = nativeLike
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const IsleBrandMark(size: 36),
                const SizedBox(width: 12),
                Expanded(child: texts),
              ],
            )
          : texts;
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child:
            (compact || largeText) &&
                trailing != null &&
                trailing is! IconButton
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: trailing!),
                ],
              )
            : Row(
                children: [
                  Expanded(child: heading),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
      );
    },
  );
}

class IsleContent extends StatelessWidget {
  const IsleContent({super.key, required this.child, this.maxWidth = 1120});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

class IsleListView extends StatelessWidget {
  const IsleListView({
    super.key,
    required this.children,
    this.padding,
    this.maxWidth = 1040,
  });
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => IsleContent(
    maxWidth: maxWidth,
    child: LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding:
            padding ??
            EdgeInsets.all(IsleLayout.pageInset(constraints.maxWidth)),
        children: children,
      ),
    ),
  );
}
