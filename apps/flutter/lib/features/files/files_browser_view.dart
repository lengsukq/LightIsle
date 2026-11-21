import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'file_entry_visuals.dart';
import 'file_models.dart';
import 'file_search_widgets.dart';
import 'file_selection_toolbar.dart';
import 'files_controller.dart';
import 'files_item_cards.dart';
import 'files_item_tiles.dart';
import 'files_shell_widgets.dart';
import 'files_ui_actions.dart';

class FilesBrowserSurface extends StatelessWidget {
  const FilesBrowserSurface({
    super.key,
    required this.controller,
    required this.actions,
    required this.highlightedItemKey,
    required this.compact,
    required this.availableWidth,
  });

  final FilesController controller;
  final FilesUiActions actions;
  final GlobalKey highlightedItemKey;
  final bool compact;
  final double availableWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final dir = controller.dir;
    final filter = controller.filter;
    final prefs = controller.prefs;
    final transfers = controller.transfers;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final desktopTable =
        availableWidth >= 840 &&
        textScale <= 1.35 &&
        prefs.fileView != 'grid' &&
        !filter.showingTrash;
    final showInspectorSidePanel =
        availableWidth >= 1040 &&
        textScale <= 1.35 &&
        !filter.showingTrash &&
        transfers.selectedPaths.length == 1;
    final gridHeightExtra = (textScale - 1).clamp(0.0, 3.0) * 45;

