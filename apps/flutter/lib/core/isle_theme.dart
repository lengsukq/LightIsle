import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'generated_isle_tokens.dart';
export 'generated_isle_tokens.dart';

/// The same semantic colors and dimensions used by Web and the Mac host.
class IslePalette {
  const IslePalette(this.dark);
  final bool dark;
  Map<String, Color> get colors =>
      dark ? IsleTokens.colorDark : IsleTokens.colorLight;
  Map<String, Color> get fluid =>
      dark ? IsleTokens.fluidDark : IsleTokens.fluidLight;
  Color operator [](String name) => colors[name] ?? fluid[name]!;
  static IslePalette of(BuildContext context) =>
      IslePalette(Theme.of(context).brightness == Brightness.dark);
}

ThemeData buildIsleTheme(Brightness brightness, {bool highContrast = false}) {
  final dark = brightness == Brightness.dark;
  final p = IslePalette(dark);
  final primary = highContrast
      ? (dark ? const Color(0xff93c5fd) : const Color(0xff1d4ed8))
      : p['accentPrimary'];
  final colors =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        contrastLevel: highContrast ? 1 : 0,
      ).copyWith(
        primary: primary,
        onPrimary: dark ? const Color(0xff071123) : Colors.white,
        secondary: dark ? const Color(0xffc4b5fd) : p['accentSecondary'],
        surface: p['cardTop'],
        onSurface: p['textPrimary'],
        onSurfaceVariant: dark
            ? const Color(0xffa6b5ca)
            : const Color(0xff52647e),
        surfaceContainerLowest: p['canvasTop'],
        surfaceContainerLow: p['cardBottom'],
        surfaceContainer: p['cardItemBottom'],
        surfaceContainerHigh: p['cardHover'],
        surfaceContainerHighest: dark
            ? const Color(0xff26344d)
            : const Color(0xffe8eef8),
        primaryContainer: dark
            ? const Color(0xff1c3260)
            : const Color(0xffe8efff),
        onPrimaryContainer: dark
            ? const Color(0xffc6d9ff)
            : const Color(0xff1746a2),
        outline: dark ? const Color(0xff667b98) : const Color(0xff7386a3),
        outlineVariant: dark
            ? const Color(0xff2d3c54)
            : const Color(0xffdbe4f1),
      );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(IsleTokens.controlRadius),
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    scaffoldBackgroundColor: Colors.transparent,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.8,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -.3,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p['chrome'].withValues(alpha: .9),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: p['cardTop'],
      surfaceTintColor: Colors.transparent,
      elevation: highContrast ? 0 : 2,
      shadowColor: p['shadow'].withValues(alpha: .15),
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(IsleTokens.cardRadius),
        side: BorderSide(
          color: highContrast
              ? colors.outline
              : p['rim'].withValues(alpha: dark ? .45 : 1),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      errorMaxLines: 4,
      filled: true,
      fillColor: p['cardItemBottom'],
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        foregroundColor: colors.onPrimary,
        backgroundColor: colors.primary,
        minimumSize: const Size(48, 44),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        elevation: 0,
      ).copyWith(
        backgroundBuilder: (context, states, child) {
          if (states.contains(WidgetState.disabled) || highContrast) {
            return child ?? const SizedBox.shrink();
          }
          final isHovered = states.contains(WidgetState.hovered);
          final isPressed = states.contains(WidgetState.pressed);
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(IsleTokens.controlRadius),
              gradient: LinearGradient(
                colors: dark
                    ? (isHovered
                        ? [const Color(0xff60a5fa), const Color(0xff818cf8)]
                        : [const Color(0xff3b82f6), const Color(0xff6366f1)])
                    : (isHovered
                        ? [const Color(0xff3b82f6), const Color(0xff6366f1)]
                        : [const Color(0xff2563eb), const Color(0xff4f46e5)]),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: (dark ? const Color(0xff3b82f6) : const Color(0xff2563eb))
                      .withValues(alpha: isPressed ? 0.15 : (isHovered ? 0.40 : 0.25)),
                  blurRadius: isHovered ? 16 : 10,
                  offset: Offset(0, isPressed ? 1 : 3),
                ),
              ],
              border: Border.all(
                color: Colors.white.withValues(alpha: dark ? (isHovered ? 0.45 : 0.30) : (isHovered ? 0.65 : 0.45)),
                width: 0.85,
              ),
            ),
            child: child,
          );
        },
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 44),
        shape: shape,
        foregroundColor: colors.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        elevation: 0,
      ).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return p['cardTop'].withValues(alpha: dark ? 0.35 : 0.45);
          }
          final isHovered = states.contains(WidgetState.hovered);
          final isPressed = states.contains(WidgetState.pressed);
          if (isPressed) return p['cardHover'].withValues(alpha: dark ? 0.95 : 1.0);
          return isHovered
              ? p['cardHover'].withValues(alpha: dark ? 0.90 : 0.96)
              : p['cardTop'].withValues(alpha: dark ? 0.70 : 0.85);
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (highContrast) return BorderSide(color: colors.outline, width: 1.5);
          final isHovered = states.contains(WidgetState.hovered);
          return BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: isHovered ? 0.28 : 0.14)
                : (isHovered ? p['accentPrimary'].withValues(alpha: 0.5) : p['rim'].withValues(alpha: 0.85)),
            width: 0.85,
          );
        }),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        shape: shape,
        foregroundColor: primary,
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.1),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: p['cardTop'].withValues(alpha: dark ? 0.65 : 0.85),
      selectedColor: colors.primaryContainer,
      side: BorderSide(
        color: dark ? Colors.white.withValues(alpha: 0.12) : colors.outlineVariant.withValues(alpha: 0.7),
        width: 0.8,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll(
        base.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      selectedIconTheme: IconThemeData(color: primary),
      selectedLabelTextStyle: TextStyle(
        color: primary,
        fontWeight: FontWeight.w600,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p['cardTop'],
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p['cardTop'],
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p['cardTop'],
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: colors.primaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant.withValues(alpha: .5),
      space: 24,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: IsleFluidPageTransitionsBuilder(),
        TargetPlatform.iOS: IsleFluidPageTransitionsBuilder(),
        TargetPlatform.macOS: IsleFluidPageTransitionsBuilder(),
        TargetPlatform.windows: IsleFluidPageTransitionsBuilder(),
        TargetPlatform.linux: IsleFluidPageTransitionsBuilder(),
      },
    ),
  );
}

