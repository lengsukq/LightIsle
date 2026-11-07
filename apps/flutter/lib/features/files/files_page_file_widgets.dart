part of 'files_page.dart';

extension _FilesPageFileWidgets on _FilesPageState {
  Widget _buildFileList(BuildContext context, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final gridHeightExtra = (textScale - 1).clamp(0.0, 3.0) * 45;
    final title = _showingTrash
        ? '回收站'
        : _searching
        ? '搜索结果'
        : '$_rootName · ${_path == '.' ? '全部文件' : _path}';
    return IsleSurface(
      padding: EdgeInsets.zero,
      radius: IsleTokens.cardRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : 20,
              vertical: compact ? 7 : 12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    compact && !_showingTrash && !_searching
                        ? '文件 · ${_entries.length} 项'
                        : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (!compact && !_showingTrash && _entries.isNotEmpty)
                  Text(
                    '${_entries.length} 项',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                if (!_showingTrash) _fileViewToggle(),
                if (!_showingTrash && !_searching) _fileSortMenu(),
              ],
            ),
          ),
          if (!_showingTrash && _selecting) _selectionToolbar(context, compact),
          const Divider(height: 1),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else if (_showingTrash && _trashLoading)
            const LinearProgressIndicator(minHeight: 2)
          else if (_showingTrash)
            _trashEntries.isEmpty
                ? _emptyState(context, '回收站是空的。', Icons.delete_outline)
                : Column(
                    children: _trashEntries
                        .map((entry) => _trashTile(context, entry, compact))
                        .toList(),
                  )
          else if (_entries.isEmpty)
            _emptyState(
              context,
              _searching ? '没有找到匹配的文件或文件夹。' : '此文件夹目前是空的。',
              Icons.folder_open_outlined,
            )
          else
            Column(
              children: [
                if (_fileView == 'grid')
                  Padding(
                    padding: EdgeInsets.all(compact ? 10 : 16),
                    child: GridView.builder(
                      key: const ValueKey('files-card-grid'),
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: compact ? 180 : 220,
                        mainAxisExtent: (compact ? 183 : 198) + gridHeightExtra,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: _entries.length,
                      itemBuilder: (context, index) =>
                          _fileCard(context, _entries[index]),
                    ),
                  )
                else
                  ..._entries.map(
                    (entry) => _fileTile(context, entry, compact),
                  ),
                if (_searchTruncated)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '搜索结果已达到服务端上限，请缩小关键词。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                if (_nextCursor.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : () => _loadFiles(more: true),
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

  static final RegExp _thumbnailExtensions = RegExp(
    r'\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$',
    caseSensitive: false,
  );

  bool _thumbnailEligible(String name) => _thumbnailExtensions.hasMatch(name);

  /// Server-rendered 512px JPEG for image/video files; falls back to the
  /// extension badge when the pipeline cannot serve one (unsupported source,
  /// oversized file, FFmpeg-less server for exotic containers).
  Widget _fileThumbnail(FileEntry item) {
    final key = '${item.path}@${item.modified}';
    if (_failedThumbnails.contains(key)) return _buildFileBadgeIcon(item);
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
            _failedThumbnails.add(key);
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
    if (_selecting) {
      _toggleSelected(item, !_selectedPaths.contains(item.path));
    } else if (item.isFolder) {
      unawaited(_loadFiles(target: item.path));
    } else {
      unawaited(_preview(item));
    }
  }

  void _startSelectingFile(FileEntry item) {
    _refreshState(() => _selecting = true);
    _toggleSelected(item, !_selectedPaths.contains(item.path));
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
        _failedThumbnails.contains(thumbnailKey)) {
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
        _failedThumbnails.add(thumbnailKey);
        return Center(child: _buildFileBadgeIcon(item));
      },
    );
  }

