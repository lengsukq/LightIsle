import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/isle_cache_manager.dart';
import '../../core/isle_data_cache.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import 'media_batch_operations.dart';
import 'media_models.dart';
import 'media_page_result.dart';
import 'media_scan_poller.dart';
import 'media_ui.dart';
import 'photo_ai_models.dart';
import 'photo_album_repository.dart';
import 'photo_exif_filter_sheet.dart';
import 'photo_timeline_scrubber.dart';
import 'photos_album_service.dart';
import 'photos_batch_service.dart';
import 'photos_page_state_models.dart';

/// Owns all reactive state, paging, SWR cache hydration, timeline indexing,
/// EXIF/AI filtering, album catalogs, scan/AI polling, and batch selection for
/// [PhotosPage] without depending on [BuildContext].
class PhotosController extends ChangeNotifier {
  PhotosController({required this.api, required this.isAdmin}) {
    albumRepository = PhotoAlbumRepository(api);
    batchOperations = MediaBatchOperations(api);
    _scanPoller = MediaScanPoller(onPoll: () => unawaited(refreshStatus()));
    albums = PhotosAlbumService(
      api: api,
      repository: albumRepository,
      catalog: catalog,
      scope: scope,
      feed: feed,
      isAdmin: () => isAdmin,
      isAlive: () => !_disposed,
      notify: _notify,
      reloadAssets: ({required reset}) => loadAssets(reset: reset),
    );
    batch = PhotosBatchService(
      api: api,
      albumRepository: albumRepository,
      batchOperations: batchOperations,
      selection: selection,
      feed: feed,
      isAdmin: () => isAdmin,
      isAlive: () => !_disposed,
      notify: _notify,
      reloadAssets: ({required reset}) => loadAssets(reset: reset),
      togglePersonalFavorite: albums.togglePersonalFavorite,
      refreshSharedAlbums: albums.refreshSharedAlbums,
      refreshPrivateAlbums: albums.refreshPrivateAlbums,
    );
  }

  static const int pageSize = 48;
  static const double _prefetchExtentThreshold = 650.0;
  static const Duration _searchDebounceDuration = Duration(milliseconds: 350);

  final LightIsleApi api;
  bool isAdmin;
  bool _disposed = false;

  final PhotosTimelineState timeline = PhotosTimelineState();
  final PhotosAlbumCatalogState catalog = PhotosAlbumCatalogState();
  final PhotosFilterScopeState scope = PhotosFilterScopeState();
  final PhotosSelectionState selection = PhotosSelectionState();
  final PhotosLibraryFeedState feed = PhotosLibraryFeedState();
  final PhotosScanRuntimeState scan = PhotosScanRuntimeState();

  late final PhotoAlbumRepository albumRepository;
  late final MediaBatchOperations batchOperations;
  late final MediaScanPoller _scanPoller;
  late final PhotosAlbumService albums;
  late final PhotosBatchService batch;

  bool get isDisposed => _disposed;

  MediaImageMemoryCache get photoCache =>
      IsleCacheManager.instance.sharedThumbnails;

  MediaAlbum? get currentAlbum => catalog.findShared(scope.activeAlbum);
  MediaAlbum? get currentPrivateAlbum =>
      catalog.findPrivate(scope.activePrivateAlbum);

  String get currentAlbumName =>
      currentPrivateAlbum?.name ?? currentAlbum?.name ?? '';

  bool get canRemoveFromCurrentAlbum =>
      scope.activePrivateAlbum > 0 || (isAdmin && scope.activeAlbum > 0);

  bool get isFullTimelineSelected => scope.isFullTimelineSelected;

  bool get canPop =>
      !selection.selecting && !scope.showSearch && isFullTimelineSelected;

  bool get shouldShowTimelineScrubber =>
      isFullTimelineSelected &&
      !selection.selecting &&
      timeline.months.length > 1 &&
      feed.assets.isNotEmpty;

