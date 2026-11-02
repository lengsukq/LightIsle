import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/lightisle_api.dart';
import '../files/files_page.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'offline_photo_store.dart';

/// The media-first browsing route. Technical metadata and album management
/// remain in the separate details sheet, not over the image.
class PhotoGalleryViewer extends StatefulWidget {
  const PhotoGalleryViewer({
    super.key,
    required this.api,
    required this.assets,
    required this.initialIndex,
    required this.canEditSharedFavorite,
    required this.onSharedFavorite,
    required this.onPersonalFavorite,
    required this.onDetails,
    required this.onLoadMore,
    this.offlineAccountId = '',
  });

  final LightIsleApi api;
  final List<PhotoAsset> assets;
  final int initialIndex;
  final bool Function(PhotoAsset) canEditSharedFavorite;
  final Future<PhotoAsset> Function(PhotoAsset) onSharedFavorite;
  final Future<PhotoAsset> Function(PhotoAsset) onPersonalFavorite;
  final Future<void> Function(PhotoAsset) onDetails;
  final Future<List<PhotoAsset>> Function() onLoadMore;
  final String offlineAccountId;

  @override
  State<PhotoGalleryViewer> createState() => _PhotoGalleryViewerState();
}

class _PhotoGalleryViewerState extends State<PhotoGalleryViewer>
    with WidgetsBindingObserver {
  late final PageController _controller;
  late List<PhotoAsset> _items;
  late int _index;
  bool _chromeVisible = true;
  bool _busy = false;
  bool _loadingMore = false;
  Timer? _slideTimer;
  Timer? _chromeTimer;
  bool _slideshow = false;
  bool _slideAdvancing = false;
  bool _loop = false;
  int _slideSeconds = 5;
  bool _zoomed = false;
  String? _error;

  PhotoAsset get _current => _items[_index];
  PhotoAsset? get _liveMotion => livePhotoMotionFor(_current, _items);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _items = List.of(widget.assets);
    _index = widget.initialIndex.clamp(0, _items.length - 1);
    _controller = PageController(initialPage: _index);
    _scheduleChromeHide();
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
    _slideTimer?.cancel();
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
    _slideTimer?.cancel();
    _slideTimer = null;
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
    _slideTimer?.cancel();
    if (!_slideshow || !mounted) return;
    _slideTimer = Timer(Duration(seconds: _slideSeconds), () {
      unawaited(_advanceSlide());
    });
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
      _zoomed = false;
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
              child: PageView.builder(
                controller: _controller,
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: _items.length,
                onPageChanged: _changed,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return RepaintBoundary(
                    child: item.isVideo
                        ? _GalleryVideo(
                            key: ValueKey('video-${item.id}'),
                            api: widget.api,
                            asset: item,
                            active: index == _index,
                          )
                        : _GalleryImage(
                            key: ValueKey('image-${item.id}'),
                            api: widget.api,
                            asset: item,
                            onTap: _toggleChrome,
                            onZoomChanged: (zoomed) {
                              if (mounted && _zoomed != zoomed) {
                                if (zoomed) _stopSlideshow();
                                setState(() => _zoomed = zoomed);
                              }
                            },
                          ),
                  );
                },
              ),
            ),
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
                      colors: [Color(0xCC000000), Colors.transparent],
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(8, safe.top + 4, 16, 24),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '返回图库',
                          onPressed: () => Navigator.of(context).pop(),
                          color: Colors.white,
                          icon: const Icon(Icons.arrow_back_ios_new_rounded),
                        ),
                        IconButton(
                          tooltip: _slideshow ? '暂停幻灯片' : '播放幻灯片',
                          onPressed: _toggleSlideshow,
                          color: Colors.white,
                          icon: Icon(
                            _slideshow
                                ? Icons.pause_circle_outline
                                : Icons.slideshow_outlined,
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '幻灯片设置',
                          icon: const Icon(Icons.tune, color: Colors.white),
                          onSelected: (value) {
                            if (value == 'loop') {
                              setState(() => _loop = !_loop);
                            } else {
                              setState(() => _slideSeconds = int.parse(value));
                            }
                            _scheduleSlide();
                          },
                          itemBuilder: (_) => [
                            for (final seconds in [3, 5, 10])
                              CheckedPopupMenuItem<String>(
                                value: '$seconds',
                                checked: _slideSeconds == seconds,
                                child: Text('每 $seconds 秒切换'),
                              ),
                            CheckedPopupMenuItem<String>(
                              value: 'loop',
                              checked: _loop,
                              child: const Text('循环播放'),
                            ),
                            const PopupMenuItem<String>(
                              enabled: false,
                              child: Text('幻灯片自动跳过视频'),
                            ),
                          ],
                        ),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                formatMediaDate(asset.takenAt),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                '${_index + 1} / ${_items.length}',
                                style: const TextStyle(
                                  color: Color(0xCCFFFFFF),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
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
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xDD000000)],
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(14, 32, 14, safe.bottom + 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_error != null)
                          Text(
                            _error!,
                            style: const TextStyle(color: Color(0xffffb4ab)),
                          ),
                        Text(
                          asset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xCCFFFFFF),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          alignment: WrapAlignment.spaceEvenly,
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            IconButton(
                              tooltip: asset.personalFavorite
                                  ? '从我的收藏移除'
                                  : '加入我的收藏',
                              onPressed: _busy
                                  ? null
                                  : () => _favorite(shared: false),
                              color: asset.personalFavorite
                                  ? const Color(0xffffd568)
                                  : Colors.white,
                              icon: Icon(
                                asset.personalFavorite
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                              ),
                            ),
                            if (widget.canEditSharedFavorite(asset))
                              IconButton(
                                tooltip: asset.favorite ? '取消收藏' : '加入共享收藏',
                                onPressed: _busy
                                    ? null
                                    : () => _favorite(shared: true),
                                color: asset.favorite
                                    ? const Color(0xffff8195)
                                    : Colors.white,
                                icon: Icon(
                                  asset.favorite
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                ),
                              ),
                            IconButton(
                              tooltip: '照片信息与相册管理',
                              onPressed: _busy
                                  ? null
                                  : () {
                                      _stopSlideshow();
                                      unawaited(widget.onDetails(_current));
                                    },
                              color: Colors.white,
                              icon: const Icon(Icons.info_outline_rounded),
                            ),
                            IconButton(
                              tooltip: '分享媒体',
                              onPressed: _busy ? null : _shareCurrent,
                              color: Colors.white,
                              icon: const Icon(Icons.ios_share_outlined),
                            ),
                            IconButton(
                              tooltip: '保存原文件',
                              onPressed: _busy ? null : _exportCurrent,
                              color: Colors.white,
                              icon: const Icon(Icons.download_outlined),
                            ),
                            if (_liveMotion != null)
                              IconButton(
                                tooltip: '播放 Live Photo 动态片段',
                                onPressed: _busy
                                    ? null
                                    : () => _navigate(
                                        _items.indexOf(_liveMotion!) - _index,
                                      ),
                                color: Colors.white,
                                icon: const Icon(
                                  Icons.motion_photos_on_outlined,
                                ),
                              ),
                            if (!asset.isVideo &&
                                widget.offlineAccountId.isNotEmpty)
                              IconButton(
                                tooltip: '离线保存照片原件',
                                onPressed: _busy ? null : _saveOfflinePhoto,
                                color: Colors.white,
                                icon: const Icon(Icons.offline_pin_outlined),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GalleryImage extends StatefulWidget {
  const _GalleryImage({
    super.key,
    required this.api,
    required this.asset,
    required this.onTap,
    required this.onZoomChanged,
  });
  final LightIsleApi api;
  final PhotoAsset asset;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_GalleryImage> createState() => _GalleryImageState();
}

class _GalleryImageState extends State<_GalleryImage> {
  final TransformationController _zoom = TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _doubleTap() {
    setState(() {
      _zoomed = !_zoomed;
      _zoom.value = Matrix4.identity()
        ..scaleByDouble(_zoomed ? 2.5 : 1, _zoomed ? 2.5 : 1, 1, 1);
    });
    widget.onZoomChanged(_zoomed);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    onDoubleTap: _doubleTap,
    child: ColoredBox(
      color: Colors.black,
      child: Center(
        child: InteractiveViewer(
          transformationController: _zoom,
          minScale: 1,
          maxScale: 5,
          panEnabled: _zoomed,
          onInteractionUpdate: (_) {
            final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
            if (_zoomed != zoomed) {
              setState(() => _zoomed = zoomed);
              widget.onZoomChanged(zoomed);
            }
          },
          child: widget.asset.isRaw
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'RAW 原始照片已安全保存在 NAS。'
                      '当前不提供未经验证的 RAW 解码；可点击下方“保存原文件”'
                      '或“离线保存照片原件”，使用专业软件编辑原始数据。',
                      style: TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : AuthenticatedMediaImage(
                  api: widget.api,
                  path: '/api/v2/files/thumbnail',
                  query: {'path': widget.asset.path, 'size': '2048'},
                  maxBytes: 12 * 1024 * 1024,
                  fit: BoxFit.contain,
                  loadingBuilder: (_) => const Center(
                    child: CircularProgressIndicator(
                      color: Colors.white70,
                      strokeWidth: 2,
                    ),
                  ),
                  errorBuilder: (context, error, retry) => Center(
                    child: TextButton.icon(
                      onPressed: retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试加载照片'),
                    ),
                  ),
                ),
        ),
      ),
    ),
  );
}

class _GalleryVideo extends StatefulWidget {
  const _GalleryVideo({
    super.key,
    required this.api,
    required this.asset,
    required this.active,
  });
  final LightIsleApi api;
  final PhotoAsset asset;
  final bool active;

  @override
  State<_GalleryVideo> createState() => _GalleryVideoState();
}

class _GalleryVideoState extends State<_GalleryVideo>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  Object? _error;
  bool _preparing = false;
  int _generation = 0;
  double _speed = 1.0;
  bool _wasPlaying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) unawaited(_prepare());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_player?.pause());
    }
  }

  void _playerChanged() {
    final playing = _player?.value.isPlaying ?? false;
    if (mounted && _wasPlaying != playing) {
      _wasPlaying = playing;
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _GalleryVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) {
      unawaited(_player?.pause());
    } else if (widget.active && !oldWidget.active && _player == null) {
      unawaited(_prepare());
    }
  }

  Future<void> _prepare() async {
    if (_preparing) return;
    _preparing = true;
    final generation = ++_generation;
    try {
      final uri = await widget.api.mediaUri(
        '/api/v2/files/preview',
        query: {'path': widget.asset.path},
      );
      if (!mounted || !widget.active || generation != _generation) return;
      final player = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      _player = player;
      await player.initialize();
      if (!mounted || generation != _generation) {
        await player.dispose();
        return;
      }
      player.addListener(_playerChanged);
      await player.setPlaybackSpeed(_speed);
      if (!widget.active) await player.pause();
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      _preparing = false;
    }
  }

  Future<void> _retry() async {
    _generation++;
    final old = _player;
    _player = null;
    old?.removeListener(_playerChanged);
    if (old != null) await old.dispose();
    if (!mounted) return;
    setState(() => _error = null);
    await _prepare();
  }

  Future<void> _seekSeconds(int seconds) async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    final millis = (player.value.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.value.duration.inMilliseconds)
        .toInt();
    try {
      await player.seekTo(Duration(milliseconds: millis));
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _setSpeed(double value) async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    try {
      await player.setPlaybackSpeed(value);
      if (mounted) setState(() => _speed = value);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _player?.removeListener(_playerChanged);
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mediaErrorLabel(_error!),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            TextButton.icon(
              onPressed: _preparing ? null : _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试播放'),
            ),
          ],
        ),
      );
    }
    if (player == null || !player.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: player.value.aspectRatio,
            child: VideoPlayer(player),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                IconButton(
                  tooltip: player.value.isPlaying ? '暂停视频' : '播放视频',
                  color: Colors.white,
                  onPressed: () async {
                    if (player.value.isPlaying) {
                      await player.pause();
                    } else {
                      await player.play();
                    }
                    if (mounted) setState(() {});
                  },
                  icon: Icon(
                    player.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                IconButton(
                  tooltip: '快退 10 秒',
                  color: Colors.white,
                  onPressed: () => _seekSeconds(-10),
                  icon: const Icon(Icons.replay_10),
                ),
                SizedBox(
                  width: 150,
                  child: VideoProgressIndicator(
                    player,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Colors.white,
                      bufferedColor: Colors.white54,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '快进 10 秒',
                  color: Colors.white,
                  onPressed: () => _seekSeconds(10),
                  icon: const Icon(Icons.forward_10),
                ),
                DropdownButton<double>(
                  value: _speed,
                  dropdownColor: const Color(0xff202124),
                  style: const TextStyle(color: Colors.white),
                  underline: const SizedBox.shrink(),
                  iconEnabledColor: Colors.white,
                  onChanged: (value) {
                    if (value != null) unawaited(_setSpeed(value));
                  },
                  items: [
                    for (final speed in [0.75, 1.0, 1.25, 1.5, 2.0])
                      DropdownMenuItem(value: speed, child: Text('${speed}x')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
