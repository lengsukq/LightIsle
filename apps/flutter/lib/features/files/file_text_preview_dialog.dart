import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/widgets.dart';
import 'file_models.dart';

/// Presentation-only QuickLook panel shared by text previews.
/// Loading/decoding and account-specific file actions remain with the caller.
class FileTextPreviewDialog extends StatelessWidget {
  const FileTextPreviewDialog({
    super.key,
    required this.item,
    required this.badge,
    required this.onOpenExternal,
    required this.onDownload,
    this.text,
    this.error,
  }) : assert(text != null || error != null);

  final FileEntry item;
  final Widget badge;
  final String? text;
  final String? error;
  final VoidCallback onOpenExternal;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ClipRRect(
        borderRadius: IsleRadius.brCard,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 820),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: isDark ? 0.92 : 0.97),
              borderRadius: IsleRadius.brCard,
              border: Border.all(color: borderColor, width: 1.0),
              boxShadow: IsleShadows.floating(isDark),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  child: Row(
                    children: [
                      badge,
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 1.5),
                            Text(
                              '${formatBytes(item.size)} · QuickLook 快速查看',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 11.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '其他应用打开',
                        onPressed: () {
                          Navigator.pop(context);
                          onOpenExternal();
                        },
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '下载文件',
                        onPressed: () {
                          Navigator.pop(context);
                          onDownload();
                        },
                        icon: const Icon(Icons.download_rounded, size: 18),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, size: 19),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, thickness: 1, color: borderColor),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: error != null
                        ? Padding(
                            padding: const EdgeInsets.all(18),
                            child: Text(
                              '无法预览：$error',
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.error,
                              ),
                            ),
                          )
                        : Container(
                            constraints: const BoxConstraints(maxHeight: 520),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.black.withValues(alpha: 0.36)
                                  : colors.surfaceContainerHighest.withValues(
                                      alpha: 0.42,
                                    ),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: borderColor,
                                width: 1.0,
                              ),
                            ),
                            padding: const EdgeInsets.all(14),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                text ?? '',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
