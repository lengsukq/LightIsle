import 'dart:async';

import 'package:video_player/video_player.dart';

import 'cinema_detail_controller.dart';
import 'cinema_progress_save_queue.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Coordinates periodic progress persistence, completion detection, and
/// watched-state toggles for [CinemaDetailController].
class CinemaProgressCoordinator {
  const CinemaProgressCoordinator(this.controller);

  final CinemaDetailController controller;

  void handlePlayerProgressTick(VideoPlayerController videoController) {
    final now = DateTime.now();
    final ended = videoController.value.isCompleted;
    if (ended && !controller.playback.completionSaved) {
      controller.playback.completionSaved = true;
      final value = videoController.value;
      final sessionStart = controller.playback.hlsSession?.start ?? 0;
      final clock = cinemaPlaybackClock(
        value.position.inMilliseconds / 1000.0,
        value.duration.inMilliseconds / 1000.0,
        sessionStart: sessionStart,
        originalDuration: controller.film.durationSeconds,
      );
      // A still-growing HLS playlist can reach its temporary end well before
      // the real film. Do not mark watched or play the next episode then.
      unawaited(onPlaybackCompleted(nearRealEnd: clock.nearEnd));
    } else if (now.difference(controller.progressQueue.lastQueuedAt) >=
        CinemaProgressSaveQueue.minimumInterval) {
      unawaited(queueProgressSave(force: true));
    }
  }

  Future<void> onPlaybackCompleted({required bool nearRealEnd}) async {
    final completedID = controller.film.id;
    final saved = await queueProgressSave(force: true, completed: nearRealEnd);
    if (!nearRealEnd && controller.isActive && !controller.playback.closing) {
      controller.mutate(
        () => controller.playback.playbackMessage =
            '当前转码片段已播放至末尾，但整部影片尚未结束。可等待转码继续，或调整播放进度。',
      );
    }
    if (nearRealEnd &&
        saved &&
        controller.isActive &&
        !controller.playback.closing &&
        controller.playlistState.autoPlayNext &&
        controller.film.id == completedID) {
      final advance = controller.onAutoAdvanceNextEpisode;
      if (advance != null) {
        await advance();
      }
    }
  }

  Future<bool> queueProgressSave({bool force = false, bool completed = false}) {
    final video = controller.playback.controller;
    if (video == null || !video.value.isInitialized) {
      return Future<bool>.value(true);
    }
    final value = video.value;
    final offset = controller.playback.hlsSession?.start ?? 0;
    final localSeconds = value.position.inMilliseconds / 1000.0;
    final playlistSeconds = value.duration.inMilliseconds / 1000.0;
    if (offset + playlistSeconds <= 0 ||
        !localSeconds.isFinite ||
        !playlistSeconds.isFinite) {
      return Future<bool>.value(true);
    }
    final clock = cinemaPlaybackClock(
      localSeconds,
      playlistSeconds,
      sessionStart: offset,
      originalDuration: controller.knownFilmDuration,
      ongoingHls: controller.playback.hlsSession != null,
    );
    final isCompleted = completed || clock.nearEnd;
    final filmId = controller.film.id;
    return controller.progressQueue.save(() async {
      try {
        await controller.api.send(
          'PUT',
          '/api/v2/cinema/$filmId/progress',
          body: <String, Object>{
            'position': clock.position,
            'duration': clock.duration,
            'completed': isCompleted,
          },
        );
        if (controller.isActive && controller.film.id == filmId) {
          final updated = controller.film.withProgress(
            newPosition: clock.position,
            newDuration: clock.duration,
            isCompleted: isCompleted,
          );
          controller.mutate(() {
            controller.film = updated;
            controller.playback.progressSaveMessage = null;
          });
          controller.onProgressUpdated(updated);
        }
      } catch (_) {
        if (controller.isActive && controller.film.id == filmId) {
          controller.mutate(() {
            controller.playback.progressSaveMessage = '播放进度暂时未能保存，请检查连接后重试。';
          });
        }
        rethrow;
      }
    }, force: force);
  }

  Future<void> markWatched({required bool completed}) async {
    final filmId = controller.film.id;
    try {
      final updated = CinemaFilm.fromJson(
        await controller.api.send(
          'POST',
          '/api/v2/cinema/$filmId/watched',
          body: <String, Object>{'completed': completed},
        ),
      );
      if (!controller.isActive || controller.film.id != filmId) return;
      controller.mutate(() => controller.film = updated);
      controller.onProgressUpdated(updated);
    } catch (error) {
      if (controller.isActive) {
        controller.mutate(
          () => controller.metaMatch.message = mediaErrorLabel(error),
        );
      }
    }
  }
}
