import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'file_search_widgets.dart';
import 'files_controller.dart';
import 'files_ui_actions.dart';

class FilesHeader extends StatelessWidget {
  const FilesHeader({
    super.key,
    required this.controller,
    required this.compactEmbeddedHeader,
  });

  final FilesController controller;
  final bool compactEmbeddedHeader;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final showingTrash = controller.filter.showingTrash;
    final busy = controller.dir.loading || controller.filter.trashLoading;
    final refreshButton = IconButton(
      tooltip: showingTrash ? '刷新回收站' : '刷新目录',
      visualDensity: VisualDensity.compact,
      onPressed: busy
          ? null
          : () => unawaited(
              showingTrash ? controller.loadTrash() : controller.loadFiles(),
            ),
      icon: const Icon(Icons.refresh_rounded, size: 19),
    );
    if (compactEmbeddedHeader) {
      return Row(
        children: [
          Expanded(child: FilesBreadcrumbs(controller: controller)),
          const SizedBox(width: 4),
          refreshButton,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IslePageHeader(
          accentColor: palette['brandAmber'],
          title: showingTrash ? '回收站' : '文件',
          trailing: refreshButton,
        ),
        const SizedBox(height: 4),
        FilesBreadcrumbs(controller: controller),
      ],
    );
  }
}

class FilesBreadcrumbs extends StatelessWidget {
  const FilesBreadcrumbs({super.key, required this.controller});

  final FilesController controller;

