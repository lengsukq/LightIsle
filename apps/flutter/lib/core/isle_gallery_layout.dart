import 'package:flutter/material.dart';

import 'isle_theme.dart';
import 'widgets.dart';

/// Multi-tier adaptive builder giving every page dedicated layouts for
/// Compact (Phone <600), Medium (Tablet 600..1024), and Expanded (Desktop >=1024).
///
/// Supports either a unified `builder: (context, tier, maxWidth)` callback OR
/// explicit `compact` / `medium` / `expanded` slot builders.
class IsleAdaptiveBuilder extends StatelessWidget {
  const IsleAdaptiveBuilder({
    super.key,
    this.builder,
    this.compact,
    this.medium,
    this.expanded,
  }) : assert(
         builder != null || compact != null,
         'Either builder or compact must be provided.',
       );

  final Widget Function(
    BuildContext context,
    IsleViewportTier tier,
    double maxWidth,
  )?
  builder;
  final Widget Function(BuildContext context, BoxConstraints constraints)?
  compact;
  final Widget Function(BuildContext context, BoxConstraints constraints)?
  medium;
  final Widget Function(BuildContext context, BoxConstraints constraints)?
  expanded;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final tier = textScale > 1.55
            ? IsleViewportTier.compact
            : IsleLayout.tierForWidth(constraints.maxWidth);
        if (builder != null) {
          return builder!(context, tier, constraints.maxWidth);
        }
        return switch (tier) {
          IsleViewportTier.expanded =>
            (expanded ?? medium ?? compact!)(context, constraints),
          IsleViewportTier.medium =>
            (medium ?? compact!)(context, constraints),
          IsleViewportTier.compact => compact!(context, constraints),
        };
      },
    );
  }
}

/// Signature visual focal-point stage ("视觉中心主舞台") that anchors each page
/// with warm gallery contrast, ambient pigment halo, tabular metrics, and actions.
class IsleFocalStage extends StatelessWidget {
  const IsleFocalStage({
    super.key,
    required this.title,
    this.subtitle = '',
    this.eyebrow,
    this.icon,
    this.accent,
    this.statusBadge,
    this.metrics = const [],
    this.actions = const [],
    this.aside,
    this.darkStage = false,
    this.margin = const EdgeInsets.only(bottom: 12),
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String? eyebrow;
  final IconData? icon;
  final Color? accent;
  final Widget? statusBadge;
  final List<IsleFocalMetric> metrics;
  final List<Widget> actions;
  final Widget? aside;
  final bool darkStage;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = IsleThemeStyle.of(context);
    final isDark = theme.brightness == Brightness.dark || darkStage;
    final palette = darkStage ? IslePalette(true, preset: style.preset) : style.palette;
    final tone = accent ??
        (darkStage ? palette['accentSecondary'] : theme.colorScheme.primary);
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final material = style.preset.surfaceMaterial;
    final isFlatOrBrutal =
        material == IsleSurfaceMaterial.flatHairline ||
        material == IsleSurfaceMaterial.neoBrutal;

    final stageTop = palette['cardTop'];
    final stageBottom = palette['cardBottom'];
    final fgPrimary = palette['textPrimary'];
    final fgSecondary = palette['secondaryText'];
    final trimmedSubtitle = subtitle.trim();

    return Padding(
      padding: margin,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final compact = width < IsleLayout.compactPageWidth || textScale > 1.4;
          final wide = width >= 820 && textScale <= 1.3;

          final shape = style.shapeFor(
            IsleRadius.hero,
            side: BorderSide(
              color: darkStage
                  ? Colors.white.withValues(alpha: 0.14)
                  : style.rimBorderColor(),
              width: darkStage ? 1.0 : style.effectiveBorderWidth(),
            ),
          );

          final mainColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Container(
                      width: compact ? 36 : 40,
                      height: compact ? 36 : 40,
                      decoration: ShapeDecoration(
                        shape: style.shapeFor(
                          compact ? 11 : 12.5,
                          side: BorderSide(
                            color: material == IsleSurfaceMaterial.neoBrutal
                                ? style.rimBorderColor()
                                : tone.withValues(alpha: isDark ? 0.34 : 0.22),
                            width: material == IsleSurfaceMaterial.neoBrutal
                                ? 1.5
                                : 0.9,
                          ),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            tone.withValues(alpha: isDark ? 0.26 : 0.14),
                            tone.withValues(alpha: isDark ? 0.14 : 0.06),
                          ],
                        ),
                      ),
                      child: Icon(icon, color: tone, size: compact ? 18 : 20),
                    ),
                    SizedBox(width: compact ? 10 : 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: compact ? 17 : (wide ? 20.5 : 18.5),
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: fgPrimary,
                            height: 1.2,
                          ),
                        ),
                        if (trimmedSubtitle.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            trimmedSubtitle,
                            maxLines: compact ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: compact ? 12 : 12.5,
                              color: fgSecondary,
                              height: 1.38,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (statusBadge != null) ...[
                    const SizedBox(width: 8),
                    statusBadge!,
                  ],
                ],
              ),
              if (metrics.isNotEmpty) ...[
                SizedBox(height: compact ? 10 : 13),
                Wrap(
                  spacing: compact ? 8 : 10,
                  runSpacing: 8,
                  children: [
                    for (final m in metrics)
                      _FocalMetricWell(
                        metric: m,
                        darkStage: isDark,
                        fgPrimary: fgPrimary,
                        fgSecondary: fgSecondary,
                      ),
                  ],
                ),
              ],
              if (actions.isNotEmpty) ...[
                SizedBox(height: compact ? 10 : 13),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ],
            ],
          );

          final content = Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : (wide ? 22 : 18),
              vertical: compact ? 12 : (wide ? 16 : 14),
            ),
            child: aside != null && wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(flex: 7, child: mainColumn),
                      const SizedBox(width: 20),
                      Flexible(flex: 5, child: aside!),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      mainColumn,
                      if (aside != null) ...[
                        const SizedBox(height: 12),
                        aside!,
                      ],
                    ],
                  ),
          );

          final body = DecoratedBox(
            decoration: ShapeDecoration(
              shape: shape,
              color: highContrast || isFlatOrBrutal ? stageTop : null,
              gradient: highContrast || isFlatOrBrutal
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        stageTop,
                        Color.lerp(stageBottom, tone, isDark ? 0.07 : 0.04)!,
                      ],
                    ),
              shadows: highContrast
                  ? const []
                  : style.cardShadows(hovered: true),
            ),
            child: ClipPath(
              clipper: ShapeBorderClipper(
                shape: style.shapeFor(IsleRadius.hero),
              ),
              child: Stack(
                children: [
                  if (!highContrast && material == IsleSurfaceMaterial.flatHairline)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 3.5,
                      child: IgnorePointer(
                        child: ColoredBox(color: tone),
                      ),
                    )
                  else if (!highContrast && !isFlatOrBrutal)
                    Positioned(
                      right: -40,
                      top: -50,
                      width: 220,
                      height: 220,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                tone.withValues(alpha: isDark ? 0.18 : 0.10),
                                tone.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  onTap == null
                      ? Material(type: MaterialType.transparency, child: content)
                      : Material(
                          type: MaterialType.transparency,
                          child: InkWell(onTap: onTap, child: content),
                        ),
                ],
              ),
            ),
          );
          return body;
        },
      ),
    );
  }
}

