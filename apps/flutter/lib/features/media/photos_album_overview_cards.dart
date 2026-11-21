import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'media_models.dart';

/// Responsive cover card grid for legacy shared and private photo albums.
class PhotosAlbumCardsGrid extends StatelessWidget {
  const PhotosAlbumCardsGrid({
    required this.api,
    required this.albums,
    required this.private,
    required this.onSelectRoute,
    super.key,
  });

  static const int _coverMaxBytes = 4 * 1024 * 1024;

  final LightIsleApi api;
  final List<MediaAlbum> albums;
  final bool private;
  final ValueChanged<String> onSelectRoute;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final columns = ((constraints.maxWidth + 12) / 176).floor().clamp(1, 8);
        final available = (constraints.maxWidth - (columns - 1) * 12) / columns;
        final cardWidth = available.clamp(1.0, 168.0);
        return Wrap(
          spacing: 12,
          runSpacing: 16,
          children: [
            for (final album in albums)
              SizedBox(
                key: ValueKey(
                  'albumCard_${private ? 'private' : 'shared'}_${album.id}',
                ),
                width: cardWidth,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: IsleRadius.brSm,
                    onTap: () => onSelectRoute(
                      '${private ? 'private' : 'shared'}:${album.id}',
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: IsleRadius.brSm,
                            border: Border.all(
                              color: IsleGlass.rimBorderColor(isDark),
                              width: 1.0,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: AspectRatio(
                            aspectRatio: 1.22,
                            child: album.coverAssetId > 0
                                ? AuthenticatedMediaImage(
                                    api: api,
                                    path:
                                        '/api/v2/photos/${album.coverAssetId}/thumbnail',
                                    fit: BoxFit.cover,
                                    maxBytes: _coverMaxBytes,
                                    loadingBuilder: (_) =>
                                        _AlbumCoverPlaceholder(
                                          private: private,
                                        ),
                                    errorBuilder: (_, _, retry) => Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        _AlbumCoverPlaceholder(
                                          private: private,
                                        ),
                                        Align(
                                          alignment: Alignment.bottomRight,
                                          child: IconButton(
                                            tooltip: '重试相册封面',
                                            onPressed: retry,
                                            icon: const Icon(Icons.refresh),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : _AlbumCoverPlaceholder(private: private),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                album.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${album.count} 项 · ${private ? '仅自己可见' : '家庭共享'}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AlbumCoverPlaceholder extends StatelessWidget {
  const _AlbumCoverPlaceholder({required this.private});

  final bool private;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerLow,
            scheme.primaryContainer.withValues(alpha: .55),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          private ? Icons.photo_library_outlined : Icons.collections_outlined,
          size: 27,
          color: scheme.primary.withValues(alpha: .8),
        ),
      ),
    );
  }
}

/// Smart collections quick-jump surface shown at the bottom of the albums
/// overview page.
class PhotosCollectionsQuickGrid extends StatelessWidget {
  const PhotosCollectionsQuickGrid({required this.onSelectRoute, super.key});

  final ValueChanged<String> onSelectRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final items =
        <({String label, IconData icon, Color accent, String route})>[
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
                        onPressed: () => onSelectRoute(item.route),
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
                          onTap: () => onSelectRoute(item.route),
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
}
