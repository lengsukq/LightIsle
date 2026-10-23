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
      style:
          FilledButton.styleFrom(
            foregroundColor: colors.onPrimary,
            backgroundColor: colors.primary,
            minimumSize: const Size(48, 48),
            shape: shape,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
            elevation: 0,
          ).copyWith(
            backgroundBuilder: (context, states, child) {
              if (states.contains(WidgetState.disabled) || highContrast) {
                return child ?? const SizedBox.shrink();
              }
              return DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(IsleTokens.controlRadius),
                  gradient: LinearGradient(
                    colors: dark
                        ? [const Color(0xff3b82f6), const Color(0xff6366f1)]
                        : [const Color(0xff2563eb), const Color(0xff4f46e5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (dark ? const Color(0xff3b82f6) : const Color(0xff2563eb))
                          .withValues(alpha: dark ? 0.35 : 0.24),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: dark ? 0.35 : 0.45),
                    width: 0.75,
                  ),
                ),
                child: child,
              );
            },
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        backgroundColor: p['cardTop'].withValues(alpha: dark ? .65 : .85),
        foregroundColor: colors.onSurface,
        side: BorderSide(
          color: highContrast
              ? colors.outline
              : (dark ? Colors.white.withValues(alpha: 0.14) : p['rim'].withValues(alpha: 0.85)),
          width: highContrast ? 1.5 : 0.8,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        shape: shape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: p['cardTop'],
      selectedColor: colors.primaryContainer,
      side: BorderSide(color: colors.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p['chrome'].withValues(alpha: .96),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: colors.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      labelTextStyle: WidgetStatePropertyAll(
        base.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: colors.primaryContainer,
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
  );
}

/// Living, breathing atmospheric ambient mesh canvas.
/// Diffuses fluid celestial hues (Azure Dawn, Celestial Purple Aurora, Serene Ocean)
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
          if (!quiet) ...[
            // Top-left azure dawn glow
            Positioned(
              left: -120,
              top: -120,
              width: 540,
              height: 540,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xff0284c7).withValues(alpha: dark ? 0.18 : 0.10),
                        const Color(0xff2563eb).withValues(alpha: dark ? 0.10 : 0.05),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // Top-right celestial violet / aurora glow
            Positioned(
              right: -100,
              top: -80,
              width: 560,
              height: 560,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xff7c3aed).withValues(alpha: dark ? 0.16 : 0.08),
                        const Color(0xffa855f7).withValues(alpha: dark ? 0.08 : 0.04),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.52, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // Bottom serene ocean reflection
            Positioned(
              left: 40,
              bottom: -150,
              width: 620,
              height: 420,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.elliptical(310, 210)),
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xff06b6d4).withValues(alpha: dark ? 0.12 : 0.06),
                        const Color(0xff3b82f6).withValues(alpha: dark ? 0.06 : 0.02),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.50, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // Top-center subtle warm sunrise rose accent
            Positioned(
              top: -60,
              left: 180,
              width: 360,
              height: 360,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xfff43f5e).withValues(alpha: dark ? 0.07 : 0.035),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.70],
                    ),
                  ),
                ),
              ),
            ),
          ],
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
  static const navigation = Duration(milliseconds: 320);
  static const curve = Curves.easeOutCubic;
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
