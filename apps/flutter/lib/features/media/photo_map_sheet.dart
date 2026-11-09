part of 'photo_map_page.dart';

class _PhotoMapPin extends StatelessWidget {
  const _PhotoMapPin({
    required this.api,
    required this.memoryCache,
    required this.group,
    required this.selected,
    required this.loadThumbnail,
    required this.onTap,
    super.key,
  });

  final LightIsleApi api;
  final MediaImageMemoryCache memoryCache;
  final _GeoGroup group;
  final bool selected;
  final bool loadThumbnail;
  final VoidCallback? onTap;

  Widget _placeholder(ColorScheme scheme) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          scheme.primaryContainer,
          scheme.secondaryContainer,
        ],
      ),
    ),
    child: Center(
      child: Icon(
        group.coverIsVideo ? Icons.videocam_rounded : Icons.photo_rounded,
        size: 18,
        color: scheme.onPrimaryContainer,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = group.ids.length;
    final countLabel = count > 999 ? '999+' : '$count';
    final boxSize = selected ? 50.0 : 44.0;
    final borderColor = selected ? scheme.primary : Colors.white;

    return Tooltip(
      message: '查看 $count 张照片',
      child: Semantics(
        button: true,
        selected: selected,
        label: '查看 $count 张照片',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: 68,
            height: 70,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  bottom: 6,
                  child: Transform.rotate(
                    angle: math.pi / 4,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: borderColor,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: selected ? 4 : 7,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    width: boxSize,
                    height: boxSize,
                    padding: EdgeInsets.all(selected ? 2.5 : 2.0),
                    decoration: BoxDecoration(
                      color: borderColor,
                      borderRadius: BorderRadius.circular(12),
                      border: selected
                          ? Border.all(color: Colors.white, width: 1.5)
                          : null,
                      boxShadow: [
                        BoxShadow(
                          color: selected
                              ? scheme.primary.withValues(alpha: 0.45)
                              : Colors.black.withValues(alpha: 0.28),
                          blurRadius: selected ? 12 : 7,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9.5),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (loadThumbnail)
                            AuthenticatedMediaImage(
                              api: api,
                              path: '/api/v2/photos/${group.coverId}/thumbnail',
                              memoryCache: memoryCache,
                              maxBytes: 2 * 1024 * 1024,
                              fit: BoxFit.cover,
                              loadingBuilder: (_) => _placeholder(scheme),
                              errorBuilder: (_, _, _) => _placeholder(scheme),
                            )
                          else
                            _placeholder(scheme),
                          if (count == 1 && group.coverIsVideo)
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(2),
                                  child: Icon(
                                    Icons.play_arrow_rounded,
                                    size: 11,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (count > 1)
                  Positioned(
                    top: 0,
                    right: 2,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5.5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: selected ? scheme.primary : const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white, width: 1.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Text(
                        countLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapZoomControls extends StatelessWidget {
  const _MapZoomControls({
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFitAll,
  });

  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFitAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canZoomIn = zoom < photoMapMaxZoom - 0.05;
    final canZoomOut = zoom > photoMapMinZoom + 0.05;
    return Material(
      color: scheme.surface.withValues(alpha: 0.92),
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('photo-map-zoom-in'),
            tooltip: '放大地图',
            visualDensity: VisualDensity.compact,
            onPressed: canZoomIn ? onZoomIn : null,
            icon: const Icon(Icons.add_rounded, size: 20),
          ),
          Divider(height: 1, thickness: 0.5, color: scheme.outlineVariant),
          IconButton(
            key: const ValueKey('photo-map-zoom-out'),
            tooltip: '缩小地图',
            visualDensity: VisualDensity.compact,
            onPressed: canZoomOut ? onZoomOut : null,
            icon: const Icon(Icons.remove_rounded, size: 20),
          ),
          Divider(height: 1, thickness: 0.5, color: scheme.outlineVariant),
          IconButton(
            key: const ValueKey('photo-map-fit-all'),
            tooltip: '查看全部足迹',
            visualDensity: VisualDensity.compact,
            onPressed: onFitAll,
            icon: const Icon(Icons.fit_screen_rounded, size: 19),
          ),
        ],
      ),
    );
  }
}

class _LocationPhotoSheet extends StatelessWidget {
  const _LocationPhotoSheet({
    required this.api,
    required this.memoryCache,
    required this.group,
    required this.assets,
    required this.loading,
    required this.error,
    required this.expanded,
    required this.canZoomCluster,
    required this.clusterIndex,
    required this.totalClusters,
    required this.onToggleExpand,
    required this.onZoomCluster,
    required this.onStepCluster,
    required this.onRetry,
    required this.onClose,
    required this.onOpenAsset,
  });

  final LightIsleApi api;
  final MediaImageMemoryCache memoryCache;
  final _GeoGroup group;
  final List<PhotoAsset> assets;
  final bool loading;
  final String? error;
  final bool expanded;
  final bool canZoomCluster;
  final int clusterIndex;
  final int totalClusters;
  final VoidCallback onToggleExpand;
  final VoidCallback onZoomCluster;
  final ValueChanged<int> onStepCluster;
  final VoidCallback onRetry;
  final VoidCallback onClose;
  final void Function(PhotoAsset asset, List<PhotoAsset> groupAssets)
  onOpenAsset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dateLabel = group.dateRangeLabel;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 680;
        final sheetWidth = wide ? 420.0 : constraints.maxWidth;
        final maxSheetHeight = (constraints.maxHeight * (expanded ? 0.64 : 0.42))
            .clamp(190.0, 440.0);
        final columns = sheetWidth >= 380 ? 4 : 3;

        return Align(
          alignment: wide ? Alignment.bottomRight : Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              wide ? 16 : 10,
              0,
              wide ? 16 : 10,
              10,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: sheetWidth,
                maxHeight: maxSheetHeight,
              ),
              child: Material(
                key: const ValueKey('photo-map-location-sheet'),
                color: scheme.surface.withValues(alpha: 0.97),
                elevation: 10,
                shadowColor: Colors.black38,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      onTap: onToggleExpand,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.35,
                              ),
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 2, 8, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  sameLocationPickerTitle(group.ids.length),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (dateLabel.isNotEmpty)
                                  Text(
                                    dateLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (totalClusters > 1) ...[
                            IconButton(
                              tooltip: '上一处足迹',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onStepCluster(-1),
                              icon: const Icon(
                                Icons.chevron_left_rounded,
                                size: 20,
                              ),
                            ),
                            Text(
                              '${clusterIndex + 1}/$totalClusters',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            IconButton(
                              tooltip: '下一处足迹',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => onStepCluster(1),
                              icon: const Icon(
                                Icons.chevron_right_rounded,
                                size: 20,
                              ),
                            ),
                          ],
                          if (canZoomCluster)
                            IconButton(
                              key: const ValueKey('photo-map-zoom-cluster'),
                              tooltip: '放大此区域',
                              visualDensity: VisualDensity.compact,
                              onPressed: onZoomCluster,
                              icon: const Icon(
                                Icons.zoom_in_map_rounded,
                                size: 19,
                              ),
                            ),
                          IconButton(
                            key: const ValueKey('photo-map-close-sheet'),
                            tooltip: '关闭预览',
                            visualDensity: VisualDensity.compact,
                            onPressed: onClose,
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, thickness: 0.5),
                    Flexible(
                      child: loading
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 28),
                              child: Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                              ),
                            )
                          : error != null
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Notice(
                                error!,
                                error: true,
                                onRetry: onRetry,
                              ),
                            )
                          : assets.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(18),
                              child: Text(
                                '照片可能已被移走，或当前账号没有访问权限。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.all(10),
                              shrinkWrap: true,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                  ),
                              itemCount: assets.length,
                              itemBuilder: (context, index) {
                                final asset = assets[index];
                                return _LocationPhotoGridTile(
                                  key: ValueKey('map-sheet-photo-${asset.id}'),
                                  api: api,
                                  memoryCache: memoryCache,
                                  asset: asset,
                                  onTap: () => onOpenAsset(asset, assets),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LocationPhotoGridTile extends StatelessWidget {
  const _LocationPhotoGridTile({
    required this.api,
    required this.memoryCache,
    required this.asset,
    required this.onTap,
    super.key,
  });

  final LightIsleApi api;
  final MediaImageMemoryCache memoryCache;
  final PhotoAsset asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final caption = asset.takenAt > 0
        ? formatMediaDate(asset.takenAt)
        : asset.name;

    return Tooltip(
      message: asset.name,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AuthenticatedMediaImage(
                api: api,
                path: '/api/v2/photos/${asset.id}/thumbnail',
                memoryCache: memoryCache,
                maxBytes: 2 * 1024 * 1024,
                fit: BoxFit.cover,
                loadingBuilder: (_) => ColoredBox(
                  color: scheme.surfaceContainerLow,
                  child: Center(
                    child: Icon(
                      asset.isVideo ? Icons.movie_outlined : Icons.photo_outlined,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHigh,
                  child: Center(
                    child: Icon(
                      asset.isVideo ? Icons.movie_outlined : Icons.photo_outlined,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(5, 10, 5, 4),
                    child: Row(
                      children: [
                        if (asset.isVideo) ...[
                          const Icon(
                            Icons.play_arrow_rounded,
                            size: 13,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 2),
                        ],
                        Expanded(
                          child: Text(
                            caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (asset.personalFavorite || asset.favorite)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    asset.personalFavorite
                        ? Icons.star_rounded
                        : Icons.favorite_rounded,
                    size: 14,
                    color: asset.personalFavorite
                        ? const Color(0xFFFBBF24)
                        : const Color(0xFFF43F5E),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
