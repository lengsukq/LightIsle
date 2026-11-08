part of 'photos_page.dart';

extension _PhotosPageAlbumOverview on _PhotosPageState {
  Future<bool> _addAssetToFolder(PhotoAsset asset) async {
    final root = widget.api.selectedRoot?.identity;
    final result = await Navigator.of(context).push<FolderAlbumSelection>(
      MaterialPageRoute(
        builder: (_) => FolderAlbumsPage(
          api: widget.api,
          source: asset,
          canMove: widget.isAdmin || asset.canWrite,
        ),
      ),
    );
    if (!mounted ||
        result == null ||
        root == null ||
        widget.api.selectedRoot?.identity != root) {
      return false;
    }
    _updateState(() {
      _actionMessage = result.moved ? '照片已移动到相册，图库正在更新。' : '照片已复制到相册，图库正在更新。';
      _actionIsError = false;
    });
    await _loadAssets(reset: true);
    return result.moved;
  }

  Future<void> _showAssetDetails(PhotoAsset asset) async {
    Widget details() => PhotoDetailDialog(
      api: widget.api,
      asset: asset,
      albums: _albums,
      privateAlbums: _privateAlbums,
      isAdmin: widget.isAdmin,
      currentAlbumId: _activeAlbum,
      currentPrivateAlbumId: _activePrivateAlbum,
      personalFavoritesOnly: _personalFavoritesOnly,
      canToggleFavorite: widget.isAdmin || asset.canWrite,
      onToggleFavorite: _toggleFavorite,
      onTogglePersonalFavorite: _togglePersonalFavorite,
      onAddToAlbum: _addToAlbum,
      onRemoveFromAlbum: _removeFromAlbum,
      onAddToPrivateAlbum: _addToPrivateAlbum,
      metadataOnly: true,
      onRemoveFromPrivateAlbum: _removeFromPrivateAlbum,
    );
    final wide = MediaQuery.sizeOf(context).width >= 800;
    if (wide) {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭照片信息',
        barrierColor: Colors.black45,
        pageBuilder: (dialogContext, _, _) => Align(
          alignment: Alignment.centerRight,
          child: SafeArea(
            child: Material(
              color: Theme.of(dialogContext).colorScheme.surface,
              elevation: 12,
              child: SizedBox(
                width: 400,
                height: double.infinity,
                child: details(),
              ),
            ),
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) =>
            FractionallySizedBox(heightFactor: 0.78, child: details()),
      );
    }
  }

