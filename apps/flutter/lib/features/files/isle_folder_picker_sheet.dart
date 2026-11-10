import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'file_destination_dialog.dart';

/// Refined Liquid Glass folder browser & destination picker widget adhering to
/// LightIsle's iOS continuous-curvature (squircle) and translucent surface style.
class IsleFolderBrowserCard extends StatefulWidget {
  const IsleFolderBrowserCard({
    super.key,
    required this.directory,
    required this.breadcrumbs,
    required this.folders,
    required this.canWrite,
    required this.loading,
    required this.hasMore,
    required this.onBrowse,
    required this.onLoadMore,
    required this.onCreateSubfolder,
    this.sourceParentDirectory,
  });

  final String directory;
  final List<(String, String)> breadcrumbs;
  final List<(String, String)> folders;
  final bool canWrite;
  final bool loading;
  final bool hasMore;
  final ValueChanged<String> onBrowse;
  final VoidCallback onLoadMore;
  final VoidCallback onCreateSubfolder;
  final String? sourceParentDirectory;

  @override
  State<IsleFolderBrowserCard> createState() => _IsleFolderBrowserCardState();
}

class _IsleFolderBrowserCardState extends State<IsleFolderBrowserCard> {
  String _filterQuery = '';

  @override
  void didUpdateWidget(covariant IsleFolderBrowserCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.directory != widget.directory && _filterQuery.isNotEmpty) {
      _filterQuery = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final parts = widget.directory == '.'
        ? <String>[]
        : widget.directory.split('/');
    final filteredFolders = _filterQuery.trim().isEmpty
        ? widget.folders
        : widget.folders
              .where(
                (f) => f.$1.toLowerCase().contains(
                  _filterQuery.trim().toLowerCase(),
                ),
              )
              .toList(growable: false);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Breadcrumb & quick action bar
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < widget.breadcrumbs.length; i++) ...[
              if (i > 0)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 15,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              _BreadcrumbPill(
                label: widget.breadcrumbs[i].$1,
                active: widget.breadcrumbs[i].$2 == widget.directory,
                isRoot: i == 0,
                onTap:
                    widget.loading ||
                        widget.breadcrumbs[i].$2 == widget.directory
                    ? null
                    : () => widget.onBrowse(widget.breadcrumbs[i].$2),
              ),
            ],
            if (widget.sourceParentDirectory != null &&
                widget.sourceParentDirectory != widget.directory)
              ActionChip(
                avatar: const Icon(Icons.my_location_rounded, size: 14),
                label: const Text('定位到来源所在目录'),
                onPressed: widget.loading
                    ? null
                    : () => widget.onBrowse(widget.sourceParentDirectory!),
              ),
            if (widget.canWrite && !widget.loading)
              ActionChip(
                key: const ValueKey('destination-new-folder'),
                avatar: const Icon(Icons.create_new_folder_outlined, size: 14),
                label: const Text('新建文件夹'),
                onPressed: widget.onCreateSubfolder,
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Current path & write status bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: ShapeDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : const Color(0xff0f172a).withValues(alpha: 0.035),
            shape: IsleShapes.squircle(
              12,
              side: BorderSide(
                color: colors.outlineVariant.withValues(
                  alpha: isDark ? 0.25 : 0.16,
                ),
                width: 0.75,
              ),
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.directory == '.'
                        ? Icons.dns_rounded
                        : Icons.folder_open_rounded,
                    size: 15,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      widget.directory == '.' ? '/ (存储根目录)' : '/${widget.directory}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              IsleStatusBadge(
                label: widget.loading
                    ? '读取中'
                    : (widget.canWrite ? '可写入' : '只读目录'),
                color: widget.canWrite
                    ? const Color(0xff10b981)
                    : const Color(0xff64748b),
              ),
            ],
          ),
        ),

        if (widget.folders.length > 5) ...[
          const SizedBox(height: 8),
          TextField(
            onChanged: (v) => setState(() => _filterQuery = v),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search_rounded, size: 18),
              hintText: '筛选当前层级文件夹…',
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),

        // Squircle folder tree container
        Container(
          constraints: const BoxConstraints(maxHeight: 220, minHeight: 72),
          decoration: ShapeDecoration(
            color: palette['cardItemTop'],
            shape: IsleShapes.squircle(
              16,
              side: BorderSide(
                color: IsleGlass.rimBorderColor(isDark),
                width: 0.85,
              ),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
              if (widget.directory != '.')
                ListTile(
                  dense: true,
                  leading: Container(
                    width: 30,
                    height: 30,
                    decoration: IsleDecorations.iconBadge(
                      colors.primary.withValues(alpha: isDark ? 0.20 : 0.10),
                      radius: 8,
                    ),
                    child: Icon(
                      Icons.arrow_upward_rounded,
                      color: colors.primary,
                      size: 16,
                    ),
                  ),
                  title: const Text(
                    '上一级',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    parts.length <= 1
                        ? '返回根目录'
                        : parts.take(parts.length - 1).join('/'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: widget.loading
                      ? null
                      : () => widget.onBrowse(
                          parts.length == 1
                              ? '.'
                              : parts.take(parts.length - 1).join('/'),
                        ),
                ),
              for (final (name, path) in filteredFolders)
                ListTile(
                  dense: true,
                  leading: Container(
                    width: 30,
                    height: 30,
                    decoration: IsleDecorations.iconBadge(
                      const Color(
                        0xff0ea5e9,
                      ).withValues(alpha: isDark ? 0.22 : 0.12),
                      radius: 8,
                    ),
                    child: const Icon(
                      Icons.folder_rounded,
                      color: Color(0xff0ea5e9),
                      size: 17,
                    ),
                  ),
                  title: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                  onTap: widget.loading ? null : () => widget.onBrowse(path),
                ),
              if (widget.loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (filteredFolders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 18,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.folder_off_outlined,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _filterQuery.trim().isEmpty
                              ? '当前没有子文件夹'
                              : '没有匹配的文件夹',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.hasMore && !widget.loading)
                TextButton.icon(
                  onPressed: widget.onLoadMore,
                  icon: const Icon(Icons.expand_more_rounded, size: 16),
                  label: const Text('更多文件夹'),
                ),
            ],
          ),
          ),
        ),
      ],
    );
  }
}

class _BreadcrumbPill extends StatelessWidget {
  const _BreadcrumbPill({
    required this.label,
    required this.active,
    required this.isRoot,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool isRoot;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(36, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        backgroundColor: active
            ? colors.primaryContainer.withValues(alpha: 0.75)
            : colors.surfaceContainerHighest.withValues(alpha: 0.35),
        foregroundColor: active ? colors.primary : colors.onSurface,
        shape: const StadiumBorder(),
      ),
      icon: Icon(
        isRoot ? Icons.home_outlined : Icons.folder_outlined,
        size: 14,
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

/// Convenience helper to open the refined folder picker dialog from anywhere in
/// the Flutter app (e.g. GrantsPage, StoragePage, or FilesPage).
class IsleFolderPickerSheet {
  static Future<FileDestinationSelection?> pickFolder(
    BuildContext context, {
    required LightIsleApi api,
    String action = 'grant',
    String initialSourcePath = '',
  }) {
    return showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: api,
        action: action,
        sourceName: '',
        sourcePath: initialSourcePath,
        directoryOnly: true,
      ),
    );
  }
}