  Widget _fileCard(BuildContext context, FileEntry item) {
    final colors = Theme.of(context).colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final detailHeight = 72 + (textScale - 1).clamp(0.0, 3.0) * 32;
    final writable = _canWriteItem(item);
    final selected = _selectedPaths.contains(item.path);
    return Card(
      key: ValueKey('file-card-${item.path}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.5 : .7,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _loading ? null : () => _openOrSelectFile(item),
        onLongPress: () => _startSelectingFile(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _fileCardCover(context, item),
                  if (_selecting)
                    Positioned(
                      top: 2,
                      left: 2,
                      child: Checkbox(
                        value: selected,
                        onChanged: (value) => _toggleSelected(item, value),
                      ),
                    ),
                  if (_downloading.contains(item.path))
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        value: _downloadProgress[item.path],
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
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.isFolder ? '文件夹' : formatBytes(item.size),
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
    );
  }

  Widget _fileTile(BuildContext context, FileEntry item, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final writable = _canWriteItem(item);
    final selected = _selectedPaths.contains(item.path);
    final modified = item.modified == null
        ? '修改时间未知'
        : _formatDate(item.modified!);
    return Column(
      children: [
        ListTile(
          minTileHeight: 52,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 20,
            vertical: 0,
          ),
          selected: selected,
          selectedTileColor: colors.primaryContainer.withValues(alpha: .42),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_selecting)
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
          title: Text(
            item.name,
            softWrap: true,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
          ),
          subtitle: Text(
            '${item.isFolder ? '文件夹' : formatBytes(item.size)} · $modified',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          onLongPress: () => _startSelectingFile(item),
          onTap: _loading ? null : () => _openOrSelectFile(item),
          trailing: _fileActionsMenu(item, writable),
        ),
        if (_downloading.contains(item.path))
          Padding(
            padding: const EdgeInsets.only(left: 70, right: 20, bottom: 8),
            child: LinearProgressIndicator(value: _downloadProgress[item.path]),
          ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }

  Widget _fileActionsMenu(FileEntry item, bool writable) =>
      PopupMenuButton<String>(
        tooltip: '文件操作',
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 205, maxWidth: 260),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (value) {
          switch (value) {
            case 'preview':
              _preview(item);
            case 'download':
              _download(item);
            case 'openExternal':
              _openExternal(item);
            case 'share':
              _shareFile(item);
            case 'copy':
              _operate(item, 'copy');
            case 'move':
              _operate(item, 'move');
            case 'rename':
              _rename(item);
            case 'extract':
              _extractZip(item);
            case 'trash':
              _trash(item);
          }
        },
        itemBuilder: (context) => [
          if (!item.isFolder)
            isleActionMenuItem(
              value: 'preview',
              icon: Icons.visibility_outlined,
              label: '预览',
            ),
          if (!item.isFolder)
            isleActionMenuItem(
              value: 'openExternal',
              icon: Icons.open_in_new_rounded,
              label: '其他应用打开',
            ),
          isleActionMenuItem(
            value: 'download',
            icon: item.isFolder
                ? Icons.archive_outlined
                : Icons.download_outlined,
            label: item.isFolder ? '下载文件夹 ZIP' : '下载',
          ),
          if (writable && !item.isFolder && item.name.toLowerCase().endsWith('.zip'))
            isleActionMenuItem(
              value: 'extract',
              icon: Icons.unarchive_outlined,
              label: '解压到同名文件夹',
            ),
          if (!item.isFolder)
            isleActionMenuItem(
              value: 'share',
              icon: Icons.ios_share_outlined,
              label: '分享文件',
            ),
          if (item.isFolder)
            isleActionMenuItem(
              value: 'share',
              icon: Icons.ios_share_outlined,
              label: '分享文件夹 ZIP',
            ),
          if (writable || _canWrite) const PopupMenuDivider(),
          if (writable)
            isleActionMenuItem(
              value: 'rename',
              icon: Icons.drive_file_rename_outline,
              label: '重命名',
            ),
          if (_canWrite)
            isleActionMenuItem(
              value: 'copy',
              icon: Icons.copy_outlined,
              label: '复制',
            ),
          if (writable)
            isleActionMenuItem(
              value: 'move',
              icon: Icons.drive_file_move_outline,
              label: '移动或重命名',
            ),
          if (writable)
            isleActionMenuItem(
              value: 'trash',
              icon: Icons.delete_outline,
              label: '移到回收站',
            ),
        ],
      );
  Widget _trashTile(
    BuildContext context,
    TrashEntry item,
    bool compact,
  ) => Column(
    children: [
      ListTile(
        minTileHeight: 72,
        contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 20,
          vertical: 2,
        ),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            gradient: const LinearGradient(
              colors: [Color(0xfff87171), Color(0xffdc2626)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xffdc2626).withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            Icons.delete_outline_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
        title: Text(
          item.name,
          softWrap: true,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '原路径：${item.originalPath}\n${item.deletedAt == null ? '' : _formatDate(item.deletedAt!)}',
          softWrap: true,
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 4,
          children: [
            IconButton(
              tooltip: '恢复',
              onPressed: () => _restoreTrash(item),
              icon: const Icon(Icons.restore),
            ),
            if (widget.isAdmin || item.originalPath.startsWith('Users/'))
              IconButton(
                tooltip: '永久删除',
                onPressed: () => _purgeTrash(item),
                color: Theme.of(context).colorScheme.error,
                icon: const Icon(Icons.delete_forever_outlined),
              ),
          ],
        ),
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
    ],
  );
  Widget _downloadNotice(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Material(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.download_done_outlined),
            const SizedBox(width: 10),
            Expanded(child: SelectableText(_downloadMessage!)),
            if (_downloadMessage!.startsWith('已下载到：'))
              IconButton(
                tooltip: '复制下载路径',
                onPressed: () => _copyPathToClipboard(
                  _downloadMessage!.substring('已下载到：'.length),
                ),
                icon: const Icon(Icons.copy),
              ),
          ],
        ),
      ),
    ),
  );
  Widget _emptyState(BuildContext context, String text, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.primary.withValues(alpha: isDark ? 0.16 : 0.08),
              border: Border.all(
                color: colors.primary.withValues(alpha: isDark ? 0.25 : 0.18),
                width: 0.75,
              ),
            ),
            child: Icon(icon, size: 26, color: colors.primary),
          ),
          const SizedBox(height: 14),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
