part of 'files_page.dart';

extension _FilesPageBrowserOperations on _FilesPageState {
  bool _browserRequestCurrent(int generation, String rootIdentity) =>
      mounted &&
      !_disposed &&
      generation == _loadGeneration &&
      _rootIdentity == rootIdentity &&
      (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity;
  Future<void> _loadFiles({
    String? target,
    bool more = false,
    bool keepSearch = false,
  }) async {
    final generation = ++_loadGeneration;
    final rootIdentity = _rootIdentity;
    final directory = target ?? _path;
    _refreshState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await _browserRepository.list(
        directory: directory,
        limit: _pageSize,
        cursor: more ? _nextCursor : '',
        sort: _fileSort,
        direction: _fileSortDirection,
      );
      if (!_browserRequestCurrent(generation, rootIdentity)) return;
      _refreshState(() {
        _rootName = response.rootName;
        _path = directory;
        _canWrite = response.canWrite || widget.isAdmin;
        _entries = more ? [..._entries, ...response.entries] : response.entries;
        if (!more) _selectedPaths.clear();
        _nextCursor = response.nextCursor;
        _searchTruncated = false;
        _showingTrash = false;
        if (!keepSearch) {
          _searching = false;
          _searchTerm = '';
          _searchController.clear();
        }
      });
    } catch (error) {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _error = '读取目录失败：${_friendlyError(error)}');
      }
    } finally {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _loading = false);
      }
    }
  }

  Future<void> _searchFiles() async {
    final term = _searchController.text.trim();
    if (term.runes.length < 2) {
      _refreshState(() => _error = '请输入至少两个字符再搜索。');
      return;
    }
    final generation = ++_loadGeneration;
    final rootIdentity = _rootIdentity;
    _refreshState(() {
      _loading = true;
      _error = null;
      _searching = true;
      _searchTerm = term;
      _showingTrash = false;
      _entries = [];
      _selectedPaths.clear();
      _nextCursor = '';
      _searchTruncated = false;
    });
    try {
      final response = await _browserRepository.search(
        initialPath: widget.initialPath,
        term: term,
        limit: _pageSize,
      );
      if (!_browserRequestCurrent(generation, rootIdentity)) return;
      _refreshState(() {
        _path = widget.initialPath;
        _selectedPaths.clear();
        _canWrite = response.canWrite || widget.isAdmin;
        _entries = response.entries;
        _nextCursor = '';
        _searchTruncated = response.truncated;
      });
    } catch (error) {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _error = '搜索失败：${_friendlyError(error)}');
      }
    } finally {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _loading = false);
      }
    }
  }

  Future<void> _loadTrash() async {
    final generation = ++_loadGeneration;
    final rootIdentity = _rootIdentity;
    _refreshState(() {
      _trashLoading = true;
      _error = null;
      _showingTrash = true;
      _searching = false;
      _selectedPaths.clear();
    });
    try {
      final response = await _browserRepository.trash();
      if (!_browserRequestCurrent(generation, rootIdentity)) return;
      _refreshState(() => _trashEntries = response);
    } catch (error) {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _error = '读取回收站失败：${_friendlyError(error)}');
      }
    } finally {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _trashLoading = false);
      }
    }
  }

  Future<void> _toggleTrash() async {
    if (_showingTrash) {
      await _loadFiles(target: _path);
    } else {
      await _loadTrash();
    }
  }

  Future<void> _createFolder() async {
    if (!_canWrite) return;
    final name = await _askFolderName();
    if (name == null) return;
    final path = _joinRelative(_path, name);
    _refreshState(() => _error = null);
    try {
      await widget.api.send(
        'POST',
        '/api/v2/files/folders',
        body: {'path': path},
      );
      await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _error = '新建文件夹失败：${_friendlyError(error)}');
    }
  }

  Future<String?> _askFolderName() async {
    final controller = TextEditingController();
    String? validation;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final value = controller.text.trim();
            final issue = validateFileName(value);
            if (issue != null) {
              setDialogState(() => validation = issue);
            } else {
              Navigator.pop(dialogContext, value);
            }
          }

          return AlertDialog(
            title: const Text('新建文件夹'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 150,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: '文件夹名称',
                    errorText: validation,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('创建')),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _operate(FileEntry item, String action) async {
    if (action == 'move' && !_canWriteItem(item)) return;
    final selection = await showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: widget.api,
        sourceName: item.name,
        sourcePath: item.path,
        action: action,
      ),
    );
    if (selection == null || !mounted) return;
    if (item.isFolder && selection.path.startsWith('${item.path}/')) {
      _refreshState(() => _error = '不能将文件夹移动或复制到自己的子目录中。');
      return;
    }
    _refreshState(() => _error = null);
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v2/files/operations',
        body: <String, Object>{
          'action': action,
          'from': item.path,
          'to': selection.path,
          'conflict': selection.conflict,
        },
      );
      if (!mounted) return;
      await _refreshCurrentView();
      if (!mounted) return;
      final message = result['skipped'] == true
          ? '目标已存在，已安全跳过'
          : '操作完成：${result['finalTo']?.toString() ?? selection.path}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      _refreshState(() => _error = '文件操作失败：${_friendlyError(error)}');
    }
  }

  Future<void> _rename(FileEntry item) async {
    if (!_canWriteItem(item)) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameFileDialog(initialName: item.name),
    );
    if (!mounted || name == null || name == item.name) return;
    final slash = item.path.lastIndexOf('/');
    final destination = slash < 0
        ? name
        : '${item.path.substring(0, slash)}/$name';
    try {
      await widget.api.send(
        'POST',
        '/api/v2/files/operations',
        body: {
          'action': 'move',
          'from': item.path,
          'to': destination,
          'conflict': '',
        },
      );
      if (mounted) await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _error = '重命名失败：${_friendlyError(error)}');
    }
  }

  Future<void> _trash(FileEntry item) async {
    if (!_canWriteItem(item)) return;
    final confirmed = await confirmAction(
      context,
      '移到回收站',
      '“${item.name}”会移入回收站，可以之后恢复。',
      action: '移入回收站',
    );
    if (!confirmed) return;
    _refreshState(() => _error = null);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/files',
        query: {'path': item.path},
      );
      await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _error = '移入回收站失败：${_friendlyError(error)}');
    }
  }

  Future<void> _restoreTrash(TrashEntry item) async {
    if (!await confirmAction(
      context,
      '恢复文件',
      '恢复到原位置“${item.originalPath}”。如果该路径已存在，文件不会被覆盖。',
      action: '恢复',
    )) {
      return;
    }
    try {
      await widget.api.send(
        'POST',
        '/api/v2/files/trash/${Uri.encodeComponent(item.id)}/restore',
      );
      await _loadTrash();
    } catch (error) {
      _refreshState(() => _error = '恢复失败：${_friendlyError(error)}');
    }
  }

  Future<void> _refreshCurrentView() async {
    if (_searching) {
      await _searchFiles();
    } else {
      await _loadFiles(target: _path);
    }
  }

  Future<void> _purgeTrash(TrashEntry item) async {
    if (!widget.isAdmin) return;
    if (!await confirmAction(
      context,
      '永久删除文件？',
      '“${item.name}”将被永久删除，此操作无法撤销。',
      action: '永久删除',
    )) {
      return;
    }
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/files/trash/${Uri.encodeComponent(item.id)}',
      );
      await _loadTrash();
    } catch (error) {
      _refreshState(() => _error = '永久删除失败：${_friendlyError(error)}');
    }
  }
}
