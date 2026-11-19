import 'package:flutter/material.dart';

import 'isle_theme.dart';

/// Descriptor for a single contextual quick-jump destination pill.
class IsleQuickJumpItem {
  const IsleQuickJumpItem({
    this.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.accent,
  });

  final Key? key;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final Color? accent;
}

/// Tactile warm-paper quick-jump strip connecting related workflows.
class IsleQuickJumpStrip extends StatelessWidget {
  const IsleQuickJumpStrip({
    super.key,
    required this.items,
    this.prefixLabel,
    this.padding = EdgeInsets.zero,
  });

  final List<IsleQuickJumpItem> items;
  final String? prefixLabel;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final defaultAccents = <Color>[
      palette['brandBlue'],
      palette['brandAmber'],
      palette['brandSage'],
      palette['brandViolet'],
      palette['brandTerracotta'],
    ];

    return Padding(
      padding: padding,
      child: Material(
        type: MaterialType.transparency,
        child: Wrap(
          spacing: 7,
          runSpacing: 7,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (prefixLabel != null && prefixLabel!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(
                  prefixLabel!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            for (var i = 0; i < items.length; i++)
              _QuickJumpChip(
                item: items[i],
                accent:
                    items[i].accent ?? defaultAccents[i % defaultAccents.length],
                colors: colors,
                palette: palette,
                isDark: isDark,
              ),
          ],
        ),
      ),
    );
  }
}

class _QuickJumpChip extends StatelessWidget {
  const _QuickJumpChip({
    required this.item,
    required this.accent,
    required this.colors,
    required this.palette,
    required this.isDark,
  });

  final IsleQuickJumpItem item;
  final Color accent;
  final ColorScheme colors;
  final IslePalette palette;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.tooltip,
      child: ActionChip(
        key: item.key,
        avatar: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withValues(alpha: isDark ? 0.22 : 0.12),
          ),
          child: Icon(item.icon, size: 11.5, color: accent),
        ),
        label: Text(
          item.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: isDark
            ? palette['cardItemTop'].withValues(alpha: 0.88)
            : palette['cardTop'].withValues(alpha: 0.94),
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 0.9),
        shape: IsleShapes.pill(),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        onPressed: item.onTap,
      ),
    );
  }
}
