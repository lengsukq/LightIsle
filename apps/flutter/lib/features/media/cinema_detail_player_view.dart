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
    for (final cue in _cues) {
      if (cue.contains(position)) return cue;
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
                OutlinedButton.icon(
                  onPressed: () => unawaited(
                    _startTranscode(
                      start: _film.canResume ? _film.position : 0,
                    ),
                  ),
                  icon: const Icon(Icons.auto_awesome, size: 17),
                  label: const Text('重试在线转码播放'),
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
                    value: _hlsSession?.quality ?? 'source',
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
}
