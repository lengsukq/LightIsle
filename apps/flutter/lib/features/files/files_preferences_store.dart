import 'dart:async';

import 'package:flutter/foundation.dart';

import 'file_browser_preferences.dart';
import 'file_search_history_store.dart';
import 'files_page_state_models.dart';

/// Persists file-browser display preferences and search history scoped to
/// `(server, account, physical root, initialPath)`.
class FilesPreferencesCoordinator {
  FilesPreferencesCoordinator({
    required this.prefsState,
    required this.filterState,
    required this.readServerOrigin,
    required this.readAccountName,
    required this.readRootIdentity,
    required this.readInitialPath,
    required this.isDisposed,
    required this.onChanged,
    required this.onSaveFailed,
  });

  final FilesDisplayPrefsState prefsState;
  final FilesSearchAndTrashState filterState;
  final Uri Function() readServerOrigin;
  final String Function() readAccountName;
  final String Function() readRootIdentity;
  final String Function() readInitialPath;
  final bool Function() isDisposed;
  final VoidCallback onChanged;
  final ValueChanged<String> onSaveFailed;

  static const Set<String> _validSortFields = {'name', 'mtime', 'size'};
  static const Set<String> _validSortDirections = {'asc', 'desc'};

  String get preferencesScope => FileBrowserPreferences.scope(
    server: readServerOrigin(),
    account: readAccountName(),
    rootIdentity: readRootIdentity(),
    initialPath: readInitialPath(),
  );

  String get searchHistoryScope => FileSearchHistoryStore.scope(
    server: readServerOrigin(),
    account: readAccountName(),
    rootIdentity: readRootIdentity(),
  );

  FileBrowserPreferences get currentPreferences => FileBrowserPreferences(
    view: prefsState.fileView,
    sort: prefsState.fileSort,
    direction: prefsState.fileSortDirection,
    autoRename: prefsState.uploadAutoRename,
  );

  Future<void> restorePreferences(int generation) async {
    final scope = preferencesScope;
    try {
      final saved = await FileBrowserPreferences.load(scope);
      if (isDisposed() || generation != prefsState.preferencesGeneration) {
        return;
      }
      prefsState.fileView = saved.view;
      prefsState.fileSort = saved.sort;
      prefsState.fileSortDirection = saved.direction;
      prefsState.uploadAutoRename = saved.autoRename;
      onChanged();
    } catch (_) {
      if (!isDisposed() && generation == prefsState.preferencesGeneration) {
        prefsState.resetDefaults();
        onChanged();
      }
    }
  }

  Future<void> savePreferences() async {
    final scope = preferencesScope;
    final values = currentPreferences;
    final write = prefsState.preferenceWrites
        .catchError((Object _) {})
        .then((_) => values.save(scope));
    prefsState.preferenceWrites = write;
    try {
      await write;
    } catch (_) {
      if (!isDisposed()) {
        onSaveFailed('无法保存本机文件浏览偏好，下次打开可能恢复默认设置。');
      }
    }
  }

  void setFileView(String view) {
    if (view == prefsState.fileView) return;
    prefsState.fileView = view;
    onChanged();
    unawaited(savePreferences());
  }

  /// Updates sort field and direction, returning true when a directory reload
  /// is required.
  bool setFileSort(String value) {
    final parts = value.split(':');
    if (parts.length != 2 ||
        !_validSortFields.contains(parts[0]) ||
        !_validSortDirections.contains(parts[1])) {
      return false;
    }
    if (parts[0] == prefsState.fileSort &&
        parts[1] == prefsState.fileSortDirection) {
      return false;
    }
    prefsState.fileSort = parts[0];
    prefsState.fileSortDirection = parts[1];
    onChanged();
    unawaited(savePreferences());
    return true;
  }

  void setUploadAutoRename(bool value) {
    if (value == prefsState.uploadAutoRename) return;
    prefsState.uploadAutoRename = value;
    onChanged();
    unawaited(savePreferences());
  }

  Future<void> loadSearchHistory() async {
    final generation = ++filterState.searchHistoryGeneration;
    final scope = searchHistoryScope;
    try {
      final loaded = await FileSearchHistoryStore.load(scope);
      if (isDisposed() || generation != filterState.searchHistoryGeneration) {
        return;
      }
      filterState.recentSearches = loaded;
      onChanged();
    } catch (_) {
      // Non-critical history read should never block file browsing.
    }
  }

  Future<void> recordSearchHistory(String term) async {
    final generation = filterState.searchHistoryGeneration;
    final scope = searchHistoryScope;
    try {
      final updated = await FileSearchHistoryStore.record(scope, term);
      if (isDisposed() || generation != filterState.searchHistoryGeneration) {
        return;
      }
      filterState.recentSearches = updated;
      onChanged();
    } catch (error) {
      debugPrint('FilesPreferencesCoordinator.recordSearchHistory failed: $error');
    }
  }

  Future<void> removeSearchHistory(String term) async {
    final generation = filterState.searchHistoryGeneration;
    final scope = searchHistoryScope;
    try {
      final updated = await FileSearchHistoryStore.remove(scope, term);
      if (isDisposed() || generation != filterState.searchHistoryGeneration) {
        return;
      }
      filterState.recentSearches = updated;
      onChanged();
    } catch (error) {
      debugPrint('FilesPreferencesCoordinator.removeSearchHistory failed: $error');
    }
  }

  Future<void> clearSearchHistory() async {
    final generation = filterState.searchHistoryGeneration;
    final scope = searchHistoryScope;
    try {
      await FileSearchHistoryStore.clear(scope);
      if (isDisposed() || generation != filterState.searchHistoryGeneration) {
        return;
      }
      filterState.recentSearches = const <String>[];
      onChanged();
    } catch (error) {
      debugPrint('FilesPreferencesCoordinator.clearSearchHistory failed: $error');
    }
  }
}
