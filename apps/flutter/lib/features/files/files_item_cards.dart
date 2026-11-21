import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'file_entry_visuals.dart';
import 'file_models.dart';
import 'file_search_widgets.dart';
import 'files_item_tiles.dart';

class FilesItemCard extends StatelessWidget {
  const FilesItemCard({
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
  });

  final LightIsleApi api;
  final FileEntry item;
  final bool writable;
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
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final detailHeight = 68 + (textScale - 1).clamp(0.0, 3.0) * 32;
    final baseWidth = style.effectiveBorderWidth();

    final card = Card(
      key: ValueKey('file-card-${item.path}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: selected
          ? colors.primaryContainer
          : highlighted
          ? colors.primaryContainer.withValues(alpha: 0.62)
          : palette['cardItemTop'],
      shape: style.shapeFor(
        14,
        side: BorderSide(
          color: selected || highlighted
              ? colors.primary
              : style.rimBorderColor(),
          width: highlighted ? 2.2 : (selected ? 1.8 : baseWidth),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: loading ? null : onSecondaryTapDown,
        child: InkWell(
          onTap: loading ? null : onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FileCardCover(
                      api: api,
                      item: item,
                      failedThumbnails: failedThumbnails,
                    ),
                    if (selecting)
                      Positioned(
                        top: 2,
                        left: 2,
                        child: Checkbox(
                          value: selected,
                          onChanged: onToggleSelected,
                        ),
                      ),
                    if (downloading)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(value: downloadProgress),
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: detailHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 3, 2, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            searching
                                ? HighlightedSearchText(
                                    text: item.name,
                                    query: searchTerm,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  )
                                : Text(
                                    item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                            const SizedBox(height: 1),
                            Text(
                              searching
                                  ? '${item.isFolder ? '文件夹' : formatBytes(item.size)} · ${fileRelativeParentLabel(item.path)}'
                                  : (item.isFolder
                                        ? '文件夹'
                                        : formatBytes(item.size)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontSize: 11.5,
                                    color: colors.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      FilesItemActionsMenu(
                        item: item,
                        writable: writable,
                        searching: searching,
                        onSelected: onAction,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return highlighted
        ? KeyedSubtree(key: highlightedItemKey, child: card)
        : card;
  }
}

class FilesTrashTile extends StatelessWidget {
  const FilesTrashTile({
    super.key,
    required this.item,
    required this.compact,
    required this.canPurge,
    required this.onRestore,
    required this.onPurge,
  });

  final TrashEntry item;
  final bool compact;
  final bool canPurge;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          dense: true,
          minTileHeight: 54,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 16,
            vertical: 2,
          ),
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: colors.error.withValues(alpha: 0.12),
            ),
            child: Icon(
              Icons.delete_outline_rounded,
              color: colors.error,
              size: 18,
            ),
          ),
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '原路径：${item.originalPath}${item.deletedAt == null ? '' : ' · ${formatDateTime(item.deletedAt!)}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5),
          ),
          trailing: Wrap(
            spacing: 2,
            children: [
              IconButton(
                tooltip: '恢复',
                visualDensity: VisualDensity.compact,
                onPressed: onRestore,
                icon: const Icon(Icons.restore, size: 19),
              ),
              if (canPurge)
                IconButton(
                  tooltip: '永久删除',
                  visualDensity: VisualDensity.compact,
                  onPressed: onPurge,
                  color: colors.error,
                  icon: const Icon(Icons.delete_forever_outlined, size: 19),
                ),
            ],
          ),
        ),
        const Divider(height: 1, indent: 56, endIndent: 14),
      ],
    );
  }
}

class FilesDownloadNotice extends StatelessWidget {
  const FilesDownloadNotice({
    super.key,
    required this.message,
    required this.onCopyPath,
  });

  final String message;
  final ValueChanged<String> onCopyPath;

  static const String _downloadedPrefix = '已下载到：';

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final sage = palette['brandSage'];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        tint: sage,
        radius: IsleRadius.md,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.download_done_outlined, size: 19, color: sage),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(message)),
            if (message.startsWith(_downloadedPrefix))
              IconButton(
                tooltip: '复制下载路径',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    onCopyPath(message.substring(_downloadedPrefix.length)),
                icon: const Icon(Icons.copy, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

class FilesEmptyState extends StatelessWidget {
  const FilesEmptyState({
    super.key,
    required this.text,
    required this.icon,
    this.showCreateActions = false,
    this.busy = false,
    this.uploadBusy = false,
    this.onUpload,
    this.onCreateFolder,
  });

  final String text;
  final IconData icon;
  final bool showCreateActions;
  final bool busy;
  final bool uploadBusy;
  final VoidCallback? onUpload;
  final VoidCallback? onCreateFolder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = IslePalette.of(context);
    final accent = palette['brandAmber'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 30),
      child: Column(
        children: [
          IsleSquircleBadge(icon: icon, color: accent, size: 46, iconSize: 22),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: colors.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (showCreateActions) ...[
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                IslePillButton(
                  label: '上传文件到此目录',
                  icon: Icons.add_rounded,
                  compact: true,
                  variant: IslePillVariant.primary,
                  onPressed: busy || uploadBusy ? null : onUpload,
                ),
                IslePillButton(
                  label: '在此新建文件夹',
                  icon: Icons.create_new_folder_outlined,
                  compact: true,
                  onPressed: busy ? null : onCreateFolder,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