    final mainSurface = IsleSurface(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSurfaceHeader(context, theme, colors, style, palette),
          IsleAnimatedExpand(
            expanded: !filter.showingTrash && transfers.selecting,
            child: _buildSelectionToolbar(context),
          ),
          if (filter.searching && !filter.showingTrash)
            FileSearchScopeAndKindBar(
              busy: dir.loading,
              selectedKind: filter.searchKind,
              onSelectKind: controller.setSearchKind,
              subdirLabel: controller.searchSubdirLabel,
              searchEntireRoot: filter.searchEntireRoot,
              onToggleScope: filter.searchScopeSubdir == null
                  ? null
                  : controller.setSearchEntireRoot,
            ),
          const Divider(height: 1),
          if (desktopTable && dir.entries.isNotEmpty)
            FileDesktopColumnHeader(selecting: transfers.selecting),
          _buildSurfaceBody(
            context,
            colors: colors,
            desktopTable: desktopTable,
            gridHeightExtra: gridHeightExtra,
          ),
        ],
      ),
    );

    if (!showInspectorSidePanel) return mainSurface;
    final selectedPath = transfers.selectedPaths.first;
    final selectedEntry = dir.entries
        .where((entry) => entry.path == selectedPath)
        .firstOrNull;
    if (selectedEntry == null) return mainSurface;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 8, child: mainSurface),
        const SizedBox(width: 14),
        SizedBox(
          width: 280,
          child: IsleModeSwitcher(
            modeKey: selectedEntry.path,
            duration: IsleMotion.quick,
            child: FileDesktopSelectionInspector(
              api: controller.api,
              item: selectedEntry,
              writable: controller.canWriteItem(selectedEntry),
              failedThumbnails: dir.failedThumbnails,
              onOpenOrPreview: () => selectedEntry.isFolder
                  ? unawaited(controller.loadFiles(target: selectedEntry.path))
                  : unawaited(actions.previewEntry(context, selectedEntry)),
              onDownload: () =>
                  unawaited(actions.downloadEntry(context, selectedEntry)),
              onShare: () =>
                  unawaited(actions.shareFile(context, selectedEntry)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSurfaceHeader(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
    IsleThemeStyle style,
    IslePalette palette,
  ) {
    final dir = controller.dir;
    final filter = controller.filter;
    final prefs = controller.prefs;
    final title = filter.showingTrash
        ? '回收站'
        : filter.searching
        ? '搜索结果'
        : '${dir.rootName} · ${dir.path == '.' ? '全部文件' : dir.path}';
    final folderCount = dir.entries.where((entry) => entry.isFolder).length;
    final fileCount = dir.entries.length - folderCount;
    final totalFileBytes = dir.entries
        .where((entry) => !entry.isFolder)
        .fold<int>(0, (sum, entry) => sum + entry.size);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: compact ? 4 : 8,
      ),
      child: Row(
        children: [
          Container(
            width: style.preset.surfaceMaterial ==
                    IsleSurfaceMaterial.flatHairline
                ? 8
                : style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal
                ? 9
                : 3,
            height: style.preset.surfaceMaterial ==
                        IsleSurfaceMaterial.flatHairline ||
                    style.preset.surfaceMaterial ==
                        IsleSurfaceMaterial.neoBrutal
                ? 9
                : 15,
            decoration: BoxDecoration(
              borderRadius:
                  style.preset.cornerStyle == IsleCornerStyle.sharp
                  ? BorderRadius.zero
                  : BorderRadius.circular(999),
              color: filter.showingTrash ? colors.error : palette['brandAmber'],
              border: style.preset.surfaceMaterial ==
                      IsleSurfaceMaterial.neoBrutal
                  ? Border.all(color: style.rimBorderColor(), width: 1.4)
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              compact && !filter.showingTrash && !filter.searching
                  ? '文件 · ${dir.entries.length} 项'
                  : title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
          ),
          if (!compact && !filter.showingTrash && dir.entries.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: IsleDecorations.recessedWell(context, radius: 999),
              child: Text(
                folderCount > 0 && fileCount > 0
                    ? '$folderCount 文件夹 · $fileCount 文件 (${formatBytes(totalFileBytes)})'
                    : '${dir.entries.length} 项',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          if (!filter.showingTrash)
            FilesViewToggleButton(
              fileView: prefs.fileView,
              onChanged: controller.setFileView,
            ),
          if (!filter.showingTrash && !filter.searching)
            FilesSortMenuButton(
              fileSort: prefs.fileSort,
              fileSortDirection: prefs.fileSortDirection,
              onSelected: controller.setFileSort,
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionToolbar(BuildContext context) {
    final selection = controller.selectionSnapshot;
    return FileSelectionToolbar(
      compact: compact,
      selectedCount: selection.count,
      hasLoadedEntries: selection.visiblePaths.isNotEmpty,
      allLoadedSelected: selection.allVisibleSelected,
      canWriteSelection: selection.writableSelection,
      canSaveFiles: selection.canExportFiles,
      busy: controller.dir.loading || controller.transfers.batchBusy,
      onToggleAll: controller.batch.toggleSelectAllVisible,
      onSave: () => unawaited(actions.batchSave(context)),
      onCopy: () => unawaited(actions.batchTransfer(context, 'copy')),
      onMove: () => unawaited(actions.batchTransfer(context, 'move')),
      onClear: controller.batch.clearSelectedPaths,
      onDone: controller.batch.exitSelectionMode,
      onTrash: () => unawaited(actions.batchTrash(context)),
    );
  }

  Widget _buildSurfaceBody(
    BuildContext context, {
    required ColorScheme colors,
    required bool desktopTable,
    required double gridHeightExtra,
  }) {
    final dir = controller.dir;
    final filter = controller.filter;
    final prefs = controller.prefs;

    if (dir.loading || (filter.showingTrash && filter.trashLoading)) {
      return const RepaintBoundary(child: LinearProgressIndicator(minHeight: 2));
    }
    if (filter.showingTrash) {
      if (filter.trashEntries.isEmpty) {
        return const FilesEmptyState(
          text: '回收站是空的。',
          icon: Icons.delete_outline,
        );
      }
      return RepaintBoundary(
        child: Column(
          children: filter.trashEntries
              .map(
                (entry) => FilesTrashTile(
                  item: entry,
                  compact: compact,
                  canPurge: controller.canPurgeTrashItem(entry),
                  onRestore: () =>
                      unawaited(actions.restoreTrashEntry(context, entry)),
                  onPurge: () =>
                      unawaited(actions.purgeTrashEntry(context, entry)),
                ),
              )
              .toList(),
        ),
      );
    }
    if (dir.entries.isEmpty) {
      if (filter.searching) {
        return FileSearchEmptyState(
          searchTerm: filter.searchTerm,
          searchKind: filter.searchKind,
          subdirLabel: controller.searchSubdirLabel,
          searchingSubdir:
              filter.searchScopeSubdir != null && !filter.searchEntireRoot,
          onResetKind: () => controller.setSearchKind(''),
          onExpandToRoot: () => controller.setSearchEntireRoot(true),
          onExitSearch: controller.exitSearchAndRestore,
        );
      }
      return FilesEmptyState(
        text: '此文件夹目前是空的。',
        icon: Icons.folder_open_outlined,
        showCreateActions: dir.canWrite,
        busy: dir.loading,
        uploadBusy: controller.transfers.uploadBusy,
        onUpload: () => unawaited(actions.chooseUploadSource(context)),
        onCreateFolder: () => unawaited(actions.createFolder(context)),
      );
    }

    return Column(
      children: [
        IsleModeSwitcher(
          modeKey:
              '${dir.rootName}:${dir.path}:${filter.searching}:${prefs.fileView}:$desktopTable',
          child: prefs.fileView == 'grid'
              ? Padding(
                  padding: EdgeInsets.all(compact ? 8 : 12),
                  child: RepaintBoundary(
                    child: GridView.builder(
                      key: const ValueKey('files-card-grid'),
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: compact
                            ? 152
                            : availableWidth < 960
                            ? 182
                            : 206,
                        mainAxisExtent:
                            (compact ? 156 : 180) + gridHeightExtra,
                        crossAxisSpacing: compact ? 8 : 11,
                        mainAxisSpacing: compact ? 8 : 11,
                      ),
                      itemCount: dir.entries.length,
                      itemBuilder: (context, index) =>
                          _buildItemCard(context, dir.entries[index]),
                    ),
                  ),
                )
              : RepaintBoundary(
                  child: Column(
                    children: dir.entries
                        .map(
                          (entry) => desktopTable
                              ? _buildDesktopRow(context, entry)
                              : _buildItemTile(context, entry),
                        )
                        .toList(),
                  ),
                ),
        ),
        if (filter.searchTruncated)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              '搜索结果已达到服务端上限，请缩小关键词。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
        if (dir.nextCursor.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(10),
            child: OutlinedButton.icon(
              onPressed: dir.loading
                  ? null
                  : () => unawaited(controller.loadFiles(more: true)),
              icon: const Icon(Icons.expand_more),
              label: const Text('加载更多文件'),
            ),
          ),
      ],
    );
  }

  Widget _buildDesktopRow(BuildContext context, FileEntry item) {
    final transfers = controller.transfers;
    return FilesDesktopTableRow(
      api: controller.api,
      item: item,
      writable: controller.canWriteItem(item),
      searching: controller.filter.searching,
      searchTerm: controller.filter.searchTerm,
      selecting: transfers.selecting,
      selected: transfers.selectedPaths.contains(item.path),
      highlighted: controller.dir.highlightedPath == item.path,
      highlightedItemKey: highlightedItemKey,
      loading: controller.dir.loading,
      downloading: transfers.downloading.contains(item.path),
      downloadProgress: transfers.downloadProgress[item.path],
      failedThumbnails: controller.dir.failedThumbnails,
      onTap: () => actions.openOrSelectEntry(context, item),
      onLongPress: () => controller.batch.startSelectingItem(item),
      onToggleSelected: (value) => controller.batch.toggleSelected(item, value),
      onAction: (action) => actions.dispatchFileAction(context, item, action),
      onSecondaryTapDown: (details) => unawaited(
        actions.showFileContextMenu(context, details.globalPosition, item),
      ),
    );
  }

  Widget _buildItemTile(BuildContext context, FileEntry item) {
    final transfers = controller.transfers;
    return FilesItemListTile(
      api: controller.api,
      item: item,
      compact: compact,
      writable: controller.canWriteItem(item),
      searching: controller.filter.searching,
      searchTerm: controller.filter.searchTerm,
      selecting: transfers.selecting,
      selected: transfers.selectedPaths.contains(item.path),
      highlighted: controller.dir.highlightedPath == item.path,
      highlightedItemKey: highlightedItemKey,
      loading: controller.dir.loading,
      downloading: transfers.downloading.contains(item.path),
      downloadProgress: transfers.downloadProgress[item.path],
      failedThumbnails: controller.dir.failedThumbnails,
      onTap: () => actions.openOrSelectEntry(context, item),
      onLongPress: () => controller.batch.startSelectingItem(item),
      onToggleSelected: (value) => controller.batch.toggleSelected(item, value),
      onAction: (action) => actions.dispatchFileAction(context, item, action),
      onSecondaryTapDown: (details) => unawaited(
        actions.showFileContextMenu(context, details.globalPosition, item),
      ),
    );
  }

  Widget _buildItemCard(BuildContext context, FileEntry item) {
    final transfers = controller.transfers;
    return FilesItemCard(
      api: controller.api,
      item: item,
      writable: controller.canWriteItem(item),
      searching: controller.filter.searching,
      searchTerm: controller.filter.searchTerm,
      selecting: transfers.selecting,
      selected: transfers.selectedPaths.contains(item.path),
      highlighted: controller.dir.highlightedPath == item.path,
      highlightedItemKey: highlightedItemKey,
      loading: controller.dir.loading,
      downloading: transfers.downloading.contains(item.path),
      downloadProgress: transfers.downloadProgress[item.path],
      failedThumbnails: controller.dir.failedThumbnails,
      onTap: () => actions.openOrSelectEntry(context, item),
      onLongPress: () => controller.batch.startSelectingItem(item),
      onToggleSelected: (value) => controller.batch.toggleSelected(item, value),
      onAction: (action) => actions.dispatchFileAction(context, item, action),
      onSecondaryTapDown: (details) => unawaited(
        actions.showFileContextMenu(context, details.globalPosition, item),
      ),
    );
  }
}
