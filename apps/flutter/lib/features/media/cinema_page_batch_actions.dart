part of 'cinema_page.dart';

extension _CinemaPageBatchActions on _CinemaPageState {
  void _toggleFilmSelection(CinemaFilm film) {
    if (_selection.batchBusy) return;
    HapticFeedback.selectionClick();
    _updateState(() {
      _selection.selecting = true;
      if (!_selection.selectedFilmIds.remove(film.id)) {
        if (_selection.selectedFilmIds.length >= 50) {
          _catalog.actionMessage = '每次最多选择 50 部影片。';
          _catalog.actionIsError = true;
        } else {
          _selection.selectedFilmIds.add(film.id);
        }
      }
    });
  }

  void _selectVisibleFilms() {
    if (_selection.batchBusy) return;
    final visible = _catalog.films.take(50).map((film) => film.id).toSet();
    _updateState(() {
      _selection.selecting = true;
      if (visible.every(_selection.selectedFilmIds.contains)) {
        _selection.selectedFilmIds.removeAll(visible);
      } else {
        _selection.selectedFilmIds
          ..clear()
          ..addAll(visible);
      }
    });
  }

  void _endFilmSelection() {
    if (_selection.batchBusy) return;
    _updateState(_selection.clear);
  }

  List<CinemaFilm> get _selectedFilms => _catalog.films
      .where((film) => _selection.selectedFilmIds.contains(film.id))
      .toList(growable: false);

  Future<void> _batchSaveFilms() async {
    if (_selection.batchBusy || _selection.selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.length != _selection.selectedFilmIds.length ||
        films.any((film) => film.path.isEmpty)) {
      _updateState(() {
        _catalog.actionMessage = '影片列表已变化，请重新选择。';
        _catalog.actionIsError = true;
      });
      return;
    }
    _updateState(() {
      _selection.batchBusy = true;
      _catalog.actionMessage = null;
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
              _catalog.actionMessage = '正在保存影片 $done/$total';
              _catalog.actionIsError = false;
            });
          }
        },
      );
      if (mounted) {
        _updateState(() {
          _catalog.actionMessage = message;
          _catalog.actionIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _catalog.actionMessage = '批量保存失败：${mediaErrorLabel(error)}';
          _catalog.actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _selection.batchBusy = false);
    }
  }

  Future<void> _batchShareFilms() async {
    if (_selection.batchBusy || _selection.selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.length != _selection.selectedFilmIds.length ||
        films.length > 10 ||
        films.any((film) => film.path.isEmpty)) {
      _updateState(() {
        _catalog.actionMessage = '每次最多分享 10 部影片，请重新选择。';
        _catalog.actionIsError = true;
      });
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final listGeneration = _catalog.listGeneration;
    final selected = Set<int>.unmodifiable(_selection.selectedFilmIds);
    bool stillCurrent() =>
        mounted &&
        listGeneration == _catalog.listGeneration &&
        (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity &&
        selected.length == _selection.selectedFilmIds.length &&
        selected.every(_selection.selectedFilmIds.contains);
    final confirmed = await confirmAction(
      context,
      '分享所选影片',
      '为 ${films.length} 部影片创建各自有效期 24 小时的公开下载链接。拿到链接的人无需登录。',
      action: '创建并复制链接',
    );
    if (!confirmed || !mounted) return;
    if (!stillCurrent()) {
      _updateState(() {
        _catalog.actionMessage = '影视库或共享磁盘已变化，请重新选择。';
        _catalog.actionIsError = true;
      });
      return;
    }
    _updateState(() => _selection.batchBusy = true);
    try {
      final result = await MediaBatchOperations(widget.api).createShares(
        items: [for (final film in films) (path: film.path, label: film.title)],
        stillCurrent: stillCurrent,
      );
      if (!mounted) return;
      if (result.cancelled || !stillCurrent()) {
        _updateState(() {
          _catalog.actionMessage = '共享磁盘已变化，分享已停止。若已创建链接，请在原硬盘的分享列表撤销。';
          _catalog.actionIsError = true;
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
        _catalog.actionMessage = failure == null
            ? '已创建并复制 ${result.completed} 条限时链接。'
            : '已创建 ${result.completed} 条链接，后续失败：$failure';
        _catalog.actionIsError = failure != null;
      });
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _catalog.actionMessage = '批量分享失败：${mediaErrorLabel(error)}';
          _catalog.actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _selection.batchBusy = false);
    }
  }

  Future<void> _batchTrashFilms() async {
    if (_selection.batchBusy || _selection.selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.any((film) => !(widget.isAdmin || film.canWrite))) {
      _updateState(() {
        _catalog.actionMessage = '所选影片中有只读文件，请取消选择后重试。';
        _catalog.actionIsError = true;
      });
      return;
    }
    final rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    final generation = _catalog.listGeneration;
    final selectedIDs = Set<int>.unmodifiable(_selection.selectedFilmIds);
    bool stillCurrent() =>
        mounted &&
        _catalog.listGeneration == generation &&
        (widget.api.selectedRoot?.identity ?? 'default') == rootIdentity &&
        setEquals(_selection.selectedFilmIds, selectedIDs);
    if (films.length != _selection.selectedFilmIds.length ||
        films.any((film) => film.path.isEmpty)) {
      _updateState(() {
        _catalog.actionMessage = '影片列表已变化，请重新选择。';
        _catalog.actionIsError = true;
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
    _updateState(() => _selection.batchBusy = true);
    try {
      final result = await MediaBatchOperations(widget.api).trashOriginals(
        paths: [for (final film in films) film.path],
        stillCurrent: stillCurrent,
      );
      if (result.cancelled || !stillCurrent()) {
        if (mounted) {
          _updateState(() {
            _catalog.actionMessage = '共享磁盘或所选影片已变化，请回原目录核对回收站。';
            _catalog.actionIsError = true;
          });
        }
        return;
      }
      await _loadFilms(reset: true);
      if (mounted) {
        _updateState(() {
          _catalog.actionMessage =
              '已移入回收站 ${result.completed}/${films.length} 项。影视库将在下次扫描后更新。';
          _catalog.actionIsError = result.error != null;
          _selection.selecting = false;
        });
      }
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _catalog.actionMessage = '批量删除失败：${mediaErrorLabel(error)}';
          _catalog.actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _selection.batchBusy = false);
    }
  }
}
