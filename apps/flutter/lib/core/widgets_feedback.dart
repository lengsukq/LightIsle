part of 'widgets.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IsleSurface(
      margin: margin,
      padding: EdgeInsets.zero,
      radius: IsleRadius.card,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                indent: 58,
                endIndent: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xff0f172a).withValues(alpha: 0.055),
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
      radius: IsleRadius.item,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          shape: IsleShapes.item(),
          collapsedShape: IsleShapes.item(),
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
      final toneColor = (iconColor != null && iconColor != Colors.white)
          ? iconColor!
          : baseColor;
      lead = Container(
        width: 34,
        height: 34,
        decoration: ShapeDecoration(
          color: toneColor.withValues(alpha: isDark ? 0.14 : 0.085),
          shape: IsleShapes.squircle(
            10,
            side: BorderSide(
              color: toneColor.withValues(alpha: isDark ? 0.22 : 0.12),
              width: 0.75,
            ),
          ),
        ),
        child: Icon(icon, color: toneColor, size: 18),
      );
    }

    return ListTile(
      onTap: onTap,
      minTileHeight: subtitle != null ? 52 : 46,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      leading: lead,
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 14.5,
          letterSpacing: -0.15,
        ),
      ),
      subtitle: subtitle != null
          ? Padding(
              padding: const EdgeInsets.only(top: 1.5),
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            )
          : null,
      trailing:
          trailing ??
          (onTap != null
              ? Icon(
                  Icons.chevron_right_rounded,
                  size: 19,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.45),
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
    this.size = 34,
    this.iconSize = 18,
    this.iconColor,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final shapeRadius = size * 0.30;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = (iconColor != null && iconColor != Colors.white)
        ? iconColor!
        : color;

    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        shape: IsleShapes.squircle(
          shapeRadius,
          side: BorderSide(
            color: color.withValues(alpha: isDark ? 0.22 : 0.13),
            width: 0.75,
          ),
        ),
        color: color.withValues(alpha: isDark ? 0.14 : 0.085),
      ),
      child: Center(
        child: Icon(icon, color: fg, size: iconSize),
      ),
    );
  }
}

/// Monospace code / path capsule for file paths, endpoints, and CLI snippets.
class IsleCodePill extends StatelessWidget {
  const IsleCodePill(
    this.text, {
    super.key,
    this.icon,
    this.selectable = false,
  });

  final String text;
  final IconData? icon;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontSize: 12,
      color: colors.onSurfaceVariant,
      height: 1.35,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: ShapeDecoration(
        color: palette['cardItemTop'],
        shape: IsleShapes.sm(
          side: BorderSide(
            color: IsleGlass.rimBorderColor(isDark),
            width: 0.75,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: colors.onSurfaceVariant),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: selectable
                ? SelectableText(text, style: style)
                : Text(text, style: style),
          ),
        ],
      ),
    );
  }
}

/// Top summary / toolbar card for secondary pages with an icon badge,
/// explanatory text, optional path/code capsule, and action buttons.
class IsleIntroCard extends StatelessWidget {
  const IsleIntroCard({
    super.key,
    required this.icon,
    required this.description,
    this.title,
    this.color,
    this.codePill,
    this.actions = const [],
    this.margin = const EdgeInsets.only(bottom: 12),
  });

  final IconData icon;
  final String? title;
  final String description;
  final Color? color;
  final String? codePill;
  final List<Widget> actions;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = color ?? colors.primary;

    return IsleSurface(
      margin: margin,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: accent,
                size: 38,
                iconSize: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null && title!.isNotEmpty) ...[
                      Text(
                        title!,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                    ],
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        height: 1.45,
                        color: title != null
                            ? colors.onSurfaceVariant
                            : colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (codePill != null && codePill!.isNotEmpty) ...[
            const SizedBox(height: 10),
            IsleCodePill(codePill!, icon: Icons.folder_open_rounded),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// Beginner-friendly onboarding & empty state card with squircle icon badge,
/// plain-language guidance, and direct call-to-action buttons.
class IsleEmptyStateCard extends StatelessWidget {
  const IsleEmptyStateCard(
    this.message, {
    super.key,
    this.title,
    this.icon = Icons.inbox_rounded,
    this.color,
    this.action,
    this.margin = const EdgeInsets.symmetric(vertical: 8),
  });

  final String message;
  final String? title;
  final IconData icon;
  final Color? color;
  final Widget? action;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = color ?? colors.primary;

    return IsleSurface(
      margin: margin,
      radius: IsleRadius.card,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: accent,
                size: 48,
                iconSize: 24,
              ),
              const SizedBox(height: 14),
              if (title != null && title!.isNotEmpty) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 15.5,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 5),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}
