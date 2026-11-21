import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'photos_batch_service.dart';
import 'photos_controller.dart';

/// Horizontal Warm Editorial story strip highlighting curated collections such
/// as "On This Day", personal stars, shared favorites, Live Photos, videos, and
/// footprint map.
class PhotosMemoriesCarousel extends StatelessWidget {
  const PhotosMemoriesCarousel({
    required this.pageInset,
    required this.onOnThisDay,
    required this.onPersonalFavorites,
    required this.onSharedFavorites,
    required this.onLivePhotos,
    required this.onVideos,
    required this.onOpenMap,
    super.key,
  });

  final double pageInset;
  final VoidCallback onOnThisDay;
  final VoidCallback onPersonalFavorites;
  final VoidCallback onSharedFavorites;
  final VoidCallback onLivePhotos;
  final VoidCallback onVideos;
  final VoidCallback onOpenMap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isBrutal =
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final isFlat =
        style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact = screenWidth < IsleLayout.compactPageWidth;
    final desktop = screenWidth >= IsleLayout.desktopRailWidth;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;

    final stories =
        <
          ({
            String keyId,
            String title,
            IconData icon,
            Color accent,
            VoidCallback onTap,
          })
        >[
          (
            keyId: 'memoryOnThisDay',
            title: '那年今日',
            icon: Icons.auto_awesome_rounded,
            accent: palette['brandViolet'],
            onTap: onOnThisDay,
          ),
          (
            keyId: 'memoryPersonalStars',
            title: '星标精选',
            icon: Icons.star_rounded,
            accent: palette['brandAmber'],
            onTap: onPersonalFavorites,
          ),
          (
            keyId: 'memorySharedHearts',
            title: '家庭佳作',
            icon: Icons.favorite_rounded,
            accent: palette['brandRose'],
            onTap: onSharedFavorites,
          ),
          (
            keyId: 'memoryLivePhotos',
            title: '实况瞬间',
            icon: Icons.motion_photos_on_rounded,
            accent: palette['brandTerracotta'],
            onTap: onLivePhotos,
          ),
          (
            keyId: 'memoryVideos',
            title: '动态影像',
            icon: Icons.play_circle_fill_rounded,
            accent: palette['brandBlue'],
            onTap: onVideos,
          ),
          (
            keyId: 'memoryMapFootprints',
            title: '足迹地图',
            icon: Icons.explore_rounded,
            accent: palette['brandSage'],
            onTap: onOpenMap,
          ),
        ];

    final cardHeight = largeText
        ? 86.0
        : desktop
        ? 68.0
        : compact
        ? 58.0
        : 64.0;
    final cardWidth = desktop
        ? 162.0
        : compact
        ? 118.0
        : 140.0;

