part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerState on _CinemaDetailDialogState {
  String get _currentQualityKey {
    if (_playback.hlsSession != null) return _playback.hlsSession!.quality;
    if (_playback.directLocalActive && !_film.canAttemptPlayback) {
      return 'local';
    }
    return 'source';
  }

  Future<void> _loadDetailAndPlayer({
    double? seekTo,
    bool forceDirect = false,
    bool fallbackFromNoFfmpeg = false,
  }) async {
    try {
      final response = await widget.api.get('/api/v2/cinema/${_film.id}');
      final detail = CinemaFilm.fromJson(response);
      if (!mounted) return;
      _updateState(() => _film = detail);
    } catch (_) {
      // Keep list metadata and progress if the detail refresh is unavailable.
    }
    if (!mounted) return;
    final preferLocal =
        forceDirect || CinemaDecodePreference.preferLocalDecode.value;
    if (!_film.canAttemptPlayback && !preferLocal) {
      _updateState(() {
        _playback.loading = false;
        _playback.playbackMessage = _unsupportedMessage;
      });
      await _startTranscode(
        start: seekTo ?? (_film.canResume ? _film.position : 0),
      );
      return;
    }
    final useDirectParam =
        !_film.canAttemptPlayback || forceDirect || preferLocal;
    try {
      final source = await widget.api.mediaUri(
        '/api/v2/cinema/${_film.id}/stream',
        query: useDirectParam ? const <String, String>{'direct': '1'} : null,
      );
      if (!mounted) return;
      final controller = VideoPlayerController.networkUrl(
        source,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      final previous = _playback.controller;
      _playback.controller = controller;
      if (previous != null && previous != controller) {
        previous.removeListener(_onVideoChanged);
        await previous.dispose();
      }
      await controller.initialize();
      if (!mounted || _playback.controller != controller) return;
      final savedPosition = seekTo != null && seekTo > 1
          ? Duration(milliseconds: (seekTo * 1000).round())
          : Duration(milliseconds: (_film.position * 1000).round());
      if (savedPosition > Duration.zero &&
          savedPosition <
              controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(savedPosition);
      }
      if (_playback.playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playback.playbackSpeed);
      }
      if (_playback.volume < 0.999) {
        await controller.setVolume(_playback.volume);
      }
      if (!mounted || _playback.controller != controller) return;
      controller.addListener(_onVideoChanged);
      final isTestBinding = WidgetsBinding.instance.runtimeType
          .toString()
          .contains('Test');
      if (widget.playerOnly && !isTestBinding) {
        unawaited(controller.play());
      }
      _updateState(() {
        _playback.hlsSession = null;
        _playback.directLocalActive = useDirectParam;
        _playback.loading = false;
        if (fallbackFromNoFfmpeg) {
          _playback.playbackMessage = '服务器未安装 FFmpeg，已自动启用原片直传（本地解码）。';
        } else if (!_film.canAttemptPlayback) {
          _playback.playbackMessage = '原片直传（本地解码）播放中。若声音或画面异常，可切换清晰度使用转码。';
        } else {
          _playback.playbackMessage =
              _film.browserPlayback == 'unverified-direct'
              ? '此格式尚未验证；如果当前设备无法解码，播放会失败。原片未做转换。'
              : null;
        }
      });
      _scheduleChromeHide();
    } catch (error) {
      if (!mounted) return;
      if (!_film.canAttemptPlayback && !fallbackFromNoFfmpeg) {
        await _startTranscode(
          start: seekTo ?? (_film.canResume ? _film.position : 0),
          allowDirectFallback: false,
        );
        return;
      }
      _updateState(() {
        _playback.loading = false;
        _playback.playbackMessage = fallbackFromNoFfmpeg
            ? '未安装 FFmpeg，且当前设备无法本地解码此格式；可使用外部播放器（IINA / VLC / Infuse）打开或安装 FFmpeg。'
            : '无法在当前设备播放此视频：${mediaErrorLabel(error)}';
      });
    }
  }

  String get _unsupportedMessage {
    switch (_film.probeStatus) {
      case 'pending':
        return '格式仍在识别中，当前无法直接播放。请稍后重新打开。';
      case 'unavailable':
        return '格式检查器不可用，暂时无法确认此视频是否能播放。';
      case 'failed':
        return '视频格式识别失败，当前无法直接播放。';
      case 'unsupported':
        return '当前设备的播放器不支持此视频格式。原始文件未做转换。';
      default:
        return '此视频无法通过当前播放器播放。原始文件未做转换。';
    }
  }

  String _transcodeErrorLabel(Object error) {
    if (error is LightIsleApiException) {
      switch (error.code) {
        case 'transcode_unavailable':
          return '未安装 FFmpeg，仅支持下载后播放；管理员可在服务器执行 brew install ffmpeg 启用转码。';
        case 'transcode_busy':
          return '转码通道被占用，请稍后重试。';
        case 'transcode_failed':
          return '转码失败：该影片可能包含不兼容的编码，请下载后用本地播放器打开。';
        case 'transcode_insufficient_space':
          return '服务器空间不足，无法创建转码缓存，请清理后重试。';
        case 'transcode_start_timeout':
          return '转码启动超时，请稍后重试。';
      }
    }
    return mediaErrorLabel(error);
  }

  Future<void> _startTranscode({
    double? start,
    int audio = 0,
    String quality = 'source',
    bool allowDirectFallback = true,
  }) async {
    if (!mounted || _playback.transcodeStarting) return;
    final filmId = _film.id;
    _updateState(() {
      _playback.transcodeStarting = true;
      _playback.playbackMessage = '正在启动转码…';
    });
    try {
      final source = await prepareCinemaHlsSource(
        api: widget.api,
        filmId: '$filmId',
        isCurrent: () => mounted && _film.id == filmId,
        start: start ?? 0,
        audio: audio,
        quality: quality,
        replaceSessionId: _playback.hlsSession?.sessionId ?? '',
      );
      if (source == null || !mounted || _film.id != filmId) return;
      final session = source.session;
      final controller = VideoPlayerController.networkUrl(
        source.playlist,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      final previous = _playback.controller;
      _playback.controller = controller;
      if (previous != null && previous != controller) {
        previous.removeListener(_onVideoChanged);
        await previous.dispose();
      }
      if (!mounted || _playback.controller != controller) return;
      await controller.initialize();
      if (!mounted || _playback.controller != controller) return;
      final target =
          (start ?? (_film.canResume ? _film.position : 0)) - session.start;
      final savedPosition = Duration(
        milliseconds: (target > 1 ? target * 1000 : 0).round(),
      );
      if (savedPosition > Duration.zero &&
          savedPosition <
              controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(savedPosition);
      }
      if (_playback.playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playback.playbackSpeed);
      }
      if (_playback.volume < 0.999) {
        await controller.setVolume(_playback.volume);
      }
      if (!mounted || _playback.controller != controller) return;
      controller.addListener(_onVideoChanged);
      try {
        _playback.tracks = CinemaTrackInfo.fromJson(
          await widget.api.get('/api/v2/cinema/$filmId/tracks'),
        );
      } catch (_) {
        // Track listing is optional; playback continues without selectors.
      }
      if (!mounted) return;
      final isTestBinding = WidgetsBinding.instance.runtimeType
          .toString()
          .contains('Test');
      if (widget.playerOnly && !isTestBinding) {
        unawaited(controller.play());
      }
      _updateState(() {
        _playback.hlsSession = session;
        _playback.directLocalActive = false;
        _playback.transcodeStarting = false;
        _playback.playbackMessage = session.profile == 'remux'
            ? '转封装播放（无画质损失），原片未修改。'
            : '转码播放中（服务器实时转码），原片未修改。';
      });
      _scheduleChromeHide();
    } catch (error) {
      if (!mounted || _film.id != filmId) return;
      if (allowDirectFallback &&
          error is LightIsleApiException &&
          error.code == 'transcode_unavailable') {
        _updateState(() {
          _playback.transcodeStarting = false;
          _playback.playbackMessage = '服务器未安装 FFmpeg，正在尝试原片直传（本地解码）…';
        });
        await _loadDetailAndPlayer(
          seekTo: start,
          forceDirect: true,
          fallbackFromNoFfmpeg: true,
        );
        return;
      }
      _updateState(() {
        _playback.transcodeStarting = false;
        _playback.playbackMessage = _transcodeErrorLabel(error);
      });
    }
  }

  Future<void> _switchAudio(int audioIndex) async {
    final controller = _playback.controller;
    final session = _playback.hlsSession;
    if (controller == null ||
        session == null ||
        session.audioTrack == audioIndex) {
      return;
    }
    final realPosition =
        controller.value.position.inMilliseconds / 1000.0 + session.start;
    await controller.pause();
    await _startTranscode(
      start: realPosition,
      audio: audioIndex,
      quality: session.quality,
    );
  }

  /// 原画 plus local decode option and every tier below the source height.
  List<(String, String)> _qualityOptions() {
    final options = <(String, String)>[('source', '原画'), ('local', '本地硬解')];
    final sourceHeight = _film.height > 0
        ? _film.height
        : (_playback.tracks?.height ?? 0);
    for (final (value, label, height)
        in _CinemaDetailDialogState._qualityTiers) {
      if (sourceHeight > 0 && sourceHeight <= height) break;
      options.add((value, label));
    }
    return options;
  }

  Future<void> _switchQuality(String quality) async {
    if (_playback.transcodeStarting) return;
    final controller = _playback.controller;
    final session = _playback.hlsSession;
    final realPosition = controller != null
        ? controller.value.position.inMilliseconds / 1000.0 +
              (session?.start ?? 0.0)
        : (_film.canResume ? _film.position : 0.0);
    if (quality == 'local') {
      if (session == null && _playback.directLocalActive) return;
      await controller?.pause();
      if (controller != null) {
        controller.removeListener(_onVideoChanged);
        await controller.dispose();
      }
      _playback.hlsSession = null;
      _playback.controller = null;
      if (!mounted) return;
      _updateState(() {
        _playback.loading = true;
        _playback.playbackMessage = null;
      });
      await _loadDetailAndPlayer(seekTo: realPosition, forceDirect: true);
      return;
    }
    if (session == null) {
      if (quality == 'source' &&
          _film.canAttemptPlayback &&
          !_playback.directLocalActive) {
        return;
      }
      await controller?.pause();
      await _startTranscode(
        start: realPosition,
        quality: quality,
        allowDirectFallback: false,
      );
      return;
    }
    if (session.quality == quality) return;
    await controller!.pause();
    if (quality == 'source' && _film.canAttemptPlayback) {
      // Back to the plain stream: dispose the session controller first.
      controller.removeListener(_onVideoChanged);
      await controller.dispose();
      _playback.hlsSession = null;
      _playback.controller = null;
      if (!mounted) return;
      _updateState(() {
        _playback.loading = true;
        _playback.playbackMessage = null;
      });
      await _loadDetailAndPlayer(seekTo: realPosition);
      return;
    }
    await _startTranscode(
      start: realPosition,
      audio: session.audioTrack,
      quality: quality,
      allowDirectFallback: false,
    );
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    if (!const [0.75, 1.0, 1.25, 1.5, 2.0].contains(speed)) return;
    _sessionCinemaSpeed = speed;
    _playback.playbackSpeed = speed;
    await _playback.controller?.setPlaybackSpeed(speed);
    if (mounted) _updateState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lightisle_cinema_playback_speed', speed);
    } catch (_) {
      /* Persist when possible, playback still works without it. */
    }
  }

  double get _originalPlaybackSeconds {
    final controller = _playback.controller;
    if (controller == null || !controller.value.isInitialized) return 0;
    return controller.value.position.inMilliseconds / 1000.0 +
        (_playback.hlsSession?.start ?? 0);
  }

  double get _knownFilmDuration {
    var best = _film.durationSeconds > 0 ? _film.durationSeconds : 0.0;
    if (_film.duration > best) best = _film.duration;
    final sessionDur = _playback.hlsSession?.durationSeconds ?? 0;
    if (sessionDur > best) best = sessionDur;
    final trackDur = _playback.tracks?.durationSeconds ?? 0;
    if (trackDur > best) best = trackDur;
    return best;
  }

  double get _originalPlaybackDuration {
    final controller = _playback.controller;
    final sessionStart = _playback.hlsSession?.start ?? 0;
    final observed = controller == null || !controller.value.isInitialized
        ? 0.0
        : controller.value.duration.inMilliseconds / 1000.0 + sessionStart;
    final known = _knownFilmDuration;
    if (_playback.hlsSession != null && known > 0) {
      final pos = _originalPlaybackSeconds;
      return known > pos ? known : pos;
    }
    return known > observed ? known : observed;
  }

  Future<void> _seekAbsolute(double absoluteSeconds) async {
    final controller = _playback.controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _playback.transcodeStarting) {
      return;
    }
    final max = _originalPlaybackDuration;
    final target = absoluteSeconds
        .clamp(0.0, max > 0 ? max - .25 : 0.0)
        .toDouble();
    final session = _playback.hlsSession;
    if (session != null) {
      final localTarget = target - session.start;
      final muxedLen = controller.value.duration.inMilliseconds / 1000.0;
      if (localTarget >= 0 && muxedLen > 2 && localTarget <= muxedLen - 1.5) {
        await controller.seekTo(
          Duration(milliseconds: (localTarget * 1000).round()),
        );
        unawaited(_queueProgressSave(force: true));
      } else {
        unawaited(_queueProgressSave(force: true));
        await _startTranscode(
          start: target,
          audio: session.audioTrack,
          quality: session.quality,
        );
      }
    } else {
      await controller.seekTo(Duration(milliseconds: (target * 1000).round()));
      unawaited(_queueProgressSave(force: true));
    }
    if (mounted) _updateState(() => _playback.seekDraft = null);
  }

  Future<void> _seekRelative(double deltaSeconds) async {
    await _seekAbsolute(_originalPlaybackSeconds + deltaSeconds);
  }

  static const _nativeVideoChannel = MethodChannel('lightisle/native-video');

  void _revealChrome() {
    if (!mounted) return;
    if (!_chrome.visible) {
      _updateState(() => _chrome.visible = true);
    }
    _scheduleChromeHide();
  }

  void _scheduleChromeHide() {
    _chrome.cancelTimer();
    final isTestBinding = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('Test');
    if (isTestBinding) return;
    _chrome.hideTimer = Timer(const Duration(milliseconds: 3400), () {
      if (!mounted) return;
      final controller = _playback.controller;
      if (controller != null &&
          controller.value.isInitialized &&
          controller.value.isPlaying &&
          !_chrome.showPlayerDetails &&
          !_chrome.showPlaylistSheet &&
          _playback.seekDraft == null &&
          _playback.progressSaveMessage == null &&
          _externalActions.offlineProgress == null) {
        _updateState(() => _chrome.visible = false);
      }
    });
  }

  void _toggleChrome() {
    if (!mounted) return;
    if (_chrome.visible) {
      _chrome.cancelTimer();
      _updateState(() => _chrome.visible = false);
    } else {
      _revealChrome();
    }
  }

  Future<void> _toggleFullscreen() async {
    final next = !_chrome.windowFullscreen;
    _updateState(() => _chrome.windowFullscreen = next);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      try {
        await _nativeVideoChannel.invokeMethod<void>('toggleFullScreen');
      } catch (_) {
        // Fallback cleanly if channel is unavailable in tests.
      }
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        await SystemChrome.setEnabledSystemUIMode(
          next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } catch (_) {
        // System UI mode toggling is best-effort on restricted test bindings.
      }
    }
  }

  Future<void> _exitNativeFullscreen() async {
    if (!_chrome.windowFullscreen) return;
    _chrome.windowFullscreen = false;
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      try {
        await _nativeVideoChannel.invokeMethod<void>('exitFullScreen');
      } catch (_) {
        // Window channel may already be detached on teardown.
      }
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (_) {
        // System UI restoration is best-effort on teardown.
      }
    }
  }

  Future<void> _showFullscreenPlayer() async {
    if (_playback.controller?.value.isInitialized != true) return;
    double? draggedPosition;
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierColor: Colors.black,
      builder: (context) => StatefulBuilder(
        builder: (dialogContext, updateOverlay) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: '退出全屏',
                      color: Colors.white,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.fullscreen_exit),
                    ),
                    if (_pip.supported)
                      IconButton(
                        tooltip: '画中画',
                        color: Colors.white,
                        onPressed: _enterPiP,
                        icon: const Icon(Icons.picture_in_picture_alt_rounded),
                      ),
                    Expanded(
                      child: Text(
                        _film.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child:
                        _playback.controller == null ||
                            !_playback.controller!.value.isInitialized
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio:
                                _playback.controller!.value.aspectRatio > 0
                                ? _playback.controller!.value.aspectRatio
                                : 16 / 9,
                            child: GestureDetector(
                              onDoubleTapDown: (details) async {
                                final width = MediaQuery.sizeOf(dialogContext)
                                    .width;
                                final direction =
                                    details.localPosition.dx < width * .4
                                    ? -10.0
                                    : details.localPosition.dx > width * .6
                                    ? 10.0
                                    : 0.0;
                                if (direction != 0) {
                                  await _seekRelative(direction);
                                  if (dialogContext.mounted) {
                                    updateOverlay(() {});
                                  }
                                } else if (_playback
                                        .controller
                                        ?.value
                                        .isPlaying ==
                                    true) {
                                  await _playback.controller?.pause();
                                } else {
                                  await _playback.controller?.play();
                                }
                              },
                              child: VideoPlayer(_playback.controller!),
                            ),
                          ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _playback.controller!,
                  builder: (context, _) {
                    final total = _originalPlaybackDuration;
                    final current = _originalPlaybackSeconds;
                    if (total <= 0) return const SizedBox(height: 20);
                    return Column(
                      children: [
                        Slider(
                          value: (draggedPosition ?? current).clamp(0.0, total),
                          max: total,
                          onChanged: _playback.transcodeStarting
                              ? null
                              : (value) => updateOverlay(
                                  () => draggedPosition = value,
                                ),
                          onChangeEnd: (value) async {
                            await _seekAbsolute(value);
                            if (dialogContext.mounted) {
                              updateOverlay(() => draggedPosition = null);
                            }
                          },
                        ),
                        Text(
                          '${_timeLabel(Duration(milliseconds: (current * 1000).round()))} / ${_timeLabel(Duration(milliseconds: (total * 1000).round()))}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    );
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '快退10秒',
                      color: Colors.white,
                      onPressed: () async {
                        await _seekRelative(-10);
                        if (dialogContext.mounted) updateOverlay(() {});
                      },
                      icon: const Icon(Icons.replay_10),
                    ),
                    IconButton(
                      tooltip: _playback.controller?.value.isPlaying == true
                          ? '暂停'
                          : '播放',
                      color: Colors.white,
                      onPressed: () {
                        final controller = _playback.controller;
                        if (controller == null) return;
                        if (controller.value.isPlaying) {
                          unawaited(controller.pause());
                        } else {
                          unawaited(controller.play());
                        }
                        updateOverlay(() {});
                      },
                      icon: Icon(
                        _playback.controller?.value.isPlaying == true
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      tooltip: '快进10秒',
                      color: Colors.white,
                      onPressed: () async {
                        await _seekRelative(10);
                        if (dialogContext.mounted) updateOverlay(() {});
                      },
                      icon: const Icon(Icons.forward_10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onVideoChanged() {
    final controller = _playback.controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.hasError) {
      final message =
          '视频播放中断：${controller.value.errorDescription ?? '当前设备无法解码此格式。'}';
      if (mounted && _playback.playbackMessage != message) {
        _updateState(() => _playback.playbackMessage = message);
      }
      return;
    }
    if (mounted &&
        _playback.consumeShouldRebuild(
          controller.value,
          playerOnly: widget.playerOnly,
          subtitleText: _subtitles.cues.isEmpty ? null : _activeCue?.text,
        )) {
      _updateState(() {});
    }
    _handlePlayerProgressTick(controller);
  }
}
