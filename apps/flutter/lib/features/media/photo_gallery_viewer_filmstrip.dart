import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import 'media_models.dart';

/// Synchronized bottom thumbnail strip rendered inside [PhotoGalleryViewer]'s
/// overlay chrome so users can scrub across nearby photos at a glance.
class PhotoGalleryViewerFilmstrip extends StatefulWidget {
  const PhotoGalleryViewerFilmstrip({
    super.key,
    required this.api,
    required this.memoryCache,
    required this.items,
    required this.currentIndex,
    required this.onSelectIndex,
    this.fileBrowserMode = false,
  });

  final LightIsleApi api;
  final MediaImageMemoryCache memoryCache;
  final List<PhotoAsset> items;
  final int currentIndex;
  final ValueChanged<int> onSelectIndex;
  final bool fileBrowserMode;

  @override
  State<PhotoGalleryViewerFilmstrip> createState() =>
      _PhotoGalleryViewerFilmstripState();
}

class _PhotoGalleryViewerFilmstripState
    extends State<PhotoGalleryViewerFilmstrip> {
  static const double _tileWidth = 48;
  static const double _tileGap = 6;
  static const double _stripPadding = 12;

  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActive(jump: true);
    });
  }

  @override
  void didUpdateWidget(covariant PhotoGalleryViewerFilmstrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex ||
        oldWidget.items.length != widget.items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActive(jump: false);
      });
    }
  }

  void _scrollToActive({required bool jump}) {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasViewportDimension) return;
    final stride = _tileWidth + _tileGap;
    final targetCenter =
        _stripPadding + widget.currentIndex * stride + _tileWidth / 2;
    final offset = (targetCenter - position.viewportDimension / 2).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if (jump || IsleMotion.reducedMotion(context)) {
      _scrollController.jumpTo(offset);
      return;
    }
    _scrollController.animateTo(
      offset,
      duration: IsleMotion.fast,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      key: const Key('photoGalleryFilmstrip'),
      height: 56,
      child: ListView.separated(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _stripPadding),
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: _tileGap),
        itemBuilder: (context, index) {
          final item = widget.items[index];
          final active = index == widget.currentIndex;
          return RepaintBoundary(
            child: GestureDetector(
              onTap: () => widget.onSelectIndex(index),
              child: AnimatedContainer(
                duration: IsleMotion.reducedMotion(context)
                    ? Duration.zero
                    : IsleMotion.fast,
                curve: Curves.easeOutCubic,
                width: _tileWidth,
                height: active ? 52 : 44,
                margin: EdgeInsets.symmetric(vertical: active ? 2 : 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: active
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.22),
                    width: active ? 2 : 0.8,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Opacity(
                      opacity: active ? 1.0 : 0.72,
                      child: _buildFilmstripTileMedia(item),
                    ),
                    if (item.isVideo)
                      const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.play_circle_filled_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      )
                    else if (item.isLivePhoto)
                      const Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(
                            Icons.motion_photos_on_rounded,
                            size: 12,
                            color: Color(0xFF9CDCF5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilmstripTileMedia(PhotoAsset item) {
    final useGalleryThumb = !widget.fileBrowserMode && item.id > 0;
    if (useGalleryThumb && item.isRaw) {
      return const ColoredBox(
        color: Color(0xFF1D2430),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 16,
                color: Colors.white70,
              ),
              Text(
                'RAW',
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return AuthenticatedMediaImage(
      api: widget.api,
      memoryCache: widget.memoryCache,
      path: useGalleryThumb
          ? '/api/v2/photos/${item.id}/thumbnail'
          : '/api/v2/files/thumbnail',
      query: useGalleryThumb ? null : {'path': item.path, 'size': '512'},
      maxBytes: 2 * 1024 * 1024,
      fit: BoxFit.cover,
      loadingBuilder: (_) => const ColoredBox(color: Color(0xFF1D2430)),
      errorBuilder: (_, _, _) => const ColoredBox(
        color: Color(0xFF1D2430),
        child: Icon(Icons.image_outlined, size: 16, color: Colors.white54),
      ),
    );
  }
}
