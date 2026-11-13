part of 'files_page.dart';

extension _FilesPagePreferences on _FilesPageState {
  String get _filePreferencesScope => FileBrowserPreferences.scope(
    server: widget.api.uri('/'),
    account: widget.accountName,
    rootIdentity: _dir.rootIdentity,
    initialPath: widget.initialPath,
  );
  FileBrowserPreferences get _currentPreferences => FileBrowserPreferences(
    view: _prefsState.fileView,
    sort: _prefsState.fileSort,
    direction: _prefsState.fileSortDirection,
    autoRename: _prefsState.uploadAutoRename,
  );
  Future<void> _restorePreferences(int generation) async {
    final scope = _filePreferencesScope;
    try {
      final saved = await FileBrowserPreferences.load(scope);
      if (!mounted || generation != _prefsState.preferencesGeneration) return;
      _refreshState(() {
        _prefsState.fileView = saved.view;
        _prefsState.fileSort = saved.sort;
        _prefsState.fileSortDirection = saved.direction;
        _prefsState.uploadAutoRename = saved.autoRename;
      });
    } catch (_) {
      if (mounted && generation == _prefsState.preferencesGeneration) {
        _refreshState(_prefsState.resetDefaults);
      }
    }
  }

  Future<void> _savePreferences() async {
    final scope = _filePreferencesScope;
    final values = _currentPreferences;
    final write = _prefsState.preferenceWrites
        .catchError((Object _) {})
        .then((_) => values.save(scope));
    _prefsState.preferenceWrites = write;
    try {
      await write;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('无法保存本机文件浏览偏好，下次打开可能恢复默认设置。')),
        );
      }
    }
  }

  void _setFileView(String view) {
    if (view == _prefsState.fileView) return;
    _refreshState(() => _prefsState.fileView = view);
    unawaited(_savePreferences());
  }

  void _setFileSort(String value) {
    final parts = value.split(':');
    if (parts.length != 2 ||
        !{'name', 'mtime', 'size'}.contains(parts[0]) ||
        !{'asc', 'desc'}.contains(parts[1])) {
      return;
    }
    if (parts[0] == _prefsState.fileSort &&
        parts[1] == _prefsState.fileSortDirection) {
      return;
    }
    _refreshState(() {
      _prefsState.fileSort = parts[0];
      _prefsState.fileSortDirection = parts[1];
    });
    unawaited(_savePreferences());
    unawaited(_loadFiles());
  }

  void _setUploadAutoRename(bool value) {
    if (value == _prefsState.uploadAutoRename) return;
    _refreshState(() => _prefsState.uploadAutoRename = value);
    unawaited(_savePreferences());
  }

  String get _searchHistoryScope => FileSearchHistoryStore.scope(
    server: widget.api.uri('/'),
    account: widget.accountName,
    rootIdentity: _dir.rootIdentity,
  );

  Future<void> _loadSearchHistory() async {
    final generation = ++_filter.searchHistoryGeneration;
    final scope = _searchHistoryScope;
    try {
      final loaded = await FileSearchHistoryStore.load(scope);
      if (!mounted ||
          _disposed ||
          generation != _filter.searchHistoryGeneration) {
        return;
      }
      _refreshState(() => _filter.recentSearches = loaded);
    } catch (_) {
      // Non-critical history read should never block file browsing.
    }
  }

  Future<void> _recordSearchHistory(String term) async {
    final generation = _filter.searchHistoryGeneration;
    final scope = _searchHistoryScope;
    try {
      final updated = await FileSearchHistoryStore.record(scope, term);
      if (!mounted ||
          _disposed ||
          generation != _filter.searchHistoryGeneration) {
        return;
      }
      _refreshState(() => _filter.recentSearches = updated);
    } catch (_) {}
  }

  Future<void> _removeSearchHistory(String term) async {
    final generation = _filter.searchHistoryGeneration;
    final scope = _searchHistoryScope;
    try {
      final updated = await FileSearchHistoryStore.remove(scope, term);
      if (!mounted ||
          _disposed ||
          generation != _filter.searchHistoryGeneration) {
        return;
      }
      _refreshState(() => _filter.recentSearches = updated);
    } catch (_) {}
  }

  Future<void> _clearSearchHistory() async {
    final generation = _filter.searchHistoryGeneration;
    final scope = _searchHistoryScope;
    try {
      await FileSearchHistoryStore.clear(scope);
      if (!mounted ||
          _disposed ||
          generation != _filter.searchHistoryGeneration) {
        return;
      }
      _refreshState(() => _filter.recentSearches = const <String>[]);
    } catch (_) {}
  }

  Future<void> _initialize() async {
    final generation = ++_prefsState.preferencesGeneration;
    final initialSort = _prefsState.fileSort;
    final initialDirection = _prefsState.fileSortDirection;
    final initialLoad = _loadFiles();
    unawaited(_loadSearchHistory());
    await _restorePreferences(generation);
    if (!mounted || generation != _prefsState.preferencesGeneration) return;
    if (_prefsState.fileSort != initialSort ||
        _prefsState.fileSortDirection != initialDirection) {
      await _loadFiles();
    } else {
      await initialLoad;
    }
    if (mounted &&
        generation == _prefsState.preferencesGeneration &&
        widget.uploadOnly &&
        _dir.canWrite &&
        _dir.error == null) {
      await _pickUploads(type: widget.initialUploadType);
    }
  }
}
