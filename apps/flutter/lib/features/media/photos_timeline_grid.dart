import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'photos_batch_service.dart';
import 'photos_controller.dart';

/// Groups chronologically sorted gallery assets into month-labeled sections.
class PhotoMonthSection {
  PhotoMonthSection(this.key, this.title) : items = <PhotoAsset>[];

  final String key;
  final String title;
  final List<PhotoAsset> items;
}

String photoAssetMonthKey(int takenAt) {
  if (takenAt <= 0) return 'unknown';
  final value = DateTime.fromMillisecondsSinceEpoch(takenAt * 1000).toLocal();
  return '${value.year}-${value.month}';
}

List<PhotoMonthSection> groupPhotoAssetsByMonth(List<PhotoAsset> assets) {
  final sections = <PhotoMonthSection>[];
  for (final asset in assets) {
    final key = photoAssetMonthKey(asset.takenAt);
    if (sections.isEmpty || sections.last.key != key) {
      sections.add(PhotoMonthSection(key, formatMediaMonth(asset.takenAt)));
    }
    sections.last.items.add(asset);
  }
  return sections;
}

/// Sliver displaying loading/error/empty states or month-grouped responsive
/// photo/video thumbnail grids.
class PhotosTimelineGridSliver extends StatelessWidget {
  const PhotosTimelineGridSliver({
    required this.api,
    required this.controller,
    required this.pageInset,
    required this.hasOtherRoots,
    required this.onRetryInitialLoad,
    required this.onBrowseAllPhotos,
    required this.onUpload,
    required this.onToggleSectionSelection,
    required this.onOpenAsset,
    required this.onToggleAssetSelection,
    super.key,
  });

  final LightIsleApi api;
  final PhotosController controller;
  final double pageInset;
  final bool hasOtherRoots;
  final VoidCallback onRetryInitialLoad;
  final VoidCallback onBrowseAllPhotos;
  final VoidCallback onUpload;
  final ValueChanged<List<PhotoAsset>> onToggleSectionSelection;
  final ValueChanged<PhotoAsset> onOpenAsset;
  final ValueChanged<PhotoAsset> onToggleAssetSelection;

