import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';

export 'isle_controls.dart';
export 'isle_style.dart';

part 'widgets_sections.dart';
part 'widgets_navigation.dart';
part 'widgets_feedback.dart';

enum IsleGlassVariant { regular, clear }

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

  @override
  Widget build(BuildContext context) => IsleLayout.opaqueNavigation(context)
      ? child
      : ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: child,
          ),
        );
}

/// Unified Liquid Glass floating surface for navigation bars, modals, and HUDs.
class IsleGlassSurface extends StatelessWidget {
  const IsleGlassSurface({
    super.key,
    required this.child,
    this.radius = IsleRadius.hero,
    this.padding = EdgeInsets.zero,
    this.variant = IsleGlassVariant.regular,
    this.elevated = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final IsleGlassVariant variant;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isOpaque = IsleLayout.opaqueNavigation(context);
    final isClear = variant == IsleGlassVariant.clear;
    final shape = IsleShapes.squircle(
      radius,
      side: BorderSide(
        color: IsleGlass.rimBorderColor(isDark, isGlass: true),
        width: 0.9,
      ),
    );
    final innerShape = IsleShapes.squircle(radius);

    final body = Container(
      padding: padding,
      decoration: ShapeDecoration(
        shape: shape,
        color: isOpaque
            ? colors.surface
            : isClear
            ? IsleGlass.clearTint(isDark)
            : IsleGlass.regularTint(isDark, colors.surface),
        shadows: elevated && !isOpaque ? IsleShadows.floating(isDark) : null,
      ),
      child: child,
    );

    if (isOpaque) return body;

    return ClipPath(
      clipper: ShapeBorderClipper(shape: innerShape),
      child: BackdropFilter(
        filter: isClear ? IsleGlass.filterClear : IsleGlass.filterRegular,
        child: body,
      ),
    );
  }
}

/// Keep the essential fact visible on narrow / large-text screens while
/// allowing users to read the complete explanatory guidance on demand.
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
      margin: const EdgeInsets.symmetric(vertical: 8),
      radius: IsleRadius.item,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading: Container(
            width: 30,
            height: 30,
            decoration: IsleDecorations.iconBadge(
              scheme.onSurfaceVariant.withValues(alpha: isDark ? 0.16 : 0.09),
              radius: IsleRadius.xs,
            ),
            child: Icon(
              Icons.help_outline_rounded,
              color: scheme.onSurfaceVariant,
              size: 16,
            ),
          ),
          title: Text(
            summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: scheme.onSurface.withValues(alpha: 0.88),
            ),
          ),
          subtitle: Text(
            '查看说明',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
              fontSize: 11.5,
            ),
          ),
          children: [
            Divider(
              height: 1,
              thickness: 0.5,
              indent: 14,
              endIndent: 14,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xff0f172a).withValues(alpha: 0.06),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  details,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
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

/// Compact counterpart of the native Mac overview's full-width device card.
class IsleDeviceHero extends StatelessWidget {
  const IsleDeviceHero({
    super.key,
    required this.title,
    required this.detail,
    required this.status,
    this.statusColor,
  });

  final String title;
  final String detail;
  final String status;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scheme = Theme.of(context).colorScheme;
      final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final statusChip = IsleStatusBadge(
        label: status,
        color: statusColor ?? scheme.onSurfaceVariant,
      );
      return IsleSurface(
        glass: true,
        radius: IsleRadius.card,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 18,
          vertical: compact ? 12 : 15,
        ),
        child: Row(
          children: [
            IsleSquircleBadge(
              icon: Icons.desktop_mac_rounded,
              color: scheme.primary,
              size: compact ? 40 : 44,
              iconSize: compact ? 20 : 22,
            ),
            SizedBox(width: compact ? 12 : 14),
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
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.25,
                              ),
                        ),
                      ),
                      if (compact && !largeText) ...[
                        const SizedBox(width: 8),
                        statusChip,
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: largeText ? 3 : (compact ? 1 : 2),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
    this.error = false,
    this.diagnostic,
    this.icon,
    this.trailing,
  });
  final String message;
  final VoidCallback? onRetry;
  final bool error;
  final String? diagnostic;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = error ? colors.error : colors.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        liveRegion: true,
        child: IsleSurface(
          radius: IsleRadius.item,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          tint: error
              ? colors.errorContainer.withValues(alpha: isDark ? 0.38 : 0.55)
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: IsleDecorations.iconBadge(
                  accentColor.withValues(alpha: isDark ? 0.20 : 0.12),
                  radius: IsleRadius.xs,
                ),
                child: Center(
                  child: Icon(
                    icon ??
                        (error
                            ? Icons.error_outline_rounded
                            : Icons.info_outline_rounded),
                    color: accentColor,
                    size: 17,
                  ),
                ),
              ),
              const SizedBox(width: 12),
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
                        height: 1.45,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (diagnostic != null) ...[
                      const SizedBox(height: 5),
                      SelectableText(
                        diagnostic!,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                    if (onRetry != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('重试'),
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

typedef IsleBanner = Notice;

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
  return await showDialog<bool>(
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
              constraints: const BoxConstraints(maxWidth: 420),
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
                          width: 36,
                          height: 36,
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
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
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
                    const SizedBox(height: 14),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 22),
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
                        const SizedBox(width: 10),
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

/// Refined Apple-style status badge with glowing micro dot and tracked label.
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xff0f172a).withValues(alpha: 0.045),
        borderRadius: IsleRadius.brPill,
        border: Border.all(
          color: IsleGlass.rimBorderColor(isDark),
          width: 0.75,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: tint),
            const SizedBox(width: 5),
          ] else ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dot,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              color: colors.onSurface.withValues(alpha: 0.82),
            ),
          ),
        ],
      ),
    );
  }
}
