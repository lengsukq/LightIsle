part of 'cinema_page.dart';

extension _CinemaPageLibrary on _CinemaPageState {
  Future<void> _loadShelves() async {
    final generation = ++_shelfGeneration;
    try {
      final replies = await Future.wait([
        widget.api.get(
          '/api/v2/cinema',
          query: const {'kind': 'continue', 'limit': '8', 'cursor': '0'},
        ),
        widget.api.get(
          '/api/v2/cinema',
          query: const {'kind': 'recent', 'limit': '8', 'cursor': '0'},
        ),
      ]);
      if (!mounted || generation != _shelfGeneration) return;
      List<CinemaFilm> parse(Map<String, dynamic> response) =>
          MediaPageResult.parse<CinemaFilm>(
            response,
            itemsKey: 'films',
            fromJson: CinemaFilm.fromJson,
          ).items;
      _updateState(() {
        _resumeShelf
          ..clear()
          ..addAll(parse(replies[0]).where((film) => film.canResume));
        _recentShelf
          ..clear()
          ..addAll(parse(replies[1]));
        _shelvesLoaded = true;
      });
    } catch (_) {
      // The standard library remains available even if a secondary shelf
      // fails to load, including when connecting to an older NAS build.
      if (mounted && generation == _shelfGeneration) {
        _updateState(() => _shelvesLoaded = false);
      }
    }
  }

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
    final cacheKey = Uri(queryParameters: query).query;
    if (reset) {
      final cached = IsleDataCache.instance.getJsonMap(
        widget.api,
        'cinema',
        cacheKey,
      );
      if (cached != null) {
        final cachedPage = MediaPageResult.parse<CinemaFilm>(
          cached,
          itemsKey: 'films',
          fromJson: CinemaFilm.fromJson,
        );
        _updateState(() {
          _films
            ..clear()
            ..addAll(cachedPage.items);
          _nextCursor = cachedPage.nextCursor;
          _loading = false;
        });
      }
    }
    try {
      final response = await widget.api.get('/api/v2/cinema', query: query);
      if (!mounted || generation != _listGeneration) return;
      if (reset) {
        IsleDataCache.instance.putJsonMap(
          widget.api,
          'cinema',
          cacheKey,
          response,
        );
      }
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
      final scrapeError =
          status.lastError.isEmpty || status.lastError == 'cancelled'
          ? null
          : mediaErrorLabel(status.lastError);
      _updateState(() {
        _scanStatus = status;
        _scanning = status.running;
        _scanError = scrapeError;
      });
      if (finished) {
        await Future.wait([
          _loadFilms(reset: true),
          _loadShelves(),
          if (_showSeries) _loadSeries(),
          if (widget.isAdmin && (_mode == 'unmatched' || _showSeries))
            _refreshScrape(),
        ]);
      }
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
      _updateState(() => _query = value.trim());
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

  List<CinemaFilm> _candidatePlaylist([Iterable<CinemaFilm> extra = const []]) =>
      <CinemaFilm>[
        ...extra,
        ..._films,
        ..._resumeShelf,
        ..._recentShelf,
        ..._history,
      ];

  Future<void> _openFilm(CinemaFilm film) => _openFilmPlayer(film);

  Future<void> _openFilmPlayer(
    CinemaFilm film, {
    List<CinemaFilm> playlist = const [],
  }) async {
    HapticFeedback.selectionClick();
    // A dialog returns the next episode only after the old player has saved
    // progress and closed. No two video controllers overlap during a switch.
    CinemaFilm? next = film;
    var activePlaylist = _candidatePlaylist(playlist);
    while (next != null && mounted) {
      if (!mounted) break;
      final current = next;
      if (!activePlaylist.any((item) => item.id == current.id)) {
        activePlaylist = <CinemaFilm>[...activePlaylist, current];
      }
      Widget detail() => CinemaDetailDialog(
        api: widget.api,
        film: current,
        playlist: activePlaylist,
        isAdmin: widget.isAdmin,
        accountName: widget.accountName,
        onRename: _renameFilm,
        onProgressUpdated: (updated) {
          _updateProgress(updated);
          final idx = activePlaylist.indexWhere((f) => f.id == updated.id);
          if (idx >= 0) {
            activePlaylist = <CinemaFilm>[...activePlaylist]..[idx] = updated;
          }
        },
        playerOnly: true,
      );
      // Every platform uses one genuine full-screen player route. Keeping
      // the existing pop-result handshake ensures the previous decoder is
      // fully disposed before the next episode begins.
      next = await Navigator.of(context).push<CinemaFilm>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => detail()),
      );
    }
    if (mounted) {
      await Future.wait([
        _loadFilms(reset: true),
        _loadShelves(),
        if (_showHistory) _loadHistory(),
      ]);
    }
  }

  Future<void> _openFilmDetails(CinemaFilm film) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CinemaFilmOverview(
          api: widget.api,
          film: film,
          isAdmin: widget.isAdmin,
          memoryCache: _posterCache,
          onRename: _renameFilm,
          onUpdated: _updateProgress,
          onPlay: () => _openFilmPlayer(film),
        ),
      ),
    );
    if (mounted) {
      await Future.wait([
        _loadFilms(reset: true),
        _loadShelves(),
        if (_showHistory) _loadHistory(),
      ]);
    }
  }
}
