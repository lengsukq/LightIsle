part of 'cinema_detail_dialog.dart';

extension _CinemaDetailSessionActions on _CinemaDetailDialogState {
  Future<void> _stopDlna() async {
    final session = _externalActions.castSession;
    if (session == null) return;
    try {
      await session.stop();
      _externalActions.castSession = null;
      if (mounted) {
        _updateState(() => _playback.playbackMessage = '已停止投屏并撤销临时链接。');
      }
    } catch (error) {
      if (session.revoked) _externalActions.castSession = null;
      if (mounted) {
        _updateState(
          () => _playback.playbackMessage = session.revoked
              ? '临时链接已撤销。电视停止指令未得到确认，请在电视上手动停止播放。'
              : '未能撤销公开链接。请保持此页面并重试“停止投屏”；链接最多 1 小时失效：${mediaErrorLabel(error)}',
        );
      }
    }
  }

  Future<void> _castToDlna() async {
    if (_externalActions.castSession != null) throw StateError('请先停止当前投屏。');
    if (!RegExp(r'\.(mp4|m4v)$', caseSensitive: false).hasMatch(_film.path)) {
      throw StateError('DLNA 目前仅支持 MP4/M4V 原始文件。');
    }
    final cast = DlnaCast();
    var retained = false;
    final currentFilmId = _film.id;
    final currentRootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    try {
      if (mounted) {
        _updateState(() => _playback.playbackMessage = '正在发现局域网 DLNA 电视…');
      }
      final devices = await cast.discover();
      if (!mounted) return;
      if (devices.isEmpty) {
        _updateState(
          () =>
              _playback.playbackMessage = '未发现支持 DLNA 的设备，请检查电视与本机是否位于同一局域网。',
        );
        return;
      }
      final renderer = await showDialog<DlnaRenderer>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('选择 DLNA 设备'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final device in devices)
                  ListTile(
                    leading: const Icon(Icons.tv_rounded),
                    title: Text(device.name),
                    subtitle: Text(device.controlUri.host),
                    onTap: () => Navigator.pop(dialogContext, device),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (renderer == null || !mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认通过临时链接投屏？'),
          content: Text(
            '将为“${_film.title}”创建有效期 1 小时、无需登录的公开下载链接，'
            '发送给“${renderer.name}”。任何拿到链接的人在有效期内均可下载原文件。'
            '电视需能访问 NAS 地址并支持当前编码。停止投屏会撤销链接。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认投屏'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      _externalActions.castSession = await CinemaDlnaCastService(widget.api)
          .start(
            cast: cast,
            renderer: renderer,
            filmPath: _film.path,
            stillCurrent: () =>
                mounted &&
                !_playback.closing &&
                _film.id == currentFilmId &&
                (widget.api.selectedRoot?.identity ?? 'default') ==
                    currentRootIdentity,
          );
      retained = true;
      await _playback.controller?.pause();
      if (mounted) {
        _updateState(
          () => _playback.playbackMessage = '已投屏到 ${renderer.name}。停止投屏将撤销链接。',
        );
      }
    } finally {
      if (!retained) {
        cast.close();
      }
    }
  }

  Future<void> _mediaAction(String action) async {
    if (_externalActions.mediaActionBusy || _playback.closing) return;
    _updateState(() => _externalActions.mediaActionBusy = true);
    try {
      final fileName = _film.path.split('/').last;
      if (action == 'toggleWatched') {
        final next = !_film.completed;
        await _markWatched(completed: next);
        if (mounted) {
          _updateState(() {
            _playback.playbackMessage = next ? '已标记为已看完。' : '已标记为未看完。';
          });
        }
      } else if (action == 'rename') {
        await _renameFilm();
      } else if (action == 'details') {
        await _playback.controller?.pause();
        unawaited(_queueProgressSave(force: true));
        _updateState(() => _chrome.showPlayerDetails = true);
      } else if (action == 'cast') {
        await _castToDlna();
      } else if (action == 'stopCast') {
        await _stopDlna();
      } else if (action == 'share') {
        await openMediaFileShare(
          context,
          api: widget.api,
          path: _film.path,
          name: fileName,
        );
      } else if (action == 'externalPlayer') {
        await showCinemaExternalPlayerDialog(
          context,
          api: widget.api,
          film: _film,
        );
      } else if (action == 'trash') {
        await _trashCurrentFilm();
        return;
      } else if (action == 'export') {
        final result = await exportMediaFile(
          widget.api,
          path: _film.path,
          name: fileName,
        );
        if (mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(result)));
        }
      } else if (action == 'offline') {
        await _saveFilmOffline();
      }
    } catch (error) {
      if (mounted) {
        _updateState(() => _playback.playbackMessage = mediaErrorLabel(error));
      }
    } finally {
      if (mounted) {
        _updateState(() {
          _externalActions.mediaActionBusy = false;
          _externalActions.offlineProgress = null;
        });
      }
    }
  }

  Future<void> _trashCurrentFilm() async {
    if (!widget.isAdmin && !_film.canWrite) {
      throw StateError('没有该影片原件的写入权限，请联系管理员。');
    }
    final root = widget.api.selectedRoot?.identity ?? 'default';
    final approved = await confirmAction(
      context,
      '移入回收站',
      '将“${_film.title}”的原始视频移入回收站？可在文件管理中恢复。',
      action: '移入回收站',
    );
    if (approved != true ||
        !mounted ||
        (widget.api.selectedRoot?.identity ?? 'default') != root) {
      return;
    }
    final result = await widget.api.send(
      'POST',
      '/api/v2/files/batch',
      body: {
        'action': 'trash',
        'paths': [_film.path],
      },
    );
    if (!mounted || (widget.api.selectedRoot?.identity ?? 'default') != root) {
      return;
    }
    final items = result['results'];
    if (items is List &&
        items.length == 1 &&
        items.single is Map &&
        (items.single['error'] == 'storage_operation_uncertain' ||
            items.single['error'] == 'root_unavailable')) {
      throw const LightIsleApiException(
        code: 'storage_operation_uncertain',
        message: '操作可能已在原硬盘上执行，请检查原目录和回收站。',
      );
    }
    if (items is! List ||
        items.length != 1 ||
        items.single is! Map ||
        items.single['success'] != true) {
      throw StateError('移动失败，请检查当前目录权限和原文件状态');
    }
    _playback.hasQueuedFinalSave = true;
    Navigator.of(context).pop();
  }

  Future<void> _saveFilmOffline() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存到离线库？'),
        content: Text(
          '会将“${_film.title}”的原始视频保存到本设备的应用私有空间，'
          '仅当前服务器、账号和存储根可在应用内查看；离线库最多 5 GiB，'
          '单个影片最多 2 GiB。若文件太大请使用“保存原始视频”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final store = OfflineVideoStore(
      api: widget.api,
      accountName: widget.accountName,
    );
    await store.save(
      _film,
      onProgress: (received, total) {
        if (mounted && total > 0) {
          _updateState(
            () => _externalActions.offlineProgress = received / total,
          );
        }
      },
    );
    if (mounted) {
      _updateState(
        () => _playback.playbackMessage = '已保存到本设备离线影片库，可在断网时播放。',
      );
    }
  }

