import 'package:flutter/material.dart';

/// Consistent compact, icon-led items for overflow menus across the NAS UI.
PopupMenuItem<String> isleActionMenuItem({
  required String value,
  required String label,
  required IconData icon,
  bool enabled = true,
  bool checked = false,
}) => PopupMenuItem<String>(
  value: value,
  enabled: enabled,
  height: 46,
  padding: const EdgeInsets.symmetric(horizontal: 14),
  child: Builder(
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return Row(
        children: [
          Icon(
            icon,
            size: 19,
            color: enabled ? colors.onSurfaceVariant : colors.outline,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          if (checked) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_rounded, size: 18, color: colors.primary),
          ],
        ],
      );
    },
  ),
);