  @override
  Widget build(BuildContext context) {
    final feed = controller.feed;
    if (feed.loading && feed.assets.isEmpty) {
      return const SliverToBoxAdapter(
        child: IsleLoadingState(
          padding: EdgeInsets.all(48),
          label: '正在加载时光相册…',
        ),
      );
    }
    if (feed.assets.isEmpty && feed.loadError != null) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.photo_library_outlined,
          title: '暂时无法读取图库',
          message: feed.loadError!,
          action: OutlinedButton.icon(
            onPressed: feed.loading ? null : onRetryInitialLoad,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (feed.assets.isEmpty) return _buildEmptyLibrarySliver();

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final comfortable = feed.comfortableGrid;
        final columns = _computeGridColumns(width, comfortable: comfortable);
        final gridSpacing = comfortable ? 7.0 : 2.5;
        final tileRadius = comfortable ? 11.0 : 3.0;
        final gridHorizontalInset = comfortable ? pageInset : 3.0;
        final sections = groupPhotoAssetsByMonth(feed.assets);
        final compact = width < IsleLayout.compactPageWidth;
        return SliverMainAxisGroup(
          slivers: [
            for (final section in sections) ...[
              _buildMonthHeaderSliver(
                context,
                section,
                isFirst: identical(section, sections.first),
                compact: compact,
              ),
              _buildMonthAssetGridSliver(
                section,
                columns: columns,
                gridSpacing: gridSpacing,
                tileRadius: tileRadius,
                horizontalInset: gridHorizontalInset,
              ),
            ],
          ],
        );
      },
    );
  }

  int _computeGridColumns(double width, {required bool comfortable}) {
    final baseColumns = width < 340
        ? 3
        : width < 600
        ? 4
        : width < 760
        ? 5
        : width < 960
        ? 6
        : (width / 142).floor().clamp(6, 10);
    return comfortable ? (baseColumns - 1).clamp(2, 8) : baseColumns;
  }

  Widget _buildEmptyLibrarySliver() {
    final scope = controller.scope;
    final album = controller.currentAlbum;
    final privateAlbum = controller.currentPrivateAlbum;
    final hasActiveScope =
        scope.activeFolderPath.isNotEmpty ||
        album != null ||
        privateAlbum != null ||
        scope.favoritesOnly ||
        scope.personalFavoritesOnly ||
        scope.onThisDay;
    final (title, message) = _resolveEmptyLibraryCopy(
      album: album,
      privateAlbum: privateAlbum,
    );
    return SliverToBoxAdapter(
      child: MediaEmptyState(
        icon: Icons.photo_library_outlined,
        title: title,
        message: message,
        action: hasActiveScope
            ? TextButton.icon(
                onPressed: onBrowseAllPhotos,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('浏览全部照片'),
              )
            : FilledButton.icon(
                onPressed: onUpload,
                icon: const Icon(Icons.add_rounded),
                label: const Text('上传照片与视频'),
              ),
      ),
    );
  }

  (String, String) _resolveEmptyLibraryCopy({
    required MediaAlbum? album,
    required MediaAlbum? privateAlbum,
  }) {
    final scope = controller.scope;
    if (scope.activeFolderPath.isNotEmpty) {
      return ('文件夹相册还没有媒体', '可以在文件管理中放入照片，或在照片预览中选择复制或移动到此相册。');
    }
    if (album != null) {
      return ('此相册还没有媒体', '在全部照片中打开一项媒体，选择此相册并加入。');
    }
    if (privateAlbum != null) {
      return ('私人相册还没有媒体', '此清单仅当前账号可见。打开全部照片，选择私人相册并加入媒体。');
    }
    if (scope.favoritesOnly) {
      return ('还没有共享收藏', '打开一项你有权编辑的媒体并加入共享收藏。');
    }
    if (scope.personalFavoritesOnly) {
      return ('还没有个人收藏', '预览自己有权限查看的照片，点星形图标保存到仅自己可见的收藏。');
    }
    if (scope.onThisDay) {
      return ('往年今天还没有照片', '今天拍摄的往年照片会出现在这里，试试浏览全部照片。');
    }
    if (scope.query.isNotEmpty) {
      return ('没有找到匹配的照片', '试试其他文件名，或清除搜索条件。');
    }
    if (hasOtherRoots) {
      return (
        '这里还没有照片或视频',
        '点击上传保存照片。若迁移前的照片在原存储目录（如「图库 / PhonePhotos」），原数据未丢失，可在顶部切换存储目录查看。',
      );
    }
    return ('这里还没有照片或视频', '点击上传，把设备里的照片与视频保存到 NAS。');
  }

  Widget _buildMonthHeaderSliver(
    BuildContext context,
    PhotoMonthSection section, {
    required bool isFirst,
    required bool compact,
  }) {
    final selection = controller.selection;
    final allSectionSelected = section.items
        .take(PhotosBatchService.maxSelectionCount)
        .every((item) => selection.selectedAssets.contains(item.id));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = IslePalette.of(context);

    return SliverToBoxAdapter(
      child: Padding(
        key: isFirst ? controller.timeline.firstMonthHeadingKey : null,
        padding: EdgeInsets.fromLTRB(
          pageInset,
          compact ? 12 : 18,
          pageInset,
          compact ? 6 : 9,
        ),
        child: Row(
          children: [
            Semantics(
              button: true,
              label: '全选 ${section.title}',
              child: InkWell(
                key: ValueKey('selectMonth_${section.key}'),
                borderRadius: BorderRadius.circular(20),
                onTap: selection.batchBusy
                    ? null
                    : () => onToggleSectionSelection(section.items),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(
                        allSectionSelected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: allSectionSelected
                            ? scheme.primary
                            : scheme.onSurfaceVariant.withValues(alpha: 0.62),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              width: 3,
              height: 15,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: palette['brandRose'],
              ),
            ),
            Expanded(
              child: Text(
                section.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.25,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
              decoration: IsleDecorations.recessedWell(context, radius: 999),
              child: Text(
                '${section.items.length} 项',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthAssetGridSliver(
    PhotoMonthSection section, {
    required int columns,
    required double gridSpacing,
    required double tileRadius,
    required double horizontalInset,
  }) {
    final selection = controller.selection;
    final photoCache = controller.photoCache;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: horizontalInset),
      sliver: SliverGrid.builder(
        itemCount: section.items.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gridSpacing,
          mainAxisSpacing: gridSpacing,
          childAspectRatio: 1,
        ),
        itemBuilder: (context, index) {
          final asset = section.items[index];
          return _PhotoGridTile(
            api: api,
            photoCache: photoCache,
            asset: asset,
            tileRadius: tileRadius,
            selecting: selection.selecting,
            isSelected: selection.selectedAssets.contains(asset.id),
            onOpen: () => onOpenAsset(asset),
            onToggleSelect: () => onToggleAssetSelection(asset),
          );
        },
      ),
    );
  }
}

class _PhotoGridTile extends StatelessWidget {
  const _PhotoGridTile({
    required this.api,
    required this.photoCache,
    required this.asset,
    required this.tileRadius,
    required this.selecting,
    required this.isSelected,
    required this.onOpen,
    required this.onToggleSelect,
  });

  static const int _thumbnailMaxBytes = 4 * 1024 * 1024;

  final LightIsleApi api;
  final MediaImageMemoryCache photoCache;
  final PhotoAsset asset;
  final double tileRadius;
  final bool selecting;
  final bool isSelected;
  final VoidCallback onOpen;
  final VoidCallback onToggleSelect;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label:
          '${asset.name}, ${asset.isVideo ? '视频' : '照片'}，${formatMediaDate(asset.takenAt)}${asset.personalFavorite ? '，我的收藏' : ''}${asset.favorite ? '，共享收藏' : ''}',
      child: InkWell(
        onTap: () {
          if (selecting || HardwareKeyboard.instance.isShiftPressed) {
            onToggleSelect();
            return;
          }
          onOpen();
        },
        onLongPress: onToggleSelect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(tileRadius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Hero(
                tag: 'photo_thumb_${asset.id}',
                child: _buildThumbnailSurface(context),
              ),
              if (selecting)
                _buildSelectionBadge(context)
              else if (asset.isLivePhoto)
                _buildLiveBadge(),
              if (asset.isVideo) _buildVideoBadge(),
              if (asset.favorite || asset.personalFavorite)
                _buildFavoriteBadges(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnailSurface(BuildContext context) {
    final palette = IslePalette.of(context);
    if (asset.isRaw) {
      return Container(
        color: palette['cardItemBottom'],
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined, size: 26),
              Text(
                'RAW',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      );
    }
    return AuthenticatedMediaImage(
      api: api,
      memoryCache: photoCache,
      path: '/api/v2/photos/${asset.id}/thumbnail',
      maxBytes: _thumbnailMaxBytes,
      fit: BoxFit.cover,
      loadingBuilder: (_) => Container(color: palette['cardItemBottom']),
      errorBuilder: (_, _, retry) => Container(
        color: palette['cardItemBottom'],
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Icon(
                asset.isVideo
                    ? Icons.movie_outlined
                    : Icons.image_not_supported_outlined,
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  tooltip: '重试缩略图',
                  visualDensity: VisualDensity.compact,
                  onPressed: retry,
                  icon: const Icon(Icons.refresh, size: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBadge(BuildContext context) {
    return Positioned(
      top: 5,
      left: 5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.black54,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(
            isSelected ? Icons.check_rounded : Icons.circle_outlined,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildLiveBadge() {
    return Positioned(
      top: 5,
      left: 5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.motion_photos_on_rounded,
                color: Color(0xFFF6C177),
                size: 11,
              ),
              SizedBox(width: 3),
              Text(
                'LIVE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoBadge() {
    return Positioned(
      right: 5,
      bottom: 5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 14,
              ),
              if (asset.durationSeconds > 0) ...[
                const SizedBox(width: 2),
                Text(
                  formatMediaSeconds(asset.durationSeconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFavoriteBadges() {
    return Positioned(
      top: 7,
      right: 7,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (asset.personalFavorite)
            const Icon(
              Icons.star,
              color: Color(0xFFFFD76C),
              size: 17,
              shadows: [Shadow(blurRadius: 5, color: Colors.black54)],
            ),
          if (asset.favorite && asset.personalFavorite)
            const SizedBox(width: 4),
          if (asset.favorite)
            const Icon(
              Icons.favorite,
              color: Colors.white,
              size: 18,
              shadows: [Shadow(blurRadius: 5, color: Colors.black54)],
            ),
        ],
      ),
    );
  }
}

/// Footer sliver rendering load-more control or loaded total count plus bottom
/// safe breathing room.
class PhotosPaginationFooterSliver extends StatelessWidget {
  const PhotosPaginationFooterSliver({
    required this.assetCount,
    required this.hasMore,
    required this.loadingMore,
    required this.pageInset,
    required this.onLoadMore,
    super.key,
  });

  final int assetCount;
  final bool hasMore;
  final bool loadingMore;
  final double pageInset;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        children: [
          if (assetCount > 0)
            Padding(
              padding: EdgeInsets.fromLTRB(pageInset, 16, pageInset, 22),
              child: Center(
                child: hasMore
                    ? OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: loadingMore ? null : onLoadMore,
                        icon: loadingMore
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.expand_more, size: 18),
                        label: Text(loadingMore ? '正在加载' : '加载更多媒体'),
                      )
                    : Text(
                        '已显示全部 $assetCount 项',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              ),
            ),
          const SizedBox(height: 68),
        ],
      ),
    );
  }
}