  @override
  Widget build(BuildContext context) {
    final segments = controller.pathSegments;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final disabled = controller.dir.loading || controller.filter.showingTrash;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: IsleDecorations.recessedWell(context, radius: 11),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Icon(
              controller.filter.showingTrash
                  ? Icons.delete_outline_rounded
                  : Icons.folder_special_outlined,
              size: 15,
              color: palette['brandAmber'],
            ),
            const SizedBox(width: 4),
            for (var index = 0; index < segments.length; index++) ...[
              if (index > 0)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
              _FilesBreadcrumbSegment(
                segment: segments[index],
                active: index == segments.length - 1,
                onTap: disabled
                    ? null
                    : () => unawaited(
                        controller.loadFiles(target: segments[index].$2),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilesBreadcrumbSegment extends StatelessWidget {
  const _FilesBreadcrumbSegment({
    required this.segment,
    required this.active,
    required this.onTap,
  });

  final (String, String) segment;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = Text(
      segment.$1,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.8,
        color: active ? colors.onSurface : colors.primary,
        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width < 360 ? 112 : 200,
      ),
      child: Tooltip(
        message: segment.$1,
        child: active
            ? Semantics(
                label: '当前位置：${segment.$1}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 3,
                  ),
                  child: label,
                ),
              )
            : TextButton(
                onPressed: onTap,
                style: TextButton.styleFrom(
                  minimumSize: const Size(28, 26),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: label,
              ),
      ),
    );
  }
}

class FilesToolbar extends StatelessWidget {
  const FilesToolbar({
    super.key,
    required this.controller,
    required this.actions,
    required this.compact,
    required this.availableWidth,
  });

  final FilesController controller;
  final FilesUiActions actions;
  final bool compact;
  final double availableWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final iconActions = IsleLayout.compactToolbar(availableWidth, textScale);
    final filter = controller.filter;
    final dir = controller.dir;
    final transfers = controller.transfers;
    final singleRowToolbar =
        !filter.showingTrash && availableWidth >= 600 && textScale <= 1.35;

    final searchField = Row(
      children: [
        Expanded(
          child: IsleSearchBar(
            controller: filter.searchController,
            focusNode: filter.searchFocusNode,
            enabled: !dir.loading,
            hintText: filter.searchViaSpotlight ? '全文搜索文件名或正文' : '搜索文件',
            showClear: filter.searching,
            onChanged: (_) => controller.notifySearchQueryChanged(),
            onSubmitted: (_) => unawaited(controller.searchFiles()),
            onClear: dir.loading
                ? null
                : () {
                    if (filter.searching) {
                      controller.exitSearchAndRestore();
                    } else {
                      unawaited(controller.searchFiles());
                    }
                  },
          ),
        ),
        const SizedBox(width: 6),
        FilterChip(
          key: const ValueKey('filesSpotlightToggle'),
          label: const Text('全文搜索', style: TextStyle(fontSize: 12)),
          tooltip: '使用 Spotlight 全文检索文件内容',
          visualDensity: VisualDensity.compact,
          side: BorderSide(
            color: filter.searchViaSpotlight
                ? colors.primary.withValues(alpha: 0.45)
                : borderColor,
            width: 1.0,
          ),
          selected: filter.searchViaSpotlight,
          onSelected: dir.loading ? null : controller.setSearchViaSpotlight,
        ),
      ],
    );

    final actionsRow = Row(
      mainAxisSize: singleRowToolbar ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (filter.showingTrash)
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => unawaited(controller.toggleTrash()),
            icon: const Icon(Icons.arrow_back_rounded, size: 17),
            label: const Text('返回文件'),
          )
        else if (dir.canWrite && iconActions)
          IconButton.filled(
            tooltip: '上传文件',
            visualDensity: VisualDensity.compact,
            onPressed: dir.loading || transfers.uploadBusy
                ? null
                : () => unawaited(actions.chooseUploadSource(context)),
            icon: const Icon(Icons.add_rounded, size: 19),
          )
        else if (dir.canWrite)
          FilledButton.icon(
            onPressed: dir.loading || transfers.uploadBusy
                ? null
                : () => unawaited(actions.chooseUploadSource(context)),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('上传文件'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(36, 34),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (!filter.showingTrash && dir.canWrite) ...[
          const SizedBox(width: 6),
          if (compact || iconActions)
            IconButton(
              tooltip: '新建文件夹',
              visualDensity: VisualDensity.compact,
              onPressed: dir.loading
                  ? null
                  : () => unawaited(actions.createFolder(context)),
              icon: const Icon(Icons.create_new_folder_outlined, size: 19),
            )
          else
            OutlinedButton.icon(
              onPressed: dir.loading
                  ? null
                  : () => unawaited(actions.createFolder(context)),
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: const Text('新建文件夹'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(36, 34),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
        if (!singleRowToolbar) const Spacer() else const SizedBox(width: 4),
        if (!filter.showingTrash) ...[
          IconButton(
            key: const Key('files-select-toggle'),
            tooltip: transfers.selecting ? '结束多选' : '多选文件',
            visualDensity: VisualDensity.compact,
            onPressed: dir.loading || transfers.batchBusy
                ? null
                : controller.batch.toggleSelectingMode,
            icon: Icon(
              transfers.selecting
                  ? Icons.close_rounded
                  : Icons.checklist_rounded,
              size: 19,
            ),
            color: transfers.selecting ? colors.primary : null,
          ),
          _FilesMoreActionsMenu(
            controller: controller,
            actions: actions,
            borderColor: borderColor,
          ),
        ],
      ],
    );

    final showHistory =
        !filter.showingTrash &&
        filter.recentSearches.isNotEmpty &&
        ((filter.searchInputFocused &&
                filter.searchController.text.trim().isEmpty) ||
            (filter.searching && dir.entries.isEmpty));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (singleRowToolbar)
          Row(
            children: [
              Expanded(child: searchField),
              const SizedBox(width: 8),
              actionsRow,
            ],
          )
        else ...[
          if (!filter.showingTrash) searchField,
          const SizedBox(height: 6),
          actionsRow,
        ],
        if (showHistory)
          FileSearchHistoryStrip(
            terms: filter.recentSearches,
            busy: dir.loading,
            onTapTerm: controller.applySearchTerm,
            onRemoveTerm: (term) =>
                unawaited(controller.preferences.removeSearchHistory(term)),
            onClearAll: () =>
                unawaited(controller.preferences.clearSearchHistory()),
          ),
      ],
    );
  }
}

class _FilesMoreActionsMenu extends StatelessWidget {
  const _FilesMoreActionsMenu({
    required this.controller,
    required this.actions,
    required this.borderColor,
  });

  final FilesController controller;
  final FilesUiActions actions;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多文件操作',
      icon: const Icon(Icons.more_horiz_rounded, size: 19),
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 206, maxWidth: 260),
      shape: IsleShapes.md(side: BorderSide(color: borderColor, width: 1.0)),
      elevation: 4,
      onSelected: (value) {
        switch (value) {
          case 'downloads':
            unawaited(actions.openDownloads(context));
          case 'offlineVault':
            unawaited(actions.openOfflineVault(context));
          case 'duplicates':
            unawaited(actions.openDuplicates(context));
          case 'trash':
            unawaited(controller.toggleTrash());
          case 'dav':
            actions.openWebDavMount(context);
          case 'smb':
            actions.openSmbMount(context);
          case 'rename':
            actions.toggleUploadAutoRenameWithFeedback(context);
        }
      },
      itemBuilder: (_) => [
        isleActionMenuItem(
          value: 'trash',
          icon: Icons.delete_outline_rounded,
          label: '回收站',
        ),
        isleActionMenuItem(
          value: 'downloads',
          icon: Icons.download_outlined,
          label: '下载中心',
        ),
        isleActionMenuItem(
          value: 'offlineVault',
          icon: Icons.offline_pin_outlined,
          label: '离线文件箱',
        ),
        isleActionMenuItem(
          value: 'duplicates',
          icon: Icons.cleaning_services_outlined,
          label: '重复大文件清理',
        ),
        const PopupMenuDivider(),
        isleActionMenuItem(
          value: 'dav',
          icon: Icons.laptop_mac_outlined,
          label: '挂载到电脑（WebDAV）',
        ),
        if (controller.isAdmin)
          isleActionMenuItem(
            value: 'smb',
            icon: Icons.dns_outlined,
            label: 'Mac 文件共享（SMB）',
          ),
        if (controller.dir.canWrite) const PopupMenuDivider(),
        if (controller.dir.canWrite)
          isleActionMenuItem(
            value: 'rename',
            icon: Icons.drive_file_rename_outline_rounded,
            label: '上传时同名自动改名',
            checked: controller.prefs.uploadAutoRename,
          ),
      ],
    );
  }
}

