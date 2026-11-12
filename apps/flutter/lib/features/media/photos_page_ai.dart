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
        _scope.facetCameras = cameras;
        _scope.facetYears = years;
      });
    } catch (_) {
      if (mounted) {
        _updateState(() {
          _scope.facetCameras = const [];
          _scope.facetYears = const [];
        });
      }
    }
  }

  Future<void> _refreshTimelineIndex() async {
    final generation = ++_timeline.indexGeneration;
    try {
      final response = await widget.api.get('/api/v2/photos/timeline');
      if (!mounted || generation != _timeline.indexGeneration) return;
      _updateState(
        () => _timeline.months = PhotoTimelineMonth.parse(response['months']),
      );
    } catch (_) {
      if (mounted && generation == _timeline.indexGeneration) {
        _updateState(() => _timeline.months = const []);
      }
    }
  }

  Future<void> _jumpToTimelineMonth(PhotoTimelineMonth month) async {
    if (!_fullTimelineSelected || _feed.loading || _feed.loadingMore) return;
    await _loadAssets(reset: true, startCursor: month.firstIndex);
    if (!mounted || _feed.loadError != null) return;
    _updateState(() => _timeline.activeFirstIndex = month.firstIndex);
    if (_timeline.scrollController.hasClients) {
      _timeline.scrollController.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
      final heading = _timeline.firstMonthHeadingKey.currentContext;
      if (mounted && heading != null && heading.mounted) {
        await Scrollable.ensureVisible(heading, alignment: .08);
      }
    }
  }

  Future<void> _chooseTimelineMonth() async {
    if (!_fullTimelineSelected || _feed.loading) return;
    if (_timeline.months.isEmpty) await _refreshTimelineIndex();
    if (!mounted) return;
    if (_timeline.months.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法读取拍摄年月，请检查网络并重试。')));
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
                  itemCount: _timeline.months.length,
                  itemBuilder: (context, index) {
                    final month = _timeline.months[index];
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
      _scope.setCollectionScope(
        personId: selected.id,
        personName: selected.displayName,
      );
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
    if (_scan.aiPauseBusy) return;
    final nextPaused = !_scan.status.aiPaused;
    _updateState(() => _scan.aiPauseBusy = true);
    try {
      await PhotoAIRepository(widget.api).setAIPaused(nextPaused);
      if (!mounted) return;
      _updateState(
        () => _feed.setActionFeedback(
          nextPaused ? '已暂停后台智能识图索引' : '已恢复后台智能识图索引',
        ),
      );
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        _updateState(
          () => _feed.setActionFeedback(mediaErrorLabel(e), isError: true),
        );
      }
    } finally {
      if (mounted) _updateState(() => _scan.aiPauseBusy = false);
    }
  }

  Widget _buildAIIndexBanner() {
    if (!_scan.status.aiRunning && !_scan.status.aiPaused) {
      return const SizedBox.shrink();
    }
    final remaining = _scan.status.aiRemaining;
    final text = _scan.status.aiPaused
        ? '后台离线智能识图已暂停${remaining > 0 ? '（剩余 $remaining 张待索引）' : ''}'
        : '正在后台离线建立智能识图与 OCR 索引${remaining > 0 ? ' · 剩余 $remaining 张' : ''}';
    return MediaStatusBanner(
      message: text,
      icon: _scan.status.aiPaused
          ? Icons.pause_circle_outline_rounded
          : Icons.auto_awesome_outlined,
      trailing: widget.isAdmin
          ? TextButton(
              onPressed: _scan.aiPauseBusy ? null : _toggleAIPause,
              child: Text(_scan.status.aiPaused ? '继续' : '暂停'),
            )
          : null,
    );
  }
}
