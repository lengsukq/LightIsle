import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

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
  static const _pipChannel = MethodChannel('lightisle/pip');
  VideoPlayerController? _controller;
  String? _error;
  bool _loading = true;
  double _speed = 1;
  bool _playing = false;
  bool _pipSupported = false;
  bool _pipRequested = false;
  bool _pipActive = false;
  Timer? _pipWatchdog;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _pipChannel.setMethodCallHandler((call) async {
        if (call.method == 'state' && mounted) {
          _pipWatchdog?.cancel();
          final active = call.arguments == true;
          setState(() {
            _pipActive = active;
            _pipRequested = active;
          });
        }
      });
      unawaited(_checkPiPSupport());
    }
    unawaited(_open());
  }

  Future<void> _checkPiPSupport() async {
    try {
      final supported = await _pipChannel.invokeMethod<bool>('supported');
      if (mounted) setState(() => _pipSupported = supported == true);
    } on PlatformException {
      // PiP is an optional OS capability.
    } on MissingPluginException {
      // Older native client builds do not implement this method channel.
    }
  }

  Future<void> _enterPiP() async {
    if (!_pipSupported || _controller?.value.isInitialized != true) return;
    setState(() => _pipRequested = true);
    _pipWatchdog?.cancel();
    // Some Android OEMs return true for enterPictureInPictureMode but never
    // deliver a state callback (or deny PiP from app settings). Do not leave
    // a phantom PiP state that suppresses all subsequent background pauses.
    _pipWatchdog = Timer(const Duration(seconds: 4), () {
      if (mounted && !_pipActive && _pipRequested) {
        setState(() => _pipRequested = false);
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('未确认进入画中画，请检查系统画中画权限。')));
        if (WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.resumed) {
          unawaited(_controller?.pause());
        }
      }
    });
    try {
      final entered = await _pipChannel.invokeMethod<bool>('enter');
      if (entered != true && mounted) {
        setState(() => _pipRequested = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _pipRequested = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('画中画启动失败，请检查系统权限。')));
      }
    }
  }

  Future<void> _openSystemPlayer() async {
    try {
      await _controller?.pause();
      await _nativePlayer.invokeMethod<bool>('openLocal', {
        'path': widget.path,
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
    final controller = VideoPlayerController.file(File(widget.path));
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      controller.addListener(_updated);
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法播放此本地文件，请检查格式或文件是否仍可访问。';
        });
      }
    }
  }

  void _updated() {
    final playing = _controller?.value.isPlaying == true;
    if (mounted && playing != _playing) {
      setState(() => _playing = playing);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !_pipRequested && !_pipActive) {
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

  @override
  void dispose() {
    _pipWatchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _pipChannel.setMethodCallHandler(null);
    }
    _controller?.removeListener(_updated);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
        title: Text(
          widget.path.split(Platform.pathSeparator).last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
              : (_pipActive || _pipRequested)
              ? Center(
                  child: AspectRatio(
                    aspectRatio: player!.value.aspectRatio > 0
                        ? player.value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(player),
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
                          child: VideoPlayer(player),
                        ),
                      ),
                    ),
                    VideoProgressIndicator(
                      player,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      colors: const VideoProgressColors(
                        playedColor: Colors.white,
                        bufferedColor: Colors.white54,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.spaceEvenly,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '快退 10 秒',
                            onPressed: () => unawaited(_seek(-10)),
                            color: Colors.white,
                            icon: const Icon(Icons.replay_10),
                          ),
                          if (defaultTargetPlatform == TargetPlatform.iOS ||
                              defaultTargetPlatform == TargetPlatform.macOS)
                            TextButton.icon(
                              onPressed: _openSystemPlayer,
                              icon: const Icon(
                                Icons.picture_in_picture_alt_rounded,
                              ),
                              label: const Text('系统播放器 / 画中画 / AirPlay'),
                            ),
                          if (defaultTargetPlatform == TargetPlatform.android &&
                              _pipSupported)
                            TextButton.icon(
                              onPressed: _enterPiP,
                              icon: const Icon(
                                Icons.picture_in_picture_alt_rounded,
                              ),
                              label: const Text('画中画'),
                            ),
                          IconButton(
                            tooltip: _playing ? '暂停' : '播放',
                            color: Colors.white,
                            onPressed: () => unawaited(
                              _playing ? player.pause() : player.play(),
                            ),
                            icon: Icon(
                              _playing ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          IconButton(
                            tooltip: '快进 10 秒',
                            onPressed: () => unawaited(_seek(10)),
                            color: Colors.white,
                            icon: const Icon(Icons.forward_10),
                          ),
                          DropdownButton<double>(
                            value: _speed,
                            dropdownColor: const Color(0xff202124),
                            style: const TextStyle(color: Colors.white),
                            iconEnabledColor: Colors.white,
                            onChanged: (value) async {
                              if (value == null) return;
                              try {
                                await player.setPlaybackSpeed(value);
                                if (mounted) setState(() => _speed = value);
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('当前格式不支持此倍速')),
                                  );
                                }
                              }
                            },
                            items: [
                              for (final speed in [0.75, 1.0, 1.25, 1.5, 2.0])
                                DropdownMenuItem(
                                  value: speed,
                                  child: Text('${speed}x'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
