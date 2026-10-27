import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';

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
  const Notice(this.message, {super.key, this.onRetry, this.error = false});
  final String message;
  final VoidCallback? onRetry;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Semantics(
        liveRegion: true,
        child: Container(
          decoration: BoxDecoration(
            color: error
                ? colors.errorContainer.withValues(alpha: 0.85)
                : colors.surfaceContainerHighest.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: error
                  ? colors.error.withValues(alpha: 0.35)
                  : colors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                error
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded,
                color: error ? colors.error : colors.primary,
                size: 20,
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
                        height: 1.5,
                      ),
                    ),
                    if (onRetry != null) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重试'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: const Size(40, 32),
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
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(
                      alpha: isDark ? 0.85 : 0.92,
                    ),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.16)
                          : colors.outlineVariant.withValues(alpha: 0.50),
                      width: 0.85,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.45 : 0.14,
                        ),
                        blurRadius: 32,
                        offset: const Offset(0, 12),
                      ),
                    ],
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

/// 3D Interactive Liquid Sanctuary Tile (Files, Photos, Cinema)
/// Replicates macOS LiquidSanctuaryTile with tactile radiant icon badge,
/// soft shadow aura, clean hierarchy, and subtle arrow.
class IsleSanctuaryTile extends StatelessWidget {
  const IsleSanctuaryTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradientColors,
    this.badgeText,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> gradientColors;
  final String? badgeText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (MediaQuery.sizeOf(context).width < 600) {
      return IsleSurface(
        padding: EdgeInsets.zero,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: Icon(icon, color: gradientColors.first, size: 28),
          title: Text(title, style: theme.textTheme.titleMedium),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      );
    }

    return IsleSurface(
      onTap: onTap,
      radius: 20,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Radiant colored gradient badge
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  gradient: LinearGradient(
                    colors: gradientColors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: gradientColors.first.withValues(
                        alpha: isDark ? 0.38 : 0.28,
                      ),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: isDark ? 0.35 : 0.5),
                    width: 0.75,
                  ),
                ),
                child: Center(child: Icon(icon, color: Colors.white, size: 22)),
              ),
              const Spacer(),
              if (badgeText != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(
                      alpha: isDark ? 0.2 : 0.1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    badgeText!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                ),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
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

/// iOS/macOS Grouped Inset Card for Settings and Clean List Groups
class IsleGroupCard extends StatelessWidget {
  const IsleGroupCard({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(vertical: 8),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return IsleSurface(
      margin: margin,
      padding: EdgeInsets.zero,
      radius: IsleTokens.cardRadius,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.75,
                indent: 58,
                endIndent: 16,
                color: Theme.of(context).colorScheme.outlineVariant
                    .withValues(alpha: 0.4),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A row inside IsleGroupCard with icon squircle badge, title, subtitle, and chevron.
class IsleGroupTile extends StatelessWidget {
  const IsleGroupTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.icon,
    this.iconBgColor,
    this.iconColor,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final IconData? icon;
  final Color? iconBgColor;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    Widget? lead = leading;
    if (lead == null && icon != null) {
      final bg = iconBgColor ?? colors.primaryContainer;
      final fg = iconColor ?? colors.primary;
      lead = Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: bg.withValues(alpha: isDark ? 0.35 : 0.22),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.25 : 0.45),
            width: 0.65,
          ),
        ),
        child: Icon(icon, color: fg, size: 20),
      );
    }

    return ListTile(
      onTap: onTap,
      minTileHeight: 52,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: lead,
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            )
          : null,
      trailing:
          trailing ??
          (onTap != null
              ? Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                )
              : null),
    );
  }
}

