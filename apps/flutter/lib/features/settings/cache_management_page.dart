import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_cache_manager.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/offline_file_store.dart';
import '../files/offline_vault_page.dart';
import '../media/offline_photo_store.dart';
import '../media/offline_photos_page.dart';
import '../media/offline_video_store.dart';
import '../media/offline_videos_page.dart';
import 'cache_management_cards.dart';

class CacheManagementPage extends StatefulWidget {
  const CacheManagementPage({
    required this.api,
    this.isAdmin = false,
    this.accountId = '',
    super.key,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountId;

  @override
  State<CacheManagementPage> createState() => _CacheManagementPageState();
}

class _CacheManagementPageState extends State<CacheManagementPage> {
  final Set<IsleCacheCategory> _selected = IsleCacheCategory.values.toSet();
  IsleCacheReport? _report;
  int _offlineFileBytes = 0;
  int _offlineFileCount = 0;
  Map<String, dynamic>? _serverStatus;
  bool _loading = true;
  bool _clearingLocal = false;
  bool _clearingServer = false;
  String? _notice;
  bool _noticeError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
    });
    var offlineFileBytes = 0;
    var offlineFileCount = 0;
    var offlinePhotoBytes = 0;
    var offlinePhotoCount = 0;
    var offlineVideoBytes = 0;
    var offlineVideoCount = 0;
    if (widget.accountId.isNotEmpty) {
      try {
        final stats = await OfflineFileStore(
          api: widget.api,
          accountIdentity: widget.accountId,
        ).stats();
        offlineFileCount = stats.count;
        offlineFileBytes = stats.totalBytes;
      } catch (error) {
        debugPrint(
          'CacheManagementPage: offline file vault stats unavailable: $error',
        );
      }
      try {
        final photos = await OfflinePhotoStore(
          api: widget.api,
          accountId: widget.accountId,
        ).list();
        offlinePhotoCount = photos.length;
        for (final item in photos) {
          offlinePhotoBytes += item.size;
        }
      } catch (error) {
        debugPrint(
          'CacheManagementPage: offline photo stats unavailable: $error',
        );
      }
      try {
        final videos = await OfflineVideoStore(
          api: widget.api,
          accountName: widget.accountId,
        ).list();
        offlineVideoCount = videos.length;
        for (final item in videos) {
          offlineVideoBytes += item.size;
        }
      } catch (error) {
        debugPrint(
          'CacheManagementPage: offline video stats unavailable: $error',
        );
      }
    }

    final report = await IsleCacheManager.instance.inspect(
      offlinePhotoBytes: offlinePhotoBytes,
      offlinePhotoCount: offlinePhotoCount,
      offlineVideoBytes: offlineVideoBytes,
      offlineVideoCount: offlineVideoCount,
    );

    Map<String, dynamic>? serverStatus;
    if (widget.isAdmin) {
      try {
        serverStatus = await widget.api.get('/api/v2/cache/status');
      } catch (error) {
        debugPrint(
          'CacheManagementPage: server cache status unavailable: $error',
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _report = report;
      _offlineFileBytes = offlineFileBytes;
      _offlineFileCount = offlineFileCount;
      _serverStatus = serverStatus;
      _loading = false;
    });
  }

  Future<void> _clearLocalCategories(Set<IsleCacheCategory> categories) async {
    if (categories.isEmpty || _clearingLocal) return;
    setState(() {
      _clearingLocal = true;
      _notice = null;
      _noticeError = false;
    });
    try {
      await IsleCacheManager.instance.clearCategories(categories);
      await _refresh();
      if (!mounted) return;
      final names = categories.map((c) => c.label).join('、');
      setState(() {
        _notice = '已清理本机缓存：$names。';
        _noticeError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = '清理本机缓存失败：${userFacingError(error)}';
        _noticeError = true;
      });
    } finally {
      if (mounted) {
        setState(() => _clearingLocal = false);
      }
    }
  }

