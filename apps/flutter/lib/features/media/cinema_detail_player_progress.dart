part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerProgress on _CinemaDetailDialogState {
  void _handlePlayerProgressTick(VideoPlayerController controller) {
    final now = DateTime.now();
    final ended = controller.value.isCompleted;
    if (ended && !_playback.completionSaved) {
      _playback.completionSaved = true;
      final value = controller.value;
      final sessionStart = _playback.hlsSession?.start ?? 0;
      final clock = cinemaPlaybackClock(
        value.position.inMilliseconds / 1000.0,
        value.duration.inMilliseconds / 1000.0,
        sessionStart: sessionStart,
        originalDuration: _film.durationSeconds,
      );
      // A still-growing HLS playlist can reach its temporary end well before
      // the real film. Do not mark watched or play the next episode then.
      unawaited(_onPlaybackCompleted(nearRealEnd: clock.nearEnd));
    } else if (now.difference(_progressQueue.lastQueuedAt) >=
        CinemaProgressSaveQueue.minimumInterval) {
      unawaited(_queueProgressSave(force: true));
    }
  }

  Future<void> _onPlaybackCompleted({required bool nearRealEnd}) async {
    final completedID = _film.id;
    final saved = await _queueProgressSave(force: true, completed: nearRealEnd);
    if (!nearRealEnd && mounted && !_playback.closing) {
      _updateState(
        () => _playback.playbackMessage =
            '当前转码片段已播放至末尾，但整部影片尚未结束。可等待转码继续，或调整播放进度。',
      );
    }
    if (nearRealEnd &&
        saved &&
        mounted &&
        !_playback.closing &&
        _playlistState.autoPlayNext &&
        _film.id == completedID) {
      await _goToNextEpisode(alreadySaved: true);
    }
  }

  Future<bool> _queueProgressSave({
    bool force = false,
    bool completed = false,
  }) {
    final controller = _playback.controller;
    if (controller == null || !controller.value.isInitialized) {
      return Future<bool>.value(true);
    }
    final value = controller.value;
    final offset = _playback.hlsSession?.start ?? 0;
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
      originalDuration: _knownFilmDuration,
      ongoingHls: _playback.hlsSession != null,
    );
    final isCompleted = completed || clock.nearEnd;
    final filmId = _film.id;
    return _progressQueue.save(() async {
      try {
        await widget.api.send(
          'PUT',
          '/api/v2/cinema/$filmId/progress',
          body: <String, Object>{
            'position': clock.position,
            'duration': clock.duration,
            'completed': isCompleted,
          },
        );
        if (mounted && _film.id == filmId) {
          final updated = _film.withProgress(
            newPosition: clock.position,
            newDuration: clock.duration,
            isCompleted: isCompleted,
          );
          _updateState(() {
            _film = updated;
            _playback.progressSaveMessage = null;
          });
          widget.onProgressUpdated(updated);
        }
      } catch (_) {
        if (mounted && _film.id == filmId) {
          _updateState(() {
            _playback.progressSaveMessage = '播放进度暂时未能保存，请检查连接后重试。';
          });
        }
        rethrow;
      }
    }, force: force);
  }
}
