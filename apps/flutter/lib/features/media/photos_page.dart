import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_action_menu.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/isle_data_cache.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/backup_status_pill.dart';
import '../files/files_page.dart';
import '../files/mobile_photo_backup_page.dart';
import '../files/upload_task_center.dart';
import '../settings/storage_page.dart';
import 'folder_albums_page.dart';
import 'media_batch_operations.dart';
import 'media_models.dart';
import 'media_page_result.dart';
import 'media_scan_poller.dart';
import 'media_ui.dart';
import 'offline_photos_page.dart';
import 'photo_ai_models.dart';
import 'photo_album_repository.dart';
import 'photo_detail_dialog.dart';
import 'photo_gallery_viewer.dart';
import 'photo_map_page.dart';
import 'photo_people_section.dart';
import 'photo_similar_cleanup_sheet.dart';
import 'photo_timeline_scrubber.dart';
import 'photos_page_state_models.dart';
export 'photo_detail_dialog.dart' show PhotoDetailDialog;

part 'photos_page_ai.dart';
part 'photos_page_batch_actions.dart';
part 'photos_page_album_management.dart';
part 'photos_page_album_overview.dart';
part 'photos_page_library.dart';
part 'photos_page_navigation.dart';

class PhotosPage extends StatefulWidget {
  const PhotosPage({
    required this.api,
    required this.isAdmin,
    this.accountName = '',
    this.offlineAccountId = '',
    this.backupDirectory = 'PhonePhotos',
    this.canBackup = false,
    this.hasOtherRoots = false,
    this.taskCenter,
    this.uploadDirectory = '图库',
    super.key,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final String offlineAccountId;
  final String backupDirectory;
  final bool canBackup;
  final bool hasOtherRoots;
  final UploadTaskCenter? taskCenter;
  final String uploadDirectory;

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> with WidgetsBindingObserver {
  static const int _pageSize = 48;

  final PhotosTimelineState _timeline = PhotosTimelineState();
  final PhotosAlbumCatalogState _catalog = PhotosAlbumCatalogState();
  final PhotosFilterScopeState _scope = PhotosFilterScopeState();
  final PhotosSelectionState _selection = PhotosSelectionState();
  final PhotosLibraryFeedState _feed = PhotosLibraryFeedState();
  final PhotosScanRuntimeState _scan = PhotosScanRuntimeState();
  late final MediaScanPoller _scanPoller = MediaScanPoller(
    onPoll: () => unawaited(_refreshStatus()),
  );

  void _updateState(VoidCallback fn) => setState(fn);

  PhotoAlbumRepository get _albumRepository => PhotoAlbumRepository(widget.api);
  MediaImageMemoryCache get _photoCache =>
      IsleCacheManager.instance.sharedThumbnails;

  MediaAlbum? get _currentAlbum => _catalog.findShared(_scope.activeAlbum);
  MediaAlbum? get _currentPrivateAlbum =>
      _catalog.findPrivate(_scope.activePrivateAlbum);

  /// Page-level inset aligns the content while the grid stays full-bleed.
  double get _pageInset =>
      IsleLayout.pageInset(MediaQuery.sizeOf(context).width);

  @override
  void initState() {
    super.initState();
    _loadAssets(reset: true);
    _refreshAlbums();
    _refreshPrivateAlbums();
    unawaited(_refreshFolderAlbums());
    unawaited(_refreshTimelineIndex());
    unawaited(_refreshFacets());
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _feed.generation++;
    _catalog.cancelPending();
    _scan.generation++;
    _scanPoller.dispose();
    _timeline.dispose();
    _scope.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scan.tabEnabled = TickerMode.valuesOf(context).enabled;
    _updatePollingState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _scan.appForeground = state == AppLifecycleState.resumed;
    _updatePollingState();
  }

  void _updatePollingState() {
    final active = _scan.shouldPoll;
    if (!_scanPoller.setActive(active)) return;
    if (!active) {
      _scan.generation++;
    } else {
      _refreshStatus();
    }
  }

  bool _onViewportScrollNotification(ScrollNotification notification) {
    // Near-endless scroll: paging fires automatically as the viewport
    // approaches the sentinel; the manual button stays as the fallback.
    if (notification is ScrollUpdateNotification &&
        (notification.scrollDelta ?? 0) > 0 &&
        notification.metrics.axis == Axis.vertical &&
        notification.depth == 0 &&
        notification.metrics.extentAfter < 650 &&
        _feed.nextCursor > 0 &&
        !_feed.loading &&
        !_feed.loadingMore &&
        _feed.loadError == null) {
      _loadAssets(reset: false);
    }
    return false;
  }

  Future<void> _refreshAllSources() async {
    await Future.wait([
      _loadAssets(reset: true),
      _refreshAlbums(),
      _refreshPrivateAlbums(),
      _refreshFolderAlbums(),
      _refreshTimelineIndex(),
      _refreshFacets(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop:
          !_selection.selecting && !_scope.showSearch && _fullTimelineSelected,
      onPopInvokedWithResult: _handleSystemBack,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onViewportScrollNotification,
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _refreshAllSources,
              child: CustomScrollView(
                key: PageStorageKey<String>(
                  'photos:${widget.api.selectedRoot?.identity ?? 'default'}',
                ),
                physics: const AlwaysScrollableScrollPhysics(),
                controller: _timeline.scrollController,
                slivers: [
                  _buildTopChromeSliver(context),
                  _buildGrid(),
                  _buildPaginationFooterSliver(context),
                ],
              ),
            ),
            if (_shouldShowTimelineScrubber)
              _buildTimelineScrubberOverlay(context),
          ],
        ),
      ),
    );
  }

  bool get _shouldShowTimelineScrubber =>
      _fullTimelineSelected &&
      !_selection.selecting &&
      _timeline.months.length > 1 &&
      _feed.assets.isNotEmpty;

  Widget _buildTopChromeSliver(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPageHeader(context),
          _photoNavigation(),
          if (_fullTimelineSelected &&
              _feed.assets.isNotEmpty &&
              !_selection.selecting)
            _buildMemoriesCarousel(),
          _buildSelectionToolbar(),
          _buildStatusBanners(),
        ],
      ),
    );
  }

  String get _headerSubtitle {
    if (_scope.activePersonId > 0) {
      return '人物 · ${_scope.activePersonName}';
    }
    if (_scope.activeFolderName.isNotEmpty) {
      return _scope.activeFolderName;
    }
    final activeAlbumName = _currentPrivateAlbum?.name ?? _currentAlbum?.name;
    if (activeAlbumName != null) return activeAlbumName;
    if (_scope.personalFavoritesOnly) return '我的收藏';
    if (_scope.favoritesOnly) return '共享收藏';
    if (_scope.onThisDay) return '那年今天';
    return '按时间整理的照片和视频';
  }

  Widget _buildPageHeader(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _pageInset,
        IsleLayout.pageTopInset(MediaQuery.sizeOf(context).width),
        _pageInset,
        0,
      ),
      child: IslePageHeader(
        title: '图库',
        hideSubtitleOnCompact: _fullTimelineSelected,
        subtitle: _headerSubtitle,
        trailing: _buildHeaderTrailingActions(),
      ),
    );
  }

  Widget _buildHeaderTrailingActions() {
    final isMobilePlatform =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isMobilePlatform) ...[
          PhotoBackupStatusPill(
            key: const ValueKey('photoBackupStatusPill'),
            api: widget.api,
            accountName: widget.accountName,
            baseDirectory: widget.backupDirectory,
            canBackup: widget.canBackup,
            onTap: _openMobilePhotoBackup,
          ),
          const SizedBox(width: 4),
        ],
        IconButton(
          key: const ValueKey('photoGridDensityToggle'),
          visualDensity: VisualDensity.compact,
          tooltip: _feed.comfortableGrid ? '切换为紧凑网格' : '切换为舒适视图',
          onPressed: () =>
              setState(() => _feed.comfortableGrid = !_feed.comfortableGrid),
          icon: Icon(
            _feed.comfortableGrid
                ? Icons.grid_on_rounded
                : Icons.grid_view_rounded,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: _selection.selecting ? '退出选择' : '选择照片',
          onPressed: _selection.batchBusy
              ? null
              : () => setState(() {
                  _selection.selecting = !_selection.selecting;
                  _selection.selectedAssets.clear();
                }),
          icon: Icon(
            _selection.selecting
                ? Icons.close_rounded
                : Icons.checklist_rounded,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '搜索照片',
          onPressed: () =>
              setState(() => _scope.showSearch = !_scope.showSearch),
          icon: const Icon(Icons.search_rounded),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '上传照片与视频',
          onPressed: _upload,
          icon: const Icon(Icons.add_rounded),
        ),
        _buildOverflowMenuButton(),
      ],
    );
  }

  Widget _buildOverflowMenuButton() {
    return PopupMenuButton<String>(
      tooltip: '更多照片操作',
      onSelected: _photoAction,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 218, maxWidth: 270),
      shape: IsleShapes.menu(),
      itemBuilder: (_) => _buildOverflowMenuItems(),
    );
  }

  List<PopupMenuEntry<String>> _buildOverflowMenuItems() {
    final isMobilePlatform =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return [
      isleActionMenuItem(
        value: 'select',
        icon: _selection.selecting
            ? Icons.close_rounded
            : Icons.checklist_rounded,
        label: _selection.selecting ? '结束多选' : '多选照片',
      ),
      const PopupMenuDivider(),
      isleActionMenuItem(
        value: 'offline',
        icon: Icons.offline_pin_outlined,
        label: '本机离线照片库',
      ),
      if (_currentPrivateAlbum == null && _currentAlbum == null) ...[
        isleActionMenuItem(
          value: 'people',
          icon: Icons.face_retouching_natural_outlined,
          label: '人物相册',
        ),
        isleActionMenuItem(
          value: 'similarCleanup',
          icon: Icons.auto_fix_high_outlined,
          label: '连拍与相似清理',
        ),
      ],
      isleActionMenuItem(
        value: 'map',
        icon: Icons.map_outlined,
        label: '地图回溯',
      ),
      if (_fullTimelineSelected &&
          _scope.query.isEmpty &&
          _scope.mediaType.isEmpty)
        isleActionMenuItem(
          value: 'month',
          icon: Icons.calendar_month_outlined,
          label: '年月跳转',
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
        checked: _scope.mediaType.isEmpty,
      ),
      isleActionMenuItem(
        value: 'photo',
        icon: Icons.photo_outlined,
        label: '仅照片',
        checked: _scope.mediaType == 'photo',
      ),
      isleActionMenuItem(
        value: 'live',
        icon: Icons.motion_photos_on_outlined,
        label: '实况照片 (Live)',
        checked: _scope.mediaType == 'live',
      ),
      isleActionMenuItem(
        value: 'video',
        icon: Icons.videocam_outlined,
        label: '仅视频',
        checked: _scope.mediaType == 'video',
      ),
      if (_currentPrivateAlbum != null) ...[
        isleActionMenuItem(
          value: 'renamePrivate',
          enabled: !_catalog.busy,
          icon: Icons.drive_file_rename_outline,
          label: '重命名私人相册',
        ),
        isleActionMenuItem(
          value: 'deletePrivate',
          enabled: !_catalog.busy,
          icon: Icons.delete_outline_rounded,
          label: '删除私人相册',
        ),
      ],
      if (widget.isAdmin && _currentAlbum != null) ...[
        isleActionMenuItem(
          value: 'renameShared',
          enabled: !_catalog.busy,
          icon: Icons.drive_file_rename_outline,
          label: '重命名相册',
        ),
        isleActionMenuItem(
          value: 'deleteShared',
          enabled: !_catalog.busy,
          icon: Icons.delete_outline_rounded,
          label: '删除相册',
        ),
      ],
      if (widget.canBackup && isMobilePlatform)
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
      if (widget.isAdmin)
        isleActionMenuItem(
          value: 'scan',
          enabled: !_scan.scanning,
          icon: Icons.sync_rounded,
          label: _scan.scanning ? '扫描中' : '扫描媒体',
        ),
    ];
  }

  Widget _buildSelectionToolbar() {
    final selectedIds = _selection.selectedAssets;
    final busy = _selection.batchBusy;
    final allSelectedFavorited =
        selectedIds.isNotEmpty &&
        _feed.assets
            .where((a) => selectedIds.contains(a.id))
            .every((a) => a.personalFavorite);
    final allPageSelected = _feed.assets
        .take(50)
        .every((asset) => selectedIds.contains(asset.id));
    final canTrashSelected =
        !busy &&
        selectedIds.isNotEmpty &&
        !_feed.assets
            .where((a) => selectedIds.contains(a.id))
            .any((a) => !widget.isAdmin && !a.canWrite);

    return IsleAnimatedExpand(
      expanded: _selection.selecting,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 14),
        child: MediaSelectionActionBar(
          label: '已选 ${selectedIds.length} 项',
          actions: [
            OutlinedButton.icon(
              onPressed: busy || _feed.assets.isEmpty
                  ? null
                  : _selectVisiblePhotos,
              icon: const Icon(Icons.select_all_rounded, size: 17),
              label: Text(allPageSelected ? '取消全选' : '全选当前页'),
            ),
            TextButton(
              onPressed: busy ? null : () => setState(_selection.clear),
              child: const Text('完成'),
            ),
            OutlinedButton.icon(
              onPressed: busy || selectedIds.isEmpty ? null : _batchFavorite,
              icon: Icon(
                allSelectedFavorited
                    ? Icons.star_outline_rounded
                    : Icons.star_border_rounded,
                size: 17,
              ),
              label: Text(allSelectedFavorited ? '取消收藏' : '收藏'),
            ),
            FilledButton.tonalIcon(
              onPressed: busy || selectedIds.isEmpty
                  ? null
                  : _batchAddToPrivateAlbum,
              icon: const Icon(Icons.add_to_photos_outlined, size: 17),
              label: const Text('加入相册'),
            ),
            if (_scope.activePrivateAlbum > 0 ||
                (widget.isAdmin && _scope.activeAlbum > 0))
              OutlinedButton.icon(
                onPressed: busy || selectedIds.isEmpty
                    ? null
                    : _batchRemoveFromCurrentAlbum,
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 17),
                label: const Text('移出相册'),
              ),
            OutlinedButton.icon(
              onPressed: busy || selectedIds.isEmpty ? null : _batchExport,
              icon: const Icon(Icons.download_outlined, size: 17),
              label: const Text('保存原文件'),
            ),
            OutlinedButton.icon(
              onPressed: busy || selectedIds.isEmpty ? null : _batchShare,
              icon: const Icon(Icons.ios_share_outlined, size: 17),
              label: const Text('分享'),
            ),
            FilledButton.tonalIcon(
              onPressed: canTrashSelected ? _batchTrashAssets : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 17),
              label: const Text('移入回收站'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanners() {
    final privateFailure = _catalog.privateFailure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_scan.scanning)
          MediaStatusBanner(
            message: '正在整理媒体 · 已找到 ${_scan.status.found} 项',
            icon: Icons.sync,
          ),
        _buildAIIndexBanner(),
        if (_scan.scanError != null)
          MediaStatusBanner(
            message: '上次扫描未完成：${_scan.scanError}',
            isError: true,
          ),
        if (privateFailure != null)
          MediaStatusBanner(
            key: const ValueKey('privateAlbumsLoadFailure'),
            message:
                '私人相册列表未能读取：${mediaErrorLabel(privateFailure)}\n'
                '其他图库内容可以继续浏览；请排除故障后重试。',
            diagnostic: errorDiagnosticLabel(privateFailure),
            isError: true,
            icon: Icons.error_outline,
            trailing: TextButton(
              onPressed: _catalog.privateRefreshing
                  ? null
                  : () => unawaited(_refreshPrivateAlbums()),
              child: Text(_catalog.privateRefreshing ? '加载中' : '重试'),
            ),
          ),
        if (_feed.actionMessage != null)
          MediaStatusBanner(
            message: _feed.actionMessage!,
            isError: _feed.actionIsError,
          ),
        if (_feed.loadError != null && _feed.assets.isNotEmpty)
          MediaStatusBanner(
            message: _feed.loadError!,
            isError: true,
            icon: Icons.error_outline,
            trailing: TextButton(
              onPressed: _feed.loadingMore
                  ? null
                  : () => _loadAssets(reset: false),
              child: const Text('重试'),
            ),
          ),
      ],
    );
  }

  Widget _buildPaginationFooterSliver(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        children: [
          if (_feed.assets.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(_pageInset, 20, _pageInset, 26),
              child: Center(
                child: _feed.nextCursor > 0
                    ? OutlinedButton.icon(
                        onPressed: _feed.loadingMore
                            ? null
                            : () => _loadAssets(reset: false),
                        icon: _feed.loadingMore
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.expand_more),
                        label: Text(_feed.loadingMore ? '正在加载' : '加载更多媒体'),
                      )
                    : Text(
                        '已显示全部 ${_feed.assets.length} 项',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              ),
            ),
          const SizedBox(height: 76),
        ],
      ),
    );
  }

  Widget _buildTimelineScrubberOverlay(BuildContext context) {
    return Positioned(
      right: 4,
      top: 76,
      bottom: 40,
      child: PhotoTimelineScrubber(
        scrollController: _timeline.scrollController,
        months: _timeline.months,
        activeFirstIndex: _timeline.activeFirstIndex,
        wide: MediaQuery.sizeOf(context).width >= 800,
        onSelected: (month) => unawaited(_jumpToTimelineMonth(month)),
      ),
    );
  }
}

class _AssetMonthSection {
  _AssetMonthSection(this.key, this.title) : items = <PhotoAsset>[];

  final String key;
  final String title;
  final List<PhotoAsset> items;
}

String _assetMonthKey(int takenAt) {
  if (takenAt <= 0) return 'unknown';
  final value = DateTime.fromMillisecondsSinceEpoch(takenAt * 1000).toLocal();
  return '${value.year}-${value.month}';
}
