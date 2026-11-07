part of 'files_page.dart';

extension _FilesPageSelection on _FilesPageState {
  bool _batchSelectionStillCurrent(
    String rootIdentity,
    String directory,
    List<String> paths,
  ) =>
      _rootIdentity == rootIdentity &&
      (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity &&
      _path == directory &&
      _selectedPaths.length == paths.length &&
      _selectedPaths.containsAll(paths) &&
      _selectionSnapshot.writableSelection;
  Future<void> _batchTransfer(String action) async {
    if (_batchBusy || _loading || _selectedPaths.isEmpty) return;
    final selection = _selectionSnapshot;
    final byPath = {for (final item in _entries) item.path: item};
    final paths = _selectedPaths.toList(growable: false);
    if (!selection.writableSelection) {
      _refreshState(() => _error = '选择已变更或包含只读项目，请刷新目录再试。');
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final sourceDirectory = _path;
    final destination = await showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: widget.api,
        sourceName: '',
        sourcePath: '',
        action: action,
        directoryOnly: true,
      ),
    );
    if (destination == null || !mounted) return;
    if (!_batchSelectionStillCurrent(rootIdentity, sourceDirectory, paths)) {
      _refreshState(() => _error = '共享目录或选择已变化，请刷新后重新选择文件。');
      return;
    }
    final plan = FileBatchOperations.planTransfer(
      action: action,
      items: [for (final path in paths) byPath[path]!],
      destination: destination.path,
    );
    if (plan.invalidPaths.isNotEmpty) {
      _refreshState(
        () => _error =
            '有 ${plan.invalidPaths.length} 个项目的目标为原位置或自身子目录，请重新选择其他目录。',
      );
      return;
    }
    final confirmed = await confirmAction(
      context,
      action == 'move' ? '批量移动文件' : '批量复制文件',
      '将 ${plan.items.length} 项${action == 'move' ? '移动' : '复制'}到'
      '“${destination.path == '.' ? '根目录' : destination.path}”？'
      '同名文件自动改名，原目标文件不会覆盖。'
      '中途失败时已完成的项目会保留，剩余项目可重试。',
      action: action == 'move' ? '开始移动' : '开始复制',
    );
    if (!confirmed || !mounted) return;
    if (!_batchSelectionStillCurrent(rootIdentity, sourceDirectory, paths)) {
      _refreshState(() => _error = '共享目录或选择已变化，未开始批量操作。');
      return;
    }
    _updateState(() {
      _batchBusy = true;
      _error = null;
    });
    try {
      final result = await _batchOperations.transfer(
        action: action,
        plan: plan,
        destination: destination.path,
        stillCurrent: () =>
            mounted &&
            _rootIdentity == rootIdentity &&
            _path == sourceDirectory &&
            (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity,
      );
      if (mounted &&
          _rootIdentity == rootIdentity &&
          _path == sourceDirectory &&
          (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity) {
        await _refreshCurrentView();
        if (mounted &&
            _rootIdentity == rootIdentity &&
            (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity) {
          _updateState(() {
            _selectedPaths
              ..clear()
              ..addAll(result.failedPaths);
            _error = result.failedPaths.isEmpty
                ? null
                : '已完成 ${result.completed} 项，${result.failedPaths.length} 项未完成；失败项目仍保留选择，可检查权限后重试。';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '批量${action == 'move' ? '移动' : '复制'}已完成 ${result.completed}/${plan.items.length} 项。',
              ),
            ),
          );
        }
      }
    } finally {
      if (mounted) _updateState(() => _batchBusy = false);
    }
  }

  void _toggleSelected(FileEntry item, bool? selected) {
    if (selected == true &&
        !_selectedPaths.contains(item.path) &&
        _selectedPaths.length >= 50) {
      _refreshState(() => _error = '每次最多选择 50 项文件。');
      return;
    }
    _refreshState(() {
      if (selected == true) {
        _selectedPaths.add(item.path);
      } else {
        _selectedPaths.remove(item.path);
      }
      _error = null;
    });
  }

  Future<void> _batchSave() async {
    if (_loading || _batchBusy || _selectedPaths.isEmpty) return;
    final selection = _selectionSnapshot;
    if (!selection.fullyLoaded) {
      _refreshState(() => _error = '文件列表已变化，请重新选择。');
      return;
    }
    if (!selection.canExportFiles) {
      _refreshState(() => _error = '批量保存暂不支持文件夹，请只选择文件。');
      return;
    }
    final selected = selection.selectedEntries;
    _refreshState(() {
      _batchBusy = true;
      _error = null;
    });
    try {
      final message = await exportSelectedFiles(
        widget.api,
        items: [
          for (final item in selected)
            (path: item.path, name: item.name, size: item.size),
        ],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) {
        _refreshState(() => _error = '批量保存失败：${_friendlyError(error)}');
      }
    } finally {
      if (mounted) _refreshState(() => _batchBusy = false);
    }
  }

  Future<void> _batchTrash() async {
    final paths = _selectedPaths.toList(growable: false);
    if (paths.isEmpty) return;
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final sourceDirectory = _path;
    if (paths.length > FileSelectionSnapshot.maxSelection) {
      _refreshState(() => _error = '每次最多选择 50 项移入回收站。');
      return;
    }
    if (!_selectionSnapshot.writableSelection) {
      _refreshState(() => _error = '所选项目包含只读或已变更的项目，请刷新后重试。');
      return;
    }
    if (!await confirmAction(
      context,
      '批量移到回收站',
      '将选中的 ${paths.length} 项移到回收站？之后可以逐项恢复。',
      action: '移入回收站',
    )) {
      return;
    }
    if (!mounted) return;
    if (!_batchSelectionStillCurrent(rootIdentity, sourceDirectory, paths)) {
      _refreshState(() => _error = '共享目录或选择已变化，未执行批量删除。');
      return;
    }

    _refreshState(() => _error = null);
    try {
      final result = await _batchOperations.trash(paths);
      if (!mounted ||
          _rootIdentity != rootIdentity ||
          (widget.api.selectedRoot?.identity ?? 'default') != rootIdentity) {
        return;
      }
      await _refreshCurrentView();
      if (!mounted ||
          _rootIdentity != rootIdentity ||
          (widget.api.selectedRoot?.identity ?? 'default') != rootIdentity) {
        return;
      }
      if (result.failureCount > 0) {
        _refreshState(() {
          _selectedPaths.addAll(result.failedPaths);
          _error = result.needsRootCheck
              ? '已确认 ${result.succeeded} 项移入回收站。硬盘连接发生变化，部分操作结果不确定；请重新连接原硬盘，检查原目录和回收站后再重试。'
              : result.needsTrashCheck
              ? '已确认 ${result.succeeded} 项移入回收站。检测到文件已变化，后续操作已停止；请检查原目录和回收站。'
              : '${result.failureCount} 项移入回收站失败，${result.succeeded} 项已完成。请检查权限后重试。';
        });
      } else if (result.receivedCount != paths.length) {
        _refreshState(() => _error = '服务端没有返回完整的操作结果，请刷新目录确认文件状态。');
      }
    } catch (error) {
      _refreshState(() => _error = '批量操作失败：${_friendlyError(error)}');
    }
  }

  FileSelectionSnapshot get _selectionSnapshot => FileSelectionSnapshot(
    loadedEntries: _entries,
    selectedPaths: _selectedPaths,
    canWrite: _canWriteItem,
  );
  Widget _selectionToolbar(BuildContext context, bool compact) {
    final selection = _selectionSnapshot;
    return FileSelectionToolbar(
      compact: compact,
      selectedCount: selection.count,
      hasLoadedEntries: selection.visiblePaths.isNotEmpty,
      allLoadedSelected: selection.allVisibleSelected,
      canWriteSelection: selection.writableSelection,
      canSaveFiles: selection.canExportFiles,
      busy: _loading || _batchBusy,
      onToggleAll: () => _refreshState(() {
        _selectedPaths
          ..clear()
          ..addAll(selection.toggledVisible());
      }),
      onSave: _batchSave,
      onCopy: () => _batchTransfer('copy'),
      onMove: () => _batchTransfer('move'),
      onClear: () => _refreshState(_selectedPaths.clear),
      onDone: () => _refreshState(() {
        _selectedPaths.clear();
        _selecting = false;
      }),
      onTrash: _batchTrash,
    );
  }

  Future<void> _copyPathToClipboard(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('下载路径已复制。')));
  }
}
