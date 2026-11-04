part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerState on _CinemaDetailDialogState {
  Future<void> _loadDetailAndPlayer({double? seekTo}) async {
    try {
      final response = await widget.api.get('/api/v2/cinema/${_film.id}');
      final detail = CinemaFilm.fromJson(response);
      if (!mounted) return;
      _updateState(() => _film = detail);
    } catch (_) {
      // Keep list metadata and progress if the detail refresh is unavailable.
    }
    if (!mounted) return;
    if (!_film.canAttemptPlayback) {
      _updateState(() {
        _loading = false;
        _playbackMessage = _unsupportedMessage;
      });
      // The browser-grade player cannot decode this container/codec. The
      // server-side HLS session (remux or VideoToolbox transcode) is the
      // remaining playback path; it degrades honestly when FFmpeg is absent.
      // Starting the session at the resume point keeps the muxer from
      // producing minutes of segments nobody is watching yet.
      await _startTranscode(start: _film.canResume ? _film.position : 0);
      return;
    }
    try {
      final source = await widget.api.mediaUri(
        '/api/v2/cinema/${_film.id}/stream',
      );
      if (!mounted) return;
      final controller = VideoPlayerController.networkUrl(
        source,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      final savedPosition = seekTo != null && seekTo > 1
          ? Duration(milliseconds: (seekTo * 1000).round())
          : Duration(milliseconds: (_film.position * 1000).round());
      if (savedPosition > Duration.zero &&
          savedPosition <
              controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(savedPosition);
      }
      if (_playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playbackSpeed);
      }
      if (!mounted || _controller != controller) return;
      controller.addListener(_onVideoChanged);
      _updateState(() {
        _loading = false;
        _playbackMessage = _film.browserPlayback == 'unverified-direct'
            ? '此格式尚未验证；如果当前设备无法解码，播放会失败。原片未做转换。'
            : null;
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        _loading = false;
        _playbackMessage = '无法在当前设备播放此视频：${mediaErrorLabel(error)}';
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
  }) async {
    if (!mounted || _transcodeStarting) return;
    final filmId = _film.id;
    _updateState(() {
      _transcodeStarting = true;
      _playbackMessage = '正在启动转码…';
    });
    try {
      final source = await prepareCinemaHlsSource(
        api: widget.api,
        filmId: '$filmId',
        isCurrent: () => mounted && _film.id == filmId,
        start: start ?? 0,
        audio: audio,
        quality: quality,
      );
      if (source == null || !mounted || _film.id != filmId) return;
      final session = source.session;
      final controller = VideoPlayerController.networkUrl(
        source.playlist,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      final previous = _controller;
      _controller = controller;
      if (previous != null && previous != controller) {
        previous.removeListener(_onVideoChanged);
        await previous.dispose();
      }
      if (!mounted || _controller != controller) return;
      await controller.initialize();
      if (!mounted || _controller != controller) return;
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
      if (_playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playbackSpeed);
      }
      if (!mounted || _controller != controller) return;
      controller.addListener(_onVideoChanged);
      try {
        _tracks = CinemaTrackInfo.fromJson(
          await widget.api.get('/api/v2/cinema/$filmId/tracks'),
        );
      } catch (_) {
        // Track listing is optional; playback continues without selectors.
      }
      if (!mounted) return;
      _updateState(() {
        _hlsSession = session;
        _transcodeStarting = false;
        _playbackMessage = session.profile == 'remux'
            ? '转封装播放（无画质损失），原片未修改。'
            : '转码播放中（服务器实时转码），原片未修改。';
      });
    } catch (error) {
      if (!mounted || _film.id != filmId) return;
      _updateState(() {
        _transcodeStarting = false;
        _playbackMessage = _transcodeErrorLabel(error);
      });
    }
  }

  Future<void> _switchAudio(int audioIndex) async {
    final controller = _controller;
    final session = _hlsSession;
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

  /// 原画 plus every tier below the source height (no upscaling options).
  List<(String, String)> _qualityOptions() {
    final options = <(String, String)>[('source', '原画')];
    final sourceHeight = _film.height;
    for (final (value, label, height)
        in _CinemaDetailDialogState._qualityTiers) {
      if (sourceHeight > 0 && sourceHeight <= height) break;
      options.add((value, label));
    }
    return options;
  }

  Future<void> _switchQuality(String quality) async {
    if (_transcodeStarting) return;
    final controller = _controller;
    final session = _hlsSession;
    if (session == null) {
      if (quality == 'source') return;
      final realPosition = controller != null
          ? controller.value.position.inMilliseconds / 1000.0
          : (_film.canResume ? _film.position : 0.0);
      await controller?.pause();
      await _startTranscode(start: realPosition, quality: quality);
      return;
    }
    if (session.quality == quality) return;
    final realPosition =
        controller!.value.position.inMilliseconds / 1000.0 + session.start;
    await controller.pause();
    if (quality == 'source' && _film.canAttemptPlayback) {
      // Back to the plain stream: dispose the session controller first.
      controller.removeListener(_onVideoChanged);
      await controller.dispose();
      _hlsSession = null;
      _controller = null;
      if (!mounted) return;
      _updateState(() {
        _loading = true;
        _playbackMessage = null;
      });
      await _loadDetailAndPlayer(seekTo: realPosition);
      return;
    }
    await _startTranscode(
      start: realPosition,
      audio: session.audioTrack,
      quality: quality,
    );
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    if (!const [0.75, 1.0, 1.25, 1.5, 2.0].contains(speed)) return;
    _playbackSpeed = speed;
    await _controller?.setPlaybackSpeed(speed);
    if (mounted) {
      _updateState(() {});
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lightisle_cinema_playback_speed', speed);
    } catch (_) {
      /* Persist when possible, playback still works without it. */
    }
  }

  double get _originalPlaybackSeconds {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return 0;
    return controller.value.position.inMilliseconds / 1000.0 +
        (_hlsSession?.start ?? 0);
  }

  double get _originalPlaybackDuration {
    final controller = _controller;
    final sessionStart = _hlsSession?.start ?? 0;
    final observed = controller == null || !controller.value.isInitialized
        ? 0.0
        : controller.value.duration.inMilliseconds / 1000.0 + sessionStart;
    return _film.durationSeconds > 0
        ? (_film.durationSeconds > observed ? _film.durationSeconds : observed)
        : observed;
  }

  Future<void> _seekAbsolute(double absoluteSeconds) async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _transcodeStarting) {
      return;
    }
    final max = _originalPlaybackDuration;
    final target = absoluteSeconds
        .clamp(0.0, max > 0 ? max - .25 : 0.0)
        .toDouble();
    final session = _hlsSession;
    if (session != null) {
      // The playlist's first frame is at session.start; rebuild the session
      // for absolute seeks outside its guaranteed live media window.
      unawaited(_queueProgressSave(force: true));
      await _startTranscode(
        start: target,
        audio: session.audioTrack,
        quality: session.quality,
      );
    } else {
      await controller.seekTo(Duration(milliseconds: (target * 1000).round()));
      unawaited(_queueProgressSave(force: true));
    }
    if (mounted) _updateState(() => _seekDraft = null);
  }

  Future<void> _seekRelative(double deltaSeconds) async {
    await _seekAbsolute(_originalPlaybackSeconds + deltaSeconds);
  }

  Future<void> _showFullscreenPlayer() async {
    if (_controller?.value.isInitialized != true) return;
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
                        _controller == null || !_controller!.value.isInitialized
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: _controller!.value.aspectRatio > 0
                                ? _controller!.value.aspectRatio
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
                                } else if (_controller?.value.isPlaying ==
                                    true) {
                                  await _controller?.pause();
                                } else {
                                  await _controller?.play();
                                }
                              },
                              child: VideoPlayer(_controller!),
                            ),
                          ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _controller!,
                  builder: (context, _) {
                    final total = _originalPlaybackDuration;
                    final current = _originalPlaybackSeconds;
                    if (total <= 0) return const SizedBox(height: 20);
                    return Column(
                      children: [
                        Slider(
                          value: (draggedPosition ?? current).clamp(0.0, total),
                          max: total,
                          onChanged: _transcodeStarting
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
                      tooltip: _controller?.value.isPlaying == true
                          ? '暂停'
                          : '播放',
                      color: Colors.white,
                      onPressed: () {
                        final controller = _controller;
                        if (controller == null) return;
                        if (controller.value.isPlaying) {
                          unawaited(controller.pause());
                        } else {
                          unawaited(controller.play());
                        }
                        updateOverlay(() {});
                      },
                      icon: Icon(
                        _controller?.value.isPlaying == true
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

  Future<void> _markWatched({required bool completed}) async {
    final filmId = _film.id;
    try {
      final updated = CinemaFilm.fromJson(
        await widget.api.send(
          'POST',
          '/api/v2/cinema/$filmId/watched',
          body: <String, Object>{'completed': completed},
        ),
      );
      if (!mounted || _film.id != filmId) return;
      _updateState(() => _film = updated);
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (mounted) {
        _updateState(() => _metadataMessage = mediaErrorLabel(error));
      }
    }
  }

  Future<void> _restartFromBeginning() async {
    final controller = _controller;
    final session = _hlsSession;
    if (session != null) {
      await _startTranscode(
        start: 0,
        audio: session.audioTrack,
        quality: session.quality,
      );
      return;
    }
    if (controller != null) {
      await controller.seekTo(Duration.zero);
      await controller.play();
    }
  }

  void _onVideoChanged() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.hasError) {
      final message =
          '视频播放中断：${controller.value.errorDescription ?? '当前设备无法解码此格式。'}';
      if (mounted && _playbackMessage != message) {
        _updateState(() => _playbackMessage = message);
      }
      return;
    }
    if (mounted) {
      _updateState(() {});
    }
    final now = DateTime.now();
    final ended = controller.value.isCompleted;
    if (ended && !_completionSaved) {
      _completionSaved = true;
      final value = controller.value;
      final sessionStart = _hlsSession?.start ?? 0;
      final clock = cinemaPlaybackClock(
        value.position.inMilliseconds / 1000.0,
        value.duration.inMilliseconds / 1000.0,
        sessionStart: sessionStart,
        originalDuration: _film.durationSeconds,
      );
      // A still-growing HLS playlist can reach its temporary end well before
      // the real film. Do not mark watched or play the next episode then.
      unawaited(_onPlaybackCompleted(nearRealEnd: clock.nearEnd));
    } else if (now.difference(_progressQueue.lastQueuedAt) >=
        CinemaProgressSaveQueue.minimumInterval) {
      unawaited(_queueProgressSave(force: true));
    }
  }

  Future<void> _onPlaybackCompleted({required bool nearRealEnd}) async {
    final completedID = _film.id;
    final saved = await _queueProgressSave(force: true, completed: nearRealEnd);
    if (!nearRealEnd && mounted && !_closing) {
      _updateState(
        () => _playbackMessage = '当前转码片段已播放至末尾，但整部影片尚未结束。可等待转码继续，或调整播放进度。',
      );
    }
    if (nearRealEnd &&
        saved &&
        mounted &&
        !_closing &&
        _autoPlayNext &&
        _film.id == completedID) {
      await _goToNextEpisode(alreadySaved: true);
    }
  }

  Future<bool> _queueProgressSave({
    bool force = false,
    bool completed = false,
  }) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Future<bool>.value(true);
    }
    final value = controller.value;
    final offset = _hlsSession?.start ?? 0;
    final localSeconds = value.position.inMilliseconds / 1000.0;
    final playlistSeconds = value.duration.inMilliseconds / 1000.0;
    if (offset + playlistSeconds <= 0 ||
        !localSeconds.isFinite ||
        !playlistSeconds.isFinite) {
      return Future<bool>.value(true);
    }
    final clock = cinemaPlaybackClock(
      localSeconds,
      playlistSeconds,
      sessionStart: offset,
      originalDuration: _film.durationSeconds,
    );
    final isCompleted = completed || clock.nearEnd;
    final filmId = _film.id;
    return _progressQueue.save(() async {
      try {
        await widget.api.send(
          'PUT',
          '/api/v2/cinema/$filmId/progress',
          body: <String, Object>{
            'position': clock.position,
            'duration': clock.duration,
            'completed': isCompleted,
          },
        );
        if (mounted && _film.id == filmId) {
          final updated = _film.withProgress(
            newPosition: clock.position,
            newDuration: clock.duration,
            isCompleted: isCompleted,
          );
          _updateState(() {
            _film = updated;
            _progressSaveMessage = null;
          });
          widget.onProgressUpdated(updated);
        }
      } catch (_) {
        if (mounted && _film.id == filmId) {
          _updateState(() {
            _progressSaveMessage = '播放进度暂时未能保存，请检查连接后重试。';
          });
        }
        rethrow;
      }
    }, force: force);
  }

  Future<void> _loadSubtitles(String language) async {
    final generation = ++_subtitleGeneration;
    final filmId = _film.id;
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    _updateState(() {
      _captionLanguage = language;
      _subtitleMessage = null;
      _cues = const [];
    });
    if (language == 'off') return;
    try {
      final cues = await _subtitleRepository.load(filmId, language);
      if (!_subtitleRequestCurrent(generation, filmId, rootIdentity)) return;
      _updateState(() {
        _cues = cues;
        _subtitleMessage = cues.isEmpty ? '字幕文件没有可显示的内容。' : null;
      });
    } catch (error) {
      if (!_subtitleRequestCurrent(generation, filmId, rootIdentity)) return;
      _updateState(() {
        _subtitleMessage =
            error is LightIsleApiException && error.code == 'film_not_found'
            ? '未找到匹配字幕，或此影片已被移除。'
            : mediaErrorLabel(error);
      });
    }
  }

  bool _subtitleRequestCurrent(
    int generation,
    int filmId,
    String rootIdentity,
  ) =>
      mounted &&
      generation == _subtitleGeneration &&
      _film.id == filmId &&
      (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity;

  /// An optional, one-session subtitle source from this device.
  Future<void> _importLocalSubtitles() async {
    final generation = ++_subtitleGeneration;
    final filmId = _film.id;
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    try {
      final selected = await _subtitleRepository.importLocal();
      if (selected == null ||
          !_subtitleRequestCurrent(generation, filmId, rootIdentity)) {
        return;
      }
      _updateState(() {
        _captionLanguage = 'local';
        _cues = selected.cues;
        _subtitleMessage = '已加载：${selected.name}（仅本次播放）';
      });
    } catch (error) {
      if (_subtitleRequestCurrent(generation, filmId, rootIdentity)) {
        _updateState(
          () => _subtitleMessage = '无法加载字幕：${mediaErrorLabel(error)}',
        );
      }
    }
  }
}
