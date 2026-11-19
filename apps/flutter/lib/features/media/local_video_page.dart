import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/widgets.dart';
import 'android_pip_session.dart';
import 'shared_video_player_controls.dart';

/// Plays a file the user selected on this device. No NAS session, temporary
/// media token or external network player is involved.
class LocalVideoPage extends StatefulWidget {
  const LocalVideoPage({super.key, required this.path});

  final String path;

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage>
    with WidgetsBindingObserver {
  static const _nativePlayer = MethodChannel('lightisle/native-video');
  static final _videoExtPattern = RegExp(
    r'\.(mp4|m4v|mov|mkv|webm|avi|ts|m2ts)$',
    caseSensitive: false,
  );
  late String _currentPath = widget.path;
  List<String> _playlist = const [];
  bool _autoPlayNext = false;
  bool _advancingNext = false;
  VideoPlayerController? _controller;
  String? _error;
  bool _loading = true;
  double _speed = 1;
  double _volume = 1;
  bool _muted = false;
  bool _playing = false;
  late final AndroidPipSession _pip;

  int get _currentIndex {
    final idx = _playlist.indexOf(_currentPath);
    return idx < 0 ? 0 : idx;
  }

  String? get _previousPath {
    final idx = _currentIndex;
    return idx > 0 && idx < _playlist.length ? _playlist[idx - 1] : null;
  }

  String? get _nextPath {
    final idx = _currentIndex;
    return idx >= 0 && idx + 1 < _playlist.length ? _playlist[idx + 1] : null;
  }

  void _discoverPlaylist() {
    try {
      final currentFile = File(_currentPath);
      if (!currentFile.existsSync()) {
        _playlist = <String>[_currentPath];
        return;
      }
      final parent = currentFile.parent;
      if (parent.path.isEmpty ||
          parent.path == '/' ||
          parent.path == _currentPath ||
          !parent.existsSync()) {
        _playlist = <String>[_currentPath];
        return;
      }
      final siblings = parent
          .listSync(followLinks: false)
          .whereType<File>()
          .map((entry) => entry.path)
          .where((entryPath) => _videoExtPattern.hasMatch(entryPath))
          .toSet();
      siblings.add(_currentPath);
      final sorted = siblings.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _playlist = sorted;
    } catch (_) {
      _playlist = <String>[_currentPath];
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pip = AndroidPipSession(
      onChanged: () {
        if (mounted) setState(() {});
      },
      onTimeout: () {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('未确认进入画中画，请检查系统画中画权限。')));
        if (WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.resumed) {
          unawaited(_controller?.pause());
        }
      },
      onError: (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('画中画启动失败，请检查系统权限。')));
      },
      onExit: () {
        if (mounted &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          unawaited(_controller?.pause());
        }
      },
    )..attach();
    _discoverPlaylist();
    unawaited(_open());
  }

  Future<void> _enterPiP() async {
    if (_controller?.value.isInitialized == true) await _pip.enter();
  }

  Future<void> _openSystemPlayer() async {
    try {
      await _controller?.pause();
      await _nativePlayer.invokeMethod<bool>('openLocal', {
        'path': _currentPath,
      });
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message ?? '无法打开系统播放器')));
      }
    } on MissingPluginException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前版本暂不支持原生播放器')));
      }
    }
  }

  Future<void> _open() async {
    final old = _controller;
    old?.removeListener(_updated);
    if (old != null) unawaited(old.dispose());
    final controller = VideoPlayerController.file(File(_currentPath));
    _controller = controller;
    setState(() {
      _loading = true;
      _error = null;
      _playing = false;
      _advancingNext = false;
    });
    try {
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      if (_speed != 1) {
        await controller.setPlaybackSpeed(_speed);
      }
      if (_muted || _volume < 0.999) {
        await controller.setVolume(_muted ? 0 : _volume);
      }
      controller.addListener(_updated);
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted && _controller == controller) {
        setState(() {
          _loading = false;
          _error = '无法播放此本地文件，请检查格式或文件是否仍可访问。';
        });
      }
    }
  }

  Future<void> _switchToPath(String targetPath) async {
    if (targetPath == _currentPath && _error == null) return;
    _currentPath = targetPath;
    _discoverPlaylist();
    await _open();
    if (mounted && _error == null) {
      unawaited(_controller?.play());
    }
  }

  void _updated() {
    final controller = _controller;
    final playing = controller?.value.isPlaying == true;
    if (mounted && playing != _playing) {
      setState(() => _playing = playing);
    }
    if (controller != null &&
        controller.value.isInitialized &&
        _autoPlayNext &&
        !_advancingNext &&
        controller.value.duration > Duration.zero &&
        controller.value.position >= controller.value.duration) {
      final next = _nextPath;
      if (next != null) {
        _advancingNext = true;
        unawaited(_switchToPath(next));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !_pip.requested && !_pip.active) {
      unawaited(_controller?.pause());
    }
  }

  Future<void> _seek(int seconds) async {
    final player = _controller;
    if (player?.value.isInitialized != true) return;
    final value = (player!.value.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.value.duration.inMilliseconds)
        .toInt();
    await player.seekTo(Duration(milliseconds: value));
  }

  Future<void> _toggleMute() async {
    final nextMuted = !_muted;
    final nextVolume = !nextMuted && _volume == 0 ? 1.0 : _volume;
    setState(() {
      _muted = nextMuted;
      _volume = nextVolume;
    });
    final player = _controller;
    if (player?.value.isInitialized != true) return;
    await player!.setVolume(nextMuted ? 0 : nextVolume);
  }

  Future<void> _setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    setState(() {
      _volume = clamped;
      _muted = clamped == 0;
    });
    final player = _controller;
    if (player?.value.isInitialized != true) return;
    await player!.setVolume(clamped);
  }

  Future<void> _showPlaylistSheet() async {
    _discoverPlaylist();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xF5121620),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(
          color: Colors.white.withValues(alpha: 0.14),
          width: 1.0,
        ),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.playlist_play_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '同目录播放列表（${_playlist.length}）',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        FilterChip(
                          visualDensity: VisualDensity.compact,
                          label: const Text(
                            '自动连播',
                            style: TextStyle(fontSize: 12),
                          ),
                          selected: _autoPlayNext,
                          onSelected: (value) {
                            setState(() => _autoPlayNext = value);
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Flexible(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.10),
                            width: 1.0,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _playlist.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            thickness: 1,
                            indent: 44,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          itemBuilder: (context, index) {
                            final itemPath = _playlist[index];
                            final active = itemPath == _currentPath;
                            final fileName = itemPath
                                .split(Platform.pathSeparator)
                                .last;
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              tileColor: active
                                  ? const Color(
                                      0xFFE50914,
                                    ).withValues(alpha: 0.18)
                                  : null,
                              leading: Icon(
                                active
                                    ? Icons.equalizer_rounded
                                    : Icons.play_circle_outline_rounded,
                                size: 18,
                                color: active
                                    ? const Color(0xFFFF6B72)
                                    : Colors.white70,
                              ),
                              title: Text(
                                fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  color: Colors.white,
                                  fontWeight: active
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              trailing: active
                                  ? const Text(
                                      '正在播放',
                                      style: TextStyle(
                                        color: Color(0xFFFF6B72),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    )
                                  : null,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                unawaited(_switchToPath(itemPath));
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pip.dispose();
    _controller?.removeListener(_updated);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _controller;
    final prev = _previousPath;
    final next = _nextPath;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: IsleAppBar(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
        title: Text(
          _currentPath.split(Platform.pathSeparator).last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '同目录播放列表',
            onPressed: _showPlaylistSheet,
            icon: const Icon(Icons.playlist_play_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.white),
                  ),
                )
              : (_pip.active || _pip.requested)
              ? Center(
                  child: AspectRatio(
                    aspectRatio: player!.value.aspectRatio > 0
                        ? player.value.aspectRatio
                        : 16 / 9,
                    child: RepaintBoundary(child: VideoPlayer(player)),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: player!.value.aspectRatio > 0
                              ? player.value.aspectRatio
                              : 16 / 9,
                          child: RepaintBoundary(child: VideoPlayer(player)),
                        ),
                      ),
                    ),
                    SharedVideoTransportDeck(
                      controller: player,
                      wrapInSafeArea: false,
                      seekBar: SharedVideoProgressBar(controller: player),
                      playing: _playing,
                      showPrevNext: _playlist.length > 1,
                      onPrev: prev == null
                          ? null
                          : () => unawaited(_switchToPath(prev)),
                      onNext: next == null
                          ? null
                          : () => unawaited(_switchToPath(next)),
                      onTogglePlay: () => unawaited(
                        _playing ? player.pause() : player.play(),
                      ),
                      onSeekBackward: () => unawaited(_seek(-10)),
                      onSeekForward: () => unawaited(_seek(10)),
                      muted: _muted,
                      volume: _muted ? 0 : _volume,
                      onToggleMute: () => unawaited(_toggleMute()),
                      onVolumeChanged: (value) => unawaited(_setVolume(value)),
                      rightClusterItems: [
                        if (defaultTargetPlatform == TargetPlatform.iOS ||
                            defaultTargetPlatform == TargetPlatform.macOS)
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _openSystemPlayer,
                            icon: const Icon(
                              Icons.picture_in_picture_alt_rounded,
                            ),
                            label: const Text('系统播放器 / 画中画 / AirPlay'),
                          ),
                        if (defaultTargetPlatform == TargetPlatform.android &&
                            _pip.supported)
                          IconButton(
                            tooltip: '画中画',
                            style:
                                SharedVideoPlayerStyle.compactTransportIconStyle(),
                            onPressed: _enterPiP,
                            icon: const Icon(
                              Icons.picture_in_picture_alt_rounded,
                              size: 19,
                            ),
                          ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: _showPlaylistSheet,
                          icon: const Icon(
                            Icons.playlist_play_rounded,
                            size: 18,
                          ),
                          label: Text(
                            _playlist.length > 1
                                ? '播放列表 ${_currentIndex + 1}/${_playlist.length}'
                                : '播放列表',
                          ),
                        ),
                        SharedPlayerSpeedMenuPill(
                          value: _speed,
                          onSelected: (value) async {
                            try {
                              await player.setPlaybackSpeed(value);
                              if (mounted) {
                                setState(() => _speed = value);
                              }
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('当前格式不支持此倍速'),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
