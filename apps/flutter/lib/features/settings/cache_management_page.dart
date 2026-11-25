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

  Color _categoryColor(IsleCacheCategory category, IslePalette palette) =>
      switch (category) {
        IsleCacheCategory.thumbnails => palette['brandRose'],
        IsleCacheCategory.posters => palette['brandTerracotta'],
        IsleCacheCategory.mapTiles => palette['brandSage'],
        IsleCacheCategory.metadata => palette['brandAmber'],
      };

  IconData _categoryIcon(IsleCacheCategory category) => switch (category) {
    IsleCacheCategory.thumbnails => Icons.photo_library_rounded,
    IsleCacheCategory.posters => Icons.movie_creation_rounded,
    IsleCacheCategory.mapTiles => Icons.map_rounded,
    IsleCacheCategory.metadata => Icons.bolt_rounded,
  };

  Widget _buildOverviewCard(
    BuildContext context,
    IsleCacheReport report,
    IslePalette palette,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final mineral = palette['brandBlue'];
    final totalTemp = report.totalTemporaryBytes;
    final totalAll = report.totalAllBytes;
    return IsleSurface(
      margin: EdgeInsets.zero,
      tint: mineral,
      radius: IsleRadius.hero,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.pie_chart_rounded,
                color: mineral,
                size: 40,
                iconSize: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '本机临时缓存占用',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      formatBytes(totalTemp),
                      key: const ValueKey('localTotalTempCacheBytes'),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontWeight: FontWeight.w800,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                  ],
                ),
              ),
              IsleStatusBadge(
                label: '${report.totalTemporaryEntries} 项缓存',
                color: mineral,
              ),
            ],
          ),
          const SizedBox(height: 14),
          IsleSegmentedBar(
            height: 8,
            showPercentInLegend: true,
            legendGap: 8,
            legendSpacing: 12,
            legendRunSpacing: 5,
            segments: [
              for (final cat in IsleCacheCategory.values)
                IsleChartSegment(
                  label: cat.label,
                  value: (report.categories[cat]?.effectiveBytes ?? 0)
                      .toDouble(),
                  color: _categoryColor(cat, palette),
                  detail: formatBytes(
                    report.categories[cat]?.effectiveBytes ?? 0,
                  ),
                ),
              if (report.totalOfflineBytes > 0)
                IsleChartSegment(
                  label: '离线原件',
                  value: report.totalOfflineBytes.toDouble(),
                  color: palette['brandViolet'],
                  detail: formatBytes(report.totalOfflineBytes),
                ),
            ],
            semanticsLabel: '本机缓存分类占用，总计 ${formatBytes(totalAll)}',
          ),
        ],
      ),
    );
  }

  Widget _buildLocalCategoriesCard(
    BuildContext context,
    IsleCacheReport report,
    IslePalette palette,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '本机缓存分类管理',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
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
          const SizedBox(height: 6),
          for (final cat in IsleCacheCategory.values) ...[
            Builder(
              builder: (context) {
                final stat = report.categories[cat];
                final bytes = stat?.effectiveBytes ?? 0;
                final count = stat?.effectiveEntries ?? 0;
                final checked = _selected.contains(cat);
                final color = _categoryColor(cat, palette);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        key: ValueKey('cache-check-${cat.id}'),
                        visualDensity: VisualDensity.compact,
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
                      IsleSquircleBadge(
                        icon: _categoryIcon(cat),
                        color: color,
                        size: 32,
                        iconSize: 16.5,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cat.label,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            Text(
                              '${formatBytes(bytes)} · $count 项',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontSize: 11.5,
                                    color: scheme.onSurfaceVariant,
                                  ),
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
            if (cat != IsleCacheCategory.values.last) const Divider(height: 8),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IslePillButton(
                key: const ValueKey('clearSelectedLocalCachesBtn'),
                label: _clearingLocal
                    ? '正在清理…'
                    : '清理所选缓存 (${_selected.length})',
                icon: Icons.cleaning_services_rounded,
                variant: IslePillVariant.primary,
                compact: true,
                onPressed: _clearingLocal || _selected.isEmpty
                    ? null
                    : () => _clearLocalCategories(_selected.toSet()),
              ),
              IslePillButton(
                key: const ValueKey('clearAllLocalCachesBtn'),
                label: '一键清空全部临时缓存',
                icon: Icons.delete_sweep_rounded,
                compact: true,
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
    IslePalette palette,
  ) {
    final rose = palette['brandRose'];
    final terracotta = palette['brandTerracotta'];
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本机离线媒体库',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: IsleSquircleBadge(
              icon: Icons.photo_rounded,
              color: rose,
              size: 32,
              iconSize: 16.5,
            ),
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
                        buildIslePageRoute<void>(
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
          const Divider(height: 4),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: IsleSquircleBadge(
              icon: Icons.video_library_rounded,
              color: terracotta,
              size: 32,
              iconSize: 16.5,
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
                        buildIslePageRoute<void>(
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

  Widget _buildServerCacheCard(BuildContext context, IslePalette palette) {
    final status = _serverStatus;
    if (status == null) return const SizedBox.shrink();
    final mineral = palette['brandBlue'];
    final sage = palette['brandSage'];
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
    final totalServerMax = thumbMax + tileMax;
    final serverUsedTotal = thumbBytes + tileBytes;
    final serverBudgetLeft = (totalServerMax - serverUsedTotal).clamp(
      0,
      1 << 60,
    );

    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NAS 服务端派生缓存',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (serverUsedTotal > 0 || totalServerMax > 0) ...[
            const SizedBox(height: 10),
            IsleSegmentedBar(
              height: 7,
              showPercentInLegend: serverUsedTotal > 0,
              legendGap: 6,
              legendSpacing: 12,
              legendRunSpacing: 4,
              segments: [
                IsleChartSegment(
                  label: '缩略图与海报',
                  value: thumbBytes.toDouble(),
                  color: mineral,
                  detail: formatBytes(thumbBytes),
                ),
                IsleChartSegment(
                  label: '地图瓦片代理',
                  value: tileBytes.toDouble(),
                  color: sage,
                  detail: formatBytes(tileBytes),
                ),
                if (serverBudgetLeft > 0)
                  IsleChartSegment(
                    label: '剩余配额',
                    value: serverBudgetLeft.toDouble(),
                    color: palette['cardItemBottom'],
                    detail: formatBytes(serverBudgetLeft),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: thumbMax > 0
                ? IsleDonutGauge(
                    fraction: (thumbBytes / thumbMax).clamp(0.0, 1.0),
                    color: mineral,
                    size: 34,
                    strokeWidth: 3.5,
                    centerText:
                        '${((thumbBytes / thumbMax).clamp(0.0, 1.0) * 100).round()}%',
                    centerStyle: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(fontSize: 8.5, fontWeight: FontWeight.w700),
                  )
                : Icon(Icons.burst_mode_rounded, color: mineral, size: 20),
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
          const Divider(height: 4),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: tileMax > 0
                ? IsleDonutGauge(
                    fraction: (tileBytes / tileMax).clamp(0.0, 1.0),
                    color: sage,
                    size: 34,
                    strokeWidth: 3.5,
                    centerText:
                        '${((tileBytes / tileMax).clamp(0.0, 1.0) * 100).round()}%',
                    centerStyle: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(fontSize: 8.5, fontWeight: FontWeight.w700),
                  )
                : Icon(Icons.public_rounded, color: sage, size: 20),
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
            const SizedBox(height: 8),
            IslePillButton(
              key: const ValueKey('clearAllServerCachesBtn'),
              label: _clearingServer ? '正在清理服务端…' : '一键清理全部服务端缓存',
              icon: Icons.dns_rounded,
              compact: true,
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
          _buildOverviewCard(context, report, palette),
          const SizedBox(height: 12),
          IsleWorkbenchSplit(
            breakpoint: 880,
            primaryFlex: 6,
            secondaryFlex: 6,
            primary: _buildLocalCategoriesCard(context, report, palette),
            secondary: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildOfflineMediaSection(context, report, palette),
                if (_serverStatus != null) ...[
                  const SizedBox(height: 12),
                  _buildServerCacheCard(context, palette),
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