/// Compact recessed datum pill displayed inside an [IsleFocalStage].
class IsleFocalMetric {
  const IsleFocalMetric({
    required this.label,
    required this.value,
    this.icon,
    this.color,
    this.accent,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? color;
  final Color? accent;

  Color? get resolvedColor => color ?? accent;
}

class _FocalMetricWell extends StatelessWidget {
  const _FocalMetricWell({
    required this.metric,
    required this.darkStage,
    required this.fgPrimary,
    required this.fgSecondary,
  });

  final IsleFocalMetric metric;
  final bool darkStage;
  final Color fgPrimary;
  final Color fgSecondary;

  @override
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final accent = metric.resolvedColor ?? fgPrimary;
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
      decoration: BoxDecoration(
        color: isBrutal
            ? palette['cardItemTop']
            : darkStage
            ? Colors.white.withValues(alpha: 0.06)
            : palette['cardItemBottom'].withValues(alpha: 0.80),
        borderRadius: style.borderRadiusFor(IsleRadius.sm),
        border: Border.all(
          color: isBrutal
              ? style.rimBorderColor()
              : darkStage
              ? Colors.white.withValues(alpha: 0.10)
              : style.rimBorderColor(),
          width: isBrutal ? 1.4 : 0.85,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (metric.icon != null) ...[
            Icon(metric.icon, size: 14.5, color: accent),
            const SizedBox(width: 6),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                metric.label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: fgSecondary,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 1.5),
              Text(
                metric.value,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: metric.resolvedColor ?? fgPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  height: 1.2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asymmetric two-pane desktop/tablet workbench (Primary Canvas + Side Inspector/Context).
/// Supports either proportional `primaryFlex`/`secondaryFlex` OR fixed `secondaryWidth`.
/// Collapses cleanly into a vertical stack on phones or large accessibility text scales.
class IsleWorkbenchSplit extends StatelessWidget {
  const IsleWorkbenchSplit({
    super.key,
    required this.primary,
    required this.secondary,
    this.breakpoint = 880,
    this.secondaryWidth = 320,
    this.primaryFlex,
    this.secondaryFlex,
    this.gap = 16,
    this.secondaryFirstOnCompact = false,
  });

  final Widget primary;
  final Widget secondary;
  final double breakpoint;
  final double secondaryWidth;
  final int? primaryFlex;
  final int? secondaryFlex;
  final double gap;
  final bool secondaryFirstOnCompact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final split = constraints.maxWidth >= breakpoint && textScale <= 1.35;
        if (split) {
          final useFlex = primaryFlex != null || secondaryFlex != null;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: primaryFlex ?? 7, child: primary),
              SizedBox(width: gap),
              if (useFlex)
                Expanded(flex: secondaryFlex ?? 5, child: secondary)
              else
                SizedBox(width: secondaryWidth, child: secondary),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: secondaryFirstOnCompact
              ? [secondary, SizedBox(height: gap * 0.75), primary]
              : [primary, SizedBox(height: gap * 0.75), secondary],
        );
      },
    );
  }
}