  Future<void> _clearServerCache(List<String> categories, String label) async {
    if (_clearingServer) return;
    setState(() {
      _clearingServer = true;
      _notice = null;
      _noticeError = false;
    });
    try {
      final res = await widget.api.send(
        'POST',
        '/api/v2/admin/cache/clear',
        body: {'categories': categories},
      );
      await _refresh();
      if (!mounted) return;
      final freed = (res['freedBytes'] as num?)?.toInt() ?? 0;
      final removed = (res['removedEntries'] as num?)?.toInt() ?? 0;
      setState(() {
        _notice = '已清理服务端$label（释放 ${formatBytes(freed)}，共 $removed 项）。';
        _noticeError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = '清理服务端缓存失败：${userFacingError(error)}';
        _noticeError = true;
      });
    } finally {
      if (mounted) {
        setState(() => _clearingServer = false);
      }
    }
  }

  Future<void> _pushAndRefresh(Widget page) async {
    await Navigator.of(context).push<void>(
      buildIslePageRoute<void>(builder: (_) => page),
    );
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final report =
        _report ??
        const IsleCacheReport(
          categories: <IsleCacheCategory, IsleCacheCategoryStats>{},
        );
    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('缓存与本地存储管理'),
        actions: [
          IconButton(
            tooltip: '刷新缓存统计',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IsleHelpButton(
            title: '缓存与离线库说明',
            accentColor: palette['brandBlue'],
            items: const [
              IsleHelpItem(
                title: '临时缓存安全清理',
                body: '清理缩略图、海报、地图瓦片与元数据仅释放临时派生文件，绝不会删除 NAS 原件，下次浏览时将按需重新加载。',
              ),
              IsleHelpItem(
                title: '离线原件独立保留',
                body: '手动保存至本机的离线照片与离线影片不受「清空全部临时缓存」影响，可在下方离线媒体库中单独管理。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Notice(_notice!, error: _noticeError),
            ),
          CacheOverviewCard(
            report: report,
            offlineFileBytes: _offlineFileBytes,
            palette: palette,
          ),
          const SizedBox(height: 12),
          IsleWorkbenchSplit(
            breakpoint: 880,
            primaryFlex: 6,
            secondaryFlex: 6,
            primary: LocalCacheCategoriesCard(
              report: report,
              palette: palette,
              selected: _selected,
              clearingLocal: _clearingLocal,
              onToggleSelectAll: () {
                setState(() {
                  if (_selected.length == IsleCacheCategory.values.length) {
                    _selected.clear();
                  } else {
                    _selected.addAll(IsleCacheCategory.values);
                  }
                });
              },
              onToggleCategory: (cat, checked) {
                setState(() {
                  if (checked) {
                    _selected.add(cat);
                  } else {
                    _selected.remove(cat);
                  }
                });
              },
              onClearCategories: (cats) =>
                  unawaited(_clearLocalCategories(cats)),
            ),
            secondary: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OfflineMediaVaultCard(
                  report: report,
                  offlineFileBytes: _offlineFileBytes,
                  offlineFileCount: _offlineFileCount,
                  palette: palette,
                  canManage: widget.accountId.isNotEmpty,
                  onManageVault: () => unawaited(
                    _pushAndRefresh(
                      OfflineVaultPage(
                        api: widget.api,
                        accountId: widget.accountId,
                      ),
                    ),
                  ),
                  onManagePhotos: () => unawaited(
                    _pushAndRefresh(
                      OfflinePhotosPage(
                        api: widget.api,
                        accountId: widget.accountId,
                      ),
                    ),
                  ),
                  onManageVideos: () => unawaited(
                    _pushAndRefresh(
                      OfflineVideosPage(
                        api: widget.api,
                        accountName: widget.accountId,
                      ),
                    ),
                  ),
                ),
                if (_serverStatus != null) ...[
                  const SizedBox(height: 12),
                  ServerDerivedCacheCard(
                    status: _serverStatus!,
                    palette: palette,
                    isAdmin: widget.isAdmin,
                    clearingServer: _clearingServer,
                    onClearServer: (cats, label) =>
                        unawaited(_clearServerCache(cats, label)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
