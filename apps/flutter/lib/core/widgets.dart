import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';

/// A single guarded material treatment for dialogs and floating docks.
/// High-contrast and reduced-animation modes get an opaque, unblurred surface.
class _IsleGlassBackdrop extends StatelessWidget {
  const _IsleGlassBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => IsleLayout.opaqueNavigation(context)
      ? child
      : BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: child,
        );
}

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
    return IsleSurface(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.symmetric(vertical: 8),
      radius: IsleTokens.itemRadius,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(Icons.info_outline_rounded, color: scheme.primary),
          title: Text(summary, style: Theme.of(context).textTheme.bodyMedium),
          subtitle: Text(
            '查看说明',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  details,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
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
      final palette = IslePalette.of(context);
      final compact =
          constraints.maxWidth < 450 ||
          MediaQuery.textScalerOf(context).scale(14) > 19;
      final statusChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.circle,
              size: 8,
              color: statusColor ?? scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(status, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      );
      return IsleSurface(
        radius: IsleTokens.heroRadius,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 20,
          vertical: compact ? 14 : 20,
        ),
        child: Row(
          children: [
            Container(
              height: compact ? 42 : 54,
              width: compact ? 42 : 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette['brandBlue'].withValues(alpha: .12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.desktop_mac_rounded,
                size: compact ? 23 : 28,
                color: palette['brandBlue'],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (compact) ...[
                    const SizedBox(height: 7),
                    Align(alignment: Alignment.centerLeft, child: statusChip),
                  ],
                ],
              ),
            ),
            if (!compact) ...[const SizedBox(width: 12), statusChip],
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

/// Inset Grouped style disclosure card (replaces unstyled ExpansionTile)
class IsleDisclosureCard extends StatelessWidget {
  const IsleDisclosureCard({
    super.key,
    required this.title,
    required this.children,
    this.leading,
    this.initiallyExpanded = false,
    this.margin = const EdgeInsets.only(bottom: 12),
  });

  final Widget title;
  final List<Widget> children;
  final Widget? leading;
  final bool initiallyExpanded;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return IsleSurface(
      margin: margin,
      padding: EdgeInsets.zero,
      radius: 16,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          collapsedShape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: leading,
          title: title,
          children: children,
        ),
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
      final baseColor = iconBgColor ?? colors.primary;
      final bg = baseColor.withValues(alpha: isDark ? 0.22 : 0.12);
      final fg = (iconColor != null && iconColor != Colors.white)
          ? iconColor!
          : baseColor;
      lead = Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: fg, size: 18),
      );
    }

    return ListTile(
      onTap: onTap,
      minTileHeight: 52,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: lead,
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
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

/// Squircle icon badge for navigation, categories, and settings.
/// Replicates Apple continuous rounded rectangle with radiant ambient background.
class IsleSquircleBadge extends StatelessWidget {
  const IsleSquircleBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 32,
    this.iconSize = 18,
    this.iconColor,
    this.gradient,
    this.shadow = false,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final Color? iconColor;
  final List<Color>? gradient;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final shapeRadius = size * 0.26;
    final fg = iconColor ?? color;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(shapeRadius),
        color: color.withValues(alpha: 0.12),
      ),
      child: Center(
        child: Icon(icon, color: fg, size: iconSize),
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
    final colors = theme.colorScheme;

    return IsleSurface(
      onTap: onTap,
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: color,
                size: 28,
                iconSize: 16,
              ),
              const SizedBox(width: 8),
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
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant.withValues(alpha: 0.85),
              fontSize: 12,
              height: 1.25,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                children: [
                  Container(
                    height: 4,
                    color: colors.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0.0,
                      end: progress!.clamp(0.0, 1.0),
                    ),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    builder: (context, animatedProgress, _) =>
                        FractionallySizedBox(
                          widthFactor: animatedProgress,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: color,
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
    this.padding = const EdgeInsets.fromLTRB(4, 20, 4, 8),
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
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          ?action,
        ],
      ),
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

          final direction =
              (_previousIndex == null || _currentIndex >= _previousIndex!)
              ? 1.0
              : -1.0;

          if (isCurrent) {
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(0.035 * direction, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.99, end: 1.0).animate(curved),
                  child: TickerMode(enabled: true, child: widget.children[i]),
                ),
              ),
            );
          }

          // isPrevious
          return FadeTransition(
            opacity: Tween<double>(begin: 1.0, end: 0.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset.zero,
                end: Offset(-0.035 * direction, 0),
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(begin: 1.0, end: 0.99).animate(curved),
                child: TickerMode(enabled: false, child: widget.children[i]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Floating vertical dock container for desktop/tablet NavigationRail
class IsleFloatingRailDock extends StatelessWidget {
  const IsleFloatingRailDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 12, bottom: 16, right: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: _IsleGlassBackdrop(
          child: IntrinsicHeight(
            child: Container(
              decoration: BoxDecoration(
                color: palette['cardTop'].withValues(
                  alpha: IsleLayout.opaqueNavigation(context)
                      ? 1
                      : isDark
                      ? 0.78
                      : 0.86,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: borderColor),
                boxShadow: IsleShadows.floating(isDark),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating horizontal pill dock container for mobile NavigationBar
class IsleFloatingBottomNavDock extends StatelessWidget {
  const IsleFloatingBottomNavDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.08);

    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: _IsleGlassBackdrop(
            child: Container(
              decoration: BoxDecoration(
                color: palette['cardTop'].withValues(
                  alpha: IsleLayout.opaqueNavigation(context)
                      ? 1
                      : isDark
                      ? 0.80
                      : 0.88,
                ),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: borderColor),
                boxShadow: IsleShadows.floating(isDark),
              ),
              child: child,
            ),
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

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: _IsleGlassBackdrop(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: IsleLayout.opaqueNavigation(context)
                      ? colors.surface
                      : isDark
                      ? const Color(0xff1e2027).withValues(alpha: 0.88)
                      : Colors.white.withValues(alpha: 0.90),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: colors.primary.withValues(
                      alpha: isDark ? 0.35 : 0.25,
                    ),
                  ),
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

/// Status and severity badge pill with macOS aesthetic
class IsleBadgePill extends StatelessWidget {
  const IsleBadgePill({super.key, required this.label, this.color, this.icon});

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: effectiveColor.withValues(alpha: 0.28)),
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
