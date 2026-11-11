part of 'photos_page.dart';

extension _PhotosPageAIAndTimeline on _PhotosPageState {
  Future<void> _refreshFacets() async {
    try {
      final response = await widget.api.get('/api/v2/photos/facets');
      if (!mounted) return;
      final cameras = (response['cameras'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      final years = (response['years'] as List<dynamic>? ?? const [])
          .map((e) => int.tryParse(e.toString()) ?? 0)
          .where((e) => e >= 1970)
          .toList();
      _updateState(() {
        _facetCameras = cameras;
        _facetYears = years;
      });
    } catch (_) {
      if (mounted) {
        _updateState(() {
          _facetCameras = const [];
          _facetYears = const [];
        });
      }
    }
  }

  Future<void> _refreshTimelineIndex() async {
    final generation = ++_timelineIndexGeneration;
    try {
      final response = await widget.api.get('/api/v2/photos/timeline');
      if (!mounted || generation != _timelineIndexGeneration) return;
      _updateState(
        () => _timelineMonths = PhotoTimelineMonth.parse(response['months']),
      );
    } catch (_) {
      if (mounted && generation == _timelineIndexGeneration) {
        _updateState(() => _timelineMonths = const []);
      }
    }
  }

  Future<void> _jumpToTimelineMonth(PhotoTimelineMonth month) async {
    if (!_fullTimelineSelected || _loading || _loadingMore) return;
    await _loadAssets(reset: true, startCursor: month.firstIndex);
    if (!mounted || _loadError != null) return;
    _updateState(() => _timelineActiveFirstIndex = month.firstIndex);
    if (_timelineScroll.hasClients) {
      _timelineScroll.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
      final heading = _firstMonthHeadingKey.currentContext;
      if (mounted && heading != null && heading.mounted) {
        await Scrollable.ensureVisible(heading, alignment: .08);
      }
    }
  }

  Future<void> _chooseTimelineMonth() async {
    if (!_fullTimelineSelected || _loading) return;
    if (_timelineMonths.isEmpty) await _refreshTimelineIndex();
    if (!mounted) return;
    if (_timelineMonths.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂时无法读取拍摄年月，请检查网络并重试。')));
      return;
    }
    final month = await showModalBottomSheet<PhotoTimelineMonth>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .65,
          child: Column(
            children: [
              const ListTile(
                title: Text('跳转到拍摄年月'),
                subtitle: Text('可直接跳转至尚未加载的历史照片，不必逐页滚动。'),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _timelineMonths.length,
                  itemBuilder: (context, index) {
                    final month = _timelineMonths[index];
                    return ListTile(
                      leading: const Icon(Icons.calendar_month_outlined),
                      title: Text(month.label),
                      trailing: Text('${month.count} 项'),
                      onTap: () => Navigator.pop(sheetContext, month),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (month != null && mounted) await _jumpToTimelineMonth(month);
  }

  Future<void> _openPeoplePage() async {
    final selected = await Navigator.of(context).push<PersonSummary>(
      MaterialPageRoute<PersonSummary>(
        builder: (_) => PhotoPeoplePage(api: widget.api),
      ),
    );
    if (!mounted || selected == null) return;
    _updateState(() {
      _activePersonId = selected.id;
      _activePersonName = selected.displayName;
      _activeAlbum = 0;
      _activePrivateAlbum = 0;
      _activeFolderPath = '';
      _activeFolderName = '';
      _favoritesOnly = false;
      _personalFavoritesOnly = false;
      _onThisDay = false;
    });
    await _loadAssets(reset: true);
  }

  Future<void> _openSimilarCleanupPage() async {
    final trashed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PhotoSimilarCleanupPage(api: widget.api),
      ),
    );
    if (trashed == true && mounted) {
      await Future.wait([_loadAssets(reset: true), _refreshStatus()]);
    }
  }

  Future<void> _toggleAIPause() async {
    if (_aiPauseBusy) return;
    final nextPaused = !_scanStatus.aiPaused;
    _updateState(() => _aiPauseBusy = true);
    try {
      await PhotoAIRepository(widget.api).setAIPaused(nextPaused);
      if (!mounted) return;
      _updateState(() {
        _actionMessage = nextPaused ? '已暂停后台智能识图索引' : '已恢复后台智能识图索引';
        _actionIsError = false;
      });
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        _updateState(() {
          _actionMessage = mediaErrorLabel(e);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) _updateState(() => _aiPauseBusy = false);
    }
  }

  Widget _buildAIIndexBanner() {
    if (!_scanStatus.aiRunning && !_scanStatus.aiPaused) {
      return const SizedBox.shrink();
    }
    final remaining = _scanStatus.aiRemaining;
    final text = _scanStatus.aiPaused
        ? '后台离线智能识图已暂停${remaining > 0 ? '（剩余 $remaining 张待索引）' : ''}'
        : '正在后台离线建立智能识图与 OCR 索引${remaining > 0 ? ' · 剩余 $remaining 张' : ''}';
    return MediaStatusBanner(
      message: text,
      icon: _scanStatus.aiPaused
          ? Icons.pause_circle_outline_rounded
          : Icons.auto_awesome_outlined,
      trailing: widget.isAdmin
          ? TextButton(
              onPressed: _aiPauseBusy ? null : _toggleAIPause,
              child: Text(_scanStatus.aiPaused ? '继续' : '暂停'),
            )
          : null,
    );
  }
}
