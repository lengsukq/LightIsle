import 'package:flutter/material.dart';

import 'isle_style.dart';

/// Ambient canvas adapting its backdrop layer to the active [IsleThemePreset]:
/// warm editorial glow, aurora luminescence, flat Swiss paper, pop dot matrix,
/// or technical coordinate grid.
class IsleCanvas extends StatelessWidget {
  const IsleCanvas({super.key, required this.child});
  final Widget child;

  Widget? _buildBackdropLayer(
    IsleThemeStyle style,
    IslePalette palette,
    bool isDark,
  ) {
    return switch (style.preset.canvasBackdrop) {
      IsleCanvasBackdrop.warmGlow => Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -120,
            left: -80,
            width: 460,
            height: 360,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      palette['brandAmber'].withValues(
                        alpha: isDark ? 0.055 : 0.065,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: -90,
            right: -70,
            width: 420,
            height: 340,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      palette['accentPrimary'].withValues(
                        alpha: isDark ? 0.06 : 0.045,
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
      IsleCanvasBackdrop.auroraGlow => Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -130,
            left: -90,
            width: 520,
            height: 400,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      palette['accentPrimary'].withValues(
                        alpha: isDark ? 0.22 : 0.16,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: -70,
            right: -80,
            width: 480,
            height: 380,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      palette['accentSecondary'].withValues(
                        alpha: isDark ? 0.18 : 0.13,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -140,
            left: 60,
            width: 460,
            height: 340,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      palette['brandCyan'].withValues(
                        alpha: isDark ? 0.14 : 0.10,
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
      IsleCanvasBackdrop.flatRule => Align(
        alignment: Alignment.topCenter,
        child: IgnorePointer(
          child: Container(height: 2.5, color: palette['accentPrimary']),
        ),
      ),
      IsleCanvasBackdrop.dotMatrix => IgnorePointer(
        child: CustomPaint(
          painter: _IsleCanvasPatternPainter(
            kind: _IsleCanvasPatternKind.dots,
            color: palette['rim'].withValues(alpha: isDark ? 0.085 : 0.085),
          ),
        ),
      ),
      IsleCanvasBackdrop.techGrid => Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: CustomPaint(
              painter: _IsleCanvasPatternPainter(
                kind: _IsleCanvasPatternKind.grid,
                color: palette['accentPrimary'].withValues(
                  alpha: isDark ? 0.05 : 0.045,
                ),
              ),
            ),
          ),
          Positioned(
            top: -110,
            right: -60,
            width: 420,
            height: 320,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      palette['accentPrimary'].withValues(
                        alpha: isDark ? 0.09 : 0.055,
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
    };
  }

  @override
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
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
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette['canvasTop'], palette['canvasBottom']],
              ),
            ),
            child: highContrast
                ? null
                : _buildBackdropLayer(style, palette, isDark),
          ),
        ),
        child,
      ],
    );
  }
}

enum _IsleCanvasPatternKind { dots, grid }

class _IsleCanvasPatternPainter extends CustomPainter {
  const _IsleCanvasPatternPainter({required this.kind, required this.color});

  final _IsleCanvasPatternKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (kind == _IsleCanvasPatternKind.dots) {
      const step = 24.0;
      for (double y = 12; y < size.height; y += step) {
        for (double x = 12; x < size.width; x += step) {
          canvas.drawCircle(Offset(x, y), 1.1, paint);
        }
      }
      return;
    }
    paint.strokeWidth = 0.8;
    const step = 36.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _IsleCanvasPatternPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}

