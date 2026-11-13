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
  });

  final Key? key;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
}

/// Compact, single-line horizontal Liquid Glass quick-jump strip connecting
/// related workflows (e.g. quota -> cleanup, files -> WebDAV/SMB mount).
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

    return Padding(
      padding: padding,
      child: Material(
        type: MaterialType.transparency,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (prefixLabel != null && prefixLabel!.isNotEmpty)
              Text(
                prefixLabel!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            for (final item in items)
              _QuickJumpChip(item: item, colors: colors, isDark: isDark),
          ],
        ),
      ),
    );
  }
}

class _QuickJumpChip extends StatelessWidget {
  const _QuickJumpChip({
    required this.item,
    required this.colors,
    required this.isDark,
  });

  final IsleQuickJumpItem item;
  final ColorScheme colors;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.tooltip,
      child: ActionChip(
        key: item.key,
        avatar: Icon(item.icon, size: 15, color: colors.primary),
        label: Text(
          item.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : colors.surfaceContainerHighest.withValues(alpha: 0.55),
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 0.75),
        shape: IsleShapes.pill(),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        onPressed: item.onTap,
      ),
    );
  }
}
