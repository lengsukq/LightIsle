part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerControls on _CinemaDetailDialogState {
  static const Color _crimsonAccent = SharedVideoPlayerStyle.crimsonAccent;
  static const TextStyle _tabularTimeStyle =
      SharedVideoPlayerStyle.tabularTimeStyle;

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

  ButtonStyle get _compactTransportIconStyle =>
      SharedVideoPlayerStyle.compactTransportIconStyle();

  PopupMenuItem<T> _buildPopupChoice<T>({
    required T value,
    required String label,
    required bool selected,
  }) => buildSharedPlayerPopupChoice<T>(
    value: value,
    label: label,
    selected: selected,
  );

  Widget _buildPlayerMenuPill<T>({
    required String label,
    required String tooltip,
    required List<PopupMenuEntry<T>> items,
    required ValueChanged<T> onSelected,
    IconData? icon,
    bool active = false,
    bool enabled = true,
  }) => SharedPlayerMenuPill<T>(
    label: label,
    tooltip: tooltip,
    items: items,
    onSelected: (value) {
      _revealChrome();
      onSelected(value);
    },
    icon: icon,
    active: active,
    enabled: enabled,
  );

  Widget _buildBottomTransportDeck(BuildContext context) {
    final controller = _playback.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final compactControls = SharedVideoPlayerStyle.isCompactWidth(context);
    final screenSize = MediaQuery.sizeOf(context);
    final buttonStyle = _compactTransportIconStyle;
    final busy = _playback.transcodeStarting || _playlistState.nextEpisodeBusy;
    final deck = SharedVideoTransportDeck(
      controller: controller,
      wrapInSafeArea: false,
      outerPadding: EdgeInsets.zero,
      buttonStyle: buttonStyle,
      headerRow: _buildDockDragHandleRow(),
      seekBar: _buildTransportSeekBar(context, controller),
      playing: controller.value.isPlaying,
      busy: _playback.transcodeStarting,
      showPrevNext: _sameDirectoryFilms.length > 1,
      prevKey: const ValueKey('cinemaPlayerPrevButton'),
      nextKey: const ValueKey('cinemaPlayerNextButton'),
      onPrev: busy || _previousPlaylistFilm == null
          ? null
          : () {
              _revealChrome();
              unawaited(_goToPreviousEpisode());
            },
      onNext: busy || _nextPlaylistFilm == null
          ? null
          : () {
              _revealChrome();
              unawaited(_goToNextEpisode());
            },
      onTogglePlay: () async {
        if (controller.value.isPlaying) {
          await controller.pause();
          unawaited(_queueProgressSave(force: true));
        } else {
          await controller.play();
        }
        _revealChrome();
        if (mounted) _updateState(() {});
      },
      onSeekBackward: () {
        _revealChrome();
        unawaited(_seekRelative(-10));
      },
      onSeekForward: () {
        _revealChrome();
        unawaited(_seekRelative(10));
      },
      muted: controller.value.volume == 0,
      volume: controller.value.volume,
      onToggleMute: () {
        unawaited(_toggleMuteShortcut());
        _revealChrome();
      },
      onVolumeChanged: (value) {
        unawaited(_setPlayerVolume(value));
        _revealChrome();
      },
      timeReadout: _buildTransportTimeReadout(),
      rightClusterItems: _buildTransportRightClusterItems(buttonStyle),
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compactControls ? 12 : 24,
          8,
          compactControls ? 12 : 24,
          compactControls ? 10 : 16,
        ),
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
            child: deck,
          ),
        ),
      ),
    );
  }

  Widget _buildDockDragHandleRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () {
            _revealChrome();
            _updateState(() => _chrome.dockDragOffset = Offset.zero);
          },
          child: Tooltip(
            message: '按住拖动控制栏位置，双击复位',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0x4DFFFFFF),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
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
    if (_playback.hlsSession != null) {
      return RepaintBoundary(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final total = _originalPlaybackDuration;
            if (total <= 0) {
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
            return Semantics(
              label: '原片完整进度',
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3.5,
                  activeTrackColor: _crimsonAccent,
                  inactiveTrackColor: const Color(0x33FFFFFF),
                  thumbColor: Colors.white,
                  overlayColor: _crimsonAccent.withValues(alpha: 0.22),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5.5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10,
                  ),
                ),
                child: Slider(
                  value: (_playback.seekDraft ?? _originalPlaybackSeconds)
                      .clamp(0.0, total),
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
          },
        ),
      );
    }
    return SharedVideoProgressBar(controller: controller);
  }

  Widget _buildTransportTimeReadout() {
    final controller = _playback.controller;
    if (controller == null) return const SizedBox.shrink();
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
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
                style: _tabularTimeStyle.copyWith(
                  color: const Color(0xB3FFFFFF),
                ),
              ),
            ],
          );
        },
      ),
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

  List<Widget> _buildTransportRightClusterItems(ButtonStyle buttonStyle) {
    final hasMultiAudio =
        (_playback.tracks?.audio.length ?? 0) > 1 &&
        _playback.hlsSession != null;
    return [
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
    ];
  }
}
