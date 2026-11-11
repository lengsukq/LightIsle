part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerView on _CinemaDetailDialogState {
  String _timeLabel(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  SubtitleCue? get _activeCue {
    final position = _controller?.value.position;
    if (position == null) return null;
    final adjusted =
        position -
        Duration(milliseconds: (_subtitleOffsetSeconds * 1000).round());
    for (final cue in _cues) {
      if (cue.contains(adjusted)) return cue;
    }
    return null;
  }

  Widget _player(BuildContext context) {
    final controller = _controller;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (controller == null || !controller.value.isInitialized) {
      final canTranscode =
          !_film.canAttemptPlayback && _film.probeStatus != 'pending';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_transcodeStarting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                )
              else
                Icon(
                  Icons.video_file_outlined,
                  size: 44,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              const SizedBox(height: 12),
              Text(_playbackMessage ?? '此视频无法播放。', textAlign: TextAlign.center),
              if (canTranscode && !_transcodeStarting) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('cinemaTryLocalDecodeButton'),
                      onPressed: () => unawaited(
                        _loadDetailAndPlayer(
                          seekTo: _film.canResume ? _film.position : 0,
                          forceDirect: true,
                        ),
                      ),
                      icon: const Icon(Icons.memory_rounded, size: 17),
                      label: const Text('原画直传（本地解码）'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(
                        _startTranscode(
                          start: _film.canResume ? _film.position : 0,
                        ),
                      ),
                      icon: const Icon(Icons.auto_awesome, size: 17),
                      label: const Text('重试在线转码播放'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('cinemaOpenExternalPlayerButton'),
                      onPressed: () => unawaited(
                        showCinemaExternalPlayerDialog(
                          context,
                          api: widget.api,
                          film: _film,
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new_rounded, size: 17),
                      label: const Text('外部播放器打开'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }
    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    final compactControls =
        MediaQuery.sizeOf(context).width < 480 ||
        MediaQuery.textScalerOf(context).scale(14) > 20;
    final controlTextStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Colors.white);
    final playButton = IconButton(
      tooltip: controller.value.isPlaying ? '暂停' : '播放',
      color: Colors.white,
      onPressed: () async {
        if (controller.value.isPlaying) {
          await controller.pause();
          unawaited(_queueProgressSave(force: true));
        } else {
          await controller.play();
        }
        if (mounted) {
          _updateState(() {});
        }
      },
      icon: Icon(controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
    );
    final positionLabel = Text(
      _timeLabel(
        Duration(milliseconds: (_originalPlaybackSeconds * 1000).round()),
      ),
      style: controlTextStyle,
    );
    final durationLabel = Text(
      _timeLabel(
        Duration(milliseconds: (_originalPlaybackDuration * 1000).round()),
      ),
      style: controlTextStyle,
    );
    Widget seekBar = VideoProgressIndicator(
      controller,
      allowScrubbing: true,
      padding: const EdgeInsets.symmetric(vertical: 9),
      colors: VideoProgressColors(
        playedColor: Theme.of(context).colorScheme.primary,
        bufferedColor: Colors.white54,
        backgroundColor: Colors.white24,
      ),
    );
    if (_hlsSession != null && _originalPlaybackDuration > 0) {
      final total = _originalPlaybackDuration;
      seekBar = Semantics(
        label: '原片完整进度',
        child: Slider(
          value: (_seekDraft ?? _originalPlaybackSeconds).clamp(0.0, total),
          min: 0,
          max: total,
          onChanged: _transcodeStarting
              ? null
              : (value) => _updateState(() => _seekDraft = value),
          onChangeEnd: (value) => unawaited(_seekAbsolute(value)),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final videoHeight = (constraints.maxWidth / aspectRatio)
            .clamp(0.0, 400.0)
            .toDouble();
        final videoWidth = videoHeight * aspectRatio;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: constraints.maxWidth,
              height: videoHeight,
              child: Center(
                child: SizedBox(
                  width: videoWidth,
                  height: videoHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTapDown: (details) {
                          final x = details.localPosition.dx;
                          if (x < videoWidth * .4) {
                            unawaited(_seekRelative(-10));
                          } else if (x > videoWidth * .6) {
                            unawaited(_seekRelative(10));
                          } else if (controller.value.isPlaying) {
                            unawaited(controller.pause());
                          } else {
                            unawaited(controller.play());
                          }
                        },
                        child: VideoPlayer(controller),
                      ),
                      if (_activeCue case final cue?)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            margin: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .78),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              cue.text,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: _subtitleFontSize,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
              child: compactControls
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            playButton,
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    positionLabel,
                                    const SizedBox(width: 12),
                                    durationLabel,
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: seekBar,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        playButton,
                        positionLabel,
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: seekBar,
                          ),
                        ),
                        durationLabel,
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: '全屏播放',
                    color: Colors.white,
                    onPressed: _transcodeStarting
                        ? null
                        : () => unawaited(_showFullscreenPlayer()),
                    icon: const Icon(Icons.fullscreen),
                  ),
                  IconButton(
                    tooltip: '快退 10 秒',
                    color: Colors.white,
                    onPressed: _transcodeStarting
                        ? null
                        : () => unawaited(_seekRelative(-10)),
                    icon: const Icon(Icons.replay_10),
                  ),
                  IconButton(
                    tooltip: '快进 10 秒',
                    color: Colors.white,
                    onPressed: _transcodeStarting
                        ? null
                        : () => unawaited(_seekRelative(10)),
                    icon: const Icon(Icons.forward_10),
                  ),
                  Icon(
                    controller.value.volume == 0
                        ? Icons.volume_off
                        : Icons.volume_up,
                    size: 19,
                    color: Colors.white,
                  ),
                  Semantics(
                    label: '音量',
                    child: SizedBox(
                      width: 110,
                      child: Slider(
                        value: controller.value.volume
                            .clamp(0.0, 1.0)
                            .toDouble(),
                        onChanged: (value) => controller.setVolume(value),
                        activeColor: Theme.of(context).colorScheme.primary,
                        inactiveColor: Colors.white38,
                        semanticFormatterCallback: (value) =>
                            '音量 ${(value * 100).round()}%',
                      ),
                    ),
                  ),
                  DropdownButton<String>(
                    value: _captionLanguage,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Colors.white),
                    dropdownColor: const Color(0xFF202124),
                    iconEnabledColor: Colors.white,
                    iconDisabledColor: Colors.white54,
                    underline: const SizedBox.shrink(),
                    hint: const Text(
                      '字幕',
                      style: TextStyle(color: Colors.white70),
                    ),
                    onChanged: (value) {
                      if (value == 'import') {
                        unawaited(_importLocalSubtitles());
                      } else if (value != null && value != 'local') {
                        unawaited(_loadSubtitles(value));
                      }
                    },
                    items: <DropdownMenuItem<String>>[
                      const DropdownMenuItem(
                        value: 'off',
                        child: Text(
                          '关闭字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'auto',
                        child: Text(
                          '同名字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'zh',
                        child: Text(
                          '中文字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'en',
                        child: Text(
                          '英文字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      if (_captionLanguage == 'local')
                        const DropdownMenuItem(
                          value: 'local',
                          child: Text(
                            '本机字幕',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      const DropdownMenuItem(
                        value: 'import',
                        child: Text(
                          '导入字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      for (final track
                          in _tracks?.subtitles ??
                              const <CinemaSubtitleTrack>[])
                        if (track.extractable)
                          DropdownMenuItem(
                            value: 'emb:${track.streamIndex}',
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                    ],
                  ),
                  if (_captionLanguage != 'off')
                    DropdownButton<double>(
                      value: _subtitleFontSize,
                      dropdownColor: const Color(0xFF202124),
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      onChanged: (size) {
                        if (size != null) {
                          _updateState(() => _subtitleFontSize = size);
                        }
                      },
                      items: const [
                        DropdownMenuItem(value: 15.0, child: Text('字幕 小')),
                        DropdownMenuItem(value: 17.0, child: Text('字幕 标准')),
                        DropdownMenuItem(value: 21.0, child: Text('字幕 大')),
                        DropdownMenuItem(value: 25.0, child: Text('字幕 特大')),
                      ],
                    ),
                  DropdownButton<String>(
                    value: _currentQualityKey,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Colors.white),
                    dropdownColor: const Color(0xFF202124),
                    iconEnabledColor: Colors.white,
                    iconDisabledColor: Colors.white54,
                    underline: const SizedBox.shrink(),
                    hint: const Text(
                      '清晰度',
                      style: TextStyle(color: Colors.white70),
                    ),
                    onChanged: (value) {
                      if (value != null) unawaited(_switchQuality(value));
                    },
                    items: <DropdownMenuItem<String>>[
                      for (final option in _qualityOptions())
                        DropdownMenuItem(
                          value: option.$1,
                          child: Text(
                            option.$2,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                  MediaPlaybackSpeedPicker(
                    value: _playbackSpeed,
                    onChanged: (speed) => unawaited(_setPlaybackSpeed(speed)),
                  ),
                  if ((_tracks?.audio.length ?? 0) > 1 && _hlsSession != null)
                    DropdownButton<int>(
                      value: _hlsSession!.audioTrack,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      dropdownColor: const Color(0xFF202124),
                      iconEnabledColor: Colors.white,
                      iconDisabledColor: Colors.white54,
                      underline: const SizedBox.shrink(),
                      hint: const Text(
                        '音轨',
                        style: TextStyle(color: Colors.white70),
                      ),
                      onChanged: (value) {
                        if (value != null) unawaited(_switchAudio(value));
                      },
                      items: <DropdownMenuItem<int>>[
                        for (final track
                            in _tracks?.audio ?? const <CinemaAudioTrack>[])
                          DropdownMenuItem(
                            value: track.audioIndex,
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _fullscreenStage(BuildContext context) {
    final controller = _controller;
    if (_loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 2.6,
          ),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      final canTranscode =
          !_film.canAttemptPlayback && _film.probeStatus != 'pending';
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_transcodeStarting)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      ),
                    )
                  else
                    const Icon(
                      Icons.video_file_outlined,
                      size: 48,
                      color: Colors.white60,
                    ),
                  const SizedBox(height: 14),
                  Text(
                    _playbackMessage ?? '此视频无法播放。',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                  if (canTranscode && !_transcodeStarting) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          key: const ValueKey(
                            'cinemaStageTryLocalDecodeButton',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0x2EFFFFFF),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => unawaited(
                            _loadDetailAndPlayer(
                              seekTo: _film.canResume ? _film.position : 0,
                              forceDirect: true,
                            ),
                          ),
                          icon: const Icon(Icons.memory_rounded, size: 17),
                          label: const Text('原画直传（本地解码）'),
                        ),
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0x2EFFFFFF),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => unawaited(
                            _startTranscode(
                              start: _film.canResume ? _film.position : 0,
                            ),
                          ),
                          icon: const Icon(Icons.auto_awesome, size: 17),
                          label: const Text('重试在线转码播放'),
                        ),
                        FilledButton.tonalIcon(
                          key: const ValueKey(
                            'cinemaStageExternalPlayerButton',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0x2EFFFFFF),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => unawaited(
                            showCinemaExternalPlayerDialog(
                              context,
                              api: widget.api,
                              film: _film,
                            ),
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 17),
                          label: const Text('外部播放器打开'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    final showChrome =
        _chromeVisible ||
        !controller.value.isPlaying ||
        _showPlayerDetails ||
        _progressSaveMessage != null ||
        _offlineProgress != null;

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stageWidth = constraints.maxWidth;
          final videoWidget = _fillScreen
              ? SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: aspectRatio * 1000,
                      height: 1000,
                      child: VideoPlayer(controller),
                    ),
                  ),
                )
              : Center(
                  child: AspectRatio(
                    aspectRatio: aspectRatio,
                    child: VideoPlayer(controller),
                  ),
                );

          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleChrome,
                onDoubleTapDown: (details) {
                  final x = details.localPosition.dx;
                  if (x < stageWidth * .35) {
                    _revealChrome();
                    unawaited(_seekRelative(-10));
                  } else if (x > stageWidth * .65) {
                    _revealChrome();
                    unawaited(_seekRelative(10));
                  } else if (controller.value.isPlaying) {
                    unawaited(controller.pause());
                    unawaited(_queueProgressSave(force: true));
                    _revealChrome();
                  } else {
                    unawaited(controller.play());
                    _revealChrome();
                  }
                },
                child: videoWidget,
              ),
              if (!controller.value.isPlaying && !_transcodeStarting)
                Center(
                  child: GestureDetector(
                    onTap: () {
                      unawaited(controller.play());
                      _revealChrome();
                    },
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 24,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: IsleGlassBackdrop(
                          blur: 20,
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: const Color(0x960B0E14),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0x42FFFFFF),
                                width: 1.0,
                              ),
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 38,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_activeCue case final cue?)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: showChrome ? 98 : 32,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .76),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          cue.text,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: _subtitleFontSize,
                            height: 1.3,
                            shadows: const [
                              Shadow(
                                color: Colors.black,
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
