import 'package:flutter/material.dart';

import 'file_batch_operations.dart';
import 'file_models.dart';
import 'file_upload_stream.dart';

/// Encapsulates active directory listing, pagination cursor, write permission,
/// and error diagnostics for [FilesPage].
class FilesDirectoryState {
  FilesDirectoryState({required this.path, required this.rootIdentity});

  String path;
  String rootIdentity;
  String rootName = '共享文件';
  List<FileEntry> entries = <FileEntry>[];
  final Set<String> failedThumbnails = <String>{};
  String nextCursor = '';
  bool canWrite = false;
  bool loading = false;
  String? error;
  String? directoryDiagnostic;
  String? highlightedPath;
  int loadGeneration = 0;

  void resetForIdentity(String initialPath, String newRootIdentity) {
    loadGeneration++;
    rootIdentity = newRootIdentity;
    path = initialPath;
    rootName = '共享文件';
    entries = <FileEntry>[];
    failedThumbnails.clear();
    canWrite = false;
    nextCursor = '';
    error = null;
    directoryDiagnostic = null;
    highlightedPath = null;
    loading = true;
  }
}

/// Encapsulates search bar state, search kind filter, and recycle-bin view
/// state for [FilesPage].
class FilesSearchAndTrashState {
  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();
  bool searchInputFocused = false;
  bool showingTrash = false;
  bool trashLoading = false;
  List<TrashEntry> trashEntries = <TrashEntry>[];

  bool searching = false;
  bool searchViaSpotlight = false;
  String? preSearchPath;
  double preSearchScrollOffset = 0;
  String? searchScopeSubdir;
  bool searchEntireRoot = false;
  bool searchTruncated = false;
  String searchTerm = '';
  String searchKind = '';
  List<String> recentSearches = <String>[];
  int searchHistoryGeneration = 0;

  void clearSearchState() {
    searching = false;
    searchKind = '';
    preSearchPath = null;
    preSearchScrollOffset = 0;
    searchScopeSubdir = null;
    searchEntireRoot = false;
    searchTerm = '';
    searchController.clear();
  }

  void reset() {
    showingTrash = false;
    trashLoading = false;
    trashEntries = <TrashEntry>[];
    searchTruncated = false;
    recentSearches = <String>[];
    searchHistoryGeneration++;
    clearSearchState();
  }

  void dispose() {
    searchFocusNode.dispose();
    searchController.dispose();
  }
}

/// Encapsulates persisted sort order, layout view mode, and upload auto-rename
/// preferences for [FilesPage].
class FilesDisplayPrefsState {
  String fileSort = 'name';
  String fileSortDirection = 'asc';
  String fileView = 'list';
  bool uploadAutoRename = false;
  int preferencesGeneration = 0;
  Future<void> preferenceWrites = Future<void>.value();

  void resetDefaults() {
    fileView = 'list';
    fileSort = 'name';
    fileSortDirection = 'asc';
    uploadAutoRename = false;
  }
}

/// Encapsulates multi-select paths, batch move/copy/trash progress, upload
/// queue, and active file downloads for [FilesPage].
class FilesSelectionAndTransferState {
  bool selecting = false;
  final Set<String> selectedPaths = <String>{};
  String? selectionAnchorPath;

  bool batchBusy = false;
  bool batchStopRequested = false;
  FileBatchProgress? batchProgress;
  String? batchActionLabel;
  ({String action, String destination, List<String> failedPaths})?
  lastFailedBatchRetry;

  bool uploadBusy = false;
  final List<FileUploadJob> uploadJobs = <FileUploadJob>[];
  final Set<FileUploadJob> observedCompletedUploads = <FileUploadJob>{};
  final Map<String, double> downloadProgress = <String, double>{};
  final Set<String> downloading = <String>{};
  String? downloadMessage;

  void clearSelection() {
    selecting = false;
    selectedPaths.clear();
    selectionAnchorPath = null;
  }

  void resetForRootChange() {
    clearSelection();
    lastFailedBatchRetry = null;
    batchProgress = null;
    batchStopRequested = false;
  }
}