class FilesViewToggleButton extends StatelessWidget {
  const FilesViewToggleButton({
    super.key,
    required this.fileView,
    required this.onChanged,
  });

  final String fileView;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final isGrid = fileView == 'grid';
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: isGrid ? '切换列表视图' : '切换卡片视图',
      onPressed: () => onChanged(isGrid ? 'list' : 'grid'),
      icon: Icon(
        isGrid ? Icons.view_list_rounded : Icons.grid_view_rounded,
        size: 19,
      ),
    );
  }
}

class FilesSortMenuButton extends StatelessWidget {
  const FilesSortMenuButton({
    super.key,
    required this.fileSort,
    required this.fileSortDirection,
    required this.onSelected,
  });

  final String fileSort;
  final String fileSortDirection;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      tooltip: '文件排序方式',
      icon: const Icon(Icons.sort_rounded, size: 19),
      onSelected: onSelected,
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'name:asc',
          checked: fileSort == 'name' && fileSortDirection == 'asc',
          child: const Text('名称 · 升序'),
        ),
        CheckedPopupMenuItem(
          value: 'name:desc',
          checked: fileSort == 'name' && fileSortDirection == 'desc',
          child: const Text('名称 · 降序'),
        ),
        CheckedPopupMenuItem(
          value: 'mtime:desc',
          checked: fileSort == 'mtime' && fileSortDirection == 'desc',
          child: const Text('修改时间 · 最新优先'),
        ),
        CheckedPopupMenuItem(
          value: 'mtime:asc',
          checked: fileSort == 'mtime' && fileSortDirection == 'asc',
          child: const Text('修改时间 · 最早优先'),
        ),
        CheckedPopupMenuItem(
          value: 'size:desc',
          checked: fileSort == 'size' && fileSortDirection == 'desc',
          child: const Text('文件大小 · 从大到小'),
        ),
        CheckedPopupMenuItem(
          value: 'size:asc',
          checked: fileSort == 'size' && fileSortDirection == 'asc',
          child: const Text('文件大小 · 从小到大'),
        ),
      ],
    );
  }
}
