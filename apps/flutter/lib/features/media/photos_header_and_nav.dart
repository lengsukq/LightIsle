import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../files/backup_status_pill.dart';
import 'media_ui.dart';
import 'photo_ai_models.dart';
import 'photos_controller.dart';

/// Top header bar for [PhotosPage], containing mobile backup status, search,
/// multi-select toggle, media upload, and overflow actions.
class PhotosPageHeader extends StatelessWidget {
  const PhotosPageHeader({
    required this.api,
    required this.accountName,
    required this.backupDirectory,
    required this.canBackup,
    required this.isAdmin,
    required this.pageInset,
    required this.controller,
    required this.onOpenMobileBackup,
    required this.onUpload,
    required this.onMenuAction,
    super.key,
  });

  final LightIsleApi api;
  final String accountName;
  final String backupDirectory;
  final bool canBackup;
  final bool isAdmin;
  final double pageInset;
  final PhotosController controller;
  final Future<void> Function() onOpenMobileBackup;
  final VoidCallback onUpload;
  final ValueChanged<String> onMenuAction;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        pageInset,
        IsleLayout.pageTopInset(MediaQuery.sizeOf(context).width),
        pageInset,
        4,
      ),
      child: IslePageHeader(
        accentColor: palette['brandRose'],
        title: '图库',
        subtitle: controller.headerSubtitle,
        trailing: _buildTrailingActions(context),
      ),
    );
  }

  Widget _buildTrailingActions(BuildContext context) {
    final isMobilePlatform =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final selecting = controller.selection.selecting;
    final batchBusy = controller.selection.batchBusy;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isMobilePlatform) ...[
          PhotoBackupStatusPill(
            key: const ValueKey('photoBackupStatusPill'),
            api: api,
            accountName: accountName,
            baseDirectory: backupDirectory,
            canBackup: canBackup,
            onTap: onOpenMobileBackup,
          ),
          const SizedBox(width: 4),
        ],
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '搜索照片',
          onPressed: controller.toggleSearchBar,
          icon: const Icon(Icons.search_rounded, size: 19),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: selecting ? '退出选择' : '选择照片',
          onPressed: batchBusy ? null : controller.toggleSelectionMode,
          icon: Icon(
            selecting ? Icons.close_rounded : Icons.checklist_rounded,
            size: 19,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '上传照片与视频',
          onPressed: onUpload,
          icon: const Icon(Icons.add_rounded, size: 20),
        ),
        _buildOverflowMenuButton(context, isMobilePlatform: isMobilePlatform),
      ],
    );
  }

  Widget _buildOverflowMenuButton(
    BuildContext context, {
    required bool isMobilePlatform,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      tooltip: '更多照片操作',
      icon: const Icon(Icons.more_horiz_rounded, size: 19),
      onSelected: onMenuAction,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 208, maxWidth: 260),
      shape: IsleShapes.md(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      itemBuilder: (_) => _buildOverflowMenuItems(
        isMobilePlatform: isMobilePlatform,
      ),
    );
  }

  List<PopupMenuEntry<String>> _buildOverflowMenuItems({
    required bool isMobilePlatform,
  }) {
    final scope = controller.scope;
    final comfortableGrid = controller.feed.comfortableGrid;
    final catalogBusy = controller.catalog.busy;
    final scanning = controller.scan.scanning;

    return [
      isleActionMenuItem(
        value: 'gridDensity',
        icon: comfortableGrid
            ? Icons.grid_on_rounded
            : Icons.grid_view_rounded,
        label: comfortableGrid ? '切换为紧凑网格' : '切换为舒适视图',
      ),
      if (controller.isFullTimelineSelected &&
          scope.query.isEmpty &&
          scope.mediaType.isEmpty)
        isleActionMenuItem(
          value: 'month',
          icon: Icons.calendar_month_outlined,
          label: '年月跳转',
        ),
      isleActionMenuItem(
        value: 'map',
        icon: Icons.map_outlined,
        label: '足迹地图',
      ),
      isleActionMenuItem(
        value: 'documentArchive',
        icon: Icons.document_scanner_outlined,
        label: '家庭档案与扫票据',
      ),
      isleActionMenuItem(
        value: 'similarCleanup',
        icon: Icons.auto_fix_high_outlined,
        label: '连拍相似清理',
      ),
      isleActionMenuItem(
        value: 'offline',
        icon: Icons.offline_pin_outlined,
        label: '本机离线照片库',
      ),
      isleActionMenuItem(
        value: 'today',
        icon: Icons.history_rounded,
        label: '那年今天',
      ),
      isleActionMenuItem(
        value: 'sharedFavorites',
        icon: Icons.star_border_rounded,
        label: '共享收藏',
      ),
      isleActionMenuItem(
        value: 'files',
        icon: Icons.folder_open_outlined,
        label: '管理照片文件',
      ),
      const PopupMenuDivider(),
      isleActionMenuItem(
        value: 'all',
        icon: Icons.perm_media_outlined,
        label: '照片与视频',
        checked: scope.mediaType.isEmpty,
      ),
      isleActionMenuItem(
        value: 'photo',
        icon: Icons.photo_outlined,
        label: '仅照片',
        checked: scope.mediaType == 'photo',
      ),
      isleActionMenuItem(
        value: 'live',
        icon: Icons.motion_photos_on_outlined,
        label: '实况照片 (Live)',
        checked: scope.mediaType == 'live',
      ),
      isleActionMenuItem(
        value: 'video',
        icon: Icons.videocam_outlined,
        label: '仅视频',
        checked: scope.mediaType == 'video',
      ),
      if (controller.currentPrivateAlbum != null) ...[
        isleActionMenuItem(
          value: 'renamePrivate',
          enabled: !catalogBusy,
          icon: Icons.drive_file_rename_outline,
          label: '重命名私人相册',
        ),
        isleActionMenuItem(
          value: 'deletePrivate',
          enabled: !catalogBusy,
          icon: Icons.delete_outline_rounded,
          label: '删除私人相册',
        ),
      ],
      if (isAdmin && controller.currentAlbum != null) ...[
        isleActionMenuItem(
          value: 'renameShared',
          enabled: !catalogBusy,
          icon: Icons.drive_file_rename_outline,
          label: '重命名相册',
        ),
        isleActionMenuItem(
          value: 'deleteShared',
          enabled: !catalogBusy,
          icon: Icons.delete_outline_rounded,
          label: '删除相册',
        ),
      ],
      if (canBackup && isMobilePlatform)
        isleActionMenuItem(
          value: 'backup',
          icon: Icons.cloud_upload_outlined,
          label: '手机照片备份',
        ),
      const PopupMenuDivider(),
      isleActionMenuItem(
        value: 'refresh',
        icon: Icons.refresh_rounded,
        label: '刷新图库',
      ),
      if (isAdmin)
        isleActionMenuItem(
          value: 'scan',
          enabled: !scanning,
          icon: Icons.sync_rounded,
          label: scanning ? '扫描中' : '扫描媒体',
        ),
    ];
  }
}

