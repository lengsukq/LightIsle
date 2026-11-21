import 'dart:async';

import 'package:flutter/material.dart';

import 'cinema_detail_controller.dart';
import 'media_models.dart';
import 'shared_video_player_controls.dart';

/// Pure formatting helpers for compact player transport pill labels.
abstract final class CinemaPlayerMenuLabels {
  static String captionShortLabel(CinemaDetailController controller) {
    final lang = controller.subtitles.captionLanguage;
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
              in controller.playback.tracks?.subtitles ??
                  const <CinemaSubtitleTrack>[]) {
            if (track.streamIndex == index) return track.label;
          }
          return '内嵌字幕';
        }
        return '字幕';
    }
  }

  static String qualityShortLabel(CinemaDetailController controller) {
    final current = controller.currentQualityKey;
    for (final option in controller.qualityOptions()) {
      if (option.$1 == current) return option.$2;
    }
    return '原画';
  }

  static String speedShortLabel(double speed) {
    if (speed == 1.0) return '1.0x';
    final text = speed
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    return '${text}x';
  }

  static String audioShortLabel(CinemaDetailController controller) {
    final active = controller.playback.hlsSession?.audioTrack ?? 0;
    for (final track
        in controller.playback.tracks?.audio ?? const <CinemaAudioTrack>[]) {
      if (track.audioIndex == active) return track.label;
    }
    return '音轨';
  }
}

/// Subtitle track, font size, local import, and sync offset selector pill.
class CinemaCaptionMenuPill extends StatelessWidget {
  const CinemaCaptionMenuPill({super.key, required this.controller});

  final CinemaDetailController controller;

  @override
  Widget build(BuildContext context) {
    final lang = controller.subtitles.captionLanguage;
    return SharedPlayerMenuPill<String>(
      icon: Icons.subtitles_outlined,
      label: CinemaPlayerMenuLabels.captionShortLabel(controller),
      tooltip: '字幕与字号',
      active: lang != 'off',
      onSelected: (value) {
        controller.revealChrome();
        controller.handleCaptionMenuSelection(value);
      },
      items: _buildMenuItems(lang),
    );
  }

  List<PopupMenuEntry<String>> _buildMenuItems(String lang) {
    final subtitles = controller.subtitles;
    return <PopupMenuEntry<String>>[
      buildSharedPlayerPopupChoice(
        value: 'off',
        label: '关闭字幕',
        selected: lang == 'off',
      ),
      buildSharedPlayerPopupChoice(
        value: 'auto',
        label: '同名字幕',
        selected: lang == 'auto',
      ),
      buildSharedPlayerPopupChoice(
        value: 'zh',
        label: '中文字幕',
        selected: lang == 'zh',
      ),
      buildSharedPlayerPopupChoice(
        value: 'en',
        label: '英文字幕',
        selected: lang == 'en',
      ),
      if (lang == 'local')
        buildSharedPlayerPopupChoice(
          value: 'local',
          label: '本机字幕（当前）',
          selected: true,
        ),
      for (final track
          in controller.playback.tracks?.subtitles ??
              const <CinemaSubtitleTrack>[])
        if (track.extractable)
          buildSharedPlayerPopupChoice(
            value: 'emb:${track.streamIndex}',
            label: track.label,
            selected: lang == 'emb:${track.streamIndex}',
          ),
      const PopupMenuDivider(height: 8),
      const PopupMenuItem<String>(
        value: 'import',
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_rounded, size: 15, color: Colors.white70),
            SizedBox(width: 8),
            Text(
              '导入本机字幕…',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
      if (lang != 'off') ...[
        const PopupMenuDivider(height: 8),
        for (final (size, label) in const [
          (15.0, '字号：小'),
          (17.0, '字号：标准'),
          (21.0, '字号：大'),
          (25.0, '字号：特大'),
        ])
          buildSharedPlayerPopupChoice(
            value: 'size:$size',
            label: label,
            selected: subtitles.fontSize == size,
          ),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem<String>(
          value: 'offset:-0.5',
          height: 34,
          child: Text(
            '字幕提前 0.5 秒',
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'offset:+0.5',
          height: 34,
          child: Text(
            '字幕延后 0.5 秒',
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        if (subtitles.offsetSeconds != 0.0)
          PopupMenuItem<String>(
            value: 'offset:reset',
            height: 34,
            child: Text(
              '重置字幕偏移 (${subtitles.offsetSeconds >= 0 ? '+' : ''}${subtitles.offsetSeconds.toStringAsFixed(1)}s)',
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
      ],
    ];
  }
}

/// Video quality / local decode mode selector pill.
class CinemaQualityMenuPill extends StatelessWidget {
  const CinemaQualityMenuPill({super.key, required this.controller});

  final CinemaDetailController controller;

  @override
  Widget build(BuildContext context) {
    final currentQuality = controller.currentQualityKey;
    return SharedPlayerMenuPill<String>(
      label: CinemaPlayerMenuLabels.qualityShortLabel(controller),
      tooltip: '清晰度',
      enabled: !controller.playback.transcodeStarting,
      onSelected: (value) {
        controller.revealChrome();
        unawaited(controller.switchQuality(value));
      },
      items: <PopupMenuEntry<String>>[
        for (final option in controller.qualityOptions())
          buildSharedPlayerPopupChoice(
            value: option.$1,
            label: option.$2,
            selected: currentQuality == option.$1,
          ),
      ],
    );
  }
}

/// Playback speed selector pill.
class CinemaSpeedMenuPill extends StatelessWidget {
  const CinemaSpeedMenuPill({super.key, required this.controller});

  final CinemaDetailController controller;

  @override
  Widget build(BuildContext context) {
    final currentSpeed = controller.playback.playbackSpeed;
    return SharedPlayerMenuPill<double>(
      label: CinemaPlayerMenuLabels.speedShortLabel(currentSpeed),
      tooltip: '播放倍速',
      active: currentSpeed != 1.0,
      onSelected: (speed) {
        controller.revealChrome();
        unawaited(controller.setPlaybackSpeed(speed));
      },
      items: <PopupMenuEntry<double>>[
        for (final speed in CinemaDetailController.supportedSpeeds)
          buildSharedPlayerPopupChoice(
            value: speed,
            label: speed == 1.0 ? '1.0x（正常）' : '${speed}x',
            selected: currentSpeed == speed,
          ),
      ],
    );
  }
}

/// Multi-audio track selector pill for HLS sessions.
class CinemaAudioTrackMenuPill extends StatelessWidget {
  const CinemaAudioTrackMenuPill({super.key, required this.controller});

  final CinemaDetailController controller;

  @override
  Widget build(BuildContext context) {
    final session = controller.playback.hlsSession;
    return SharedPlayerMenuPill<int>(
      icon: Icons.graphic_eq_rounded,
      label: CinemaPlayerMenuLabels.audioShortLabel(controller),
      tooltip: '音轨切换',
      onSelected: (value) {
        controller.revealChrome();
        unawaited(controller.switchAudio(value));
      },
      items: <PopupMenuEntry<int>>[
        for (final track
            in controller.playback.tracks?.audio ?? const <CinemaAudioTrack>[])
          buildSharedPlayerPopupChoice(
            value: track.audioIndex,
            label: track.label,
            selected: session?.audioTrack == track.audioIndex,
          ),
      ],
    );
  }
}
