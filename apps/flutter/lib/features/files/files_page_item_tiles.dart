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
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 205, maxWidth: 260),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: _buildFileActionMenuItems(item, writable),
    );
    if (selected != null && mounted) {
      _dispatchFileAction(item, selected);
    }
  }

  Widget _fileActionsMenu(FileEntry item, bool writable) =>
      PopupMenuButton<String>(
        tooltip: '文件操作',
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 205, maxWidth: 260),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (value) => _dispatchFileAction(item, value),
        itemBuilder: (context) => _buildFileActionMenuItems(item, writable),
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
            Expanded(child: SelectableText(_transfers.downloadMessage!)),
            if (_transfers.downloadMessage!.startsWith('已下载到：'))
              IconButton(
                tooltip: '复制下载路径',
                onPressed: () => _copyPathToClipboard(
                  _transfers.downloadMessage!.substring('已下载到：'.length),
                ),
                icon: const Icon(Icons.copy),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _emptyState(
    BuildContext context,
    String text,
    IconData icon, {
    bool showCreateActions = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
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
          if (showCreateActions) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                IslePillButton(
                  label: '上传文件到此目录',
                  icon: Icons.add_rounded,
                  variant: IslePillVariant.primary,
                  onPressed: _dir.loading || _transfers.uploadBusy
                      ? null
                      : _chooseUploadSource,
                ),
                IslePillButton(
                  label: '在此新建文件夹',
                  icon: Icons.create_new_folder_outlined,
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