    return Padding(
      key: const ValueKey('googlePhotosMemoriesCarousel'),
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: cardHeight,
        child: ListView.separated(
          padding: EdgeInsets.symmetric(horizontal: pageInset),
          scrollDirection: Axis.horizontal,
          itemCount: stories.length,
          separatorBuilder: (_, _) => SizedBox(width: compact ? 8 : 10),
          itemBuilder: (context, index) {
            final story = stories[index];
            final cardTop = Color.alphaBlend(
              story.accent.withValues(alpha: isDark ? 0.14 : 0.08),
              palette['cardTop'],
            );
            final cardBottom = Color.alphaBlend(
              story.accent.withValues(alpha: isDark ? 0.05 : 0.025),
              palette['cardBottom'],
            );
            final cardRadius = style.borderRadiusFor(IsleRadius.item);
            return SizedBox(
              width: cardWidth,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: ValueKey(story.keyId),
                  borderRadius: cardRadius,
                  onTap: story.onTap,
                  child: Ink(
                    decoration: BoxDecoration(
                      borderRadius: cardRadius,
                      color: isBrutal || isFlat ? cardTop : null,
                      gradient: isBrutal || isFlat
                          ? null
                          : LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [cardTop, cardBottom],
                            ),
                      border: Border.all(
                        color: isBrutal
                            ? style.rimBorderColor()
                            : story.accent.withValues(
                                alpha: isDark ? 0.32 : 0.22,
                              ),
                        width: style.effectiveBorderWidth(),
                      ),
                      boxShadow: style.subtleShadows(),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 10 : 12,
                        vertical: compact ? 8 : 10,
                      ),
                      child: Row(
                        children: [
                          IsleSquircleBadge(
                            icon: story.icon,
                            color: story.accent,
                            size: compact ? 26 : 30,
                            iconSize: compact ? 14.5 : 16,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              story.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onSurface,
                                fontSize: compact ? 12.5 : 13.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Animated multi-select action toolbar exposing select-all, favorite, album
/// organize/remove, original export, share links, and trash actions.
class PhotosSelectionActionBar extends StatelessWidget {
  const PhotosSelectionActionBar({
    required this.controller,
    required this.isAdmin,
    required this.pageInset,
    required this.onBatchFavorite,
    required this.onBatchAddToAlbum,
    required this.onBatchRemoveFromAlbum,
    required this.onBatchExport,
    required this.onBatchShare,
    required this.onBatchTrash,
    super.key,
  });

  final PhotosController controller;
  final bool isAdmin;
  final double pageInset;
  final VoidCallback onBatchFavorite;
  final VoidCallback onBatchAddToAlbum;
  final VoidCallback onBatchRemoveFromAlbum;
  final VoidCallback onBatchExport;
  final VoidCallback onBatchShare;
  final VoidCallback onBatchTrash;

  @override
  Widget build(BuildContext context) {
    final selection = controller.selection;
    final assets = controller.feed.assets;
    final selectedIds = selection.selectedAssets;
    final busy = selection.batchBusy;

    final allSelectedFavorited =
        selectedIds.isNotEmpty &&
        assets
            .where((a) => selectedIds.contains(a.id))
            .every((a) => a.personalFavorite);
    final allPageSelected = assets
        .take(PhotosBatchService.maxSelectionCount)
        .every((asset) => selectedIds.contains(asset.id));
    final canTrashSelected =
        !busy &&
        selectedIds.isNotEmpty &&
        !assets
            .where((a) => selectedIds.contains(a.id))
            .any((a) => !isAdmin && !a.canWrite);

    final compactOutlined = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    );
    final compactTonal = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    );

    return IsleAnimatedExpand(
      expanded: selection.selecting,
      child: Padding(
        padding: EdgeInsets.fromLTRB(pageInset, 0, pageInset, 10),
        child: MediaSelectionActionBar(
          label: '已选 ${selectedIds.length} 项',
          actions: [
            OutlinedButton.icon(
              style: compactOutlined,
              onPressed: busy || assets.isEmpty
                  ? null
                  : controller.batch.selectVisiblePhotos,
              icon: const Icon(Icons.select_all_rounded, size: 15),
              label: Text(allPageSelected ? '取消全选' : '全选当前页'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: busy ? null : controller.clearSelection,
              child: const Text('完成'),
            ),
            OutlinedButton.icon(
              style: compactOutlined,
              onPressed: busy || selectedIds.isEmpty ? null : onBatchFavorite,
              icon: Icon(
                allSelectedFavorited
                    ? Icons.star_outline_rounded
                    : Icons.star_border_rounded,
                size: 15,
              ),
              label: Text(allSelectedFavorited ? '取消收藏' : '收藏'),
            ),
            FilledButton.tonalIcon(
              style: compactTonal,
              onPressed: busy || selectedIds.isEmpty ? null : onBatchAddToAlbum,
              icon: const Icon(Icons.add_to_photos_outlined, size: 15),
              label: const Text('加入相册'),
            ),
            if (controller.canRemoveFromCurrentAlbum)
              OutlinedButton.icon(
                style: compactOutlined,
                onPressed: busy || selectedIds.isEmpty
                    ? null
                    : onBatchRemoveFromAlbum,
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 15),
                label: const Text('移出相册'),
              ),
            OutlinedButton.icon(
              style: compactOutlined,
              onPressed: busy || selectedIds.isEmpty ? null : onBatchExport,
              icon: const Icon(Icons.download_outlined, size: 15),
              label: const Text('保存原文件'),
            ),
            OutlinedButton.icon(
              style: compactOutlined,
              onPressed: busy || selectedIds.isEmpty ? null : onBatchShare,
              icon: const Icon(Icons.ios_share_outlined, size: 15),
              label: const Text('分享'),
            ),
            FilledButton.tonalIcon(
              style: compactTonal,
              onPressed: canTrashSelected ? onBatchTrash : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 15),
              label: const Text('移入回收站'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Consolidates media scanning, offline AI indexing, private album load error,
/// action feedback, and pagination retry status banners for [PhotosPage].
class PhotosStatusBanners extends StatelessWidget {
  const PhotosStatusBanners({
    required this.controller,
    required this.isAdmin,
    super.key,
  });

  final PhotosController controller;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final scan = controller.scan;
    final catalog = controller.catalog;
    final feed = controller.feed;
    final privateFailure = catalog.privateFailure;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scan.scanning)
          MediaStatusBanner(
            message: '正在整理媒体 · 已找到 ${scan.status.found} 项',
            icon: Icons.sync,
          ),
        PhotosAIIndexBanner(
          status: scan.status,
          isAdmin: isAdmin,
          pauseBusy: scan.aiPauseBusy,
          onTogglePause: () => unawaited(controller.toggleAIPause()),
        ),
        if (scan.scanError != null)
          MediaStatusBanner(
            message: '上次扫描未完成：${scan.scanError}',
            isError: true,
          ),
        if (privateFailure != null)
          MediaStatusBanner(
            key: const ValueKey('privateAlbumsLoadFailure'),
            message:
                '私人相册列表未能读取：${mediaErrorLabel(privateFailure)}\n'
                '其他图库内容可以继续浏览；请排除故障后重试。',
            diagnostic: errorDiagnosticLabel(privateFailure),
            isError: true,
            icon: Icons.error_outline,
            trailing: TextButton(
              onPressed: catalog.privateRefreshing
                  ? null
                  : () => unawaited(controller.albums.refreshPrivateAlbums()),
              child: Text(catalog.privateRefreshing ? '加载中' : '重试'),
            ),
          ),
        if (feed.actionMessage != null)
          MediaStatusBanner(
            message: feed.actionMessage!,
            isError: feed.actionIsError,
          ),
        if (feed.loadError != null && feed.assets.isNotEmpty)
          MediaStatusBanner(
            message: feed.loadError!,
            isError: true,
            icon: Icons.error_outline,
            trailing: TextButton(
              onPressed: feed.loadingMore
                  ? null
                  : () => unawaited(controller.loadAssets(reset: false)),
              child: const Text('重试'),
            ),
          ),
      ],
    );
  }
}

/// Progress banner displaying offline AI vision/OCR indexing status and an
/// admin pause/resume control.
class PhotosAIIndexBanner extends StatelessWidget {
  const PhotosAIIndexBanner({
    required this.status,
    required this.isAdmin,
    required this.pauseBusy,
    required this.onTogglePause,
    super.key,
  });

  static const Color _pausedAmber = Color(0xFFF59E0B);

  final MediaScanStatus status;
  final bool isAdmin;
  final bool pauseBusy;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    if (!status.aiRunning && !status.aiPaused) {
      return const SizedBox.shrink();
    }
    final remaining = status.aiRemaining;
    final total = status.aiTotal;
    final done = (total - remaining).clamp(0, total);
    final fraction = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
    final text = status.aiPaused
        ? '后台离线智能识图已暂停${remaining > 0 ? '（剩余 $remaining 张待索引）' : ''}'
        : '正在后台离线建立智能识图与 OCR 索引${remaining > 0 ? ' · 剩余 $remaining 张' : ''}';

    return MediaStatusBanner(
      message: text,
      icon: status.aiPaused
          ? Icons.pause_circle_outline_rounded
          : Icons.auto_awesome_outlined,
      leading: fraction == null
          ? null
          : IsleDonutGauge(
              fraction: fraction,
              color: status.aiPaused
                  ? _pausedAmber
                  : Theme.of(context).colorScheme.primary,
              size: 32,
              strokeWidth: 3.5,
              centerText: '${(fraction * 100).round()}%',
              centerStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              semanticsLabel:
                  '智能识图索引进度 ${(fraction * 100).round()}%（$done/$total）',
            ),
      trailing: isAdmin
          ? TextButton(
              onPressed: pauseBusy ? null : onTogglePause,
              child: Text(status.aiPaused ? '继续' : '暂停'),
            )
          : null,
    );
  }
}
