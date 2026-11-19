part of 'files_page.dart';

extension _FilesPageShellWidgets on _FilesPageState {
  Widget _buildHeader(BuildContext context) {
    final palette = IslePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IslePageHeader(
          accentColor: palette['brandAmber'],
          title: _filter.showingTrash ? '回收站' : '文件',
          trailing: IconButton(
            tooltip: _filter.showingTrash ? '刷新回收站' : '刷新目录',
            visualDensity: VisualDensity.compact,
            onPressed: _dir.loading || _filter.trashLoading
                ? null
                : () => _filter.showingTrash ? _loadTrash() : _loadFiles(),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ),
        const SizedBox(height: 4),
        _buildBreadcrumbs(context),
      ],
    );
  }

  Widget _buildBreadcrumbs(BuildContext context) {
    final segments = _pathSegments();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: IsleDecorations.recessedWell(context, radius: 11),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Icon(
              _filter.showingTrash
                  ? Icons.delete_outline_rounded
                  : Icons.folder_special_outlined,
              size: 15,
              color: palette['brandAmber'],
            ),
            const SizedBox(width: 4),
            for (var index = 0; index < segments.length; index++) ...[
              if (index > 0)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
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
        fontSize: 12.8,
        color: active ? colors.onSurface : colors.primary,
        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width < 360 ? 112 : 200,
      ),
      child: Tooltip(
        message: segment.$1,
        child: active
            ? Semantics(
                label: '当前位置：${segment.$1}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 3,
                  ),
                  child: label,
                ),
              )
            : TextButton(
                onPressed: _dir.loading || _filter.showingTrash
                    ? null
                    : () => _loadFiles(target: segment.$2),
                style: TextButton.styleFrom(
                  minimumSize: const Size(28, 26),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
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
      buildIslePageRoute<void>(
        builder: (_) =>
            DownloadsPage(api: widget.api, initialDestination: _dir.path),
      ),
    );
    if (mounted) await _loadFiles();
  }

  Future<void> _openDuplicates() async {
    final trashed = await Navigator.of(context).push<bool>(
      buildIslePageRoute<bool>(
        builder: (_) =>
            DuplicateFilesPage(api: widget.api, initialPath: _dir.path),
      ),
    );
    if (trashed == true && mounted) await _loadFiles();
  }

  void _openWebDavMount() {
    Navigator.of(context).push<void>(
      buildIslePageRoute<void>(
        builder: (_) => DavPage(
          api: widget.api,
          accountId: widget.accountName.isEmpty ? null : widget.accountName,
        ),
      ),
    );
  }

  void _openSmbMount() {
    if (!widget.isAdmin) return;
    Navigator.of(context).push<void>(
      buildIslePageRoute<void>(builder: (_) => AdminSmbPage(api: widget.api)),
    );
  }

  Widget _buildToolbar(
    BuildContext context,
    bool compact,
    double availableWidth,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final iconActions = IsleLayout.compactToolbar(availableWidth, textScale);
    final singleRowToolbar =
        !_filter.showingTrash && availableWidth >= 600 && textScale <= 1.35;
    final searchField = Row(
      children: [
        Expanded(
          child: IsleSearchBar(
            controller: _filter.searchController,
            focusNode: _filter.searchFocusNode,
            enabled: !_dir.loading,
            hintText: _filter.searchViaSpotlight ? '全文搜索文件名或正文' : '搜索文件',
            showClear: _filter.searching,
            onChanged: (_) => _refreshState(() {}),
            onSubmitted: (_) => _searchFiles(),
            onClear: _dir.loading
                ? null
                : () {
                    if (_filter.searching) {
                      _exitSearchAndRestore();
                    } else {
                      _searchFiles();
                    }
                  },
          ),
        ),
        const SizedBox(width: 6),
        FilterChip(
          key: const ValueKey('filesSpotlightToggle'),
          label: const Text('全文搜索', style: TextStyle(fontSize: 12)),
          tooltip: '使用 Spotlight 全文检索文件内容',
          visualDensity: VisualDensity.compact,
          side: BorderSide(
            color: _filter.searchViaSpotlight
                ? colors.primary.withValues(alpha: 0.45)
                : borderColor,
            width: 1.0,
          ),
          selected: _filter.searchViaSpotlight,
          onSelected: _dir.loading
              ? null
              : (selected) {
                  _refreshState(() => _filter.searchViaSpotlight = selected);
                  if (_filter.searching &&
                      _filter.searchController.text.trim().isNotEmpty) {
                    _searchFiles();
                  }
                },
        ),
      ],
    );
    final actionsRow = Row(
      mainAxisSize: singleRowToolbar ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (_filter.showingTrash)
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _toggleTrash,
            icon: const Icon(Icons.arrow_back_rounded, size: 17),
            label: const Text('返回文件'),
          )
        else if (_dir.canWrite && iconActions)
          IconButton.filled(
            tooltip: '上传文件',
            visualDensity: VisualDensity.compact,
            onPressed: _dir.loading || _transfers.uploadBusy
                ? null
                : _chooseUploadSource,
            icon: const Icon(Icons.add_rounded, size: 19),
          )
        else if (_dir.canWrite)
          FilledButton.icon(
            onPressed: _dir.loading || _transfers.uploadBusy
                ? null
                : _chooseUploadSource,
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('上传文件'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(36, 34),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (!_filter.showingTrash && _dir.canWrite) ...[
          const SizedBox(width: 6),
          if (compact || iconActions)
            IconButton(
              tooltip: '新建文件夹',
              visualDensity: VisualDensity.compact,
              onPressed: _dir.loading ? null : _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 19),
            )
          else
            OutlinedButton.icon(
              onPressed: _dir.loading ? null : _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: const Text('新建文件夹'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(36, 34),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
        if (!singleRowToolbar) const Spacer() else const SizedBox(width: 4),
        if (!_filter.showingTrash) ...[
          IconButton(
            key: const Key('files-select-toggle'),
            tooltip: _transfers.selecting ? '结束多选' : '多选文件',
            visualDensity: VisualDensity.compact,
            onPressed: _dir.loading || _transfers.batchBusy
                ? null
                : () => _refreshState(() {
                    _transfers.selecting = !_transfers.selecting;
                    _transfers.selectedPaths.clear();
                    _transfers.selectionAnchorPath = null;
                  }),
            icon: Icon(
              _transfers.selecting
                  ? Icons.close_rounded
                  : Icons.checklist_rounded,
              size: 19,
            ),
            color: _transfers.selecting ? colors.primary : null,
          ),
          PopupMenuButton<String>(
            tooltip: '更多文件操作',
            icon: const Icon(Icons.more_horiz_rounded, size: 19),
            style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
            position: PopupMenuPosition.under,
            constraints: const BoxConstraints(minWidth: 206, maxWidth: 260),
            shape: IsleShapes.md(
              side: BorderSide(color: borderColor, width: 1.0),
            ),
            elevation: 4,
            onSelected: (value) {
              switch (value) {
                case 'downloads':
                  _openDownloads();
                case 'duplicates':
                  _openDuplicates();
                case 'trash':
                  _toggleTrash();
                case 'dav':
                  _openWebDavMount();
                case 'smb':
                  _openSmbMount();
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
              isleActionMenuItem(
                value: 'trash',
                icon: Icons.delete_outline_rounded,
                label: '回收站',
              ),
              isleActionMenuItem(
                value: 'downloads',
                icon: Icons.download_outlined,
                label: '下载中心',
              ),
              isleActionMenuItem(
                value: 'duplicates',
                icon: Icons.cleaning_services_outlined,
                label: '重复大文件清理',
              ),
              const PopupMenuDivider(),
              isleActionMenuItem(
                value: 'dav',
                icon: Icons.laptop_mac_outlined,
                label: '挂载到电脑（WebDAV）',
              ),
              if (widget.isAdmin)
                isleActionMenuItem(
                  value: 'smb',
                  icon: Icons.dns_outlined,
                  label: 'Mac 文件共享（SMB）',
                ),
              if (_dir.canWrite) const PopupMenuDivider(),
              if (_dir.canWrite)
                isleActionMenuItem(
                  value: 'rename',
                  icon: Icons.drive_file_rename_outline_rounded,
                  label: '上传时同名自动改名',
                  checked: _prefsState.uploadAutoRename,
                ),
            ],
          ),
        ],
      ],
    );
    final showHistory =
        !_filter.showingTrash &&
        _filter.recentSearches.isNotEmpty &&
        ((_filter.searchInputFocused &&
                _filter.searchController.text.trim().isEmpty) ||
            (_filter.searching && _dir.entries.isEmpty));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (singleRowToolbar)
          Row(
            children: [
              Expanded(child: searchField),
              const SizedBox(width: 8),
              actionsRow,
            ],
          )
        else ...[
          if (!_filter.showingTrash) searchField,
          const SizedBox(height: 6),
          actionsRow,
        ],
        if (showHistory)
          FileSearchHistoryStrip(
            terms: _filter.recentSearches,
            busy: _dir.loading,
            onTapTerm: (term) {
              _filter.searchController.text = term;
              unawaited(_searchFiles());
            },
            onRemoveTerm: (term) => unawaited(_removeSearchHistory(term)),
            onClearAll: () => unawaited(_clearSearchHistory()),
          ),
      ],
    );
  }

  Widget _fileViewToggle() => IconButton(
    visualDensity: VisualDensity.compact,
    tooltip: _prefsState.fileView == 'grid' ? '切换列表视图' : '切换卡片视图',
    onPressed: () =>
        _setFileView(_prefsState.fileView == 'grid' ? 'list' : 'grid'),
    icon: Icon(
      _prefsState.fileView == 'grid'
          ? Icons.view_list_rounded
          : Icons.grid_view_rounded,
      size: 19,
    ),
  );

  Widget _fileSortMenu() => PopupMenuButton<String>(
    style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
    tooltip: '文件排序方式',
    icon: const Icon(Icons.sort_rounded, size: 19),
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
