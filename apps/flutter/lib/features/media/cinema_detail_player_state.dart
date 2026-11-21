import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../core/lightisle_api.dart';
import 'cinema_decode_preference.dart';
import 'cinema_detail_controller.dart';
import 'cinema_hls_session_service.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Encapsulates direct stream initialization, HLS transcoding fallback,
/// track/quality switching, speed control, and seek math for
/// [CinemaDetailController].
class CinemaPlaybackEngine {
  const CinemaPlaybackEngine(this.controller);

  final CinemaDetailController controller;

  String get currentQualityKey {
    if (controller.playback.hlsSession != null) {
      return controller.playback.hlsSession!.quality;
    }
    if (controller.playback.directLocalActive &&
        !controller.film.canAttemptPlayback) {
      return 'local';
    }
    return 'source';
  }

  Future<void> loadDetailAndPlayer({
    double? seekTo,
    bool forceDirect = false,
    bool fallbackFromNoFfmpeg = false,
  }) async {
    try {
      final response = await controller.api.get(
        '/api/v2/cinema/${controller.film.id}',
      );
      final detail = CinemaFilm.fromJson(response);
      if (!controller.isActive) return;
      controller.mutate(() => controller.film = detail);
    } catch (_) {
      // Keep list metadata and progress if the detail refresh is unavailable.
    }
    if (!controller.isActive) return;
    final preferLocal =
        forceDirect || CinemaDecodePreference.preferLocalDecode.value;
    if (!controller.film.canAttemptPlayback && !preferLocal) {
      controller.mutate(() {
        controller.playback.loading = false;
        controller.playback.playbackMessage = _unsupportedMessage;
      });
      await startTranscode(
        start:
            seekTo ??
            (controller.film.canResume ? controller.film.position : 0),
      );
      return;
    }
    final useDirectParam =
        !controller.film.canAttemptPlayback || forceDirect || preferLocal;
    try {
      final source = await controller.api.mediaUri(
        '/api/v2/cinema/${controller.film.id}/stream',
        query: useDirectParam ? const <String, String>{'direct': '1'} : null,
      );
      if (!controller.isActive) return;
      final video = VideoPlayerController.networkUrl(
        source,
        httpHeaders: controller.api.nativeMediaHeaders,
      );
      final previous = controller.playback.controller;
      controller.playback.controller = video;
      if (previous != null && previous != video) {
        previous.removeListener(onVideoChanged);
        await previous.dispose();
      }
      await video.initialize();
      if (!controller.isActive || controller.playback.controller != video) {
        return;
      }
      final savedPosition = seekTo != null && seekTo > 1
          ? Duration(milliseconds: (seekTo * 1000).round())
          : Duration(milliseconds: (controller.film.position * 1000).round());
      if (savedPosition > Duration.zero &&
          savedPosition < video.value.duration - const Duration(seconds: 5)) {
        await video.seekTo(savedPosition);
      }
      if (controller.playback.playbackSpeed != 1.0) {
        await video.setPlaybackSpeed(controller.playback.playbackSpeed);
      }
      if (controller.playback.volume < 0.999) {
        await video.setVolume(controller.playback.volume);
      }
      if (!controller.isActive || controller.playback.controller != video) {
        return;
      }
      video.addListener(onVideoChanged);
      final isTestBinding = WidgetsBinding.instance.runtimeType
          .toString()
          .contains('Test');
      if (controller.playerOnly && !isTestBinding) {
        unawaited(video.play());
      }
      controller.mutate(() {
        controller.playback.hlsSession = null;
        controller.playback.directLocalActive = useDirectParam;
        controller.playback.loading = false;
        if (fallbackFromNoFfmpeg) {
          controller.playback.playbackMessage =
              '服务器未安装 FFmpeg，已自动启用原片直传（本地解码）。';
        } else if (!controller.film.canAttemptPlayback) {
          controller.playback.playbackMessage =
              '原片直传（本地解码）播放中。若声音或画面异常，可切换清晰度使用转码。';
        } else {
          controller.playback.playbackMessage =
              controller.film.browserPlayback == 'unverified-direct'
              ? '此格式尚未验证；如果当前设备无法解码，播放会失败。原片未做转换。'
              : null;
        }
      });
      controller.scheduleChromeHide();
    } catch (error) {
      if (!controller.isActive) return;
      if (!controller.film.canAttemptPlayback && !fallbackFromNoFfmpeg) {
        await startTranscode(
          start:
              seekTo ??
              (controller.film.canResume ? controller.film.position : 0),
          allowDirectFallback: false,
        );
        return;
      }
      controller.mutate(() {
        controller.playback.loading = false;
        controller.playback.playbackMessage = fallbackFromNoFfmpeg
            ? '未安装 FFmpeg，且当前设备无法本地解码此格式；可使用外部播放器（IINA / VLC / Infuse）打开或安装 FFmpeg。'
            : '无法在当前设备播放此视频：${mediaErrorLabel(error)}';
      });
    }
  }

