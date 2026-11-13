import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_cache_manager.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import '../files/file_export_service.dart';
import '../files/file_share_dialog.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'offline_photo_store.dart';
import 'photo_exif_panel.dart';
import 'photo_gallery_viewer_filmstrip.dart';
import 'photo_media_view.dart';

export 'photo_media_view.dart'
    show
        PhotoMediaImage,
        PhotoMediaImageState,
        PhotoMediaVideo,
        PhotoMediaVideoState;

part 'photo_gallery_viewer_actions.dart';
part 'photo_gallery_viewer_chrome.dart';

/// The media-first browsing route. Technical metadata and album management
/// remain in the separate details sheet, not over the image.

class PhotoGalleryViewer extends StatefulWidget {
  const PhotoGalleryViewer({
    super.key,
    required this.api,
    this.memoryCache,
    required this.assets,
    required this.initialIndex,
    required this.canEditSharedFavorite,
    required this.onSharedFavorite,
    required this.onPersonalFavorite,
    this.onDelete,
    this.onFolderAlbum,
    this.onRemoveFromCurrentAlbum,
    this.currentAlbumName = '',
    required this.onDetails,
    this.onSyncAsset,
    required this.onLoadMore,
    this.offlineAccountId = '',
    this.fileBrowserMode = false,
  });

  final LightIsleApi api;
  final MediaImageMemoryCache? memoryCache;
  final List<PhotoAsset> assets;
  final int initialIndex;
  final bool Function(PhotoAsset) canEditSharedFavorite;
  final Future<PhotoAsset> Function(PhotoAsset) onSharedFavorite;
  final Future<PhotoAsset> Function(PhotoAsset) onPersonalFavorite;

  /// Optional original-file trash action; absent in read-only/file-browser mode.
  final Future<bool> Function(PhotoAsset)? onDelete;
  final Future<bool> Function(PhotoAsset)? onFolderAlbum;
  final Future<bool> Function(PhotoAsset)? onRemoveFromCurrentAlbum;
  final String currentAlbumName;
  final Future<void> Function(PhotoAsset) onDetails;
  final PhotoAsset? Function(int id)? onSyncAsset;
  final Future<List<PhotoAsset>> Function() onLoadMore;
  final String offlineAccountId;

  /// Files and Photos share the same full-screen media viewer, but files do
  /// not expose gallery-specific favorites, album editing or offline library.
  final bool fileBrowserMode;

  static Route<void> route(WidgetBuilder builder) => PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      child: child,
    ),
  );

  @override
  State<PhotoGalleryViewer> createState() => _PhotoGalleryViewerState();
}

