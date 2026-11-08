import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import '../files/file_export_service.dart';
import '../files/file_share_dialog.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'offline_photo_store.dart';
import 'photo_media_view.dart';

export 'photo_media_view.dart'
    show
        PhotoMediaImage,
        PhotoMediaImageState,
        PhotoMediaVideo,
        PhotoMediaVideoState;

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
    required this.onDetails,
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
  final Future<void> Function(PhotoAsset) onDetails;
  final Future<List<PhotoAsset>> Function() onLoadMore;
  final String offlineAccountId;

  /// Files and Photos share the same full-screen media viewer, but files do
  /// not expose gallery-specific favorites, album editing or offline library.
  final bool fileBrowserMode;

  @override
  State<PhotoGalleryViewer> createState() => _PhotoGalleryViewerState();
}

class _PhotoGalleryViewerState extends State<PhotoGalleryViewer>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late MediaImageMemoryCache _imageCache;
  late bool _ownsImageCache;
  late final PageController _controller;
  late List<PhotoAsset> _items;
  late int _index;
  bool _chromeVisible = true;
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
  String? _error;

  PhotoAsset get _current => _items[_index];
  PhotoAsset? get _liveMotion => livePhotoMotionFor(_current, _items);

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  void didUpdateWidget(covariant PhotoGalleryViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api)) {
      // A changed server/account client must never display the old client's
      // photo bytes, even if the relative file path happens to match.
      if (_ownsImageCache) _imageCache.dispose();
      _imageCache = MediaImageMemoryCache();
      _ownsImageCache = true;
    }
  }

  Future<void> _mediaAction(String action) async {
    if (_busy || !mounted) return;
    final asset = _current;
    switch (action) {
      case 'shared':
        if (widget.canEditSharedFavorite(asset)) {
          await _favorite(shared: true);
        }
      case 'export':
        await _exportCurrent();
      case 'offline':
        await _saveOfflinePhoto();
      case 'live':
        _stopSlideshow();
        if (mounted) setState(() => _livePlaying = !_livePlaying);
      case 'trash':
        if (widget.onDelete == null || !widget.canEditSharedFavorite(asset)) {
          return;
        }
        final deleted = await widget.onDelete!(asset);
        if (deleted && mounted) Navigator.of(context).pop();
      case 'folder':
        final callback = widget.onFolderAlbum;
        if (callback == null) return;
        final moved = await callback(asset);
        if (moved && mounted) Navigator.of(context).pop();
    }
  }

  @override
  void initState() {
    super.initState();
    _imageCache = widget.memoryCache ?? MediaImageMemoryCache();
    _ownsImageCache = widget.memoryCache == null;
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
  }

  Future<void> _nextVideo() async {
    if (!widget.fileBrowserMode || !_continuousVideo || !mounted) return;
    final next = _items.indexWhere((asset) => asset.isVideo, _index + 1);
    if (next < 0) return;
    await _navigate(next - _index);
  }

  void _showFilePlaylist() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.68,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('当前文件夹 · 图片与视频')),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _items.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: Icon(
                      _items[index].isVideo
                          ? Icons.movie_outlined
                          : Icons.image_outlined,
                    ),
                    title: Text(
                      _items[index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: index == _index,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      unawaited(_navigate(index - _index));
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveOfflinePhoto() async {
    if (_busy || _current.isVideo || widget.offlineAccountId.isEmpty) return;
    _stopSlideshow();
    final asset = _current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('离线保存照片原件？'),
        content: Text(
          '保存“${asset.name}”到本机专属离线照片库。'
          '最多 512 MiB/张、当前离线库最多 2 GiB；照片会保留原始格式，'
          'RAW/HEIC 可能无法在本机直接预览，但可以原样导出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存原件'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = OfflinePhotoStore(
        api: widget.api,
        accountId: widget.offlineAccountId,
      );
      await store.save(asset);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('原片已保存到本机离线照片库，断网也可查看或导出。')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  Future<void> _shareCurrent() async {
    _stopSlideshow();
    final asset = _current;
    try {
      await openMediaFileShare(
        context,
        api: widget.api,
        path: asset.path,
        name: asset.name,
      );
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    }
  }

  Future<void> _exportCurrent() async {
    if (_busy) return;
    _stopSlideshow();
    final asset = _current;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await exportMediaFile(
        widget.api,
        path: asset.path,
        name: asset.name,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result)));
      }
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      unawaited(_navigate(1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      unawaited(_navigate(-1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _toggleSlideshow();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _stopSlideshow();
      unawaited(Navigator.of(context).maybePop());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    if (_ownsImageCache) _imageCache.dispose();
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

  Future<void> _loadMore() async {
    if (_loadingMore || _index < _items.length - 4) return;
    _loadingMore = true;
    try {
      final next = await widget.onLoadMore();
      if (mounted && next.length > _items.length) {
        setState(() => _items = next);
      }
    } finally {
      _loadingMore = false;
    }
  }

  void _changed(int index) {
    // A manual page swipe pauses the timer instead of unexpectedly moving on.
    if (_slideshow && !_slideAdvancing) _stopSlideshow();
    HapticFeedback.selectionClick();
    setState(() {
      _index = index;
      _error = null;
      _livePlaying = false;
    });
    _scheduleChromeHide();
    unawaited(_loadMore());
  }

  Future<void> _favorite({required bool shared}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final asset = _current;
      final updated = await (shared
          ? widget.onSharedFavorite(asset)
          : widget.onPersonalFavorite(asset));
      if (!mounted) return;
      final index = _items.indexWhere((item) => item.id == updated.id);
      if (index >= 0) setState(() => _items[index] = updated);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = _current;
    final safe = MediaQuery.paddingOf(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
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
                                onCompleted: widget.fileBrowserMode
                                    ? () => unawaited(_nextVideo())
                                    : null,
                              )
                            : PhotoMediaImage(
                                key: ValueKey('image-${item.id}'),
                                api: widget.api,
                                memoryCache: _imageCache,
                                asset: item,
                                active: index == _index,
                                allowHorizontalPageSwipe: true,
                                onSwipeDown: () =>
                                    Navigator.of(context).maybePop(),
                                onSwipeUp: widget.fileBrowserMode
                                    ? null
                                    : () {
                                        _stopSlideshow();
                                        unawaited(widget.onDetails(_current));
                                      },
                                onTap: _toggleChrome,
                                onZoomChanged: (zoomed) {
                                  if (mounted && index == _index && zoomed) {
                                    _stopSlideshow();
                                  }
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
            if (_livePlaying && _liveMotion != null && !asset.isVideo)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black,
                  child: PhotoMediaVideo(
                    key: ValueKey('live-motion-${_liveMotion!.id}'),
                    api: widget.api,
                    asset: _liveMotion!,
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
                                color: Colors.black.withValues(alpha: 0.45),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.22),
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
                                color: Colors.black.withValues(alpha: 0.45),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.22),
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
            if (_chromeVisible) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
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
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomToolbar(asset, safe.bottom),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