  String get headerSubtitle {
    if (scope.activePersonId > 0) return '人物 · ${scope.activePersonName}';
    if (scope.activeFolderName.isNotEmpty) return scope.activeFolderName;
    final activeAlbumName = currentPrivateAlbum?.name ?? currentAlbum?.name;
    if (activeAlbumName != null) return activeAlbumName;
    if (scope.personalFavoritesOnly) return '我的收藏';
    if (scope.favoritesOnly) return '共享收藏';
    if (scope.onThisDay) return '那年今天';
    return '';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Hydrates cached SWR assets synchronously and kicks off initial network
  /// refreshes. Safe to invoke from `State.initState`.
  void initialize() {
    unawaited(loadAssets(reset: true));
    unawaited(albums.refreshSharedAlbums());
    unawaited(albums.refreshPrivateAlbums());
    unawaited(albums.refreshFolderAlbums());
    unawaited(refreshTimelineIndex());
    unawaited(refreshFacets());
  }

  @override
  void dispose() {
    _disposed = true;
    feed.generation++;
    catalog.cancelPending();
    scan.generation++;
    _scanPoller.dispose();
    timeline.dispose();
    scope.dispose();
    super.dispose();
  }

  void setTabEnabled(bool enabled) {
    scan.tabEnabled = enabled;
    _updatePollingState();
  }

  void setAppForeground(bool foreground) {
    scan.appForeground = foreground;
    _updatePollingState();
  }

  void _updatePollingState() {
    final active = scan.shouldPoll;
    if (!_scanPoller.setActive(active)) return;
    if (!active) {
      scan.generation++;
    } else {
      unawaited(refreshStatus());
    }
  }

  void handleScrollExtentAfter(double extentAfter) {
    if (extentAfter < _prefetchExtentThreshold &&
        feed.nextCursor > 0 &&
        !feed.loading &&
        !feed.loadingMore &&
        feed.loadError == null) {
      unawaited(loadAssets(reset: false));
    }
  }

  Future<void> refreshAllSources() async {
    await Future.wait([
      loadAssets(reset: true),
      albums.refreshSharedAlbums(),
      albums.refreshPrivateAlbums(),
      albums.refreshFolderAlbums(),
      refreshTimelineIndex(),
      refreshFacets(),
    ]);
  }

  Future<void> refreshLibraryAndAlbums() async {
    await Future.wait([
      loadAssets(reset: true),
      albums.refreshSharedAlbums(),
      albums.refreshPrivateAlbums(),
    ]);
  }

  Future<void> loadAssets({required bool reset, int? startCursor}) async {
    if (!reset &&
        (feed.loading || feed.loadingMore || feed.nextCursor == 0)) {
      return;
    }
    final generation = ++feed.generation;
    final cursor = reset ? (startCursor ?? 0) : feed.nextCursor;
    final query = scope.buildQueryParameters(limit: pageSize, cursor: cursor);
    final cacheKey = Uri(queryParameters: query).query;
    final scopeKey =
        '${identityHashCode(api)}:${api.selectedRoot?.identity ?? ''}:$cacheKey';

    MediaPageResult<PhotoAsset>? cachedPage;
    if (reset && startCursor == null) {
      final cached = IsleDataCache.instance.getJsonMap(api, 'photos', cacheKey);
      if (cached != null) {
        cachedPage = MediaPageResult.parse<PhotoAsset>(
          cached,
          itemsKey: 'assets',
          fromJson: PhotoAsset.fromJson,
        );
      }
    }

    if (reset) {
      if (cachedPage != null) {
        feed.assets
          ..clear()
          ..addAll(cachedPage.items);
        feed.nextCursor = cachedPage.nextCursor;
        feed.activeScopeKey = scopeKey;
        timeline.activeFirstIndex = 0;
        feed.loadError = null;
        feed.loading = false;
      } else {
        final sameScope =
            startCursor == null &&
            feed.activeScopeKey == scopeKey &&
            feed.assets.isNotEmpty;
        if (startCursor == null && !sameScope) {
          feed.assets.clear();
          feed.nextCursor = 0;
          timeline.activeFirstIndex = 0;
        }
        feed.activeScopeKey = scopeKey;
        feed.loadError = null;
        feed.loading = true;
      }
    } else {
      feed.loadingMore = true;
    }
    _notify();

    try {
      final response = await api.get('/api/v2/photos', query: query);
      if (_disposed || generation != feed.generation) return;
      if (reset && startCursor == null) {
        IsleDataCache.instance.putJsonMap(api, 'photos', cacheKey, response);
      }
      final page = MediaPageResult.parse<PhotoAsset>(
        response,
        itemsKey: 'assets',
        fromJson: PhotoAsset.fromJson,
      );
      if (reset) {
        feed.assets
          ..clear()
          ..addAll(page.items);
      } else {
        feed.assets.addAll(page.items);
      }
      feed.nextCursor = page.nextCursor;
      feed.loadError = null;
      _notify();
    } catch (error) {
      if (_disposed || generation != feed.generation) return;
      feed.loadError = mediaErrorLabel(error);
      _notify();
    } finally {
      if (!_disposed && generation == feed.generation) {
        feed.loading = false;
        feed.loadingMore = false;
        _notify();
      }
    }
  }

  Future<void> refreshFacets() async {
    try {
      final response = await api.get('/api/v2/photos/facets');
      if (_disposed) return;
      scope.facetCameras = (response['cameras'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      scope.facetYears = (response['years'] as List<dynamic>? ?? const [])
          .map((e) => int.tryParse(e.toString()) ?? 0)
          .where((e) => e >= 1970)
          .toList();
      _notify();
    } catch (_) {
      if (!_disposed) {
        scope.facetCameras = const [];
        scope.facetYears = const [];
        _notify();
      }
    }
  }

  Future<void> refreshTimelineIndex() async {
    final generation = ++timeline.indexGeneration;
    try {
      final response = await api.get('/api/v2/photos/timeline');
      if (_disposed || generation != timeline.indexGeneration) return;
      timeline.months = PhotoTimelineMonth.parse(response['months']);
      _notify();
    } catch (_) {
      if (!_disposed && generation == timeline.indexGeneration) {
        timeline.months = const [];
        _notify();
      }
    }
  }

  Future<bool> loadTimelineMonth(PhotoTimelineMonth month) async {
    if (!isFullTimelineSelected || feed.loading || feed.loadingMore) {
      return false;
    }
    await loadAssets(reset: true, startCursor: month.firstIndex);
    if (_disposed || feed.loadError != null) return false;
    timeline.activeFirstIndex = month.firstIndex;
    _notify();
    return true;
  }

  Future<void> refreshStatus() async {
    final generation = ++scan.generation;
    try {
      final response = await api.get('/api/v2/photos/status');
      if (_disposed || generation != scan.generation) return;
      final status = MediaScanStatus.fromJson(response['status']);
      final finished = _scanPoller.observe(status);
      scan.status = status;
      scan.scanning = status.running;
      scan.scanError = status.lastError.isEmpty
          ? null
          : mediaErrorLabel(status.lastError);
      _notify();
      if (finished) {
        await Future.wait([
          loadAssets(reset: true),
          albums.refreshSharedAlbums(),
          albums.refreshPrivateAlbums(),
          refreshTimelineIndex(),
        ]);
      }
    } catch (_) {
      // Authentication and service health are handled by the application shell.
    }
  }

  Future<void> startScan() async {
    feed.clearActionFeedback();
    _notify();
    try {
      await api.send('POST', '/api/v2/photos/scan');
      if (_disposed) return;
      feed.setActionFeedback('媒体扫描已开始。');
      _notify();
      await refreshStatus();
    } catch (error) {
      if (!_disposed) {
        feed.setActionFeedback(mediaErrorLabel(error), isError: true);
        _notify();
      }
    }
  }

  Future<void> toggleAIPause() async {
    if (scan.aiPauseBusy) return;
    final nextPaused = !scan.status.aiPaused;
    scan.aiPauseBusy = true;
    _notify();
    try {
      await PhotoAIRepository(api).setAIPaused(nextPaused);
      if (_disposed) return;
      feed.setActionFeedback(
        nextPaused ? '已暂停后台智能识图索引' : '已恢复后台智能识图索引',
      );
      _notify();
      await refreshStatus();
    } catch (error) {
      if (!_disposed) {
        feed.setActionFeedback(mediaErrorLabel(error), isError: true);
        _notify();
      }
    } finally {
      if (!_disposed) {
        scan.aiPauseBusy = false;
        _notify();
      }
    }
  }

  Future<void> selectView({
    int albumId = 0,
    bool favorites = false,
    bool personalFavorites = false,
    int privateAlbumId = 0,
    String folderPath = '',
    String folderName = '',
    bool onThisDay = false,
  }) async {
    if (scope.activeAlbum == albumId &&
        scope.favoritesOnly == favorites &&
        scope.personalFavoritesOnly == personalFavorites &&
        scope.activePrivateAlbum == privateAlbumId &&
        scope.activeFolderPath == folderPath &&
        scope.onThisDay == onThisDay &&
        scope.activePersonId == 0) {
      return;
    }
    selection.clear();
    scope.setCollectionScope(
      albumId: albumId,
      privateAlbumId: privateAlbumId,
      folderPath: folderPath,
      folderName: folderName,
      favorites: favorites,
      personalFavorites: personalFavorites,
      onThisDayView: onThisDay,
    );
    feed.clearActionFeedback();
    _notify();
    await loadAssets(reset: true);
  }

  Future<void> selectPerson({
    required int personId,
    required String personName,
  }) async {
    selection.clear();
    scope.setCollectionScope(personId: personId, personName: personName);
    _notify();
    await loadAssets(reset: true);
  }

  void jumpToSceneSearch(String label) {
    scope.searchTimer?.cancel();
    scope.searchController.text = label;
    selection.clear();
    scope.setCollectionScope();
    scope.showSearch = true;
    scope.searchMode = PhotoSearchMode.scene;
    scope.query = label;
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void toggleSearchBar() {
    scope.showSearch = !scope.showSearch;
    _notify();
  }

  void onSearchQueryChanged(String value) {
    scope.searchTimer?.cancel();
    scope.searchTimer = Timer(_searchDebounceDuration, () {
      if (_disposed) return;
      scope.query = value.trim();
      _notify();
      unawaited(loadAssets(reset: true));
    });
  }

  void clearAndCloseSearch() {
    scope.searchTimer?.cancel();
    scope.searchController.clear();
    scope.query = '';
    scope.searchMode = PhotoSearchMode.all;
    scope.showSearch = false;
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void clearSearchAndFacets() {
    scope.clearSearchAndFacets();
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void setSearchMode(PhotoSearchMode mode) {
    if (scope.searchMode == mode) return;
    scope.searchMode = mode;
    _notify();
    if (scope.query.isNotEmpty) {
      unawaited(loadAssets(reset: true));
    }
  }

  void setMediaType(String value) {
    scope.mediaType = value == 'all' ? '' : value;
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void toggleMediaType(String type) {
    scope.mediaType = scope.mediaType == type ? '' : type;
    _notify();
    unawaited(loadAssets(reset: true));
  }

  Future<void> applyExifFilter(PhotoExifFilterSelection selectionResult) async {
    scope.cameraFilter = selectionResult.camera;
    scope.locationFilter = selectionResult.location;
    scope.yearFilter = selectionResult.year;
    scope.takenFromFilter = selectionResult.takenFrom;
    scope.takenToFilter = selectionResult.takenTo;
    _notify();
    await loadAssets(reset: true);
  }

  void clearCameraFilter() {
    scope.cameraFilter = '';
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void clearLocationFilter() {
    scope.locationFilter = '';
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void clearYearFilter() {
    scope.yearFilter = 0;
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void clearDateRangeFilter() {
    scope.takenFromFilter = 0;
    scope.takenToFilter = 0;
    _notify();
    unawaited(loadAssets(reset: true));
  }

  void clearSpecialScopeOrMediaType() {
    final hadMediaType = scope.mediaType.isNotEmpty;
    scope.mediaType = '';
    if (!scope.isUnscopedCollection) {
      unawaited(selectView());
      return;
    }
    if (hadMediaType) {
      _notify();
      unawaited(loadAssets(reset: true));
    }
  }

  void toggleGridDensity() {
    feed.comfortableGrid = !feed.comfortableGrid;
    _notify();
  }

  void toggleSelectionMode({bool clearOnlyOnEnter = false}) {
    if (selection.batchBusy) return;
    if (clearOnlyOnEnter) {
      selection.selecting = !selection.selecting;
      selection.selectedAssets.clear();
    } else if (selection.selecting) {
      selection.clear();
    } else {
      selection.selecting = true;
    }
    _notify();
  }

  void clearSelection() {
    if (selection.batchBusy) return;
    selection.clear();
    _notify();
  }

  void handleSystemBack(bool didPop) {
    if (didPop || selection.batchBusy) return;
    if (selection.selecting) {
      selection.clear();
      _notify();
      return;
    }
    if (scope.showSearch) {
      clearAndCloseSearch();
      return;
    }
    if (!isFullTimelineSelected) {
      final wasUnscoped = scope.isUnscopedCollection;
      scope.clearSearchAndFacets();
      if (wasUnscoped) {
        _notify();
        unawaited(loadAssets(reset: true));
      } else {
        unawaited(selectView());
      }
    }
  }

  void setActionFeedback(String message, {bool isError = false}) {
    feed.setActionFeedback(message, isError: isError);
    _notify();
  }

  Future<void> completeUpload(int count, {String? indexingError}) async {
    feed.setActionFeedback(
      '已上传 $count 项。${indexingError == null ? '索引更新后会显示在全部照片中，可下拉刷新。' : '媒体整理暂未开始：$indexingError'}',
      isError: indexingError != null,
    );
    scope.setCollectionScope(
      personId: scope.activePersonId,
      personName: scope.activePersonName,
    );
    scope.clearSearchAndFacets(closeSearchBar: true);
    _notify();
    await loadAssets(reset: true);
  }

  Future<void> completeBatchFolderAlbum({
    required bool moved,
    required int completedCount,
    required String albumName,
  }) async {
    selection.clear();
    feed.setActionFeedback(
      moved
          ? '已将 $completedCount 项移动到文件夹相册“$albumName”。'
          : '已将 $completedCount 项复制到文件夹相册“$albumName”。',
    );
    _notify();
    await Future.wait([loadAssets(reset: true), albums.refreshFolderAlbums()]);
  }

  PhotoAsset? findAssetById(int id) {
    for (final item in feed.assets) {
      if (item.id == id) return item;
    }
    return null;
  }
}