/// Living, breathing atmospheric ambient mesh canvas.
/// Diffuses fluid celestial hues (Azure Dawn, Celestial Purple Aurora, Serene Ocean, Sunset Rose)
/// matching macOS IsleFluidBackdrop and Web fluid.css.
class IsleCanvas extends StatelessWidget {
  const IsleCanvas({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final p = IslePalette.of(context);
    final quiet = MediaQuery.highContrastOf(context);
    final dark = p.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p['canvasTop'], p['canvasBottom']],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!quiet)
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth;
                    final h = constraints.maxHeight;
                    final maxDim = math.max(w, h);
                    return Stack(
                      children: [
                        // 1. Top-left azure dawn glow
                        Positioned(
                          left: -w * 0.20,
                          top: -h * 0.15,
                          width: maxDim * 0.85,
                          height: maxDim * 0.85,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xff0284c7).withValues(alpha: dark ? 0.22 : 0.12),
                                  const Color(0xff2563eb).withValues(alpha: dark ? 0.12 : 0.06),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // 2. Top-right celestial violet / aurora glow
                        Positioned(
                          right: -w * 0.15,
                          top: -h * 0.10,
                          width: maxDim * 0.80,
                          height: maxDim * 0.80,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xff7c3aed).withValues(alpha: dark ? 0.20 : 0.10),
                                  const Color(0xffa855f7).withValues(alpha: dark ? 0.10 : 0.05),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.52, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // 3. Center-right sunset rose glow
                        Positioned(
                          right: w * 0.10,
                          top: h * 0.25,
                          width: maxDim * 0.55,
                          height: maxDim * 0.55,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xfff43f5e).withValues(alpha: dark ? 0.08 : 0.04),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.70],
                              ),
                            ),
                          ),
                        ),
                        // 4. Bottom serene ocean teal reflection
                        Positioned(
                          left: w * 0.05,
                          bottom: -h * 0.20,
                          width: maxDim * 0.90,
                          height: maxDim * 0.65,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.all(
                                Radius.elliptical(maxDim * 0.45, maxDim * 0.32),
                              ),
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xff06b6d4).withValues(alpha: dark ? 0.15 : 0.08),
                                  const Color(0xff3b82f6).withValues(alpha: dark ? 0.08 : 0.03),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.50, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // 5. Emerald micro shimmer
                        Positioned(
                          left: w * 0.40,
                          bottom: h * 0.08,
                          width: maxDim * 0.48,
                          height: maxDim * 0.48,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xff10b981).withValues(alpha: dark ? 0.07 : 0.035),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.65],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

class _IsleSpecularRimPainter extends CustomPainter {
  const _IsleSpecularRimPainter({
    required this.radius,
    required this.isDark,
    required this.highContrast,
  });

  final double radius;
  final bool isDark;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    if (highContrast) return;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, size.height),
        [
          isDark
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.85),
          isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.35),
          isDark
              ? Colors.white.withValues(alpha: 0.03)
              : Colors.white.withValues(alpha: 0.12),
          isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.white.withValues(alpha: 0.38),
        ],
        const [0.0, 0.35, 0.70, 1.0],
      );
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_IsleSpecularRimPainter oldDelegate) =>
      radius != oldDelegate.radius ||
      isDark != oldDelegate.isDark ||
      highContrast != oldDelegate.highContrast;
}

abstract final class IsleMotion {
  static const fast = Duration(milliseconds: 180);
  static const normal = Duration(milliseconds: 260);
  static const navigation = Duration(milliseconds: 280);
  static const curve = Cubic(0.16, 1.0, 0.3, 1.0);
  static const fluid = Cubic(0.16, 1.0, 0.3, 1.0);
  static const spring = Cubic(0.20, 0.9, 0.3, 1.0);
}

