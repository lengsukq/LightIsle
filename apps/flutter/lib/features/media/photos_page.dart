import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../../core/isle_action_menu.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/media_image_memory_cache.dart';
import 'media_models.dart';
import 'media_page_result.dart';
import 'media_scan_poller.dart';
import 'media_batch_operations.dart';
import 'photo_album_repository.dart';
import 'photo_gallery_viewer.dart';
import 'photo_detail_dialog.dart';
export 'photo_detail_dialog.dart' show PhotoDetailDialog;
import 'photo_map_page.dart';
import 'media_ui.dart';
import 'offline_photos_page.dart';
import '../files/android_photo_backup_page.dart';
import '../files/files_page.dart';
import '../files/upload_task_center.dart';

part 'photos_page_batch_actions.dart';
part 'photos_page_album_management.dart';
part 'photos_page_library.dart';
part 'photos_page_navigation.dart';

class PhotosPage extends StatefulWidget {
  const PhotosPage({
    required this.api,
    required this.isAdmin,
    this.accountName = '',
    this.offlineAccountId = '',
    this.backupDirectory = 'PhonePhotos',
    this.canBackup = false,
    this.taskCenter,
    this.uploadDirectory = '图库',
    super.key,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final String offlineAccountId;
  final String backupDirectory;
  final bool canBackup;
  final UploadTaskCenter? taskCenter;
  final String uploadDirectory;

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> with WidgetsBindingObserver {
  void _updateState(VoidCallback fn) => setState(fn);

  static const int _pageSize = 48;
  PhotoAlbumRepository get _albumRepository => PhotoAlbumRepository(widget.api);
  final ScrollController _timelineScroll = ScrollController();
  // One bounded cache per mounted photo tab, including repeated visits to
  // the full-screen viewer. The shell disposes this tab on root changes.
  final MediaImageMemoryCache _photoCache = MediaImageMemoryCache();

  final List<PhotoAsset> _assets = [];
  List<MediaAlbum> _albums = const [];
  List<MediaAlbum> _privateAlbums = const [];
  int _activeAlbum = 0;
  int _activePrivateAlbum = 0;
  int _nextCursor = 0;
  bool _favoritesOnly = false;
  bool _personalFavoritesOnly = false;
  bool _onThisDay = false;
  bool _showSearch = false;
  bool _selecting = false;
  bool _batchBusy = false;
  final Set<int> _selectedAssets = <int>{};
  String _query = '', _mediaType = '';
  final _searchController = TextEditingController();
  Timer? _searchTimer;
  bool _loading = true;
  bool _loadingMore = false;
  bool _scanning = false;
  bool _albumBusy = false;
  bool _privateAlbumsRefreshing = false;
  Object? _privateAlbumsFailure;
  String? _loadError;
  String? _actionMessage;
  bool _actionIsError = false;
  String? _scanError;
  MediaScanStatus _scanStatus = const MediaScanStatus();
  int _listGeneration = 0;
  int _albumsGeneration = 0;
  int _privateAlbumsGeneration = 0;
  int _statusGeneration = 0;
  bool _tabEnabled = true;
  bool _appForeground = true;
  late final MediaScanPoller _scanPoller = MediaScanPoller(
    onPoll: () => unawaited(_refreshStatus()),
  );

  MediaAlbum? get _currentAlbum {
    for (final album in _albums) {
      if (album.id == _activeAlbum) return album;
    }
    return null;
  }

  MediaAlbum? get _currentPrivateAlbum {
    for (final album in _privateAlbums) {
      if (album.id == _activePrivateAlbum) return album;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadAssets(reset: true);
    _refreshAlbums();
    _refreshPrivateAlbums();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _photoCache.dispose();
    _listGeneration++;
    _albumsGeneration++;
    _privateAlbumsGeneration++;
    _statusGeneration++;
    _scanPoller.dispose();
    _timelineScroll.dispose();
    _searchTimer?.cancel();
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
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

  /// Page-level inset aligns the content while the grid stays full-bleed.
  double get _pageInset =>
      IsleLayout.pageInset(MediaQuery.sizeOf(context).width);

  @override
  Widget build(BuildContext context) {
    // Near-endless scroll: paging fires automatically as the viewport
    // approaches the sentinel; the manual button stays as the fallback.
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) > 0 &&
            notification.metrics.axis == Axis.vertical &&
            notification.depth == 0 &&
            notification.metrics.extentAfter < 650 &&
            _nextCursor > 0 &&
            !_loading &&
            !_loadingMore &&
            _loadError == null) {
          _loadAssets(reset: false);
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            _loadAssets(reset: true),
            _refreshAlbums(),
            _refreshPrivateAlbums(),
          ]);
        },
        child: CustomScrollView(
          key: PageStorageKey<String>(
            'photos:${widget.api.selectedRoot?.identity ?? 'default'}',
          ),
          physics: const AlwaysScrollableScrollPhysics(),
          controller: _timelineScroll,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(_pageInset, 16, _pageInset, 0),
                    child: IslePageHeader(
                      title: '图库',
                      subtitle:
                          _currentPrivateAlbum?.name ??
                          _currentAlbum?.name ??
                          (_personalFavoritesOnly
                              ? '我的收藏'
                              : _favoritesOnly
                              ? '共享收藏'
                              : _onThisDay
                              ? '那年今天'
                              : '按时间整理的照片和视频'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: _selecting ? '退出选择' : '选择照片',
                            onPressed: _batchBusy
                                ? null
                                : () => setState(() {
                                    _selecting = !_selecting;
                                    _selectedAssets.clear();
                                  }),
                            icon: Icon(
                              _selecting
                                  ? Icons.close_rounded
                                  : Icons.checklist_rounded,
                            ),
                          ),
                          IconButton(
                            tooltip: '搜索照片',
                            onPressed: () =>
                                setState(() => _showSearch = !_showSearch),
                            icon: const Icon(Icons.search_rounded),
                          ),
                          IconButton(
                            tooltip: '上传照片与视频',
                            onPressed: _upload,
                            icon: const Icon(Icons.add_rounded),
                          ),
                          PopupMenuButton<String>(
                            tooltip: '更多照片操作',
                            onSelected: _photoAction,
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
                                label: _selecting ? '结束多选' : '多选照片',
                              ),
                              const PopupMenuDivider(),
                              isleActionMenuItem(
                                value: 'offline',
                                icon: Icons.offline_pin_outlined,
                                label: '本机离线照片库',
                              ),
                              isleActionMenuItem(
                                value: 'map',
                                icon: Icons.map_outlined,
                                label: '地图回溯',
                              ),
                              if (_fullTimelineSelected &&
                                  _query.isEmpty &&
                                  _mediaType.isEmpty)
                                isleActionMenuItem(
                                  value: 'month',
                                  icon: Icons.calendar_month_outlined,
                                  label: '年月跳转',
                                ),
                              isleActionMenuItem(
                                value: 'today',
                                icon: Icons.history_rounded,
                                label: '那年今天',
                              ),
                              isleActionMenuItem(
                                value: 'sharedFavorites',
                                icon: Icons.star_border_rounded,
                                label: '共享收藏',
                              ),
                              isleActionMenuItem(
                                value: 'files',
                                icon: Icons.folder_open_outlined,
                                label: '管理照片文件',
                              ),
                              const PopupMenuDivider(),
                              isleActionMenuItem(
                                value: 'all',
                                icon: Icons.perm_media_outlined,
                                label: '照片与视频',
                                checked: _mediaType.isEmpty,
                              ),
                              isleActionMenuItem(
                                value: 'photo',
                                icon: Icons.photo_outlined,
                                label: '仅照片',
                                checked: _mediaType == 'photo',
                              ),
                              isleActionMenuItem(
                                value: 'video',
                                icon: Icons.videocam_outlined,
                                label: '仅视频',
                                checked: _mediaType == 'video',
                              ),
                              if (_currentPrivateAlbum != null) ...[
                                isleActionMenuItem(
                                  value: 'renamePrivate',
                                  enabled: !_albumBusy,
                                  icon: Icons.drive_file_rename_outline,
                                  label: '重命名私人相册',
                                ),
                                isleActionMenuItem(
                                  value: 'deletePrivate',
                                  enabled: !_albumBusy,
                                  icon: Icons.delete_outline_rounded,
                                  label: '删除私人相册',
                                ),
                              ],
                              if (widget.isAdmin && _currentAlbum != null) ...[
                                isleActionMenuItem(
                                  value: 'renameShared',
                                  enabled: !_albumBusy,
                                  icon: Icons.drive_file_rename_outline,
                                  label: '重命名相册',
                                ),
                                isleActionMenuItem(
                                  value: 'deleteShared',
                                  enabled: !_albumBusy,
                                  icon: Icons.delete_outline_rounded,
                                  label: '删除相册',
                                ),
                              ],
                              if (widget.canBackup &&
                                  (defaultTargetPlatform ==
                                          TargetPlatform.android ||
                                      defaultTargetPlatform ==
                                          TargetPlatform.iOS))
                                isleActionMenuItem(
                                  value: 'backup',
                                  icon: Icons.cloud_upload_outlined,
                                  label: '手机照片备份',
                                ),
                              const PopupMenuDivider(),
                              isleActionMenuItem(
                                value: 'refresh',
                                icon: Icons.refresh_rounded,
                                label: '刷新图库',
                              ),
                              if (widget.isAdmin)
                                isleActionMenuItem(
                                  value: 'scan',
                                  enabled: !_scanning,
                                  icon: Icons.sync_rounded,
                                  label: _scanning ? '扫描中' : '扫描媒体',
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  _photoNavigation(),
                  if (_selecting)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        _pageInset,
                        0,
                        _pageInset,
                        14,
                      ),
                      child: MediaSelectionActionBar(
                        label: '已选 ${_selectedAssets.length} 项',
                        actions: [
                          OutlinedButton.icon(
                            onPressed: _batchBusy || _assets.isEmpty
                                ? null
                                : _selectVisiblePhotos,
                            icon: const Icon(
                              Icons.select_all_rounded,
                              size: 17,
                            ),
                            label: Text(
                              _assets
                                      .take(50)
                                      .every(
                                        (asset) =>
                                            _selectedAssets.contains(asset.id),
                                      )
                                  ? '取消全选'
                                  : '全选当前页',
                            ),
                          ),
                          TextButton(
                            onPressed: _batchBusy
                                ? null
                                : () => setState(() {
                                    _selecting = false;
                                    _selectedAssets.clear();
                                  }),
                            child: const Text('完成'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchFavorite,
                            icon: const Icon(
                              Icons.star_border_rounded,
                              size: 17,
                            ),
                            label: const Text('收藏'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchAddToPrivateAlbum,
                            icon: const Icon(
                              Icons.add_to_photos_outlined,
                              size: 17,
                            ),
                            label: const Text('加入相册'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchExport,
                            icon: const Icon(Icons.download_outlined, size: 17),
                            label: const Text('保存原文件'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchShare,
                            icon: const Icon(
                              Icons.ios_share_outlined,
                              size: 17,
                            ),
                            label: const Text('分享'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed:
                                _batchBusy ||
                                    _selectedAssets.isEmpty ||
                                    _assets
                                        .where(
                                          (a) => _selectedAssets.contains(a.id),
                                        )
                                        .any(
                                          (a) => !widget.isAdmin && !a.canWrite,
                                        )
                                ? null
                                : _batchTrashAssets,
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 17,
                            ),
                            label: const Text('移入回收站'),
                          ),
                        ],
                      ),
                    ),
                  if (_scanning)
                    MediaStatusBanner(
                      message: '正在整理媒体 · 已找到 ${_scanStatus.found} 项',
                      icon: Icons.sync,
                    ),
                  if (_scanError != null)
                    MediaStatusBanner(
                      message: '上次扫描未完成：$_scanError',
                      isError: true,
                    ),
                  if (_privateAlbumsFailure != null)
                    MediaStatusBanner(
                      key: const ValueKey('privateAlbumsLoadFailure'),
                      message:
                          '私人相册列表未能读取：${mediaErrorLabel(_privateAlbumsFailure!)}\n'
                          '其他图库内容可以继续浏览；请排除故障后重试。',
                      diagnostic: errorDiagnosticLabel(_privateAlbumsFailure!),
                      isError: true,
                      icon: Icons.error_outline,
                      trailing: TextButton(
                        onPressed: _privateAlbumsRefreshing
                            ? null
                            : () => unawaited(_refreshPrivateAlbums()),
                        child: Text(_privateAlbumsRefreshing ? '加载中' : '重试'),
                      ),
                    ),
                  if (_actionMessage != null)
                    MediaStatusBanner(
                      message: _actionMessage!,
                      isError: _actionIsError,
                    ),
                  if (_loadError != null && _assets.isNotEmpty)
                    MediaStatusBanner(
                      message: _loadError!,
                      isError: true,
                      icon: Icons.error_outline,
                      trailing: TextButton(
                        onPressed: _loadingMore
                            ? null
                            : () => _loadAssets(reset: false),
                        child: const Text('重试'),
                      ),
                    ),
                ],
              ),
            ),
            _buildGrid(),
            SliverToBoxAdapter(
              child: Column(
                children: [
                  if (_assets.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        _pageInset,
                        20,
                        _pageInset,
                        26,
                      ),
                      child: Center(
                        child: _nextCursor > 0
                            ? OutlinedButton.icon(
                                onPressed: _loadingMore
                                    ? null
                                    : () => _loadAssets(reset: false),
                                icon: _loadingMore
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.expand_more),
                                label: Text(_loadingMore ? '正在加载' : '加载更多媒体'),
                              )
                            : Text(
                                '已显示全部 ${_assets.length} 项',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AlbumNameDialog extends StatefulWidget {
  const AlbumNameDialog({
    this.initialName = '',
    this.privateAlbum = false,
    super.key,
  });

  final String initialName;
  final bool privateAlbum;

  @override
  State<AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<AlbumNameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final length = name.runes.length;
    if (length == 0) {
      setState(() => _error = '请输入相册名称。');
      return;
    }
    if (length > 60 || RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(name)) {
      setState(() => _error = '相册名称需为 1–60 个字符，且不能包含控制字符。');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initialName.isEmpty
          ? widget.privateAlbum
                ? '新建私人相册'
                : '新建相册'
          : widget.privateAlbum
          ? '修改私人相册名称'
          : '修改相册名称',
    ),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 120,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: '相册名称',
        errorText: _error,
        helperText: '最多 60 个字符',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(widget.initialName.isEmpty ? '创建' : '保存'),
      ),
    ],
  );
}

class _AssetMonthSection {
  _AssetMonthSection(this.key, this.title) : items = <PhotoAsset>[];

  final String key;
  final String title;
  final List<PhotoAsset> items;
}

String _assetMonthKey(int takenAt) {
  if (takenAt <= 0) return 'unknown';
  final value = DateTime.fromMillisecondsSinceEpoch(takenAt * 1000).toLocal();
  return '${value.year}-${value.month}';
}
