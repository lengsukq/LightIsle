import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/isle_action_menu.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_page_result.dart';
import 'media_scan_poller.dart';
import 'media_batch_operations.dart';
import 'media_ui.dart';
import 'local_video_page.dart';
import 'cinema_detail_dialog.dart';
import 'cinema_film_tile.dart';
import 'cinema_film_overview.dart';
import 'cinema_series_overview.dart';
export 'cinema_detail_dialog.dart' show CinemaDetailDialog;
import 'offline_videos_page.dart';
import '../files/files_page.dart';
import '../files/file_export_service.dart';
import '../files/upload_task_center.dart';

part 'cinema_page_batch_actions.dart';
part 'cinema_page_library.dart';
part 'cinema_page_history.dart';
part 'cinema_page_series.dart';

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
  void _updateState(VoidCallback fn) => setState(fn);

  static const int _pageSize = 48;

  final MediaImageMemoryCache _posterCache = MediaImageMemoryCache();
  final List<CinemaFilm> _films = [];
  final List<CinemaFilm> _resumeShelf = [];
  final List<CinemaFilm> _recentShelf = [];
  int _shelfGeneration = 0;
  bool _shelvesLoaded = false;
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
  String? _loadError;
  String? _actionMessage;
  bool _actionIsError = false;
  String? _scanError;
  MediaScanStatus _scanStatus = const MediaScanStatus();
  Timer? _searchTimer;
  bool _tabEnabled = true;
  bool _appForeground = true;
  late final MediaScanPoller _scanPoller = MediaScanPoller(
    onPoll: () => unawaited(_refreshStatus()),
  );
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
    unawaited(_loadShelves());
    WidgetsBinding.instance.addObserver(this);
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
    _posterCache.dispose();
    _listGeneration++;
    _shelfGeneration++;
    _statusGeneration++;
    _searchTimer?.cancel();
    _scanPoller.dispose();
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
    if (!_scanPoller.setActive(active)) return;
    if (!active) {
      _statusGeneration++;
    } else {
      _refreshStatus();
    }
  }

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
      await Future.wait([
        _loadFilms(reset: true),
        if (_mode == 'all') _loadShelves(),
      ]);
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
    padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _viewChip(
                '首页',
                Icons.home_outlined,
                !_showSeries && !_showHistory && _mode == 'all',
                () {
                  setState(() {
                    _showSeries = false;
                    _showHistory = false;
                  });
                  _changeMode('all');
                },
              ),
              const SizedBox(width: 6),
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
              const SizedBox(width: 6),
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
              const SizedBox(width: 6),
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
              const SizedBox(width: 6),
              _viewChip(
                '观看历史',
                Icons.history_rounded,
                _showHistory,
                () {
                  setState(() {
                    _showHistory = true;
                    _showSeries = false;
                    _selecting = false;
                    _selectedFilmIds.clear();
                  });
                  unawaited(_loadHistory());
                },
              ),
              const SizedBox(width: 6),
              _viewChip(
                '待匹配',
                Icons.auto_fix_high_outlined,
                !_showSeries && !_showHistory && _mode == 'unmatched',
                () {
                  setState(() {
                    _showSeries = false;
                    _showHistory = false;
                  });
                  _changeMode('unmatched');
                  if (widget.isAdmin) unawaited(_refreshScrape());
                },
              ),
              if (_showHistory || _mode == 'continue') ...[
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _showHistory = false;
                      _showSeries = false;
                    });
                    _changeMode('all');
                  },
                  child: const Text('返回首页'),
                ),
              ],
            ],
          ),
        ),
        if (_showSearch && !_showSeries && !_showHistory)
          Padding(
            padding: const EdgeInsets.only(top: 8),
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    return RefreshIndicator(
      onRefresh: _refreshView,
      child: CustomScrollView(
        key: PageStorageKey<String>(
          'cinema:${widget.api.selectedRoot?.identity ?? 'default'}',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    _pageInset,
                    IsleLayout.pageTopInset(screenWidth),
                    _pageInset,
                    0,
                  ),
                  child: IslePageHeader(
                    title: '影视',
                    hideSubtitleOnCompact:
                        !_showSeries && !_showHistory && _mode == 'all',
                    subtitle: _showSeries
                        ? '按剧名与季数整理'
                        : _showHistory
                        ? '最近观看的影片'
                        : _mode == 'movie'
                        ? '电影收藏'
                        : _mode == 'unmatched'
                        ? '尚未确认海报与简介的影片'
                        : _mode == 'continue'
                        ? '从上次看到的地方接着看'
                        : '找到想看的内容，随时继续播放',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_showSeries && !_showHistory)
                          IconButton(
                            key: const Key('cinema-select-toggle'),
                            visualDensity: VisualDensity.compact,
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
                          visualDensity: VisualDensity.compact,
                          tooltip: '搜索影片',
                          onPressed: () => setState(() {
                            _showSearch = !_showSearch;
                            _showSeries = false;
                            _showHistory = false;
                          }),
                          icon: const Icon(Icons.search_rounded),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
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
                    child: MediaSelectionActionBar(
                      label: '已选 ${_selectedFilmIds.length} 项 · 最多 50 项',
                      actions: [
                        OutlinedButton.icon(
                          onPressed: _batchBusy || _films.isEmpty
                              ? null
                              : _selectVisibleFilms,
                          icon: const Icon(Icons.select_all_rounded, size: 17),
                          label: Text(
                            _films
                                    .take(50)
                                    .every(
                                      (film) =>
                                          _selectedFilmIds.contains(film.id),
                                    )
                                ? '取消全选'
                                : '全选当前页',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _batchBusy || _selectedFilmIds.isEmpty
                              ? null
                              : _batchSaveFilms,
                          icon: const Icon(Icons.download_outlined, size: 17),
                          label: const Text('保存原文件'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _batchBusy || _selectedFilmIds.isEmpty
                              ? null
                              : _batchShareFilms,
                          icon: const Icon(Icons.ios_share_outlined, size: 17),
                          label: const Text('分享'),
                        ),
                        if (_selectedFilms.isNotEmpty &&
                            _selectedFilms.every(
                              (film) => widget.isAdmin || film.canWrite,
                            ))
                          FilledButton.tonalIcon(
                            onPressed: _batchBusy || _selectedFilmIds.isEmpty
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
            SliverToBoxAdapter(child: _featuredFilmBanner()),
          if (!_showSeries && !_showHistory && _mode == 'all' && !_selecting)
            SliverToBoxAdapter(child: _continueWatchingRail()),
          if (!_showSeries && !_showHistory && _mode == 'all' && !_selecting)
            SliverToBoxAdapter(child: _topRatedRail()),
          if (!_showSeries && !_showHistory && _mode == 'all' && !_selecting)
            SliverToBoxAdapter(child: _recentlyAddedRail()),
          if (!_showSeries &&
              !_showHistory &&
              _mode == 'unmatched' &&
              widget.isAdmin)
            SliverToBoxAdapter(child: _adminScrapeBar()),
          if (!_showSeries && !_showHistory && _films.isNotEmpty && !_selecting)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(_pageInset, 8, _pageInset, 6),
                child: Text(
                  _mode == 'movie'
                      ? '电影'
                      : _mode == 'unmatched'
                      ? '待匹配资料'
                      : _mode == 'continue'
                      ? '待续播'
                      : _query.isNotEmpty
                      ? '搜索结果'
                      : '全部影片',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
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
                const SizedBox(height: 76),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
