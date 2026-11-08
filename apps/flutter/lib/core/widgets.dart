import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';

part 'widgets_sections.dart';
part 'widgets_navigation.dart';
part 'widgets_feedback.dart';

/// A single guarded material treatment for dialogs and floating docks.
/// High-contrast and reduced-animation modes get an opaque, unblurred surface.
class IsleGlassBackdrop extends StatelessWidget {
  const IsleGlassBackdrop({super.key, required this.child, this.blur = 28});

  final Widget child;
  final double blur;

  @override
  Widget build(BuildContext context) => IsleLayout.opaqueNavigation(context)
      ? child
      : ClipRect(
          // Without a clip, BackdropFilter samples the entire nearest
          // ancestor clip (often the whole screen), blurring content behind
          // a small floating control such as a gallery navigation button.
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: child,
          ),
        );
}

typedef _IsleGlassBackdrop = IsleGlassBackdrop;

/// Keep the essential fact visible on narrow / large-text screens while
/// allowing users to read the complete explanatory guidance on demand.
/// Errors and destructive confirmations must remain fully visible instead.
/// Collapsed on every width so a page never opens with a wall of help text.
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
    return IsleSurface(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.symmetric(vertical: 8),
      radius: IsleTokens.itemRadius,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          leading: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: isDark ? 0.22 : 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.info_outline_rounded,
              color: scheme.primary,
              size: 17,
            ),
          ),
          title: Text(
            summary,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5),
          ),
          subtitle: Text(
            '查看说明',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
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
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final palette = IslePalette.of(context);
      final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final statusChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
        decoration: BoxDecoration(
          color: (statusColor ?? scheme.onSurfaceVariant).withValues(
            alpha: isDark ? 0.18 : 0.10,
          ),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: (statusColor ?? scheme.onSurfaceVariant).withValues(
              alpha: isDark ? 0.35 : 0.22,
            ),
            width: 0.75,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6.5,
              height: 6.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor ?? scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              status,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: statusColor ?? scheme.onSurface,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      );
      return IsleSurface(
        glass: true,
        radius: IsleTokens.heroRadius,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 20,
          vertical: compact ? 11 : 16,
        ),
        child: Row(
          children: [
            Container(
              height: compact ? 38 : 48,
              width: compact ? 38 : 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    palette['brandBlue'].withValues(
                      alpha: isDark ? 0.28 : 0.16,
                    ),
                    palette['brandIndigo'].withValues(
                      alpha: isDark ? 0.18 : 0.08,
                    ),
                  ],
                ),
                borderRadius: BorderRadius.circular(compact ? 12 : 16),
                border: Border.all(
                  color: palette['brandBlue'].withValues(
                    alpha: isDark ? 0.35 : 0.20,
                  ),
                  width: 0.8,
                ),
              ),
              child: Icon(
                Icons.desktop_mac_rounded,
                size: compact ? 20 : 26,
                color: palette['brandBlue'],
              ),
            ),
            SizedBox(width: compact ? 12 : 15),
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
                                letterSpacing: -0.2,
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
                      height: 1.3,
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

class Notice extends StatelessWidget {
  const Notice(
    this.message, {
    super.key,
    this.onRetry,
    this.error = false,
    this.diagnostic,
  });
  final String message;
  final VoidCallback? onRetry;
  final bool error;
  final String? diagnostic;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = error ? colors.error : colors.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Semantics(
        liveRegion: true,
        child: Container(
          decoration: BoxDecoration(
            color: error
                ? colors.errorContainer.withValues(alpha: isDark ? 0.35 : 0.45)
                : (isDark
                      ? const Color(0xff1e2332).withValues(alpha: 0.70)
                      : Colors.white),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: error
                  ? colors.error.withValues(alpha: 0.30)
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.10)
                        : const Color(0xff0f172a).withValues(alpha: 0.075)),
              width: 0.8,
            ),
            boxShadow: isDark
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x060f172a),
                      blurRadius: 6,
                      offset: Offset(0, 1.5),
                    ),
                  ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: isDark ? 0.20 : 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Icon(
                    error
                        ? Icons.error_outline_rounded
                        : Icons.info_outline_rounded,
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
                        fontWeight: FontWeight.w400,
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
  return await showDialog<bool>(
        context: context,
        builder: (context) {
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final isDark = theme.brightness == Brightness.dark;
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 32,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: _IsleGlassBackdrop(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(
                      alpha: IsleLayout.opaqueNavigation(context)
                          ? 1
                          : isDark
                          ? 0.85
                          : 0.92,
                    ),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.16)
                          : colors.outlineVariant.withValues(alpha: 0.50),
                      width: 0.85,
                    ),
                    boxShadow: IsleShadows.floating(isDark),
                  ),
                  padding: const EdgeInsets.all(24),
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
    final tint = color ?? theme.colorScheme.primary;
    final dot = dotColor ?? tint;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: isDark ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: tint.withValues(alpha: isDark ? 0.30 : 0.22),
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
              width: 6.5,
              height: 6.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dot,
                boxShadow: [
                  BoxShadow(color: dot.withValues(alpha: 0.5), blurRadius: 4),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }
}

