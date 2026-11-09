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
      radius: IsleTokens.cardRadius,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.6,
                indent: 62,
                endIndent: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xff0f172a).withValues(alpha: 0.06),
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
      lead = Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: baseColor.withValues(alpha: isDark ? 0.35 : 0.24),
              blurRadius: 4,
              offset: const Offset(0, 1.5),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: (iconColor != null && iconColor != baseColor)
              ? iconColor!
              : Colors.white,
          size: 18.5,
        ),
      );
    }

    return ListTile(
      onTap: onTap,
      minTileHeight: subtitle != null ? 50 : 44,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: lead,
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 14,
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
                  color: colors.onSurfaceVariant.withValues(alpha: 0.5),
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
    final shapeRadius = size * 0.28;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = iconColor ?? (gradient != null ? Colors.white : color);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(shapeRadius),
        gradient: gradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient!,
              )
            : null,
        color: gradient == null
            ? color.withValues(alpha: isDark ? 0.20 : 0.12)
            : null,
        border: Border.all(
          color: (gradient != null ? Colors.white : color).withValues(
            alpha: gradient != null ? (isDark ? 0.28 : 0.38) : 0.16,
          ),
          width: 0.8,
        ),
        boxShadow: shadow && gradient != null
            ? [
                BoxShadow(
                  color: color.withValues(alpha: isDark ? 0.40 : 0.26),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette['cardItemTop'],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.09)
              : const Color(0xff0f172a).withValues(alpha: 0.06),
          width: 0.75,
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

/// Structured empty state card replacing generic info Notice banners when a list is empty.
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: accent,
                size: 44,
                iconSize: 22,
              ),
              const SizedBox(height: 12),
              if (title != null && title!.isNotEmpty) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 14),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
