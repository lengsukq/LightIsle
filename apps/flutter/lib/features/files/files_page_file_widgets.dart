part of 'files_page.dart';

extension _FilesPageFileWidgets on _FilesPageState {
  Widget _buildFileList(
    BuildContext context,
    bool compact,
    double availableWidth,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final desktopTable =
        availableWidth >= 840 &&
        textScale <= 1.35 &&
        _prefsState.fileView != 'grid' &&
        !_filter.showingTrash;
    final showInspectorSidePanel =
        availableWidth >= 1040 &&
        textScale <= 1.35 &&
        !_filter.showingTrash &&
        _transfers.selectedPaths.length == 1;
    final gridHeightExtra = (textScale - 1).clamp(0.0, 3.0) * 45;
    final title = _filter.showingTrash
        ? '回收站'
        : _filter.searching
        ? '搜索结果'
        : '${_dir.rootName} · ${_dir.path == '.' ? '全部文件' : _dir.path}';

    final folderCount = _dir.entries.where((e) => e.isFolder).length;
    final fileCount = _dir.entries.length - folderCount;
    final totalFileBytes = _dir.entries
        .where((e) => !e.isFolder)
        .fold<int>(0, (sum, e) => sum + e.size);

    final mainSurface = IsleSurface(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 16,
              vertical: compact ? 4 : 8,
            ),
            child: Row(
              children: [
                Container(
                  width: style.preset.surfaceMaterial ==
                          IsleSurfaceMaterial.flatHairline
                      ? 8
                      : style.preset.surfaceMaterial ==
                            IsleSurfaceMaterial.neoBrutal
                      ? 9
                      : 3,
                  height: style.preset.surfaceMaterial ==
                              IsleSurfaceMaterial.flatHairline ||
                          style.preset.surfaceMaterial ==
                              IsleSurfaceMaterial.neoBrutal
                      ? 9
                      : 15,
                  decoration: BoxDecoration(
                    borderRadius: style.preset.cornerStyle ==
                            IsleCornerStyle.sharp
                        ? BorderRadius.zero
                        : BorderRadius.circular(999),
                    color: _filter.showingTrash
                        ? colors.error
                        : palette['brandAmber'],
                    border: style.preset.surfaceMaterial ==
                            IsleSurfaceMaterial.neoBrutal
                        ? Border.all(
                            color: style.rimBorderColor(),
                            width: 1.4,
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    compact && !_filter.showingTrash && !_filter.searching
                        ? '文件 · ${_dir.entries.length} 项'
                        : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                if (!compact &&
                    !_filter.showingTrash &&
                    _dir.entries.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: IsleDecorations.recessedWell(
                      context,
                      radius: 999,
                    ),
                    child: Text(
                      folderCount > 0 && fileCount > 0
                          ? '$folderCount 文件夹 · $fileCount 文件 (${formatBytes(totalFileBytes)})'
                          : '${_dir.entries.length} 项',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                if (!_filter.showingTrash) _fileViewToggle(),
                if (!_filter.showingTrash && !_filter.searching)
                  _fileSortMenu(),
              ],
            ),
          ),
          IsleAnimatedExpand(
            expanded: !_filter.showingTrash && _transfers.selecting,
            child: _selectionToolbar(context, compact),
          ),
          if (_filter.searching && !_filter.showingTrash)
            _buildSearchScopeAndKindBar(context),
          const Divider(height: 1),
          if (desktopTable && _dir.entries.isNotEmpty)
            _buildDesktopColumnHeader(context, palette),
          if (_dir.loading)
            const RepaintBoundary(child: LinearProgressIndicator(minHeight: 2))
          else if (_filter.showingTrash && _filter.trashLoading)
            const RepaintBoundary(child: LinearProgressIndicator(minHeight: 2))
          else if (_filter.showingTrash)
            _filter.trashEntries.isEmpty
                ? _emptyState(context, '回收站是空的。', Icons.delete_outline)
                : RepaintBoundary(
                    child: Column(
                      children: _filter.trashEntries
                          .map((entry) => _trashTile(context, entry, compact))
                          .toList(),
                    ),
                  )
          else if (_dir.entries.isEmpty)
            _filter.searching
                ? FileSearchEmptyState(
                    searchTerm: _filter.searchTerm,
                    searchKind: _filter.searchKind,
                    subdirLabel: _searchSubdirLabel,
                    searchingSubdir:
                        _filter.searchScopeSubdir != null &&
                        !_filter.searchEntireRoot,
                    onResetKind: () {
                      _refreshState(() => _filter.searchKind = '');
                      unawaited(_searchFiles());
                    },
                    onExpandToRoot: () {
                      _refreshState(() => _filter.searchEntireRoot = true);
                      unawaited(_searchFiles());
                    },
                    onExitSearch: _exitSearchAndRestore,
                  )
                : _emptyState(
                    context,
                    '此文件夹目前是空的。',
                    Icons.folder_open_outlined,
                    showCreateActions: _dir.canWrite,
                  )
          else
            Column(
              children: [
                IsleModeSwitcher(
                  modeKey:
                      '${_dir.rootName}:${_dir.path}:${_filter.searching}:${_prefsState.fileView}:$desktopTable',
                  child: _prefsState.fileView == 'grid'
                      ? Padding(
                          padding: EdgeInsets.all(compact ? 8 : 12),
                          child: RepaintBoundary(
                            child: GridView.builder(
                              key: const ValueKey('files-card-grid'),
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: compact
                                        ? 152
                                        : availableWidth < 960
                                        ? 182
                                        : 206,
                                    mainAxisExtent:
                                        (compact ? 156 : 180) + gridHeightExtra,
                                    crossAxisSpacing: compact ? 8 : 11,
                                    mainAxisSpacing: compact ? 8 : 11,
                                  ),
                              itemCount: _dir.entries.length,
                              itemBuilder: (context, index) =>
                                  _fileCard(context, _dir.entries[index]),
                            ),
                          ),
                        )
                      : RepaintBoundary(
                          child: Column(
                            children: _dir.entries
                                .map(
                                  (entry) => desktopTable
                                      ? _desktopFileTableRow(context, entry)
                                      : _fileTile(context, entry, compact),
                                )
                                .toList(),
                          ),
                        ),
                ),
                if (_filter.searchTruncated)
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      '搜索结果已达到服务端上限，请缩小关键词。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                if (_dir.nextCursor.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: OutlinedButton.icon(
                      onPressed: _dir.loading
                          ? null
                          : () => _loadFiles(more: true),
                      icon: const Icon(Icons.expand_more),
                      label: const Text('加载更多文件'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );

    if (!showInspectorSidePanel) return mainSurface;
    final selectedPath = _transfers.selectedPaths.first;
    final selectedEntry = _dir.entries
        .where((e) => e.path == selectedPath)
        .firstOrNull;
    if (selectedEntry == null) return mainSurface;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 8, child: mainSurface),
        const SizedBox(width: 14),
        SizedBox(
          width: 280,
          child: IsleModeSwitcher(
            modeKey: selectedEntry.path,
            duration: IsleMotion.quick,
            child: _buildDesktopSelectionInspector(context, selectedEntry),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopColumnHeader(BuildContext context, IslePalette palette) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: colors.onSurfaceVariant,
      letterSpacing: 0.2,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      color: palette['cardItemBottom'].withValues(alpha: 0.72),
      child: Row(
        children: [
          if (_transfers.selecting) const SizedBox(width: 34),
          const SizedBox(width: 42),
          Expanded(flex: 6, child: Text('名称', style: headerStyle)),
          SizedBox(width: 110, child: Text('种类', style: headerStyle)),
          SizedBox(
            width: 96,
            child: Text(
              '大小',
              textAlign: TextAlign.right,
              style: headerStyle,
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(width: 144, child: Text('修改时间', style: headerStyle)),
          const SizedBox(width: 44),
        ],
      ),
    );
  }

  String _fileKindLabel(FileEntry item) {
    if (item.isFolder) return '文件夹';
    final ext = _extension(item.name);
    if (ext.isEmpty) return '文稿';
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' =>
        '${ext.toUpperCase()} 图像',
      'mp4' || 'mov' || 'm4v' || 'webm' || 'mkv' => '${ext.toUpperCase()} 影片',
      'mp3' || 'flac' || 'wav' || 'm4a' || 'aac' => '${ext.toUpperCase()} 音频',
      'pdf' => 'PDF 文稿',
      'zip' || '7z' || 'rar' || 'tar' || 'gz' || 'dmg' =>
        '${ext.toUpperCase()} 归档',
      _ => '${ext.toUpperCase()} 文件',
    };
  }

  Widget _desktopFileTableRow(BuildContext context, FileEntry item) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final writable = _canWriteItem(item);
    final selected = _transfers.selectedPaths.contains(item.path);
    final highlighted = _dir.highlightedPath == item.path;
    final modified = item.modified == null ? '—' : _formatDate(item.modified!);
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      color: colors.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final row = AnimatedContainer(
      key: highlighted
          ? _highlightedItemKey
          : ValueKey('file-tile-${item.path}'),
      duration: IsleMotion.reducedMotion(context)
          ? Duration.zero
          : IsleMotion.normal,
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.42)
          : highlighted
          ? colors.primaryContainer.withValues(alpha: 0.48)
          : Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: _dir.loading
            ? null
            : (details) => unawaited(
                _showFileContextMenu(
                  context,
                  details.globalPosition,
                  item,
                  writable,
                ),
              ),
        child: InkWell(
          onTap: _dir.loading ? null : () => _openOrSelectFile(item),
          onLongPress: () => _startSelectingFile(item),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                if (_transfers.selecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Semantics(
                      label: '选择 ${item.name}',
                      child: Checkbox(
                        visualDensity: VisualDensity.compact,
                        value: selected,
                        onChanged: (value) {
                          HapticFeedback.selectionClick();
                          _toggleSelected(item, value);
                        },
                      ),
                    ),
                  ),
                _buildFileBadge(item),
                const SizedBox(width: 10),
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _filter.searching
                          ? HighlightedSearchText(
                              text: item.name,
                              query: _filter.searchTerm,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            )
                          : Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                      if (_filter.searching)
                        Text(
                          _relativeParentLabel(item.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle?.copyWith(fontSize: 11.2),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: Text(
                    _fileKindLabel(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Text(
                    item.isFolder ? '—' : formatBytes(item.size),
                    textAlign: TextAlign.right,
                    style: metaStyle,
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 144,
                  child: Text(
                    modified,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _fileActionsMenu(item, writable),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Column(
      children: [
        row,
        if (_transfers.downloading.contains(item.path))
          Padding(
            padding: const EdgeInsets.only(left: 58, right: 16, bottom: 6),
            child: LinearProgressIndicator(
              value: _transfers.downloadProgress[item.path],
            ),
          ),
        const Divider(height: 1, indent: 58, endIndent: 14),
      ],
    );
  }

  Widget _buildDesktopSelectionInspector(BuildContext context, FileEntry item) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final writable = _canWriteItem(item);
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      tint: palette['brandAmber'],
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'QUICK INSPECTOR',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: palette['brandAmber'],
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: 132,
              child: _fileCardCover(context, item),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _fileKindLabel(item),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          IsleKeyValueRow(
            label: '大小',
            value: item.isFolder ? '文件夹' : formatBytes(item.size),
          ),
          IsleKeyValueRow(
            label: '修改于',
            value: item.modified == null ? '未知' : _formatDate(item.modified!),
          ),
          IsleKeyValueRow(
            label: '所在位置',
            value: _relativeParentLabel(item.path),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => item.isFolder
                    ? unawaited(_loadFiles(target: item.path))
                    : unawaited(_preview(item)),
                icon: Icon(
                  item.isFolder
                      ? Icons.folder_open_rounded
                      : Icons.visibility_outlined,
                  size: 16,
                ),
                label: Text(item.isFolder ? '进入目录' : '预览'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _download(item),
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('下载'),
              ),
              if (writable)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _shareFile(item),
                  icon: const Icon(Icons.ios_share_outlined, size: 16),
                  label: const Text('分享'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String? get _searchSubdirLabel {
    final subdir = _filter.searchScopeSubdir;
    if (subdir == null || subdir.isEmpty) return null;
    final parts = subdir.split('/');
    return parts.isEmpty ? subdir : parts.last;
  }

  Widget _buildSearchScopeAndKindBar(BuildContext context) {
    return FileSearchScopeAndKindBar(
      busy: _dir.loading,
      selectedKind: _filter.searchKind,
      onSelectKind: (kind) {
        _refreshState(() => _filter.searchKind = kind);
        unawaited(_searchFiles());
      },
      subdirLabel: _searchSubdirLabel,
      searchEntireRoot: _filter.searchEntireRoot,
      onToggleScope: _filter.searchScopeSubdir == null
          ? null
          : (entireRoot) {
              if (_filter.searchEntireRoot == entireRoot) return;
              _refreshState(() => _filter.searchEntireRoot = entireRoot);
              unawaited(_searchFiles());
            },
    );
  }

  static final RegExp _thumbnailExtensions = RegExp(
    r'\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$',
    caseSensitive: false,
  );

  bool _thumbnailEligible(String name) => _thumbnailExtensions.hasMatch(name);

  Widget _fileThumbnail(FileEntry item) {
    final key = '${item.path}@${item.modified}';
    if (_dir.failedThumbnails.contains(key)) return _buildFileBadgeIcon(item);
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(
        width: 34,
        height: 34,
        child: AuthenticatedMediaImage(
          api: widget.api,
          path: '/api/v2/files/thumbnail',
          query: {'path': item.path, 'size': '512'},
          maxBytes: 4 * 1024 * 1024,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) {
            _dir.failedThumbnails.add(key);
            return _buildFileBadgeIcon(item);
          },
        ),
      ),
    );
  }

  Widget _buildFileBadge(FileEntry item) {
    if (!item.isFolder && _thumbnailEligible(item.name)) {
      return _fileThumbnail(item);
    }
    return _buildFileBadgeIcon(item);
  }

  Widget _buildFileBadgeIcon(FileEntry item) {
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final badgeRadius = style.borderRadiusFor(IsleRadius.sm);
    if (item.isFolder) {
      final folderTint = palette['brandAmber'];
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: badgeRadius,
          color: folderTint.withValues(alpha: isBrutal ? 0.22 : 0.14),
          border: Border.all(
            color: isBrutal
                ? style.rimBorderColor()
                : folderTint.withValues(alpha: 0.24),
            width: isBrutal ? 1.5 : 0.85,
          ),
        ),
        child: Icon(Icons.folder_rounded, color: folderTint, size: 19),
      );
    }

    final ext = _extension(item.name);
    final (Color tint, IconData icon) = switch (ext) {
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'heic' => (palette['brandRose'], Icons.image_rounded),
      'mp4' ||
      'mov' ||
      'm4v' ||
      'webm' ||
      'mkv' => (palette['brandViolet'], Icons.movie_rounded),
      'mp3' ||
      'flac' ||
      'wav' ||
      'm4a' ||
      'aac' => (palette['brandTerracotta'], Icons.music_note_rounded),
      'pdf' => (Theme.of(context).colorScheme.error, Icons.picture_as_pdf_rounded),
      'zip' ||
      '7z' ||
      'rar' ||
      'tar' ||
      'gz' ||
      'dmg' => (palette['brandBlue'], Icons.archive_rounded),
      'txt' ||
      'md' ||
      'log' ||
      'json' ||
      'yaml' ||
      'xml' ||
      'ts' ||
      'js' ||
      'swift' ||
      'go' => (palette['brandSage'], Icons.description_rounded),
      _ => (
        Theme.of(context).colorScheme.onSurfaceVariant,
        Icons.insert_drive_file_rounded,
      ),
    };

    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: tint.withValues(alpha: 0.13),
        border: Border.all(color: tint.withValues(alpha: 0.18), width: 0.85),
      ),
      child: Icon(icon, color: tint, size: 18),
    );
  }

  void _openOrSelectFile(FileEntry item) {
    HapticFeedback.selectionClick();
    if (HardwareKeyboard.instance.isShiftPressed) {
      if (_transfers.selectionAnchorPath != null &&
          _dir.entries.any(
            (entry) => entry.path == _transfers.selectionAnchorPath,
          )) {
        _selectRangeTo(item);
      } else {
        _refreshState(() => _transfers.selecting = true);
        _toggleSelected(item, true);
      }
      return;
    }
    if (_transfers.selecting) {
      _toggleSelected(item, !_transfers.selectedPaths.contains(item.path));
    } else if (item.isFolder) {
      unawaited(_loadFiles(target: item.path));
    } else {
      unawaited(_preview(item));
    }
  }

  void _startSelectingFile(FileEntry item) {
    _refreshState(() => _transfers.selecting = true);
    _toggleSelected(item, !_transfers.selectedPaths.contains(item.path));
  }

  Widget _fileCardCover(BuildContext context, FileEntry item) {
    final palette = IslePalette.of(context);
    if (item.isFolder) {
      final folderTint = palette['brandAmber'];
      return ColoredBox(
        color: folderTint.withValues(alpha: 0.10),
        child: Center(
          child: Icon(Icons.folder_rounded, size: 46, color: folderTint),
        ),
      );
    }
    final thumbnailKey = '${item.path}@${item.modified}';
    if (!_thumbnailEligible(item.name) ||
        _dir.failedThumbnails.contains(thumbnailKey)) {
      return ColoredBox(
        color: palette['cardItemBottom'],
        child: Center(child: _buildFileBadgeIcon(item)),
      );
    }
    return AuthenticatedMediaImage(
      api: widget.api,
      path: '/api/v2/files/thumbnail',
      query: {'path': item.path, 'size': '512'},
      maxBytes: 4 * 1024 * 1024,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) {
        _dir.failedThumbnails.add(thumbnailKey);
        return Center(child: _buildFileBadgeIcon(item));
      },
    );
  }

  String _relativeParentLabel(String path) {
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return '根目录';
    return path.substring(0, slash);
  }

  Widget _fileCard(BuildContext context, FileEntry item) {
    final colors = Theme.of(context).colorScheme;
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final detailHeight = 68 + (textScale - 1).clamp(0.0, 3.0) * 32;
    final writable = _canWriteItem(item);
    final selected = _transfers.selectedPaths.contains(item.path);
    final highlighted = _dir.highlightedPath == item.path;
    final baseWidth = style.effectiveBorderWidth();
    final card = Card(
      key: ValueKey('file-card-${item.path}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: selected
          ? colors.primaryContainer
          : highlighted
          ? colors.primaryContainer.withValues(alpha: 0.62)
          : palette['cardItemTop'],
      shape: style.shapeFor(
        14,
        side: BorderSide(
          color: selected || highlighted
              ? colors.primary
              : style.rimBorderColor(),
          width: highlighted ? 2.2 : (selected ? 1.8 : baseWidth),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: _dir.loading
            ? null
            : (details) => unawaited(
                _showFileContextMenu(
                  context,
                  details.globalPosition,
                  item,
                  writable,
                ),
              ),
        child: InkWell(
          onTap: _dir.loading ? null : () => _openOrSelectFile(item),
          onLongPress: () => _startSelectingFile(item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _fileCardCover(context, item),
                    if (_transfers.selecting)
                      Positioned(
                        top: 2,
                        left: 2,
                        child: Checkbox(
                          value: selected,
                          onChanged: (value) => _toggleSelected(item, value),
                        ),
                      ),
                    if (_transfers.downloading.contains(item.path))
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(
                          value: _transfers.downloadProgress[item.path],
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: detailHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 3, 2, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _filter.searching
                                ? HighlightedSearchText(
                                    text: item.name,
                                    query: _filter.searchTerm,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  )
                                : Text(
                                    item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                            const SizedBox(height: 1),
                            Text(
                              _filter.searching
                                  ? '${item.isFolder ? '文件夹' : formatBytes(item.size)} · ${_relativeParentLabel(item.path)}'
                                  : (item.isFolder
                                        ? '文件夹'
                                        : formatBytes(item.size)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontSize: 11.5,
                                    color: colors.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      _fileActionsMenu(item, writable),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return highlighted
        ? KeyedSubtree(key: _highlightedItemKey, child: card)
        : card;
  }

  Widget _fileTile(BuildContext context, FileEntry item, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final writable = _canWriteItem(item);
    final selected = _transfers.selectedPaths.contains(item.path);
    final highlighted = _dir.highlightedPath == item.path;
    final modified = item.modified == null
        ? '修改时间未知'
        : _formatDate(item.modified!);
    final subtitleStyle = TextStyle(
      fontSize: 11.5,
      color: colors.onSurfaceVariant,
    );
    final tile = AnimatedContainer(
      key: highlighted
          ? _highlightedItemKey
          : ValueKey('file-tile-${item.path}'),
      duration: IsleMotion.reducedMotion(context)
          ? Duration.zero
          : IsleMotion.normal,
      color: highlighted
          ? colors.primaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: _dir.loading
            ? null
            : (details) => unawaited(
                _showFileContextMenu(
                  context,
                  details.globalPosition,
                  item,
                  writable,
                ),
              ),
        child: ListTile(
          dense: true,
          minTileHeight: compact ? 46 : 48,
          visualDensity: compact
              ? VisualDensity.compact
              : VisualDensity.standard,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 16,
            vertical: 0,
          ),
          selected: selected,
          selectedTileColor: colors.primaryContainer.withValues(alpha: .42),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_transfers.selecting)
                Semantics(
                  label: '选择 ${item.name}',
                  child: Checkbox(
                    visualDensity: VisualDensity.compact,
                    value: selected,
                    onChanged: (value) {
                      HapticFeedback.selectionClick();
                      _toggleSelected(item, value);
                    },
                  ),
                ),
              const SizedBox(width: 2),
              _buildFileBadge(item),
            ],
          ),
          title: _filter.searching
              ? HighlightedSearchText(
                  text: item.name,
                  query: _filter.searchTerm,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                )
              : Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
          subtitle: _filter.searching
              ? Row(
                  children: [
                    Text(
                      '${item.isFolder ? '文件夹' : formatBytes(item.size)} · $modified · ',
                      style: subtitleStyle,
                    ),
                    Expanded(
                      child: HighlightedSearchText(
                        text: _relativeParentLabel(item.path),
                        query: _filter.searchTerm,
                        style: subtitleStyle,
                      ),
                    ),
                  ],
                )
              : Text(
                  '${item.isFolder ? '文件夹' : formatBytes(item.size)} · $modified',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: subtitleStyle,
                ),
          onLongPress: () => _startSelectingFile(item),
          onTap: _dir.loading ? null : () => _openOrSelectFile(item),
          trailing: _fileActionsMenu(item, writable),
        ),
      ),
    );
    return Column(
      children: [
        tile,
        if (_transfers.downloading.contains(item.path))
          Padding(
            padding: const EdgeInsets.only(left: 64, right: 16, bottom: 6),
            child: LinearProgressIndicator(
              value: _transfers.downloadProgress[item.path],
            ),
          ),
        const Divider(height: 1, indent: 56, endIndent: 14),
      ],
    );
  }
}
