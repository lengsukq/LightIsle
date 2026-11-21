import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/widgets.dart';
import 'cinema_decode_preference.dart';
import 'cinema_detail_controller.dart';
import 'cinema_detail_player_shortcuts.dart';
import 'media_models.dart';
import 'shared_video_player_controls.dart';

/// Full-bleed video playback stage with tap/double-tap gestures, center play
/// overlay, shortcut HUD pill, subtitle rendering, and unplayable fallback.
class CinemaFullscreenStage extends StatelessWidget {
  const CinemaFullscreenStage({super.key, required this.controller});

  final CinemaDetailController controller;

  @override
  Widget build(BuildContext context) {
    final video = controller.playback.controller;
    if (controller.playback.loading) {
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
    if (video == null || !video.value.isInitialized) {
      return _buildUnplayableFallback(context);
    }

    final aspectRatio = video.value.aspectRatio > 0
        ? video.value.aspectRatio
        : 16 / 9;
    final showChrome =
        !controller.chrome.dockManuallyCollapsed &&
        (controller.chrome.visible ||
            !video.value.isPlaying ||
            controller.chrome.showPlayerDetails ||
            controller.playback.progressSaveMessage != null ||
            controller.externalActions.offlineProgress != null);
    final dockNearBottom = controller.chrome.dockDragOffset.dy > -56;

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stageWidth = constraints.maxWidth;
          final videoWidget = controller.chrome.fillScreen
              ? SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: aspectRatio * 1000,
                      height: 1000,
                      child: VideoPlayer(video),
                    ),
                  ),
                )
              : Center(
                  child: AspectRatio(
                    aspectRatio: aspectRatio,
                    child: VideoPlayer(video),
                  ),
                );
          final cue = controller.activeCue;

          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!controller.chrome.playerFocusNode.hasFocus) {
                    controller.chrome.playerFocusNode.requestFocus();
                  }
                  if (controller.chrome.dockManuallyCollapsed) {
                    controller.restoreDock();
                    return;
                  }
                  controller.toggleChrome();
                },
                onDoubleTapDown: (details) {
                  final x = details.localPosition.dx;
                  if (x < stageWidth * .35) {
                    controller.revealChrome();
                    unawaited(controller.seekRelative(-10));
                  } else if (x > stageWidth * .65) {
                    controller.revealChrome();
                    unawaited(controller.seekRelative(10));
                  } else if (video.value.isPlaying) {
                    unawaited(video.pause());
                    unawaited(controller.queueProgressSave(force: true));
                    controller.revealChrome();
                  } else {
                    unawaited(video.play());
                    controller.revealChrome();
                  }
                },
                child: videoWidget,
              ),
              if (!video.value.isPlaying &&
                  !controller.playback.transcodeStarting &&
                  !controller.chrome.dockManuallyCollapsed)
                _buildCenterPlayOverlay(video),
              CinemaPlayerShortcutHud(hud: controller.hud),
              if (cue != null)
                _buildSubtitleOverlay(
                  cue,
                  elevateAboveDock: showChrome && dockNearBottom,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildUnplayableFallback(BuildContext context) {
    final film = controller.film;
    final canRecover = film.probeStatus != 'pending';
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
                if (controller.playback.transcodeStarting)
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
                  controller.playback.playbackMessage ??
                      '此视频无法在当前浏览器/内置解码器中播放，原始文件安全未受影响。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                if (canRecover && !controller.playback.transcodeStarting) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      if (!controller.playback.directLocalActive)
                        FilledButton.tonalIcon(
                          key: const ValueKey(
                            'cinemaStageTryLocalDecodeButton',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0x2EFFFFFF),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => unawaited(
                            controller.loadDetailAndPlayer(
                              seekTo: film.canResume ? film.position : 0,
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
                          controller.startTranscode(
                            start: film.canResume ? film.position : 0,
                          ),
                        ),
                        icon: const Icon(Icons.auto_awesome, size: 17),
                        label: const Text('重试在线转码播放'),
                      ),
                      FilledButton.tonalIcon(
                        key: const ValueKey('cinemaStageExternalPlayerButton'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0x2EFFFFFF),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => unawaited(
                          showCinemaExternalPlayerDialog(
                            context,
                            api: controller.api,
                            film: film,
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

  Widget _buildCenterPlayOverlay(VideoPlayerController video) {
    return Center(
      child: GestureDetector(
        onTap: () {
          unawaited(video.play());
          controller.revealChrome();
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
    );
  }

  Widget _buildSubtitleOverlay(
    SubtitleCue cue, {
    required bool elevateAboveDock,
  }) {
    return Positioned(
      left: 24,
      right: 24,
      bottom: elevateAboveDock ? 98 : 32,
      child: Center(
        child: SharedVideoSubtitleOverlay(
          text: cue.text,
          fontSize: controller.subtitles.fontSize,
        ),
      ),
    );
  }
}
