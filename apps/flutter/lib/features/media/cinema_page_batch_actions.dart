part of 'cinema_page.dart';

extension _CinemaPageBatchActions on _CinemaPageState {
  void _toggleFilmSelection(CinemaFilm film) {
    if (_batchBusy) return;
    HapticFeedback.selectionClick();
    _updateState(() {
      _selecting = true;
      if (!_selectedFilmIds.remove(film.id)) {
        if (_selectedFilmIds.length >= 50) {
          _actionMessage = '每次最多选择 50 部影片。';
          _actionIsError = true;
        } else {
          _selectedFilmIds.add(film.id);
        }
      }
    });
  }

  void _selectVisibleFilms() {
    if (_batchBusy) return;
    final visible = _films.take(50).map((film) => film.id).toSet();
    _updateState(() {
      _selecting = true;
      if (visible.every(_selectedFilmIds.contains)) {
        _selectedFilmIds.removeAll(visible);
      } else {
        _selectedFilmIds
          ..clear()
          ..addAll(visible);
      }
    });
  }

  void _endFilmSelection() {
    if (_batchBusy) return;
    _updateState(() {
      _selecting = false;
      _selectedFilmIds.clear();
    });
  }

  List<CinemaFilm> get _selectedFilms => _films
      .where((film) => _selectedFilmIds.contains(film.id))
      .toList(growable: false);

  Future<void> _batchSaveFilms() async {
    if (_batchBusy || _selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.length != _selectedFilmIds.length ||
        films.any((film) => film.path.isEmpty)) {
      _updateState(() {
        _actionMessage = '影片列表已变化，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    _updateState(() {
      _batchBusy = true;
      _actionMessage = null;
    });
    try {
      final message = await exportSelectedFiles(
        widget.api,
        items: [
          for (final film in films)
            (path: film.path, name: film.path.split('/').last, size: film.size),
        ],
        onProgress: (done, total, _) {
          if (mounted) {
            _updateState(() {
              _actionMessage = '正在保存影片 $done/$total';
              _actionIsError = false;
            });
          }
        },
      );
      if (mounted) {
        _updateState(() {
          _actionMessage = message;
          _actionIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = '批量保存失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _batchBusy = false);
    }
  }

  Future<void> _batchShareFilms() async {
    if (_batchBusy || _selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.length != _selectedFilmIds.length ||
        films.length > 10 ||
        films.any((film) => film.path.isEmpty)) {
      _updateState(() {
        _actionMessage = '每次最多分享 10 部影片，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final listGeneration = _listGeneration;
    final selected = Set<int>.unmodifiable(_selectedFilmIds);
    bool stillCurrent() =>
        mounted &&
        listGeneration == _listGeneration &&
        (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity &&
        selected.length == _selectedFilmIds.length &&
        selected.every(_selectedFilmIds.contains);
    final confirmed = await confirmAction(
      context,
      '分享所选影片',
      '为 ${films.length} 部影片创建各自有效期 24 小时的公开下载链接。拿到链接的人无需登录。',
      action: '创建并复制链接',
    );
    if (!confirmed || !mounted) return;
    if (!stillCurrent()) {
      _updateState(() {
        _actionMessage = '影视库或共享磁盘已变化，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    _updateState(() => _batchBusy = true);
    try {
      final result = await MediaBatchOperations(widget.api).createShares(
        items: [for (final film in films) (path: film.path, label: film.title)],
        stillCurrent: stillCurrent,
      );
      if (!mounted) return;
      if (result.cancelled || !stillCurrent()) {
        _updateState(() {
          _actionMessage = '共享磁盘已变化，分享已停止。若已创建链接，请在原硬盘的分享列表撤销。';
          _actionIsError = true;
        });
        return;
      }
      String? failure = result.error == null
          ? null
          : mediaErrorLabel(result.error!);
      if (result.links.isNotEmpty) {
        try {
          await Clipboard.setData(ClipboardData(text: result.links.join('\n')));
        } catch (_) {
          failure ??= '无法复制链接，请进入文件分享列表撤销并重试。';
        }
      }
      if (!mounted || !stillCurrent()) return;
      _updateState(() {
        _actionMessage = failure == null
            ? '已创建并复制 ${result.completed} 条限时链接。'
            : '已创建 ${result.completed} 条链接，后续失败：$failure';
        _actionIsError = failure != null;
      });
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = '批量分享失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _batchBusy = false);
    }
  }

  Future<void> _batchTrashFilms() async {
    if (_batchBusy || _selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.any((film) => !(widget.isAdmin || film.canWrite))) {
      _updateState(() {
        _actionMessage = '所选影片中有只读文件，请取消选择后重试。';
        _actionIsError = true;
      });
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final generation = _listGeneration;
    final selectedIDs = Set<int>.unmodifiable(_selectedFilmIds);
    bool stillCurrent() =>
        mounted &&
        _listGeneration == generation &&
        (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity &&
        setEquals(_selectedFilmIds, selectedIDs);
    if (films.length != _selectedFilmIds.length ||
        films.any((film) => film.path.isEmpty)) {
      _updateState(() {
        _actionMessage = '影片列表已变化，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    final confirmed = await confirmAction(
      context,
      '批量移到回收站',
      '将 ${films.length} 部影片的原文件移到回收站？影视库会在下次扫描后同步。',
      action: '移入回收站',
    );
    if (!confirmed || !stillCurrent()) return;
    _updateState(() => _batchBusy = true);
    try {
      final result = await MediaBatchOperations(widget.api).trashOriginals(
        paths: [for (final film in films) film.path],
        stillCurrent: stillCurrent,
      );
      if (result.cancelled || !stillCurrent()) {
        if (mounted) {
          _updateState(() {
            _actionMessage = '共享磁盘或所选影片已变化，请回原目录核对回收站。';
            _actionIsError = true;
          });
        }
        return;
      }
      await _loadFilms(reset: true);
      if (mounted) {
        _updateState(() {
          _actionMessage =
              '已移入回收站 ${result.completed}/${films.length} 项。影视库将在下次扫描后更新。';
          _actionIsError = result.error != null;
          _selecting = false;
        });
      }
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = '批量删除失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _batchBusy = false);
    }
  }
}
