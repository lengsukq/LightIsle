import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';

export 'isle_charts.dart';
export 'isle_controls.dart';
export 'isle_gallery_layout.dart';
export 'isle_style.dart';

part 'widgets_sections.dart';
part 'widgets_navigation.dart';
part 'widgets_feedback.dart';

/// A single guarded material treatment for dialogs and floating docks.
/// High-contrast and reduced-animation modes get an opaque, unblurred surface.
class IsleGlassBackdrop extends StatelessWidget {
  const IsleGlassBackdrop({
    super.key,
    required this.child,
    this.blur = IsleGlass.sigmaRegular,
  });

  final Widget child;
  final double blur;

  ui.ImageFilter _resolveFilter() {
    if (blur == IsleGlass.sigmaSubtle) return IsleGlass.filterSubtle;
    if (blur == IsleGlass.sigmaRegular) return IsleGlass.filterRegular;
    if (blur == IsleGlass.sigmaIntense) return IsleGlass.filterIntense;
    return ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur);
  }

  @override
  Widget build(BuildContext context) => IsleLayout.opaqueNavigation(context)
      ? child
      : ClipRect(
          child: BackdropFilter(filter: _resolveFilter(), child: child),
        );
}

/// Unified Warm Frosted Glass floating surface for navigation bars, modals, and HUDs.
class IsleGlassSurface extends StatelessWidget {
  const IsleGlassSurface({
    super.key,
    required this.child,
    this.radius = IsleRadius.hero,
    this.padding = EdgeInsets.zero,
    this.elevated = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final isOpaque = IsleLayout.opaqueNavigation(context) ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final shape = style.shapeFor(
      radius,
      side: BorderSide(
        color: style.rimBorderColor(isGlass: !isOpaque),
        width: style.effectiveBorderWidth(),
      ),
    );
    final innerShape = style.shapeFor(radius);

    final body = Container(
      padding: padding,
      decoration: ShapeDecoration(
        shape: shape,
        color: isOpaque
            ? colors.surface
            : IsleGlass.regularTint(isDark, colors.surface),
        shadows: elevated && !IsleLayout.opaqueNavigation(context)
            ? style.floatingShadows()
            : null,
      ),
      child: child,
    );

    if (isOpaque) return body;

    return ClipPath(
      clipper: ShapeBorderClipper(shape: innerShape),
      child: BackdropFilter(filter: IsleGlass.filterRegular, child: body),
    );
  }
}

/// Compact single-row help disclosure bar styled as a quiet gallery footnote.
class IsleHelpDisclosure extends StatelessWidget {
  const IsleHelpDisclosure({
    super.key,
    required this.summary,
    required this.details,
  });
  final String summary;
  final String details;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    return IsleSurface(
      tint: palette['cardItemTop'],
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.symmetric(vertical: 4),
      radius: IsleRadius.md,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          leading: Container(
            width: 24,
            height: 24,
            decoration: IsleDecorations.iconBadge(
              palette['brandAmber'].withValues(alpha: isDark ? 0.18 : 0.11),
              radius: 7,
            ),
            child: Icon(
              Icons.lightbulb_outline_rounded,
              color: palette['brandAmber'],
              size: 14.5,
            ),
          ),
          title: Text(
            summary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
              color: scheme.onSurface.withValues(alpha: 0.86),
            ),
          ),
          children: [
            Divider(
              height: 1,
              thickness: 0.6,
              indent: 12,
              endIndent: 12,
              color: IsleGlass.rimBorderColor(isDark),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  details,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editorial sanctuary host plaque with warm tactile depth and live status beacon.
class IsleDeviceHero extends StatelessWidget {
  const IsleDeviceHero({
    super.key,
    required this.title,
    required this.detail,
    required this.status,
    this.statusColor,
    this.trailingMetrics,
  });

  final String title;
  final String detail;
  final String status;
  final Color? statusColor;
  final Widget? trailingMetrics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scheme = Theme.of(context).colorScheme;
      final palette = IslePalette.of(context);
      final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
      final wide = constraints.maxWidth >= 820;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final statusChip = IsleStatusBadge(
        label: status,
        color: statusColor ?? palette['brandSage'],
      );
      return IsleSurface(
        radius: IsleRadius.hero,
        tint: palette['brandAmber'],
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : (wide ? 20 : 16),
          vertical: compact ? 12 : (wide ? 16 : 13),
        ),
        child: Row(
          children: [
            Container(
              width: compact ? 40 : 48,
              height: compact ? 40 : 48,
              decoration: ShapeDecoration(
                shape: IsleShapes.squircle(
                  compact ? 12 : 15,
                  side: BorderSide(
                    color: scheme.primary.withValues(alpha: 0.22),
                    width: 0.9,
                  ),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary.withValues(alpha: 0.16),
                    palette['brandAmber'].withValues(alpha: 0.10),
                  ],
                ),
              ),
              child: Icon(
                Icons.desktop_mac_rounded,
                color: scheme.primary,
                size: compact ? 20 : 23,
              ),
            ),
            SizedBox(width: compact ? 11 : 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontSize: compact ? 15.5 : 17,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                        ),
                      ),
                      if (compact && !largeText) ...[
                        const SizedBox(width: 8),
                        statusChip,
                      ],
                    ],
                  ),
                  const SizedBox(height: 2.5),
                  Text(
                    detail,
                    maxLines: largeText ? 3 : (compact ? 1 : 2),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  if (largeText) ...[
                    const SizedBox(height: 6),
                    Align(alignment: Alignment.centerLeft, child: statusChip),
                  ],
                ],
              ),
            ),
            if (wide && !largeText && trailingMetrics != null) ...[
              const SizedBox(width: 14),
              trailingMetrics!,
            ],
            if (!compact && !largeText) ...[
              const SizedBox(width: 12),
              statusChip,
            ],
          ],
        ),
      );
    },
  );
}

