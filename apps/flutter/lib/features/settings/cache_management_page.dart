import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_cache_manager.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../media/offline_photo_store.dart';
import '../media/offline_photos_page.dart';
import '../media/offline_video_store.dart';
import '../media/offline_videos_page.dart';

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
    var offlinePhotoBytes = 0;
    var offlinePhotoCount = 0;
    var offlineVideoBytes = 0;
    var offlineVideoCount = 0;
    if (widget.accountId.isNotEmpty) {
      try {
        final photos = await OfflinePhotoStore(
          api: widget.api,
          accountId: widget.accountId,
        ).list();
        offlinePhotoCount = photos.length;
        for (final item in photos) {
          offlinePhotoBytes += item.size;
        }
      } catch (_) {}
      try {
        final videos = await OfflineVideoStore(
          api: widget.api,
          accountName: widget.accountId,
        ).list();
        offlineVideoCount = videos.length;
        for (final item in videos) {
          offlineVideoBytes += item.size;
        }
      } catch (_) {}
    }

    final report = await IsleCacheManager.instance.inspect(
      offlinePhotoBytes: offlinePhotoBytes,
      offlinePhotoCount: offlinePhotoCount,
      offlineVideoBytes: offlineVideoBytes,
      offlineVideoCount: offlineVideoCount,
    );

    Map<String, dynamic>? serverStatus;
    try {
      serverStatus = await widget.api.get('/api/v2/cache/status');
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _report = report;
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

  Color _categoryColor(IsleCacheCategory category) => switch (category) {
    IsleCacheCategory.thumbnails => const Color(0xFF007AFF),
    IsleCacheCategory.posters => const Color(0xFFAF52DE),
    IsleCacheCategory.mapTiles => const Color(0xFF10B981),
    IsleCacheCategory.metadata => const Color(0xFFFF9500),
  };

  IconData _categoryIcon(IsleCacheCategory category) => switch (category) {
    IsleCacheCategory.thumbnails => Icons.photo_library_rounded,
    IsleCacheCategory.posters => Icons.movie_creation_rounded,
    IsleCacheCategory.mapTiles => Icons.map_rounded,
    IsleCacheCategory.metadata => Icons.bolt_rounded,
  };

  Widget _buildOverviewCard(BuildContext context, IsleCacheReport report) {
    final scheme = Theme.of(context).colorScheme;
    final totalTemp = report.totalTemporaryBytes;
    final totalAll = report.totalAllBytes;
    return IsleSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF00C7BE).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.pie_chart_rounded,
                  color: Color(0xFF00C7BE),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '本机临时缓存占用',
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatBytes(totalTemp),
                      key: const ValueKey('localTotalTempCacheBytes'),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              IsleStatusBadge(
                label: '${report.totalTemporaryEntries} 项缓存',
                color: const Color(0xFF007AFF),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 10,
              child: totalAll <= 0
                  ? ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: const SizedBox.expand(),
                    )
                  : Row(
                      children: [
                        for (final cat in IsleCacheCategory.values)
                          if ((report.categories[cat]?.effectiveBytes ?? 0) > 0)
                            Expanded(
                              flex:
                                  ((report.categories[cat]!.effectiveBytes *
                                              1000) ~/
                                          totalAll)
                                      .clamp(15, 1000),
                              child: ColoredBox(color: _categoryColor(cat)),
                            ),
                        if (report.totalOfflineBytes > 0)
                          Expanded(
                            flex:
                                ((report.totalOfflineBytes * 1000) ~/ totalAll)
                                    .clamp(15, 1000),
                            child: const ColoredBox(color: Color(0xFF64748B)),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final cat in IsleCacheCategory.values)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _categoryColor(cat),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${cat.label} ${formatBytes(report.categories[cat]?.effectiveBytes ?? 0)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              if (report.totalOfflineBytes > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFF64748B),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '离线原件 ${formatBytes(report.totalOfflineBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLocalCategoriesCard(
    BuildContext context,
    IsleCacheReport report,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return IsleSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '本机缓存分类管理',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_selected.length == IsleCacheCategory.values.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(IsleCacheCategory.values);
                    }
                  });
                },
                child: Text(
                  _selected.length == IsleCacheCategory.values.length
                      ? '取消全选'
                      : '全选',
                ),
              ),
            ],
          ),
          Text(
            '勾选需要清理的缓存类别，或点击单项右侧按钮独立清理。清理后再次浏览时会自动重新加载。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          for (final cat in IsleCacheCategory.values) ...[
            Builder(
              builder: (context) {
                final stat = report.categories[cat];
                final bytes = stat?.effectiveBytes ?? 0;
                final count = stat?.effectiveEntries ?? 0;
                final checked = _selected.contains(cat);
                final color = _categoryColor(cat);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Checkbox(
                        key: ValueKey('cache-check-${cat.id}'),
                        value: checked,
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              _selected.add(cat);
                            } else {
                              _selected.remove(cat);
                            }
                          });
                        },
                      ),
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(_categoryIcon(cat), color: color, size: 19),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cat.label,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '${formatBytes(bytes)} · $count 项 · ${cat.subtitle}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IslePillButton(
                        key: ValueKey('clear-single-${cat.id}'),
                        label: '清理',
                        compact: true,
                        onPressed: _clearingLocal
                            ? null
                            : () => _clearLocalCategories({cat}),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (cat != IsleCacheCategory.values.last) const Divider(height: 12),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              IslePillButton(
                key: const ValueKey('clearSelectedLocalCachesBtn'),
                label: _clearingLocal
                    ? '正在清理…'
                    : '清理所选缓存 (${_selected.length})',
                icon: Icons.cleaning_services_rounded,
                variant: IslePillVariant.primary,
                onPressed: _clearingLocal || _selected.isEmpty
                    ? null
                    : () => _clearLocalCategories(_selected.toSet()),
              ),
              IslePillButton(
                key: const ValueKey('clearAllLocalCachesBtn'),
                label: '一键清空全部临时缓存',
                icon: Icons.delete_sweep_rounded,
                onPressed: _clearingLocal
                    ? null
                    : () => _clearLocalCategories(
                        IsleCacheCategory.values.toSet(),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineMediaSection(
    BuildContext context,
    IsleCacheReport report,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return IsleSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本机离线媒体库（安全隔离）',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '您主动下载到本机的离线照片与影片不会随上方临时缓存被清理，可在此独立查看和管理。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_rounded, color: Color(0xFF007AFF)),
            title: const Text('本机离线照片库'),
            subtitle: Text(
              '${formatBytes(report.offlinePhotoBytes)} · ${report.offlinePhotoCount} 张照片',
            ),
            trailing: IslePillButton(
              label: '管理',
              compact: true,
              onPressed: widget.accountId.isEmpty
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => OfflinePhotosPage(
                            api: widget.api,
                            accountId: widget.accountId,
                          ),
                        ),
                      );
                      await _refresh();
                    },
            ),
          ),
          const Divider(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.video_library_rounded,
              color: Color(0xFFAF52DE),
            ),
            title: const Text('我的离线影片库'),
            subtitle: Text(
              '${formatBytes(report.offlineVideoBytes)} · ${report.offlineVideoCount} 部影片',
            ),
            trailing: IslePillButton(
              label: '管理',
              compact: true,
              onPressed: widget.accountId.isEmpty
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => OfflineVideosPage(
                            api: widget.api,
                            accountName: widget.accountId,
                          ),
                        ),
                      );
                      await _refresh();
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerCacheCard(BuildContext context) {
    final status = _serverStatus;
    if (status == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final thumbs = status['thumbnails'] is Map
        ? Map<String, dynamic>.from(status['thumbnails'] as Map)
        : const <String, dynamic>{};
    final tiles = status['mapTiles'] is Map
        ? Map<String, dynamic>.from(status['mapTiles'] as Map)
        : const <String, dynamic>{};
    final thumbBytes = (thumbs['usedBytes'] as num?)?.toInt() ?? 0;
    final thumbMax = (thumbs['maxBytes'] as num?)?.toInt() ?? 0;
    final thumbCount = (thumbs['entryCount'] as num?)?.toInt() ?? 0;
    final tileBytes = (tiles['usedBytes'] as num?)?.toInt() ?? 0;
    final tileMax = (tiles['maxBytes'] as num?)?.toInt() ?? 0;
    final tileCount = (tiles['entryCount'] as num?)?.toInt() ?? 0;

    return IsleSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NAS 服务端派生缓存',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Mac 服务端生成的缩略图与地图瓦片缓存，供全家所有设备共享加速。清理服务端缓存绝不会删除任何原始照片或视频文件。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.burst_mode_rounded,
              color: Color(0xFF007AFF),
            ),
            title: const Text('服务端缩略图与海报磁盘缓存'),
            subtitle: Text(
              '已用 ${formatBytes(thumbBytes)}${thumbMax > 0 ? ' / 上限 ${formatBytes(thumbMax)}' : ''} · $thumbCount 项',
            ),
            trailing: widget.isAdmin
                ? IslePillButton(
                    key: const ValueKey('clearServerThumbnailsBtn'),
                    label: '清理',
                    compact: true,
                    onPressed: _clearingServer
                        ? null
                        : () =>
                              _clearServerCache(const ['thumbnails'], '缩略图缓存'),
                  )
                : null,
          ),
          const Divider(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.public_rounded, color: Color(0xFF10B981)),
            title: const Text('服务端天地图瓦片代理缓存'),
            subtitle: Text(
              '已用 ${formatBytes(tileBytes)}${tileMax > 0 ? ' / 上限 ${formatBytes(tileMax)}' : ''} · $tileCount 张瓦片',
            ),
            trailing: widget.isAdmin
                ? IslePillButton(
                    key: const ValueKey('clearServerMapTilesBtn'),
                    label: '清理',
                    compact: true,
                    onPressed: _clearingServer
                        ? null
                        : () =>
                              _clearServerCache(const ['map_tiles'], '地图瓦片缓存'),
                  )
                : null,
          ),
          if (widget.isAdmin) ...[
            const SizedBox(height: 10),
            IslePillButton(
              key: const ValueKey('clearAllServerCachesBtn'),
              label: _clearingServer ? '正在清理服务端…' : '一键清理全部服务端缓存',
              icon: Icons.dns_rounded,
              onPressed: _clearingServer
                  ? null
                  : () => _clearServerCache(const [
                      'thumbnails',
                      'map_tiles',
                    ], '全部派生缓存'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
        ],
      ),
      body: IsleListView(
        children: [
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Notice(_notice!, error: _noticeError),
            ),
          _buildOverviewCard(context, report),
          const SizedBox(height: 12),
          _buildLocalCategoriesCard(context, report),
          const SizedBox(height: 12),
          _buildOfflineMediaSection(context, report),
          if (_serverStatus != null) ...[
            const SizedBox(height: 12),
            _buildServerCacheCard(context),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