/// Primary adaptive card surface responding to the active [IsleThemeStyle]:
/// tactile embossed paper, frosted aurora glass, crisp Swiss hairline,
/// neo-brutalist hard-bordered card, or glowing cyber terminal panel.
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
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final reducedMotion = IsleMotion.reducedMotion(context);
    final animate = widget.onTap != null && !reducedMotion;
    final hovered = animate && _hovered;
    final pressed = animate && _pressed;

    final isGlass =
        (widget.glass || style.prefersGlassSurface) &&
        !highContrast &&
        !IsleLayout.opaqueNavigation(context);

    final borderColor = highContrast
        ? colors.outline
        : style.rimBorderColor(isGlass: isGlass, hovered: hovered);
    final borderWidth = highContrast
        ? 1.25
        : style.effectiveBorderWidth(hovered: hovered);
    final shape = style.shapeFor(
      widget.radius,
      side: BorderSide(color: borderColor, width: borderWidth),
    );
    final innerShape = style.shapeFor(widget.radius);
    final effectiveRadius = style.resolveRadius(widget.radius);

    final content = Padding(padding: widget.padding, child: widget.child);

    final material = style.preset.surfaceMaterial;
    final glassOverlay = widget.tint?.withValues(alpha: isDark ? 0.14 : 0.08);
    final glassTopBase = palette['cardTop'];
    final glassBottomBase = palette['cardBottom'];

    Gradient? gradient;
    Color? solidColor;

    if (highContrast) {
      solidColor = widget.tint ?? colors.surface;
    } else if (isGlass) {
      final topAlpha = material == IsleSurfaceMaterial.frostedGlass
          ? (isDark ? 0.68 : 0.78)
          : (isDark ? 0.86 : 0.93);
      final bottomAlpha = material == IsleSurfaceMaterial.frostedGlass
          ? (isDark ? 0.56 : 0.68)
          : (isDark ? 0.80 : 0.88);
      gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          (glassOverlay != null
                  ? Color.alphaBlend(glassOverlay, glassTopBase)
                  : glassTopBase)
              .withValues(alpha: topAlpha),
          (glassOverlay != null
                  ? Color.alphaBlend(glassOverlay, glassBottomBase)
                  : glassBottomBase)
              .withValues(alpha: bottomAlpha),
        ],
      );
    } else if (material == IsleSurfaceMaterial.flatHairline ||
        material == IsleSurfaceMaterial.neoBrutal) {
      final baseFill = hovered ? palette['cardHover'] : palette['cardTop'];
      solidColor = widget.tint != null
          ? Color.alphaBlend(
              widget.tint!.withValues(alpha: isDark ? 0.16 : 0.08),
              baseFill,
            )
          : baseFill;
    } else {
      gradient = IsleGlass.embossedGradient(
        isDark,
        palette,
        hovered: hovered,
        tint: widget.tint,
      );
    }

    final decoration = ShapeDecoration(
      shape: shape,
      gradient: gradient,
      color: solidColor,
      shadows: highContrast ? const [] : style.cardShadows(hovered: hovered),
    );

    final Widget interactiveContent = widget.onTap == null
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

    final Widget innerStack = ClipPath(
      clipper: ShapeBorderClipper(shape: innerShape),
      child: Stack(
        children: [
          interactiveContent,
          if (!highContrast && style.showSpecularLip)
            Positioned(
              top: 0,
              left: effectiveRadius * 0.50,
              right: effectiveRadius * 0.50,
              height: 0.9,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        style.specularLipColor(),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    Widget cardBody = widget.onTap == null
        ? DecoratedBox(decoration: decoration, child: innerStack)
        : AnimatedContainer(
            duration: animate ? IsleMotion.quick : Duration.zero,
            curve: IsleMotion.silk,
            decoration: decoration,
            child: innerStack,
          );

    if (isGlass) {
      cardBody = ClipPath(
        clipper: ShapeBorderClipper(shape: innerShape),
        child: BackdropFilter(filter: IsleGlass.filterRegular, child: cardBody),
      );
    }

    if (widget.onTap == null) {
      return Padding(padding: widget.margin, child: cardBody);
    }

    return Padding(
      padding: widget.margin,
      child: RepaintBoundary(
        child: animate
            ? AnimatedScale(
                scale: pressed
                    ? IsleMotion.pressScale
                    : (hovered ? IsleMotion.hoverScale : 1.0),
                duration: pressed
                    ? IsleMotion.pressDown
                    : IsleMotion.pressRelease,
                curve: pressed
                    ? Curves.easeOutCubic
                    : IsleMotion.gentleSpring,
                child: cardBody,
              )
            : cardBody,
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

/// Editorial gallery page header with bold display contrast and clean breathing
/// room across phone, tablet, and desktop viewports.
class IslePageHeader extends StatelessWidget {
  const IslePageHeader({
    super.key,
    required this.title,
    this.subtitle = '',
    this.trailing,
    this.eyebrow,
    this.accentColor,
    this.hideSubtitleOnCompact = false,
  });
  final String title, subtitle;
  final String? eyebrow;
  final Color? accentColor;
  final Widget? trailing;
  final bool hideSubtitleOnCompact;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
      final desktop = constraints.maxWidth >= IsleLayout.mediumPageWidth;
      final narrow = constraints.maxWidth < 440;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final trimmedSubtitle = subtitle.trim();
      final showSubtitle =
          trimmedSubtitle.isNotEmpty && !(compact && hideSubtitleOnCompact);
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: compact
                ? theme.textTheme.titleLarge?.copyWith(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    height: 1.16,
                  )
                : theme.textTheme.headlineSmall?.copyWith(
                    fontSize: desktop ? 25 : 22.5,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
          ),
          if (showSubtitle) ...[
            const SizedBox(height: 2.5),
            Text(
              trimmedSubtitle,
              maxLines: compact && !largeText ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: compact ? 12 : 12.5,
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.36,
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
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: trailing!),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: heading),
                  if (trailing != null) ...[
                    const SizedBox(width: 10),
                    trailing!,
                  ],
                ],
              ),
      );
    },
  );
}

class IsleContent extends StatelessWidget {
  const IsleContent({super.key, required this.child, this.maxWidth = 1220});
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
              EdgeInsets.fromLTRB(inset, topInset, inset, inset + 48),
          children: children,
        );
      },
    ),
  );
}
