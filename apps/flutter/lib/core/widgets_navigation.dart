part of 'widgets.dart';

class IsleFloatingRailDock extends StatelessWidget {
  const IsleFloatingRailDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final isOpaque = IsleLayout.opaqueNavigation(context);
    final shape = IsleShapes.hero(
      side: BorderSide(
        color: IsleGlass.rimBorderColor(isDark, isGlass: true),
        width: 1.0,
      ),
    );
    final innerShape = IsleShapes.hero();

    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 12, bottom: 16, right: 12),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: innerShape),
        child: IsleGlassBackdrop(
          blur: IsleGlass.sigmaRegular,
          child: IntrinsicHeight(
            child: Container(
              decoration: ShapeDecoration(
                shape: shape,
                color: isOpaque ? palette['cardTop'] : null,
                gradient: isOpaque
                    ? null
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [
                                const Color(0xff242a3d).withValues(alpha: 0.78),
                                const Color(0xff141826).withValues(alpha: 0.68),
                              ]
                            : [
                                Colors.white.withValues(alpha: 0.82),
                                const Color(0xfff5f8fd).withValues(alpha: 0.68),
                              ],
                      ),
                shadows: isOpaque ? const [] : IsleShadows.floating(isDark),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS Liquid Glass bottom navigation dock with luminous specular top rim
/// and frosted backdrop blur.
class IsleFloatingBottomNavDock extends StatelessWidget {
  const IsleFloatingBottomNavDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final isOpaque = IsleLayout.opaqueNavigation(context);
    final topBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.85);

    return ClipRect(
      child: IsleGlassBackdrop(
        blur: IsleGlass.sigmaRegular,
        child: Container(
          decoration: BoxDecoration(
            color: isOpaque ? palette['cardTop'] : null,
            gradient: isOpaque
                ? null
                : LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: isDark
                        ? [
                            const Color(0xff202536).withValues(alpha: 0.82),
                            const Color(0xff121520).withValues(alpha: 0.74),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.84),
                            const Color(0xfff4f7fc).withValues(alpha: 0.72),
                          ],
                  ),
            border: Border(top: BorderSide(color: topBorderColor, width: 0.75)),
            boxShadow: isOpaque
                ? const []
                : [
                    BoxShadow(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.35)
                          : const Color(0xff0f172a).withValues(alpha: 0.06),
                      blurRadius: 24,
                      offset: const Offset(0, -4),
                    ),
                  ],
          ),
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            bottom: true,
            child: Padding(padding: IsleSpace.floatingDockMargin, child: child),
          ),
        ),
      ),
    );
  }
}

/// Floating glass action pill HUD for batch selection and multi-item operations
class IsleFloatingActionPill extends StatelessWidget {
  const IsleFloatingActionPill({
    super.key,
    required this.child,
    this.bottomPadding = 16,
  });

  final Widget child;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    final borderColor = IsleGlass.rimBorderColor(isDark, isGlass: true);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: ClipRRect(
            borderRadius: IsleRadius.brPill,
            child: IsleGlassBackdrop(
              blur: IsleGlass.sigmaRegular,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: IsleLayout.opaqueNavigation(context)
                      ? colors.surface
                      : IsleGlass.dockTint(isDark, colors.surface),
                  borderRadius: IsleRadius.brPill,
                  border: Border.all(color: borderColor, width: 1.0),
                  boxShadow: IsleShadows.floating(isDark),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Status and severity badge pill with iOS capsule aesthetic
class IsleBadgePill extends StatelessWidget {
  const IsleBadgePill({super.key, required this.label, this.color, this.icon});

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: isDark ? 0.20 : 0.12),
        borderRadius: IsleRadius.brPill,
        border: Border.all(
          color: effectiveColor.withValues(alpha: isDark ? 0.35 : 0.25),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: effectiveColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: effectiveColor,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Adaptive responsive grid that arranges cards into 1, 2, or more columns
/// based on container constraints and system font scaling.
class IsleResponsiveGrid extends StatelessWidget {
  const IsleResponsiveGrid({
    super.key,
    required this.children,
    this.minItemWidth = 300,
    this.maxColumns = 3,
    this.spacing = 10,
    this.runSpacing = 10,
  });

  final List<Widget> children;
  final double minItemWidth;
  final int maxColumns;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final adjustedMinWidth = minItemWidth * (textScale > 1.3 ? 1.25 : 1.0);
        final rawColumns = (width / adjustedMinWidth).floor().clamp(
          1,
          maxColumns,
        );
        final columns = math.min(rawColumns.toInt(), children.length);
        final itemWidth = (width - (columns - 1) * spacing) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}

/// Unified secondary page AppBar with frosted Liquid Glass backdrop and automatic
/// macOS traffic-light clearance so scrolling content never collides with titles.
class IsleAppBar extends StatelessWidget implements PreferredSizeWidget {
  const IsleAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
    this.toolbarHeight = 52,
    this.centerTitle = false,
    this.foregroundColor,
    this.backgroundColor,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final PreferredSizeWidget? bottom;
  final double toolbarHeight;
  final bool centerTitle;
  final Color? foregroundColor;
  final Color? backgroundColor;

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + (bottom?.preferredSize.height ?? 1.0));

  @override
  Widget build(BuildContext context) {
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isOpaque = IsleLayout.opaqueNavigation(context);

    Widget? effectiveLeading = leading;
    double? effectiveLeadingWidth;

    if (isMac) {
      if (effectiveLeading != null) {
        effectiveLeading = Row(
          mainAxisSize: MainAxisSize.min,
          children: [const SizedBox(width: 78), effectiveLeading],
        );
        effectiveLeadingWidth = 78 + 48;
      } else if (automaticallyImplyLeading && canPop) {
        effectiveLeading = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [SizedBox(width: 78), BackButton()],
        );
        effectiveLeadingWidth = 78 + 48;
      } else if (!canPop) {
        effectiveLeading = const SizedBox(width: 78);
        effectiveLeadingWidth = 78;
      }
    }

    final hairlineColor = isDark
        ? Colors.white.withValues(alpha: 0.09)
        : const Color(0xff0f172a).withValues(alpha: 0.06);

    final effectiveBottom =
        bottom ??
        PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(height: 0.6, color: hairlineColor),
        );

    return AppBar(
      title: title != null
          ? DefaultTextStyle.merge(
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
              ),
              child: title!,
            )
          : null,
      actions: actions,
      actionsPadding: const EdgeInsets.only(right: 8),
      leading: effectiveLeading,
      leadingWidth: effectiveLeadingWidth,
      automaticallyImplyLeading: isMac ? false : automaticallyImplyLeading,
      bottom: effectiveBottom,
      toolbarHeight: toolbarHeight,
      centerTitle: centerTitle,
      foregroundColor: foregroundColor,
      backgroundColor: Colors.transparent,
      flexibleSpace: IsleGlassBackdrop(
        blur: IsleGlass.sigmaRegular,
        child: ColoredBox(
          color:
              backgroundColor ??
              (isOpaque
                  ? colors.surface
                  : IsleGlass.regularTint(isDark, colors.surface)),
        ),
      ),
    );
  }
}
