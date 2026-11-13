import 'dart:async';

import 'package:flutter/material.dart';

import 'media_models.dart';

/// Encapsulates film grid pagination, discovery shelves, active filter mode,
/// search input, and feedback banner state for [CinemaPage].
class CinemaCatalogViewState {
  final List<CinemaFilm> films = <CinemaFilm>[];
  final List<CinemaFilm> resumeShelf = <CinemaFilm>[];
  final List<CinemaFilm> recentShelf = <CinemaFilm>[];
  final TextEditingController searchController = TextEditingController();

  int shelfGeneration = 0;
  bool shelvesLoaded = false;
  int nextCursor = 0;
  int listGeneration = 0;
  String mode = 'all';
  String watched = 'all';
  String sort = 'recent';
  String query = '';
  String activeScopeKey = '';
  bool showSearch = false;
  bool loading = true;
  bool loadingMore = false;
  String? loadError;
  String? actionMessage;
  bool actionIsError = false;
  Timer? searchTimer;

  void resetSearch() {
    searchTimer?.cancel();
    query = '';
    searchController.clear();
    showSearch = false;
  }

  void dispose() {
    listGeneration++;
    shelfGeneration++;
    searchTimer?.cancel();
    searchController.dispose();
  }
}

/// Encapsulates multi-select film IDs and batch operation busy state for
/// [CinemaPage].
class CinemaBatchSelectionState {
  bool selecting = false;
  bool batchBusy = false;
  final Set<int> selectedFilmIds = <int>{};

  void clear() {
    selecting = false;
    selectedFilmIds.clear();
  }
}

/// Encapsulates background library scan status and administrator TMDB scrape
/// status for [CinemaPage].
class CinemaIndexingViewState {
  int statusGeneration = 0;
  bool scanning = false;
  String? scanError;
  MediaScanStatus scanStatus = const MediaScanStatus();
  CinemaScrapeStatus? scrapeStatus;
  bool scrapeBusy = false;
  String? scrapeMessage;
  Timer? postUploadTimer;

  void dispose() {
    statusGeneration++;
    postUploadTimer?.cancel();
  }
}

/// Encapsulates watch-history and TV-series subview state for [CinemaPage].
class CinemaSecondaryViewsState {
  bool showHistory = false;
  final List<CinemaFilm> history = <CinemaFilm>[];
  bool historyLoading = false;
  String? historyError;
  int historyNext = 0;

  bool showSeries = false;
  final List<CinemaSeriesInfo> series = <CinemaSeriesInfo>[];
  bool seriesLoading = false;
  String? seriesError;

  bool get isRootView => !showSeries && !showHistory;

  void exitSecondaryViews() {
    showSeries = false;
    showHistory = false;
  }
}
