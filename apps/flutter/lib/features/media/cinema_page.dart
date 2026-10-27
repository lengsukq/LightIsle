import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'media_ui.dart';

class CinemaPage extends StatefulWidget {
  const CinemaPage({required this.api, required this.isAdmin, super.key});

  final LightIsleApi api;
  final bool isAdmin;

  @override
  State<CinemaPage> createState() => _CinemaPageState();
}

class _CinemaPageState extends State<CinemaPage> with WidgetsBindingObserver {
  static const int _pageSize = 48;

  final List<CinemaFilm> _films = [];
  final TextEditingController _searchController = TextEditingController();
  int _nextCursor = 0;
  int _listGeneration = 0;
  int _statusGeneration = 0;
  String _mode = 'all';
  String _query = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _scanning = false;
  bool _wasScanning = false;
  String? _loadError;
  String? _actionMessage;
  bool _actionIsError = false;
  String? _scanError;
  MediaScanStatus _scanStatus = const MediaScanStatus();
  int _lastDone = 0;
  Timer? _searchTimer;
  Timer? _statusTimer;
  bool _tabEnabled = true;
  bool _appForeground = true;
  bool _pollingActive = false;
  // Watch-history view.
  bool _showHistory = false;
  final List<CinemaFilm> _history = [];
  bool _historyLoading = false;
  String? _historyError;
  int _historyNext = 0;
  // Series aggregation view.
  bool _showSeries = false;
  final List<CinemaSeriesInfo> _series = [];
  bool _seriesLoading = false;
  String? _seriesError;
  // Server-side TMDB scrape (administrator).
  CinemaScrapeStatus? _scrapeStatus;
  bool _scrapeBusy = false;
  bool _scrapeRetryMisses = false;
  String? _scrapeMessage;

  @override
  void initState() {
    super.initState();
    _loadFilms(reset: true);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _listGeneration++;
    _statusGeneration++;
    _searchTimer?.cancel();
    _statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tabEnabled = TickerMode.valuesOf(context).enabled;
    _updatePollingState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    _updatePollingState();
  }

  void _updatePollingState() {
    final active = _tabEnabled && _appForeground;
    if (_pollingActive == active) return;
    _pollingActive = active;
    if (!active) {
      _statusTimer?.cancel();
      _statusTimer = null;
      _statusGeneration++;
    } else {
      _refreshStatus();
    }
  }

  void _syncStatusTimer() {
    if (!_pollingActive || !_scanning) {
      _statusTimer?.cancel();
      _statusTimer = null;
    } else {
      _statusTimer ??= Timer.periodic(
        const Duration(seconds: 3),
        (_) => _refreshStatus(),
      );
    }
  }

