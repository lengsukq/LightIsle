part of 'cinema_detail_dialog.dart';

extension _CinemaDetailSessionActions on _CinemaDetailDialogState {
  Future<void> _stopDlna() async {
    final session = _castSession;
    if (session == null) return;
    try {
      await session.stop();
      _castSession = null;
      if (mounted) _updateState(() => _playbackMessage = '已停止投屏并撤销临时链接。');
    } catch (error) {
      if (session.revoked) _castSession = null;
      if (mounted) {
        _updateState(
          () => _playbackMessage = session.revoked
              ? '临时链接已撤销。电视停止指令未得到确认，请在电视上手动停止播放。'
              : '未能撤销公开链接。请保持此页面并重试“停止投屏”；链接最多 1 小时失效：${mediaErrorLabel(error)}',
        );
      }
    }
  }

  Future<void> _castToDlna() async {
    if (_castSession != null) throw StateError('请先停止当前投屏。');
    if (!RegExp(r'\.(mp4|m4v)$', caseSensitive: false).hasMatch(_film.path)) {
      throw StateError('DLNA 目前仅支持 MP4/M4V 原始文件。');
    }
    final cast = DlnaCast();
    var retained = false;
    final currentFilmId = _film.id;
    final currentRootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    try {
      if (mounted) _updateState(() => _playbackMessage = '正在发现局域网 DLNA 电视…');
      final devices = await cast.discover();
      if (!mounted) return;
      if (devices.isEmpty) {
        _updateState(
          () => _playbackMessage = '未发现支持 DLNA 的设备，请检查电视与本机是否位于同一局域网。',
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
      _castSession = await CinemaDlnaCastService(widget.api).start(
        cast: cast,
        renderer: renderer,
        filmPath: _film.path,
        stillCurrent: () =>
            mounted &&
            !_closing &&
            _film.id == currentFilmId &&
            (widget.api.selectedRoot?.identity ?? 'default') ==
                currentRootIdentity,
      );
      retained = true;
      await _controller?.pause();
      if (mounted) {
        _updateState(
          () => _playbackMessage = '已投屏到 ${renderer.name}。停止投屏将撤销链接。',
        );
      }
    } finally {
      if (!retained) {
        cast.close();
      }
    }
  }

  Future<void> _mediaAction(String action) async {
    if (_mediaActionBusy || _closing) return;
    _updateState(() => _mediaActionBusy = true);
    try {
      final fileName = _film.path.split('/').last;
      if (action == 'cast') {
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
      } else if (action == 'trash') {
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
        if (!mounted ||
            (widget.api.selectedRoot?.identity ?? 'default') != root) {
          return;
        }
        final items = result['results'];
        if (items is! List ||
            items.length != 1 ||
            items.single is! Map ||
            items.single['success'] != true) {
          throw StateError('移动失败，请检查当前目录权限和原文件状态');
        }
        _hasQueuedFinalSave = true;
        Navigator.of(context).pop();
        return;
      } else if (action == 'export') {
        final result = await exportMediaFile(
          widget.api,
          path: _film.path,
          name: fileName,
        );
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(result)));
        }
      } else if (action == 'offline') {
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
              _updateState(() => _offlineProgress = received / total);
            }
          },
        );
        if (mounted) {
          _updateState(() => _playbackMessage = '已保存到本设备离线影片库，可在断网时播放。');
        }
      }
    } catch (error) {
      if (mounted) {
        _updateState(() => _playbackMessage = mediaErrorLabel(error));
      }
    } finally {
      if (mounted) {
        _updateState(() {
          _mediaActionBusy = false;
          _offlineProgress = null;
        });
      }
    }
  }

  Future<void> _enterPiP() async {
    if (_controller?.value.isInitialized == true) await _pip.enter();
  }

  Future<void> _restoreAutoplayNext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        _updateState(
          () => _autoPlayNext =
              prefs.getBool('lightisle_cinema_autoplay_next') ?? false,
        );
      }
    } catch (_) {
      /* Opt-in defaults to off when preferences cannot load. */
    }
  }

  Future<void> _setAutoplayNext(bool value) async {
    _updateState(() => _autoPlayNext = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('lightisle_cinema_autoplay_next', value);
    } catch (_) {
      /* Session selection still works. */
    }
  }

  Future<CinemaFilm?> _findNextEpisode() async {
    return CinemaEpisodeNavigator(widget.api).findNext(_film);
  }

  Future<void> _goToNextEpisode({bool alreadySaved = false}) async {
    if (_closing || _nextEpisodeBusy || !mounted || !_film.isSeries) return;
    final currentID = _film.id;
    final currentRoot = widget.api.selectedRoot?.identity ?? 'default';
    bool stillCurrent() =>
        mounted &&
        !_closing &&
        _film.id == currentID &&
        (widget.api.selectedRoot?.identity ?? 'default') == currentRoot;
    _updateState(() => _nextEpisodeBusy = true);
    try {
      final next = await _findNextEpisode();
      if (!stillCurrent()) return;
      if (next == null) {
        _updateState(() => _playbackMessage = '本季已播完，或者还没有扫描到下一集。可从剧集库选择。');
        return;
      }
      await _controller?.pause();
      if (!alreadySaved && !await _queueProgressSave(force: true)) return;
      if (!stillCurrent()) return;
      if (!mounted) return;
      _hasQueuedFinalSave = true;
      Navigator.pop(context, next);
    } catch (error) {
      if (stillCurrent()) {
        _updateState(
          () => _playbackMessage = '无法读取下一集：${mediaErrorLabel(error)}',
        );
      }
    } finally {
      if (mounted) {
        _updateState(() => _nextEpisodeBusy = false);
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
      _updateState(() => _playbackSpeed = speed);
      await _controller?.setPlaybackSpeed(speed);
    } catch (_) {
      // Disabled preferences or a missing test platform never blocks playback.
    }
  }
}