class _PhotoGalleryViewerState extends State<PhotoGalleryViewer>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late MediaImageMemoryCache _imageCache;
  final MediaImageMemoryCache _originalCache =
      IsleCacheManager.instance.sharedOriginals;
  late final PageController _controller;
  late List<PhotoAsset> _items;
  late int _index;
  bool _chromeVisible = true;
  double _dismissDragProgress = 0.0;
  bool _busy = false;
  bool _loadingMore = false;
  late final AnimationController _slideProgress;
  Timer? _chromeTimer;
  bool _slideshow = false;
  bool _slideAdvancing = false;
  bool _loop = false;
  int _slideSeconds = 5;
  bool _livePlaying = false;
  bool _continuousVideo = true;
  bool _currentZoomed = false;
  bool _showInfoSidebar = false;
  int _resetZoomNonce = 0;
  final Set<int> _removedIds = <int>{};
  String? _error;

  PhotoAsset get _current => _items[_index];
  PhotoAsset? get _liveMotion => livePhotoMotionFor(_current, _items);
  bool get _hasLiveMotion => _current.isLivePhoto || _liveMotion != null;

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  void didUpdateWidget(covariant PhotoGalleryViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api)) {
      _imageCache =
          widget.memoryCache ?? IsleCacheManager.instance.sharedThumbnails;
    }
  }

  @override
  void initState() {
    super.initState();
    _imageCache =
        widget.memoryCache ?? IsleCacheManager.instance.sharedThumbnails;
    WidgetsBinding.instance.addObserver(this);
    _slideProgress =
        AnimationController(
          vsync: this,
          duration: Duration(seconds: _slideSeconds),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && _slideshow) {
            unawaited(_advanceSlide());
          }
        });
    _items = List.of(widget.assets);
    _index = widget.initialIndex.clamp(0, _items.length - 1);
    _controller = PageController(initialPage: _index);
    _scheduleChromeHide();
    unawaited(_loadMore(forceCheck: true));
  }

  void _scheduleChromeHide() {
    _chromeTimer?.cancel();
    if (!_chromeVisible || _current.isVideo || _slideshow) return;
    _chromeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _chromeVisible && !_current.isVideo) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    _scheduleChromeHide();
  }

  double _horizontalScrollAccumulator = 0;
  DateTime _lastScrollNavigate = DateTime.fromMillisecondsSinceEpoch(0);

  void _handleHorizontalScroll(double deltaDx) {
    if (_busy || _slideAdvancing) return;
    final now = DateTime.now();
    if (now.difference(_lastScrollNavigate).inMilliseconds < 320) return;

    _horizontalScrollAccumulator += deltaDx;
    if (_horizontalScrollAccumulator <= -32) {
      _horizontalScrollAccumulator = 0;
      _lastScrollNavigate = now;
      unawaited(_navigate(1));
    } else if (_horizontalScrollAccumulator >= 32) {
      _horizontalScrollAccumulator = 0;
      _lastScrollNavigate = now;
      unawaited(_navigate(-1));
    }
  }

  Future<void> _navigate(int delta) async {
    final target = _index + delta;
    if (target < 0 || target >= _items.length) return;
    _stopSlideshow();
    await _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _slideProgress.dispose();
    _chromeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopSlideshow();
  }

  void _stopSlideshow() {
    _slideProgress.stop();
    _slideProgress.reset();
    if (_slideshow && mounted) {
      setState(() => _slideshow = false);
      _scheduleChromeHide();
    }
  }

  void _toggleSlideshow() {
    if (_slideshow) {
      _stopSlideshow();
    } else {
      _chromeTimer?.cancel();
      setState(() => _slideshow = true);
      _scheduleSlide();
    }
  }

  void _scheduleSlide() {
    if (!_slideshow || !mounted) return;
    // This controller is both the timer and the visible countdown. Keeping
    // one clock prevents the ring drifting from the actual next slide.
    _slideProgress.duration = Duration(seconds: _slideSeconds);
    _slideProgress.forward(from: 0);
  }

  Future<void> _advanceSlide() async {
    if (!_slideshow || !mounted || _slideAdvancing) return;
    // Videos are skipped in the photo slideshow; they remain playable when
    // opened normally. The user never has to wait for an unknown video length.
    var next = _index + 1;
    if (next >= _items.length) {
      await _loadMore();
      if (!mounted || !_slideshow) return;
    }
    // Scan at most one cycle to avoid infinite loops in video-only albums.
    var inspected = 0;
    while (inspected < _items.length) {
      if (next >= _items.length) {
        if (!_loop) break;
        next = 0;
      }
      if (!_items[next].isVideo) break;
      next++;
      inspected++;
    }
    if (next >= _items.length || inspected >= _items.length) {
      _stopSlideshow();
      return;
    }
    _slideAdvancing = true;
    try {
      await _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } finally {
      _slideAdvancing = false;
    }
    if (mounted && _slideshow) _scheduleSlide();
  }

  void _changed(int index) {
    // A manual page swipe pauses the timer instead of unexpectedly moving on.
    if (_slideshow && !_slideAdvancing) _stopSlideshow();
    HapticFeedback.selectionClick();
    setState(() {
      _index = index;
      _dismissDragProgress = 0.0;
      _error = null;
      _livePlaying = false;
      _currentZoomed = false;
    });
    _scheduleChromeHide();
    unawaited(_loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final asset = _current;
    final safe = MediaQuery.paddingOf(context);
    final disableAnimations = IsleMotion.reducedMotion(context);
    final chromeDuration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final backdropAlpha = (1.0 - _dismissDragProgress * 0.62).clamp(0.22, 1.0);
    final wideSidebar =
        !widget.fileBrowserMode &&
        _showInfoSidebar &&
        MediaQuery.sizeOf(context).width >= 840;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: backdropAlpha),
        body: Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: {
                          PointerDeviceKind.touch,
                          PointerDeviceKind.mouse,
                          PointerDeviceKind.trackpad,
                          PointerDeviceKind.stylus,
                          PointerDeviceKind.unknown,
                        },
                      ),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerPanZoomUpdate: (event) {
                          _handleHorizontalScroll(event.panDelta.dx);
                        },
                        onPointerSignal: (event) {
                          if (event is PointerScrollEvent) {
                            if (event.scrollDelta.dx != 0) {
                              _handleHorizontalScroll(-event.scrollDelta.dx);
                            }
                          }
                        },
                        child: PageView.builder(
                          controller: _controller,
                          physics: const PageScrollPhysics(),
                          itemCount: _items.length,
                          onPageChanged: _changed,
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            return RepaintBoundary(
                              child: item.isVideo
                                  ? PhotoMediaVideo(
                                      key: ValueKey('video-${item.id}'),
                                      api: widget.api,
                                      asset: item,
                                      active: index == _index,
                                      autoPlay: widget.fileBrowserMode,
                                      fileBrowserMode: widget.fileBrowserMode,
                                      onCompleted: widget.fileBrowserMode
                                          ? () => unawaited(_nextVideo())
                                          : null,
                                    )
                                  : PhotoMediaImage(
                                      key: ValueKey('image-${item.id}'),
                                      api: widget.api,
                                      memoryCache: _imageCache,
                                      originalMemoryCache: _originalCache,
                                      asset: item,
                                      active: index == _index,
                                      resetZoomNonce: _resetZoomNonce,
                                      allowHorizontalPageSwipe: true,
                                      onSwipeDown: () =>
                                          Navigator.of(context).maybePop(),
                                      onSwipeUp: widget.fileBrowserMode
                                          ? null
                                          : () {
                                              _stopSlideshow();
                                              unawaited(
                                                _openFullDetailsAndSync(),
                                              );
                                            },
                                      onTap: _toggleChrome,
                                      onDragProgressChanged: (progress) {
                                        if (mounted &&
                                            index == _index &&
                                            (progress - _dismissDragProgress)
                                                    .abs() >
                                                0.01) {
                                          setState(
                                            () =>
                                                _dismissDragProgress = progress,
                                          );
                                        }
                                      },
                                      onZoomChanged: (zoomed) {
                                        if (!mounted || index != _index) return;
                                        setState(() => _currentZoomed = zoomed);
                                        if (zoomed) _stopSlideshow();
                                      },
                                    ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  // A Live Photo plays the companion MOV over its own still frame,
                  // then returns to that still. It never navigates to a second
                  // gallery item or changes the active photo index/favourites.
                  if (_livePlaying && _hasLiveMotion && !asset.isVideo)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black,
                        child: PhotoMediaVideo(
                          key: ValueKey(
                            'live-motion-${_liveMotion?.id ?? asset.liveVideoAssetId}',
                          ),
                          api: widget.api,
                          asset: _liveMotion ?? asset,
                          streamPathOverride: asset.isLivePhoto
                              ? '/api/v2/photos/${asset.id}/live-video'
                              : null,
                          active: true,
                          autoPlay: true,
                          liveMode: true,
                          onCompleted: () {
                            if (mounted) setState(() => _livePlaying = false);
                          },
                        ),
                      ),
                    ),
                  if (_chromeVisible &&
                      (defaultTargetPlatform == TargetPlatform.macOS ||
                          defaultTargetPlatform == TargetPlatform.windows ||
                          defaultTargetPlatform == TargetPlatform.linux ||
                          MediaQuery.sizeOf(context).width >= 600)) ...[
                    if (_index > 0)
                      Positioned(
                        left: 20,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: ClipOval(
                            child: IsleGlassBackdrop(
                              blur: 16,
                              child: Material(
                                color: Colors.transparent,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => unawaited(_navigate(-1)),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.black.withValues(
                                        alpha: 0.45,
                                      ),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.22,
                                        ),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.chevron_left_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_index < _items.length - 1)
                      Positioned(
                        right: 20,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: ClipOval(
                            child: IsleGlassBackdrop(
                              blur: 16,
                              child: Material(
                                color: Colors.transparent,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => unawaited(_navigate(1)),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.black.withValues(
                                        alpha: 0.45,
                                      ),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.22,
                                        ),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.chevron_right_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: !_chromeVisible,
                      child: AnimatedOpacity(
                        opacity: _chromeVisible ? 1.0 : 0.0,
                        duration: chromeDuration,
                        curve: Curves.easeOutCubic,
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xB5000000), Colors.transparent],
                            ),
                          ),
                          child: _buildModernHeader(asset, safe.top),
                        ),
                      ),
                    ),
                  ),
                  if (!asset.isVideo)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        ignoring: !_chromeVisible,
                        child: AnimatedOpacity(
                          opacity: _chromeVisible ? 1.0 : 0.0,
                          duration: chromeDuration,
                          curve: Curves.easeOutCubic,
                          child: _buildBottomToolbar(
                            context,
                            asset,
                            safe.bottom,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (wideSidebar)
              PhotoViewerInfoSidebar(
                asset: asset,
                onClose: () => setState(() => _showInfoSidebar = false),
                onOpenFullDetails: () => unawaited(_openFullDetailsAndSync()),
              ),
          ],
        ),
      ),
    );
  }
}
