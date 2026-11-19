part of 'photos_page.dart';

extension _PhotosPageAlbumOverview on _PhotosPageState {
  Future<bool> _addAssetToFolder(PhotoAsset asset) async {
    final root = widget.api.selectedRoot?.identity;
    final result = await Navigator.of(context).push<FolderAlbumSelection>(
      buildIslePageRoute(
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
    _updateState(
      () => _feed.setActionFeedback(
        result.moved ? '照片已移动到相册，图库正在更新。' : '照片已复制到相册，图库正在更新。',
      ),
    );
    await _loadAssets(reset: true);
    return result.moved;
  }

  Future<void> _showAssetDetails(PhotoAsset asset) async {
    void jumpToScene(String label) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (!mounted) return;
      _scope.searchTimer?.cancel();
      _scope.searchController.text = label;
      _updateState(() {
        _selection.clear();
        _scope.setCollectionScope();
        _scope.showSearch = true;
        _scope.searchMode = PhotoSearchMode.scene;
        _scope.query = label;
      });
      unawaited(_loadAssets(reset: true));
    }

    void jumpToPerson(int personId, String personName) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (!mounted) return;
      _updateState(() {
        _selection.clear();
        _scope.setCollectionScope(personId: personId, personName: personName);
      });
      unawaited(_loadAssets(reset: true));
    }

    Widget details() => PhotoDetailDialog(
      api: widget.api,
      asset: asset,
      albums: _catalog.sharedAlbums,
      privateAlbums: _catalog.privateAlbums,
      isAdmin: widget.isAdmin,
      currentAlbumId: _scope.activeAlbum,
      currentPrivateAlbumId: _scope.activePrivateAlbum,
      canToggleFavorite: widget.isAdmin || asset.canWrite,
      onToggleFavorite: _toggleFavorite,
      onTogglePersonalFavorite: _togglePersonalFavorite,
      onAddToAlbum: _addToAlbum,
      onRemoveFromAlbum: _removeFromAlbum,
      onAddToPrivateAlbum: _addToPrivateAlbum,
      metadataOnly: true,
      onRemoveFromPrivateAlbum: _removeFromPrivateAlbum,
      onSelectSceneLabel: jumpToScene,
      onSelectPerson: jumpToPerson,
    );
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (wide) {
      final reduced = IsleMotion.reducedMotion(context);
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭照片信息',
        barrierColor: const Color(0x66141210),
        transitionDuration: reduced ? Duration.zero : IsleMotion.modalEnter,
        transitionBuilder: (dialogContext, animation, _, dialogChild) {
          if (IsleMotion.reducedMotion(dialogContext)) {
            return dialogChild;
          }
          return AnimatedBuilder(
            animation: animation,
            child: dialogChild,
            builder: (context, drawerChild) {
              final isReverse = animation.status == AnimationStatus.reverse;
              final t = animation.value.clamp(0.0, 1.0);
              final progress = isReverse
                  ? IsleMotion.exitCurve.transform(t)
                  : IsleMotion.gentleSpring.transform(t);
              final dx = (1.0 - progress) * (isReverse ? 28.0 : 48.0);
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(dx, 0),
                  child: drawerChild,
                ),
              );
            },
          );
        },
        pageBuilder: (dialogContext, _, _) => Align(
          alignment: Alignment.centerRight,
          child: SafeArea(
            child: Container(
              width: 392,
              height: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(dialogContext).colorScheme.surface,
                border: Border(
                  left: BorderSide(
                    color: IsleGlass.rimBorderColor(isDark),
                    width: 1.0,
                  ),
                ),
                boxShadow: IsleShadows.floating(isDark),
              ),
              child: Material(
                type: MaterialType.transparency,
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
        shape: IsleShapes.sheet(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
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
        final inset = constraints.maxWidth >= 600 ? 24.0 : 14.0;
        final theme = Theme.of(context);

        final heading = Text(
          '我的相册',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.35,
          ),
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
                  vertical: 7,
                ),
              ),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('文件夹相册'),
              onPressed: _catalog.busy
                  ? null
                  : () async {
                      final root = widget.api.selectedRoot?.identity;
                      final album = await Navigator.of(pageContext)
                          .push<FolderAlbumSelection>(
                            buildIslePageRoute(
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
            constraints: const BoxConstraints(
              maxWidth: IsleLayout.workbenchMaxWidth,
            ),
            child: ListView(
              key: const ValueKey('photoAlbumOverviewList'),
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 28),
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
                  const SizedBox(height: 10),
                  actions,
                ],
                if (_feed.actionIsError && _feed.actionMessage != null) ...[
                  const SizedBox(height: 10),
                  MediaStatusBanner(
                    message: _feed.actionMessage!,
                    isError: true,
                  ),
                ],
                const SizedBox(height: 14),
                _folderAlbumOverviewSection(pageContext, refreshPage),
                if (_catalog.privateAlbums.isNotEmpty ||
                    _catalog.privateFailure != null ||
                    _catalog.sharedAlbums.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  if (sideBySide &&
                      (_catalog.privateAlbums.isNotEmpty ||
                          _catalog.privateFailure != null) &&
                      _catalog.sharedAlbums.isNotEmpty)
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
                        const SizedBox(width: 12),
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
                    if (_catalog.privateAlbums.isNotEmpty ||
                        _catalog.privateFailure != null)
                      _albumOverviewSection(
                        pageContext,
                        refreshPage,
                        private: true,
                      ),
                    if ((_catalog.privateAlbums.isNotEmpty ||
                            _catalog.privateFailure != null) &&
                        _catalog.sharedAlbums.isNotEmpty)
                      const SizedBox(height: 12),
                    if (_catalog.sharedAlbums.isNotEmpty)
                      _albumOverviewSection(
                        pageContext,
                        refreshPage,
                        private: false,
                      ),
                  ],
                ],
                const SizedBox(height: 12),
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
    final isDark = Theme.of(pageContext).brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final rose = palette['brandRose'];
    final amber = palette['brandAmber'];
    return IsleSurface(
      key: const ValueKey('folderAlbumSection'),
      tint: rose,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _albumSectionHeading(
                  pageContext,
                  '文件夹相册',
                  _catalog.folderAlbums.length,
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () async {
                  final root = widget.api.selectedRoot?.identity;
                  final album = await Navigator.of(pageContext)
                      .push<FolderAlbumSelection>(
                        buildIslePageRoute(
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
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('管理与共享'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_catalog.folderAlbums.isEmpty)
            _emptyAlbumSection(
              pageContext,
              Icons.folder_special_outlined,
              '暂无文件夹相册',
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in _catalog.folderAlbums)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: borderColor, width: 1.0),
                    avatar: Icon(
                      item['shared'] == true
                          ? Icons.folder_shared_outlined
                          : Icons.folder_rounded,
                      size: 16,
                      color: item['shared'] == true ? rose : amber,
                    ),
                    label: Text(
                      item['shared'] == true
                          ? '${item['name']} (@${item['ownerUsername']})'
                          : '${item['name']}',
                      style: const TextStyle(fontSize: 12.5),
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
    final theme = Theme.of(pageContext);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final items =
        <({
          String label,
          IconData icon,
          Color accent,
          String route,
        })>[
          (
            label: '我的收藏',
            icon: Icons.star_rounded,
            accent: palette['brandAmber'],
            route: 'collection:personalFavorites',
          ),
          (
            label: '共享收藏',
            icon: Icons.favorite_rounded,
            accent: palette['brandRose'],
            route: 'collection:sharedFavorites',
          ),
          (
            label: '那年今天',
            icon: Icons.auto_awesome_rounded,
            accent: palette['brandViolet'],
            route: 'collection:onThisDay',
          ),
          (
            label: '足迹地图',
            icon: Icons.map_rounded,
            accent: palette['brandSage'],
            route: 'collection:map',
          ),
        ];
    return IsleSurface(
      key: const ValueKey('collectionsQuickGrid'),
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '智能合集',
            style: theme.textTheme.titleSmall?.copyWith(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final textScale =
                  MediaQuery.textScalerOf(context).scale(14) / 14;
              if (constraints.maxWidth < 460 || textScale > 1.5) {
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in items)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: borderColor, width: 1.0),
                        avatar: Icon(item.icon, size: 16, color: item.accent),
                        label: Text(
                          item.label,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        onPressed: () =>
                            Navigator.pop(pageContext, item.route),
                      ),
                  ],
                );
              }
              final cols = constraints.maxWidth >= 820 ? 4 : 2;
              final w = (constraints.maxWidth - (cols - 1) * 10) / cols;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: w,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: IsleRadius.brMd,
                          onTap: () => Navigator.pop(pageContext, item.route),
                          child: Ink(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 11,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: IsleRadius.brMd,
                              color: palette['cardItemBottom'],
                              border: Border.all(
                                color: borderColor,
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                IsleSquircleBadge(
                                  icon: item.icon,
                                  color: item.accent,
                                  size: 30,
                                  iconSize: 15.5,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
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
    final albums = private ? _catalog.privateAlbums : _catalog.sharedAlbums;
    final privateFailure = _catalog.privateFailure;
    return IsleSurface(
      key: ValueKey(private ? 'privateAlbumSection' : 'sharedAlbumSection'),
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _albumSectionHeading(
            pageContext,
            private ? '旧版私人相册' : '旧版共享相册',
            albums.length,
          ),
          const SizedBox(height: 10),
          if (private && privateFailure != null)
            MediaStatusBanner(
              message: '私人相册暂时无法读取：${mediaErrorLabel(privateFailure)}',
              isError: true,
              trailing: TextButton(
                onPressed: _catalog.privateRefreshing
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
              private ? '暂无私人相册' : '暂无共享相册',
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
  ) => Row(
    children: [
      Flexible(
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(width: 6),
      IsleBadgePill(label: '$count'),
    ],
  );

  Widget _emptyAlbumSection(
    BuildContext context,
    IconData icon,
    String title,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Icon(
          icon,
          size: 17,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}
