part of 'files_page.dart';

extension _FilesPageItemTiles on _FilesPageState {
  void _dispatchFileAction(FileEntry item, String value) {
    switch (value) {
      case 'preview':
        _preview(item);
      case 'openContainingFolder':
        unawaited(_openContainingFolder(item));
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
  }

  List<PopupMenuEntry<String>> _buildFileActionMenuItems(
    FileEntry item,
    bool writable,
  ) => [
    if (_filter.searching)
      isleActionMenuItem(
        value: 'openContainingFolder',
        icon: Icons.folder_open_outlined,
        label: '打开所在目录',
      ),
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
      icon: item.isFolder ? Icons.archive_outlined : Icons.download_outlined,
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
    const PopupMenuDivider(),
    if (writable)
      isleActionMenuItem(
        value: 'rename',
        icon: Icons.drive_file_rename_outline,
        label: '重命名',
      ),
    isleActionMenuItem(value: 'copy', icon: Icons.copy_outlined, label: '复制'),
    if (writable)
      isleActionMenuItem(
        value: 'move',
        icon: Icons.drive_file_move_outline,
        label: '移动到…',
      ),
    if (writable)
      isleActionMenuItem(
        value: 'trash',
        icon: Icons.delete_outline,
        label: '移到回收站',
      ),
  ];

  Future<void> _showFileContextMenu(
    BuildContext context,
    Offset globalPosition,
    FileEntry item,
    bool writable,
  ) async {
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (overlay is! RenderBox) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 205, maxWidth: 260),
      shape: IsleShapes.md(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      items: _buildFileActionMenuItems(item, writable),
    );
    if (selected != null && mounted) {
      _dispatchFileAction(item, selected);
    }
  }

  Widget _fileActionsMenu(FileEntry item, bool writable) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      tooltip: '文件操作',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 205, maxWidth: 260),
      shape: IsleShapes.md(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      onSelected: (value) => _dispatchFileAction(item, value),
      itemBuilder: (context) => _buildFileActionMenuItems(item, writable),
    );
  }

  Widget _trashTile(BuildContext context, TrashEntry item, bool compact) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          dense: true,
          minTileHeight: 54,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 16,
            vertical: 2,
          ),
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: colors.error.withValues(alpha: 0.12),
            ),
            child: Icon(
              Icons.delete_outline_rounded,
              color: colors.error,
              size: 18,
            ),
          ),
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '原路径：${item.originalPath}${item.deletedAt == null ? '' : ' · ${_formatDate(item.deletedAt!)}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5),
          ),
          trailing: Wrap(
            spacing: 2,
            children: [
              IconButton(
                tooltip: '恢复',
                visualDensity: VisualDensity.compact,
                onPressed: () => _restoreTrash(item),
                icon: const Icon(Icons.restore, size: 19),
              ),
              if (widget.isAdmin || item.originalPath.startsWith('Users/'))
                IconButton(
                  tooltip: '永久删除',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _purgeTrash(item),
                  color: colors.error,
                  icon: const Icon(Icons.delete_forever_outlined, size: 19),
                ),
            ],
          ),
        ),
        const Divider(height: 1, indent: 56, endIndent: 14),
      ],
    );
  }

  Widget _downloadNotice(BuildContext context) {
    final palette = IslePalette.of(context);
    final sage = palette['brandSage'];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        tint: sage,
        radius: IsleRadius.md,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.download_done_outlined, size: 19, color: sage),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(_transfers.downloadMessage!)),
            if (_transfers.downloadMessage!.startsWith('已下载到：'))
              IconButton(
                tooltip: '复制下载路径',
                visualDensity: VisualDensity.compact,
                onPressed: () => _copyPathToClipboard(
                  _transfers.downloadMessage!.substring('已下载到：'.length),
                ),
                icon: const Icon(Icons.copy, size: 18),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(
    BuildContext context,
    String text,
    IconData icon, {
    bool showCreateActions = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final palette = IslePalette.of(context);
    final accent = palette['brandAmber'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 30),
      child: Column(
        children: [
          IsleSquircleBadge(icon: icon, color: accent, size: 46, iconSize: 22),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: colors.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (showCreateActions) ...[
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                IslePillButton(
                  label: '上传文件到此目录',
                  icon: Icons.add_rounded,
                  compact: true,
                  variant: IslePillVariant.primary,
                  onPressed: _dir.loading || _transfers.uploadBusy
                      ? null
                      : _chooseUploadSource,
                ),
                IslePillButton(
                  label: '在此新建文件夹',
                  icon: Icons.create_new_folder_outlined,
                  compact: true,
                  onPressed: _dir.loading ? null : _createFolder,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