  Future<void> _enterPiP() async {
    if (_playback.controller?.value.isInitialized == true) await _pip.enter();
  }

  Future<void> _restoreAutoplayNext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        _updateState(
          () => _playlistState.autoPlayNext =
              prefs.getBool('lightisle_cinema_autoplay_next') ?? false,
        );
      }
    } catch (_) {
      /* Opt-in defaults to off when preferences cannot load. */
    }
  }

  Future<void> _setAutoplayNext(bool value) async {
    _updateState(() => _playlistState.autoPlayNext = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('lightisle_cinema_autoplay_next', value);
    } catch (_) {
      /* Session selection still works. */
    }
  }

  List<CinemaFilm> get _sameDirectoryFilms =>
      CinemaEpisodeNavigator.buildSameDirectoryPlaylist(_film, <CinemaFilm>[
        ...widget.playlist,
        ..._playlistState.directoryFilms,
      ]);

  int get _currentPlaylistIndex {
    final items = _sameDirectoryFilms;
    final idx = items.indexWhere((item) => item.id == _film.id);
    return idx < 0 ? 0 : idx;
  }

  CinemaFilm? get _previousPlaylistFilm {
    final items = _sameDirectoryFilms;
    final idx = _currentPlaylistIndex;
    return idx > 0 ? items[idx - 1] : null;
  }

  CinemaFilm? get _nextPlaylistFilm {
    final items = _sameDirectoryFilms;
    final idx = _currentPlaylistIndex;
    return idx >= 0 && idx + 1 < items.length ? items[idx + 1] : null;
  }

  Future<void> _refreshDirectoryPlaylist({bool force = false}) async {
    if (_playback.closing ||
        _playlistState.loading ||
        (!force && _playlistState.loaded)) {
      return;
    }
    final generation = ++_playlistState.generation;
    final currentID = _film.id;
    final currentRoot = widget.api.selectedRoot?.identity ?? 'default';
    bool stillCurrent() =>
        mounted &&
        !_playback.closing &&
        generation == _playlistState.generation &&
        _film.id == currentID &&
        (widget.api.selectedRoot?.identity ?? 'default') == currentRoot;
    _updateState(() => _playlistState.loading = true);
    try {
      final items = await CinemaEpisodeNavigator(widget.api)
          .loadSameDirectory(_film);
      if (!stillCurrent()) return;
      _updateState(() {
        _playlistState.directoryFilms = items;
        _playlistState.loaded = true;
      });
    } catch (_) {
      if (stillCurrent()) {
        _updateState(() => _playlistState.loaded = true);
      }
    } finally {
      if (stillCurrent()) {
        _updateState(() => _playlistState.loading = false);
      }
    }
  }

  void _togglePlaylistSheet() {
    final opening = !_chrome.showPlaylistSheet;
    if (opening) {
      _revealChrome();
      if (!_playlistState.loaded) {
        unawaited(_refreshDirectoryPlaylist());
      }
    }
    _updateState(() {
      _chrome.showPlaylistSheet = opening;
      if (opening) _chrome.showPlayerDetails = false;
    });
  }

  Future<void> _switchToPlaylistFilm(
    CinemaFilm target, {
    bool alreadySaved = false,
  }) async {
    if (_playback.closing || _playlistState.nextEpisodeBusy || !mounted) return;
    if (target.id == _film.id) {
      _updateState(() => _chrome.showPlaylistSheet = false);
      return;
    }
    final currentID = _film.id;
    final currentRoot = widget.api.selectedRoot?.identity ?? 'default';
    bool stillCurrent() =>
        mounted &&
        !_playback.closing &&
        _film.id == currentID &&
        (widget.api.selectedRoot?.identity ?? 'default') == currentRoot;
    _updateState(() => _playlistState.nextEpisodeBusy = true);
    try {
      await _playback.controller?.pause();
      if (!alreadySaved && !await _queueProgressSave(force: true)) return;
      if (!stillCurrent()) return;
      if (!mounted) return;
      _playback.hasQueuedFinalSave = true;
      unawaited(_exitNativeFullscreen());
      Navigator.pop(context, target);
    } finally {
      if (mounted && !_playback.hasQueuedFinalSave) {
        _updateState(() => _playlistState.nextEpisodeBusy = false);
      }
    }
  }

  Future<CinemaFilm?> _findNextEpisode() async {
    return CinemaEpisodeNavigator(widget.api).findNext(_film);
  }

  Future<void> _goToPreviousEpisode() async {
    final previous = _previousPlaylistFilm;
    if (previous == null) return;
    await _switchToPlaylistFilm(previous);
  }

  Future<void> _goToNextEpisode({bool alreadySaved = false}) async {
    if (_playback.closing || _playlistState.nextEpisodeBusy || !mounted) return;
    if (!_film.isSeries &&
        _sameDirectoryFilms.length <= 1 &&
        _playlistState.loaded) {
      return;
    }
    final currentID = _film.id;
    final currentRoot = widget.api.selectedRoot?.identity ?? 'default';
    bool stillCurrent() =>
        mounted &&
        !_playback.closing &&
        _film.id == currentID &&
        (widget.api.selectedRoot?.identity ?? 'default') == currentRoot;
    _updateState(() => _playlistState.nextEpisodeBusy = true);
    try {
      CinemaFilm? next = _nextPlaylistFilm;
      if (next == null && _film.isSeries) {
        next = await _findNextEpisode();
        if (!stillCurrent()) return;
      }
      if (next == null && !_playlistState.loaded) {
        await _refreshDirectoryPlaylist();
        if (!stillCurrent()) return;
        next = _nextPlaylistFilm;
      }
      if (next == null) {
        _updateState(
          () => _playback.playbackMessage = _film.isSeries
              ? '本季已播完，或者还没有扫描到下一集。可从剧集库选择。'
              : '已是当前目录最后一个视频。',
        );
        return;
      }
      await _playback.controller?.pause();
      if (!alreadySaved && !await _queueProgressSave(force: true)) return;
      if (!stillCurrent()) return;
      if (!mounted) return;
      _playback.hasQueuedFinalSave = true;
      unawaited(_exitNativeFullscreen());
      Navigator.pop(context, next);
    } catch (error) {
      if (stillCurrent()) {
        _updateState(
          () =>
              _playback.playbackMessage = '无法读取下一集：${mediaErrorLabel(error)}',
        );
      }
    } finally {
      if (mounted && !_playback.hasQueuedFinalSave) {
        _updateState(() => _playlistState.nextEpisodeBusy = false);
      }
    }
  }

  Future<void> _restorePlaybackSpeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final speed = prefs.getDouble('lightisle_cinema_playback_speed');
      if (!mounted ||
          speed == null ||
          !const [0.75, 1.0, 1.25, 1.5, 2.0].contains(speed)) {
        return;
      }
      _updateState(() => _playback.playbackSpeed = speed);
      await _playback.controller?.setPlaybackSpeed(speed);
    } catch (_) {
      // Disabled preferences or a missing test platform never blocks playback.
    }
  }

  Future<void> _markWatched({required bool completed}) async {
    final filmId = _film.id;
    try {
      final updated = CinemaFilm.fromJson(
        await widget.api.send(
          'POST',
          '/api/v2/cinema/$filmId/watched',
          body: <String, Object>{'completed': completed},
        ),
      );
      if (!mounted || _film.id != filmId) return;
      _updateState(() => _film = updated);
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (mounted) {
        _updateState(() => _metaMatch.message = mediaErrorLabel(error));
      }
    }
  }

  Future<void> _restartFromBeginning() async {
    final controller = _playback.controller;
    final session = _playback.hlsSession;
    if (session != null) {
      await _startTranscode(
        start: 0,
        audio: session.audioTrack,
        quality: session.quality,
      );
      return;
    }
    if (controller != null) {
      await controller.seekTo(Duration.zero);
      await controller.play();
    }
  }

  Future<void> _loadSubtitles(String language) async {
    final generation = ++_subtitles.generation;
    final filmId = _film.id;
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    _updateState(() {
      _subtitles.captionLanguage = language;
      _subtitles.message = null;
      _subtitles.cues = const [];
    });
    if (language == 'off') return;
    try {
      final cues = await _subtitleRepository.load(filmId, language);
      if (!_subtitleRequestCurrent(generation, filmId, rootIdentity)) return;
      _updateState(() {
        _subtitles.cues = cues;
        _subtitles.message = cues.isEmpty ? '字幕文件没有可显示的内容。' : null;
      });
    } catch (error) {
      if (!_subtitleRequestCurrent(generation, filmId, rootIdentity)) return;
      _updateState(() {
        _subtitles.message =
            error is LightIsleApiException && error.code == 'film_not_found'
            ? '未找到匹配字幕，或此影片已被移除。'
            : mediaErrorLabel(error);
      });
    }
  }

  bool _subtitleRequestCurrent(
    int generation,
    int filmId,
    String rootIdentity,
  ) =>
      mounted &&
      generation == _subtitles.generation &&
      _film.id == filmId &&
      (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity;

  /// An optional, one-session subtitle source from this device.
  Future<void> _importLocalSubtitles() async {
    final generation = ++_subtitles.generation;
    final filmId = _film.id;
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    try {
      final selected = await _subtitleRepository.importLocal();
      if (selected == null ||
          !_subtitleRequestCurrent(generation, filmId, rootIdentity)) {
        return;
      }
      _updateState(() {
        _subtitles.captionLanguage = 'local';
        _subtitles.cues = selected.cues;
        _subtitles.message = '已加载：${selected.name}（仅本次播放）';
      });
    } catch (error) {
      if (_subtitleRequestCurrent(generation, filmId, rootIdentity)) {
        _updateState(
          () => _subtitles.message = '无法加载字幕：${mediaErrorLabel(error)}',
        );
      }
    }
  }

  KeyEventResult _onPlayerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _playback.closing || !widget.playerOnly) {
      return KeyEventResult.ignored;
    }
    // Pop-up routes, text editing and input sliders own their own keys.
    if (ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_chrome.showPlaylistSheet) {
        _updateState(() => _chrome.showPlaylistSheet = false);
        return KeyEventResult.handled;
      }
      if (_chrome.showPlayerDetails) {
        _updateState(() => _chrome.showPlayerDetails = false);
        return KeyEventResult.handled;
      }
      unawaited(_close());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyF) {
      unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }
    final controller = _playback.controller;
    if (controller == null || !controller.value.isInitialized) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _revealChrome();
      unawaited(_seekRelative(-10));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _revealChrome();
      unawaited(_seekRelative(10));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (controller.value.isPlaying) {
        unawaited(controller.pause());
        unawaited(_queueProgressSave(force: true));
      } else {
        unawaited(controller.play());
      }
      _revealChrome();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _renameFilm() async {
    _updateState(() => _playback.busy = true);
    try {
      final updated = await widget.onRename(_film);
      if (mounted) _updateState(() => _film = updated);
    } catch (error) {
      if (mounted) {
        _updateState(() => _playback.playbackMessage = mediaErrorLabel(error));
      }
    } finally {
      if (mounted) _updateState(() => _playback.busy = false);
    }
  }
}
