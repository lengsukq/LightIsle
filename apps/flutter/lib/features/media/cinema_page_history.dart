part of 'cinema_page.dart';

extension _CinemaPageHistory on _CinemaPageState {
  Future<void> _loadHistory({bool reset = true}) async {
    if (_subpages.historyLoading) return;
    if (!reset && _subpages.historyNext == 0) return;
    _updateState(() {
      _subpages.historyLoading = true;
      _subpages.historyError = null;
    });
    try {
      final response = await widget.api.get(
        '/api/v2/cinema/history',
        query: <String, String>{
          'limit': '48',
          'cursor': '${reset ? 0 : _subpages.historyNext}',
        },
      );
      final page = <CinemaFilm>[];
      final raw = response['films'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            try {
              page.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
            } on FormatException {
              // Skip malformed rows while keeping usable entries.
            }
          }
        }
      }
      final next = response['nextCursor'];
      if (!mounted) return;
      _updateState(() {
        if (reset) {
          _subpages.history
            ..clear()
            ..addAll(page);
        } else {
          _subpages.history.addAll(page);
        }
        _subpages.historyNext = next is num
            ? next.toInt()
            : int.tryParse('$next') ?? 0;
        _subpages.historyLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        _subpages.historyLoading = false;
        _subpages.historyError = mediaErrorLabel(error);
      });
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看历史？'),
        content: const Text('将删除当前账号全部影片的续播进度与已看标记，不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.send('DELETE', '/api/v2/cinema/history');
      if (!mounted) return;
      _updateState(() {
        _subpages.history.clear();
        _subpages.historyNext = 0;
      });
      unawaited(_loadFilms(reset: true));
    } catch (error) {
      if (mounted) {
        _updateState(() => _subpages.historyError = mediaErrorLabel(error));
      }
    }
  }

  List<Widget> _historyView() {
    final theme = Theme.of(context);
    return <Widget>[
      if (_subpages.historyLoading && _subpages.history.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 30),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_subpages.historyError != null && _subpages.history.isEmpty)
        MediaStatusBanner(
          message: '历史读取失败：${_subpages.historyError}',
          isError: true,
          icon: Icons.error_outline,
          trailing: TextButton(
            onPressed: () => _loadHistory(),
            child: const Text('重试'),
          ),
        )
      else if (_subpages.history.isEmpty)
        MediaEmptyState(
          icon: Icons.history_rounded,
          title: '还没有观看记录',
          message: '播放过的影片和剧集会按时间出现在这里。',
        )
      else ...<Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(_pageInset, 4, _pageInset, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '仅当前账号可见，按最近观看排序',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(onPressed: _clearHistory, child: const Text('清空历史')),
            ],
          ),
        ),
        IsleGroupCard(
          margin: EdgeInsets.fromLTRB(_pageInset, 8, _pageInset, 0),
          children: [
            for (final film in _subpages.history)
              ListTile(
                leading: Icon(
                  film.isSeries ? Icons.live_tv_outlined : Icons.movie_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(
                  film.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  film.completed
                      ? '已看完 · ${_historyLabel(film)}'
                      : '看到 ${film.duration > 0 ? (film.position / film.duration * 100).clamp(0, 100).toStringAsFixed(0) : 0}% · ${_historyLabel(film)}',
                ),
                trailing: const Icon(Icons.play_circle_outline),
                onTap: () => unawaited(_openFilmPlayer(film)),
              ),
          ],
        ),
        if (_subpages.historyNext > 0)
          Padding(
            padding: EdgeInsets.fromLTRB(_pageInset, 10, _pageInset, 0),
            child: Center(
              child: _subpages.historyLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton(
                      onPressed: () => _loadHistory(reset: false),
                      child: const Text('加载更多记录'),
                    ),
            ),
          ),
      ],
    ];
  }

  String _historyLabel(CinemaFilm film) {
    return film.isSeries ? '第 ${film.season} 季第 ${film.episode} 集' : '电影';
  }
}
