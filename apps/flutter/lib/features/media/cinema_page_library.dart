part of 'cinema_page.dart';

extension _CinemaPageLibrary on _CinemaPageState {
  Future<void> _loadFilms({required bool reset}) async {
    if (!reset && (_loading || _loadingMore || _nextCursor == 0)) return;
    final generation = ++_listGeneration;
    final cursor = reset ? 0 : _nextCursor;
    _updateState(() {
      if (reset) {
        _films.clear();
        _nextCursor = 0;
        _loadError = null;
        _loading = true;
        _selectedFilmIds.clear();
      } else {
        _loadingMore = true;
      }
    });
    final query = <String, String>{
      'limit': '${_CinemaPageState._pageSize}',
      'cursor': '$cursor',
    };
    if (_mode != 'all') query['kind'] = _mode;
    if (_query.trim().isNotEmpty) query['query'] = _query.trim();
    try {
      final response = await widget.api.get('/api/v2/cinema', query: query);
      if (!mounted || generation != _listGeneration) return;
      final page = MediaPageResult.parse<CinemaFilm>(
        response,
        itemsKey: 'films',
        fromJson: CinemaFilm.fromJson,
      );
      _updateState(() {
        if (reset) {
          _films
            ..clear()
            ..addAll(page.items);
        } else {
          _films.addAll(page.items);
        }
        _nextCursor = page.nextCursor;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _listGeneration) return;
      _updateState(() => _loadError = mediaErrorLabel(error));
    } finally {
      if (mounted && generation == _listGeneration) {
        _updateState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _refreshStatus() async {
    final generation = ++_statusGeneration;
    try {
      final response = await widget.api.get('/api/v2/cinema/status');
      if (!mounted || generation != _statusGeneration) return;
      final status = MediaScanStatus.fromJson(response['status']);
      final finished = _scanPoller.observe(status);
      _updateState(() {
        _scanStatus = status;
        _scanning = status.running;
        _scanError = status.lastError.isEmpty ? null : status.lastError;
      });
      if (finished) await _loadFilms(reset: true);
    } catch (_) {
      // The application shell owns session and service health feedback.
    }
  }

  Future<void> _startScan() async {
    _updateState(() {
      _actionMessage = null;
      _actionIsError = false;
    });
    try {
      await widget.api.send('POST', '/api/v2/cinema/scan');
      if (mounted) {
        _updateState(() {
          _actionMessage = '影视库扫描已开始。';
          _actionIsError = false;
        });
      }
      await _refreshStatus();
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    }
  }

  void _changeMode(String mode) {
    if (_mode == mode) return;
    _updateState(() => _mode = mode);
    _loadFilms(reset: true);
  }

  void _searchChanged(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _query = value.trim();
      _loadFilms(reset: true);
    });
  }

  Future<CinemaFilm> _renameFilm(CinemaFilm film) async {
    final controller = TextEditingController(text: film.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => FilmTitleDialog(controller: controller),
    );
    controller.dispose();
    if (title == null || title.trim().isEmpty || title.trim() == film.title) {
      return film;
    }
    final normalized = title.trim();
    await widget.api.send(
      'PATCH',
      '/api/v2/cinema/${film.id}',
      body: <String, String>{'title': normalized},
    );
    final updated = film.withTitle(normalized);
    if (mounted) {
      _updateState(() {
        final index = _films.indexWhere((item) => item.id == film.id);
        if (index >= 0) _films[index] = updated;
        _actionMessage = '影片展示名称已更新。';
        _actionIsError = false;
      });
    }
    return updated;
  }

  void _updateProgress(CinemaFilm updated) {
    if (!mounted) return;
    _updateState(() {
      final index = _films.indexWhere((film) => film.id == updated.id);
      if (index >= 0) {
        if (_mode == 'continue' && !updated.canResume) {
          _films.removeAt(index);
        } else {
          _films[index] = updated;
        }
      }
    });
  }

  Future<void> _openFilm(CinemaFilm film) async {
    HapticFeedback.selectionClick();
    // A dialog returns the next episode only after the old player has saved
    // progress and closed. No two video controllers overlap during a switch.
    CinemaFilm? next = film;
    while (next != null && mounted) {
      if (!mounted) break;
      final current = next;
      Widget detail() => CinemaDetailDialog(
        api: widget.api,
        film: current,
        isAdmin: widget.isAdmin,
        accountName: widget.accountName,
        onRename: _renameFilm,
        onProgressUpdated: _updateProgress,
      );
      if (MediaQuery.sizeOf(context).width < 600) {
        // Mobile uses a real page instead of nesting a desktop-style modal.
        // The existing close/next-episode handshake still owns the player.
        next = await Navigator.of(context).push<CinemaFilm>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (context) => Scaffold(body: SafeArea(child: detail())),
          ),
        );
      } else {
        next = await showDialog<CinemaFilm>(
          context: context,
          useSafeArea: true,
          barrierDismissible: false,
          barrierColor: Colors.black.withValues(alpha: 0.65),
          builder: (context) => detail(),
        );
      }
    }
    if (mounted) await _loadFilms(reset: true);
  }
}