  Future<void> _loadFilms({required bool reset}) async {
    if (!reset && (_loading || _loadingMore || _nextCursor == 0)) return;
    final generation = ++_listGeneration;
    final cursor = reset ? 0 : _nextCursor;
    setState(() {
      if (reset) {
        _films.clear();
        _nextCursor = 0;
        _loadError = null;
        _loading = true;
      } else {
        _loadingMore = true;
      }
    });
    final query = <String, String>{'limit': '$_pageSize', 'cursor': '$cursor'};
    if (_mode != 'all') query['kind'] = _mode;
    if (_query.trim().isNotEmpty) query['query'] = _query.trim();
    try {
      final response = await widget.api.get('/api/v2/cinema', query: query);
      if (!mounted || generation != _listGeneration) return;
      final raw = response['films'];
      final page = <CinemaFilm>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            try {
              page.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
            } on FormatException {
              // Retain valid items when a legacy row lacks a valid identifier.
            }
          }
        }
      }
      final next = response['nextCursor'];
      final parsedNext = next is num
          ? next.toInt()
          : int.tryParse('$next') ?? 0;
      setState(() {
        if (reset) {
          _films
            ..clear()
            ..addAll(page);
        } else {
          _films.addAll(page);
        }
        _nextCursor = parsedNext;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _listGeneration) return;
      setState(() => _loadError = mediaErrorLabel(error));
    } finally {
      if (mounted && generation == _listGeneration) {
        setState(() {
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
      final finished =
          (_wasScanning && !status.running) ||
          (status.lastDone > 0 && status.lastDone > _lastDone);
      setState(() {
        _scanStatus = status;
        _scanning = status.running;
        _wasScanning = status.running;
        _lastDone = status.lastDone > _lastDone ? status.lastDone : _lastDone;
        _scanError = status.lastError.isEmpty ? null : status.lastError;
      });
      _syncStatusTimer();
      if (finished) await _loadFilms(reset: true);
    } catch (_) {
      // The application shell owns session and service health feedback.
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _actionMessage = null;
      _actionIsError = false;
    });
    try {
      await widget.api.send('POST', '/api/v2/cinema/scan');
      if (mounted) {
        setState(() {
          _actionMessage = '影视库扫描已开始。';
          _actionIsError = false;
        });
      }
      await _refreshStatus();
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    }
  }

  void _changeMode(String mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
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
      builder: (context) => _FilmTitleDialog(controller: controller),
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
      setState(() {
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
    setState(() {
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
      next = await showDialog<CinemaFilm>(
        context: context,
        useSafeArea: true,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.65),
        builder: (context) => CinemaDetailDialog(
          api: widget.api,
          film: next!,
          isAdmin: widget.isAdmin,
          onRename: _renameFilm,
          onProgressUpdated: _updateProgress,
        ),
      );
    }
  }

  Future<void> _loadHistory({bool reset = true}) async {
    if (_historyLoading) return;
    if (!reset && _historyNext == 0) return;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final response = await widget.api.get(
        '/api/v2/cinema/history',
        query: <String, String>{'limit': '48', 'cursor': '${reset ? 0 : _historyNext}'},
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
      setState(() {
        if (reset) {
          _history
            ..clear()
            ..addAll(page);
        } else {
          _history.addAll(page);
        }
        _historyNext = next is num ? next.toInt() : int.tryParse('$next') ?? 0;
        _historyLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _historyLoading = false;
        _historyError = mediaErrorLabel(error);
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.send('DELETE', '/api/v2/cinema/history');
      if (!mounted) return;
      setState(() {
        _history.clear();
        _historyNext = 0;
      });
      unawaited(_loadFilms(reset: true));
    } catch (error) {
      if (mounted) setState(() => _historyError = mediaErrorLabel(error));
    }
  }

  List<Widget> _historyView() {
    final theme = Theme.of(context);
    return <Widget>[
      if (_historyLoading && _history.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 30),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_historyError != null && _history.isEmpty)
        MediaStatusBanner(
          message: '历史读取失败：$_historyError',
          isError: true,
          icon: Icons.error_outline,
          trailing: TextButton(onPressed: () => _loadHistory(), child: const Text('重试')),
        )
      else if (_history.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
          child: Center(
            child: Text(
              '还没有观看记录；播放过的影片和剧集会按时间出现在这里。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        )
      else ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
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
        for (final film in _history)
          Card(
            margin: const EdgeInsets.fromLTRB(18, 8, 18, 0),
            child: ListTile(
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
              onTap: () => unawaited(_openFilm(film)),
            ),
          ),
        if (_historyNext > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Center(
              child: _historyLoading
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
    // CinemaFilm currently keeps no watch timestamp; the ordering already
    // reflects recency, so the label stays positional.
    return film.isSeries ? '第 ${film.season} 季第 ${film.episode} 集' : '电影';
  }

  Future<void> _loadSeries() async {
    if (_seriesLoading) return;
    setState(() {
      _seriesLoading = true;
      _seriesError = null;
    });
    try {
      final response = await widget.api.get(
        '/api/v2/series',
        query: const <String, String>{'limit': '60'},
      );
      final items = <CinemaSeriesInfo>[];
      final raw = response['series'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            items.add(CinemaSeriesInfo.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _series
          ..clear()
          ..addAll(items);
        _seriesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _seriesLoading = false;
        _seriesError = mediaErrorLabel(error);
      });
    }
  }

  Future<void> _openSeries(CinemaSeriesInfo series) async {
    HapticFeedback.selectionClick();
    List<CinemaFilm> films = const [];
    String? error;
    try {
      final response = await widget.api.get('/api/v2/series/${series.id}');
      final raw = response['films'];
      final parsed = <CinemaFilm>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            try {
              parsed.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
            } on FormatException {
              // Skip malformed rows while keeping usable episodes.
            }
          }
        }
      }
      films = parsed;
    } catch (caught) {
      error = mediaErrorLabel(caught);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      useSafeArea: true,
      builder: (context) {
        final seasons = films.map((film) => film.season).toSet().toList()..sort();
        return AlertDialog(
          title: Text(series.name),
          content: SizedBox(
            width: 420,
            child: films.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(error ?? '暂无可显示的分集。'),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (series.overview.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text(
                              series.overview,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        for (final season in seasons) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              '第 $season 季',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          for (final episode in films
                              .where((film) => film.season == season))
                            ListTile(
                              dense: true,
                              leading: Text(
                                'E${episode.episode}',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              title: Text(
                                episode.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: episode.canResume
                                  ? Text('已看至 ${formatMediaSeconds(episode.position)}')
                                  : null,
                              trailing: episode.completed
                                  ? Icon(
                                      Icons.check_circle,
                                      size: 18,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    )
                                  : Text(formatMediaSeconds(
                                      episode.durationSeconds > 0
                                          ? episode.durationSeconds
                                          : episode.duration,
                                    )),
                              onTap: () {
                                Navigator.of(context).pop();
                                unawaited(_openFilm(episode));
                              },
                            ),
                        ],
                      ],
                    ),
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _refreshScrape() async {
    try {
      final status = CinemaScrapeStatus.fromJson(
        await widget.api.get('/api/v2/cinema/scrape/status'),
      );
      if (!mounted) return;
      setState(() => _scrapeStatus = status);
    } catch (_) {
      // Status polling is best-effort.
    }
  }

  Future<void> _startScrape() async {
    if (_scrapeBusy || (_scrapeStatus?.running ?? false)) return;
    setState(() {
      _scrapeBusy = true;
      _scrapeMessage = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/cinema/scrape/start',
        body: <String, Object>{'retryMisses': _scrapeRetryMisses},
      );
      if (!mounted) return;
      setState(() {
        _scrapeMessage = '自动刮削已启动；可在任务中心随时取消。';
      });
      await _refreshScrape();
    } catch (error) {
      if (!mounted) return;
      String message;
      if (error is LightIsleApiException &&
          error.code == 'tmdb_token_not_configured') {
        message = '需要先在 Mac App「偏好与安全」中配置 TMDB Token。';
      } else if (error is LightIsleApiException &&
          error.code == 'scan_running') {
        message = '媒体库扫描正在进行，请稍后再试。';
      } else {
        message = mediaErrorLabel(error);
      }
      setState(() => _scrapeMessage = message);
    } finally {
      if (mounted) setState(() => _scrapeBusy = false);
    }
  }

  Widget _viewChip(String label, IconData icon, bool selected, VoidCallback onTap) {
    final theme = Theme.of(context);
    return ChoiceChip(
      avatar: Icon(
        icon,
        size: 16,
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }

  List<Widget> _seriesView() {
    final theme = Theme.of(context);
    return <Widget>[
      if (_seriesLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 30),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_seriesError != null)
        MediaStatusBanner(
          message: '剧集库读取失败：$_seriesError',
          isError: true,
          icon: Icons.error_outline,
          trailing: TextButton(
            onPressed: _loadSeries,
            child: const Text('重试'),
          ),
        )
      else if (_series.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
          child: Center(
            child: Text(
              '还没有可聚合的剧集。将剧集文件（如 Show.S01E01.mkv）加入共享目录并扫描后，这里会按剧名聚合。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
          child: GridView.count(
            crossAxisCount: MediaQuery.sizeOf(context).width > 720 ? 3 : 1,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 3.4,
            children: <Widget>[
              for (final series in _series)
                Card(
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => unawaited(_openSeries(series)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  series.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  series.hasContinue && series.inProgress
                                      ? '继续：${series.nextTitle} · 已看 ${series.watchedCount}/${series.episodeCount} 集'
                                      : '已看 ${series.watchedCount}/${series.episodeCount} 集',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            series.hasContinue && series.inProgress
                                ? Icons.play_circle_outline
                                : Icons.live_tv_outlined,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      if (widget.isAdmin) ...<Widget>[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                'TMDB 自动刮削',
                style: theme.textTheme.titleSmall,
              ),
              if (_scrapeStatus == null)
                TextButton(onPressed: _refreshScrape, child: const Text('查看状态'))
              else if (!_scrapeStatus!.tmdbConfigured)
                Text(
                  '需要在 Mac App「偏好与安全」中配置 TMDB Token 后使用',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else if (_scrapeStatus!.running)
                Text(
                  '刮削进行中：已处理 ${_scrapeStatus!.processed} 项 · 匹配 ${_scrapeStatus!.matched} 项',
                  style: theme.textTheme.bodySmall,
                )
              else ...<Widget>[
                OutlinedButton.icon(
                  onPressed: _scrapeBusy ? null : _startScrape,
                  icon: _scrapeBusy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('开始自动刮削'),
                ),
                FilterChip(
                  label: const Text('重试未匹配项'),
                  selected: _scrapeRetryMisses,
                  onSelected: (value) =>
                      setState(() => _scrapeRetryMisses = value),
                ),
              ],
            ],
          ),
        ),
        if (_scrapeMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Text(
              _scrapeMessage!,
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    ];
  }

  Widget _modeChip(String label, String value, IconData icon) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selected = _mode == value;
    final primary = theme.colorScheme.primary;

    return ChoiceChip(
      avatar: Icon(
        icon,
        size: 16,
        color: selected ? primary : theme.colorScheme.onSurfaceVariant,
      ),
      label: Text(label),
      selected: selected,
      onSelected: (_) => _changeMode(value),
      selectedColor: primary.withValues(alpha: isDark ? 0.22 : 0.12),
      backgroundColor: theme.colorScheme.surfaceContainerHigh.withValues(
        alpha: isDark ? 0.5 : 0.6,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(
        color: selected
            ? primary.withValues(alpha: isDark ? 0.50 : 0.38)
            : (isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
        width: selected ? 1.0 : 0.8,
      ),
      labelStyle: TextStyle(
        color: selected ? primary : theme.colorScheme.onSurface,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        letterSpacing: -0.2,
      ),
    );
  }

  Widget _filmGrid() {
    if (_films.isEmpty && _loading) {
      return const Padding(
        padding: EdgeInsets.all(56),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_films.isEmpty && _loadError != null) {
      return MediaEmptyState(
        icon: Icons.local_movies_outlined,
        title: '暂时无法读取影视库',
        message: _loadError!,
        action: OutlinedButton.icon(
          onPressed: _loading ? null : () => _loadFilms(reset: true),
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    if (_films.isEmpty) {
      return MediaEmptyState(
        icon: Icons.local_movies_outlined,
        title: _query.isNotEmpty
            ? '没有找到匹配影片'
            : _mode == 'continue'
            ? '没有待续播的影片'
            : '影视库还没有影片',
        message: _query.isNotEmpty
            ? '调整关键词后再搜索。'
            : widget.isAdmin
            ? '将影片放入共享目录后，扫描影视库以建立索引。'
            : '请联系管理员检查共享目录并扫描影视库。',
        action: widget.isAdmin && _query.isEmpty
            ? OutlinedButton.icon(
                onPressed: _scanning ? null : _startScan,
                icon: const Icon(Icons.refresh),
                label: const Text('扫描影视库'),
              )
            : null,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
            .clamp(1.0, 2.5)
            .toDouble();
        final columns = (constraints.maxWidth / 176)
            .floor()
            .clamp(2, 8)
            .toInt();
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _films.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
            childAspectRatio: .58 / textScale,
          ),
          itemBuilder: (context, index) {
            final film = _films[index];
            return _CinemaTile(
              api: widget.api,
              film: film,
              isAdmin: widget.isAdmin,
              onOpen: () => _openFilm(film),
              onRename: () => _renameFilm(film),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final continueCount = _films.where((film) => film.canResume).length;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: IslePageHeader(
              title: '私人影院',
              subtitle: '按当前设备的播放器能力播放授权目录中的原始视频。',
              icon: Icons.local_movies_rounded,
              trailing: widget.isAdmin
                  ? OutlinedButton.icon(
                      onPressed: _scanning ? null : _startScan,
                      icon: _scanning
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(_scanning ? '扫描中' : '扫描影视库'),
                    )
                  : null,
            ),
          ),
          if (_scanning)
            MediaStatusBanner(
              message: widget.isAdmin
                  ? '正在扫描影视文件 · 已检查 ${_scanStatus.visited} 项 · 找到 ${_scanStatus.found} 部影片。'
                  : '正在后台扫描影视文件。',
              icon: Icons.sync,
            ),
          if (_scanError != null)
            MediaStatusBanner(
              message: '上次扫描未完成：$_scanError',
              icon: Icons.warning_amber_outlined,
              isError: true,
            ),
          if (_actionMessage != null)
            MediaStatusBanner(
              message: _actionMessage!,
              icon: _actionIsError
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              isError: _actionIsError,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
            child: LayoutBuilder(
              builder: (context, constraints) => Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _viewChip('影片', Icons.local_movies_rounded, !_showSeries && !_showHistory,
                      () => setState(() {
                        _showSeries = false;
                        _showHistory = false;
                      })),
                  _viewChip('剧集库', Icons.video_library_rounded, _showSeries,
                      () {
                    setState(() {
                      _showSeries = true;
                      _showHistory = false;
                    });
                    unawaited(_loadSeries());
                    if (widget.isAdmin) unawaited(_refreshScrape());
                  }),
                  _viewChip('历史播放', Icons.history_rounded, _showHistory, () {
                    setState(() {
                      _showHistory = true;
                      _showSeries = false;
                    });
                    unawaited(_loadHistory());
                  }),
                  if (!_showSeries && !_showHistory) ...<Widget>[
                    _modeChip('全部', 'all', Icons.local_movies_outlined),
                    _modeChip('电影', 'movie', Icons.movie_outlined),
                    _modeChip('剧集', 'series', Icons.live_tv_outlined),
                    _modeChip('继续观看', 'continue', Icons.play_circle_outline),
                  ],
                  if (!_showSeries && !_showHistory)
                    SizedBox(
                      width: constraints.maxWidth < 560
                          ? constraints.maxWidth
                          : 300,
                      child: TextField(
                      controller: _searchController,
                      onChanged: _searchChanged,
                      maxLength: 120,
                      decoration: InputDecoration(
                        counterText: '',
                        prefixIcon: const Icon(Icons.search),
                        hintText: '搜索影片或剧集',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () {
                                  _searchController.clear();
                                  _searchChanged('');
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_mode == 'continue' && continueCount > 0)
            MediaStatusBanner(
              message: '$continueCount 部影片可继续观看。',
              icon: Icons.play_circle_outline,
            ),
          if (_loadError != null && _films.isNotEmpty)
            MediaStatusBanner(
              message: _loadError!,
              isError: true,
              icon: Icons.error_outline,
              trailing: TextButton(
                onPressed: _loadingMore ? null : () => _loadFilms(reset: false),
                child: const Text('重试'),
              ),
            ),
          if (_showSeries)
            ..._seriesView()
          else if (_showHistory) ..._historyView()
          else ...[
            _filmGrid(),
          ],
          if (!_showSeries && !_showHistory && _films.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 26),
              child: Center(
                child: _nextCursor > 0
                    ? OutlinedButton.icon(
                        onPressed: _loadingMore
                            ? null
                            : () => _loadFilms(reset: false),
                        icon: _loadingMore
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.expand_more),
                        label: Text(_loadingMore ? '正在加载' : '加载更多影片'),
                      )
                    : Text(
                        '已显示全部 ${_films.length} 部影片',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
            child: Text(
              '无法播放的格式会标记为可转码播放（服务器实时转封装/转码为临时缓存，原片永不修改）或仅下载；未安装 FFmpeg 时仅提供直接播放与下载。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CinemaTile extends StatefulWidget {
  const _CinemaTile({
    required this.api,
    required this.film,
    required this.isAdmin,
    required this.onOpen,
    required this.onRename,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final VoidCallback onOpen;
  final Future<CinemaFilm> Function() onRename;

  @override
  State<_CinemaTile> createState() => _CinemaTileState();
}

class _CinemaTileState extends State<_CinemaTile> {
  String get _playbackLabel {
    if (widget.film.browserPlayback == 'verified-direct') return '已验证播放';
    if (widget.film.browserPlayback == 'unverified-direct') return '尝试播放';
    switch (widget.film.probeStatus) {
      case 'pending':
        return '正在识别格式';
      case 'unavailable':
        return '格式检查器不可用';
      case 'failed':
        return '格式识别失败';
      case 'unsupported':
        return '当前设备不支持';
      default:
        return '无法直接播放';
    }
  }

  String get _format {
    return <String>[
      widget.film.container.toUpperCase(),
      widget.film.videoCodec.toUpperCase(),
      widget.film.audioCodec.toUpperCase(),
    ].where((item) => item.isNotEmpty).join(' · ');
  }

  String get _positionLabel {
    final value = Duration(seconds: widget.film.position.round());
    if (value.inHours > 0) {
      return '${value.inHours}时${value.inMinutes.remainder(60)}分';
    }
    return '${value.inMinutes} 分钟';
  }

  @override
  Widget build(BuildContext context) {
    final film = widget.film;
    final percent = film.duration > 0
        ? (film.position / film.duration).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final surface = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '播放：${film.title}',
      child: IsleSurface(
        onTap: widget.onOpen,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (film.probeStatus == 'ready')
                    Hero(
                      tag: 'cinema_poster_${film.id}',
                      child: AuthenticatedMediaImage(
                        api: widget.api,
                        path: '/api/v2/cinema/${film.id}/poster',
                        maxBytes: 4 * 1024 * 1024,
                        fit: BoxFit.cover,
                        loadingBuilder: _posterPlaceholder,
                        errorBuilder: (context, error, retry) => Stack(
                          fit: StackFit.expand,
                          children: [
                            _posterPlaceholder(context),
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: IconButton(
                                tooltip: '重试加载封面',
                                visualDensity: VisualDensity.compact,
                                onPressed: retry,
                                icon: const Icon(Icons.refresh, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    _posterPlaceholder(context),
                  Align(
                    alignment: Alignment.center,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: .45),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .65),
                          width: 1.0,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          film.canAttemptPlayback
                              ? Icons.play_arrow_rounded
                              : Icons.info_outline_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 9,
                    right: 9,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .60),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                          width: 0.75,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          film.isSeries
                              ? 'S${film.season} · E${film.episode}'
                              : '${film.year == 0 ? '电影' : film.year}',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ),
                  ),
                  if (percent > 0 && !film.completed)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: percent,
                        minHeight: 4,
                        backgroundColor: Colors.black45,
                        color: const Color(0xff3b82f6),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            film.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${film.isSeries ? '剧集' : '电影'} · ${formatMediaSeconds(film.durationSeconds > 0 ? film.durationSeconds : film.duration)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: surface.onSurfaceVariant),
                          ),
                          if (_format.isNotEmpty)
                            Text(
                              _format,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: surface.onSurfaceVariant),
                            ),
                          if (film.completed)
                            Text(
                              '已看完',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: const Color(0xFF15803D),
                                    fontWeight: FontWeight.w600,
                                  ),
                            )
                          else if (film.canResume)
                            Text(
                              '已看至 $_positionLabel',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          if (!film.canAttemptPlayback)
                            Text(
                              _playbackLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: surface.error),
                            ),
                        ],
                      ),
                    ),
                    if (widget.isAdmin)
                      IconButton(
                        tooltip: '修改展示名称',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onRename,
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _posterPlaceholder(BuildContext context) {
    final film = widget.film;
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primaryContainer,
            colors.surfaceContainerHigh,
            colors.secondaryContainer,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          film.isSeries ? Icons.live_tv_outlined : Icons.movie_outlined,
          size: 42,
          color: colors.primary,
        ),
      ),
    );
  }
}

class _FilmTitleDialog extends StatelessWidget {
  const _FilmTitleDialog({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改影片展示名称'),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: 100,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => Navigator.pop(context, controller.text),
      decoration: const InputDecoration(labelText: '影片名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('保存'),
      ),
    ],
  );
}

class CinemaDetailDialog extends StatefulWidget {
  const CinemaDetailDialog({
    required this.api,
    required this.film,
    required this.isAdmin,
    required this.onRename,
    required this.onProgressUpdated,
    super.key,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final Future<CinemaFilm> Function(CinemaFilm film) onRename;
  final ValueChanged<CinemaFilm> onProgressUpdated;

  @override
  State<CinemaDetailDialog> createState() => _CinemaDetailDialogState();
}

class _CinemaDetailDialogState extends State<CinemaDetailDialog>
    with WidgetsBindingObserver {
  final TextEditingController _tmdbTokenController = TextEditingController();
  late final TextEditingController _tmdbQueryController;
  late CinemaFilm _film;
  VideoPlayerController? _controller;
  bool _loading = true;
  bool _busy = false;
  bool _closing = false;
  bool _completionSaved = false;
  bool _autoPlayNext = false;
  bool _nextEpisodeBusy = false;
  String? _playbackMessage;
  String? _progressSaveMessage;
  String? _subtitleMessage;
  String _captionLanguage = 'off';
  List<SubtitleCue> _cues = const [];
  int _subtitleGeneration = 0;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _saveQueue = Future<void>.value();
  bool _hasQueuedFinalSave = false;
  bool _metadataBusy = false;
  bool _tmdbSearching = false;
  bool _tmdbMatching = false;
  int _metadataGeneration = 0;
  List<TMDBCandidate> _tmdbCandidates = const [];
  String? _metadataMessage;
  String? _tmdbMessage;
  bool _metadataIsError = false;
  // Transcode (HLS) playback state. The muxer writes segments starting at
  // [CinemaHlsSession.start], so the player timeline begins at zero and every
  // persisted position is offset by that value before being saved.
  CinemaHlsSession? _hlsSession;
  CinemaTrackInfo? _tracks;
  bool _transcodeStarting = false;
  double _playbackSpeed = 1.0;
  double _subtitleFontSize = 17.0;
  double? _seekDraft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _film = widget.film;
    _tmdbQueryController = TextEditingController(text: _film.title);
    _restorePlaybackSpeed();
    _restoreAutoplayNext();
    _loadDetailAndPlayer();
  }

  Future<void> _restoreAutoplayNext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() =>
          _autoPlayNext = prefs.getBool('lightisle_cinema_autoplay_next') ?? false);
      }
    } catch (_) { /* Opt-in defaults to off when preferences cannot load. */ }
  }

  Future<void> _setAutoplayNext(bool value) async {
    setState(() => _autoPlayNext = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('lightisle_cinema_autoplay_next', value);
    } catch (_) { /* Session selection still works. */ }
  }

  Future<CinemaFilm?> _findNextEpisode() async {
    final current = _film;
    if (!current.isSeries || current.series.isEmpty) return null;
    final response = await widget.api.get('/api/v2/series',
      query: {'limit': '60'});
    final matches = <int>[];
    for (final item in (response['series'] as List? ?? const [])) {
      if (item is Map && item['name'] == current.series && item['id'] is num) {
        matches.add((item['id'] as num).toInt());
      }
    }
    // Ambiguous shows should not accidentally play an unrelated episode.
    if (matches.length != 1 || matches.single <= 0) return null;
    final detail = await widget.api.get('/api/v2/series/${matches.single}');
    final episodes = <CinemaFilm>[];
    for (final item in (detail['films'] as List? ?? const [])) {
      if (item is Map) {
        try { episodes.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item))); }
        on FormatException { /* Ignore malformed records. */ }
      }
    }
    episodes.sort((a, b) {
      final season = a.season.compareTo(b.season);
      if (season != 0) return season;
      final episode = a.episode.compareTo(b.episode);
      return episode != 0 ? episode : a.id.compareTo(b.id);
    });
    final index = episodes.indexWhere((item) => item.id == current.id);
    return index < 0 || index + 1 >= episodes.length ? null : episodes[index + 1];
  }

  Future<void> _goToNextEpisode({bool alreadySaved = false}) async {
    if (_closing || _nextEpisodeBusy || !mounted || !_film.isSeries) return;
    final currentID = _film.id;
    setState(() => _nextEpisodeBusy = true);
    try {
      final next = await _findNextEpisode();
      if (!mounted || _closing || _film.id != currentID) return;
      if (next == null) {
        setState(() => _playbackMessage =
          '本季已播完，或者还没有扫描到下一集。可从剧集库选择。');
        return;
      }
      await _controller?.pause();
      if (!alreadySaved && !await _queueProgressSave(force: true)) return;
      if (!mounted || _closing || _film.id != currentID) return;
      _hasQueuedFinalSave = true;
      Navigator.pop(context, next);
    } catch (error) {
      if (mounted) {
        setState(() => _playbackMessage =
          '无法读取下一集：${mediaErrorLabel(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _nextEpisodeBusy = false);
      }
    }
  }

  Future<void> _restorePlaybackSpeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final speed = prefs.getDouble('lightisle_cinema_playback_speed');
      if (!mounted || speed == null ||
          !const [0.75, 1.0, 1.25, 1.5, 2.0].contains(speed)) {
        return;
      }
      setState(() => _playbackSpeed = speed);
      await _controller?.setPlaybackSpeed(speed);
    } catch (_) {
      // Disabled preferences or a missing test platform never blocks playback.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_queueProgressSave(force: true));
      final controller = _controller;
      if (controller?.value.isPlaying == true) unawaited(controller!.pause());
    }
  }

  Future<void> _loadDetailAndPlayer({double? seekTo}) async {
    try {
      final response = await widget.api.get('/api/v2/cinema/${_film.id}');
      final detail = CinemaFilm.fromJson(response);
      if (!mounted) return;
      setState(() => _film = detail);
    } catch (_) {
      // Keep list metadata and progress if the detail refresh is unavailable.
    }
    if (!mounted) return;
    if (!_film.canAttemptPlayback) {
      setState(() {
        _loading = false;
        _playbackMessage = _unsupportedMessage;
      });
      // The browser-grade player cannot decode this container/codec. The
      // server-side HLS session (remux or VideoToolbox transcode) is the
      // remaining playback path; it degrades honestly when FFmpeg is absent.
      // Starting the session at the resume point keeps the muxer from
      // producing minutes of segments nobody is watching yet.
      await _startTranscode(start: _film.canResume ? _film.position : 0);
      return;
    }
    try {
      final source = await widget.api.mediaUri(
        '/api/v2/cinema/${_film.id}/stream',
      );
      if (!mounted) return;
      final controller = VideoPlayerController.networkUrl(
        source,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      final savedPosition = seekTo != null && seekTo > 1
          ? Duration(milliseconds: (seekTo * 1000).round())
          : Duration(milliseconds: (_film.position * 1000).round());
      if (savedPosition > Duration.zero &&
          savedPosition <
              controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(savedPosition);
      }
      if (_playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playbackSpeed);
      }
      if (!mounted || _controller != controller) return;
      controller.addListener(_onVideoChanged);
      setState(() {
        _loading = false;
        _playbackMessage = _film.browserPlayback == 'unverified-direct'
            ? '此格式尚未验证；如果当前设备无法解码，播放会失败。原片未做转换。'
            : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playbackMessage = '无法在当前设备播放此视频：${mediaErrorLabel(error)}';
      });
    }
  }

  String get _unsupportedMessage {
    switch (_film.probeStatus) {
      case 'pending':
        return '格式仍在识别中，当前无法直接播放。请稍后重新打开。';
      case 'unavailable':
        return '格式检查器不可用，暂时无法确认此视频是否能播放。';
      case 'failed':
        return '视频格式识别失败，当前无法直接播放。';
      case 'unsupported':
        return '当前设备的播放器不支持此视频格式。原始文件未做转换。';
      default:
        return '此视频无法通过当前播放器播放。原始文件未做转换。';
    }
  }

  String _transcodeErrorLabel(Object error) {
    if (error is LightIsleApiException) {
      switch (error.code) {
        case 'transcode_unavailable':
          return '未安装 FFmpeg，仅支持下载后播放；管理员可在服务器执行 brew install ffmpeg 启用转码。';
        case 'transcode_busy':
          return '转码通道被占用，请稍后重试。';
        case 'transcode_failed':
          return '转码失败：该影片可能包含不兼容的编码，请下载后用本地播放器打开。';
        case 'transcode_insufficient_space':
          return '服务器空间不足，无法创建转码缓存，请清理后重试。';
        case 'transcode_start_timeout':
          return '转码启动超时，请稍后重试。';
      }
    }
    return mediaErrorLabel(error);
  }

  Future<void> _startTranscode({double? start, int audio = 0, String quality = 'source'}) async {
    if (!mounted || _transcodeStarting) return;
    final filmId = _film.id;
    setState(() {
      _transcodeStarting = true;
      _playbackMessage = '正在启动转码…';
    });
    try {
      final session = CinemaHlsSession.fromJson(
        await widget.api.get(
          '/api/v2/cinema/$filmId/hls/session',
          query: <String, String>{
            'start': ((start ?? 0).clamp(0, double.infinity)).toStringAsFixed(3),
            'audio': '$audio',
            if (quality != 'source') 'quality': quality,
          },
        ),
      );
      // The muxer writes the playlist after its first segment; poll until it
      // exists so the native player never initializes against a 404.
      Uri? playlist;
      for (var attempt = 0; attempt < 60; attempt++) {
        if (!mounted || _film.id != filmId) return;
        try {
          await widget.api.bytes(
            '/api/v2/cinema/$filmId/hls/${session.sessionId}/index.m3u8',
            maxBytes: 1 << 20,
          );
          playlist = await widget.api
              .mediaHlsUri('/api/v2/cinema/$filmId/hls/${session.sessionId}/');
          break;
        } on LightIsleApiException catch (error) {
          if (error.statusCode == 502) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      // Resolving the authenticated HLS relay can outlive the dialog. Never
      // create a native player after dispose has released the current one.
      if (!mounted || _film.id != filmId) return;
      if (playlist == null) {
        throw const LightIsleApiException(
          code: 'transcode_start_timeout',
          message: '转码启动超时。',
        );
      }
      final controller = VideoPlayerController.networkUrl(
        playlist,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      final previous = _controller;
      _controller = controller;
      if (previous != null && previous != controller) {
        previous.removeListener(_onVideoChanged);
        await previous.dispose();
      }
      if (!mounted || _controller != controller) return;
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      final target = (start ?? (_film.canResume ? _film.position : 0)) -
          session.start;
      final savedPosition = Duration(
        milliseconds: (target > 1 ? target * 1000 : 0).round(),
      );
      if (savedPosition > Duration.zero &&
          savedPosition <
              controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(savedPosition);
      }
      if (_playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playbackSpeed);
      }
      if (!mounted || _controller != controller) return;
      controller.addListener(_onVideoChanged);
      try {
        _tracks = CinemaTrackInfo.fromJson(
          await widget.api.get('/api/v2/cinema/$filmId/tracks'),
        );
      } catch (_) {
        // Track listing is optional; playback continues without selectors.
      }
      if (!mounted) return;
      setState(() {
        _hlsSession = session;
        _transcodeStarting = false;
        _playbackMessage = session.profile == 'remux'
            ? '转封装播放（无画质损失），原片未修改。'
            : '转码播放中（服务器实时转码），原片未修改。';
      });
    } catch (error) {
      if (!mounted || _film.id != filmId) return;
      setState(() {
        _transcodeStarting = false;
        _playbackMessage = _transcodeErrorLabel(error);
      });
    }
  }

  Future<void> _switchAudio(int audioIndex) async {
    final controller = _controller;
    final session = _hlsSession;
    if (controller == null || session == null || session.audioTrack == audioIndex) {
      return;
    }
    final realPosition =
        controller.value.position.inMilliseconds / 1000.0 + session.start;
    await controller.pause();
    await _startTranscode(
      start: realPosition,
      audio: audioIndex,
      quality: session.quality,
    );
  }

  /// Switches the quality tier. Lower tiers force a transcode session even
  /// for directly playable sources; 原画 tears a session down when the film
  /// can play directly, keeping the resume point.
  static const _qualityTiers = <(String, String, int)>[
    ('1080', '1080P', 1080),
    ('720', '720P', 720),
    ('480', '480P', 480),
  ];

  /// 原画 plus every tier below the source height (no upscaling options).
  List<(String, String)> _qualityOptions() {
    final options = <(String, String)>[('source', '原画')];
    final sourceHeight = _film.height;
    for (final (value, label, height) in _qualityTiers) {
      if (sourceHeight > 0 && sourceHeight <= height) break;
      options.add((value, label));
    }
    return options;
  }

  Future<void> _switchQuality(String quality) async {
    if (_transcodeStarting) return;
    final controller = _controller;
    final session = _hlsSession;
    if (session == null) {
      if (quality == 'source') return;
      final realPosition = controller != null
          ? controller.value.position.inMilliseconds / 1000.0
          : (_film.canResume ? _film.position : 0.0);
      await controller?.pause();
      await _startTranscode(start: realPosition, quality: quality);
      return;
    }
    if (session.quality == quality) return;
    final realPosition =
        controller!.value.position.inMilliseconds / 1000.0 + session.start;
    await controller.pause();
    if (quality == 'source' && _film.canAttemptPlayback) {
      // Back to the plain stream: dispose the session controller first.
      controller.removeListener(_onVideoChanged);
      await controller.dispose();
      _hlsSession = null;
      _controller = null;
      if (!mounted) return;
      setState(() {
        _loading = true;
        _playbackMessage = null;
      });
      await _loadDetailAndPlayer(seekTo: realPosition);
      return;
    }
    await _startTranscode(
      start: realPosition,
      audio: session.audioTrack,
      quality: quality,
    );
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    if (!const [0.75, 1.0, 1.25, 1.5, 2.0].contains(speed)) return;
    _playbackSpeed = speed;
    await _controller?.setPlaybackSpeed(speed);
    if (mounted) setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lightisle_cinema_playback_speed', speed);
    } catch (_) { /* Persist when possible, playback still works without it. */ }
  }

  double get _originalPlaybackSeconds {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return 0;
    return controller.value.position.inMilliseconds / 1000.0 +
        (_hlsSession?.start ?? 0);
  }

  double get _originalPlaybackDuration {
    final controller = _controller;
    final sessionStart = _hlsSession?.start ?? 0;
    final observed = controller == null || !controller.value.isInitialized
        ? 0.0
        : controller.value.duration.inMilliseconds / 1000.0 + sessionStart;
    return _film.durationSeconds > 0
        ? (_film.durationSeconds > observed ? _film.durationSeconds : observed)
        : observed;
  }

  Future<void> _seekAbsolute(double absoluteSeconds) async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _transcodeStarting) {
      return;
    }
    final max = _originalPlaybackDuration;
    final target = absoluteSeconds.clamp(0.0, max > 0 ? max - .25 : 0.0).toDouble();
    final session = _hlsSession;
    if (session != null) {
      // The playlist's first frame is at session.start; rebuild the session
      // for absolute seeks outside its guaranteed live media window.
      unawaited(_queueProgressSave(force: true));
      await _startTranscode(
        start: target,
        audio: session.audioTrack,
        quality: session.quality,
      );
    } else {
      await controller.seekTo(Duration(milliseconds: (target * 1000).round()));
      unawaited(_queueProgressSave(force: true));
    }
    if (mounted) setState(() => _seekDraft = null);
  }

  Future<void> _seekRelative(double deltaSeconds) async {
    await _seekAbsolute(_originalPlaybackSeconds + deltaSeconds);
  }

  Future<void> _showFullscreenPlayer() async {
    if (_controller?.value.isInitialized != true) return;
    double? draggedPosition;
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierColor: Colors.black,
      builder: (context) => StatefulBuilder(
        builder: (dialogContext, updateOverlay) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Column(children: [
              Row(children: [
                IconButton(
                  tooltip: '退出全屏',
                  color: Colors.white,
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.fullscreen_exit),
                ),
                Expanded(child: Text(_film.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white))),
              ]),
              Expanded(child: Center(
                child: _controller == null || !_controller!.value.isInitialized
                    ? const CircularProgressIndicator()
                    : AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio > 0
                            ? _controller!.value.aspectRatio : 16 / 9,
                        child: GestureDetector(
                          onDoubleTapDown: (details) async {
                            final width = MediaQuery.sizeOf(dialogContext).width;
                            final direction = details.localPosition.dx < width * .4
                                ? -10.0
                                : details.localPosition.dx > width * .6 ? 10.0 : 0.0;
                            if (direction != 0) {
                              await _seekRelative(direction);
                              if (dialogContext.mounted) updateOverlay(() {});
                            } else if (_controller?.value.isPlaying == true) {
                              await _controller?.pause();
                            } else {
                              await _controller?.play();
                            }
                          },
                          child: VideoPlayer(_controller!),
                        ),
                      ),
              )),
              AnimatedBuilder(
                animation: _controller!,
                builder: (context, _) {
                  final total = _originalPlaybackDuration;
                  final current = _originalPlaybackSeconds;
                  if (total <= 0) return const SizedBox(height: 20);
                  return Column(children: [
                    Slider(
                      value: (draggedPosition ?? current).clamp(0.0, total),
                      max: total,
                      onChanged: _transcodeStarting
                          ? null
                          : (value) => updateOverlay(() => draggedPosition = value),
                      onChangeEnd: (value) async {
                        await _seekAbsolute(value);
                        if (dialogContext.mounted) {
                          updateOverlay(() => draggedPosition = null);
                        }
                      },
                    ),
                    Text(
                      '${_timeLabel(Duration(milliseconds: (current * 1000).round()))} / ${_timeLabel(Duration(milliseconds: (total * 1000).round()))}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ]);
                },
              ),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  tooltip: '快退10秒', color: Colors.white,
                  onPressed: () async {
                    await _seekRelative(-10);
                    if (dialogContext.mounted) updateOverlay(() {});
                  },
                  icon: const Icon(Icons.replay_10),
                ),
                IconButton(
                  tooltip: _controller?.value.isPlaying == true ? '暂停' : '播放',
                  color: Colors.white,
                  onPressed: () {
                    final controller = _controller;
                    if (controller == null) return;
                    if (controller.value.isPlaying) {
                      unawaited(controller.pause());
                    } else {
                      unawaited(controller.play());
                    }
                    updateOverlay(() {});
                  },
                  icon: Icon(_controller?.value.isPlaying == true
                      ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: '快进10秒', color: Colors.white,
                  onPressed: () async {
                    await _seekRelative(10);
                    if (dialogContext.mounted) updateOverlay(() {});
                  },
                  icon: const Icon(Icons.forward_10),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _markWatched({required bool completed}) async {
    final filmId = _film.id;
    try {
      final updated = CinemaFilm.fromJson(
        await widget.api.send('POST', '/api/v2/cinema/$filmId/watched',
            body: <String, Object>{'completed': completed}),
      );
      if (!mounted || _film.id != filmId) return;
      setState(() => _film = updated);
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (mounted) {
        setState(() => _metadataMessage = mediaErrorLabel(error));
      }
    }
  }

  Future<void> _restartFromBeginning() async {
    final controller = _controller;
    final session = _hlsSession;
    if (session != null) {
      await _startTranscode(start: 0, audio: session.audioTrack, quality: session.quality);
      return;
    }
    if (controller != null) {
      await controller.seekTo(Duration.zero);
      await controller.play();
    }
  }

  void _onVideoChanged() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.hasError) {
      final message =
          '视频播放中断：${controller.value.errorDescription ?? '当前设备无法解码此格式。'}';
      if (mounted && _playbackMessage != message) {
        setState(() => _playbackMessage = message);
      }
      return;
    }
    if (mounted) setState(() {});
    final now = DateTime.now();
    final ended = controller.value.isCompleted;
    if (ended && !_completionSaved) {
      _completionSaved = true;
      final value = controller.value;
      final sessionStart = _hlsSession?.start ?? 0;
      final clock = cinemaPlaybackClock(
        value.position.inMilliseconds / 1000.0,
        value.duration.inMilliseconds / 1000.0,
        sessionStart: sessionStart,
        originalDuration: _film.durationSeconds,
      );
      // A still-growing HLS playlist can reach its temporary end well before
      // the real film. Do not mark watched or play the next episode then.
      unawaited(_onPlaybackCompleted(nearRealEnd: clock.nearEnd));
    } else if (now.difference(_lastSaved) >= const Duration(seconds: 10)) {
      unawaited(_queueProgressSave(force: true));
    }
  }

  Future<void> _onPlaybackCompleted({required bool nearRealEnd}) async {
    final completedID = _film.id;
    final saved = await _queueProgressSave(force: true,
      completed: nearRealEnd);
    if (!nearRealEnd && mounted && !_closing) {
      setState(() => _playbackMessage =
        '当前转码片段已播放至末尾，但整部影片尚未结束。可等待转码继续，或调整播放进度。');
    }
    if (nearRealEnd && saved && mounted && !_closing && _autoPlayNext &&
        _film.id == completedID) {
      await _goToNextEpisode(alreadySaved: true);
    }
  }

  Future<bool> _queueProgressSave({
    bool force = false,
    bool completed = false,
  }) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Future<bool>.value(true);
    }
    final value = controller.value;
    final offset = _hlsSession?.start ?? 0;
    final localSeconds = value.position.inMilliseconds / 1000.0;
    final playlistSeconds = value.duration.inMilliseconds / 1000.0;
    if (offset + playlistSeconds <= 0 ||
        !localSeconds.isFinite ||
        !playlistSeconds.isFinite) {
      return Future<bool>.value(true);
    }
    final clock = cinemaPlaybackClock(
      localSeconds,
      playlistSeconds,
      sessionStart: offset,
      originalDuration: _film.durationSeconds,
    );
    final now = DateTime.now();
    if (!force && now.difference(_lastSaved) < const Duration(seconds: 10)) {
      return Future<bool>.value(true);
    }
    _lastSaved = now;
    final isCompleted = completed || clock.nearEnd;
    final filmId = _film.id;
    final result = Completer<bool>();
    _saveQueue = _saveQueue.then((_) async {
      try {
        await widget.api.send(
          'PUT',
          '/api/v2/cinema/$filmId/progress',
          body: <String, Object>{
            'position': clock.position,
            'duration': clock.duration,
            'completed': isCompleted,
          },
        );
        if (mounted && _film.id == filmId) {
          final updated = _film.withProgress(
            newPosition: clock.position,
            newDuration: clock.duration,
            isCompleted: isCompleted,
          );
          setState(() {
            _film = updated;
            _progressSaveMessage = null;
          });
          widget.onProgressUpdated(updated);
        }
        result.complete(true);
      } catch (_) {
        if (mounted && _film.id == filmId) {
          setState(() {
            _progressSaveMessage = '播放进度暂时未能保存，请检查连接后重试。';
          });
        }
        result.complete(false);
      }
    });
    return result.future;
  }

  Future<void> _loadSubtitles(String language) async {
    final generation = ++_subtitleGeneration;
    setState(() {
      _captionLanguage = language;
      _subtitleMessage = null;
      _cues = const [];
    });
    if (language == 'off') return;
    try {
      final embedded = language.startsWith('emb:');
      final query = embedded
          ? <String, String>{'track': language.substring(4)}
          : language == 'auto'
          ? null
          : <String, String>{'lang': language};
      final bytes = await widget.api.bytes(
        embedded
            ? '/api/v2/cinema/${_film.id}/embedded-subtitles'
            : '/api/v2/cinema/${_film.id}/subtitles',
        query: query,
        maxBytes: 1 << 20,
      );
      final cues = parseWebVtt(utf8.decode(bytes, allowMalformed: true));
      if (!mounted || generation != _subtitleGeneration) return;
      setState(() {
        _cues = cues;
        _subtitleMessage = cues.isEmpty ? '字幕文件没有可显示的内容。' : null;
      });
    } catch (error) {
      if (!mounted || generation != _subtitleGeneration) return;
      setState(() {
        _subtitleMessage =
            error is LightIsleApiException && error.code == 'film_not_found'
            ? '未找到匹配字幕，或此影片已被移除。'
            : mediaErrorLabel(error);
      });
    }
  }

  Future<void> _close({bool allowUnsaved = false}) async {
    if (_closing) return;
    HapticFeedback.lightImpact();
    if (allowUnsaved && _progressSaveMessage != null) {
      _hasQueuedFinalSave = true;
      Navigator.pop(context);
      return;
    }
    setState(() => _closing = true);
    try {
      await _controller?.pause();
    } catch (_) {
      // Still try to persist the last known position if the native player
      // cannot pause cleanly.
    }
    final saved = await _queueProgressSave(force: true);
    if (!mounted) return;
    if (!saved) {
      setState(() => _closing = false);
      return;
    }
    _hasQueuedFinalSave = true;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _metadataGeneration++;
    _tmdbTokenController.clear();
    _tmdbTokenController.dispose();
    _tmdbQueryController.dispose();
    _subtitleGeneration++;
    if (!_hasQueuedFinalSave) {
      _hasQueuedFinalSave = true;
      unawaited(_queueProgressSave(force: true));
    }
    final controller = _controller;
    controller?.removeListener(_onVideoChanged);
    controller?.dispose();
    super.dispose();
  }

  Future<void> _importLocalNfo() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    setState(() {
      _metadataBusy = true;
      _metadataMessage = null;
      _metadataIsError = false;
    });
    try {
      await widget.api.send('POST', '/api/v2/cinema/$filmId/metadata/nfo');
      final response = await widget.api.get('/api/v2/cinema/$filmId');
      final updated = CinemaFilm.fromJson(response);
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _film = updated;
        _metadataMessage = '已导入本地 NFO 资料，原视频和观看进度未修改。';
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _metadataMessage = mediaErrorLabel(error);
        _metadataIsError = true;
      });
    } finally {
      if (mounted && generation == _metadataGeneration) {
        setState(() => _metadataBusy = false);
      }
    }
  }

  Future<void> _searchTmdb() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final token = _tmdbTokenController.text.trim();
    final query = _tmdbQueryController.text.trim();
    if (token.isEmpty || query.isEmpty) {
      setState(() {
        _tmdbMessage = '请输入自己的 TMDB API Read Access Token 和搜索关键词。';
      });
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    setState(() {
      _tmdbSearching = true;
      _tmdbCandidates = const [];
      _tmdbMessage = null;
    });
    try {
      final response = await widget.api.send(
        'POST',
        '/api/v2/cinema/$filmId/metadata/tmdb/search',
        body: <String, String>{'accessToken': token, 'query': query},
      );
      final raw = response['results'];
      final candidates = <TMDBCandidate>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          try {
            candidates.add(
              TMDBCandidate.fromJson(Map<String, dynamic>.from(item)),
            );
          } on FormatException {
            // Skip incomplete upstream rows while retaining usable matches.
          }
        }
      }
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _tmdbCandidates = candidates;
        if (candidates.isEmpty) {
          _tmdbMessage = '没有找到相关影视资料，可以调整关键词后再搜索。';
        }
      });
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      setState(() => _tmdbMessage = '搜索失败：${mediaErrorLabel(error)}');
    } finally {
      if (mounted && generation == _metadataGeneration) {
        setState(() => _tmdbSearching = false);
      }
    }
  }

  Future<void> _matchTmdb(TMDBCandidate candidate) async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认匹配影视资料？'),
        content: Text(
          '将“${candidate.title}”的 TMDB 简介、评分和海报资料匹配到“${_film.title}”。手动设置的影片名称会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认匹配'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final token = _tmdbTokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _tmdbMessage = '令牌已清除，请重新输入后搜索并匹配。');
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    setState(() {
      _tmdbMatching = true;
      _tmdbMessage = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/cinema/$filmId/metadata/tmdb/match',
        body: <String, Object>{'accessToken': token, 'tmdbId': candidate.id},
      );
      final response = await widget.api.get('/api/v2/cinema/$filmId');
      final updated = CinemaFilm.fromJson(response);
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _film = updated;
        _tmdbCandidates = const [];
        _tmdbTokenController.clear();
        _metadataMessage = '已匹配 TMDB 资料；API 凭据已从页面内存清除。';
        _metadataIsError = false;
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      setState(() => _tmdbMessage = '匹配失败：${mediaErrorLabel(error)}');
    } finally {
      if (mounted && generation == _metadataGeneration) {
        setState(() => _tmdbMatching = false);
      }
    }
  }

  Widget _metadataMatchingPanel(BuildContext context) {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final busy = _metadataBusy || _tmdbSearching || _tmdbMatching;
    final theme = Theme.of(context);
    return IsleSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('影视资料', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '资料来源可在本地 NFO 和 TMDB 之间手动选择。不会自动联网查询。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () => unawaited(
                    _markWatched(completed: !_film.completed),
                  ),
                  icon: Icon(_film.completed
                      ? Icons.visibility_off_outlined
                      : Icons.check_circle_outline),
                  label: Text(_film.completed ? '标记未看' : '标记已看'),
                ),
                if (_film.position > 5 && !_film.completed)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_restartFromBeginning()),
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('从头播放'),
                  ),
                if (_film.isSeries)
                  OutlinedButton.icon(
                    onPressed: _closing || _nextEpisodeBusy
                        ? null : () => unawaited(_goToNextEpisode()),
                    icon: const Icon(Icons.skip_next_rounded),
                    label: Text(_nextEpisodeBusy ? '查找下一集…' : '下一集'),
                  ),
              ],
            ),
          ),
          if (_film.isSeries)
            SwitchListTile.adaptive(
              title: const Text('播完自动下一集'),
              subtitle: const Text('默认关闭；先保存本集进度，再开始下一集。'),
              value: _autoPlayNext,
              onChanged: _setAutoplayNext,
              contentPadding: EdgeInsets.zero,
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: busy ? null : _importLocalNfo,
              icon: _metadataBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.description_outlined),
              label: const Text('导入本地 NFO 资料'),
            ),
          ),
          if (_metadataMessage != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: _metadataMessage!,
              icon: _metadataIsError
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              isError: _metadataIsError,
            ),
          ],
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Text('TMDB 在线匹配（自愿联网）', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            '只有点击“搜索 TMDB”或确认匹配时，令牌和请求才会发送到当前 LightIsle 服务器，由服务器联系 TMDB。令牌仅保存在当前页面内存，不写入 LightIsle 数据库；关闭详情页会清除令牌。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'This product uses the TMDB API but is not endorsed or certified by TMDB.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tmdbTokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'TMDB API Read Access Token',
              hintText: '仅为本次手动匹配提供',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.key_outlined),
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                controller: _tmdbQueryController,
                maxLength: 120,
                enabled: !busy,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_searchTmdb()),
                decoration: const InputDecoration(
                  labelText: '影视名称',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                  counterText: '',
                ),
              );
              final button = FilledButton.icon(
                onPressed: busy ? null : _searchTmdb,
                icon: _tmdbSearching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore_outlined),
                label: Text(_tmdbSearching ? '搜索中…' : '搜索 TMDB'),
              );
              if (constraints.maxWidth < 460) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [field, const SizedBox(height: 8), button],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: button,
                  ),
                ],
              );
            },
          ),
          if (_tmdbMessage != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: _tmdbMessage!,
              icon: Icons.info_outline,
              isError:
                  _tmdbCandidates.isEmpty &&
                  !_tmdbSearching &&
                  _tmdbMessage!.startsWith('搜索失败'),
            ),
          ],
          if (_tmdbCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final candidate in _tmdbCandidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _tmdbCandidateCard(candidate, busy),
              ),
          ],
        ],
      ),
    );
  }

  Widget _tmdbCandidateCard(TMDBCandidate candidate, bool busy) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Text(
            '${candidate.title}${candidate.year.isEmpty ? '' : ' (${candidate.year})'}',
            style: theme.textTheme.titleSmall,
          );
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(height: 4),
              Text(
                '${candidate.kind == 'tv' || candidate.kind == 'series' ? '剧集' : '电影'} · 评分 ${candidate.rating.toStringAsFixed(1)} / 10',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (candidate.overview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  candidate.overview,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          );
          final matchButton = OutlinedButton.icon(
            onPressed: busy ? null : () => _matchTmdb(candidate),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('选择匹配'),
          );
          if (constraints.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [description, const SizedBox(height: 8), matchButton],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: description),
              const SizedBox(width: 8),
              matchButton,
            ],
          );
        },
      ),
    );
  }

  String _timeLabel(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  SubtitleCue? get _activeCue {
    final position = _controller?.value.position;
    if (position == null) return null;
    for (final cue in _cues) {
      if (cue.contains(position)) return cue;
    }
    return null;
  }

  Widget _player(BuildContext context) {
    final controller = _controller;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (controller == null || !controller.value.isInitialized) {
      final canTranscode = !_film.canAttemptPlayback && _film.probeStatus != 'pending';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_transcodeStarting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                )
              else
                Icon(
                  Icons.video_file_outlined,
                  size: 44,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              const SizedBox(height: 12),
              Text(_playbackMessage ?? '此视频无法播放。', textAlign: TextAlign.center),
              if (canTranscode && !_transcodeStarting) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => unawaited(
                    _startTranscode(start: _film.canResume ? _film.position : 0),
                  ),
                  icon: const Icon(Icons.auto_awesome, size: 17),
                  label: const Text('重试在线转码播放'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    final compactControls =
        MediaQuery.sizeOf(context).width < 480 ||
        MediaQuery.textScalerOf(context).scale(14) > 20;
    final controlTextStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Colors.white);
    final playButton = IconButton(
      tooltip: controller.value.isPlaying ? '暂停' : '播放',
      color: Colors.white,
      onPressed: () async {
        if (controller.value.isPlaying) {
          await controller.pause();
          unawaited(_queueProgressSave(force: true));
        } else {
          await controller.play();
        }
        if (mounted) setState(() {});
      },
      icon: Icon(controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
    );
    final positionLabel = Text(
      _timeLabel(Duration(milliseconds: (_originalPlaybackSeconds * 1000).round())),
      style: controlTextStyle,
    );
    final durationLabel = Text(
      _timeLabel(Duration(milliseconds: (_originalPlaybackDuration * 1000).round())),
      style: controlTextStyle,
    );
    Widget seekBar = VideoProgressIndicator(
      controller,
      allowScrubbing: true,
      padding: const EdgeInsets.symmetric(vertical: 9),
      colors: VideoProgressColors(
        playedColor: Theme.of(context).colorScheme.primary,
        bufferedColor: Colors.white54,
        backgroundColor: Colors.white24,
      ),
    );
    if (_hlsSession != null && _originalPlaybackDuration > 0) {
      final total = _originalPlaybackDuration;
      seekBar = Semantics(
        label: '原片完整进度',
        child: Slider(
          value: (_seekDraft ?? _originalPlaybackSeconds).clamp(0.0, total),
          min: 0,
          max: total,
          onChanged: _transcodeStarting
              ? null
              : (value) => setState(() => _seekDraft = value),
          onChangeEnd: (value) => unawaited(_seekAbsolute(value)),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final videoHeight = (constraints.maxWidth / aspectRatio)
            .clamp(0.0, 400.0)
            .toDouble();
        final videoWidth = videoHeight * aspectRatio;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: constraints.maxWidth,
              height: videoHeight,
              child: Center(
                child: SizedBox(
                  width: videoWidth,
                  height: videoHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTapDown: (details) {
                          final x = details.localPosition.dx;
                          if (x < videoWidth * .4) {
                            unawaited(_seekRelative(-10));
                          } else if (x > videoWidth * .6) {
                            unawaited(_seekRelative(10));
                          } else if (controller.value.isPlaying) {
                            unawaited(controller.pause());
                          } else {
                            unawaited(controller.play());
                          }
                        },
                        child: VideoPlayer(controller),
                      ),
                      if (_activeCue case final cue?)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            margin: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .78),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              cue.text,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: _subtitleFontSize,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
              child: compactControls
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            playButton,
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    positionLabel,
                                    const SizedBox(width: 12),
                                    durationLabel,
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: seekBar,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        playButton,
                        positionLabel,
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: seekBar,
                          ),
                        ),
                        durationLabel,
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: '全屏播放',
                    color: Colors.white,
                    onPressed: _transcodeStarting ? null : () => unawaited(_showFullscreenPlayer()),
                    icon: const Icon(Icons.fullscreen),
                  ),
                  IconButton(
                    tooltip: '快退 10 秒',
                    color: Colors.white,
                    onPressed: _transcodeStarting ? null : () => unawaited(_seekRelative(-10)),
                    icon: const Icon(Icons.replay_10),
                  ),
                  IconButton(
                    tooltip: '快进 10 秒',
                    color: Colors.white,
                    onPressed: _transcodeStarting ? null : () => unawaited(_seekRelative(10)),
                    icon: const Icon(Icons.forward_10),
                  ),
                  Icon(
                    controller.value.volume == 0
                        ? Icons.volume_off
                        : Icons.volume_up,
                    size: 19,
                    color: Colors.white,
                  ),
                  Semantics(
                    label: '音量',
                    child: SizedBox(
                      width: 110,
                      child: Slider(
                        value: controller.value.volume
                            .clamp(0.0, 1.0)
                            .toDouble(),
                        onChanged: (value) => controller.setVolume(value),
                        activeColor: Theme.of(context).colorScheme.primary,
                        inactiveColor: Colors.white38,
                        semanticFormatterCallback: (value) =>
                            '音量 ${(value * 100).round()}%',
                      ),
                    ),
                  ),
                  DropdownButton<String>(
                    value: _captionLanguage,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Colors.white),
                    dropdownColor: const Color(0xFF202124),
                    iconEnabledColor: Colors.white,
                    iconDisabledColor: Colors.white54,
                    underline: const SizedBox.shrink(),
                    hint: const Text(
                      '字幕',
                      style: TextStyle(color: Colors.white70),
                    ),
                    onChanged: (value) {
                      if (value != null) _loadSubtitles(value);
                    },
                    items: <DropdownMenuItem<String>>[
                      const DropdownMenuItem(
                        value: 'off',
                        child: Text(
                          '关闭字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'auto',
                        child: Text(
                          '同名字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'zh',
                        child: Text(
                          '中文字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'en',
                        child: Text(
                          '英文字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      for (final track
                          in _tracks?.subtitles ?? const <CinemaSubtitleTrack>[])
                        if (track.extractable)
                          DropdownMenuItem(
                            value: 'emb:${track.streamIndex}',
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                    ],
                  ),
                  if (_captionLanguage != 'off')
                    DropdownButton<double>(
                      value: _subtitleFontSize,
                      dropdownColor: const Color(0xFF202124),
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      onChanged: (size) {
                        if (size != null) setState(() => _subtitleFontSize = size);
                      },
                      items: const [
                        DropdownMenuItem(value: 15.0, child: Text('字幕 小')),
                        DropdownMenuItem(value: 17.0, child: Text('字幕 标准')),
                        DropdownMenuItem(value: 21.0, child: Text('字幕 大')),
                        DropdownMenuItem(value: 25.0, child: Text('字幕 特大')),
                      ],
                    ),
                  DropdownButton<String>(
                      value: _hlsSession?.quality ?? 'source',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      dropdownColor: const Color(0xFF202124),
                      iconEnabledColor: Colors.white,
                      iconDisabledColor: Colors.white54,
                      underline: const SizedBox.shrink(),
                      hint: const Text(
                        '清晰度',
                        style: TextStyle(color: Colors.white70),
                      ),
                      onChanged: (value) {
                        if (value != null) unawaited(_switchQuality(value));
                      },
                      items: <DropdownMenuItem<String>>[
                        for (final option in _qualityOptions())
                          DropdownMenuItem(
                            value: option.$1,
                            child: Text(
                              option.$2,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                    DropdownButton<double>(
                      value: _playbackSpeed,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      dropdownColor: const Color(0xFF202124),
                      iconEnabledColor: Colors.white,
                      iconDisabledColor: Colors.white54,
                      underline: const SizedBox.shrink(),
                      hint: const Text(
                        '倍速',
                        style: TextStyle(color: Colors.white70),
                      ),
                      onChanged: (value) {
                        if (value != null) unawaited(_setPlaybackSpeed(value));
                      },
                      items: const <DropdownMenuItem<double>>[
                        DropdownMenuItem(value: 0.75, child: Text('0.75x', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 1.0, child: Text('1x', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 1.25, child: Text('1.25x', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 1.5, child: Text('1.5x', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 2.0, child: Text('2x', style: TextStyle(color: Colors.white))),
                      ],
                    ),
                    if ((_tracks?.audio.length ?? 0) > 1 && _hlsSession != null)
                      DropdownButton<int>(
                        value: _hlsSession!.audioTrack,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      dropdownColor: const Color(0xFF202124),
                      iconEnabledColor: Colors.white,
                      iconDisabledColor: Colors.white54,
                      underline: const SizedBox.shrink(),
                      hint: const Text(
                        '音轨',
                        style: TextStyle(color: Colors.white70),
                      ),
                      onChanged: (value) {
                        if (value != null) unawaited(_switchAudio(value));
                      },
                      items: <DropdownMenuItem<int>>[
                        for (final track in _tracks?.audio ?? const <CinemaAudioTrack>[])
                          DropdownMenuItem(
                            value: track.audioIndex,
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _metadata(BuildContext context) {
    final format = <String>[
      _film.container.toUpperCase(),
      _film.videoCodec.toUpperCase(),
      _film.audioCodec.toUpperCase(),
    ].where((value) => value.isNotEmpty).join(' · ');
    final rows = <(IconData, String, String)>[
      (
        Icons.video_library_outlined,
        '类型',
        _film.isSeries
            ? '剧集 · 第 ${_film.season} 季 · 第 ${_film.episode} 集'
            : _film.year > 0
            ? '电影 · ${_film.year}'
            : '电影',
      ),
      (Icons.storage_outlined, '文件大小', formatMediaSize(_film.size)),
      (
        Icons.schedule_outlined,
        '时长',
        formatMediaSeconds(
          _film.durationSeconds > 0 ? _film.durationSeconds : _film.duration,
        ),
      ),
      if (_film.width > 0 && _film.height > 0)
        (
          Icons.aspect_ratio_outlined,
          '画面尺寸',
          '${_film.width} × ${_film.height}',
        ),
      if (format.isNotEmpty) (Icons.movie_outlined, '编码格式', format),
      if (_film.mime.isNotEmpty)
        (Icons.insert_drive_file_outlined, '媒体类型', _film.mime),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        for (final row in rows)
          SizedBox(
            width: 230,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  row.$1,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.$2,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(row.$3),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final position = _controller?.value.position;
    final resume = _film.canResume && position == null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              constraints: BoxConstraints(
                maxWidth: 1040,
                maxHeight: MediaQuery.sizeOf(context).height * .94,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withValues(
                      alpha: isDark ? 0.88 : 0.94,
                    ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.16)
                      : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
                  width: 0.85,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.15),
                    blurRadius: 36,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
                    child: Row(
                      children: [
                        Hero(
                          tag: 'cinema_poster_${_film.id}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 38,
                              height: 54,
                              child: AuthenticatedMediaImage(
                                api: widget.api,
                                path: '/api/v2/cinema/${_film.id}/poster',
                                maxBytes: 2 * 1024 * 1024,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _film.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.3,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _film.isSeries
                                    ? '第 ${_film.season} 季 · 第 ${_film.episode} 集'
                                    : '电影详情',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                    if (widget.isAdmin)
                      IconButton.filledTonal(
                        tooltip: '修改展示名称',
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  final updated = await widget.onRename(_film);
                                  if (mounted) setState(() => _film = updated);
                                } catch (error) {
                                  if (mounted) {
                                    setState(
                                      () => _playbackMessage = mediaErrorLabel(
                                        error,
                                      ),
                                    );
                                  }
                                } finally {
                                  if (mounted) setState(() => _busy = false);
                                }
                              },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: _closing ? null : _close,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (resume && _film.position > 5)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            '上次观看至 ${_timeLabel(Duration(seconds: _film.position.round()))}。',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      if (_playbackMessage != null && !_film.canAttemptPlayback)
                        MediaStatusBanner(
                          message: _playbackMessage!,
                          icon: Icons.info_outline,
                        ),
                      if (_playbackMessage != null && _film.canAttemptPlayback)
                        MediaStatusBanner(
                          message: _playbackMessage!,
                          icon: Icons.warning_amber_outlined,
                        ),
                      const SizedBox(height: 10),
                      Container(
                        constraints: const BoxConstraints(minHeight: 180),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _player(context),
                      ),
                      if (_progressSaveMessage != null)
                        MediaStatusBanner(
                          message: _progressSaveMessage!,
                          icon: Icons.cloud_off_outlined,
                          isError: true,
                          trailing: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 4,
                            children: [
                              TextButton(
                                onPressed: _closing
                                    ? null
                                    : () => unawaited(
                                        _queueProgressSave(force: true),
                                      ),
                                child: const Text('重试'),
                              ),
                              TextButton(
                                onPressed: _closing
                                    ? null
                                    : () => _close(allowUnsaved: true),
                                child: const Text('仍然关闭'),
                              ),
                            ],
                          ),
                        ),
                      if (_subtitleMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _subtitleMessage!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                      if (_film.canAttemptPlayback) ...[
                        const SizedBox(height: 18),
                        Text(
                          '播放进度',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        _metadata(context),
                      ] else ...[
                        const SizedBox(height: 18),
                        Text(
                          '媒体信息',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        _metadata(context),
                      ],
                      if (_film.overview.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text(
                          '简介',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(_film.overview),
                      ],
                      if (_film.metadataSource.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          '${_film.metadataSource.startsWith('nfo:') ? '资料来源：本地 NFO' : '资料来源：TMDB'}${_film.rating > 0 ? ' · 评分 ${_film.rating.toStringAsFixed(1)} / 10' : ''}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                      if (widget.isAdmin) ...[
                        const SizedBox(height: 18),
                        _metadataMatchingPanel(context),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);
  }
}
