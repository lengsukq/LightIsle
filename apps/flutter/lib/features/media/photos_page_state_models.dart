import 'dart:async';

import 'package:flutter/material.dart';

import 'media_models.dart';
import 'photo_ai_models.dart';
import 'photo_timeline_scrubber.dart';

/// Encapsulates timeline scroll controller, month anchor key, and month jump
/// index state for [PhotosPage].
class PhotosTimelineState {
  final ScrollController scrollController = ScrollController();
  final GlobalKey firstMonthHeadingKey = GlobalKey();
  List<PhotoTimelineMonth> months = const [];
  int indexGeneration = 0;
  int activeFirstIndex = 0;

  void dispose() {
    indexGeneration++;
    scrollController.dispose();
  }
}

/// Encapsulates shared, personal, and folder-backed album catalogs and their
/// async refresh lifecycles for [PhotosPage].
class PhotosAlbumCatalogState {
  List<MediaAlbum> sharedAlbums = const [];
  List<MediaAlbum> privateAlbums = const [];
  List<Map<String, dynamic>> folderAlbums = const [];
  bool busy = false;
  bool privateRefreshing = false;
  Object? privateFailure;
  int sharedGeneration = 0;
  int privateGeneration = 0;

  MediaAlbum? findShared(int id) {
    if (id <= 0) return null;
    for (final album in sharedAlbums) {
      if (album.id == id) return album;
    }
    return null;
  }

  MediaAlbum? findPrivate(int id) {
    if (id <= 0) return null;
    for (final album in privateAlbums) {
      if (album.id == id) return album;
    }
    return null;
  }

  void cancelPending() {
    sharedGeneration++;
    privateGeneration++;
  }
}

/// Encapsulates active album/folder/person collection scope, search query, and
/// EXIF/time facet filters for [PhotosPage].
class PhotosFilterScopeState {
  final TextEditingController searchController = TextEditingController();
  Timer? searchTimer;

  int activeAlbum = 0;
  int activePrivateAlbum = 0;
  String activeFolderPath = '';
  String activeFolderName = '';
  int activePersonId = 0;
  String activePersonName = '';

  bool favoritesOnly = false;
  bool personalFavoritesOnly = false;
  bool onThisDay = false;
  bool showSearch = false;

  String query = '';
  String mediaType = '';
  String cameraFilter = '';
  String locationFilter = '';
  PhotoSearchMode searchMode = PhotoSearchMode.all;
  int yearFilter = 0;
  int takenFromFilter = 0;
  int takenToFilter = 0;

  List<String> facetCameras = const [];
  List<int> facetYears = const [];

  bool get isUnscopedCollection =>
      activeAlbum == 0 &&
      activePrivateAlbum == 0 &&
      activeFolderPath.isEmpty &&
      activePersonId == 0 &&
      !favoritesOnly &&
      !personalFavoritesOnly &&
      !onThisDay;

  bool get isFullTimelineSelected =>
      isUnscopedCollection &&
      query.isEmpty &&
      mediaType.isEmpty &&
      cameraFilter.isEmpty &&
      locationFilter.isEmpty &&
      yearFilter == 0 &&
      takenFromFilter == 0 &&
      takenToFilter == 0;

  void setCollectionScope({
    int albumId = 0,
    int privateAlbumId = 0,
    String folderPath = '',
    String folderName = '',
    int personId = 0,
    String personName = '',
    bool favorites = false,
    bool personalFavorites = false,
    bool onThisDayView = false,
  }) {
    activeAlbum = albumId;
    activePrivateAlbum = privateAlbumId;
    activeFolderPath = folderPath;
    activeFolderName = folderName;
    activePersonId = personId;
    activePersonName = personName;
    favoritesOnly = favorites;
    personalFavoritesOnly = personalFavorites;
    onThisDay = onThisDayView;
  }

  void clearSearchAndFacets({bool closeSearchBar = false}) {
    searchTimer?.cancel();
    searchController.clear();
    query = '';
    searchMode = PhotoSearchMode.all;
    mediaType = '';
    cameraFilter = '';
    locationFilter = '';
    yearFilter = 0;
    takenFromFilter = 0;
    takenToFilter = 0;
    if (closeSearchBar) showSearch = false;
  }

  Map<String, String> buildQueryParameters({
    required int limit,
    required int cursor,
  }) {
    final params = <String, String>{'limit': '$limit', 'cursor': '$cursor'};
    if (activeAlbum > 0) params['album'] = '$activeAlbum';
    if (activePrivateAlbum > 0) params['privateAlbum'] = '$activePrivateAlbum';
    if (activeFolderPath.isNotEmpty) params['directory'] = activeFolderPath;
    if (favoritesOnly) params['favorites'] = '1';
    if (personalFavoritesOnly) params['personal'] = '1';
    if (onThisDay) params['onThisDay'] = '1';
    if (query.isNotEmpty) params['q'] = query;
    appendPhotoAISearchQuery(
      params,
      searchTerm: query,
      searchMode: searchMode,
      personId: activePersonId,
    );
    if (mediaType.isNotEmpty) params['type'] = mediaType;
    if (cameraFilter.isNotEmpty) params['camera'] = cameraFilter;
    if (locationFilter.isNotEmpty) params['hasLocation'] = locationFilter;
    if (yearFilter > 0) {
      final from = DateTime(yearFilter, 1, 1).millisecondsSinceEpoch ~/ 1000;
      final to =
          DateTime(yearFilter, 12, 31, 23, 59, 59).millisecondsSinceEpoch ~/
          1000;
      params['takenFrom'] = '$from';
      params['takenTo'] = '$to';
    } else {
      if (takenFromFilter > 0) params['takenFrom'] = '$takenFromFilter';
      if (takenToFilter > 0) params['takenTo'] = '$takenToFilter';
    }
    return params;
  }

  void dispose() {
    searchTimer?.cancel();
    searchController.dispose();
  }
}

/// Encapsulates multi-select mode and active batch operation state for
/// [PhotosPage].
class PhotosSelectionState {
  bool selecting = false;
  bool batchBusy = false;
  final Set<int> selectedAssets = <int>{};

  void clear() {
    selecting = false;
    selectedAssets.clear();
  }
}

/// Encapsulates paged photo/video assets, grid density preference, and transient
/// banner feedback for [PhotosPage].
class PhotosLibraryFeedState {
  final List<PhotoAsset> assets = <PhotoAsset>[];
  int nextCursor = 0;
  int generation = 0;
  bool loading = true;
  bool loadingMore = false;
  bool comfortableGrid = false;
  String? loadError;
  String? actionMessage;
  bool actionIsError = false;

  void clearActionFeedback() {
    actionMessage = null;
    actionIsError = false;
  }

  void setActionFeedback(String message, {bool isError = false}) {
    actionMessage = message;
    actionIsError = isError;
  }
}

/// Encapsulates background gallery/AI indexing scan status and foreground
/// polling lifecycle flags for [PhotosPage].
class PhotosScanRuntimeState {
  bool scanning = false;
  bool aiPauseBusy = false;
  String? scanError;
  MediaScanStatus status = const MediaScanStatus();
  int generation = 0;
  bool tabEnabled = true;
  bool appForeground = true;

  bool get shouldPoll => tabEnabled && appForeground;
}
