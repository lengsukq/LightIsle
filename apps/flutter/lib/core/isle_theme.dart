import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_style.dart';
export 'isle_style.dart';

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
        secondary: dark ? const Color(0xff94a3b8) : const Color(0xff475569),
        onSecondary: dark ? const Color(0xff0f172a) : Colors.white,
        secondaryContainer: dark
            ? const Color(0xff1e2638)
            : const Color(0xffedf1f7),
        onSecondaryContainer: dark
            ? const Color(0xffe2e8f0)
            : const Color(0xff1e293b),
        outline: dark ? const Color(0xff667b98) : const Color(0xff7386a3),
        outlineVariant: p['rim'],
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
  );
  final controlShape = IsleShapes.control();
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.45,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.3,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -.2,
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
        letterSpacing: -.2,
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
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(dark), width: 0.8),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      errorMaxLines: 4,
      filled: true,
      fillColor: dark ? const Color(0xff1f2436) : const Color(0xfff1f3f8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: IsleRadius.brControl,
        borderSide: BorderSide(
          color: colors.outlineVariant.withValues(alpha: dark ? 0.35 : 0.18),
          width: 0.8,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: IsleRadius.brControl,
        borderSide: BorderSide(
          color: colors.outlineVariant.withValues(alpha: dark ? 0.35 : 0.18),
          width: 0.8,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: IsleRadius.brControl,
        borderSide: BorderSide(color: primary, width: 1.8),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: IsleShapes.control(),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: IsleShapes.control(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        foregroundColor: colors.onSurface,
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: dark ? 0.35 : 0.25),
          width: 0.9,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: IsleShapes.control(),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(
        color: colors.outlineVariant.withValues(alpha: dark ? 0.3 : 0.15),
        width: 0.8,
      ),
      backgroundColor: colors.surface,
      selectedColor: colors.primaryContainer,
      labelStyle: TextStyle(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
      ),
      shape: const StadiumBorder(),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: colors.primary.withValues(alpha: 0.14),
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: colors.primary, size: 24);
        }
        return IconThemeData(color: colors.onSurfaceVariant, size: 23);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: colors.primary,
          );
        }
        return TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: colors.onSurfaceVariant,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.primaryContainer,
      indicatorShape: IsleShapes.control(),
      selectedIconTheme: IconThemeData(color: colors.primary),
      selectedLabelTextStyle: TextStyle(
        color: colors.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: IsleShapes.sheet(
        side: BorderSide(
          color: IsleGlass.rimBorderColor(dark, isGlass: true),
          width: 0.8,
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: IsleShapes.item(
        side: BorderSide(
          color: IsleGlass.rimBorderColor(dark, isGlass: true),
          width: 0.8,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(IsleRadius.sheet),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: IsleShapes.item(),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: colors.primaryContainer,
      borderRadius: IsleRadius.brXs,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: controlShape,
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant.withValues(alpha: dark ? 0.45 : 0.65),
      thickness: 0.6,
      space: 18,
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

/// iOS-grade ambient canvas background with soft scatter halos so translucent
/// Liquid Glass surfaces have subtle depth to refract.
class IsleCanvas extends StatelessWidget {
  const IsleCanvas({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          key: const ValueKey<String>('isle-canvas-background'),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [palette['canvasTop'], palette['canvasBottom']],
              ),
            ),
            child: highContrast
                ? null
                : Align(
                    alignment: Alignment.topCenter,
                    child: IgnorePointer(
                      child: SizedBox(
                        width: double.infinity,
                        height: 280,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                palette['accentPrimary'].withValues(
                                  alpha: isDark ? 0.045 : 0.025,
                                ),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Base Liquid Glass / embossed card surface: subtle top-to-bottom luminosity
/// gradient, continuous squircle corners, specular top rim, and soft ambient shadow.
class IsleSurface extends StatefulWidget {
  const IsleSurface({
    super.key,
    required this.child,
    this.padding = IsleSpace.cardPadding,
    this.margin = EdgeInsets.zero,
    this.radius = IsleTokens.cardRadius,
    this.onTap,
    this.tint,
    this.glass = false,
  });
  final Widget child;
  final EdgeInsetsGeometry padding, margin;
  final double radius;
  final VoidCallback? onTap;
  final Color? tint;
  final bool glass;
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
    final palette = IslePalette(isDark);
    final highContrast = MediaQuery.highContrastOf(context);
    final animate =
        widget.onTap != null && !MediaQuery.disableAnimationsOf(context);
    final hovered = animate && _hovered;
    final pressed = animate && _pressed;

    final isGlass =
        widget.glass && !highContrast && !IsleLayout.opaqueNavigation(context);

    final borderColor = highContrast
        ? colors.outline
        : IsleGlass.rimBorderColor(isDark, isGlass: isGlass, hovered: hovered);
    final borderWidth = highContrast ? 1.2 : (isGlass ? 0.95 : 0.8);
    final shape = IsleShapes.squircle(
      widget.radius,
      side: BorderSide(color: borderColor, width: borderWidth),
    );
    final innerShape = IsleShapes.squircle(widget.radius);

    final content = Padding(padding: widget.padding, child: widget.child);

    final glassTopBase = isDark ? const Color(0xff23293f) : Colors.white;
    final glassBottomBase = isDark
        ? const Color(0xff191e30)
        : const Color(0xfff7f9fc);
    final glassOverlay = widget.tint?.withValues(alpha: isDark ? 0.10 : 0.05);

    final gradient = isGlass
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              (glassOverlay != null
                      ? Color.alphaBlend(glassOverlay, glassTopBase)
                      : glassTopBase)
                  .withValues(alpha: isDark ? 0.80 : 0.88),
              (glassOverlay != null
                      ? Color.alphaBlend(glassOverlay, glassBottomBase)
                      : glassBottomBase)
                  .withValues(alpha: isDark ? 0.72 : 0.82),
            ],
          )
        : IsleGlass.embossedGradient(
            isDark,
            palette,
            hovered: hovered,
            tint: widget.tint,
          );

    Widget interactiveContent = widget.onTap == null
        ? Material(type: MaterialType.transparency, child: content)
        : Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: innerShape,
              onTap: widget.onTap,
              onHover: animate ? (h) => setState(() => _hovered = h) : null,
              onTapDown: animate
                  ? (_) => setState(() => _pressed = true)
                  : null,
              onTapUp: animate ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: animate
                  ? () => setState(() => _pressed = false)
                  : null,
              child: content,
            ),
          );

    Widget cardBody = AnimatedContainer(
      duration: IsleMotion.fast,
      curve: IsleMotion.spring,
      decoration: ShapeDecoration(
        shape: shape,
        gradient: highContrast ? null : gradient,
        color: highContrast ? (widget.tint ?? colors.surface) : null,
        shadows: highContrast
            ? const []
            : (hovered ? IsleShadows.raised(isDark) : IsleShadows.card(isDark)),
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: innerShape),
        child: Stack(
          children: [
            interactiveContent,
            if (!highContrast)
              Positioned(
                top: 0,
                left: widget.radius * 0.6,
                right: widget.radius * 0.6,
                height: 0.8,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          IsleGlass.specularLipColor(isDark),
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
    );

    if (isGlass) {
      cardBody = ClipPath(
        clipper: ShapeBorderClipper(shape: innerShape),
        child: BackdropFilter(filter: IsleGlass.filterRegular, child: cardBody),
      );
    }

    return Padding(
      padding: widget.margin,
      child: AnimatedScale(
        scale: pressed ? IsleMotion.pressScale : (hovered ? 1.006 : 1.0),
        duration: IsleMotion.fast,
        curve: IsleMotion.spring,
        child: cardBody,
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

/// Clean iOS Large-Title style page header without duplicate brand logos.
class IslePageHeader extends StatelessWidget {
  const IslePageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon,
    this.trailing,
    this.hideSubtitleOnCompact = false,
  });
  final String title, subtitle;
  final IconData? icon;
  final Widget? trailing;
  final bool hideSubtitleOnCompact;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
      final narrow = constraints.maxWidth < 440;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final showSubtitle =
          subtitle.isNotEmpty && !(compact && hideSubtitleOnCompact);
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: compact
                ? theme.textTheme.titleLarge?.copyWith(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  )
                : theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
          ),
          if (showSubtitle) ...[
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: compact && !largeText ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style:
                  (compact
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
            ),
          ],
        ],
      );
      final stackTrailing =
          trailing != null &&
          trailing is! IconButton &&
          (largeText || (narrow && trailing is Wrap));
      return Padding(
        padding: EdgeInsets.only(bottom: compact ? 8 : 12),
        child: stackTrailing
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
  const IsleContent({super.key, required this.child, this.maxWidth = 1160});
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
    this.maxWidth = IsleLayout.secondaryPageWidth,
  });
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => IsleContent(
    maxWidth: maxWidth,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final inset = IsleLayout.pageInset(constraints.maxWidth);
        final topInset = IsleLayout.pageTopInset(constraints.maxWidth);
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding:
              padding ??
              EdgeInsets.fromLTRB(inset, topInset, inset, inset + 56),
          children: children,
        );
      },
    ),
  );
}
