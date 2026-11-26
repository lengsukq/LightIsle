import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_action_menu.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'file_entry_visuals.dart';
import 'file_extras_api.dart';
import 'file_models.dart';
import 'file_search_widgets.dart';

const BoxConstraints _kActionMenuConstraints = BoxConstraints(
  minWidth: 205,
  maxWidth: 260,
);

List<PopupMenuEntry<String>> buildFilesActionMenuItems({
  required FileEntry item,
  required bool writable,
  required bool searching,
  bool pinned = false,
}) => [
  if (searching)
    isleActionMenuItem(
      value: 'openContainingFolder',
      icon: Icons.folder_open_outlined,
      label: '打开所在目录',
    ),
  if (!item.isFolder)
    isleActionMenuItem(
      value: 'preview',
      icon: Icons.visibility_outlined,
      label: '预览',
    ),
  if (!item.isFolder && isReadableArchiveFile(item.name))
    isleActionMenuItem(
      value: 'openReader',
      icon: Icons.auto_stories_outlined,
      label: '漫画/EPUB 轻阅读',
    ),
  if (!item.isFolder)
    isleActionMenuItem(
      value: 'openExternal',
      icon: Icons.open_in_new_rounded,
      label: '其他应用打开',
    ),
  if (!item.isFolder)
    isleActionMenuItem(
      value: 'saveOffline',
      icon: Icons.offline_pin_outlined,
      label: '保存到离线文件箱',
    ),
  isleActionMenuItem(
    value: 'togglePin',
    icon: pinned ? Icons.star_rounded : Icons.star_outline_rounded,
    label: pinned ? '取消置顶' : '置顶到常用',
  ),
  isleActionMenuItem(
    value: 'download',
    icon: item.isFolder ? Icons.archive_outlined : Icons.download_outlined,
    label: item.isFolder ? '下载文件夹 ZIP' : '下载',
  ),
  if (writable && !item.isFolder && item.name.toLowerCase().endsWith('.zip'))
    isleActionMenuItem(
      value: 'extract',
      icon: Icons.unarchive_outlined,
      label: '解压到同名文件夹',
    ),
  if (!item.isFolder)
    isleActionMenuItem(
      value: 'share',
      icon: Icons.ios_share_outlined,
      label: '分享文件',
    ),
  if (item.isFolder)
    isleActionMenuItem(
      value: 'share',
      icon: Icons.ios_share_outlined,
      label: '分享文件夹 ZIP',
    ),
  if (writable && item.isFolder)
    isleActionMenuItem(
      value: 'collectLink',
      icon: Icons.move_to_inbox_outlined,
      label: '创建收集链接',
    ),
  const PopupMenuDivider(),
  if (writable)
    isleActionMenuItem(
      value: 'rename',
      icon: Icons.drive_file_rename_outline,
      label: '重命名',
    ),
  isleActionMenuItem(value: 'copy', icon: Icons.copy_outlined, label: '复制'),
  if (writable)
    isleActionMenuItem(
      value: 'move',
      icon: Icons.drive_file_move_outline,
      label: '移动到…',
    ),
  if (writable)
    isleActionMenuItem(
      value: 'trash',
      icon: Icons.delete_outline,
      label: '移到回收站',
    ),
];

Future<String?> showFilesItemContextMenu(
  BuildContext context, {
  required Offset globalPosition,
  required FileEntry item,
  required bool writable,
  required bool searching,
  bool pinned = false,
}) async {
  final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
  if (overlay is! RenderBox) return null;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    constraints: _kActionMenuConstraints,
    shape: IsleShapes.md(
      side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
    ),
    items: buildFilesActionMenuItems(
      item: item,
      writable: writable,
      searching: searching,
      pinned: pinned,
    ),
  );
}

class FilesItemActionsMenu extends StatelessWidget {
  const FilesItemActionsMenu({
    super.key,
    required this.item,
    required this.writable,
    required this.searching,
    required this.onSelected,
    this.pinned = false,
  });

  final FileEntry item;
  final bool writable;
  final bool searching;
  final bool pinned;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      tooltip: '文件操作',
      position: PopupMenuPosition.under,
      constraints: _kActionMenuConstraints,
      shape: IsleShapes.md(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      onSelected: onSelected,
      itemBuilder: (_) => buildFilesActionMenuItems(
        item: item,
        writable: writable,
        searching: searching,
        pinned: pinned,
      ),
    );
  }
}

class FilesDesktopTableRow extends StatelessWidget {
  const FilesDesktopTableRow({
    super.key,
    required this.api,
    required this.item,
    required this.writable,
    required this.searching,
    required this.searchTerm,
    required this.selecting,
    required this.selected,
    required this.highlighted,
    required this.highlightedItemKey,
    required this.loading,
    required this.downloading,
    required this.downloadProgress,
    required this.failedThumbnails,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleSelected,
    required this.onAction,
    required this.onSecondaryTapDown,
    this.pinned = false,
  });

