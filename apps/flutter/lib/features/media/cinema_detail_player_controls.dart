import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'cinema_detail_controller.dart';
import 'cinema_detail_player_menus.dart';
import 'shared_video_player_controls.dart';

/// Draggable bottom transport deck for the media-first cinema player route.
class CinemaBottomTransportDeck extends StatelessWidget {
  const CinemaBottomTransportDeck({
    super.key,
    required this.controller,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
  });

  final CinemaDetailController controller;
  final VoidCallback onPreviousEpisode;
  final VoidCallback onNextEpisode;

  static const Color _crimsonAccent = SharedVideoPlayerStyle.crimsonAccent;
  static const TextStyle _tabularTimeStyle =
      SharedVideoPlayerStyle.tabularTimeStyle;

  @override
  Widget build(BuildContext context) {
    final video = controller.playback.controller;
    if (video == null || !video.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final compactControls = SharedVideoPlayerStyle.isCompactWidth(context);
    final screenSize = MediaQuery.sizeOf(context);
    final buttonStyle = SharedVideoPlayerStyle.compactTransportIconStyle();
    final busy =
        controller.playback.transcodeStarting ||
        controller.playlistState.nextEpisodeBusy;

    final deck = SharedVideoTransportDeck(
      controller: video,
      wrapInSafeArea: false,
      outerPadding: EdgeInsets.zero,
      buttonStyle: buttonStyle,
      headerRow: _buildDockDragHandleRow(),
      seekBar: _buildTransportSeekBar(context, video),
      playing: video.value.isPlaying,
      busy: controller.playback.transcodeStarting,
      showPrevNext: controller.sameDirectoryFilms.length > 1,
      prevKey: const ValueKey('cinemaPlayerPrevButton'),
      nextKey: const ValueKey('cinemaPlayerNextButton'),
      onPrev: busy || controller.previousPlaylistFilm == null
          ? null
          : () {
              controller.revealChrome();
              onPreviousEpisode();
            },
      onNext: busy || controller.nextPlaylistFilm == null
          ? null
          : () {
              controller.revealChrome();
              onNextEpisode();
            },
      onTogglePlay: () =>
          unawaited(controller.togglePlayPause(revealChromeAfter: true)),
      onSeekBackward: () {
        controller.revealChrome();
        unawaited(controller.seekRelative(-10));
      },
      onSeekForward: () {
        controller.revealChrome();
        unawaited(controller.seekRelative(10));
      },
      muted: video.value.volume == 0,
      volume: video.value.volume,
      onToggleMute: () {
        unawaited(controller.toggleMuteShortcut());
        controller.revealChrome();
      },
      onVolumeChanged: (value) {
        unawaited(controller.setPlayerVolume(value));
        controller.revealChrome();
      },
      timeReadout: _buildTransportTimeReadout(video),
      rightClusterItems: _buildRightClusterItems(buttonStyle),
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
          offset: controller.chrome.dockDragOffset,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (details) =>
                controller.updateDockDragOffset(details.delta, screenSize),
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
          onDoubleTap: () => controller.resetDockDragOffset(reveal: true),
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
        if (controller.chrome.isDockMoved) ...[
          const SizedBox(width: 8),
          InkWell(
            onTap: () => controller.resetDockDragOffset(),
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
    VideoPlayerController video,
  ) {
    if (controller.playback.hlsSession != null) {
      return RepaintBoundary(
        child: AnimatedBuilder(
          animation: video,
          builder: (context, _) {
            final total = controller.originalPlaybackDuration;
            if (total <= 0) {
              return VideoProgressIndicator(
                video,
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
                  value:
                      (controller.playback.seekDraft ??
                              controller.originalPlaybackSeconds)
                          .clamp(0.0, total),
                  min: 0,
                  max: total,
                  onChanged: controller.playback.transcodeStarting
                      ? null
                      : (value) => controller.setSeekDraft(value, reveal: true),
                  onChangeEnd: (value) =>
                      unawaited(controller.seekAbsolute(value)),
                ),
              ),
            );
          },
        ),
      );
    }
    return SharedVideoProgressBar(controller: video);
  }

  Widget _buildTransportTimeReadout(VideoPlayerController video) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: video,
        builder: (context, _) {
          final currentStr = SharedVideoPlayerStyle.formatClock(
            Duration(
              milliseconds: (controller.originalPlaybackSeconds * 1000).round(),
            ),
          );
          final totalStr = SharedVideoPlayerStyle.formatClock(
            Duration(
              milliseconds: (controller.originalPlaybackDuration * 1000)
                  .round(),
            ),
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
    final active = controller.chrome.showPlaylistSheet;
    final items = controller.sameDirectoryFilms;
    return Semantics(
      button: true,
      label: '同目录播放列表',
      child: Tooltip(
        message: '同目录播放列表',
        child: InkWell(
          key: const ValueKey('cinemaPlayerPlaylistToggle'),
          borderRadius: BorderRadius.circular(999),
          onTap: controller.togglePlaylistSheet,
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
                      ? '播放列表 ${controller.currentPlaylistIndex + 1}/${items.length}'
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

  List<Widget> _buildRightClusterItems(ButtonStyle buttonStyle) {
    final hasMultiAudio =
        (controller.playback.tracks?.audio.length ?? 0) > 1 &&
        controller.playback.hlsSession != null;
    return [
      _buildPlaylistTogglePill(),
      CinemaCaptionMenuPill(controller: controller),
      CinemaQualityMenuPill(controller: controller),
      CinemaSpeedMenuPill(controller: controller),
      if (hasMultiAudio) CinemaAudioTrackMenuPill(controller: controller),
      IconButton(
        tooltip: controller.chrome.fillScreen ? '适应屏幕' : '铺满画面',
        style: buttonStyle,
        onPressed: controller.toggleFillScreen,
        icon: Icon(
          controller.chrome.fillScreen
              ? Icons.fit_screen_rounded
              : Icons.aspect_ratio_rounded,
          size: 19,
        ),
      ),
      if (controller.pip.supported)
        IconButton(
          tooltip: '画中画',
          style: buttonStyle,
          onPressed: () => unawaited(controller.enterPiP()),
          icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 19),
        ),
      IconButton(
        tooltip: controller.chrome.windowFullscreen ? '退出全屏' : '全屏播放',
        style: buttonStyle,
        onPressed: controller.playback.transcodeStarting
            ? null
            : () {
                controller.revealChrome();
                unawaited(controller.toggleFullscreen());
              },
        icon: Icon(
          controller.chrome.windowFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          size: 21,
        ),
      ),
      IconButton(
        key: const ValueKey('cinemaCollapseDockButton'),
        tooltip: '收起控制栏（避免遮挡字幕）',
        style: buttonStyle,
        onPressed: controller.collapseDock,
        icon: const Icon(Icons.visibility_off_outlined, size: 18),
      ),
    ];
  }
}