/// Signature Apple / Liquid Glass fluid route transition builder.
/// Combines shared-axis slide, spring scale, and smooth opacity fading.
class IsleFluidPageTransitionsBuilder extends PageTransitionsBuilder {
  const IsleFluidPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) return child;

    final primaryCurved = CurvedAnimation(
      parent: animation,
      curve: IsleMotion.fluid,
      reverseCurve: Curves.easeInCubic,
    );

    final slide = Tween<Offset>(
      begin: const Offset(0.08, 0.0),
      end: Offset.zero,
    ).animate(primaryCurved);

    final scale = Tween<double>(
      begin: 0.965,
      end: 1.0,
    ).animate(primaryCurved);

    final fade = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.75, curve: Curves.easeOut),
    ));

    final secondaryCurved = CurvedAnimation(
      parent: secondaryAnimation,
      curve: IsleMotion.fluid,
    );

    final secondaryScale = Tween<double>(
      begin: 1.0,
      end: 0.96,
    ).animate(secondaryCurved);

    final secondaryFade = Tween<double>(
      begin: 1.0,
      end: 0.88,
    ).animate(secondaryCurved);

    return SlideTransition(
      position: slide,
      child: ScaleTransition(
        scale: scale,
        child: FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: secondaryScale,
            child: FadeTransition(
              opacity: secondaryFade,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

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
    final p = IslePalette.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final isDark = p.dark;
    final isInteractive = widget.onTap != null;

    Widget content = Padding(padding: widget.padding, child: widget.child);
    if (isInteractive) {
      content = InkWell(
        onTap: widget.onTap,
        onTapDown: (_) {
          if (!disableAnimations) setState(() => _pressed = true);
        },
        onTapUp: (_) {
          if (!disableAnimations) setState(() => _pressed = false);
        },
        onTapCancel: () {
          if (!disableAnimations) setState(() => _pressed = false);
        },
        onHover: (hovering) {
          if (!disableAnimations) setState(() => _hovered = hovering);
        },
        borderRadius: BorderRadius.circular(widget.radius),
        child: content,
      );
    }

    final double scale = isInteractive && !disableAnimations
        ? (_pressed ? 0.985 : (_hovered ? 1.008 : 1.0))
        : 1.0;
    final double offsetY = isInteractive && !disableAnimations
        ? (_pressed ? 1.0 : (_hovered ? -1.5 : 0.0))
        : 0.0;

    return Padding(
      padding: widget.margin,
      child: AnimatedContainer(
        duration: IsleMotion.fast,
        curve: IsleMotion.curve,
        transform: Matrix4.diagonal3Values(scale, scale, 1.0)
          ..setTranslationRaw(0.0, offsetY, 0.0),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          boxShadow: highContrast
              ? []
              : [
                  BoxShadow(
                    color: p['shadow'].withValues(
                      alpha: isDark
                          ? (_hovered ? 0.44 : 0.36)
                          : (_hovered ? 0.12 : 0.07),
                    ),
                    blurRadius: _hovered ? 34 : 28,
                    offset: Offset(0, _hovered ? 12 : 9),
                  ),
                  BoxShadow(
                    color: p['shadow'].withValues(alpha: isDark ? 0.20 : 0.03),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: p['accentPrimary'].withValues(
                      alpha: isDark
                          ? (_hovered ? 0.08 : 0.04)
                          : (_hovered ? 0.05 : 0.025),
                    ),
                    blurRadius: _hovered ? 16 : 12,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(widget.radius),
          clipBehavior: Clip.antiAlias,
          child: CustomPaint(
            foregroundPainter: _IsleSpecularRimPainter(
              radius: widget.radius,
              isDark: isDark,
              highContrast: highContrast,
            ),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _hovered && widget.tint == null
                        ? p['cardHover']
                        : (widget.tint ?? p['cardTop']),
                    p['cardBottom'],
                  ],
                ),
                border: Border.all(
                  color: highContrast
                      ? Theme.of(context).colorScheme.outline
                      : p['rim'].withValues(
                          alpha: isDark
                              ? (_hovered ? 0.40 : 0.25)
                              : (_hovered ? 0.85 : 0.65),
                        ),
                  width: highContrast ? 1.5 : 0.75,
                ),
              ),
              child: content,
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
      final stacked =
          constraints.maxWidth < 440 ||
          MediaQuery.textScalerOf(context).scale(14) > 22;
      final heading = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: theme.colorScheme.primary, size: 24),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 7),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading,
                  if (trailing != null) ...[
                    const SizedBox(height: 14),
                    trailing!,
                  ],
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: heading),
                  if (trailing != null) ...[
                    const SizedBox(width: 20),
                    trailing!,
                  ],
                ],
              ),
      );
    },
  );
}

class IsleContent extends StatelessWidget {
  const IsleContent({super.key, required this.child, this.maxWidth = 1440});
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

/// Bounded single-column pages keep account forms comfortable on large windows.
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
    child: ListView(
      padding: padding ?? const EdgeInsets.all(24),
      children: children,
    ),
  );
}