  String get _unsupportedMessage {
    switch (controller.film.probeStatus) {
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

  Future<void> startTranscode({
    double? start,
    int audio = 0,
    String quality = 'source',
    bool allowDirectFallback = true,
  }) async {
    if (!controller.isActive || controller.playback.transcodeStarting) return;
    final filmId = controller.film.id;
    controller.mutate(() {
      controller.playback.transcodeStarting = true;
      controller.playback.playbackMessage = '正在启动转码…';
    });
    try {
      final source = await prepareCinemaHlsSource(
        api: controller.api,
        filmId: '$filmId',
        isCurrent: () => controller.isActive && controller.film.id == filmId,
        start: start ?? 0,
        audio: audio,
        quality: quality,
        replaceSessionId: controller.playback.hlsSession?.sessionId ?? '',
      );
      if (source == null ||
          !controller.isActive ||
          controller.film.id != filmId) {
        return;
      }
      final session = source.session;
      final video = VideoPlayerController.networkUrl(
        source.playlist,
        httpHeaders: controller.api.nativeMediaHeaders,
      );
      final previous = controller.playback.controller;
      controller.playback.controller = video;
      if (previous != null && previous != video) {
        previous.removeListener(onVideoChanged);
        await previous.dispose();
      }
      if (!controller.isActive || controller.playback.controller != video) {
        return;
      }
      await video.initialize();
      if (!controller.isActive || controller.playback.controller != video) {
        return;
      }
      final target =
          (start ??
              (controller.film.canResume ? controller.film.position : 0)) -
          session.start;
      final savedPosition = Duration(
        milliseconds: (target > 1 ? target * 1000 : 0).round(),
      );
      if (savedPosition > Duration.zero &&
          savedPosition < video.value.duration - const Duration(seconds: 5)) {
        await video.seekTo(savedPosition);
      }
      if (controller.playback.playbackSpeed != 1.0) {
        await video.setPlaybackSpeed(controller.playback.playbackSpeed);
      }
      if (controller.playback.volume < 0.999) {
        await video.setVolume(controller.playback.volume);
      }
      if (!controller.isActive || controller.playback.controller != video) {
        return;
      }
      video.addListener(onVideoChanged);
      try {
        controller.playback.tracks = CinemaTrackInfo.fromJson(
          await controller.api.get('/api/v2/cinema/$filmId/tracks'),
        );
      } catch (_) {
        // Track listing is optional; playback continues without selectors.
      }
      if (!controller.isActive) return;
      final isTestBinding = WidgetsBinding.instance.runtimeType
          .toString()
          .contains('Test');
      if (controller.playerOnly && !isTestBinding) {
        unawaited(video.play());
      }
      controller.mutate(() {
        controller.playback.hlsSession = session;
        controller.playback.directLocalActive = false;
        controller.playback.transcodeStarting = false;
        controller.playback.playbackMessage = session.profile == 'remux'
            ? '转封装播放（无画质损失），原片未修改。'
            : '转码播放中（服务器实时转码），原片未修改。';
      });
      controller.scheduleChromeHide();
    } catch (error) {
      if (!controller.isActive || controller.film.id != filmId) return;
      if (allowDirectFallback &&
          error is LightIsleApiException &&
          error.code == 'transcode_unavailable') {
        controller.mutate(() {
          controller.playback.transcodeStarting = false;
          controller.playback.playbackMessage = '服务器未安装 FFmpeg，正在尝试原片直传（本地解码）…';
        });
        await loadDetailAndPlayer(
          seekTo: start,
          forceDirect: true,
          fallbackFromNoFfmpeg: true,
        );
        return;
      }
      controller.mutate(() {
        controller.playback.transcodeStarting = false;
        controller.playback.playbackMessage = _transcodeErrorLabel(error);
      });
    }
  }

  Future<void> switchAudio(int audioIndex) async {
    final video = controller.playback.controller;
    final session = controller.playback.hlsSession;
    if (video == null || session == null || session.audioTrack == audioIndex) {
      return;
    }
    final realPosition =
        video.value.position.inMilliseconds / 1000.0 + session.start;
    await video.pause();
    await startTranscode(
      start: realPosition,
      audio: audioIndex,
      quality: session.quality,
    );
  }

  /// 原画 plus local decode option and every tier below the source height.
  List<(String, String)> qualityOptions() {
    final options = <(String, String)>[('source', '原画'), ('local', '本地硬解')];
    final sourceHeight = controller.film.height > 0
        ? controller.film.height
        : (controller.playback.tracks?.height ?? 0);
    for (final (value, label, height) in CinemaDetailController.qualityTiers) {
      if (sourceHeight > 0 && sourceHeight <= height) break;
      options.add((value, label));
    }
    return options;
  }

  Future<void> switchQuality(String quality) async {
    if (controller.playback.transcodeStarting) return;
    final video = controller.playback.controller;
    final session = controller.playback.hlsSession;
    final realPosition = video != null
        ? video.value.position.inMilliseconds / 1000.0 + (session?.start ?? 0.0)
        : (controller.film.canResume ? controller.film.position : 0.0);
    if (quality == 'local') {
      if (session == null && controller.playback.directLocalActive) return;
      await video?.pause();
      if (video != null) {
        video.removeListener(onVideoChanged);
        await video.dispose();
      }
      controller.playback.hlsSession = null;
      controller.playback.controller = null;
      if (!controller.isActive) return;
      controller.mutate(() {
        controller.playback.loading = true;
        controller.playback.playbackMessage = null;
      });
      await loadDetailAndPlayer(seekTo: realPosition, forceDirect: true);
      return;
    }
    if (session == null) {
      if (quality == 'source' &&
          controller.film.canAttemptPlayback &&
          !controller.playback.directLocalActive) {
        return;
      }
      await video?.pause();
      await startTranscode(
        start: realPosition,
        quality: quality,
        allowDirectFallback: false,
      );
      return;
    }
    if (session.quality == quality) return;
    await video!.pause();
    if (quality == 'source' && controller.film.canAttemptPlayback) {
      // Back to the plain stream: dispose the session controller first.
      video.removeListener(onVideoChanged);
      await video.dispose();
      controller.playback.hlsSession = null;
      controller.playback.controller = null;
      if (!controller.isActive) return;
      controller.mutate(() {
        controller.playback.loading = true;
        controller.playback.playbackMessage = null;
      });
      await loadDetailAndPlayer(seekTo: realPosition);
      return;
    }
    await startTranscode(
      start: realPosition,
      audio: session.audioTrack,
      quality: quality,
      allowDirectFallback: false,
    );
  }

  Future<void> restorePlaybackSpeed() async {
    final cached = CinemaDetailController.sessionSpeed;
    if (cached != null) {
      controller.playback.playbackSpeed = cached;
      await controller.playback.controller?.setPlaybackSpeed(cached);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final speed = prefs.getDouble('lightisle_cinema_playback_speed');
      if (!controller.isActive ||
          speed == null ||
          !CinemaDetailController.supportedSpeeds.contains(speed)) {
        return;
      }
      CinemaDetailController.sessionSpeed = speed;
      controller.mutate(() => controller.playback.playbackSpeed = speed);
      await controller.playback.controller?.setPlaybackSpeed(speed);
    } catch (_) {
      // Disabled preferences or a missing test platform never blocks playback.
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (!CinemaDetailController.supportedSpeeds.contains(speed)) return;
    CinemaDetailController.sessionSpeed = speed;
    controller.playback.playbackSpeed = speed;
    await controller.playback.controller?.setPlaybackSpeed(speed);
    controller.notify();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lightisle_cinema_playback_speed', speed);
    } catch (_) {
      // Persist when possible, playback still works without it.
    }
  }

  double get originalPlaybackSeconds {
    final video = controller.playback.controller;
    if (video == null || !video.value.isInitialized) return 0;
    return video.value.position.inMilliseconds / 1000.0 +
        (controller.playback.hlsSession?.start ?? 0);
  }

  double get knownFilmDuration {
    var best = controller.film.durationSeconds > 0
        ? controller.film.durationSeconds
        : 0.0;
    if (controller.film.duration > best) best = controller.film.duration;
    final sessionDur = controller.playback.hlsSession?.durationSeconds ?? 0;
    if (sessionDur > best) best = sessionDur;
    final trackDur = controller.playback.tracks?.durationSeconds ?? 0;
    if (trackDur > best) best = trackDur;
    return best;
  }

  double get originalPlaybackDuration {
    final video = controller.playback.controller;
    final sessionStart = controller.playback.hlsSession?.start ?? 0;
    final observed = video == null || !video.value.isInitialized
        ? 0.0
        : video.value.duration.inMilliseconds / 1000.0 + sessionStart;
    final known = knownFilmDuration;
    if (controller.playback.hlsSession != null && known > 0) {
      final pos = originalPlaybackSeconds;
      return known > pos ? known : pos;
    }
    return known > observed ? known : observed;
  }

  Future<void> seekAbsolute(double absoluteSeconds) async {
    final video = controller.playback.controller;
    if (video == null ||
        !video.value.isInitialized ||
        controller.playback.transcodeStarting) {
      return;
    }
    final max = originalPlaybackDuration;
    final target = absoluteSeconds
        .clamp(0.0, max > 0 ? max - .25 : 0.0)
        .toDouble();
    final session = controller.playback.hlsSession;
    if (session != null) {
      final localTarget = target - session.start;
      final muxedLen = video.value.duration.inMilliseconds / 1000.0;
      if (localTarget >= 0 && muxedLen > 2 && localTarget <= muxedLen - 1.5) {
        await video.seekTo(
          Duration(milliseconds: (localTarget * 1000).round()),
        );
        unawaited(controller.queueProgressSave(force: true));
      } else {
        unawaited(controller.queueProgressSave(force: true));
        await startTranscode(
          start: target,
          audio: session.audioTrack,
          quality: session.quality,
        );
      }
    } else {
      await video.seekTo(Duration(milliseconds: (target * 1000).round()));
      unawaited(controller.queueProgressSave(force: true));
    }
    if (controller.isActive) {
      controller.mutate(() => controller.playback.seekDraft = null);
    }
  }

  Future<void> seekRelative(double deltaSeconds) async {
    await seekAbsolute(originalPlaybackSeconds + deltaSeconds);
  }

  Future<void> restartFromBeginning() async {
    final video = controller.playback.controller;
    final session = controller.playback.hlsSession;
    if (session != null) {
      await startTranscode(
        start: 0,
        audio: session.audioTrack,
        quality: session.quality,
      );
      return;
    }
    if (video != null) {
      await video.seekTo(Duration.zero);
      await video.play();
    }
  }

  void onVideoChanged() {
    final video = controller.playback.controller;
    if (video == null || !video.value.isInitialized) return;
    if (video.value.hasError) {
      final message =
          '视频播放中断：${video.value.errorDescription ?? '当前设备无法解码此格式。'}';
      if (controller.isActive &&
          controller.playback.playbackMessage != message) {
        controller.mutate(() => controller.playback.playbackMessage = message);
      }
      return;
    }
    if (controller.isActive &&
        controller.playback.consumeShouldRebuild(
          video.value,
          playerOnly: controller.playerOnly,
          subtitleText: controller.subtitles.cues.isEmpty
              ? null
              : controller.activeCue?.text,
        )) {
      controller.notify();
    }
    controller.progressCoordinator.handlePlayerProgressTick(video);
  }
}
