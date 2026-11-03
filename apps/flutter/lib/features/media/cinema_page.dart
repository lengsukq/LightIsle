import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/isle_action_menu.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_page_result.dart';
import 'media_ui.dart';
import 'local_video_page.dart';
import 'cinema_detail_dialog.dart';
export 'cinema_detail_dialog.dart' show CinemaDetailDialog;
import 'offline_videos_page.dart';
import '../files/files_page.dart';
import '../files/file_export_service.dart';
import '../files/upload_task_center.dart';

class CinemaPage extends StatefulWidget {
  const CinemaPage({
    required this.api,
    required this.isAdmin,
    this.accountName = '',
    this.taskCenter,
    this.uploadDirectory = '影视',
    super.key,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final UploadTaskCenter? taskCenter;
  final String uploadDirectory;

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
  bool _showSearch = false;
  bool _loading = true;
  bool _selecting = false;
  bool _batchBusy = false;
  final Set<int> _selectedFilmIds = <int>{};
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

  void _toggleFilmSelection(CinemaFilm film) {
    if (_batchBusy) return;
    HapticFeedback.selectionClick();
    setState(() {
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
    setState(() {
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
    setState(() {
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
      setState(() {
        _actionMessage = '影片列表已变化，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    setState(() {
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
            setState(() {
              _actionMessage = '正在保存影片 $done/$total';
              _actionIsError = false;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _actionMessage = message;
          _actionIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = '批量保存失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _batchShareFilms() async {
    if (_batchBusy || _selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.length != _selectedFilmIds.length || films.length > 10) {
      setState(() {
        _actionMessage = '每次最多分享 10 部影片，请重新选择。';
        _actionIsError = true;
      });
      return;
    }
    final confirmed = await confirmAction(
      context,
      '分享所选影片',
      '为 ${films.length} 部影片创建各自有效期 24 小时的公开下载链接。拿到链接的人无需登录。',
      action: '创建并复制链接',
    );
    if (!confirmed || !mounted) return;
    setState(() => _batchBusy = true);
    final links = <String>[];
    String? failure;
    for (final film in films) {
      try {
        final response = await widget.api.send(
          'POST',
          '/api/v2/file-shares',
          body: {'path': film.path, 'hours': 24},
        );
        final token = response['token']?.toString() ?? '';
        if (token.isEmpty) throw const FormatException('服务器未返回分享令牌');
        links.add(
          '${film.title}: ${widget.api.publicFileShareUri(token)}',
        );
      } catch (error) {
        failure = mediaErrorLabel(error);
        break;
      }
      if (!mounted) return;
    }
    if (links.isNotEmpty) {
      try {
        await Clipboard.setData(ClipboardData(text: links.join('\n')));
      } catch (_) {
        failure ??= '无法复制链接，请进入文件分享列表撤销并重试。';
      }
    }
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _actionMessage = failure == null
          ? '已创建并复制 ${links.length} 条限时链接。'
          : '已创建 ${links.length} 条链接，后续失败：$failure';
      _actionIsError = failure != null;
    });
  }

  Future<void> _batchTrashFilms() async {
    if (!widget.isAdmin || _batchBusy || _selectedFilmIds.isEmpty) return;
    final films = _selectedFilms;
    if (films.length != _selectedFilmIds.length ||
        films.any((film) => film.path.isEmpty)) {
      setState(() {
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
    if (!confirmed || !mounted) return;
    setState(() => _batchBusy = true);
    try {
      final response = await widget.api.send(
        'POST',
        '/api/v2/files/batch',
        body: {
          'action': 'trash',
          'paths': [for (final film in films) film.path],
        },
      );
      final raw = response['results'];
      final results = raw is List ? raw : const [];
      final succeeded = results
          .where((result) => result is Map && result['success'] == true)
          .length;
      await _loadFilms(reset: true);
      if (mounted) {
        setState(() {
          _actionMessage = '已移入回收站 $succeeded/${films.length} 项。影视库将在下次扫描后更新。';
          _actionIsError = succeeded != films.length;
          _selecting = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = '批量删除失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  Future<void> _openLocalVideo() async {
    try {
      final selected = await FilePicker.pickFiles(type: FileType.video);
      if (!mounted || selected.isEmpty) return;
      final path = selected.first.path;
      if (path == null || path.isEmpty) {
        setState(() {
          _actionMessage = '无法获取所选文件的本地路径。';
          _actionIsError = true;
        });
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => LocalVideoPage(path: path)),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    }
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
        _selectedFilmIds.clear();
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
      final page = MediaPageResult.parse<CinemaFilm>(
        response,
        itemsKey: 'films',
        fromJson: CinemaFilm.fromJson,
      );
      setState(() {
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
        query: <String, String>{
          'limit': '48',
          'cursor': '${reset ? 0 : _historyNext}',
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
          trailing: TextButton(
            onPressed: () => _loadHistory(),
            child: const Text('重试'),
          ),
        )
      else if (_history.isEmpty)
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
            for (final film in _history)
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
                onTap: () => unawaited(_openFilm(film)),
              ),
          ],
        ),
        if (_historyNext > 0)
          Padding(
            padding: EdgeInsets.fromLTRB(_pageInset, 10, _pageInset, 0),
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
            items.add(
              CinemaSeriesInfo.fromJson(Map<String, dynamic>.from(item)),
            );
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
        final seasons = films.map((film) => film.season).toSet().toList()
          ..sort();
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
                          for (final episode in films.where(
                            (film) => film.season == season,
                          ))
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
                                  ? Text(
                                      '已看至 ${formatMediaSeconds(episode.position)}',
                                    )
                                  : null,
                              trailing: episode.completed
                                  ? Icon(
                                      Icons.check_circle,
                                      size: 18,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    )
                                  : Text(
                                      formatMediaSeconds(
                                        episode.durationSeconds > 0
                                            ? episode.durationSeconds
                                            : episode.duration,
                                      ),
                                    ),
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

  Widget _viewChip(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) => MediaFilterChip(
    label: label,
    selected: selected,
    onSelected: onTap,
    icon: icon,
  );

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
          trailing: TextButton(onPressed: _loadSeries, child: const Text('重试')),
        )
      else if (_series.isEmpty)
        MediaEmptyState(
          icon: Icons.live_tv_outlined,
          title: '还没有可聚合的剧集',
          message: '将剧集文件（如 Show.S01E01.mkv）加入共享目录并扫描后，这里会按剧名聚合。',
        )
      else
        Padding(
          padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 0),
          child: GridView.count(
            crossAxisCount: MediaQuery.sizeOf(context).width > 720 ? 3 : 1,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 3.4,
            children: <Widget>[
              for (final series in _series)
                IsleSurface(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  radius: 14,
                  onTap: () => unawaited(_openSeries(series)),
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
            ],
          ),
        ),
      if (widget.isAdmin) ...<Widget>[
        const SizedBox(height: 8),
        Padding(
          padding: EdgeInsets.fromLTRB(_pageInset, 10, _pageInset, 0),
          child: Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text('TMDB 自动刮削', style: theme.textTheme.titleSmall),
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
            padding: EdgeInsets.fromLTRB(_pageInset, 6, _pageInset, 0),
            child: Text(_scrapeMessage!, style: theme.textTheme.bodySmall),
          ),
      ],
    ];
  }

  Widget _filmGrid() {
    if (_films.isEmpty && _loading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(56),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_films.isEmpty && _loadError != null) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.local_movies_outlined,
          title: '暂时无法读取影视库',
          message: _loadError!,
          action: OutlinedButton.icon(
            onPressed: _loading ? null : () => _loadFilms(reset: true),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_films.isEmpty) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.local_movies_outlined,
          title: _query.isNotEmpty
              ? '没有找到匹配影片'
              : _mode == 'continue'
              ? '没有待续播的影片'
              : '影视库还没有影片',
          message: _query.isNotEmpty ? '调整关键词后再搜索。' : '点击上传，把设备上的视频保存到 NAS。',
          action: _query.isEmpty
              ? FilledButton.icon(
                  onPressed: _upload,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('上传视频'),
                )
              : null,
        ),
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
            .clamp(1.0, 2.5)
            .toDouble();
        final width = constraints.crossAxisExtent;
        final columns = (width / 176).floor().clamp(2, 8).toInt();
        final posterWidth = (width - 36 - (columns - 1) * 12) / columns;
        // The footer can have title, kind/duration, resume/codec status and
        // an admin edit action. The previous 78px allowance clipped real
        // cards by up to 26px on 320px screens with 200% text.
        final footerHeight = 92 * textScale + 12;
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(_pageInset, 2, _pageInset, 0),
          sliver: SliverGrid.builder(
            itemCount: _films.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 14,
              mainAxisExtent: posterWidth * 1.5 + footerHeight,
            ),
            itemBuilder: (context, index) {
              final film = _films[index];
              return _CinemaTile(
                api: widget.api,
                film: film,
                isAdmin: widget.isAdmin,
                selecting: _selecting,
                selected: _selectedFilmIds.contains(film.id),
                onToggle: () => _toggleFilmSelection(film),
                onOpen: () => _openFilm(film),
                onRename: () => _renameFilm(film),
              );
            },
          ),
        );
      },
    );
  }

  Widget _continueWatchingRail() {
    if (_mode != 'all') return const SizedBox.shrink();
    final films = _films.where((film) => film.canResume).take(6).toList();
    if (films.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.5)
        .toDouble();
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 10, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 18, bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '继续观看',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () => _changeMode('continue'),
                  child: const Text('查看全部'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 132 + 72 * (textScale - 1),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 18),
              itemCount: films.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final film = films[index];
                final progress = film.duration > 0
                    ? (film.position / film.duration).clamp(0.0, 1.0).toDouble()
                    : 0.0;
                return SizedBox(
                  width: 252 + 76 * (textScale - 1),
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _openFilm(film),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 88,
                            height: double.infinity,
                            child: AuthenticatedMediaImage(
                              api: widget.api,
                              path: '/api/v2/cinema/${film.id}/poster',
                              maxBytes: 4 * 1024 * 1024,
                              fit: BoxFit.cover,
                              loadingBuilder: (_) => _continuePlaceholder(),
                              errorBuilder: (_, _, retry) => InkWell(
                                onTap: retry,
                                child: _continuePlaceholder(),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    film.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  const Spacer(),
                                  Text(
                                    film.isSeries
                                        ? '第 ${film.season} 季 · 第 ${film.episode} 集'
                                        : '继续播放',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _continuePlaceholder() => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: const Center(child: Icon(Icons.movie_outlined, size: 26)),
  );

  Future<void> _upload() async {
    final count = await openFileUpload(
      context,
      api: widget.api,
      isAdmin: widget.isAdmin,
      directory: widget.uploadDirectory,
      type: FileType.video,
      title: '上传视频',
      taskCenter: widget.taskCenter,
      accountName: widget.accountName,
    );
    if (!mounted || count == 0) return;
    String? indexingError;
    if (widget.isAdmin && !_scanning) {
      await _startScan();
      if (_actionIsError) indexingError = _actionMessage;
    }
    if (!mounted) return;
    setState(() {
      _actionMessage =
          '已上传 $count 个视频。${indexingError == null ? '索引更新后会显示在影片中，可下拉刷新。' : '影视整理暂未开始：$indexingError'}';
      _actionIsError = indexingError != null;
      _showSeries = false;
      _showHistory = false;
      _mode = 'all';
      _searchTimer?.cancel();
      _query = '';
      _searchController.clear();
      _showSearch = false;
    });
    await _loadFilms(reset: true);
  }

  Future<void> _refreshView() async {
    if (_showSeries) {
      await _loadSeries();
    } else if (_showHistory) {
      await _loadHistory();
    } else {
      await _loadFilms(reset: true);
    }
  }

  void _cinemaAction(String value) {
    switch (value) {
      case 'select':
        if (_selecting) {
          _endFilmSelection();
        } else {
          setState(() {
            _selecting = true;
            _showSeries = false;
            _showHistory = false;
          });
        }
      case 'scan':
        _startScan();
      case 'refresh':
        _refreshView();
      case 'local':
        unawaited(_openLocalVideo());
      case 'offline':
        if (widget.accountName.isEmpty) {
          setState(() {
            _actionMessage = '服务器未提供稳定账号 ID，请升级 NAS 服务端后再使用离线库。';
            _actionIsError = true;
          });
          return;
        }
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => OfflineVideosPage(
              api: widget.api,
              accountName: widget.accountName,
            ),
          ),
        );
      case 'files':
        openFileManager(
          context,
          api: widget.api,
          isAdmin: widget.isAdmin,
          directory: widget.uploadDirectory,
          title: '视频文件',
        );
      default:
        setState(() {
          _showSeries = false;
          _showHistory = false;
        });
        _changeMode(value);
    }
  }

  Widget _cinemaNavigation() => Padding(
    padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _viewChip(
                '全部',
                Icons.grid_view_rounded,
                !_showSeries && !_showHistory && _mode == 'all',
                () {
                  setState(() {
                    _showSeries = false;
                    _showHistory = false;
                  });
                  _changeMode('all');
                },
              ),
              const SizedBox(width: 8),
              _viewChip(
                '电影',
                Icons.movie_outlined,
                !_showSeries && !_showHistory && _mode == 'movie',
                () {
                  setState(() {
                    _showSeries = false;
                    _showHistory = false;
                  });
                  _changeMode('movie');
                },
              ),
              const SizedBox(width: 8),
              _viewChip('剧集', Icons.video_library_rounded, _showSeries, () {
                setState(() {
                  _showSeries = true;
                  _showHistory = false;
                  _selecting = false;
                  _selectedFilmIds.clear();
                });
                unawaited(_loadSeries());
                if (widget.isAdmin) unawaited(_refreshScrape());
              }),
              const SizedBox(width: 8),
              _viewChip(
                '继续观看',
                Icons.play_circle_outline_rounded,
                !_showSeries && !_showHistory && _mode == 'continue',
                () {
                  setState(() {
                    _showSeries = false;
                    _showHistory = false;
                  });
                  _changeMode('continue');
                },
              ),
              const SizedBox(width: 8),
              _viewChip('历史', Icons.history_rounded, _showHistory, () {
                setState(() {
                  _showHistory = true;
                  _showSeries = false;
                  _selecting = false;
                  _selectedFilmIds.clear();
                });
                unawaited(_loadHistory());
              }),
            ],
          ),
        ),
        if (_showSearch && !_showSeries && !_showHistory)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _searchChanged,
              maxLength: 120,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索影片或剧集',
                counterText: '',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '关闭搜索',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchController.clear();
                    _searchChanged('');
                    setState(() => _showSearch = false);
                  },
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// Shared horizontal baseline so header, chips, grids and footers align
  /// with the other main tabs on every window width.
  double get _pageInset =>
      IsleLayout.pageInset(MediaQuery.sizeOf(context).width);

  @override
  Widget build(BuildContext context) {
    final continueCount = _films.where((film) => film.canResume).length;
    return RefreshIndicator(
      onRefresh: _refreshView,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(_pageInset, 16, _pageInset, 0),
                  child: IslePageHeader(
                    title: '影院',
                    subtitle: '收藏的影片，随时接着看',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_showSeries && !_showHistory)
                          IconButton(
                            key: const Key('cinema-select-toggle'),
                            tooltip: _selecting ? '结束多选' : '多选影片',
                            onPressed: _batchBusy
                                ? null
                                : () {
                                    if (_selecting) {
                                      _endFilmSelection();
                                    } else {
                                      setState(() => _selecting = true);
                                    }
                                  },
                            icon: Icon(
                              _selecting
                                  ? Icons.close_rounded
                                  : Icons.checklist_rounded,
                            ),
                            color: _selecting
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        IconButton(
                          tooltip: '搜索影片',
                          onPressed: () => setState(() {
                            _showSearch = !_showSearch;
                            _showSeries = false;
                            _showHistory = false;
                          }),
                          icon: const Icon(Icons.search_rounded),
                        ),
                        IconButton(
                          tooltip: '上传视频',
                          onPressed: _upload,
                          icon: const Icon(Icons.add_rounded),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '更多影院操作',
                          onSelected: _cinemaAction,
                          position: PopupMenuPosition.under,
                          constraints: const BoxConstraints(
                            minWidth: 218,
                            maxWidth: 270,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          itemBuilder: (_) => [
                            isleActionMenuItem(
                              value: 'select',
                              icon: _selecting
                                  ? Icons.close_rounded
                                  : Icons.checklist_rounded,
                              label: _selecting ? '结束多选' : '多选影片',
                            ),
                            const PopupMenuDivider(),
                            isleActionMenuItem(
                              value: 'files',
                              icon: Icons.folder_open_outlined,
                              label: '管理视频文件',
                            ),
                            isleActionMenuItem(
                              value: 'local',
                              icon: Icons.play_circle_outline_rounded,
                              label: '播放本地视频（离线）',
                            ),
                            isleActionMenuItem(
                              value: 'offline',
                              icon: Icons.offline_pin_outlined,
                              label: '我的离线影片库',
                            ),
                            isleActionMenuItem(
                              value: 'refresh',
                              icon: Icons.refresh_rounded,
                              label: '刷新影视库',
                            ),
                            if (widget.isAdmin)
                              isleActionMenuItem(
                                value: 'scan',
                                enabled: !_scanning,
                                icon: Icons.sync_rounded,
                                label: _scanning ? '扫描中' : '扫描影视库',
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                _cinemaNavigation(),
                if (_selecting && !_showSeries && !_showHistory)
                  Padding(
                    padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 14),
                    child: Card(
                      margin: EdgeInsets.zero,
                      color: Theme.of(context).colorScheme.primaryContainer
                          .withValues(alpha: .45),
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '已选 ${_selectedFilmIds.length} 项 · 最多 50 项',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            OutlinedButton.icon(
                              onPressed: _batchBusy || _films.isEmpty
                                  ? null
                                  : _selectVisibleFilms,
                              icon: const Icon(
                                Icons.select_all_rounded,
                                size: 17,
                              ),
                              label: Text(
                                _films
                                        .take(50)
                                        .every(
                                          (film) => _selectedFilmIds.contains(
                                            film.id,
                                          ),
                                        )
                                    ? '取消全选'
                                    : '全选当前页',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _batchBusy || _selectedFilmIds.isEmpty
                                  ? null
                                  : _batchSaveFilms,
                              icon: const Icon(
                                Icons.download_outlined,
                                size: 17,
                              ),
                              label: const Text('保存原文件'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _batchBusy || _selectedFilmIds.isEmpty
                                  ? null
                                  : _batchShareFilms,
                              icon: const Icon(
                                Icons.ios_share_outlined,
                                size: 17,
                              ),
                              label: const Text('分享'),
                            ),
                            if (widget.isAdmin)
                              FilledButton.tonalIcon(
                                onPressed:
                                    _batchBusy || _selectedFilmIds.isEmpty
                                    ? null
                                    : _batchTrashFilms,
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 17,
                                ),
                                label: const Text('移入回收站'),
                              ),
                            TextButton(
                              onPressed: _batchBusy ? null : _endFilmSelection,
                              child: const Text('完成'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_scanning)
                  MediaStatusBanner(
                    message: '正在整理影视库 · 找到 ${_scanStatus.found} 部影片',
                    icon: Icons.sync,
                  ),
                if (_scanError != null)
                  MediaStatusBanner(
                    message: '上次扫描未完成：$_scanError',
                    isError: true,
                  ),
                if (_actionMessage != null)
                  MediaStatusBanner(
                    message: _actionMessage!,
                    isError: _actionIsError,
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
                      onPressed: _loadingMore
                          ? null
                          : () => _loadFilms(reset: false),
                      child: const Text('重试'),
                    ),
                  ),
                if (_showSeries)
                  ..._seriesView()
                else if (_showHistory)
                  ..._historyView(),
              ],
            ),
          ),
          if (!_showSeries && !_showHistory && _mode == 'all' && !_selecting)
            SliverToBoxAdapter(child: _continueWatchingRail()),
          if (!_showSeries && !_showHistory) _filmGrid(),
          SliverToBoxAdapter(
            child: Column(
              children: [
                if (!_showSeries && !_showHistory && _films.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      _pageInset,
                      22,
                      _pageInset,
                      26,
                    ),
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
                  padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 22),
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
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
    required this.onRename,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
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
      selected: widget.selected,
      label: widget.selecting ? '选择：${film.title}' : '播放：${film.title}',
      child: Material(
        color: widget.selected
            ? surface.primaryContainer.withValues(alpha: .32)
            : Colors.transparent,
        child: InkWell(
          onTap: widget.selecting ? widget.onToggle : widget.onOpen,
          onLongPress: widget.onToggle,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
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
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .65),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            child: Text(
                              film.isSeries
                                  ? 'S${film.season} · E${film.episode}'
                                  : '${film.year == 0 ? '电影' : film.year}',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                            ),
                          ),
                        ),
                      ),
                      if (!film.canAttemptPlayback)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .65),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.info_outline_rounded,
                              color: surface.error,
                              size: 14,
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
                            minHeight: 3,
                            backgroundColor: Colors.black38,
                            color: const Color(0xff3b82f6),
                          ),
                        ),
                      if (widget.selecting)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: widget.selected
                                  ? surface.primary
                                  : Colors.black54,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1.5,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                widget.selected
                                    ? Icons.check_rounded
                                    : Icons.circle_outlined,
                                size: 17,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            film.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${film.isSeries ? '剧集' : '电影'} · ${formatMediaSeconds(film.durationSeconds > 0 ? film.durationSeconds : film.duration)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: surface.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                          ),
                          if (film.completed)
                            Text(
                              '已看完',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: const Color(0xFF15803D),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
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
                                    fontSize: 12,
                                  ),
                            ),
                          if (!film.canAttemptPlayback)
                            Text(
                              _playbackLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: surface.error,
                                    fontSize: 12,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.isAdmin && !widget.selecting)
                      IconButton(
                        tooltip: '修改展示名称',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: widget.onRename,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                      ),
                  ],
                ),
              ),
            ],
          ),
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
