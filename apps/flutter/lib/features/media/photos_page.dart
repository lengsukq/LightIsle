import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../files/upload_task_center.dart';
import 'photo_timeline_scrubber.dart';
import 'photos_batch_actions.dart';
import 'photos_controller.dart';
import 'photos_header_and_nav.dart';
import 'photos_memories_and_banners.dart';
import 'photos_navigation_actions.dart';
import 'photos_timeline_grid.dart';

export 'photo_detail_dialog.dart' show PhotoDetailDialog;
export 'photos_album_dialogs.dart' show AlbumNameDialog;

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
  late final PhotosController _controller;
  late PhotosBatchActions _batchActions;
  late PhotosNavigationActions _navigationActions;

  void _rebuildActionCoordinators() {
    _batchActions = PhotosBatchActions(
      api: widget.api,
      controller: _controller,
      isAdmin: widget.isAdmin,
    );
    _navigationActions = PhotosNavigationActions(
      api: widget.api,
      controller: _controller,
      batchActions: _batchActions,
      isAdmin: widget.isAdmin,
      accountName: widget.accountName,
      offlineAccountId: widget.offlineAccountId,
      backupDirectory: widget.backupDirectory,
      canBackup: widget.canBackup,
      uploadDirectory: widget.uploadDirectory,
      taskCenter: widget.taskCenter,
    );
  }

  @override
  void initState() {
    super.initState();
    _controller = PhotosController(api: widget.api, isAdmin: widget.isAdmin);
    _rebuildActionCoordinators();
    _controller.initialize();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant PhotosPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAdmin != oldWidget.isAdmin) {
      _controller.isAdmin = widget.isAdmin;
    }
    if (widget.api != oldWidget.api ||
        widget.isAdmin != oldWidget.isAdmin ||
        widget.accountName != oldWidget.accountName ||
        widget.offlineAccountId != oldWidget.offlineAccountId ||
        widget.backupDirectory != oldWidget.backupDirectory ||
        widget.canBackup != oldWidget.canBackup ||
        widget.uploadDirectory != oldWidget.uploadDirectory ||
        widget.taskCenter != oldWidget.taskCenter) {
      _rebuildActionCoordinators();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.setTabEnabled(TickerMode.valuesOf(context).enabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.setAppForeground(state == AppLifecycleState.resumed);
  }

  bool _onViewportScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        (notification.scrollDelta ?? 0) > 0 &&
        notification.metrics.axis == Axis.vertical &&
        notification.depth == 0) {
      _controller.handleScrollExtentAfter(notification.metrics.extentAfter);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final pageInset = IsleLayout.pageInset(
          MediaQuery.sizeOf(context).width,
        );
        return IsleChildPopScope(
          canPop: _controller.canPop,
          onPopInvokedWithResult: (didPop, _) =>
              _controller.handleSystemBack(didPop),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onViewportScrollNotification,
            child: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _controller.refreshAllSources,
                  child: CustomScrollView(
                    key: PageStorageKey<String>(
                      'photos:${widget.api.selectedRoot?.identity ?? 'default'}',
                    ),
                    physics: const AlwaysScrollableScrollPhysics(),
                    controller: _controller.timeline.scrollController,
                    slivers: [
                      _buildTopChromeSliver(context, pageInset: pageInset),
                      PhotosTimelineGridSliver(
                        api: widget.api,
                        controller: _controller,
                        pageInset: pageInset,
                        hasOtherRoots: widget.hasOtherRoots,
                        onRetryInitialLoad: () =>
                            unawaited(_controller.loadAssets(reset: true)),
                        onBrowseAllPhotos: () =>
                            unawaited(_controller.selectView()),
                        onUpload: () =>
                            unawaited(_navigationActions.upload(context)),
                        onToggleSectionSelection: (items) => _batchActions
                            .toggleSectionSelection(context, items),
                        onOpenAsset: (asset) => unawaited(
                          _navigationActions.openAsset(context, asset),
                        ),
                        onToggleAssetSelection: (asset) =>
                            _batchActions.toggleSelection(context, asset),
                      ),
                      PhotosPaginationFooterSliver(
                        assetCount: _controller.feed.assets.length,
                        hasMore: _controller.feed.nextCursor > 0,
                        loadingMore: _controller.feed.loadingMore,
                        pageInset: pageInset,
                        onLoadMore: () =>
                            unawaited(_controller.loadAssets(reset: false)),
                      ),
                    ],
                  ),
                ),
                if (_controller.shouldShowTimelineScrubber)
                  _buildTimelineScrubberOverlay(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopChromeSliver(
    BuildContext context, {
    required double pageInset,
  }) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PhotosPageHeader(
            api: widget.api,
            accountName: widget.accountName,
            backupDirectory: widget.backupDirectory,
            canBackup: widget.canBackup,
            isAdmin: widget.isAdmin,
            pageInset: pageInset,
            controller: _controller,
            onOpenMobileBackup: () =>
                _navigationActions.openMobilePhotoBackup(context),
            onUpload: () => unawaited(_navigationActions.upload(context)),
            onMenuAction: (value) =>
                _navigationActions.handleMenuAction(context, value),
          ),
          PhotosNavigationSection(
            controller: _controller,
            pageInset: pageInset,
            onBrowseAlbums: () =>
                unawaited(_navigationActions.browseAlbums(context)),
            onOpenPeople: () =>
                unawaited(_navigationActions.openPeoplePage(context)),
            onOpenExifFilter: () =>
                unawaited(_navigationActions.openExifFilterSheet(context)),
          ),
          IsleAnimatedExpand(
            expanded:
                _controller.isFullTimelineSelected &&
                _controller.feed.assets.isNotEmpty &&
                !_controller.selection.selecting,
            child: PhotosMemoriesCarousel(
              pageInset: pageInset,
              onOnThisDay: () =>
                  unawaited(_controller.selectView(onThisDay: true)),
              onPersonalFavorites: () =>
                  unawaited(_controller.selectView(personalFavorites: true)),
              onSharedFavorites: () =>
                  unawaited(_controller.selectView(favorites: true)),
              onLivePhotos: () => _controller.setMediaType('live'),
              onVideos: () => _controller.setMediaType('video'),
              onOpenMap: () =>
                  unawaited(_navigationActions.openPhotoMap(context)),
            ),
          ),
          PhotosSelectionActionBar(
            controller: _controller,
            isAdmin: widget.isAdmin,
            pageInset: pageInset,
            onBatchFavorite: () =>
                unawaited(_controller.batch.favoriteSelected()),
            onBatchAddToAlbum: () =>
                unawaited(_batchActions.batchAddToAlbum(context)),
            onBatchRemoveFromAlbum: () =>
                unawaited(_batchActions.batchRemoveFromCurrentAlbum(context)),
            onBatchExport: () => unawaited(_batchActions.batchExport(context)),
            onBatchShare: () => unawaited(_batchActions.batchShare(context)),
            onBatchTrash: () =>
                unawaited(_batchActions.batchTrashAssets(context)),
          ),
          PhotosStatusBanners(controller: _controller, isAdmin: widget.isAdmin),
        ],
      ),
    );
  }

  Widget _buildTimelineScrubberOverlay(BuildContext context) {
    return Positioned(
      right: 4,
      top: 72,
      bottom: 36,
      child: PhotoTimelineScrubber(
        scrollController: _controller.timeline.scrollController,
        months: _controller.timeline.months,
        activeFirstIndex: _controller.timeline.activeFirstIndex,
        wide: MediaQuery.sizeOf(context).width >= 800,
        onSelected: (month) =>
            unawaited(_navigationActions.jumpToTimelineMonth(context, month)),
      ),
    );
  }
}