  final LightIsleApi api;
  final FileEntry item;
  final bool writable;
  final bool pinned;
  final bool searching;
  final String searchTerm;
  final bool selecting;
  final bool selected;
  final bool highlighted;
  final GlobalKey highlightedItemKey;
  final bool loading;
  final bool downloading;
  final double? downloadProgress;
  final Set<String> failedThumbnails;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<bool?> onToggleSelected;
  final ValueChanged<String> onAction;
  final GestureTapDownCallback onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final modified = item.modified == null ? '—' : formatDateTime(item.modified!);
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      color: colors.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final row = AnimatedContainer(
      key: highlighted
          ? highlightedItemKey
          : ValueKey('file-tile-${item.path}'),
      duration: IsleMotion.reducedMotion(context)
          ? Duration.zero
          : IsleMotion.normal,
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.42)
          : highlighted
          ? colors.primaryContainer.withValues(alpha: 0.48)
          : Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: loading ? null : onSecondaryTapDown,
        child: InkWell(
          onTap: loading ? null : onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                if (selecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Semantics(
                      label: '选择 ${item.name}',
                      child: Checkbox(
                        visualDensity: VisualDensity.compact,
                        value: selected,
                        onChanged: (value) {
                          HapticFeedback.selectionClick();
                          onToggleSelected(value);
                        },
                      ),
                    ),
                  ),
                FileEntryBadge(
                  api: api,
                  item: item,
                  failedThumbnails: failedThumbnails,
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      searching
                          ? HighlightedSearchText(
                              text: item.name,
                              query: searchTerm,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            )
                          : Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                      if (searching)
                        Text(
                          fileRelativeParentLabel(item.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle?.copyWith(fontSize: 11.2),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: Text(
                    fileKindLabel(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Text(
                    item.isFolder ? '—' : formatBytes(item.size),
                    textAlign: TextAlign.right,
                    style: metaStyle,
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 144,
                  child: Text(
                    modified,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FilesItemActionsMenu(
                      item: item,
                      writable: writable,
                      searching: searching,
                      pinned: pinned,
                      onSelected: onAction,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Column(
      children: [
        row,
        if (downloading)
          Padding(
            padding: const EdgeInsets.only(left: 58, right: 16, bottom: 6),
            child: LinearProgressIndicator(value: downloadProgress),
          ),
        const Divider(height: 1, indent: 58, endIndent: 14),
      ],
    );
  }
}

class FilesItemListTile extends StatelessWidget {
  const FilesItemListTile({
    super.key,
    required this.api,
    required this.item,
    required this.compact,
    required this.writable,
    required this.searching,
    required this.searchTerm,
    required this.selecting,
    required this.selected,
    required this.highlighted,
    required this.highlightedItemKey,
    required this.loading,
    required this.downloading,
    required this.downloadProgress,
    required this.failedThumbnails,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleSelected,
    required this.onAction,
    required this.onSecondaryTapDown,
    this.pinned = false,
  });

  final LightIsleApi api;
  final FileEntry item;
  final bool compact;
  final bool writable;
  final bool pinned;
  final bool searching;
  final String searchTerm;
  final bool selecting;
  final bool selected;
  final bool highlighted;
  final GlobalKey highlightedItemKey;
  final bool loading;
  final bool downloading;
  final double? downloadProgress;
  final Set<String> failedThumbnails;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<bool?> onToggleSelected;
  final ValueChanged<String> onAction;
  final GestureTapDownCallback onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final modified = item.modified == null
        ? '修改时间未知'
        : formatDateTime(item.modified!);
    final subtitleStyle = TextStyle(
      fontSize: 11.5,
      color: colors.onSurfaceVariant,
    );

    final tile = AnimatedContainer(
      key: highlighted
          ? highlightedItemKey
          : ValueKey('file-tile-${item.path}'),
      duration: IsleMotion.reducedMotion(context)
          ? Duration.zero
          : IsleMotion.normal,
      color: highlighted
          ? colors.primaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: loading ? null : onSecondaryTapDown,
        child: ListTile(
          dense: true,
          minTileHeight: compact ? 46 : 48,
          visualDensity: compact
              ? VisualDensity.compact
              : VisualDensity.standard,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 16,
            vertical: 0,
          ),
          selected: selected,
          selectedTileColor: colors.primaryContainer.withValues(alpha: .42),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selecting)
                Semantics(
                  label: '选择 ${item.name}',
                  child: Checkbox(
                    visualDensity: VisualDensity.compact,
                    value: selected,
                    onChanged: (value) {
                      HapticFeedback.selectionClick();
                      onToggleSelected(value);
                    },
                  ),
                ),
              const SizedBox(width: 2),
              FileEntryBadge(
                api: api,
                item: item,
                failedThumbnails: failedThumbnails,
              ),
            ],
          ),
          title: searching
              ? HighlightedSearchText(
                  text: item.name,
                  query: searchTerm,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                )
              : Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
          subtitle: searching
              ? Row(
                  children: [
                    Text(
                      '${item.isFolder ? '文件夹' : formatBytes(item.size)} · $modified · ',
                      style: subtitleStyle,
                    ),
                    Expanded(
                      child: HighlightedSearchText(
                        text: fileRelativeParentLabel(item.path),
                        query: searchTerm,
                        style: subtitleStyle,
                      ),
                    ),
                  ],
                )
              : Text(
                  '${item.isFolder ? '文件夹' : formatBytes(item.size)} · $modified',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: subtitleStyle,
                ),
          onLongPress: onLongPress,
          onTap: loading ? null : onTap,
          trailing: FilesItemActionsMenu(
            item: item,
            writable: writable,
            searching: searching,
            pinned: pinned,
            onSelected: onAction,
          ),
        ),
      ),
    );

    return Column(
      children: [
        tile,
        if (downloading)
          Padding(
            padding: const EdgeInsets.only(left: 64, right: 16, bottom: 6),
            child: LinearProgressIndicator(value: downloadProgress),
          ),
        const Divider(height: 1, indent: 56, endIndent: 14),
      ],
    );
  }
}
