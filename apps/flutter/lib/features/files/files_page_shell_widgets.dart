part of 'files_page.dart';

extension _FilesPageShellWidgets on _FilesPageState {
  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IslePageHeader(
          title: '文件',
          subtitle: '浏览共享目录、管理文件并查看回收站。',
          icon: Icons.folder_open_rounded,
          trailing: IconButton(
            tooltip: _showingTrash ? '刷新回收站' : '刷新目录',
            onPressed: _loading || _trashLoading
                ? null
                : () => _showingTrash ? _loadTrash() : _loadFiles(),
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
                    vertical: 8,
                  ),
                  child: label,
                ),
              )
            : TextButton(
                onPressed: _loading || _showingTrash
                    ? null
                    : () => _loadFiles(target: segment.$2),
                style: TextButton.styleFrom(
                  minimumSize: const Size(36, 36),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
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
            DownloadsPage(api: widget.api, initialDestination: _path),
      ),
    );
    if (mounted) await _loadFiles();
  }

  Widget _buildToolbar(
    BuildContext context,
    bool compact,
    double availableWidth,
  ) {
    final iconActions = IsleLayout.compactToolbar(
      availableWidth,
      MediaQuery.textScalerOf(context).scale(14) / 14,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_showingTrash)
          TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _searchFiles(),
            decoration: InputDecoration(
              isDense: true,
              hintText: iconActions ? '搜索文件名' : '搜索文件名（至少 2 个字符）',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              suffixIcon: IconButton(
                tooltip: _searching ? '清除搜索' : '搜索',
                onPressed: _loading
                    ? null
                    : () {
                        if (_searching) {
                          _searchController.clear();
                          _loadFiles(target: widget.initialPath);
                        } else {
                          _searchFiles();
                        }
                      },
                icon: Icon(
                  _searching
                      ? Icons.close_rounded
                      : Icons.arrow_forward_rounded,
                  size: 20,
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (_showingTrash)
              TextButton.icon(
                onPressed: _toggleTrash,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('返回文件'),
              )
            else if (_canWrite && iconActions)
              IconButton.filled(
                tooltip: '上传文件',
                onPressed: _loading || _uploadBusy ? null : _chooseUploadSource,
                icon: const Icon(Icons.add_rounded),
              )
            else if (_canWrite)
              FilledButton.icon(
                onPressed: _loading || _uploadBusy ? null : _chooseUploadSource,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('上传文件'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(40, 38),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
              ),
            if (!_showingTrash && _canWrite) ...[
              const SizedBox(width: 6),
              if (compact || iconActions)
                IconButton(
                  tooltip: '新建文件夹',
                  onPressed: _loading ? null : _createFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                )
              else
                OutlinedButton.icon(
                  onPressed: _loading ? null : _createFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('新建文件夹'),
                ),
            ],
            const Spacer(),
            if (!_showingTrash)
              IconButton(
                key: const Key('files-select-toggle'),
                tooltip: _selecting ? '结束多选' : '多选文件',
                onPressed: _loading || _batchBusy
                    ? null
                    : () => _refreshState(() {
                        _selecting = !_selecting;
                        _selectedPaths.clear();
                      }),
                icon: Icon(
                  _selecting ? Icons.close_rounded : Icons.checklist_rounded,
                ),
                color: _selecting
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            if (!_showingTrash)
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
                        _selecting = !_selecting;
                        _selectedPaths.clear();
                      });
                    case 'downloads':
                      _openDownloads();
                    case 'trash':
                      _toggleTrash();
                    case 'rename':
                      _setUploadAutoRename(!_uploadAutoRename);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _uploadAutoRename
                                ? '上传时遇到同名文件会自动生成新名称，已保存到本机。'
                                : '上传时遇到同名文件不会自动改名，已保存到本机。',
                          ),
                        ),
                      );
                  }
                },
                itemBuilder: (_) => [
                  if (!_showingTrash && _canWrite)
                    isleActionMenuItem(
                      value: 'folder',
                      icon: Icons.create_new_folder_outlined,
                      label: '新建文件夹',
                    ),
                  if (!_showingTrash)
                    isleActionMenuItem(
                      value: 'select',
                      icon: _selecting
                          ? Icons.close_rounded
                          : Icons.checklist_rounded,
                      label: _selecting ? '结束多选' : '多选文件',
                    ),
                  if (!_showingTrash)
                    isleActionMenuItem(
                      value: 'downloads',
                      icon: Icons.download_outlined,
                      label: '下载中心',
                    ),
                  if (!_showingTrash)
                    isleActionMenuItem(
                      value: 'trash',
                      icon: Icons.delete_outline_rounded,
                      label: '回收站',
                    ),
                  if (!_showingTrash && _canWrite) const PopupMenuDivider(),
                  if (!_showingTrash && _canWrite)
                    isleActionMenuItem(
                      value: 'rename',
                      icon: Icons.drive_file_rename_outline_rounded,
                      label: '上传时同名自动改名',
                      checked: _uploadAutoRename,
                    ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _fileViewToggle() => IconButton(
    tooltip: _fileView == 'grid' ? '切换列表视图' : '切换卡片视图',
    onPressed: () => _setFileView(_fileView == 'grid' ? 'list' : 'grid'),
    icon: Icon(
      _fileView == 'grid' ? Icons.view_list_rounded : Icons.grid_view_rounded,
    ),
  );
  Widget _fileSortMenu() => PopupMenuButton<String>(
    tooltip: '文件排序方式',
    icon: const Icon(Icons.sort_rounded),
    onSelected: _setFileSort,
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: 'name:asc',
        checked: _fileSort == 'name' && _fileSortDirection == 'asc',
        child: const Text('名称 · 升序'),
      ),
      CheckedPopupMenuItem(
        value: 'name:desc',
        checked: _fileSort == 'name' && _fileSortDirection == 'desc',
        child: const Text('名称 · 降序'),
      ),
      CheckedPopupMenuItem(
        value: 'mtime:desc',
        checked: _fileSort == 'mtime' && _fileSortDirection == 'desc',
        child: const Text('修改时间 · 最新优先'),
      ),
      CheckedPopupMenuItem(
        value: 'mtime:asc',
        checked: _fileSort == 'mtime' && _fileSortDirection == 'asc',
        child: const Text('修改时间 · 最早优先'),
      ),
      CheckedPopupMenuItem(
        value: 'size:desc',
        checked: _fileSort == 'size' && _fileSortDirection == 'desc',
        child: const Text('文件大小 · 从大到小'),
      ),
      CheckedPopupMenuItem(
        value: 'size:asc',
        checked: _fileSort == 'size' && _fileSortDirection == 'asc',
        child: const Text('文件大小 · 从小到大'),
      ),
    ],
  );
  List<(String, String)> _pathSegments() {
    if (widget.initialPath != '.' &&
        (_path == widget.initialPath ||
            _path.startsWith('${widget.initialPath}/'))) {
      final label = widget.initialPath.endsWith('/photos')
          ? '我的照片'
          : widget.initialPath.endsWith('/videos')
          ? '我的视频'
          : '我的文件';
      final result = <(String, String)>[(label, widget.initialPath)];
      if (_path == widget.initialPath) return result;
      final relative = _path
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
    final result = <(String, String)>[(_rootName, '.')];
    if (_path == '.' || _path.isEmpty) return result;
    final names = _path.split('/');
    for (var i = 0; i < names.length; i++) {
      result.add((names[i], names.take(i + 1).join('/')));
    }
    return result;
  }
}