/// Horizontal collection/filter chip strip, expandable AI search bar, and
/// active filter summary banner for [PhotosPage].
class PhotosNavigationSection extends StatelessWidget {
  const PhotosNavigationSection({
    required this.controller,
    required this.pageInset,
    required this.onBrowseAlbums,
    required this.onOpenPeople,
    required this.onOpenExifFilter,
    this.onOpenDocumentArchive,
    super.key,
  });

  static const double _wideNavBreakpoint = 960.0;

  final PhotosController controller;
  final double pageInset;
  final VoidCallback onBrowseAlbums;
  final VoidCallback onOpenPeople;
  final VoidCallback onOpenExifFilter;
  final VoidCallback? onOpenDocumentArchive;

  @override
  Widget build(BuildContext context) {
    final scope = controller.scope;
    return Padding(
      padding: EdgeInsets.fromLTRB(pageInset, 0, pageInset, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildNavigationChipStrip(context),
          if (controller.currentPrivateAlbum != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '私人相册 · 仅当前账号可见',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          _buildExpandableSearchBar(context),
          IsleAnimatedExpand(
            expanded: scope.hasActiveQueryOrFacets,
            child: _buildActiveFilterSummary(context),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationChipStrip(BuildContext context) {
    final scope = controller.scope;
    final selectedAlbum =
        controller.currentPrivateAlbum ?? controller.currentAlbum;
    final wide = MediaQuery.sizeOf(context).width >= _wideNavBreakpoint;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          MediaFilterChip(
            label: '全部照片',
            selected: scope.isUnscopedCollection,
            onSelected: () => unawaited(controller.selectView()),
          ),
          const SizedBox(width: 6),
          MediaFilterChip(
            label: scope.activeFolderName.isNotEmpty
                ? scope.activeFolderName
                : selectedAlbum == null
                ? '相册'
                : selectedAlbum.name,
            selected: selectedAlbum != null || scope.activeFolderPath.isNotEmpty,
            icon: Icons.photo_album_outlined,
            onSelected: onBrowseAlbums,
            onDeleted: selectedAlbum != null || scope.activeFolderPath.isNotEmpty
                ? () => unawaited(controller.selectView())
                : null,
          ),
          const SizedBox(width: 6),
          MediaFilterChip(
            label: '我的收藏',
            icon: Icons.star_outline,
            selected: scope.personalFavoritesOnly,
            onSelected: () => unawaited(
              controller.selectView(
                personalFavorites: !scope.personalFavoritesOnly,
              ),
            ),
          ),
          const SizedBox(width: 6),
          MediaFilterChip(
            label: scope.activePersonId > 0 ? scope.activePersonName : '人物',
            icon: Icons.face_retouching_natural_outlined,
            selected: scope.activePersonId > 0,
            onSelected: onOpenPeople,
            onDeleted: scope.activePersonId > 0
                ? () => unawaited(controller.selectView())
                : null,
          ),
          const SizedBox(width: 6),
          _ActionPillChip(
            tooltip: '按相机型号、定位、年份筛选',
            icon: Icons.tune_rounded,
            label: '筛选',
            onPressed: onOpenExifFilter,
          ),
          if (onOpenDocumentArchive != null) ...[
            const SizedBox(width: 6),
            _ActionPillChip(
              key: const ValueKey('photosDocumentArchiveChip'),
              tooltip: '扫描证件票据与离线 Vision OCR 秒搜',
              icon: Icons.document_scanner_outlined,
              label: '家庭档案',
              onPressed: onOpenDocumentArchive!,
            ),
          ],
          if (wide) ...[
            const SizedBox(width: 10),
            Container(
              width: 1,
              height: 18,
              color: IsleGlass.rimBorderColor(
                Theme.of(context).brightness == Brightness.dark,
              ),
            ),
            const SizedBox(width: 10),
            MediaFilterChip(
              label: '实况 Live',
              icon: Icons.motion_photos_on_outlined,
              selected: scope.mediaType == 'live',
              onSelected: () => controller.toggleMediaType('live'),
            ),
            const SizedBox(width: 6),
            MediaFilterChip(
              label: '仅视频',
              icon: Icons.videocam_outlined,
              selected: scope.mediaType == 'video',
              onSelected: () => controller.toggleMediaType('video'),
            ),
          ],
          ..._buildActiveFacetChips(context, wide: wide),
        ],
      ),
    );
  }

  List<Widget> _buildActiveFacetChips(
    BuildContext context, {
    required bool wide,
  }) {
    final scope = controller.scope;
    final style = IsleThemeStyle.of(context);
    final borderColor = style.rimBorderColor();
    final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;

    Widget facetChip(String text, VoidCallback onClear) => InputChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: isSharp ? style.shapeFor(IsleRadius.sm) : const StadiumBorder(),
      side: BorderSide(color: borderColor, width: style.effectiveBorderWidth()),
      label: Text(text, style: const TextStyle(fontSize: 12)),
      onDeleted: onClear,
    );

    return [
      if (scope.cameraFilter.isNotEmpty) ...[
        const SizedBox(width: 6),
        facetChip(scope.cameraFilter, controller.clearCameraFilter),
      ],
      if (scope.locationFilter.isNotEmpty) ...[
        const SizedBox(width: 6),
        facetChip(
          scope.locationFilter == '1' ? '含定位' : '无定位',
          controller.clearLocationFilter,
        ),
      ],
      if (scope.yearFilter > 0) ...[
        const SizedBox(width: 6),
        facetChip('${scope.yearFilter} 年', controller.clearYearFilter),
      ],
      if (scope.takenFromFilter > 0 || scope.takenToFilter > 0) ...[
        const SizedBox(width: 6),
        facetChip(
          formatPhotoCustomDateRange(
            scope.takenFromFilter,
            scope.takenToFilter,
          ),
          controller.clearDateRangeFilter,
        ),
      ],
      if (scope.favoritesOnly ||
          scope.onThisDay ||
          (scope.mediaType.isNotEmpty && !wide)) ...[
        const SizedBox(width: 6),
        facetChip(
          scope.favoritesOnly
              ? '共享收藏'
              : scope.onThisDay
              ? '那年今天'
              : scope.mediaType == 'photo'
              ? '仅照片'
              : scope.mediaType == 'live'
              ? '实况照片'
              : '仅视频',
          controller.clearSpecialScopeOrMediaType,
        ),
      ],
    ];
  }

  Widget _buildExpandableSearchBar(BuildContext context) {
    final scope = controller.scope;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);

    return IsleAnimatedExpand(
      expanded: scope.showSearch,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IsleSearchBar(
              controller: scope.searchController,
              autofocus: true,
              maxLength: 64,
              hintText: scope.searchMode.hintText,
              showClear: true,
              clearTooltip: '关闭搜索',
              onChanged: controller.onSearchQueryChanged,
              onClear: controller.clearAndCloseSearch,
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final mode in PhotoSearchMode.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: const StadiumBorder(),
                        side: BorderSide(
                          color: scope.searchMode == mode
                              ? colors.primary.withValues(alpha: 0.45)
                              : borderColor,
                          width: 1.0,
                        ),
                        label: Text(
                          mode.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: scope.searchMode == mode,
                        onSelected: (_) => controller.setSearchMode(mode),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveFilterSummary(BuildContext context) {
    final scope = controller.scope;
    final parts = <String>[
      if (scope.query.isNotEmpty) '关键词 “${scope.query}”',
      if (scope.cameraFilter.isNotEmpty) scope.cameraFilter,
      if (scope.locationFilter.isNotEmpty)
        scope.locationFilter == '1' ? '含定位' : '无定位',
      if (scope.yearFilter > 0) '${scope.yearFilter} 年',
      if (scope.takenFromFilter > 0 || scope.takenToFilter > 0)
        formatPhotoCustomDateRange(scope.takenFromFilter, scope.takenToFilter),
      if (scope.mediaType == 'photo') '仅照片',
      if (scope.mediaType == 'live') '实况照片',
      if (scope.mediaType == 'video') '仅视频',
    ];
    final theme = Theme.of(context);
    final rose = IslePalette.of(context)['brandRose'];

    return Container(
      key: const Key('photoFilterSummaryBanner'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: IsleDecorations.recessedWell(context, radius: 10),
      child: Row(
        children: [
          Icon(Icons.filter_alt_outlined, size: 15, color: rose),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '当前筛选：${parts.join(' · ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: controller.clearSearchAndFacets,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 26),
              padding: const EdgeInsets.symmetric(horizontal: 7),
            ),
            child: const Text('清除条件', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ActionPillChip extends StatelessWidget {
  const _ActionPillChip({
    super.key,
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;
    final isBrutal =
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;

    return ActionChip(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: isBrutal
          ? palette['cardTop']
          : isDark
          ? palette['cardItemTop'].withValues(alpha: 0.85)
          : palette['cardTop'].withValues(alpha: 0.95),
      side: BorderSide(
        color: style.rimBorderColor(),
        width: isBrutal ? 1.5 : 1.0,
      ),
      shape: isSharp ? style.shapeFor(IsleRadius.sm) : const StadiumBorder(),
      avatar: Icon(icon, size: 15, color: colors.onSurfaceVariant),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: colors.onSurface,
        ),
      ),
      onPressed: onPressed,
    );
  }
}

/// Formats a Unix-second custom taken-date filter range for display in facet
/// chips and filter summaries.
String formatPhotoCustomDateRange(int takenFrom, int takenTo) {
  String fmt(int sec) {
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000).toLocal();
    return '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
  }

  if (takenFrom > 0 && takenTo > 0) {
    return '${fmt(takenFrom)}–${fmt(takenTo)}';
  }
  if (takenFrom > 0) return '${fmt(takenFrom)} 起';
  return '至 ${fmt(takenTo)}';
}