  Widget _albumOverviewBody(BuildContext pageContext, StateSetter refreshPage) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final sideBySide = constraints.maxWidth >= 600 && textScale < 1.6;
        final inlineActions = constraints.maxWidth >= 570 && textScale < 1.4;
        final inset = constraints.maxWidth >= 600 ? 28.0 : 16.0;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;

        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '我的相册',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '按主题整理照片，也可以与家人分享',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('文件夹相册'),
              onPressed: _albumBusy
                  ? null
                  : () async {
                      final root = widget.api.selectedRoot?.identity;
                      final album = await Navigator.of(pageContext)
                          .push<FolderAlbumSelection>(
                            MaterialPageRoute(
                              builder: (_) => FolderAlbumsPage(api: widget.api),
                            ),
                          );
                      if (pageContext.mounted &&
                          album != null &&
                          widget.api.selectedRoot?.identity == root) {
                        Navigator.pop(
                          pageContext,
                          'folder:${Uri.encodeComponent(album.path)}',
                        );
                      }
                    },
            ),
          ],
        );

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              key: const ValueKey('photoAlbumOverviewList'),
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 36),
              children: [
                if (inlineActions)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: heading),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: actions,
                        ),
                      ),
                    ],
                  )
                else ...[
                  heading,
                  const SizedBox(height: 12),
                  actions,
                ],
                if (_actionIsError && _actionMessage != null) ...[
                  const SizedBox(height: 12),
                  MediaStatusBanner(message: _actionMessage!, isError: true),
                ],
                const SizedBox(height: 22),
                if (sideBySide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _albumOverviewSection(
                          pageContext,
                          refreshPage,
                          private: true,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _albumOverviewSection(
                          pageContext,
                          refreshPage,
                          private: false,
                        ),
                      ),
                    ],
                  )
                else ...[
                  _albumOverviewSection(
                    pageContext,
                    refreshPage,
                    private: true,
                  ),
                  const SizedBox(height: 16),
                  _albumOverviewSection(
                    pageContext,
                    refreshPage,
                    private: false,
                  ),
                ],
                const SizedBox(height: 16),
                _folderAlbumOverviewSection(pageContext, refreshPage),
                const SizedBox(height: 16),
                _collectionsQuickGrid(pageContext),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _folderAlbumOverviewSection(
    BuildContext pageContext,
    StateSetter refreshPage,
  ) {
    final scheme = Theme.of(pageContext).colorScheme;
    return Container(
      key: const ValueKey('folderAlbumSection'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: .55),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _albumSectionHeading(
                  pageContext,
                  '照片目录中的相册',
                  _folderAlbums.length,
                  '对应个人照片目录下的真实文件夹，支持家庭受控软链接共享',
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final root = widget.api.selectedRoot?.identity;
                  final album = await Navigator.of(pageContext)
                      .push<FolderAlbumSelection>(
                        MaterialPageRoute(
                          builder: (_) => FolderAlbumsPage(api: widget.api),
                        ),
                      );
                  await _refreshFolderAlbums();
                  if (pageContext.mounted) {
                    refreshPage(() {});
                    if (album != null &&
                        widget.api.selectedRoot?.identity == root) {
                      Navigator.pop(
                        pageContext,
                        'folder:${Uri.encodeComponent(album.path)}',
                      );
                    }
                  }
                },
                icon: const Icon(Icons.folder_open_rounded, size: 17),
                label: const Text('管理与共享'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_folderAlbums.isEmpty)
            _emptyAlbumSection(
              pageContext,
              Icons.folder_special_outlined,
              '照片目录中还没有文件夹相册',
              '点击右上角“文件夹相册”或“管理与共享”直接创建并分享给家人',
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final item in _folderAlbums)
                  ActionChip(
                    avatar: Icon(
                      item['shared'] == true
                          ? Icons.folder_shared_outlined
                          : Icons.folder_outlined,
                      size: 18,
                    ),
                    label: Text(
                      item['shared'] == true
                          ? '${item['name']} (@${item['ownerUsername']})'
                          : '${item['name']}',
                    ),
                    onPressed: () {
                      final path = item['path']?.toString() ?? '';
                      if (path.isNotEmpty) {
                        Navigator.pop(
                          pageContext,
                          'folder:${Uri.encodeComponent(path)}',
                        );
                      }
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _collectionsQuickGrid(BuildContext pageContext) {
    final scheme = Theme.of(pageContext).colorScheme;
    final items =
        <({String label, String subtitle, IconData icon, String route})>[
          (
            label: '我的收藏',
            subtitle: '仅自己可见的星标照片',
            icon: Icons.star_rounded,
            route: 'collection:personalFavorites',
          ),
          (
            label: '共享收藏',
            subtitle: '家庭共同喜爱的精选',
            icon: Icons.favorite_rounded,
            route: 'collection:sharedFavorites',
          ),
          (
            label: '那年今天',
            subtitle: '重温往年今日的回忆',
            icon: Icons.auto_awesome_rounded,
            route: 'collection:onThisDay',
          ),
          (
            label: '足迹地图',
            subtitle: '按地理位置回溯照片',
            icon: Icons.map_rounded,
            route: 'collection:map',
          ),
        ];
    return Container(
      key: const ValueKey('collectionsQuickGrid'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: .55),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '智能合集与探索',
            style: Theme.of(
              pageContext,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final item in items)
                ActionChip(
                  avatar: Icon(item.icon, size: 18),
                  label: Text(item.label),
                  tooltip: item.subtitle,
                  onPressed: () => Navigator.pop(pageContext, item.route),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _albumOverviewSection(
    BuildContext pageContext,
    StateSetter refreshPage, {
    required bool private,
  }) {
    final scheme = Theme.of(pageContext).colorScheme;
    final albums = private ? _privateAlbums : _albums;
    return Container(
      key: ValueKey(private ? 'privateAlbumSection' : 'sharedAlbumSection'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: .55),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _albumSectionHeading(
            pageContext,
            private ? '旧版私人相册' : '旧版共享相册',
            albums.length,
            private ? '仅自己可见' : '家庭成员共享',
          ),
          const SizedBox(height: 14),
          if (private && _privateAlbumsFailure != null)
            MediaStatusBanner(
              message: '私人相册暂时无法读取：${mediaErrorLabel(_privateAlbumsFailure!)}',
              isError: true,
              trailing: TextButton(
                onPressed: _privateAlbumsRefreshing
                    ? null
                    : () async {
                        await _refreshPrivateAlbums();
                        if (pageContext.mounted) refreshPage(() {});
                      },
                child: const Text('重试'),
              ),
            )
          else if (albums.isEmpty)
            _emptyAlbumSection(
              pageContext,
              private
                  ? Icons.lock_outline_rounded
                  : Icons.people_outline_rounded,
              private ? '没有旧版私人相册' : '没有旧版共享相册',
              private
                  ? '新建相册使用真实文件夹'
                  : widget.isAdmin
                  ? '现有共享相册会继续保留'
                  : '家庭共享相册将显示在这里',
            )
          else
            _albumCards(pageContext, albums, private: private),
        ],
      ),
    );
  }

  Widget _albumSectionHeading(
    BuildContext context,
    String title,
    int count,
    String description,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Flexible(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      const SizedBox(height: 3),
      Text(
        description,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  Widget _emptyAlbumSection(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}
