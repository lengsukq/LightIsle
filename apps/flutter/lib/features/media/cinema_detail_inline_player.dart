import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'cinema_decode_preference.dart';
import 'cinema_detail_controller.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'shared_video_player_controls.dart';

/// Embedded inline player rendered inside the legacy cinema detail dialog.
class CinemaInlinePlayerView extends StatelessWidget {
  const CinemaInlinePlayerView({super.key, required this.controller});

  final CinemaDetailController controller;

  @override
  Widget build(BuildContext context) {
    final video = controller.playback.controller;
    if (controller.playback.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (video == null || !video.value.isInitialized) {
      return _buildUnplayableFallback(context);
    }
    final aspectRatio = video.value.aspectRatio > 0
        ? video.value.aspectRatio
        : 16 / 9;
    return LayoutBuilder(
      builder: (context, constraints) {
        final videoHeight = (constraints.maxWidth / aspectRatio)
            .clamp(0.0, 400.0)
            .toDouble();
        final videoWidth = videoHeight * aspectRatio;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildVideoStage(
              video,
              maxWidth: constraints.maxWidth,
              videoWidth: videoWidth,
              videoHeight: videoHeight,
            ),
            _buildProgressRow(context, video),
            _buildToolbar(context, video),
          ],
        );
      },
    );
  }

  Widget _buildUnplayableFallback(BuildContext context) {
    final film = controller.film;
    final canTranscode =
        !film.canAttemptPlayback && film.probeStatus != 'pending';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.playback.transcodeStarting)
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
            Text(
              controller.playback.playbackMessage ?? '此视频无法播放。',
              textAlign: TextAlign.center,
            ),
            if (canTranscode && !controller.playback.transcodeStarting) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('cinemaTryLocalDecodeButton'),
                    onPressed: () => unawaited(
                      controller.loadDetailAndPlayer(
                        seekTo: film.canResume ? film.position : 0,
                        forceDirect: true,
                      ),
                    ),
                    icon: const Icon(Icons.memory_rounded, size: 17),
                    label: const Text('原画直传（本地解码）'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      controller.startTranscode(
                        start: film.canResume ? film.position : 0,
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
    );
  }

  Widget _buildVideoStage(
    VideoPlayerController video, {
    required double maxWidth,
    required double videoWidth,
    required double videoHeight,
  }) {
    final cue = controller.activeCue;
    return SizedBox(
      width: maxWidth,
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
                    unawaited(controller.seekRelative(-10));
                  } else if (x > videoWidth * .6) {
                    unawaited(controller.seekRelative(10));
                  } else if (video.value.isPlaying) {
                    unawaited(video.pause());
                  } else {
                    unawaited(video.play());
                  }
                },
                child: VideoPlayer(video),
              ),
              if (cue != null)
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
                        fontSize: controller.subtitles.fontSize,
                        height: 1.25,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressRow(BuildContext context, VideoPlayerController video) {
    final compactControls =
        MediaQuery.sizeOf(context).width < 480 ||
        MediaQuery.textScalerOf(context).scale(14) > 20;
    final controlTextStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Colors.white);
    final playButton = IconButton(
      tooltip: video.value.isPlaying ? '暂停' : '播放',
      color: Colors.white,
      onPressed: () => unawaited(controller.togglePlayPause()),
      icon: Icon(video.value.isPlaying ? Icons.pause : Icons.play_arrow),
    );
    final positionLabel = Text(
      SharedVideoPlayerStyle.formatClock(
        Duration(
          milliseconds: (controller.originalPlaybackSeconds * 1000).round(),
        ),
      ),
      style: controlTextStyle,
    );
    final durationLabel = Text(
      SharedVideoPlayerStyle.formatClock(
        Duration(
          milliseconds: (controller.originalPlaybackDuration * 1000).round(),
        ),
      ),
      style: controlTextStyle,
    );
    Widget seekBar = VideoProgressIndicator(
      video,
      allowScrubbing: true,
      padding: const EdgeInsets.symmetric(vertical: 9),
      colors: VideoProgressColors(
        playedColor: Theme.of(context).colorScheme.primary,
        bufferedColor: Colors.white54,
        backgroundColor: Colors.white24,
      ),
    );
    if (controller.playback.hlsSession != null &&
        controller.originalPlaybackDuration > 0) {
      final total = controller.originalPlaybackDuration;
      seekBar = Semantics(
        label: '原片完整进度',
        child: Slider(
          value:
              (controller.playback.seekDraft ??
                      controller.originalPlaybackSeconds)
                  .clamp(0.0, total),
          min: 0,
          max: total,
          onChanged: controller.playback.transcodeStarting
              ? null
              : (value) => controller.setSeekDraft(value),
          onChangeEnd: (value) => unawaited(controller.seekAbsolute(value)),
        ),
      );
    }
    return Padding(
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
    );
  }

  Widget _buildToolbar(BuildContext context, VideoPlayerController video) {
    final textStyle = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Colors.white);
    return Padding(
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
            onPressed: controller.playback.transcodeStarting
                ? null
                : () => unawaited(
                    showCinemaFullscreenDialog(context, controller),
                  ),
            icon: const Icon(Icons.fullscreen),
          ),
          IconButton(
            tooltip: '快退 10 秒',
            color: Colors.white,
            onPressed: controller.playback.transcodeStarting
                ? null
                : () => unawaited(controller.seekRelative(-10)),
            icon: const Icon(Icons.replay_10),
          ),
          IconButton(
            tooltip: '快进 10 秒',
            color: Colors.white,
            onPressed: controller.playback.transcodeStarting
                ? null
                : () => unawaited(controller.seekRelative(10)),
            icon: const Icon(Icons.forward_10),
          ),
          Icon(
            video.value.volume == 0 ? Icons.volume_off : Icons.volume_up,
            size: 19,
            color: Colors.white,
          ),
          Semantics(
            label: '音量',
            child: SizedBox(
              width: 110,
              child: Slider(
                value: video.value.volume.clamp(0.0, 1.0).toDouble(),
                onChanged: (value) => video.setVolume(value),
                activeColor: Theme.of(context).colorScheme.primary,
                inactiveColor: Colors.white38,
                semanticFormatterCallback: (value) =>
                    '音量 ${(value * 100).round()}%',
              ),
            ),
          ),
          DropdownButton<String>(
            value: controller.subtitles.captionLanguage,
            style: textStyle,
            dropdownColor: const Color(0xFF202124),
            iconEnabledColor: Colors.white,
            iconDisabledColor: Colors.white54,
            underline: const SizedBox.shrink(),
            hint: const Text('字幕', style: TextStyle(color: Colors.white70)),
            onChanged: (value) {
              if (value == 'import') {
                unawaited(controller.importLocalSubtitles());
              } else if (value != null && value != 'local') {
                unawaited(controller.loadSubtitles(value));
              }
            },
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem(
                value: 'off',
                child: Text('关闭字幕', style: TextStyle(color: Colors.white)),
              ),
              const DropdownMenuItem(
                value: 'auto',
                child: Text('同名字幕', style: TextStyle(color: Colors.white)),
              ),
              const DropdownMenuItem(
                value: 'zh',
                child: Text('中文字幕', style: TextStyle(color: Colors.white)),
              ),
              const DropdownMenuItem(
                value: 'en',
                child: Text('英文字幕', style: TextStyle(color: Colors.white)),
              ),
              if (controller.subtitles.captionLanguage == 'local')
                const DropdownMenuItem(
                  value: 'local',
                  child: Text('本机字幕', style: TextStyle(color: Colors.white)),
                ),
              const DropdownMenuItem(
                value: 'import',
                child: Text('导入字幕', style: TextStyle(color: Colors.white)),
              ),
              for (final track
                  in controller.playback.tracks?.subtitles ??
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
          if (controller.subtitles.captionLanguage != 'off')
            DropdownButton<double>(
              value: controller.subtitles.fontSize,
              dropdownColor: const Color(0xFF202124),
              style: textStyle,
              onChanged: (size) {
                if (size != null) controller.setSubtitleFontSize(size);
              },
              items: const [
                DropdownMenuItem(value: 15.0, child: Text('字幕 小')),
                DropdownMenuItem(value: 17.0, child: Text('字幕 标准')),
                DropdownMenuItem(value: 21.0, child: Text('字幕 大')),
                DropdownMenuItem(value: 25.0, child: Text('字幕 特大')),
              ],
            ),
          DropdownButton<String>(
            value: controller.currentQualityKey,
            style: textStyle,
            dropdownColor: const Color(0xFF202124),
            iconEnabledColor: Colors.white,
            iconDisabledColor: Colors.white54,
            underline: const SizedBox.shrink(),
            hint: const Text('清晰度', style: TextStyle(color: Colors.white70)),
            onChanged: (value) {
              if (value != null) unawaited(controller.switchQuality(value));
            },
            items: <DropdownMenuItem<String>>[
              for (final option in controller.qualityOptions())
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
            value: controller.playback.playbackSpeed,
            onChanged: (speed) => unawaited(controller.setPlaybackSpeed(speed)),
          ),
          if ((controller.playback.tracks?.audio.length ?? 0) > 1 &&
              controller.playback.hlsSession != null)
            DropdownButton<int>(
              value: controller.playback.hlsSession!.audioTrack,
              style: textStyle,
              dropdownColor: const Color(0xFF202124),
              iconEnabledColor: Colors.white,
              iconDisabledColor: Colors.white54,
              underline: const SizedBox.shrink(),
              hint: const Text('音轨', style: TextStyle(color: Colors.white70)),
              onChanged: (value) {
                if (value != null) unawaited(controller.switchAudio(value));
              },
              items: <DropdownMenuItem<int>>[
                for (final track
                    in controller.playback.tracks?.audio ??
                        const <CinemaAudioTrack>[])
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
    );
  }
}

/// Opens the legacy dialog fullscreen video player overlay.
Future<void> showCinemaFullscreenDialog(
  BuildContext context,
  CinemaDetailController controller,
) async {
  if (controller.playback.controller?.value.isInitialized != true) return;
  double? draggedPosition;
  await showDialog<void>(
    context: context,
    useSafeArea: false,
    barrierColor: Colors.black,
    builder: (context) => StatefulBuilder(
      builder: (dialogContext, updateOverlay) {
        final video = controller.playback.controller;
        return Dialog.fullscreen(
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
                    if (controller.pip.supported)
                      IconButton(
                        tooltip: '画中画',
                        color: Colors.white,
                        onPressed: () => unawaited(controller.enterPiP()),
                        icon: const Icon(Icons.picture_in_picture_alt_rounded),
                      ),
                    Expanded(
                      child: Text(
                        controller.film.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: video == null || !video.value.isInitialized
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: video.value.aspectRatio > 0
                                ? video.value.aspectRatio
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
                                  await controller.seekRelative(direction);
                                  if (dialogContext.mounted) {
                                    updateOverlay(() {});
                                  }
                                } else if (video.value.isPlaying) {
                                  await video.pause();
                                } else {
                                  await video.play();
                                }
                              },
                              child: VideoPlayer(video),
                            ),
                          ),
                  ),
                ),
                if (video != null)
                  AnimatedBuilder(
                    animation: video,
                    builder: (context, _) {
                      final total = controller.originalPlaybackDuration;
                      final current = controller.originalPlaybackSeconds;
                      if (total <= 0) return const SizedBox(height: 20);
                      return Column(
                        children: [
                          Slider(
                            value: (draggedPosition ?? current).clamp(
                              0.0,
                              total,
                            ),
                            max: total,
                            onChanged: controller.playback.transcodeStarting
                                ? null
                                : (value) => updateOverlay(
                                    () => draggedPosition = value,
                                  ),
                            onChangeEnd: (value) async {
                              await controller.seekAbsolute(value);
                              if (dialogContext.mounted) {
                                updateOverlay(() => draggedPosition = null);
                              }
                            },
                          ),
                          Text(
                            '${SharedVideoPlayerStyle.formatClock(Duration(milliseconds: (current * 1000).round()))} / ${SharedVideoPlayerStyle.formatClock(Duration(milliseconds: (total * 1000).round()))}',
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
                        await controller.seekRelative(-10);
                        if (dialogContext.mounted) updateOverlay(() {});
                      },
                      icon: const Icon(Icons.replay_10),
                    ),
                    IconButton(
                      tooltip: video?.value.isPlaying == true ? '暂停' : '播放',
                      color: Colors.white,
                      onPressed: () {
                        if (video == null) return;
                        if (video.value.isPlaying) {
                          unawaited(video.pause());
                        } else {
                          unawaited(video.play());
                        }
                        updateOverlay(() {});
                      },
                      icon: Icon(
                        video?.value.isPlaying == true
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      tooltip: '快进10秒',
                      color: Colors.white,
                      onPressed: () async {
                        await controller.seekRelative(10);
                        if (dialogContext.mounted) updateOverlay(() {});
                      },
                      icon: const Icon(Icons.forward_10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
