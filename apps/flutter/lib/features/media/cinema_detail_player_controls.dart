part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerControls on _CinemaDetailDialogState {
  static const Color _crimsonAccent = Color(0xFFE50914);
  static const TextStyle _tabularTimeStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontFeatures: [ui.FontFeature.tabularFigures()],
  );

  String get _captionShortLabel {
    final lang = _subtitles.captionLanguage;
    switch (lang) {
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
        if (lang.startsWith('emb:')) {
          final index = int.tryParse(lang.substring(4));
          for (final track
              in _playback.tracks?.subtitles ?? const <CinemaSubtitleTrack>[]) {
            if (track.streamIndex == index) return track.label;
          }
          return '内嵌字幕';
        }
        return '字幕';
    }
  }

  String get _qualityShortLabel {
    final current = _currentQualityKey;
    for (final option in _qualityOptions()) {
      if (option.$1 == current) return option.$2;
    }
    return '原画';
  }

  String get _speedShortLabel {
    final speed = _playback.playbackSpeed;
    if (speed == 1.0) return '1.0x';
    final text = speed
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    return '${text}x';
  }

  String get _audioShortLabel {
    final active = _playback.hlsSession?.audioTrack ?? 0;
    for (final track in _playback.tracks?.audio ?? const <CinemaAudioTrack>[]) {
      if (track.audioIndex == active) return track.label;
    }
    return '音轨';
  }

  ButtonStyle get _compactTransportIconStyle => IconButton.styleFrom(
    foregroundColor: Colors.white,
    disabledForegroundColor: Colors.white38,
    hoverColor: const Color(0x24FFFFFF),
    padding: const EdgeInsets.all(6),
    minimumSize: const Size(32, 32),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

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
          color: selected ? _crimsonAccent : Colors.transparent,
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
    final controller = _playback.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compactControls =
        screenWidth < 640 || MediaQuery.textScalerOf(context).scale(14) > 20;
    final buttonStyle = _compactTransportIconStyle;
    final leftCluster = _buildTransportLeftCluster(
      context,
      controller,
      buttonStyle,
      compactControls: compactControls,
    );
    final rightCluster = _buildTransportRightCluster(buttonStyle);

    return _buildDraggableDockShell(
      context: context,
      compactControls: compactControls,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDockDragHandleRow(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _buildTransportSeekBar(context, controller),
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
    );
  }

  Widget _buildDraggableDockShell({
    required BuildContext context,
    required bool compactControls,
    required Widget child,
  }) {
    final screenSize = MediaQuery.sizeOf(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compactControls ? 12 : 24,
          8,
          compactControls ? 12 : 24,
          compactControls ? 10 : 16,
        ),
        child: Center(
          child: Transform.translate(
            offset: _chrome.dockDragOffset,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (details) {
                _revealChrome();
                final maxDx = ((screenSize.width - 320) / 2).clamp(
                  0.0,
                  screenSize.width,
                );
                final minDy = -(screenSize.height - 160).clamp(
                  0.0,
                  screenSize.height,
                );
                _updateState(() {
                  _chrome.dockDragOffset = Offset(
                    (_chrome.dockDragOffset.dx + details.delta.dx).clamp(
                      -maxDx,
                      maxDx,
                    ),
                    (_chrome.dockDragOffset.dy + details.delta.dy).clamp(
                      minDy,
                      12.0,
                    ),
                  );
                });
              },
              onDoubleTap: () {
                _revealChrome();
                _updateState(() => _chrome.dockDragOffset = Offset.zero);
              },
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
                          4,
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
                        child: child,
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

  Widget _buildDockDragHandleRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Tooltip(
          message: '按住拖动控制栏位置，双击复位',
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0x4DFFFFFF),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        if (_chrome.isDockMoved) ...[
          const SizedBox(width: 8),
          InkWell(
            onTap: () =>
                _updateState(() => _chrome.dockDragOffset = Offset.zero),
            child: const Text(
              '复位',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTransportSeekBar(
    BuildContext context,
    VideoPlayerController controller,
  ) {
    if (_playback.hlsSession != null && _originalPlaybackDuration > 0) {
      final total = _originalPlaybackDuration;
      return Semantics(
        label: '原片完整进度',
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.5,
            activeTrackColor: _crimsonAccent,
            inactiveTrackColor: const Color(0x33FFFFFF),
            thumbColor: Colors.white,
            overlayColor: _crimsonAccent.withValues(alpha: 0.22),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          ),
          child: Slider(
            value: (_playback.seekDraft ?? _originalPlaybackSeconds).clamp(
              0.0,
              total,
            ),
            min: 0,
            max: total,
            onChanged: _playback.transcodeStarting
                ? null
                : (value) {
                    _revealChrome();
                    _updateState(() => _playback.seekDraft = value);
                  },
            onChangeEnd: (value) => unawaited(_seekAbsolute(value)),
          ),
        ),
      );
    }
    return VideoProgressIndicator(
      controller,
      allowScrubbing: true,
      padding: const EdgeInsets.symmetric(vertical: 5),
      colors: const VideoProgressColors(
        playedColor: _crimsonAccent,
        bufferedColor: Color(0x59FFFFFF),
        backgroundColor: Color(0x2EFFFFFF),
      ),
    );
  }

  Widget _buildTransportPlayButton(
    VideoPlayerController controller,
    ButtonStyle buttonStyle,
  ) {
    return IconButton(
      tooltip: controller.value.isPlaying ? '暂停' : '播放',
      style: buttonStyle,
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
  }

  Widget _buildTransportTimeReadout() {
    final currentStr = _timeLabel(
      Duration(milliseconds: (_originalPlaybackSeconds * 1000).round()),
    );
    final totalStr = _timeLabel(
      Duration(milliseconds: (_originalPlaybackDuration * 1000).round()),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(currentStr, style: _tabularTimeStyle),
        const Text(
          ' / ',
          style: TextStyle(color: Color(0x80FFFFFF), fontSize: 11.5),
        ),
        Text(
          totalStr,
          style: _tabularTimeStyle.copyWith(color: const Color(0xB3FFFFFF)),
        ),
      ],
    );
  }

  List<Widget> _buildTransportVolumeWidgets(
    BuildContext context,
    VideoPlayerController controller,
    ButtonStyle buttonStyle, {
    required bool compactControls,
  }) {
    return [
      IconButton(
        tooltip: controller.value.volume == 0 ? '取消静音' : '静音',
        style: buttonStyle,
        onPressed: () {
          final current = controller.value.volume;
          if (current > 0) {
            _playback.lastNonZeroVolume = current;
            unawaited(controller.setVolume(0));
          } else {
            unawaited(
              controller.setVolume(
                _playback.lastNonZeroVolume > 0
                    ? _playback.lastNonZeroVolume
                    : 1.0,
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
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
              ),
              child: Slider(
                value: controller.value.volume.clamp(0.0, 1.0).toDouble(),
                onChanged: (value) {
                  if (value > 0) {
                    _playback.lastNonZeroVolume = value;
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
    ];
  }

  Widget _buildTransportLeftCluster(
    BuildContext context,
    VideoPlayerController controller,
    ButtonStyle buttonStyle, {
    required bool compactControls,
  }) {
    final busy = _playback.transcodeStarting || _playlistState.nextEpisodeBusy;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTransportPlayButton(controller, buttonStyle),
        if (_sameDirectoryFilms.length > 1) ...[
          IconButton(
            key: const ValueKey('cinemaPlayerPrevButton'),
            tooltip: '上一部',
            style: buttonStyle,
            onPressed: busy || _previousPlaylistFilm == null
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
            style: buttonStyle,
            onPressed: busy || _nextPlaylistFilm == null
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
          style: buttonStyle,
          onPressed: _playback.transcodeStarting
              ? null
              : () {
                  _revealChrome();
                  unawaited(_seekRelative(-10));
                },
          icon: const Icon(Icons.replay_10_rounded, size: 19),
        ),
        IconButton(
          tooltip: '快进 10 秒',
          style: buttonStyle,
          onPressed: _playback.transcodeStarting
              ? null
              : () {
                  _revealChrome();
                  unawaited(_seekRelative(10));
                },
          icon: const Icon(Icons.forward_10_rounded, size: 19),
        ),
        const SizedBox(width: 2),
        ..._buildTransportVolumeWidgets(
          context,
          controller,
          buttonStyle,
          compactControls: compactControls,
        ),
        const SizedBox(width: 8),
        _buildTransportTimeReadout(),
      ],
    );
  }

  Widget _buildPlaylistTogglePill() {
    final active = _chrome.showPlaylistSheet;
    final items = _sameDirectoryFilms;
    return Semantics(
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
              color: active ? const Color(0x47FFFFFF) : const Color(0x1FFFFFFF),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: active
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
                  items.length > 1
                      ? '播放列表 ${_currentPlaylistIndex + 1}/${items.length}'
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
    );
  }

  Widget _buildTransportRightCluster(ButtonStyle buttonStyle) {
    final hasMultiAudio =
        (_playback.tracks?.audio.length ?? 0) > 1 &&
        _playback.hlsSession != null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildPlaylistTogglePill(),
        _buildCaptionMenuPill(),
        _buildQualityMenuPill(),
        _buildSpeedMenuPill(),
        if (hasMultiAudio) _buildAudioTrackMenuPill(),
        IconButton(
          tooltip: _chrome.fillScreen ? '适应屏幕' : '铺满画面',
          style: buttonStyle,
          onPressed: () {
            _revealChrome();
            _updateState(() => _chrome.fillScreen = !_chrome.fillScreen);
          },
          icon: Icon(
            _chrome.fillScreen
                ? Icons.fit_screen_rounded
                : Icons.aspect_ratio_rounded,
            size: 19,
          ),
        ),
        if (_pip.supported)
          IconButton(
            tooltip: '画中画',
            style: buttonStyle,
            onPressed: _enterPiP,
            icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 19),
          ),
        IconButton(
          tooltip: _chrome.windowFullscreen ? '退出全屏' : '全屏播放',
          style: buttonStyle,
          onPressed: _playback.transcodeStarting
              ? null
              : () {
                  _revealChrome();
                  unawaited(_toggleFullscreen());
                },
          icon: Icon(
            _chrome.windowFullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            size: 21,
          ),
        ),
        IconButton(
          key: const ValueKey('cinemaCollapseDockButton'),
          tooltip: '收起控制栏（避免遮挡字幕）',
          style: buttonStyle,
          onPressed: () {
            _chrome.cancelTimer();
            _updateState(() {
              _chrome.dockManuallyCollapsed = true;
              _chrome.visible = false;
            });
          },
          icon: const Icon(Icons.visibility_off_outlined, size: 18),
        ),
      ],
    );
  }
}
