import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';
import 'native_video_bridge.dart';

export 'isle_charts.dart';
export 'isle_controls.dart';
export 'isle_formatters.dart';
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
