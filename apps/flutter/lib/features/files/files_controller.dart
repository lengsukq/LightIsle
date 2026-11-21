import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'file_browser_repository.dart';
import 'file_destination_dialog.dart';
import 'file_models.dart';
import 'file_selection_snapshot.dart';
import 'file_upload_stream.dart';
import 'files_batch_coordinator.dart';
import 'files_entry_actions.dart';
import 'files_page_state_models.dart';
import 'files_path_utils.dart';
import 'files_preferences_store.dart';
import 'files_transfer_coordinator.dart';
import 'upload_task_center.dart';

final class FilesPageConfig {
  const FilesPageConfig({
    required this.api,
    required this.isAdmin,
    this.accountName = '',
    this.accountId,
    this.initialPath = '.',
    this.uploadOnly = false,
    this.initialUploadType = FileType.any,
    this.onUploaded,
    this.taskCenter,
    this.mobileExportOverride,
    this.exportDirectoryFactory,
    this.exportDirectoryCleanup,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final String? accountId;
  final String initialPath;
  final bool uploadOnly;
  final FileType initialUploadType;
  final VoidCallback? onUploaded;
  final UploadTaskCenter? taskCenter;
  final bool? mobileExportOverride;
  final Future<Directory> Function(Directory parent)? exportDirectoryFactory;
  final Future<void> Function(Directory directory)? exportDirectoryCleanup;
}

/// Central [ChangeNotifier] state controller for the file browser.
///
/// Owns directory/search/trash loading, display preferences, multi-select batch
/// operations, single-entry mutations, upload queue orchestration, and
/// download/preview preparation. Never holds a [BuildContext]; dialogs,
/// navigation, and SnackBars live in `FilesUiActions`.
class FilesController extends ChangeNotifier {
  FilesController({
    required FilesPageConfig config,
    this.onHighlightActivated,
    this.onRestoreScrollOffset,
    this.readScrollOffset,
    this.onNoticeMessage,
  }) : _config = config,
       dir = FilesDirectoryState(
         path: config.initialPath,
         rootIdentity: config.api.selectedRoot?.identity ?? 'default',
       ) {
    preferences = FilesPreferencesCoordinator(
      prefsState: prefs,
      filterState: filter,
      readServerOrigin: () => _config.api.uri('/'),
      readAccountName: () => _config.accountName,
      readRootIdentity: () => dir.rootIdentity,
      readInitialPath: () => _config.initialPath,
      isDisposed: () => _disposed,
      onChanged: _notify,
      onSaveFailed: (message) => onNoticeMessage?.call(message),
    );
    batch = FilesBatchCoordinator(
      dir: dir,
      transfers: transfers,
      readApi: () => _config.api,
      canWriteItem: canWriteItem,
      isDisposed: () => _disposed,
      onChanged: _notify,
      refreshCurrentView: refreshCurrentView,
    );
    transfer = FilesTransferCoordinator(
      dir: dir,
      prefs: prefs,
      transfers: transfers,
      readApi: () => _config.api,
      readAccountName: () => _config.accountName,
      readUploadOnly: () => _config.uploadOnly,
      readOnUploaded: () => _config.onUploaded,
      readTaskCenter: () => _config.taskCenter,
      readMobileExportOverride: () => _config.mobileExportOverride,
      readExportDirectoryFactory: () => _config.exportDirectoryFactory,
      readExportDirectoryCleanup: () => _config.exportDirectoryCleanup,
      isDisposed: () => _disposed,
      onChanged: _notify,
      refreshCurrentView: refreshCurrentView,
    );
    entries = FilesEntryActionsCoordinator(
      dir: dir,
      transfers: transfers,
      readApi: () => _config.api,
      canWriteItem: canWriteItem,
      canPurgeTrashItem: canPurgeTrashItem,
      isDisposed: () => _disposed,
      isBrowserRequestCurrent: isBrowserRequestCurrent,
      onChanged: _notify,
      refreshCurrentView: refreshCurrentView,
      loadTrash: loadTrash,
    );
    filter.searchFocusNode.addListener(_onSearchFocusChanged);
    _config.taskCenter?.addListener(transfer.handleTaskCenterChange);
  }

  FilesPageConfig _config;

  final VoidCallback? onHighlightActivated;
  final ValueChanged<double>? onRestoreScrollOffset;
  final double Function()? readScrollOffset;
  final ValueChanged<String>? onNoticeMessage;

  final FilesDirectoryState dir;
  final FilesSearchAndTrashState filter = FilesSearchAndTrashState();
  final FilesDisplayPrefsState prefs = FilesDisplayPrefsState();
  final FilesSelectionAndTransferState transfers =
      FilesSelectionAndTransferState();

  late final FilesPreferencesCoordinator preferences;
  late final FilesBatchCoordinator batch;
  late final FilesTransferCoordinator transfer;
  late final FilesEntryActionsCoordinator entries;

  Timer? _highlightTimer;
  bool _disposed = false;

  LightIsleApi get api => _config.api;
  bool get isAdmin => _config.isAdmin;
  String get accountName => _config.accountName;
  String? get accountId => _config.accountId;
  String get initialPath => _config.initialPath;
  bool get uploadOnly => _config.uploadOnly;
  FileType get initialUploadType => _config.initialUploadType;
  UploadTaskCenter? get taskCenter => _config.taskCenter;
  bool get isDisposed => _disposed;

  FileBrowserRepository get _browserRepository =>
      FileBrowserRepository(_config.api);
  FileSelectionSnapshot get selectionSnapshot => batch.selectionSnapshot;
  List<FileUploadJob> get uploadJobs => transfer.uploadJobs;
  bool get hasActiveLocalUploads => transfer.hasActiveLocalUploads;

  bool canWriteItem(FileEntry item) => item.canWrite || _config.isAdmin;

  bool canPurgeTrashItem(TrashEntry item) =>
      _config.isAdmin || item.originalPath.startsWith('Users/');

  List<(String, String)> get pathSegments => buildFilePathSegments(
    currentPath: dir.path,
    initialPath: _config.initialPath,
    rootName: dir.rootName,
  );

  String? get searchSubdirLabel =>
      fileSearchSubdirLabel(filter.searchScopeSubdir);

  bool get canPopPage =>
      dir.path == _config.initialPath &&
      !filter.showingTrash &&
      !filter.searching &&
      !transfers.selecting;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onSearchFocusChanged() {
    if (_disposed) return;
    final focused = filter.searchFocusNode.hasFocus;
    if (filter.searchInputFocused != focused) {
      filter.searchInputFocused = focused;
      _notify();
    }
  }

  void updateConfig(FilesPageConfig next) {
    final previous = _config;
    if (!identical(previous.taskCenter, next.taskCenter)) {
      previous.taskCenter?.removeListener(transfer.handleTaskCenterChange);
      next.taskCenter?.addListener(transfer.handleTaskCenterChange);
    }
    _config = next;

    final newRootIdentity = next.api.selectedRoot?.identity ?? 'default';
    if (previous.api != next.api ||
        previous.isAdmin != next.isAdmin ||
        previous.accountName != next.accountName ||
        previous.initialPath != next.initialPath ||
        dir.rootIdentity != newRootIdentity) {
      prefs.preferencesGeneration++;
      _highlightTimer?.cancel();
      _highlightTimer = null;
      transfer.cancelActiveUploads();
      transfer.rebuildUploadService();
      dir.resetForIdentity(next.initialPath, newRootIdentity);
      filter.reset();
      transfers.resetForRootChange();
      prefs.resetDefaults();
      // Do not call notifyListeners synchronously inside didUpdateWidget; the
      // host State is already scheduled to rebuild immediately with the reset
      // state, and async completions below will notify safely outside build.
      unawaited(initialize(deferInitialNotify: true));
    }
  }

  Future<void> initialize({bool deferInitialNotify = false}) async {
    final generation = ++prefs.preferencesGeneration;
    final initialSort = prefs.fileSort;
    final initialDirection = prefs.fileSortDirection;
    final initialLoad = loadFiles(notifyBeforeFetch: !deferInitialNotify);
    unawaited(preferences.loadSearchHistory());
    await preferences.restorePreferences(generation);
    if (_disposed || generation != prefs.preferencesGeneration) return;
    if (prefs.fileSort != initialSort ||
        prefs.fileSortDirection != initialDirection) {
      await loadFiles();
    } else {
      await initialLoad;
    }
    if (!_disposed &&
        generation == prefs.preferencesGeneration &&
        _config.uploadOnly &&
        dir.canWrite &&
        dir.error == null) {
      await transfer.pickUploads(type: _config.initialUploadType);
    }
  }

  bool isBrowserRequestCurrent(int generation, String rootIdentity) =>
      !_disposed &&
      generation == dir.loadGeneration &&
      dir.rootIdentity == rootIdentity &&
      (_config.api.selectedRoot?.identity ?? 'default') == rootIdentity;

  Future<void> loadFiles({
    String? target,
    bool more = false,
    bool keepSearch = false,
    double? restoreScrollOffset,
    String? highlightPath,
    bool notifyBeforeFetch = true,
  }) async {
    final generation = ++dir.loadGeneration;
    final rootIdentity = dir.rootIdentity;
    final directory = target ?? dir.path;
    dir.loading = true;
    dir.error = null;
    dir.directoryDiagnostic = null;
    if (notifyBeforeFetch) _notify();

    try {
      final response = await _browserRepository.list(
        directory: directory,
        limit: kFilesPageSize,
        cursor: more ? dir.nextCursor : '',
        sort: prefs.fileSort,
        direction: prefs.fileSortDirection,
      );
      if (!isBrowserRequestCurrent(generation, rootIdentity)) return;
      dir.rootName = response.rootName;
      dir.directoryDiagnostic = null;
      dir.path = directory;
      dir.canWrite = response.canWrite || _config.isAdmin;
      dir.entries = more
          ? [...dir.entries, ...response.entries]
          : response.entries;
      if (!more) {
        transfers.selectedPaths.clear();
        transfers.selectionAnchorPath = null;
        dir.highlightedPath = highlightPath;
      }
      dir.nextCursor = response.nextCursor;
      filter.searchTruncated = false;
      filter.showingTrash = false;
      if (!keepSearch) {
        filter.clearSearchState();
      }
      _notify();
      if (highlightPath != null &&
          dir.entries.any((entry) => entry.path == highlightPath)) {
        activateLocateHighlight(highlightPath);
      } else if (restoreScrollOffset != null) {
        onRestoreScrollOffset?.call(restoreScrollOffset);
      }
    } catch (error) {
      if (isBrowserRequestCurrent(generation, rootIdentity)) {
        dir.error = '读取目录失败：${userFacingError(error)}';
        dir.directoryDiagnostic = errorDiagnosticLabel(error);
        dir.canWrite = false;
        _notify();
      }
    } finally {
      if (isBrowserRequestCurrent(generation, rootIdentity)) {
        dir.loading = false;
        _notify();
      }
    }
  }

  Future<void> openContainingFolder(FileEntry item) async {
    final slash = item.path.lastIndexOf('/');
    final parent = slash < 0 ? '.' : item.path.substring(0, slash);
    filter.searchFocusNode.unfocus();
    await loadFiles(target: parent, highlightPath: item.path);
    var pagesLoaded = 0;
    while (!_disposed &&
        dir.path == parent &&
        !dir.entries.any((entry) => entry.path == item.path) &&
        dir.nextCursor.isNotEmpty &&
        pagesLoaded < kFilesLocateMaxPages) {
      pagesLoaded++;
      await loadFiles(target: parent, more: true, highlightPath: item.path);
    }
    if (!_disposed && dir.entries.any((entry) => entry.path == item.path)) {
      activateLocateHighlight(item.path);
    }
  }

  Future<void> searchFiles() async {
    final term = filter.searchController.text.trim();
    if (term.isEmpty) {
      dir.error = '请输入要搜索的关键词。';
      _notify();
      return;
    }
    final generation = ++dir.loadGeneration;
    final rootIdentity = dir.rootIdentity;
    if (!filter.searching && !filter.showingTrash) {
      filter.preSearchPath = dir.path;
      filter.preSearchScrollOffset = readScrollOffset?.call() ?? 0.0;
      final current = dir.path;
      filter.searchScopeSubdir =
          current.isNotEmpty && current != _config.initialPath ? current : null;
      filter.searchEntireRoot = filter.searchScopeSubdir == null;
    }
    final scopePath =
        (filter.searchScopeSubdir != null && !filter.searchEntireRoot)
        ? filter.searchScopeSubdir!
        : _config.initialPath;
    dir.loading = true;
    dir.error = null;
    filter.searching = true;
    filter.searchTerm = term;
    filter.showingTrash = false;
    dir.entries = [];
    transfers.selectedPaths.clear();
    transfers.selectionAnchorPath = null;
    dir.highlightedPath = null;
    dir.nextCursor = '';
    filter.searchTruncated = false;
    _notify();
    unawaited(preferences.recordSearchHistory(term));
    try {
      final response = await _browserRepository.search(
        initialPath: scopePath,
        term: term,
        limit: kFilesPageSize,
        kind: filter.searchKind,
        engine: filter.searchViaSpotlight ? 'spotlight' : '',
      );
      if (!isBrowserRequestCurrent(generation, rootIdentity)) return;
      dir.path = scopePath;
      transfers.selectedPaths.clear();
      transfers.selectionAnchorPath = null;
      dir.canWrite = response.canWrite || _config.isAdmin;
      dir.entries = response.entries;
      dir.nextCursor = '';
      filter.searchTruncated = response.truncated;
      _notify();
    } catch (error) {
      if (isBrowserRequestCurrent(generation, rootIdentity)) {
        dir.error = '搜索失败：${userFacingError(error)}';
        _notify();
      }
    } finally {
      if (isBrowserRequestCurrent(generation, rootIdentity)) {
        dir.loading = false;
        _notify();
      }
    }
  }

  void exitSearchAndRestore() {
    final target = filter.preSearchPath ?? _config.initialPath;
    final offset = filter.preSearchScrollOffset;
    filter.searchFocusNode.unfocus();
    unawaited(loadFiles(target: target, restoreScrollOffset: offset));
  }

  Future<void> loadTrash() async {
    final generation = ++dir.loadGeneration;
    final rootIdentity = dir.rootIdentity;
    filter.trashLoading = true;
    dir.error = null;
    filter.showingTrash = true;
    filter.searching = false;
    filter.preSearchPath = null;
    transfers.selectedPaths.clear();
    _notify();
    try {
      final response = await _browserRepository.trash();
      if (!isBrowserRequestCurrent(generation, rootIdentity)) return;
      filter.trashEntries = response;
      _notify();
    } catch (error) {
      if (isBrowserRequestCurrent(generation, rootIdentity)) {
        dir.error = '读取回收站失败：${userFacingError(error)}';
        _notify();
      }
    } finally {
      if (isBrowserRequestCurrent(generation, rootIdentity)) {
        filter.trashLoading = false;
        _notify();
      }
    }
  }

  Future<void> toggleTrash() async {
    if (filter.showingTrash) {
      await loadFiles(target: dir.path);
    } else {
      await loadTrash();
    }
  }

  Future<void> refreshCurrentView() async {
    if (filter.showingTrash) {
      await loadTrash();
    } else if (filter.searching) {
      await searchFiles();
    } else {
      await loadFiles(target: dir.path);
    }
  }

  void setFileView(String view) => preferences.setFileView(view);

  void setFileSort(String value) {
    if (preferences.setFileSort(value)) {
      unawaited(loadFiles());
    }
  }

  void setUploadAutoRename(bool value) =>
      preferences.setUploadAutoRename(value);

  void setSearchViaSpotlight(bool selected) {
    filter.searchViaSpotlight = selected;
    _notify();
    if (filter.searching && filter.searchController.text.trim().isNotEmpty) {
      unawaited(searchFiles());
    }
  }

  void setSearchKind(String kind) {
    filter.searchKind = kind;
    _notify();
    unawaited(searchFiles());
  }

  void setSearchEntireRoot(bool entireRoot) {
    if (filter.searchEntireRoot == entireRoot) return;
    filter.searchEntireRoot = entireRoot;
    _notify();
    unawaited(searchFiles());
  }

  void applySearchTerm(String term) {
    filter.searchController.text = term;
    unawaited(searchFiles());
  }

  void notifySearchQueryChanged() => _notify();

  void setDirectoryError(String? message) {
    dir.error = message;
    _notify();
  }

  void activateLocateHighlight(String path) {
    _highlightTimer?.cancel();
    dir.highlightedPath = path;
    _notify();
    onHighlightActivated?.call();
    _highlightTimer = Timer(kFilesHighlightDuration, () {
      if (!_disposed && dir.highlightedPath == path) {
        dir.highlightedPath = null;
        _notify();
      }
    });
  }

  Future<void> createFolder(String name) => entries.createFolder(name);

  Future<String?> operateEntry(
    FileEntry item, {
    required String action,
    required FileDestinationSelection selection,
  }) => entries.operateEntry(item, action: action, selection: selection);

  Future<void> renameEntry(FileEntry item, String newName) =>
      entries.renameEntry(item, newName);

  Future<void> trashEntry(FileEntry item) => entries.trashEntry(item);

  Future<void> restoreTrashEntry(TrashEntry item) =>
      entries.restoreTrashEntry(item);

  Future<void> purgeTrashEntry(TrashEntry item) =>
      entries.purgeTrashEntry(item);

  Future<String?> extractZip(FileEntry item) => entries.extractZip(item);

  Future<FilesCinemaLookupOutcome> lookupCinemaFilmForPreview(FileEntry item) =>
      entries.lookupCinemaFilmForPreview(item);

  Future<FilesTextPreviewOutcome?> loadTextPreview(FileEntry item) =>
      entries.loadTextPreview(item);

  void handlePopBack() {
    if (dir.loading) return;
    if (transfers.selecting) {
      batch.exitSelectionMode();
    } else if (filter.showingTrash) {
      unawaited(toggleTrash());
    } else if (filter.searching) {
      exitSearchAndRestore();
    } else {
      final segments = pathSegments;
      if (segments.length > 1) {
        unawaited(loadFiles(target: segments[segments.length - 2].$2));
      }
    }
  }

  void handleEscapeKey({required bool isEditingText}) {
    if (dir.loading || transfers.batchBusy) return;
    if (filter.searchFocusNode.hasFocus) {
      if (filter.searching) {
        exitSearchAndRestore();
      } else {
        filter.searchFocusNode.unfocus();
      }
      return;
    }
    if (isEditingText) return;
    if (transfers.selecting) {
      batch.exitSelectionMode();
    } else if (filter.searching) {
      exitSearchAndRestore();
    } else if (filter.showingTrash) {
      unawaited(toggleTrash());
    }
  }

  void handleSelectAllKey({required bool isEditingText}) {
    if (isEditingText ||
        dir.loading ||
        transfers.batchBusy ||
        filter.showingTrash) {
      return;
    }
    batch.toggleSelectAllVisible(enterSelectionMode: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _highlightTimer?.cancel();
    _highlightTimer = null;
    filter.searchFocusNode.removeListener(_onSearchFocusChanged);
    prefs.preferencesGeneration++;
    filter.dispose();
    _config.taskCenter?.removeListener(transfer.handleTaskCenterChange);
    if (_config.taskCenter == null) transfer.cancelActiveUploads();
    super.dispose();
  }
}
