part of 'files_page.dart';

extension _FilesPageBrowserOperations on _FilesPageState {
  bool _browserRequestCurrent(int generation, String rootIdentity) =>
      mounted &&
      !_disposed &&
      generation == _dir.loadGeneration &&
      _dir.rootIdentity == rootIdentity &&
      (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity;

  Future<void> _loadFiles({
    String? target,
    bool more = false,
    bool keepSearch = false,
  }) async {
    final generation = ++_dir.loadGeneration;
    final rootIdentity = _dir.rootIdentity;
    final directory = target ?? _dir.path;
    _refreshState(() {
      _dir.loading = true;
      _dir.error = null;
      _dir.directoryDiagnostic = null;
    });

    try {
      final response = await _browserRepository.list(
        directory: directory,
        limit: _pageSize,
        cursor: more ? _dir.nextCursor : '',
        sort: _prefsState.fileSort,
        direction: _prefsState.fileSortDirection,
      );
      if (!_browserRequestCurrent(generation, rootIdentity)) return;
      _refreshState(() {
        _dir.rootName = response.rootName;
        _dir.directoryDiagnostic = null;
        _dir.path = directory;
        _dir.canWrite = response.canWrite || widget.isAdmin;
        _dir.entries = more
            ? [..._dir.entries, ...response.entries]
            : response.entries;
        if (!more) _transfers.selectedPaths.clear();
        _dir.nextCursor = response.nextCursor;
        _filter.searchTruncated = false;
        _filter.showingTrash = false;
        if (!keepSearch) {
          _filter.clearSearchState();
        }
      });
    } catch (error) {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() {
          _dir.error = '读取目录失败：${_friendlyError(error)}';
          _dir.directoryDiagnostic = errorDiagnosticLabel(error);
          _dir.canWrite = false;
        });
      }
    } finally {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _dir.loading = false);
      }
    }
  }

  Future<void> _searchFiles() async {
    final term = _filter.searchController.text.trim();
    if (term.runes.length < 2) {
      _refreshState(() => _dir.error = '请输入至少两个字符再搜索。');
      return;
    }
    final generation = ++_dir.loadGeneration;
    final rootIdentity = _dir.rootIdentity;
    if (!_filter.searching && !_filter.showingTrash) {
      _filter.preSearchPath = _dir.path;
    }
    _refreshState(() {
      _dir.loading = true;
      _dir.error = null;
      _filter.searching = true;
      _filter.searchTerm = term;
      _filter.showingTrash = false;
      _dir.entries = [];
      _transfers.selectedPaths.clear();
      _dir.nextCursor = '';
      _filter.searchTruncated = false;
    });
    try {
      final response = await _browserRepository.search(
        initialPath: widget.initialPath,
        term: term,
        limit: _pageSize,
        kind: _filter.searchKind,
        engine: _filter.searchViaSpotlight ? 'spotlight' : '',
      );
      if (!_browserRequestCurrent(generation, rootIdentity)) return;
      _refreshState(() {
        _dir.path = widget.initialPath;
        _transfers.selectedPaths.clear();
        _dir.canWrite = response.canWrite || widget.isAdmin;
        _dir.entries = response.entries;
        _dir.nextCursor = '';
        _filter.searchTruncated = response.truncated;
      });
    } catch (error) {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _dir.error = '搜索失败：${_friendlyError(error)}');
      }
    } finally {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _dir.loading = false);
      }
    }
  }

  Future<void> _loadTrash() async {
    final generation = ++_dir.loadGeneration;
    final rootIdentity = _dir.rootIdentity;
    _refreshState(() {
      _filter.trashLoading = true;
      _dir.error = null;
      _filter.showingTrash = true;
      _filter.searching = false;
      _filter.preSearchPath = null;
      _transfers.selectedPaths.clear();
    });
    try {
      final response = await _browserRepository.trash();
      if (!_browserRequestCurrent(generation, rootIdentity)) return;
      _refreshState(() => _filter.trashEntries = response);
    } catch (error) {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _dir.error = '读取回收站失败：${_friendlyError(error)}');
      }
    } finally {
      if (_browserRequestCurrent(generation, rootIdentity)) {
        _refreshState(() => _filter.trashLoading = false);
      }
    }
  }

  Future<void> _toggleTrash() async {
    if (_filter.showingTrash) {
      await _loadFiles(target: _dir.path);
    } else {
      await _loadTrash();
    }
  }

  Future<void> _createFolder() async {
    if (!_dir.canWrite) return;
    final name = await _askFolderName();
    if (name == null) return;
    final path = _joinRelative(_dir.path, name);
    _refreshState(() => _dir.error = null);
    try {
      await widget.api.send(
        'POST',
        '/api/v2/files/folders',
        body: {'path': path},
      );
      await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _dir.error = '新建文件夹失败：${_friendlyError(error)}');
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
      _refreshState(() => _dir.error = '不能将文件夹移动或复制到自己的子目录中。');
      return;
    }
    _refreshState(() => _dir.error = null);
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
      _refreshState(() => _dir.error = '文件操作失败：${_friendlyError(error)}');
    }
  }

  Future<void> _rename(FileEntry item) async {
    if (!_canWriteItem(item)) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          _RenameFileDialog(initialName: item.name, isFolder: item.isFolder),
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
      _refreshState(() => _dir.error = '重命名失败：${_friendlyError(error)}');
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
    _refreshState(() => _dir.error = null);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/files',
        query: {'path': item.path},
      );
      await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _dir.error = '未能确认移入回收站的结果：${_friendlyError(error)}');
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
      _refreshState(() => _dir.error = '未能确认恢复结果：${_friendlyError(error)}');
    }
  }

  Future<void> _refreshCurrentView() async {
    if (_filter.showingTrash) {
      await _loadTrash();
    } else if (_filter.searching) {
      await _searchFiles();
    } else {
      await _loadFiles(target: _dir.path);
    }
  }

  Future<void> _extractZip(FileEntry item) async {
    if (!_canWriteItem(item) || _dir.loading || _transfers.batchBusy) return;
    _refreshState(() {
      _dir.loading = true;
      _dir.error = null;
    });
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v2/files/extract',
        body: {'path': item.path},
      );
      if (!mounted) return;
      await _refreshCurrentView();
      if (!mounted) return;
      final target = result['targetPath']?.toString() ?? item.name;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已解压到：$target')));
    } catch (error) {
      _refreshState(() {
        _dir.loading = false;
        _dir.error = '解压失败：${_friendlyError(error)}';
      });
    }
  }

  Future<void> _purgeTrash(TrashEntry item) async {
    if (!widget.isAdmin && !item.originalPath.startsWith('Users/')) return;
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
      _refreshState(() => _dir.error = '未能确认永久删除结果：${_friendlyError(error)}');
    }
  }
}
