import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'generated_isle_tokens.dart';
export 'generated_isle_tokens.dart';

abstract final class IsleMotion {
  static const fast = Duration(milliseconds: 160);
  static const quick = Duration(milliseconds: 220);
  static const normal = Duration(milliseconds: 300);
  static const navigation = Duration(milliseconds: 320);
  static const reveal = Duration(milliseconds: 350);
  static const curve = Curves.easeOutCubic;
  static const fluid = Cubic(0.25, 1.0, 0.5, 1.0);
  static const spring = Cubic(0.2, 0.9, 0.3, 1.0);
  static const responsiveSpring = Cubic(0.2, 0.9, 0.3, 1.0);
}

/// Multi-stop ambient + key shadow recipes matching iOS and macOS Liquid Glass hierarchy.
abstract final class IsleShadows {
  /// Delicate, multi-stop Apple ambient + key shadow for cards
  static List<BoxShadow> card(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.28)
          : const Color(0xff0f172a).withValues(alpha: 0.035),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.38)
          : const Color(0xff0f172a).withValues(alpha: 0.065),
      blurRadius: 22,
      offset: const Offset(0, 8),
    ),
  ];

  /// Elevated shadow for hover states and raised cards
  static List<BoxShadow> raised(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.35)
          : const Color(0xff0f172a).withValues(alpha: 0.05),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.48)
          : const Color(0xff0f172a).withValues(alpha: 0.11),
      blurRadius: 30,
      offset: const Offset(0, 12),
    ),
  ];

  /// Deep floating shadow for docks, popovers, and sheets
  static List<BoxShadow> floating(bool dark) => [
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.50)
          : const Color(0xff0f172a).withValues(alpha: 0.11),
      blurRadius: 32,
      offset: const Offset(0, 12),
    ),
    BoxShadow(
      color: dark
          ? Colors.black.withValues(alpha: 0.25)
          : const Color(0xff0f172a).withValues(alpha: 0.04),
      blurRadius: 8,
      offset: const Offset(0, 2),
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

  /// Secondary detail and utility pages stay focused on wide desktop windows.
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
          color: dark
              ? Colors.white.withValues(alpha: 0.12)
              : const Color(0xff0f172a).withValues(alpha: 0.05),
          width: 0.8,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      errorMaxLines: 4,
      filled: true,
      fillColor: dark ? const Color(0xff1f2436) : const Color(0xfff1f3f8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: colors.outlineVariant.withValues(alpha: dark ? 0.35 : 0.18),
          width: 0.8,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: colors.outlineVariant.withValues(alpha: dark ? 0.35 : 0.18),
          width: 0.8,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: primary, width: 1.8),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: colors.primary.withValues(alpha: 0.14),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
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
      selectedIconTheme: IconThemeData(color: colors.primary),
      selectedLabelTextStyle: TextStyle(
        color: colors.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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

/// A crisp, refined Apple-grade canvas background with tight contrast and no muddy blobs.
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
                colors: isDark
                    ? const [Color(0xff121520), Color(0xff090b10)]
                    : const [Color(0xfff6f8fb), Color(0xffeff2f7)],
              ),
            ),
            child: highContrast
                ? null
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 260,
                        child: IgnorePointer(
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
    final highContrast = MediaQuery.highContrastOf(context);
    final animate =
        widget.onTap != null && !MediaQuery.disableAnimationsOf(context);
    final hovered = animate && _hovered;
    final pressed = animate && _pressed;

    final isGlass =
        widget.glass && !highContrast && !IsleLayout.opaqueNavigation(context);
    final base = widget.tint ??
        (isGlass
            ? (isDark ? const Color(0xd01e2336) : const Color(0xd9ffffff))
            : colors.surface);

    final borderColor = highContrast
        ? colors.outline
        : isGlass
            ? (isDark
                ? Colors.white.withValues(alpha: hovered ? 0.28 : 0.18)
                : Colors.white.withValues(alpha: hovered ? 0.95 : 0.85))
            : (isDark
                ? Colors.white.withValues(alpha: hovered ? 0.18 : 0.11)
                : const Color(0xff0f172a).withValues(alpha: hovered ? 0.10 : 0.055));

    final borderWidth = highContrast ? 1.2 : (isGlass ? 1.0 : 0.75);
    final content = Padding(padding: widget.padding, child: widget.child);

    final fillColor = hovered
        ? Color.lerp(base, colors.surfaceContainerHigh, 0.4)
        : base;

    Widget interactiveContent = widget.onTap == null
        ? Material(type: MaterialType.transparency, child: content)
        : Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              onHover: animate ? (h) => setState(() => _hovered = h) : null,
              onTapDown: animate ? (_) => setState(() => _pressed = true) : null,
              onTapUp: animate ? (_) => setState(() => _pressed = false) : null,
              onTapCancel:
                  animate ? () => setState(() => _pressed = false) : null,
              child: content,
            ),
          );

    Widget cardBody = AnimatedContainer(
      duration: IsleMotion.fast,
      curve: IsleMotion.spring,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: borderColor,
          width: borderWidth,
        ),
        boxShadow: hovered
            ? IsleShadows.raised(isDark)
            : IsleShadows.card(isDark),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: fillColor,
          child: interactiveContent,
        ),
      ),
    );

    if (isGlass) {
      cardBody = ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        clipBehavior: Clip.antiAlias,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: cardBody,
        ),
      );
    }

    return Padding(
      padding: widget.margin,
      child: AnimatedScale(
        scale: pressed ? 0.985 : (hovered ? 1.008 : 1.0),
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

/// Page titles and primary actions remain visible on every screen size.
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
      final nativeLike = constraints.maxWidth >= 700;
      final showSubtitle =
          subtitle.isNotEmpty && !(compact && hideSubtitleOnCompact);
      final texts = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: compact
                ? theme.textTheme.titleLarge?.copyWith(fontSize: 20)
                : theme.textTheme.headlineSmall,
          ),
          if (showSubtitle) ...[
            const SizedBox(height: 2),
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
                        height: 1.3,
                      ),
            ),
          ],
        ],
      );
      final heading = nativeLike
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const IsleBrandMark(size: 34),
                const SizedBox(width: 10),
                Expanded(child: texts),
              ],
            )
          : texts;
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
