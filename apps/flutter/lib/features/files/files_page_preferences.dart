part of 'files_page.dart';

extension _FilesPagePreferences on _FilesPageState {
  String get _filePreferencesScope => FileBrowserPreferences.scope(
    server: widget.api.uri('/'),
    account: widget.accountName,
    rootIdentity: _rootIdentity,
    initialPath: widget.initialPath,
  );
  FileBrowserPreferences get _currentPreferences => FileBrowserPreferences(
    view: _fileView,
    sort: _fileSort,
    direction: _fileSortDirection,
    autoRename: _uploadAutoRename,
  );
  Future<void> _restorePreferences(int generation) async {
    final scope = _filePreferencesScope;
    try {
      final saved = await FileBrowserPreferences.load(scope);
      if (!mounted || generation != _preferencesGeneration) return;
      _refreshState(() {
        _fileView = saved.view;
        _fileSort = saved.sort;
        _fileSortDirection = saved.direction;
        _uploadAutoRename = saved.autoRename;
      });
    } catch (_) {
      // A preference read failure must never prevent accessing NAS files.
      if (mounted && generation == _preferencesGeneration) {
        _refreshState(() {
          _fileView = 'list';
          _fileSort = 'name';
          _fileSortDirection = 'asc';
          _uploadAutoRename = false;
        });
      }
    }
  }

  Future<void> _savePreferences() async {
    final scope = _filePreferencesScope;
    final values = _currentPreferences;
    // Serialize writes so rapid toggles cannot leave an older preference
    // snapshot on disk after the user has already chosen a newer one.
    final write = _preferenceWrites
        .catchError((Object _) {})
        .then((_) => values.save(scope));
    _preferenceWrites = write;
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
    if (view == _fileView) return;
    _refreshState(() => _fileView = view);
    unawaited(_savePreferences());
  }

  void _setFileSort(String value) {
    final parts = value.split(':');
    if (parts.length != 2 ||
        !{'name', 'mtime', 'size'}.contains(parts[0]) ||
        !{'asc', 'desc'}.contains(parts[1])) {
      return;
    }
    if (parts[0] == _fileSort && parts[1] == _fileSortDirection) return;
    _refreshState(() {
      _fileSort = parts[0];
      _fileSortDirection = parts[1];
    });
    unawaited(_savePreferences());
    unawaited(_loadFiles());
  }

  void _setUploadAutoRename(bool value) {
    if (value == _uploadAutoRename) return;
    _refreshState(() => _uploadAutoRename = value);
    unawaited(_savePreferences());
  }

  Future<void> _initialize() async {
    final generation = ++_preferencesGeneration;
    // Start the initial directory request immediately. Reading local platform
    // preferences can be slow or unavailable in embedded/test environments;
    // it must not leave normal file actions disabled during startup.
    final initialSort = _fileSort;
    final initialDirection = _fileSortDirection;
    final initialLoad = _loadFiles();
    await _restorePreferences(generation);
    if (!mounted || generation != _preferencesGeneration) return;
    if (_fileSort != initialSort || _fileSortDirection != initialDirection) {
      // Discard the first unsorted response via _loadGeneration and request
      // the remembered server order. The current directory stays unchanged.
      await _loadFiles();
    } else {
      await initialLoad;
    }
    if (mounted &&
        generation == _preferencesGeneration &&
        widget.uploadOnly &&
        _canWrite &&
        _error == null) {
      await _pickUploads(type: widget.initialUploadType);
    }
  }
}
