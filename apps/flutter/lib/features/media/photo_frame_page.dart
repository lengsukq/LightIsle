import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Full-screen borderless Digital Photo Frame mode for idle tablets, TVs, and
/// desktop displays, showing ambient photo transitions with a live clock.
class PhotoFramePage extends StatefulWidget {
  const PhotoFramePage({
    super.key,
    required this.api,
    required this.assets,
    this.title = '时光相册',
  });

  final LightIsleApi api;
  final List<PhotoAsset> assets;
  final String title;

  @override
  State<PhotoFramePage> createState() => _PhotoFramePageState();
}

class _PhotoFramePageState extends State<PhotoFramePage> {
  late final List<PhotoAsset> _photos;
  final Random _random = Random();
  int _index = 0;
  int _intervalSeconds = 10;
  bool _playing = true;
  bool _shuffled = false;
  bool _controlsVisible = true;
  DateTime _now = DateTime.now();

  Timer? _slideTimer;
  Timer? _clockTimer;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _photos = widget.assets.where((a) => !a.isVideo).toList(growable: false);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _restartSlideTimer();
    _revealControls();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _clockTimer?.cancel();
    _hideTimer?.cancel();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _restartSlideTimer() {
    _slideTimer?.cancel();
    if (_playing && _photos.length > 1) {
      _slideTimer = Timer.periodic(
        Duration(seconds: _intervalSeconds),
        (_) => _advance(1),
      );
    }
  }

  void _advance(int delta) {
    if (!mounted || _photos.length <= 1) return;
    setState(() {
      if (_shuffled) {
        var next = _index;
        for (var i = 0; i < 4 && next == _index; i++) {
          next = _random.nextInt(_photos.length);
        }
        _index = next;
      } else {
        _index = (_index + delta + _photos.length) % _photos.length;
      }
    });
  }

  void _revealControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  String get _clockText =>
      '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';

  String get _dateText {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${_now.year}年${_now.month}月${_now.day}日 · ${weekdays[_now.weekday - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final current = _photos.isEmpty ? null : _photos[_index % _photos.length];
    final safe = MediaQuery.paddingOf(context);

    return Scaffold(
      backgroundColor: const Color(0xFF050507),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _revealControls,
        onHorizontalDragEnd: (details) {
          final vx = details.primaryVelocity ?? 0;
          if (vx < -180) _advance(1);
          if (vx > 180) _advance(-1);
          _revealControls();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (current == null)
              const Center(
                child: Text(
                  '当前列表暂无可轮播的照片',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              )
            else
              AnimatedSwitcher(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 550),
                child: SizedBox.expand(
                  key: ValueKey(current.id),
                  child: AuthenticatedMediaImage(
                    api: widget.api,
                    path: '/api/v2/files/preview',
                    query: {'path': current.path},
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            Positioned(
              left: safe.left + 28,
              bottom: safe.bottom + 24,
              child: IgnorePointer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _clockText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 56,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                        fontFeatures: [FontFeature.tabularFigures()],
                        shadows: [
                          Shadow(color: Color(0xCC000000), blurRadius: 18),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _dateText,
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 15,
                        shadows: [
                          Shadow(color: Color(0xCC000000), blurRadius: 12),
                        ],
                      ),
                    ),
                    if (current != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${widget.title} · ${formatMediaDate(current.takenAt)}'
                        '${_photos.length > 1 ? ' (${_index + 1}/${_photos.length})' : ''}',
                        style: const TextStyle(
                          color: Color(0xBFFFFFFF),
                          fontSize: 12.5,
                          shadows: [
                            Shadow(color: Color(0xCC000000), blurRadius: 10),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Positioned(
              top: safe.top + 16,
              right: safe.right + 16,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xB8141418),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _playing ? '暂停轮播' : '继续轮播',
                          color: Colors.white,
                          icon: Icon(
                            _playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          onPressed: () {
                            setState(() => _playing = !_playing);
                            _restartSlideTimer();
                            _revealControls();
                          },
                        ),
                        IconButton(
                          tooltip: '随机顺序',
                          color: _shuffled
                              ? const Color(0xFF9CDCF5)
                              : Colors.white70,
                          icon: const Icon(Icons.shuffle_rounded),
                          onPressed: () {
                            setState(() => _shuffled = !_shuffled);
                            _revealControls();
                          },
                        ),
                        PopupMenuButton<int>(
                          tooltip: '轮播间隔',
                          initialValue: _intervalSeconds,
                          onSelected: (secs) {
                            setState(() => _intervalSeconds = secs);
                            _restartSlideTimer();
                            _revealControls();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 5, child: Text('每 5 秒')),
                            PopupMenuItem(value: 10, child: Text('每 10 秒')),
                            PopupMenuItem(value: 30, child: Text('每 30 秒')),
                            PopupMenuItem(value: 60, child: Text('每 60 秒')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              '${_intervalSeconds}s',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '退出电子相框',
                          color: Colors.white,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
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
