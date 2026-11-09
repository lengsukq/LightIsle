part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerControls on _CinemaDetailDialogState {
  String get _captionShortLabel {
    switch (_captionLanguage) {
      case 'off':
        return '字幕';
      case 'auto':
        return '同名字幕';
      case 'zh':
        return '中文';
      case 'en':
        return '英文';
      case 'local':
        return '本机字幕';
      default:
        if (_captionLanguage.startsWith('emb:')) {
          final index = int.tryParse(_captionLanguage.substring(4));
          for (final track
              in _tracks?.subtitles ?? const <CinemaSubtitleTrack>[]) {
            if (track.streamIndex == index) return track.label;
          }
          return '内嵌字幕';
        }
        return '字幕';
    }
  }

  String get _qualityShortLabel {
    final current = _hlsSession?.quality ?? 'source';
    for (final option in _qualityOptions()) {
      if (option.$1 == current) return option.$2;
    }
    return '原画';
  }

  String get _speedShortLabel {
    if (_playbackSpeed == 1.0) return '1.0x';
    final text = _playbackSpeed
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    return '${text}x';
  }

  String get _audioShortLabel {
    final active = _hlsSession?.audioTrack ?? 0;
    for (final track in _tracks?.audio ?? const <CinemaAudioTrack>[]) {
      if (track.audioIndex == active) return track.label;
    }
    return '音轨';
  }

  PopupMenuItem<T> _buildPopupChoice<T>({
    required T value,
    required String label,
    required bool selected,
  }) => PopupMenuItem<T>(
    value: value,
    height: 36,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.check_rounded,
          size: 16,
          color: selected ? const Color(0xFFE50914) : Colors.transparent,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xD9FFFFFF),
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildPlayerMenuPill<T>({
    required String label,
    required String tooltip,
    required List<PopupMenuEntry<T>> items,
    required ValueChanged<T> onSelected,
    IconData? icon,
    bool active = false,
    bool enabled = true,
  }) => PopupMenuButton<T>(
    tooltip: tooltip,
    enabled: enabled,
    color: const Color(0xF2161A24),
    surfaceTintColor: Colors.transparent,
    elevation: 16,
    position: PopupMenuPosition.over,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Color(0x2EFFFFFF), width: 0.8),
    ),
    onSelected: (value) {
      _revealChrome();
      onSelected(value);
    },
    itemBuilder: (_) => items,
    child: Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? const Color(0x38FFFFFF) : const Color(0x1FFFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? const Color(0x4DFFFFFF) : const Color(0x24FFFFFF),
          width: 0.75,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 15,
            color: Colors.white70,
          ),
        ],
      ),
    ),
  );

  Widget _buildBottomTransportDeck(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compactControls =
        screenWidth < 640 || MediaQuery.textScalerOf(context).scale(14) > 20;
    const crimsonAccent = Color(0xFFE50914);
    const tabularTimeStyle = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: [ui.FontFeature.tabularFigures()],
    );

    final compactIconButtonStyle = IconButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white38,
      hoverColor: const Color(0x24FFFFFF),
      padding: const EdgeInsets.all(6),
      minimumSize: const Size(32, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    final playButton = IconButton(
      tooltip: controller.value.isPlaying ? '暂停' : '播放',
      style: compactIconButtonStyle,
      onPressed: () async {
        if (controller.value.isPlaying) {
          await controller.pause();
          unawaited(_queueProgressSave(force: true));
        } else {
          await controller.play();
        }
        _revealChrome();
        if (mounted) _updateState(() {});
      },
      icon: Icon(
        controller.value.isPlaying
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        size: 24,
      ),
    );

    final currentStr = _timeLabel(
      Duration(milliseconds: (_originalPlaybackSeconds * 1000).round()),
    );
    final totalStr = _timeLabel(
      Duration(milliseconds: (_originalPlaybackDuration * 1000).round()),
    );
    final timeReadout = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(currentStr, style: tabularTimeStyle),
        const Text(
          ' / ',
          style: TextStyle(color: Color(0x80FFFFFF), fontSize: 11.5),
        ),
        Text(
          totalStr,
          style: tabularTimeStyle.copyWith(color: const Color(0xB3FFFFFF)),
        ),
      ],
    );

    Widget seekBar = VideoProgressIndicator(
      controller,
      allowScrubbing: true,
      padding: const EdgeInsets.symmetric(vertical: 5),
      colors: const VideoProgressColors(
        playedColor: crimsonAccent,
        bufferedColor: Color(0x59FFFFFF),
        backgroundColor: Color(0x2EFFFFFF),
      ),
    );
    if (_hlsSession != null && _originalPlaybackDuration > 0) {
      final total = _originalPlaybackDuration;
      seekBar = Semantics(
        label: '原片完整进度',
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.5,
            activeTrackColor: crimsonAccent,
            inactiveTrackColor: const Color(0x33FFFFFF),
            thumbColor: Colors.white,
            overlayColor: crimsonAccent.withValues(alpha: 0.22),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          ),
          child: Slider(
            value: (_seekDraft ?? _originalPlaybackSeconds).clamp(0.0, total),
            min: 0,
            max: total,
            onChanged: _transcodeStarting
                ? null
                : (value) {
                    _revealChrome();
                    _updateState(() => _seekDraft = value);
                  },
            onChangeEnd: (value) => unawaited(_seekAbsolute(value)),
          ),
        ),
      );
    }

    final leftCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        playButton,
        if (_sameDirectoryFilms.length > 1) ...[
          IconButton(
            key: const ValueKey('cinemaPlayerPrevButton'),
            tooltip: '上一部',
            style: compactIconButtonStyle,
            onPressed: _transcodeStarting ||
                    _nextEpisodeBusy ||
                    _previousPlaylistFilm == null
                ? null
                : () {
                    _revealChrome();
                    unawaited(_goToPreviousEpisode());
                  },
            icon: const Icon(Icons.skip_previous_rounded, size: 21),
          ),
          IconButton(
            key: const ValueKey('cinemaPlayerNextButton'),
            tooltip: '下一部',
            style: compactIconButtonStyle,
            onPressed: _transcodeStarting ||
                    _nextEpisodeBusy ||
                    _nextPlaylistFilm == null
                ? null
                : () {
                    _revealChrome();
                    unawaited(_goToNextEpisode());
                  },
            icon: const Icon(Icons.skip_next_rounded, size: 21),
          ),
        ],
        const SizedBox(width: 2),
        IconButton(
          tooltip: '快退 10 秒',
          style: compactIconButtonStyle,
          onPressed: _transcodeStarting
              ? null
              : () {
                  _revealChrome();
                  unawaited(_seekRelative(-10));
                },
          icon: const Icon(Icons.replay_10_rounded, size: 19),
        ),
        IconButton(
          tooltip: '快进 10 秒',
          style: compactIconButtonStyle,
          onPressed: _transcodeStarting
              ? null
              : () {
                  _revealChrome();
                  unawaited(_seekRelative(10));
                },
          icon: const Icon(Icons.forward_10_rounded, size: 19),
        ),
        const SizedBox(width: 2),
        IconButton(
          tooltip: controller.value.volume == 0 ? '取消静音' : '静音',
          style: compactIconButtonStyle,
          onPressed: () {
            final current = controller.value.volume;
            if (current > 0) {
              _lastNonZeroVolume = current;
              unawaited(controller.setVolume(0));
            } else {
              unawaited(
                controller.setVolume(
                  _lastNonZeroVolume > 0 ? _lastNonZeroVolume : 1.0,
                ),
              );
            }
            _revealChrome();
          },
          icon: Icon(
            controller.value.volume == 0
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
            size: 18,
          ),
        ),
        if (!compactControls)
          Semantics(
            label: '音量',
            child: SizedBox(
              width: 78,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: const Color(0x38FFFFFF),
                  thumbColor: Colors.white,
                  overlayColor: const Color(0x24FFFFFF),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                ),
                child: Slider(
                  value: controller.value.volume.clamp(0.0, 1.0).toDouble(),
                  onChanged: (value) {
                    if (value > 0) {
                      _lastNonZeroVolume = value;
                    }
                    controller.setVolume(value);
                    _revealChrome();
                  },
                  semanticFormatterCallback: (value) =>
                      '音量 ${(value * 100).round()}%',
                ),
              ),
            ),
          ),
        const SizedBox(width: 8),
        timeReadout,
      ],
    );

    final rightCluster = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Semantics(
          button: true,
          label: '同目录播放列表',
          child: Tooltip(
            message: '同目录播放列表',
            child: InkWell(
              key: const ValueKey('cinemaPlayerPlaylistToggle'),
              borderRadius: BorderRadius.circular(999),
              onTap: _togglePlaylistSheet,
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: _showPlaylistSheet
                      ? const Color(0x47FFFFFF)
                      : const Color(0x1FFFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: _showPlaylistSheet
                        ? const Color(0x59FFFFFF)
                        : const Color(0x24FFFFFF),
                    width: 0.75,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.playlist_play_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _sameDirectoryFilms.length > 1
                          ? '播放列表 ${_currentPlaylistIndex + 1}/${_sameDirectoryFilms.length}'
                          : '播放列表',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _buildPlayerMenuPill<String>(
          icon: Icons.subtitles_outlined,
          label: _captionShortLabel,
          tooltip: '字幕与字号',
          active: _captionLanguage != 'off',
          onSelected: (value) {
            if (value == 'import') {
              unawaited(_importLocalSubtitles());
            } else if (value.startsWith('size:')) {
              final parsed = double.tryParse(value.substring(5));
              if (parsed != null) {
                _updateState(() => _subtitleFontSize = parsed);
              }
            } else if (value != 'local') {
              unawaited(_loadSubtitles(value));
            }
          },
          items: <PopupMenuEntry<String>>[
            _buildPopupChoice(
              value: 'off',
              label: '关闭字幕',
              selected: _captionLanguage == 'off',
            ),
            _buildPopupChoice(
              value: 'auto',
              label: '同名字幕',
              selected: _captionLanguage == 'auto',
            ),
            _buildPopupChoice(
              value: 'zh',
              label: '中文字幕',
              selected: _captionLanguage == 'zh',
            ),
            _buildPopupChoice(
              value: 'en',
              label: '英文字幕',
              selected: _captionLanguage == 'en',
            ),
            if (_captionLanguage == 'local')
              _buildPopupChoice(
                value: 'local',
                label: '本机字幕（当前）',
                selected: true,
              ),
            for (final track
                in _tracks?.subtitles ?? const <CinemaSubtitleTrack>[])
              if (track.extractable)
                _buildPopupChoice(
                  value: 'emb:${track.streamIndex}',
                  label: track.label,
                  selected: _captionLanguage == 'emb:${track.streamIndex}',
                ),
            const PopupMenuDivider(height: 8),
            const PopupMenuItem<String>(
              value: 'import',
              height: 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 15,
                    color: Colors.white70,
                  ),
                  SizedBox(width: 8),
                  Text(
                    '导入本机字幕…',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (_captionLanguage != 'off') ...[
              const PopupMenuDivider(height: 8),
              for (final (size, label) in const [
                (15.0, '字号：小'),
                (17.0, '字号：标准'),
                (21.0, '字号：大'),
                (25.0, '字号：特大'),
              ])
                _buildPopupChoice(
                  value: 'size:$size',
                  label: label,
                  selected: _subtitleFontSize == size,
                ),
            ],
          ],
        ),
        _buildPlayerMenuPill<String>(
          label: _qualityShortLabel,
          tooltip: '清晰度',
          enabled: !_transcodeStarting,
          onSelected: (value) => unawaited(_switchQuality(value)),
          items: <PopupMenuEntry<String>>[
            for (final option in _qualityOptions())
              _buildPopupChoice(
                value: option.$1,
                label: option.$2,
                selected: (_hlsSession?.quality ?? 'source') == option.$1,
              ),
          ],
        ),
        _buildPlayerMenuPill<double>(
          label: _speedShortLabel,
          tooltip: '播放倍速',
          active: _playbackSpeed != 1.0,
          onSelected: (speed) => unawaited(_setPlaybackSpeed(speed)),
          items: <PopupMenuEntry<double>>[
            for (final speed in const [0.75, 1.0, 1.25, 1.5, 2.0])
              _buildPopupChoice(
                value: speed,
                label: speed == 1.0 ? '1.0x（正常）' : '${speed}x',
                selected: _playbackSpeed == speed,
              ),
          ],
        ),
        if ((_tracks?.audio.length ?? 0) > 1 && _hlsSession != null)
          _buildPlayerMenuPill<int>(
            icon: Icons.graphic_eq_rounded,
            label: _audioShortLabel,
            tooltip: '音轨切换',
            onSelected: (value) => unawaited(_switchAudio(value)),
            items: <PopupMenuEntry<int>>[
              for (final track in _tracks?.audio ?? const <CinemaAudioTrack>[])
                _buildPopupChoice(
                  value: track.audioIndex,
                  label: track.label,
                  selected: _hlsSession!.audioTrack == track.audioIndex,
                ),
            ],
          ),
        IconButton(
          tooltip: _fillScreen ? '适应屏幕' : '铺满画面',
          style: compactIconButtonStyle,
          onPressed: () {
            _revealChrome();
            _updateState(() => _fillScreen = !_fillScreen);
          },
          icon: Icon(
            _fillScreen
                ? Icons.fit_screen_rounded
                : Icons.aspect_ratio_rounded,
            size: 19,
          ),
        ),
        if (_pip.supported)
          IconButton(
            tooltip: '画中画',
            style: compactIconButtonStyle,
            onPressed: _enterPiP,
            icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 19),
          ),
        IconButton(
          tooltip: _windowFullscreen ? '退出全屏' : '全屏播放',
          style: compactIconButtonStyle,
          onPressed: _transcodeStarting
              ? null
              : () {
                  _revealChrome();
                  unawaited(_toggleFullscreen());
                },
          icon: Icon(
            _windowFullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            size: 21,
          ),
        ),
      ],
    );

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Color(0xD9000000),
            Color(0x66000000),
            Colors.transparent,
          ],
          stops: [0.0, 0.6, 1.0],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compactControls ? 12 : 24,
            8,
            compactControls ? 12 : 24,
            compactControls ? 10 : 16,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: IsleGlassBackdrop(
                    blur: 24,
                    child: Container(
                      padding: EdgeInsets.fromLTRB(
                        compactControls ? 10 : 14,
                        6,
                        compactControls ? 10 : 14,
                        8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xB80E121A),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0x26FFFFFF),
                          width: 0.8,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: seekBar,
                          ),
                          const SizedBox(height: 2),
                          if (compactControls)
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [leftCluster, rightCluster],
                            )
                          else
                            Row(
                              children: [
                                leftCluster,
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: rightCluster,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