/// Liquid Glass Search Field for Finder & Media views
class IsleSearchField extends StatelessWidget {
  const IsleSearchField({
    super.key,
    required this.controller,
    this.hintText = '搜索…',
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh.withValues(
          alpha: isDark ? 0.65 : 0.75,
        ),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : colors.outlineVariant.withValues(alpha: 0.6),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 19, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.65),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                filled: false,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                onChanged?.call('');
                onClear?.call();
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.cancel_rounded,
                  size: 17,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum IsleButtonVariant { prominent, secondary, destructive, ghost }

enum IsleButtonSize { small, regular, large }

/// Unified Apple-grade Liquid Glass Button.
/// Radiates tactile gradients, specular rim highlight border, and soft layered shadows.
class IsleButton extends StatefulWidget {
  const IsleButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.variant = IsleButtonVariant.secondary,
    this.size = IsleButtonSize.regular,
    this.loading = false,
    this.tooltip,
    this.expanded = false,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final IsleButtonVariant variant;
  final IsleButtonSize size;
  final bool loading;
  final String? tooltip;
  final bool expanded;

  @override
  State<IsleButton> createState() => _IsleButtonState();
}

class _IsleButtonState extends State<IsleButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final isEnabled = widget.onPressed != null && !widget.loading;

    final double height = switch (widget.size) {
      IsleButtonSize.small => 32.0,
      IsleButtonSize.regular => 42.0,
      IsleButtonSize.large => 48.0,
    };
    final double hPadding = switch (widget.size) {
      IsleButtonSize.small => 10.0,
      IsleButtonSize.regular => 16.0,
      IsleButtonSize.large => 20.0,
    };
    final double fontSize = switch (widget.size) {
      IsleButtonSize.small => 12.0,
      IsleButtonSize.regular => 13.5,
      IsleButtonSize.large => 15.0,
    };
    final double iconSize = switch (widget.size) {
      IsleButtonSize.small => 15.0,
      IsleButtonSize.regular => 18.0,
      IsleButtonSize.large => 20.0,
    };
    final double radius = switch (widget.size) {
      IsleButtonSize.small => 8.5,
      IsleButtonSize.regular => 12.0,
      IsleButtonSize.large => 14.0,
    };

    final scale = isEnabled && !disableAnimations
        ? (_pressed ? 0.975 : (_hovered ? 1.012 : 1.0))
        : 1.0;
    final offsetY = isEnabled && !disableAnimations
        ? (_pressed ? 0.8 : (_hovered ? -1.0 : 0.0))
        : 0.0;

    Color textColor;
    Gradient? backgroundGradient;
    Color? backgroundColor;
    Border? border;
    List<BoxShadow>? shadows;

    switch (widget.variant) {
      case IsleButtonVariant.prominent:
        textColor = Colors.white;
        backgroundGradient = LinearGradient(
          colors: isDark
              ? (_hovered
                    ? [const Color(0xff60a5fa), const Color(0xff818cf8)]
                    : [const Color(0xff3b82f6), const Color(0xff6366f1)])
              : (_hovered
                    ? [const Color(0xff3b82f6), const Color(0xff6366f1)]
                    : [const Color(0xff2563eb), const Color(0xff4f46e5)]),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
        if (!highContrast) {
          border = Border.all(
            color: Colors.white.withValues(
              alpha: isDark
                  ? (_hovered ? 0.45 : 0.30)
                  : (_hovered ? 0.65 : 0.45),
            ),
            width: 0.85,
          );
          shadows = [
            BoxShadow(
              color:
                  (isDark ? const Color(0xff3b82f6) : const Color(0xff2563eb))
                      .withValues(
                        alpha: isEnabled ? (_hovered ? 0.38 : 0.24) : 0.0,
                      ),
              blurRadius: _hovered ? 14 : 9,
              offset: Offset(0, _pressed ? 1 : 3),
            ),
          ];
        }
        break;

      case IsleButtonVariant.secondary:
        textColor = colors.onSurface;
        final p = IslePalette.of(context);
        backgroundColor = _hovered
            ? p['cardHover'].withValues(alpha: isDark ? 0.90 : 0.96)
            : p['cardTop'].withValues(alpha: isDark ? 0.70 : 0.85);
        if (highContrast) {
          border = Border.all(color: colors.outline, width: 1.5);
        } else {
          border = Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: _hovered ? 0.28 : 0.14)
                : (_hovered
                      ? colors.primary.withValues(alpha: 0.5)
                      : p['rim'].withValues(alpha: 0.85)),
            width: 0.85,
          );
          shadows = [
            BoxShadow(
              color: p['shadow'].withValues(
                alpha: isDark
                    ? (_hovered ? 0.25 : 0.12)
                    : (_hovered ? 0.08 : 0.03),
              ),
              blurRadius: _hovered ? 10 : 6,
              offset: Offset(0, _pressed ? 1 : 2),
            ),
          ];
        }
        break;

      case IsleButtonVariant.destructive:
        textColor = isDark ? const Color(0xfff87171) : const Color(0xffdc2626);
        backgroundGradient = LinearGradient(
          colors: [
            const Color(0xffef4444).withValues(alpha: _hovered ? 0.22 : 0.12),
            const Color(0xffdc2626).withValues(alpha: _hovered ? 0.28 : 0.18),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
        border = Border.all(
          color: const Color(0xffef4444)
              .withValues(alpha: _hovered ? 0.50 : 0.30),
          width: 0.85,
        );
        shadows = [
          BoxShadow(
            color: const Color(0xffef4444)
                .withValues(alpha: _hovered ? 0.20 : 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ];
        break;

      case IsleButtonVariant.ghost:
        textColor = colors.primary;
        backgroundColor = _hovered
            ? colors.primary.withValues(alpha: 0.09)
            : Colors.transparent;
        break;
    }

    Widget content = Row(
      mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading) ...[
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(textColor),
            ),
          ),
          const SizedBox(width: 8),
        ] else if (widget.icon != null) ...[
          Icon(widget.icon, size: iconSize, color: textColor),
          const SizedBox(width: 7),
        ],
        Text(
          widget.label,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontWeight: widget.variant == IsleButtonVariant.prominent
                ? FontWeight.w700
                : FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );

    Widget button = AnimatedScale(
      scale: scale,
      duration: IsleMotion.quick,
      curve: IsleMotion.spring,
      child: AnimatedSlide(
        offset: Offset(0, offsetY == 0.0 ? 0.0 : (offsetY / 40.0)),
        duration: IsleMotion.quick,
        curve: IsleMotion.spring,
        child: AnimatedContainer(
          duration: IsleMotion.quick,
          curve: IsleMotion.spring,
          height: height,
          decoration: BoxDecoration(
            color: backgroundColor,
            gradient: backgroundGradient,
            borderRadius: BorderRadius.circular(radius),
            border: border,
            boxShadow: shadows,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: isEnabled
                  ? () {
                      HapticFeedback.selectionClick();
                      widget.onPressed?.call();
                    }
                  : null,
              onTapDown: isEnabled && !disableAnimations
                  ? (_) {
                      HapticFeedback.lightImpact();
                      setState(() => _pressed = true);
                    }
                  : null,
              onTapUp: isEnabled && !disableAnimations
                  ? (_) => setState(() => _pressed = false)
                  : null,
              onTapCancel: isEnabled && !disableAnimations
                  ? () => setState(() => _pressed = false)
                  : null,
              onHover: isEnabled && !disableAnimations
                  ? (h) => setState(() => _hovered = h)
                  : null,
              borderRadius: BorderRadius.circular(radius),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hPadding),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );

    if (!isEnabled) {
      button = Opacity(opacity: 0.45, child: button);
    }
    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return widget.expanded
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }
}

/// Squircle icon badge for navigation, categories, and settings.
/// Replicates Apple continuous rounded rectangle with radiant ambient background.
class IsleSquircleBadge extends StatelessWidget {
  const IsleSquircleBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 32,
    this.iconSize = 18,
    this.iconColor = Colors.white,
    this.gradient,
    this.shadow = true,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final Color iconColor;
  final List<Color>? gradient;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColors = gradient ?? [color, color.withValues(alpha: 0.82)];
    final shapeRadius = size * 0.28;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(shapeRadius),
        gradient: LinearGradient(
          colors: bgColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: shadow && !MediaQuery.highContrastOf(context)
            ? [
                BoxShadow(
                  color: bgColors.first.withValues(alpha: isDark ? 0.38 : 0.26),
                  blurRadius: size * 0.25,
                  offset: Offset(0, size * 0.08),
                ),
              ]
            : null,
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.35 : 0.50),
          width: 0.75,
        ),
      ),
      child: Center(
        child: Icon(icon, color: iconColor, size: iconSize),
      ),
    );
  }
}

