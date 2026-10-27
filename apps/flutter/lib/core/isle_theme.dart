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

/// Shared LightIsle brand colors. Functional surfaces stay quiet around media.
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
  final primary = dark ? const Color(0xff93baff) : const Color(0xff2459c4);
  final colors =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        contrastLevel: highContrast ? 1 : 0,
      ).copyWith(
        primary: primary,
        onPrimary: dark ? const Color(0xff101b30) : Colors.white,
        surface: p['surfaceElevated'],
        onSurface: p['textPrimary'],
        onSurfaceVariant: dark
            ? const Color(0xffa6b5ca)
            : const Color(0xff52647e),
        surfaceContainerLowest: p['surfaceBase'],
        surfaceContainerLow: p['surfaceBase'],
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
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return base.copyWith(
    scaffoldBackgroundColor: p['surfaceBase'],
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
      backgroundColor: p['surfaceBase'],
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
        systemNavigationBarColor: p['surfaceBase'],
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      errorMaxLines: 4,
      filled: true,
      fillColor: colors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: colors.primaryContainer,
      labelTextStyle: WidgetStatePropertyAll(
        base.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
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
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

/// A static canvas avoids perpetual background work and keeps photos in focus.
class IsleCanvas extends StatelessWidget {
  const IsleCanvas({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: IslePalette.of(context)['surfaceBase'], child: child);
}

class IsleSurface extends StatelessWidget {
  const IsleSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin = EdgeInsets.zero,
    this.radius = 18,
    this.onTap,
    this.tint,
  });
  final Widget child;
  final EdgeInsetsGeometry padding, margin;
  final double radius;
  final VoidCallback? onTap;
  final Color? tint;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Padding(padding: padding, child: child);
    return Padding(
      padding: margin,
      child: Material(
        color: tint ?? colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: MediaQuery.highContrastOf(context)
                ? colors.outline
                : colors.outlineVariant,
            width: .7,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
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

/// Compact headers keep the first row of content within reach on a phone.
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
      final compact = constraints.maxWidth < 600;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 23;
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.headlineSmall),
          if (!compact && subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: largeText && trailing != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [heading, const SizedBox(height: 8), trailing!],
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
      padding:
          padding ??
          EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 24),
      children: children,
    ),
  );
}
