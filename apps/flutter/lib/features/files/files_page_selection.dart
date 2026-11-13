part of 'files_page.dart';

extension _FilesPageSelection on _FilesPageState {
  bool _batchSelectionStillCurrent(
    String rootIdentity,
    String directory,
    List<String> paths, {
    bool requireWritable = true,
  }) =>
      _dir.rootIdentity == rootIdentity &&
      (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity &&
      _dir.path == directory &&
      _transfers.selectedPaths.length == paths.length &&
      _transfers.selectedPaths.containsAll(paths) &&
      (requireWritable
          ? _selectionSnapshot.writableSelection
          : _selectionSnapshot.fullyLoaded);

  Future<void> _batchTransfer(String action) async {
    if (_transfers.batchBusy ||
        _dir.loading ||
        _transfers.selectedPaths.isEmpty) {
      return;
    }
    final selection = _selectionSnapshot;
    final byPath = {for (final item in _dir.entries) item.path: item};
    final paths = _transfers.selectedPaths.toList(growable: false);
    final requireWritable = action != 'copy';
    if (requireWritable && !selection.writableSelection) {
      _refreshState(() => _dir.error = '选择已变更或包含只读项目，请刷新目录再试。');
      return;
    }
    if (!selection.fullyLoaded) {
      _refreshState(() => _dir.error = '选择已变更，请刷新目录再试。');
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final sourceDirectory = _dir.path;
    final destination = await showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: widget.api,
        sourceName: '',
        sourcePath: sourceDirectory == '.' ? '' : sourceDirectory,
        action: action,
        directoryOnly: true,
      ),
    );
    if (destination == null || !mounted) return;
    if (!_batchSelectionStillCurrent(
      rootIdentity,
      sourceDirectory,
      paths,
      requireWritable: requireWritable,
    )) {
      _refreshState(() => _dir.error = '共享目录或选择已变化，请刷新后重新选择文件。');
      return;
    }
    final plan = FileBatchOperations.planTransfer(
      action: action,
      items: [for (final path in paths) byPath[path]!],
      destination: destination.path,
    );
    if (plan.invalidPaths.isNotEmpty) {
      _refreshState(
        () => _dir.error =
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
    if (!_batchSelectionStillCurrent(
      rootIdentity,
      sourceDirectory,
      paths,
      requireWritable: requireWritable,
    )) {
      _refreshState(() => _dir.error = '共享目录或选择已变化，未开始批量操作。');
      return;
    }
    await _executeBatchTransferPlan(
      action: action,
      plan: plan,
      destinationPath: destination.path,
      rootIdentity: rootIdentity,
      sourceDirectory: sourceDirectory,
    );
  }

  Future<void> _retryFailedBatchTransfer() async {
    final retry = _transfers.lastFailedBatchRetry;
    if (retry == null || _transfers.batchBusy || _dir.loading) return;
    final byPath = {for (final item in _dir.entries) item.path: item};
    final items = <FileEntry>[
      for (final path in retry.failedPaths)
        if (byPath[path] != null) byPath[path]!,
    ];
    if (items.isEmpty) {
      _refreshState(() {
        _transfers.lastFailedBatchRetry = null;
        _dir.error = '待重试的文件已不在当前目录，请刷新后重新选择。';
      });
      return;
    }
    final plan = FileBatchOperations.planTransfer(
      action: retry.action,
      items: items,
      destination: retry.destination,
    );
    if (!plan.valid) {
      _refreshState(() {
        _transfers.lastFailedBatchRetry = null;
        _dir.error = '重试目标路径无效，请重新选择目标目录。';
      });
      return;
    }
    await _executeBatchTransferPlan(
      action: retry.action,
      plan: plan,
      destinationPath: retry.destination,
      rootIdentity: widget.api.selectedRoot?.identity ?? 'default',
      sourceDirectory: _dir.path,
    );
  }

  Future<void> _executeBatchTransferPlan({
    required String action,
    required FileBatchTransferPlan plan,
    required String destinationPath,
    required String rootIdentity,
    required String sourceDirectory,
  }) async {
    _updateState(() {
      _transfers.batchBusy = true;
      _transfers.batchStopRequested = false;
      _transfers.batchActionLabel = action == 'move' ? '移动' : '复制';
      _transfers.batchProgress = FileBatchProgress(
        index: 1,
        total: plan.items.length,
        currentName: plan.items.first.name,
      );
      _transfers.lastFailedBatchRetry = null;
      _dir.error = null;
    });
    try {
      final result = await _batchOperations.transfer(
        action: action,
        plan: plan,
        destination: destinationPath,
        stillCurrent: () =>
            mounted &&
            _dir.rootIdentity == rootIdentity &&
            _dir.path == sourceDirectory &&
            (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity,
        stopRequested: () => _transfers.batchStopRequested,
        onProgress: (progress) =>
            _refreshState(() => _transfers.batchProgress = progress),
      );
      if (mounted &&
          _dir.rootIdentity == rootIdentity &&
          _dir.path == sourceDirectory &&
          (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity) {
        await _refreshCurrentView();
        if (mounted &&
            _dir.rootIdentity == rootIdentity &&
            (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity) {
          _updateState(() {
            _transfers.selectedPaths
              ..clear()
              ..addAll(result.failedPaths);
            if (result.failedPaths.isEmpty) {
              _transfers.lastFailedBatchRetry = null;
              _dir.error = null;
            } else {
              _transfers.lastFailedBatchRetry = (
                action: action,
                destination: destinationPath,
                failedPaths: result.failedPaths,
              );
              final reasons = result.failures
                  .take(3)
                  .map((f) => '${f.path}（${f.reason}）')
                  .join('；');
              final more = result.failures.length > 3
                  ? ' 等 ${result.failures.length} 项'
                  : '';
              final prefix = result.stoppedByUser
                  ? '已手动停止后续项，已完成 ${result.completed} 项，剩余 ${result.failedPaths.length} 项未执行'
                  : '已完成 ${result.completed} 项，${result.failedPaths.length} 项未完成';
              _dir.error = '$prefix：$reasons$more；未完成项目仍保留选择，可点击「仅重试失败项」。';
            }
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
      if (mounted) {
        _updateState(() {
          _transfers.batchBusy = false;
          _transfers.batchProgress = null;
          _transfers.batchStopRequested = false;
        });
      }
    }
  }

  void _toggleSelected(FileEntry item, bool? selected) {
    if (HardwareKeyboard.instance.isShiftPressed &&
        _transfers.selectionAnchorPath != null &&
        _dir.entries.any(
          (entry) => entry.path == _transfers.selectionAnchorPath,
        )) {
      _selectRangeTo(item);
      return;
    }
    if (selected == true &&
        !_transfers.selectedPaths.contains(item.path) &&
        _transfers.selectedPaths.length >= 50) {
      _refreshState(() => _dir.error = '每次最多选择 50 项文件。');
      return;
    }
    _refreshState(() {
      if (selected == true) {
        _transfers.selectedPaths.add(item.path);
        _transfers.selectionAnchorPath = item.path;
      } else {
        _transfers.selectedPaths.remove(item.path);
      }
      _dir.error = null;
    });
  }

  void _selectRangeTo(FileEntry target) {
    final entries = _dir.entries;
    final anchorPath = _transfers.selectionAnchorPath;
    final anchorIndex = anchorPath == null
        ? -1
        : entries.indexWhere((entry) => entry.path == anchorPath);
    final targetIndex = entries.indexWhere(
      (entry) => entry.path == target.path,
    );
    if (anchorIndex < 0 || targetIndex < 0) {
      _toggleSelected(target, !_transfers.selectedPaths.contains(target.path));
      return;
    }
    final start = anchorIndex < targetIndex ? anchorIndex : targetIndex;
    final end = anchorIndex > targetIndex ? anchorIndex : targetIndex;
    final additions = entries
        .sublist(start, end + 1)
        .map((entry) => entry.path)
        .toList(growable: false);
    final next = {..._transfers.selectedPaths};
    var truncated = false;
    for (final path in additions) {
      if (next.contains(path)) continue;
      if (next.length >= 50) {
        truncated = true;
        break;
      }
      next.add(path);
    }
    _refreshState(() {
      _transfers.selecting = true;
      _transfers.selectedPaths
        ..clear()
        ..addAll(next);
      _dir.error = truncated ? '已按 Shift 区间选择，单次最多选择 50 项文件。' : null;
    });
  }

  Future<void> _batchSave() async {
    if (_dir.loading ||
        _transfers.batchBusy ||
        _transfers.selectedPaths.isEmpty) {
      return;
    }
    final selection = _selectionSnapshot;
    if (!selection.fullyLoaded) {
      _refreshState(() => _dir.error = '文件列表已变化，请重新选择。');
      return;
    }
    if (!selection.canExportFiles) {
      _refreshState(() => _dir.error = '批量保存暂不支持文件夹，请只选择文件。');
      return;
    }
    final selected = selection.selectedEntries;
    _refreshState(() {
      _transfers.batchBusy = true;
      _dir.error = null;
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
        _refreshState(() => _dir.error = '批量保存失败：${_friendlyError(error)}');
      }
    } finally {
      if (mounted) _refreshState(() => _transfers.batchBusy = false);
    }
  }

  Future<void> _batchTrash() async {
    final paths = _transfers.selectedPaths.toList(growable: false);
    if (paths.isEmpty) return;
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final sourceDirectory = _dir.path;
    if (paths.length > FileSelectionSnapshot.maxSelection) {
      _refreshState(() => _dir.error = '每次最多选择 50 项移入回收站。');
      return;
    }
    if (!_selectionSnapshot.writableSelection) {
      _refreshState(() => _dir.error = '所选项目包含只读或已变更的项目，请刷新后重试。');
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
      _refreshState(() => _dir.error = '共享目录或选择已变化，未执行批量删除。');
      return;
    }

    _refreshState(() => _dir.error = null);
    try {
      final result = await _batchOperations.trash(paths);
      if (!mounted ||
          _dir.rootIdentity != rootIdentity ||
          (widget.api.selectedRoot?.identity ?? 'default') != rootIdentity) {
        return;
      }
      await _refreshCurrentView();
      if (!mounted ||
          _dir.rootIdentity != rootIdentity ||
          (widget.api.selectedRoot?.identity ?? 'default') != rootIdentity) {
        return;
      }
      if (result.failureCount > 0) {
        _refreshState(() {
          _transfers.selectedPaths.addAll(result.failedPaths);
          _dir.error = result.needsRootCheck
              ? '已确认 ${result.succeeded} 项移入回收站。硬盘连接发生变化，部分操作结果不确定；请重新连接原硬盘，检查原目录和回收站后再重试。'
              : result.needsTrashCheck
              ? '已确认 ${result.succeeded} 项移入回收站。检测到文件已变化，后续操作已停止；请检查原目录和回收站。'
              : '${result.failureCount} 项移入回收站失败，${result.succeeded} 项已完成。请检查权限后重试。';
        });
      } else if (result.receivedCount != paths.length) {
        _refreshState(() => _dir.error = '服务端没有返回完整的操作结果，请刷新目录确认文件状态。');
      }
    } catch (error) {
      _refreshState(() => _dir.error = '批量操作失败：${_friendlyError(error)}');
    }
  }

  FileSelectionSnapshot get _selectionSnapshot => FileSelectionSnapshot(
    loadedEntries: _dir.entries,
    selectedPaths: _transfers.selectedPaths,
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
      busy: _dir.loading || _transfers.batchBusy,
      onToggleAll: () => _refreshState(() {
        _transfers.selectedPaths
          ..clear()
          ..addAll(selection.toggledVisible());
      }),
      onSave: _batchSave,
      onCopy: () => _batchTransfer('copy'),
      onMove: () => _batchTransfer('move'),
      onClear: () => _refreshState(_transfers.selectedPaths.clear),
      onDone: () => _refreshState(_transfers.clearSelection),
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
