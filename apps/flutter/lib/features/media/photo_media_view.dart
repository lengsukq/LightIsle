import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'photo_viewer_quality.dart';
import 'photo_zoom_surface.dart';
import 'subtitle_import.dart';

/// Computes a safe RGBA decode cap (`<= 4096px`) for full-screen viewers so
/// 50MP originals stay crystal clear at 2x pinch-zoom without allocating
/// 200+ MiB uncompressed bitmaps.
int computeViewerDecodeCap(BuildContext context) {
  final mq = MediaQuery.of(context);
  final maxViewportSide = math.max(mq.size.width, mq.size.height);
  final target = (maxViewportSide * mq.devicePixelRatio * 2.0).round();
  return math.min(4096, target).clamp(256, 4096);
}

class PhotoMediaImage extends StatefulWidget {
  const PhotoMediaImage({
    super.key,
    required this.api,
    this.memoryCache,
    this.originalMemoryCache,
    required this.asset,
    required this.onTap,
    required this.onZoomChanged,
    this.active = true,
    this.allowHorizontalPageSwipe = false,
    this.onSwipeDown,
    this.onSwipeUp,
  });
  final LightIsleApi api;
  final MediaImageMemoryCache? memoryCache;
  final MediaImageMemoryCache? originalMemoryCache;
  final PhotoAsset asset;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;
  final bool active;
  final bool allowHorizontalPageSwipe;
  final VoidCallback? onSwipeDown;
  final VoidCallback? onSwipeUp;

  @override
  State<PhotoMediaImage> createState() => PhotoMediaImageState();
}

class PhotoMediaImageState extends State<PhotoMediaImage> {
  // Always attempt the real JPEG/PNG/WebP/GIF on the active page. A separate
  // low-resolution layer remains visible while the full-quality bytes load;
  // once the original frame paints, the underlying 2048px preview unmounts.
  bool _loadOriginal = true;
  bool _originalPainted = false;

  bool get _canLoadOriginal => photoViewerCanOpenOriginal(widget.asset);
  // PageView also builds neighbouring images for smooth swipes. Only decode
  // the active page at full resolution; adjacent pages stay on bounded
  // previews until the user navigates to them.
  bool get _showOriginal => widget.active && _canLoadOriginal && _loadOriginal;

  MediaImageMemoryCache get _previewCache =>
      widget.memoryCache ?? IsleCacheManager.instance.sharedThumbnails;

  MediaImageMemoryCache get _originalCache =>
      widget.originalMemoryCache ?? IsleCacheManager.instance.sharedOriginals;

