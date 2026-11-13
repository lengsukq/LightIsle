part of 'files_page.dart';

extension _FilesPageFileWidgets on _FilesPageState {
  Widget _buildFileList(BuildContext context, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final gridHeightExtra = (textScale - 1).clamp(0.0, 3.0) * 45;
    final title = _filter.showingTrash
        ? '回收站'
        : _filter.searching
        ? '搜索结果'
        : '${_dir.rootName} · ${_dir.path == '.' ? '全部文件' : _dir.path}';
    return IsleSurface(
      padding: EdgeInsets.zero,
      radius: IsleRadius.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 18,
              vertical: compact ? 4 : 8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    compact && !_filter.showingTrash && !_filter.searching
                        ? '文件 · ${_dir.entries.length} 项'
                        : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (!compact &&
                    !_filter.showingTrash &&
                    _dir.entries.isNotEmpty)
                  Text(
                    '${_dir.entries.length} 项',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
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
                  modeKey: _prefsState.fileView,
                  child: _prefsState.fileView == 'grid'
                      ? Padding(
                          padding: EdgeInsets.all(compact ? 8 : 14),
                          child: RepaintBoundary(
                            child: GridView.builder(
                              key: const ValueKey('files-card-grid'),
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: compact
                                        ? 156
                                        : MediaQuery.sizeOf(context).width <
                                              1024
                                        ? 185
                                        : 210,
                                    mainAxisExtent:
                                        (compact ? 160 : 182) + gridHeightExtra,
                                    crossAxisSpacing: compact ? 8 : 10,
                                    mainAxisSpacing: compact ? 8 : 10,
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
                                  (entry) => _fileTile(context, entry, compact),
                                )
                                .toList(),
                          ),
                        ),
                ),
                if (_filter.searchTruncated)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '搜索结果已达到服务端上限，请缩小关键词。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                if (_dir.nextCursor.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
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
      borderRadius: BorderRadius.circular(11),
      child: SizedBox(
        width: 40,
        height: 40,
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
    if (item.isFolder) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: const Color(0xff0284c7).withValues(alpha: 0.12),
        ),
        child: const Icon(
          Icons.folder_rounded,
          color: Color(0xff0284c7),
          size: 21,
        ),
      );
    }

    final ext = _extension(item.name);
    final (tint, icon) = switch (ext) {
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'heic' => (const Color(0xfff43f5e), Icons.image_rounded),
      'mp4' ||
      'mov' ||
      'm4v' ||
      'webm' ||
      'mkv' => (const Color(0xff8b5cf6), Icons.movie_rounded),
      'mp3' ||
      'flac' ||
      'wav' ||
      'm4a' ||
      'aac' => (const Color(0xfff59e0b), Icons.music_note_rounded),
      'pdf' => (const Color(0xffef4444), Icons.picture_as_pdf_rounded),
      'zip' ||
      '7z' ||
      'rar' ||
      'tar' ||
      'gz' ||
      'dmg' => (const Color(0xff64748b), Icons.archive_rounded),
      'txt' ||
      'md' ||
      'log' ||
      'json' ||
      'yaml' ||
      'xml' ||
      'ts' ||
      'js' ||
      'swift' ||
      'go' => (const Color(0xff0ea5e9), Icons.description_rounded),
      _ => (const Color(0xff94a3b8), Icons.insert_drive_file_rounded),
    };

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: tint.withValues(alpha: 0.12),
      ),
      child: Icon(icon, color: tint, size: 20),
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
    final colors = Theme.of(context).colorScheme;
    if (item.isFolder) {
      return ColoredBox(
        color: colors.primary.withValues(alpha: .09),
        child: Center(
          child: Icon(Icons.folder_rounded, size: 52, color: colors.primary),
        ),
      );
    }
    final thumbnailKey = '${item.path}@${item.modified}';
    if (!_thumbnailEligible(item.name) ||
        _dir.failedThumbnails.contains(thumbnailKey)) {
      return ColoredBox(
        color: colors.surfaceContainerHighest,
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
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final detailHeight = 72 + (textScale - 1).clamp(0.0, 3.0) * 32;
    final writable = _canWriteItem(item);
    final selected = _transfers.selectedPaths.contains(item.path);
    final highlighted = _dir.highlightedPath == item.path;
    final card = Card(
      key: ValueKey('file-card-${item.path}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: selected
          ? colors.primaryContainer
          : highlighted
          ? colors.primaryContainer.withValues(alpha: 0.62)
          : colors.surfaceContainerLow,
      shape: IsleShapes.squircle(
        14,
        side: BorderSide(
          color: selected || highlighted
              ? colors.primary
              : colors.outlineVariant,
          width: highlighted ? 2.0 : (selected ? 1.5 : .7),
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
                  padding: const EdgeInsets.fromLTRB(10, 3, 2, 5),
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
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  )
                                : Text(
                                    item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                            const SizedBox(height: 2),
                            Text(
                              _filter.searching
                                  ? '${item.isFolder ? '文件夹' : formatBytes(item.size)} · ${_relativeParentLabel(item.path)}'
                                  : (item.isFolder
                                        ? '文件夹'
                                        : formatBytes(item.size)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
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
          minTileHeight: compact ? 46 : 50,
          visualDensity: compact
              ? VisualDensity.compact
              : VisualDensity.standard,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 18,
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
                    value: selected,
                    onChanged: (value) {
                      HapticFeedback.selectionClick();
                      _toggleSelected(item, value);
                    },
                  ),
                ),
              const SizedBox(width: 4),
              _buildFileBadge(item),
            ],
          ),
          title: _filter.searching
              ? HighlightedSearchText(
                  text: item.name,
                  query: _filter.searchTerm,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                )
              : Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
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
            padding: const EdgeInsets.only(left: 70, right: 20, bottom: 8),
            child: LinearProgressIndicator(
              value: _transfers.downloadProgress[item.path],
            ),
          ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}