/// The 5 core sections matching Web and macOS visual language.
enum IsleSectionTheme {
  overview(
    label: '概览',
    icon: Icons.space_dashboard_rounded,
    color: Color(0xff0071e3),
    gradient: [Color(0xff2589ff), Color(0xff0066cc)],
  ),
  files(
    label: '文件',
    icon: Icons.folder_rounded,
    color: Color(0xff0ea5e9),
    gradient: [Color(0xff38bdf8), Color(0xff0284c7)],
  ),
  photos(
    label: '图库',
    icon: Icons.photo_library_rounded,
    color: Color(0xffec4899),
    gradient: [Color(0xfff472b6), Color(0xffdb2777)],
  ),
  cinema(
    label: '影视',
    icon: Icons.movie_rounded,
    color: Color(0xfff97316),
    gradient: [Color(0xfffb923c), Color(0xffea580c)],
  ),
  settings(
    label: '设置',
    icon: Icons.settings_rounded,
    color: Color(0xff8b5cf6),
    gradient: [Color(0xffa78bfa), Color(0xff7c3aed)],
  );

  const IsleSectionTheme({
    required this.label,
    required this.icon,
    required this.color,
    required this.gradient,
  });

  final String label;
  final IconData icon;
  final Color color;
  final List<Color> gradient;
}

