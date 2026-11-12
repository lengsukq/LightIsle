part of 'cinema_page.dart';

extension _CinemaPageLibrary on _CinemaPageState {
  Future<void> _loadShelves() async {
    final generation = ++_catalog.shelfGeneration;
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
      if (!mounted || generation != _catalog.shelfGeneration) return;
      List<CinemaFilm> parse(Map<String, dynamic> response) =>
          MediaPageResult.parse<CinemaFilm>(
            response,
            itemsKey: 'films',
            fromJson: CinemaFilm.fromJson,
          ).items;
      _updateState(() {
        _catalog.resumeShelf
          ..clear()
          ..addAll(parse(replies[0]).where((film) => film.canResume));
        _catalog.recentShelf
          ..clear()
          ..addAll(parse(replies[1]));
        _catalog.shelvesLoaded = true;
      });
    } catch (_) {
      if (mounted && generation == _catalog.shelfGeneration) {
        _updateState(() => _catalog.shelvesLoaded = false);
      }
    }
  }

  Future<void> _loadFilms({required bool reset}) async {
    if (!reset &&
        (_catalog.loading ||
            _catalog.loadingMore ||
            _catalog.nextCursor == 0)) {
      return;
    }
    final generation = ++_catalog.listGeneration;
    final cursor = reset ? 0 : _catalog.nextCursor;
    _updateState(() {
      if (reset) {
        _catalog.films.clear();
        _catalog.nextCursor = 0;
        _catalog.loadError = null;
        _catalog.loading = true;
        _selection.selectedFilmIds.clear();
      } else {
        _catalog.loadingMore = true;
      }
    });
    final query = <String, String>{
      'limit': '${_CinemaPageState._pageSize}',
      'cursor': '$cursor',
    };
    if (_catalog.mode != 'all') query['kind'] = _catalog.mode;
    if (_catalog.query.trim().isNotEmpty) query['query'] = _catalog.query.trim();
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
          _catalog.films
            ..clear()
            ..addAll(cachedPage.items);
          _catalog.nextCursor = cachedPage.nextCursor;
          _catalog.loading = false;
        });
      }
    }
    try {
      final response = await widget.api.get('/api/v2/cinema', query: query);
      if (!mounted || generation != _catalog.listGeneration) return;
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
          _catalog.films
            ..clear()
            ..addAll(page.items);
        } else {
          _catalog.films.addAll(page.items);
        }
        _catalog.nextCursor = page.nextCursor;
        _catalog.loadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _catalog.listGeneration) return;
      _updateState(() => _catalog.loadError = mediaErrorLabel(error));
    } finally {
      if (mounted && generation == _catalog.listGeneration) {
        _updateState(() {
          _catalog.loading = false;
          _catalog.loadingMore = false;
        });
      }
    }
  }

  Future<void> _refreshStatus() async {
    final generation = ++_indexing.statusGeneration;
    try {
      final response = await widget.api.get('/api/v2/cinema/status');
      if (!mounted || generation != _indexing.statusGeneration) return;
      final status = MediaScanStatus.fromJson(response['status']);
      final finished = _scanPoller.observe(status);
      final scrapeError =
          status.lastError.isEmpty || status.lastError == 'cancelled'
          ? null
          : mediaErrorLabel(status.lastError);
      _updateState(() {
        _indexing.scanStatus = status;
        _indexing.scanning = status.running;
        _indexing.scanError = scrapeError;
      });
      if (finished) {
        await Future.wait([
          _loadFilms(reset: true),
          _loadShelves(),
          if (_subpages.showSeries) _loadSeries(),
          if (widget.isAdmin &&
              (_catalog.mode == 'unmatched' || _subpages.showSeries))
            _refreshScrape(),
        ]);
      }
    } catch (_) {
      // The application shell owns session and service health feedback.
    }
  }

  Future<void> _startScan() async {
    _updateState(() {
      _catalog.actionMessage = null;
      _catalog.actionIsError = false;
    });
    try {
      await widget.api.send('POST', '/api/v2/cinema/scan');
      if (mounted) {
        _updateState(() {
          _catalog.actionMessage = '影视库扫描已开始。';
          _catalog.actionIsError = false;
        });
      }
      await _refreshStatus();
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _catalog.actionMessage = mediaErrorLabel(error);
          _catalog.actionIsError = true;
        });
      }
    }
  }

  void _changeMode(String mode) {
    if (_catalog.mode == mode) return;
    _updateState(() => _catalog.mode = mode);
    _loadFilms(reset: true);
  }

  void _searchChanged(String value) {
    _catalog.searchTimer?.cancel();
    _catalog.searchTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _updateState(() => _catalog.query = value.trim());
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
        final index = _catalog.films.indexWhere((item) => item.id == film.id);
        if (index >= 0) _catalog.films[index] = updated;
        _catalog.actionMessage = '影片展示名称已更新。';
        _catalog.actionIsError = false;
      });
    }
    return updated;
  }

  void _updateProgress(CinemaFilm updated) {
    if (!mounted) return;
    _updateState(() {
      final index = _catalog.films.indexWhere((film) => film.id == updated.id);
      if (index >= 0) {
        if (_catalog.mode == 'continue' && !updated.canResume) {
          _catalog.films.removeAt(index);
        } else {
          _catalog.films[index] = updated;
        }
      }
    });
  }

  List<CinemaFilm> _candidatePlaylist([
    Iterable<CinemaFilm> extra = const [],
  ]) => <CinemaFilm>[
    ...extra,
    ..._catalog.films,
    ..._catalog.resumeShelf,
    ..._catalog.recentShelf,
    ..._subpages.history,
  ];

  Future<void> _openFilm(CinemaFilm film) => _openFilmPlayer(film);

  Future<void> _openFilmPlayer(
    CinemaFilm film, {
    List<CinemaFilm> playlist = const [],
  }) async {
    HapticFeedback.selectionClick();
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
      next = await Navigator.of(context).push<CinemaFilm>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => detail()),
      );
    }
    if (mounted) {
      await Future.wait([
        _loadFilms(reset: true),
        _loadShelves(),
        if (_subpages.showHistory) _loadHistory(),
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
        if (_subpages.showHistory) _loadHistory(),
      ]);
    }
  }
}
