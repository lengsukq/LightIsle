part of 'widgets.dart';

/// Grouped Inset Card for Settings and Clean List Groups with warm stone dividers.
class IsleGroupCard extends StatelessWidget {
  const IsleGroupCard({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(vertical: 6),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
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
                thickness: isBrutal ? 1.4 : 0.65,
                indent: isBrutal ? 0 : 54,
                endIndent: isBrutal ? 0 : 14,
                color: style.rimBorderColor(),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Structured Q&A or topic item displayed inside [showIsleHelpDialog].
class IsleHelpItem {
  const IsleHelpItem({required this.title, required this.body});

  final String title;
  final String body;
}

/// Shows a calm Warm Editorial Gallery help modal dialog for page-level or
/// item-level `?` help triggers, replacing noisy inline accordions.
Future<void> showIsleHelpDialog(
  BuildContext context, {
  required String title,
  String? body,
  List<IsleHelpItem> items = const [],
  IconData icon = Icons.help_outline_rounded,
  Color? accentColor,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final palette = IslePalette(isDark);
  final accent = accentColor ?? palette['brandBlue'];

  return showIsleDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      title: Row(
        children: [
          IsleSquircleBadge(
            icon: icon,
            color: accent,
            size: 32,
            iconSize: 16.5,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (body != null && body.trim().isNotEmpty)
                Text(
                  body.trim(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              if (body != null && body.trim().isNotEmpty && items.isNotEmpty)
                const SizedBox(height: 12),
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                Text(
                  items[i].title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  items[i].body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12.5,
                    color: colors.onSurfaceVariant,
                    height: 1.46,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton.tonal(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// Subtle `?` icon button used either in [IsleAppBar.actions] (`compact: false`)
/// or inline beside a section/item title (`IsleHelpButton.compact`).
class IsleHelpButton extends StatelessWidget {
  const IsleHelpButton({
    super.key,
    required this.title,
    this.body,
    this.items = const [],
    this.tooltip,
    this.icon = Icons.help_outline_rounded,
    this.accentColor,
    this.compact = false,
  });

  const IsleHelpButton.compact({
    super.key,
    required this.title,
    this.body,
    this.items = const [],
    this.tooltip,
    this.icon = Icons.help_outline_rounded,
    this.accentColor,
  }) : compact = true;

  final String title;
  final String? body;
  final List<IsleHelpItem> items;
  final String? tooltip;
  final IconData icon;
  final Color? accentColor;
  final bool compact;

  void _open(BuildContext context) {
    showIsleHelpDialog(
      context,
      title: title,
      body: body,
      items: items,
      icon: icon,
      accentColor: accentColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (compact) {
      return IconButton(
        tooltip: tooltip ?? '$title说明',
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(3),
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => _open(context),
        icon: Icon(
          icon,
          size: 15.5,
          color: colors.onSurfaceVariant.withValues(alpha: 0.72),
        ),
      );
    }
    return IconButton(
      tooltip: tooltip ?? title,
      onPressed: () => _open(context),
      icon: Icon(icon, size: 20),
    );
  }
}

/// Inset Grouped style disclosure card.
class IsleDisclosureCard extends StatelessWidget {
  const IsleDisclosureCard({
    super.key,
    required this.title,
    required this.children,
    this.leading,
    this.initiallyExpanded = false,
    this.margin = const EdgeInsets.only(bottom: 10),
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
          dense: true,
          visualDensity: VisualDensity.compact,
          initiallyExpanded: initiallyExpanded,
          shape: IsleShapes.item(),
          collapsedShape: IsleShapes.item(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading: leading,
          title: title,
          children: children,
        ),
      ),
    );
  }
}

/// A row inside [IsleGroupCard] with curated semantic pigment squircle badge.
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
      lead = IsleSquircleBadge(
        icon: icon!,
        color: toneColor,
        size: 32,
        iconSize: 17,
      );
    }

    final hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;
    return ListTile(
      onTap: onTap,
      minTileHeight: hasSubtitle ? 52 : 46,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: lead,
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          letterSpacing: -0.15,
        ),
      ),
      subtitle: hasSubtitle
          ? Padding(
              padding: const EdgeInsets.only(top: 1.5),
              child: Text(
                subtitle!.trim(),
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
                  size: 18,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.5),
                )
              : null),
    );
  }
}

/// Tactile Squircle icon badge with soft two-stop pigment wash.
class IsleSquircleBadge extends StatelessWidget {
  const IsleSquircleBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 32,
    this.iconSize = 17,
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
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final isFlat = style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline;
    final fg = (iconColor != null && iconColor != Colors.white)
        ? iconColor!
        : color;

    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        shape: style.shapeFor(
          shapeRadius,
          side: BorderSide(
            color: isBrutal
                ? style.rimBorderColor()
                : color.withValues(alpha: isDark ? 0.34 : 0.22),
            width: isBrutal ? 1.5 : 0.85,
          ),
        ),
        color: isBrutal || isFlat
            ? color.withValues(alpha: isDark ? 0.24 : 0.14)
            : null,
        gradient: isBrutal || isFlat
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.withValues(alpha: isDark ? 0.22 : 0.14),
                  color.withValues(alpha: isDark ? 0.11 : 0.06),
                ],
              ),
      ),
      child: Center(
        child: Icon(icon, color: fg, size: iconSize),
      ),
    );
  }
}

/// Monospace code / path capsule set on recessed warm stone paper.
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
      fontSize: 11.5,
      color: colors.onSurfaceVariant,
      height: 1.32,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
      decoration: ShapeDecoration(
        color: palette['cardItemBottom'],
        shape: IsleShapes.sm(
          side: BorderSide(
            color: IsleGlass.rimBorderColor(isDark),
            width: 0.85,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13.5, color: colors.onSurfaceVariant),
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

/// Editorial hero intro card for secondary pages: establishes an immediate
/// visual focal anchor with subtle pigment tinting and clean inline CTAs.
class IsleIntroCard extends StatelessWidget {
  const IsleIntroCard({
    super.key,
    required this.icon,
    this.description = '',
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
    final palette = IslePalette.of(context);
    final accent = color ?? palette['brandAmber'];
    final trimmedDesc = description.trim();
    final hasTitle = title != null && title!.trim().isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final inlineActions =
            actions.isNotEmpty &&
            codePill == null &&
            constraints.maxWidth >= 600 &&
            textScale <= 1.25;

        final infoRow = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IsleSquircleBadge(
              icon: icon,
              color: accent,
              size: 36,
              iconSize: 18.5,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasTitle)
                    Text(
                      title!.trim(),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        letterSpacing: -0.2,
                      ),
                    ),
                  if (trimmedDesc.isNotEmpty) ...[
                    if (hasTitle) const SizedBox(height: 2),
                    Text(
                      trimmedDesc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12.5,
                        height: 1.4,
                        color: hasTitle
                            ? colors.onSurfaceVariant
                            : colors.onSurface,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (inlineActions) ...[
              const SizedBox(width: 14),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ],
          ],
        );

        return IsleSurface(
          margin: margin,
          tint: accent,
          radius: IsleRadius.hero,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              infoRow,
              if (codePill != null && codePill!.isNotEmpty) ...[
                const SizedBox(height: 8),
                IsleCodePill(codePill!, icon: Icons.folder_open_rounded),
              ],
              if (actions.isNotEmpty && !inlineActions) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Calm gallery empty state card with centered warm emblem.
class IsleEmptyStateCard extends StatelessWidget {
  const IsleEmptyStateCard(
    this.message, {
    super.key,
    this.title,
    this.icon = Icons.inbox_rounded,
    this.color,
    this.action,
    this.margin = const EdgeInsets.symmetric(vertical: 6),
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
    final palette = IslePalette.of(context);
    final accent = color ?? palette['brandAmber'];

    return IsleSurface(
      margin: margin,
      radius: IsleRadius.card,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 22),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: accent,
                size: 46,
                iconSize: 22,
              ),
              const SizedBox(height: 12),
              if (title != null && title!.isNotEmpty) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 12.5,
                  height: 1.48,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 14), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact two-column metadata row used in quick inspector cards.
class IsleKeyValueRow extends StatelessWidget {
  const IsleKeyValueRow({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
