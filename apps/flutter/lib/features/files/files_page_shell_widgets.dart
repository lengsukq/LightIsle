part of 'files_page.dart';

extension _FilesPageShellWidgets on _FilesPageState {
  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IslePageHeader(
          title: '文件',
          subtitle: '浏览共享目录、管理文件并查看回收站。',
          hideSubtitleOnCompact: true,
          icon: Icons.folder_open_rounded,
          trailing: IconButton(
            tooltip: _filter.showingTrash ? '刷新回收站' : '刷新目录',
            visualDensity: VisualDensity.compact,
            onPressed: _dir.loading || _filter.trashLoading
                ? null
                : () => _filter.showingTrash ? _loadTrash() : _loadFiles(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        _buildBreadcrumbs(context),
      ],
    );
  }

  Widget _buildBreadcrumbs(BuildContext context) {
    final segments = _pathSegments();
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < segments.length; index++) ...[
            if (index > 0)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            _breadcrumbSegment(
              context,
              segments[index],
              index == segments.length - 1,
            ),
          ],
        ],
      ),
    );
  }

  Widget _breadcrumbSegment(
    BuildContext context,
    (String, String) segment,
    bool active,
  ) {
    final colors = Theme.of(context).colorScheme;
    final label = Text(
      segment.$1,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: active ? colors.onSurface : colors.primary,
        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width < 360 ? 112 : 190,
      ),
      child: Tooltip(
        message: segment.$1,
        child: active
            ? Semantics(
                label: '当前位置：${segment.$1}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: label,
                ),
              )
            : TextButton(
                onPressed: _dir.loading || _filter.showingTrash
                    ? null
                    : () => _loadFiles(target: segment.$2),
                style: TextButton.styleFrom(
                  minimumSize: const Size(32, 30),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: label,
              ),
      ),
    );
  }

  Future<void> _openDownloads() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DownloadsPage(api: widget.api, initialDestination: _dir.path),
      ),
    );
    if (mounted) await _loadFiles();
  }

  Future<void> _openDuplicates() async {
    final trashed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            DuplicateFilesPage(api: widget.api, initialPath: _dir.path),
      ),
    );
    if (trashed == true && mounted) await _loadFiles();
  }

  Widget _buildToolbar(
    BuildContext context,
    bool compact,
    double availableWidth,
  ) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final iconActions = IsleLayout.compactToolbar(availableWidth, textScale);
    final singleRowToolbar =
        !_filter.showingTrash && availableWidth >= 600 && textScale <= 1.35;
    final searchField = IsleSearchBar(
      controller: _filter.searchController,
      enabled: !_dir.loading,
      hintText: iconActions || compact ? '搜索文件名' : '搜索文件名（至少 2 个字符）',
      showClear: _filter.searching,
      onSubmitted: (_) => _searchFiles(),
      onClear: _dir.loading
          ? null
          : () {
              if (_filter.searching) {
                final target = _filter.preSearchPath ?? widget.initialPath;
                _filter.searchController.clear();
                _loadFiles(target: target);
              } else {
                _searchFiles();
              }
            },
    );
    final actionsRow = Row(
      mainAxisSize: singleRowToolbar ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (_filter.showingTrash)
          TextButton.icon(
            onPressed: _toggleTrash,
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('返回文件'),
          )
        else if (_dir.canWrite && iconActions)
          IconButton.filled(
            tooltip: '上传文件',
            onPressed: _dir.loading || _transfers.uploadBusy
                ? null
                : _chooseUploadSource,
            icon: const Icon(Icons.add_rounded),
          )
        else if (_dir.canWrite)
          FilledButton.icon(
            onPressed: _dir.loading || _transfers.uploadBusy
                ? null
                : _chooseUploadSource,
            icon: const Icon(Icons.add_rounded, size: 17),
            label: const Text('上传文件'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(40, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
        if (!_filter.showingTrash && _dir.canWrite) ...[
          const SizedBox(width: 6),
          if (compact || iconActions)
            IconButton(
              tooltip: '新建文件夹',
              onPressed: _dir.loading ? null : _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            )
          else
            OutlinedButton.icon(
              onPressed: _dir.loading ? null : _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 17),
              label: const Text('新建文件夹'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(40, 36),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
              ),
            ),
        ],
        if (!singleRowToolbar) const Spacer() else const SizedBox(width: 6),
        if (!_filter.showingTrash)
          IconButton(
            key: const Key('files-select-toggle'),
            tooltip: _transfers.selecting ? '结束多选' : '多选文件',
            visualDensity: VisualDensity.compact,
            onPressed: _dir.loading || _transfers.batchBusy
                ? null
                : () => _refreshState(() {
                    _transfers.selecting = !_transfers.selecting;
                    _transfers.selectedPaths.clear();
                  }),
            icon: Icon(
              _transfers.selecting
                  ? Icons.close_rounded
                  : Icons.checklist_rounded,
            ),
            color: _transfers.selecting
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        if (!_filter.showingTrash)
          PopupMenuButton<String>(
            tooltip: '更多文件操作',
            icon: const Icon(Icons.more_horiz_rounded),
            position: PopupMenuPosition.under,
            constraints: const BoxConstraints(minWidth: 228, maxWidth: 270),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 4,
            onSelected: (value) {
              switch (value) {
                case 'folder':
                  _createFolder();
                case 'select':
                  _refreshState(() {
                    _transfers.selecting = !_transfers.selecting;
                    _transfers.selectedPaths.clear();
                  });
                case 'downloads':
                  _openDownloads();
                case 'duplicates':
                  _openDuplicates();
                case 'trash':
                  _toggleTrash();
                case 'rename':
                  _setUploadAutoRename(!_prefsState.uploadAutoRename);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        _prefsState.uploadAutoRename
                            ? '上传时遇到同名文件会自动生成新名称，已保存到本机。'
                            : '上传时遇到同名文件不会自动改名，已保存到本机。',
                      ),
                    ),
                  );
              }
            },
            itemBuilder: (_) => [
              if (!_filter.showingTrash && _dir.canWrite)
                isleActionMenuItem(
                  value: 'folder',
                  icon: Icons.create_new_folder_outlined,
                  label: '新建文件夹',
                ),
              if (!_filter.showingTrash)
                isleActionMenuItem(
                  value: 'select',
                  icon: _transfers.selecting
                      ? Icons.close_rounded
                      : Icons.checklist_rounded,
                  label: _transfers.selecting ? '结束多选' : '多选文件',
                ),
              if (!_filter.showingTrash)
                isleActionMenuItem(
                  value: 'downloads',
                  icon: Icons.download_outlined,
                  label: '下载中心',
                ),
              if (!_filter.showingTrash)
                isleActionMenuItem(
                  value: 'duplicates',
                  icon: Icons.file_copy_outlined,
                  label: '重复大文件清理',
                ),
              if (!_filter.showingTrash)
                isleActionMenuItem(
                  value: 'trash',
                  icon: Icons.delete_outline_rounded,
                  label: '回收站',
                ),
              if (!_filter.showingTrash && _dir.canWrite)
                const PopupMenuDivider(),
              if (!_filter.showingTrash && _dir.canWrite)
                isleActionMenuItem(
                  value: 'rename',
                  icon: Icons.drive_file_rename_outline_rounded,
                  label: '上传时同名自动改名',
                  checked: _prefsState.uploadAutoRename,
                ),
            ],
          ),
      ],
    );
    if (singleRowToolbar) {
      return Row(
        children: [
          Expanded(child: searchField),
          const SizedBox(width: 10),
          actionsRow,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_filter.showingTrash) searchField,
        const SizedBox(height: 6),
        actionsRow,
      ],
    );
  }

  Widget _fileViewToggle() => IconButton(
    tooltip: _prefsState.fileView == 'grid' ? '切换列表视图' : '切换卡片视图',
    onPressed: () =>
        _setFileView(_prefsState.fileView == 'grid' ? 'list' : 'grid'),
    icon: Icon(
      _prefsState.fileView == 'grid'
          ? Icons.view_list_rounded
          : Icons.grid_view_rounded,
    ),
  );

  Widget _fileSortMenu() => PopupMenuButton<String>(
    tooltip: '文件排序方式',
    icon: const Icon(Icons.sort_rounded),
    onSelected: _setFileSort,
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: 'name:asc',
        checked:
            _prefsState.fileSort == 'name' &&
            _prefsState.fileSortDirection == 'asc',
        child: const Text('名称 · 升序'),
      ),
      CheckedPopupMenuItem(
        value: 'name:desc',
        checked:
            _prefsState.fileSort == 'name' &&
            _prefsState.fileSortDirection == 'desc',
        child: const Text('名称 · 降序'),
      ),
      CheckedPopupMenuItem(
        value: 'mtime:desc',
        checked:
            _prefsState.fileSort == 'mtime' &&
            _prefsState.fileSortDirection == 'desc',
        child: const Text('修改时间 · 最新优先'),
      ),
      CheckedPopupMenuItem(
        value: 'mtime:asc',
        checked:
            _prefsState.fileSort == 'mtime' &&
            _prefsState.fileSortDirection == 'asc',
        child: const Text('修改时间 · 最早优先'),
      ),
      CheckedPopupMenuItem(
        value: 'size:desc',
        checked:
            _prefsState.fileSort == 'size' &&
            _prefsState.fileSortDirection == 'desc',
        child: const Text('文件大小 · 从大到小'),
      ),
      CheckedPopupMenuItem(
        value: 'size:asc',
        checked:
            _prefsState.fileSort == 'size' &&
            _prefsState.fileSortDirection == 'asc',
        child: const Text('文件大小 · 从小到大'),
      ),
    ],
  );

  List<(String, String)> _pathSegments() {
    if (widget.initialPath != '.' &&
        (_dir.path == widget.initialPath ||
            _dir.path.startsWith('${widget.initialPath}/'))) {
      final label = widget.initialPath.endsWith('/photos')
          ? '我的照片'
          : widget.initialPath.endsWith('/videos')
          ? '我的视频'
          : '我的文件';
      final result = <(String, String)>[(label, widget.initialPath)];
      if (_dir.path == widget.initialPath) return result;
      final relative = _dir.path
          .substring(widget.initialPath.length + 1)
          .split('/');
      for (var i = 0; i < relative.length; i++) {
        result.add((
          relative[i],
          '${widget.initialPath}/${relative.take(i + 1).join('/')}',
        ));
      }
      return result;
    }
    final result = <(String, String)>[(_dir.rootName, '.')];
    if (_dir.path == '.' || _dir.path.isEmpty) return result;
    final names = _dir.path.split('/');
    for (var i = 0; i < names.length; i++) {
      result.add((names[i], names.take(i + 1).join('/')));
    }
    return result;
  }
}
