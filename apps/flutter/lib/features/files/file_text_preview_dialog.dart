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
    final isDark = theme.brightness == Brightness.dark;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 820),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(
                alpha: isDark ? 0.88 : 0.94,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.16)
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                width: 0.85,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.15),
                  blurRadius: 36,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
                  child: Row(
                    children: [
                      badge,
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${formatBytes(item.size)} · QuickLook 快速查看',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '其他应用打开',
                        onPressed: () {
                          Navigator.pop(context);
                          onOpenExternal();
                        },
                        icon: const Icon(Icons.open_in_new_rounded),
                      ),
                      IconButton(
                        tooltip: '下载文件',
                        onPressed: () {
                          Navigator.pop(context);
                          onDownload();
                        },
                        icon: const Icon(Icons.download_rounded),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.35,
                        ),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: error != null
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text('无法预览：$error'),
                          )
                        : Container(
                            constraints: const BoxConstraints(maxHeight: 520),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.black.withValues(alpha: 0.45)
                                  : theme.colorScheme.surfaceContainerHighest
                                        .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : theme.colorScheme.outlineVariant
                                          .withValues(alpha: 0.3),
                              ),
                            ),
                            padding: const EdgeInsets.all(16),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                text ?? '',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontFamily: 'monospace',
                                  height: 1.55,
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