String formatBytes(num? value) {
  if (value == null || !value.isFinite) return '—';
  var n = value.toDouble();
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
  }
  return '${n.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

List<Map<String, dynamic>> objectList(Object? value) => value is List
    ? value.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
    : [];

/// Unified banner component for informational notices, warnings, and errors.
class Notice extends StatelessWidget {
  const Notice(
    this.message, {
    super.key,
    this.onRetry,
    this.retryLabel = '重试',
    this.error = false,
    this.diagnostic,
    this.icon,
    this.leading,
    this.trailing,
  });
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final bool error;
  final String? diagnostic;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final accentColor = error ? colors.error : palette['brandAmber'];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        liveRegion: true,
        child: IsleSurface(
          radius: IsleRadius.md,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          tint: error
              ? colors.errorContainer.withValues(alpha: isDark ? 0.42 : 0.58)
              : palette['brandAmber'],
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null)
                leading!
              else
                Container(
                  width: 24,
                  height: 24,
                  decoration: IsleDecorations.iconBadge(
                    accentColor.withValues(alpha: isDark ? 0.20 : 0.13),
                    radius: 7,
                  ),
                  child: Center(
                    child: Icon(
                      icon ??
                          (error
                              ? Icons.error_outline_rounded
                              : Icons.info_outline_rounded),
                      color: accentColor,
                      size: 15,
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message,
                      style: TextStyle(
                        color: error
                            ? colors.onErrorContainer
                            : colors.onSurface,
                        height: 1.44,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (diagnostic != null) ...[
                      const SizedBox(height: 4),
                      SelectableText(
                        diagnostic!,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                    if (onRetry != null) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded, size: 15),
                          label: Text(retryLabel),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String message, {
  String action = '确认',
  bool isDestructive = false,
}) async {
  if (isDestructive) {
    HapticFeedback.mediumImpact();
  } else {
    HapticFeedback.lightImpact();
  }
  return await showIsleDialog<bool>(
        context: context,
        builder: (context) {
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: IsleGlassSurface(
                radius: IsleRadius.sheet,
                padding: IsleSpace.dialogPadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDestructive
                                ? colors.error.withValues(alpha: 0.12)
                                : colors.primary.withValues(alpha: 0.12),
                          ),
                          child: Icon(
                            isDestructive
                                ? Icons.warning_amber_rounded
                                : Icons.help_outline_rounded,
                            color: isDestructive
                                ? colors.error
                                : colors.primary,
                            size: 19,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            Navigator.pop(context, false);
                          },
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            if (isDestructive) {
                              HapticFeedback.heavyImpact();
                            } else {
                              HapticFeedback.selectionClick();
                            }
                            Navigator.pop(context, true);
                          },
                          style: isDestructive
                              ? FilledButton.styleFrom(
                                  backgroundColor: colors.error,
                                  foregroundColor: colors.onError,
                                )
                              : null,
                          child: Text(action),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ) ??
      false;
}

/// Refined gallery status badge with pigmented indicator dot and warm stone border.
class IsleStatusBadge extends StatelessWidget {
  const IsleStatusBadge({
    super.key,
    required this.label,
    this.color,
    this.dotColor,
    this.icon,
  });

  final String label;
  final Color? color;
  final Color? dotColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = color ?? colors.primary;
    final dot = dotColor ?? tint;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: IsleRadius.brPill,
        border: Border.all(
          color: tint.withValues(alpha: isDark ? 0.28 : 0.18),
          width: 0.85,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12.5, color: tint),
            const SizedBox(width: 4.5),
          ] else ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
            ),
            const SizedBox(width: 5.5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
                color: isDark
                    ? Color.lerp(tint, Colors.white, 0.35)
                    : Color.lerp(tint, const Color(0xff181715), 0.28),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
