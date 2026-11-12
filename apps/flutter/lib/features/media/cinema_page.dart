import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_action_menu.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/isle_data_cache.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/widgets.dart';
import '../files/file_export_service.dart';
import '../files/files_page.dart';
import '../files/upload_task_center.dart';
import 'cinema_catalog_display.dart';
import 'cinema_detail_dialog.dart';
import 'cinema_film_overview.dart';
import 'cinema_film_tile.dart';
import 'cinema_page_state_models.dart';
import 'cinema_series_overview.dart';
import 'local_video_page.dart';
import 'media_batch_operations.dart';
import 'media_models.dart';
import 'media_page_result.dart';
import 'media_scan_poller.dart';
import 'media_ui.dart';
import 'offline_videos_page.dart';
export 'cinema_detail_dialog.dart' show CinemaDetailDialog;

part 'cinema_page_batch_actions.dart';
part 'cinema_page_library.dart';
part 'cinema_page_history.dart';
part 'cinema_page_series.dart';
part 'cinema_page_home_rails.dart';

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

  MediaImageMemoryCache get _posterCache =>
      IsleCacheManager.instance.sharedPosters;
  final CinemaCatalogViewState _catalog = CinemaCatalogViewState();
  final CinemaBatchSelectionState _selection = CinemaBatchSelectionState();
  final CinemaIndexingViewState _indexing = CinemaIndexingViewState();
  final CinemaSecondaryViewsState _subpages = CinemaSecondaryViewsState();
  bool _tabEnabled = true;
  bool _appForeground = true;
  late final MediaScanPoller _scanPoller = MediaScanPoller(
    onPoll: () => unawaited(_refreshStatus()),
  );

  bool get _isRootCinemaView => _subpages.isRootView && _catalog.mode == 'all';

  @override
  void initState() {
    super.initState();
    _loadFilms(reset: true);
    unawaited(_loadShelves());
    unawaited(_refreshStatus());
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _openLocalVideo() async {
    try {
      final selected = await FilePicker.pickFiles(type: FileType.video);
      if (!mounted || selected.isEmpty) return;
      final path = selected.first.path;
      if (path == null || path.isEmpty) {
        setState(() {
          _catalog.actionMessage = '无法获取所选文件的本地路径。';
          _catalog.actionIsError = true;
        });
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => LocalVideoPage(path: path)),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _catalog.actionMessage = mediaErrorLabel(error);
          _catalog.actionIsError = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _catalog.dispose();
    _indexing.dispose();
    _scanPoller.dispose();
    WidgetsBinding.instance.addObserver(this);
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
      _indexing.statusGeneration++;
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
    if (widget.isAdmin &&
        (!_indexing.scanning || _indexing.scanStatus.operation == 'scrape')) {
      await _startScan();
      if (_catalog.actionIsError) indexingError = _catalog.actionMessage;
    } else {
      _indexing.postUploadTimer?.cancel();
      _indexing.postUploadTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) unawaited(_refreshStatus());
      });
    }
    if (!mounted) return;
    setState(() {
      _catalog.actionMessage =
          '已上传 $count 个视频。${indexingError == null ? '正在自动识别并匹配海报与简介，完成后将自动刷新。' : '影视整理暂未开始：$indexingError'}';
      _catalog.actionIsError = indexingError != null;
      _subpages.exitSecondaryViews();
      _catalog.mode = 'all';
      _catalog.resetSearch();
    });
    await _loadFilms(reset: true);
  }

  Future<void> _refreshView() async {
    if (_subpages.showSeries) {
      await _loadSeries();
    } else if (_subpages.showHistory) {
      await _loadHistory();
    } else {
      await Future.wait([
        _loadFilms(reset: true),
        if (_catalog.mode == 'all') _loadShelves(),
      ]);
    }
  }

  void _cinemaAction(String value) {
    switch (value) {
      case 'select':
        if (_selection.selecting) {
          _endFilmSelection();
        } else {
          setState(() {
            _selection.selecting = true;
            _subpages.exitSecondaryViews();
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
            _catalog.actionMessage = '服务器未提供稳定账号 ID，请升级 NAS 服务端后再使用离线库。';
            _catalog.actionIsError = true;
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
        setState(_subpages.exitSecondaryViews);
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
                _isRootCinemaView,
                () => _switchToFilmMode('all'),
              ),
              const SizedBox(width: 6),
              _viewChip(
                '电影',
                Icons.movie_outlined,
                _subpages.isRootView && _catalog.mode == 'movie',
                () => _switchToFilmMode('movie'),
              ),
              const SizedBox(width: 6),
              _viewChip(
                '剧集',
                Icons.video_library_rounded,
                _subpages.showSeries,
                () {
                  setState(() {
                    _subpages.showSeries = true;
                    _subpages.showHistory = false;
                    _selection.clear();
                  });
                  unawaited(_loadSeries());
                  if (widget.isAdmin) unawaited(_refreshScrape());
                },
              ),
              const SizedBox(width: 6),
              _viewChip(
                '继续观看',
                Icons.play_circle_outline_rounded,
                _subpages.isRootView && _catalog.mode == 'continue',
                () => _switchToFilmMode('continue'),
              ),
              const SizedBox(width: 6),
              _viewChip(
                '观看历史',
                Icons.history_rounded,
                _subpages.showHistory,
                () {
                  setState(() {
                    _subpages.showHistory = true;
                    _subpages.showSeries = false;
                    _selection.clear();
                    if (_catalog.searchController.text.isEmpty) {
                      _catalog.showSearch = false;
                    }
                  });
                  unawaited(_loadHistory());
                },
              ),
              const SizedBox(width: 6),
              _viewChip(
                '待匹配',
                Icons.auto_fix_high_outlined,
                _subpages.isRootView && _catalog.mode == 'unmatched',
                () {
                  _switchToFilmMode('unmatched');
                  if (widget.isAdmin) unawaited(_refreshScrape());
                },
              ),
              if (_subpages.showHistory || _catalog.mode == 'continue') ...[
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => _switchToFilmMode('all'),
                  child: const Text('返回首页'),
                ),
              ],
            ],
          ),
        ),
        IsleAnimatedExpand(
          expanded: _catalog.showSearch && !_subpages.showHistory,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: IsleSearchBar(
              controller: _catalog.searchController,
              autofocus: true,
              onChanged: _searchChanged,
              maxLength: 120,
              hintText: '搜索影片或剧集',
              showClear: true,
              clearTooltip: '关闭搜索',
              onClear: () {
                _catalog.searchController.clear();
                _searchChanged('');
                setState(() => _catalog.showSearch = false);
              },
            ),
          ),
        ),
      ],
    ),
  );

  void _switchToFilmMode(String targetMode) {
    setState(_subpages.exitSecondaryViews);
    _changeMode(targetMode);
  }

  double get _pageInset =>
      IsleLayout.pageInset(MediaQuery.sizeOf(context).width);

  void _handleSystemBack(bool didPop, Object? result) {
    if (didPop) return;
    if (_selection.selecting) {
      _endFilmSelection();
    } else if (_catalog.showSearch) {
      _catalog.searchController.clear();
      _searchChanged('');
      setState(() => _catalog.showSearch = false);
    } else if (!_isRootCinemaView) {
      _switchToFilmMode('all');
    }
  }

  @override
  Widget build(BuildContext context) {
    final showHomeRails =
        _isRootCinemaView &&
        _catalog.query.trim().isEmpty &&
        !_selection.selecting;
    final showFilmListSection = _subpages.isRootView;

    return PopScope(
      canPop:
          !_selection.selecting && !_catalog.showSearch && _isRootCinemaView,
      onPopInvokedWithResult: _handleSystemBack,
      child: RefreshIndicator(
        onRefresh: _refreshView,
        child: CustomScrollView(
          key: PageStorageKey<String>(
            'cinema:${widget.api.selectedRoot?.identity ?? 'default'}',
          ),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildTopChromeSliver(context),
            if (showHomeRails) ...[
              SliverToBoxAdapter(child: _featuredFilmBanner()),
              SliverToBoxAdapter(child: _continueWatchingRail()),
              SliverToBoxAdapter(child: _topRatedRail()),
              SliverToBoxAdapter(child: _recentlyAddedRail()),
            ],
            if (showFilmListSection &&
                _catalog.mode == 'unmatched' &&
                widget.isAdmin)
              SliverToBoxAdapter(child: _adminScrapeBar()),
            if (showFilmListSection &&
                _catalog.films.isNotEmpty &&
                !_selection.selecting)
              _buildFilmSectionHeadingSliver(context),
            if (showFilmListSection) _filmGrid(),
            _buildPaginationFooterSliver(
              context,
              showFilmFooter: showFilmListSection && _catalog.films.isNotEmpty,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopChromeSliver(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    return SliverToBoxAdapter(
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
              hideSubtitleOnCompact: _isRootCinemaView,
              subtitle: _headerSubtitle,
              trailing: _buildHeaderTrailingActions(context),
            ),
          ),
          _cinemaNavigation(),
          _buildSelectionToolbar(),
          _buildStatusBanners(),
          if (_subpages.showSeries)
            ..._seriesView()
          else if (_subpages.showHistory)
            ..._historyView(),
        ],
      ),
    );
  }

  String get _headerSubtitle {
    if (_subpages.showSeries) return '按剧名与季数整理';
    if (_subpages.showHistory) return '最近观看的影片';
    switch (_catalog.mode) {
      case 'movie':
        return '电影收藏';
      case 'unmatched':
        return '尚未确认海报与简介的影片';
      case 'continue':
        return '从上次看到的地方接着看';
      default:
        return '找到想看的内容，随时继续播放';
    }
  }

  Widget _buildHeaderTrailingActions(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_subpages.isRootView)
          IconButton(
            key: const Key('cinema-select-toggle'),
            visualDensity: VisualDensity.compact,
            tooltip: _selection.selecting ? '结束多选' : '多选影片',
            onPressed: _selection.batchBusy
                ? null
                : () {
                    if (_selection.selecting) {
                      _endFilmSelection();
                    } else {
                      setState(() => _selection.selecting = true);
                    }
                  },
            icon: Icon(
              _selection.selecting
                  ? Icons.close_rounded
                  : Icons.checklist_rounded,
            ),
            color: _selection.selecting
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '搜索影片',
          onPressed: () {
            if (_catalog.showSearch) {
              _catalog.searchController.clear();
              _searchChanged('');
              setState(() => _catalog.showSearch = false);
            } else {
              setState(() {
                _catalog.showSearch = true;
                _subpages.showHistory = false;
              });
            }
          },
          icon: const Icon(Icons.search_rounded),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '上传视频',
          onPressed: _upload,
          icon: const Icon(Icons.add_rounded),
        ),
        _buildOverflowMenuButton(),
      ],
    );
  }

  Widget _buildOverflowMenuButton() {
    return PopupMenuButton<String>(
      tooltip: '更多影院操作',
      onSelected: _cinemaAction,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 218, maxWidth: 270),
      shape: IsleShapes.menu(),
      itemBuilder: (_) => [
        isleActionMenuItem(
          value: 'select',
          icon: _selection.selecting
              ? Icons.close_rounded
              : Icons.checklist_rounded,
          label: _selection.selecting ? '结束多选' : '多选影片',
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
            enabled: !_indexing.scanning,
            icon: Icons.sync_rounded,
            label: _indexing.scanning ? '扫描中' : '扫描影视库',
          ),
      ],
    );
  }

  Widget _buildSelectionToolbar() {
    final allPageSelected = _catalog.films
        .take(50)
        .every((film) => _selection.selectedFilmIds.contains(film.id));
    final canTrashSelected =
        _selectedFilms.isNotEmpty &&
        _selectedFilms.every((film) => widget.isAdmin || film.canWrite);

    return IsleAnimatedExpand(
      expanded: _selection.selecting && _subpages.isRootView,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 14),
        child: MediaSelectionActionBar(
          label: '已选 ${_selection.selectedFilmIds.length} 项 · 最多 50 项',
          actions: [
            OutlinedButton.icon(
              onPressed: _selection.batchBusy || _catalog.films.isEmpty
                  ? null
                  : _selectVisibleFilms,
              icon: const Icon(Icons.select_all_rounded, size: 17),
              label: Text(allPageSelected ? '取消全选' : '全选当前页'),
            ),
            OutlinedButton.icon(
              onPressed:
                  _selection.batchBusy || _selection.selectedFilmIds.isEmpty
                  ? null
                  : _batchSaveFilms,
              icon: const Icon(Icons.download_outlined, size: 17),
              label: const Text('保存原文件'),
            ),
            OutlinedButton.icon(
              onPressed:
                  _selection.batchBusy || _selection.selectedFilmIds.isEmpty
                  ? null
                  : _batchShareFilms,
              icon: const Icon(Icons.ios_share_outlined, size: 17),
              label: const Text('分享'),
            ),
            if (canTrashSelected)
              FilledButton.tonalIcon(
                onPressed:
                    _selection.batchBusy || _selection.selectedFilmIds.isEmpty
                    ? null
                    : _batchTrashFilms,
                icon: const Icon(Icons.delete_outline_rounded, size: 17),
                label: const Text('移入回收站'),
              ),
            TextButton(
              onPressed: _selection.batchBusy ? null : _endFilmSelection,
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanners() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_indexing.scanning)
          MediaStatusBanner(
            message: _indexing.scanStatus.operation == 'scrape'
                ? '正在自动识别与刮削影视资料 · 已匹配 ${_indexing.scanStatus.found} / ${_indexing.scanStatus.visited} 部'
                : '正在整理影视库 · 找到 ${_indexing.scanStatus.found} 部影片',
            icon: Icons.sync,
          ),
        if (_indexing.scanError != null)
          MediaStatusBanner(
            message: '上次扫描未完成：${_indexing.scanError}',
            isError: true,
          ),
        if (_catalog.actionMessage != null)
          MediaStatusBanner(
            message: _catalog.actionMessage!,
            isError: _catalog.actionIsError,
          ),
        if (_catalog.loadError != null && _catalog.films.isNotEmpty)
          MediaStatusBanner(
            message: _catalog.loadError!,
            isError: true,
            icon: Icons.error_outline,
            trailing: TextButton(
              onPressed: _catalog.loadingMore
                  ? null
                  : () => _loadFilms(reset: false),
              child: const Text('重试'),
            ),
          ),
      ],
    );
  }

  Widget _buildFilmSectionHeadingSliver(BuildContext context) {
    final title = _catalog.mode == 'movie'
        ? '电影'
        : _catalog.mode == 'unmatched'
        ? '待匹配资料'
        : _catalog.mode == 'continue'
        ? '待续播'
        : _catalog.query.isNotEmpty
        ? '搜索结果'
        : '全部影片';
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(_pageInset, 8, _pageInset, 6),
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildPaginationFooterSliver(
    BuildContext context, {
    required bool showFilmFooter,
  }) {
    return SliverToBoxAdapter(
      child: Column(
        children: [
          if (showFilmFooter)
            Padding(
              padding: EdgeInsets.fromLTRB(_pageInset, 22, _pageInset, 26),
              child: Center(
                child: _catalog.nextCursor > 0
                    ? OutlinedButton.icon(
                        onPressed: _catalog.loadingMore
                            ? null
                            : () => _loadFilms(reset: false),
                        icon: _catalog.loadingMore
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.expand_more),
                        label: Text(_catalog.loadingMore ? '正在加载' : '加载更多影片'),
                      )
                    : Text(
                        '已显示全部 ${_catalog.films.length} 部影片',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              ),
            ),
          const SizedBox(height: 76),
        ],
      ),
    );
  }
}
