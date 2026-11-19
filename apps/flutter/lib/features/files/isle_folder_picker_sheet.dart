import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'file_destination_dialog.dart';

/// Folder browser & destination picker widget adhering to
/// LightIsle's continuous-curvature (squircle) and crisp 1px border style.
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

  Widget _buildBreadcrumbBar(ColorScheme colors, Color borderColor) {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < widget.breadcrumbs.length; i++) ...[
          if (i > 0)
            Icon(
              Icons.chevron_right_rounded,
              size: 14,
              color: colors.onSurfaceVariant.withValues(alpha: 0.65),
            ),
          _BreadcrumbPill(
            label: widget.breadcrumbs[i].$1,
            active: widget.breadcrumbs[i].$2 == widget.directory,
            isRoot: i == 0,
            borderColor: borderColor,
            onTap:
                widget.loading || widget.breadcrumbs[i].$2 == widget.directory
                ? null
                : () => widget.onBrowse(widget.breadcrumbs[i].$2),
          ),
        ],
        if (widget.sourceParentDirectory != null &&
            widget.sourceParentDirectory != widget.directory)
          ActionChip(
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: borderColor, width: 1.0),
            avatar: const Icon(Icons.my_location_rounded, size: 13.5),
            label: const Text('定位到来源所在目录', style: TextStyle(fontSize: 12)),
            onPressed: widget.loading
                ? null
                : () => widget.onBrowse(widget.sourceParentDirectory!),
          ),
        if (widget.canWrite && !widget.loading)
          ActionChip(
            key: const ValueKey('destination-new-folder'),
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: borderColor, width: 1.0),
            avatar: const Icon(Icons.create_new_folder_outlined, size: 13.5),
            label: const Text('新建文件夹', style: TextStyle(fontSize: 12)),
            onPressed: widget.onCreateSubfolder,
          ),
      ],
    );
  }

  Widget _buildPathStatusHeader(
    ThemeData theme,
    ColorScheme colors, {
    required bool isDark,
    required Color borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: ShapeDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.035)
            : colors.surfaceContainerHighest.withValues(alpha: 0.30),
        shape: IsleShapes.sm(
          side: BorderSide(color: borderColor, width: 1.0),
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
                size: 14.5,
                color: colors.primary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.directory == '.'
                      ? '/ (存储根目录)'
                      : '/${widget.directory}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ),
            ],
          ),
          IsleStatusBadge(
            label: widget.loading ? '读取中' : (widget.canWrite ? '可写入' : '只读目录'),
            color: widget.canWrite
                ? const Color(0xff10b981)
                : const Color(0xff64748b),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderListContainer({
    required ThemeData theme,
    required ColorScheme colors,
    required IslePalette palette,
    required bool isDark,
    required Color borderColor,
    required List<String> parts,
    required List<(String, String)> filteredFolders,
  }) {
    final hasUpRow = widget.directory != '.';
    return Container(
      constraints: const BoxConstraints(maxHeight: 204, minHeight: 68),
      decoration: ShapeDecoration(
        color: palette['cardItemTop'],
        shape: IsleShapes.md(
          side: BorderSide(color: borderColor, width: 1.0),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            if (hasUpRow)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: Container(
                  width: 28,
                  height: 28,
                  decoration: IsleDecorations.iconBadge(
                    colors.primary.withValues(alpha: isDark ? 0.20 : 0.10),
                    radius: 7,
                  ),
                  child: Icon(
                    Icons.arrow_upward_rounded,
                    color: colors.primary,
                    size: 15,
                  ),
                ),
                title: const Text(
                  '上一级',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  parts.length <= 1
                      ? '返回根目录'
                      : parts.take(parts.length - 1).join('/'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5),
                ),
                onTap: widget.loading
                    ? null
                    : () => widget.onBrowse(
                        parts.length == 1
                            ? '.'
                            : parts.take(parts.length - 1).join('/'),
                      ),
              ),
            for (var idx = 0; idx < filteredFolders.length; idx++) ...[
              if (idx > 0 || hasUpRow)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 46,
                  color: borderColor,
                ),
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: Container(
                  width: 28,
                  height: 28,
                  decoration: IsleDecorations.iconBadge(
                    palette['brandAmber']
                        .withValues(alpha: isDark ? 0.22 : 0.12),
                    radius: 7,
                  ),
                  child: Icon(
                    Icons.folder_rounded,
                    color: palette['brandAmber'],
                    size: 15.5,
                  ),
                ),
                title: Text(
                  filteredFolders[idx].$1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: colors.onSurfaceVariant,
                ),
                onTap: widget.loading
                    ? null
                    : () => widget.onBrowse(filteredFolders[idx].$2),
              ),
            ],
            if (widget.loading)
              const IsleLoadingState(
                compact: true,
                padding: EdgeInsets.symmetric(vertical: 12),
              )
            else if (filteredFolders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.folder_off_outlined,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _filterQuery.trim().isEmpty ? '当前没有子文件夹' : '没有匹配的文件夹',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.hasMore && !widget.loading)
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: widget.onLoadMore,
                icon: const Icon(Icons.expand_more_rounded, size: 15),
                label: const Text('更多文件夹', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
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
        _buildBreadcrumbBar(colors, borderColor),
        const SizedBox(height: 6),
        _buildPathStatusHeader(
          theme,
          colors,
          isDark: isDark,
          borderColor: borderColor,
        ),
        if (widget.folders.length > 5) ...[
          const SizedBox(height: 6),
          TextField(
            onChanged: (v) => setState(() => _filterQuery = v),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search_rounded, size: 17),
              hintText: '筛选当前层级文件夹…',
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),
        _buildFolderListContainer(
          theme: theme,
          colors: colors,
          palette: palette,
          isDark: isDark,
          borderColor: borderColor,
          parts: parts,
          filteredFolders: filteredFolders,
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
    required this.borderColor,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool isRoot;
  final Color borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(32, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        backgroundColor: active
            ? colors.primaryContainer.withValues(alpha: 0.72)
            : colors.surfaceContainerHighest.withValues(alpha: 0.30),
        foregroundColor: active ? colors.primary : colors.onSurface,
        shape: StadiumBorder(
          side: BorderSide(
            color: active
                ? colors.primary.withValues(alpha: 0.36)
                : borderColor,
            width: 1.0,
          ),
        ),
      ),
      icon: Icon(
        isRoot ? Icons.home_outlined : Icons.folder_outlined,
        size: 13.5,
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
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
