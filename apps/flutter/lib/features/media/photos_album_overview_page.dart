import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'folder_albums_page.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'photos_album_overview_cards.dart';
import 'photos_controller.dart';

/// Dedicated albums overview screen showing folder albums, optional legacy
/// private/shared albums, and smart collections. Pops with a route token.
class PhotosAlbumOverviewPage extends StatelessWidget {
  const PhotosAlbumOverviewPage({
    required this.api,
    required this.controller,
    super.key,
  });

  final LightIsleApi api;
  final PhotosController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (pageContext, _) => Scaffold(
        key: const ValueKey('photoAlbumsPage'),
        appBar: const IsleAppBar(title: Text('相册')),
        body: SafeArea(child: _buildOverviewBody(pageContext)),
      ),
    );
  }

  Widget _buildOverviewBody(BuildContext pageContext) {
    final catalog = controller.catalog;
    final feed = controller.feed;
    final hasPrivateSection =
        catalog.privateAlbums.isNotEmpty || catalog.privateFailure != null;
    final hasSharedSection = catalog.sharedAlbums.isNotEmpty;

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
              onPressed: catalog.busy
                  ? null
                  : () => _openFolderAlbums(pageContext, refreshAfter: false),
            ),
          ],
        );

        Widget buildPrivateSection() => _LegacyAlbumOverviewSection(
          api: api,
          private: true,
          albums: catalog.privateAlbums,
          privateFailure: catalog.privateFailure,
          privateRefreshing: catalog.privateRefreshing,
          onRetryPrivate: () =>
              unawaited(controller.albums.refreshPrivateAlbums()),
          onSelectRoute: (route) => Navigator.pop(pageContext, route),
        );

        Widget buildSharedSection() => _LegacyAlbumOverviewSection(
          api: api,
          private: false,
          albums: catalog.sharedAlbums,
          privateFailure: null,
          privateRefreshing: false,
          onRetryPrivate: null,
          onSelectRoute: (route) => Navigator.pop(pageContext, route),
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
                if (feed.actionIsError && feed.actionMessage != null) ...[
                  const SizedBox(height: 10),
                  MediaStatusBanner(
                    message: feed.actionMessage!,
                    isError: true,
                  ),
                ],
                const SizedBox(height: 14),
                _FolderAlbumOverviewSection(
                  folderAlbums: catalog.folderAlbums,
                  onManageFolders: () =>
                      _openFolderAlbums(pageContext, refreshAfter: true),
                  onSelectFolder: (path) => Navigator.pop(
                    pageContext,
                    'folder:${Uri.encodeComponent(path)}',
                  ),
                ),
                if (hasPrivateSection || hasSharedSection) ...[
                  const SizedBox(height: 12),
                  if (sideBySide && hasPrivateSection && hasSharedSection)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: buildPrivateSection()),
                        const SizedBox(width: 12),
                        Expanded(child: buildSharedSection()),
                      ],
                    )
                  else ...[
                    if (hasPrivateSection) buildPrivateSection(),
                    if (hasPrivateSection && hasSharedSection)
                      const SizedBox(height: 12),
                    if (hasSharedSection) buildSharedSection(),
                  ],
                ],
                const SizedBox(height: 12),
                PhotosCollectionsQuickGrid(
                  onSelectRoute: (route) => Navigator.pop(pageContext, route),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openFolderAlbums(
    BuildContext pageContext, {
    required bool refreshAfter,
  }) async {
    final root = api.selectedRoot?.identity;
    final album = await Navigator.of(pageContext).push<FolderAlbumSelection>(
      buildIslePageRoute(builder: (_) => FolderAlbumsPage(api: api)),
    );
    if (refreshAfter) {
      await controller.albums.refreshFolderAlbums();
    }
    if (pageContext.mounted &&
        album != null &&
        api.selectedRoot?.identity == root) {
      Navigator.pop(pageContext, 'folder:${Uri.encodeComponent(album.path)}');
    }
  }
}

class _FolderAlbumOverviewSection extends StatelessWidget {
  const _FolderAlbumOverviewSection({
    required this.folderAlbums,
    required this.onManageFolders,
    required this.onSelectFolder,
  });

  final List<Map<String, dynamic>> folderAlbums;
  final VoidCallback onManageFolders;
  final ValueChanged<String> onSelectFolder;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette.of(context);
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
                child: _AlbumSectionHeading(
                  title: '文件夹相册',
                  count: folderAlbums.length,
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onManageFolders,
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('管理与共享'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (folderAlbums.isEmpty)
            const _EmptyAlbumSection(
              icon: Icons.folder_special_outlined,
              title: '暂无文件夹相册',
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in folderAlbums)
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
                      if (path.isNotEmpty) onSelectFolder(path);
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LegacyAlbumOverviewSection extends StatelessWidget {
  const _LegacyAlbumOverviewSection({
    required this.api,
    required this.private,
    required this.albums,
    required this.privateFailure,
    required this.privateRefreshing,
    required this.onRetryPrivate,
    required this.onSelectRoute,
  });

  final LightIsleApi api;
  final bool private;
  final List<MediaAlbum> albums;
  final Object? privateFailure;
  final bool privateRefreshing;
  final VoidCallback? onRetryPrivate;
  final ValueChanged<String> onSelectRoute;

  @override
  Widget build(BuildContext context) {
    return IsleSurface(
      key: ValueKey(private ? 'privateAlbumSection' : 'sharedAlbumSection'),
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AlbumSectionHeading(
            title: private ? '旧版私人相册' : '旧版共享相册',
            count: albums.length,
          ),
          const SizedBox(height: 10),
          if (private && privateFailure != null)
            MediaStatusBanner(
              message: '私人相册暂时无法读取：${mediaErrorLabel(privateFailure!)}',
              isError: true,
              trailing: TextButton(
                onPressed: privateRefreshing ? null : onRetryPrivate,
                child: const Text('重试'),
              ),
            )
          else if (albums.isEmpty)
            _EmptyAlbumSection(
              icon: private
                  ? Icons.lock_outline_rounded
                  : Icons.people_outline_rounded,
              title: private ? '暂无私人相册' : '暂无共享相册',
            )
          else
            PhotosAlbumCardsGrid(
              api: api,
              albums: albums,
              private: private,
              onSelectRoute: onSelectRoute,
            ),
        ],
      ),
    );
  }
}

class _AlbumSectionHeading extends StatelessWidget {
  const _AlbumSectionHeading({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
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
}

class _EmptyAlbumSection extends StatelessWidget {
  const _EmptyAlbumSection({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
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
