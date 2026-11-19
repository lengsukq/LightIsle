import 'package:flutter/material.dart';

/// Consistent compact, icon-led items for overflow menus across the NAS UI.
PopupMenuItem<String> isleActionMenuItem({
  required String value,
  required String label,
  required IconData icon,
  bool enabled = true,
  bool checked = false,
  bool destructive = false,
}) => PopupMenuItem<String>(
  value: value,
  enabled: enabled,
  height: 40,
  padding: const EdgeInsets.symmetric(horizontal: 12),
  child: Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final iconColor = !enabled
          ? colors.outline
          : destructive
          ? colors.error
          : colors.onSurfaceVariant;
      final labelColor = !enabled
          ? colors.onSurfaceVariant.withValues(alpha: 0.45)
          : destructive
          ? colors.error
          : colors.onSurface;
      return Row(
        children: [
          Icon(
            icon,
            size: 17.5,
            color: iconColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13.5,
                fontWeight: checked ? FontWeight.w600 : FontWeight.w500,
                color: labelColor,
              ),
            ),
          ),
          if (checked) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_rounded, size: 17, color: colors.primary),
          ],
        ],
      );
    },
  ),
);