/// Bento Vitality Gauge card matching macOS LiquidHealthGauge and Web Bento.
class IsleBentoStatCard extends StatelessWidget {
  const IsleBentoStatCard({
    super.key,
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
    this.gradient,
    this.progress,
    this.onTap,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;
  final List<Color>? gradient;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;

    return IsleSurface(
      onTap: onTap,
      radius: IsleTokens.itemRadius + 2,
      padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: color,
                gradient: gradient,
                size: 32,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (progress != null)
                Container(
                  width: 6.5,
                  height: 6.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: isDark ? 0.6 : 0.4),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant.withValues(alpha: 0.85),
              height: 1.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                children: [
                  Container(
                    height: 5.5,
                    color: colors.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0.0,
                      end: progress!.clamp(0.0, 1.0),
                    ),
                    duration: const Duration(milliseconds: 650),
                    curve: Curves.easeOutCubic,
                    builder: (context, animatedProgress, _) =>
                        FractionallySizedBox(
                          widthFactor: animatedProgress,
                          child: Container(
                            height: 5.5,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              gradient: LinearGradient(
                                colors:
                                    gradient ??
                                    [color, color.withValues(alpha: 0.75)],
                              ),
                            ),
                          ),
                        ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Clean Inset Section Header for Grouped Lists and Settings.
class IsleSectionHeader extends StatelessWidget {
  const IsleSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(4, 16, 4, 8),
  });

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Living, breathing status heartbeat dot.
/// In production, radiates a continuous, rhythmic glowing pulse.
/// In automated tests, remains stable without infinite timers.
class IslePulsingStatusDot extends StatefulWidget {
  const IslePulsingStatusDot({
    super.key,
    this.color = const Color(0xff10b981),
    this.size = 7.0,
  });

  final Color color;
  final double size;

  @override
  State<IslePulsingStatusDot> createState() => _IslePulsingStatusDotState();
}

class _IslePulsingStatusDotState extends State<IslePulsingStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    final isTest = WidgetsBinding.instance.runtimeType.toString().contains(
      'Test',
    );
    if (!isTest) {
      _controller.repeat(reverse: true);
    } else {
      _controller.value = 0.5;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25 + 0.45 * t),
                blurRadius: 3.0 + 5.0 * t,
                spreadRadius: 0.5 + 1.5 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Fluid staggered entrance wrapper with smooth opacity and slide reveal.
class IsleAnimatedEntrance extends StatefulWidget {
  const IsleAnimatedEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 18),
  });

  final Widget child;
  final Duration delay;
  final Offset offset;

  @override
  State<IsleAnimatedEntrance> createState() => _IsleAnimatedEntranceState();
}

class _IsleAnimatedEntranceState extends State<IsleAnimatedEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: IsleMotion.reveal);
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.85, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: widget.offset,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: IsleMotion.spring));

    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Transform.translate(offset: _slideAnimation.value, child: child),
      ),
      child: widget.child,
    );
  }
}

/// Fluid, continuous tab switcher that blends smooth cross-fades and subtle spring scale
/// while preserving the full state of all child views.
class IsleFluidTabSwitcher extends StatefulWidget {
  const IsleFluidTabSwitcher({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 260),
  });

  final int index;
  final List<Widget> children;
  final Duration duration;

  @override
  State<IsleFluidTabSwitcher> createState() => _IsleFluidTabSwitcherState();
}

class _IsleFluidTabSwitcherState extends State<IsleFluidTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late int _currentIndex;
  int? _previousIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.index;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(IsleFluidTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != _currentIndex) {
      _previousIndex = _currentIndex;
      _currentIndex = widget.index;
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      return IndexedStack(index: _currentIndex, children: widget.children);
    }

    final curved = CurvedAnimation(
      parent: _controller,
      curve: IsleMotion.spring,
    );

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: List.generate(widget.children.length, (i) {
          final isCurrent = i == _currentIndex;
          final isPrevious = i == _previousIndex;

          if (!isCurrent && !isPrevious) {
            return Offstage(
              offstage: true,
              child: TickerMode(enabled: false, child: widget.children[i]),
            );
          }

          if (isCurrent) {
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.985, end: 1.0).animate(curved),
                child: TickerMode(enabled: true, child: widget.children[i]),
              ),
            );
          }

          // isPrevious
          return FadeTransition(
            opacity: Tween<double>(begin: 1.0, end: 0.0).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 1.0, end: 0.985).animate(curved),
              child: TickerMode(enabled: false, child: widget.children[i]),
            ),
          );
        }),
      ),
    );
  }
}