  @override
  void didUpdateWidget(covariant PhotoMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.asset.path != widget.asset.path ||
        oldWidget.api != widget.api) {
      _loadOriginal = true;
      _originalPainted = false;
    } else if (!_showOriginal && _originalPainted) {
      _originalPainted = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final decodeCap = computeViewerDecodeCap(context);
    final previewCap = math.min(2048, decodeCap);
    final portrait =
        widget.asset.width > 0 && widget.asset.height > widget.asset.width;

    return ColoredBox(
      color: Colors.black,
      child: PhotoZoomSurface(
        aspectRatio: widget.asset.displayAspectRatio,
        active: widget.active,
        allowHorizontalPageSwipe: widget.allowHorizontalPageSwipe,
        onSwipeDown: widget.onSwipeDown,
        onSwipeUp: widget.onSwipeUp,
        onTap: widget.onTap,
        onZoomChanged: (zoomed) {
          widget.onZoomChanged(zoomed);
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
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (!(_showOriginal && _originalPainted))
                    AuthenticatedMediaImage(
                      key: ValueKey(
                        'img-${widget.asset.id}-${widget.asset.path}-prev',
                      ),
                      api: widget.api,
                      memoryCache: _previewCache,
                      path: '/api/v2/files/thumbnail',
                      query: {'path': widget.asset.path, 'size': '2048'},
                      maxBytes: 8 * 1024 * 1024,
                      cacheWidthOverride: portrait ? null : previewCap,
                      cacheHeightOverride: portrait ? previewCap : null,
                      highQualityFilter: true,
                      fit: BoxFit.contain,
                      loadingBuilder: (_) => const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              color: Colors.white70,
                              strokeWidth: 2,
                            ),
                            SizedBox(height: 12),
                            Text(
                              '正在加载照片预览…',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      errorBuilder: (context, error, retry) => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '照片加载失败',
                              style: TextStyle(color: Colors.white70),
                            ),
                            TextButton.icon(
                              onPressed: retry,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试加载照片'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_showOriginal)
                    AuthenticatedMediaImage(
                      key: ValueKey(
                        'img-${widget.asset.id}-${widget.asset.path}-orig',
                      ),
                      api: widget.api,
                      memoryCache: _originalCache,
                      path: '/api/v2/files/preview',
                      query: {'path': widget.asset.path},
                      maxBytes: photoViewerOriginalMaxBytes,
                      cacheWidthOverride: portrait ? null : decodeCap,
                      cacheHeightOverride: portrait ? decodeCap : null,
                      highQualityFilter: true,
                      fit: BoxFit.contain,
                      frameBuilder:
                          (context, child, frame, wasSynchronouslyLoaded) {
                            if (frame != null && !_originalPainted) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted &&
                                    _showOriginal &&
                                    !_originalPainted) {
                                  setState(() => _originalPainted = true);
                                }
                              });
                            }
                            return child;
                          },
                      // Transparent during loading: the preview above is never
                      // replaced by a spinner or an opaque black placeholder.
                      loadingBuilder: (_) => const SizedBox.shrink(),
                      errorBuilder: (_, error, retry) {
                        if (_originalPainted) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && _originalPainted) {
                              setState(() => _originalPainted = false);
                            }
                          });
                        }
                        return Align(
                          alignment: Alignment.topCenter,
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 48),
                              child: Material(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Flexible(
                                        child: Text(
                                          '原图暂不可用，已显示压缩预览',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: retry,
                                        child: const Text('重试原图'),
                                      ),
                                      TextButton(
                                        onPressed: () => setState(() {
                                          _loadOriginal = false;
                                          _originalPainted = false;
                                        }),
                                        child: const Text('仅预览'),
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
                  if (!_showOriginal && widget.active)
                    Positioned(
                      top: 60,
                      right: 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: IsleGlassBackdrop(
                          blur: 16,
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: _canLoadOriginal
                                  ? () => setState(() {
                                      _loadOriginal = true;
                                      _originalPainted = false;
                                    })
                                  : null,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    width: 0.75,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.image_outlined,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _canLoadOriginal
                                          ? '压缩预览 · 点击查看原图'
                                          : photoViewerOriginalTooLarge(
                                              widget.asset,
                                            )
                                          ? '原图较大 · 请用保存原文件'
                                          : '压缩预览 · 原文件可下载',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class PhotoMediaVideo extends StatefulWidget {
  const PhotoMediaVideo({
    super.key,
    required this.api,
    required this.asset,
    required this.active,
    this.autoPlay = false,
    this.liveMode = false,
    this.onCompleted,
  });
  final LightIsleApi api;
  final PhotoAsset asset;
  final bool active;
  final bool autoPlay;
  final bool liveMode;
  final VoidCallback? onCompleted;

  @override
  State<PhotoMediaVideo> createState() => PhotoMediaVideoState();
}

class PhotoMediaVideoState extends State<PhotoMediaVideo>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  Object? _error;
  bool _preparing = false;
  int _generation = 0;
  double _speed = 1.0;
  bool _wasPlaying = false;
  bool _completionNotified = false;
  List<SubtitleCue> _localCues = const [];
  String? _localSubtitleName;
  String? _subtitleError;

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
    if ((widget.liveMode || widget.onCompleted != null) &&
        _player?.value.isCompleted == true &&
        !_completionNotified) {
      _completionNotified = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCompleted?.call();
      });
    }
    if (mounted && _wasPlaying != playing) {
      _wasPlaying = playing;
      setState(() {});
    }
  }

  Future<void> _disposeController() async {
    _generation++;
    _preparing = false;
    _wasPlaying = false;
    _completionNotified = false;
    final old = _player;
    _player = null;
    old?.removeListener(_playerChanged);
    if (old != null) {
      await old.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant PhotoMediaVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      // Release native AVPlayer / ExoPlayer decoder buffers immediately when
      // swiping away in PageView instead of keeping multiple decoders resident.
      unawaited(_disposeController());
      setState(() {});
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
      if (!mounted || !widget.active || generation != _generation) {
        if (identical(_player, player)) _player = null;
        await player.dispose();
        return;
      }
      player.addListener(_playerChanged);
      await player.setPlaybackSpeed(_speed);
      if (widget.autoPlay) {
        await player.play();
      }
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (generation == _generation) _preparing = false;
    }
  }

  Future<void> _retry() async {
    await _disposeController();
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

  Future<void> _importSubtitle() async {
    try {
      final selected = await pickLocalSubtitle();
      if (!mounted || selected == null) return;
      final cues = parseWebVtt(selected.contents);
      if (cues.isEmpty) {
        throw const FormatException('没有找到有效的字幕时间轴');
      }
      setState(() {
        _localCues = cues;
        _localSubtitleName = selected.name;
        _subtitleError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _subtitleError = mediaErrorLabel(error));
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
    if (!widget.active && player == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          AuthenticatedMediaImage(
            api: widget.api,
            memoryCache: IsleCacheManager.instance.sharedThumbnails,
            path: '/api/v2/files/thumbnail',
            query: {'path': widget.asset.path, 'size': '1024'},
            maxBytes: 4 * 1024 * 1024,
            fit: BoxFit.contain,
            loadingBuilder: (_) => const SizedBox.shrink(),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          const Center(
            child: Icon(
              Icons.play_circle_outline_rounded,
              color: Colors.white70,
              size: 64,
            ),
          ),
        ],
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
          Flexible(
            child: Center(
              child: AspectRatio(
                aspectRatio: player.value.aspectRatio > 0
                    ? player.value.aspectRatio
                    : 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoPlayer(player),
                    if (_localCues.isNotEmpty)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: player,
                        builder: (context, value, _) {
                          final matches = _localCues.where(
                            (cue) => cue.contains(value.position),
                          );
                          if (matches.isEmpty) return const SizedBox.shrink();
                          return Positioned(
                            bottom: 12,
                            left: 16,
                            right: 16,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.68),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 7,
                                  ),
                                  child: Text(
                                    matches.first.text,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!widget.liveMode)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: IsleGlassBackdrop(
                  blur: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xBD10141D),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0x29FFFFFF),
                        width: 0.8,
                      ),
                    ),
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
                              playedColor: Color(0xFFE50914),
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
                        MediaPlaybackSpeedPicker(
                          value: _speed,
                          onChanged: (value) => unawaited(_setSpeed(value)),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '字幕选择与加载',
                          icon: const Icon(
                            Icons.closed_caption_rounded,
                            color: Colors.white,
                          ),
                          onSelected: (action) {
                            if (action == 'load') {
                              unawaited(_importSubtitle());
                            } else if (action == 'off') {
                              setState(() {
                                _localCues = const [];
                                _localSubtitleName = null;
                                _subtitleError = null;
                              });
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'off',
                              child: Text('关闭字幕'),
                            ),
                            const PopupMenuItem(
                              value: 'load',
                              child: Text('加载本机字幕 SRT / VTT'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (!widget.liveMode && _localSubtitleName != null)
            Text(
              '字幕：$_localSubtitleName',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          if (!widget.liveMode && _subtitleError != null)
            Text(
              '字幕加载失败：$_subtitleError',
              style: const TextStyle(color: Color(0xffffb4ab), fontSize: 12),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }
}
