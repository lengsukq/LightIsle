import 'package:flutter/material.dart';

import '../../core/isle_cache_manager.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';

Color cacheCategoryColor(IsleCacheCategory category, IslePalette palette) =>
    switch (category) {
      IsleCacheCategory.thumbnails => palette['brandRose'],
      IsleCacheCategory.posters => palette['brandTerracotta'],
      IsleCacheCategory.mapTiles => palette['brandSage'],
      IsleCacheCategory.metadata => palette['brandAmber'],
    };

IconData cacheCategoryIcon(IsleCacheCategory category) => switch (category) {
  IsleCacheCategory.thumbnails => Icons.photo_library_rounded,
  IsleCacheCategory.posters => Icons.movie_creation_rounded,
  IsleCacheCategory.mapTiles => Icons.map_rounded,
  IsleCacheCategory.metadata => Icons.bolt_rounded,
};

class CacheOverviewCard extends StatelessWidget {
  const CacheOverviewCard({
    super.key,
    required this.report,
    required this.offlineFileBytes,
    required this.palette,
  });

  final IsleCacheReport report;
  final int offlineFileBytes;
  final IslePalette palette;

  @override
  Widget build(BuildContext context) {
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
                  color: cacheCategoryColor(cat, palette),
                  detail: formatBytes(
                    report.categories[cat]?.effectiveBytes ?? 0,
                  ),
                ),
              if (report.totalOfflineBytes + offlineFileBytes > 0)
                IsleChartSegment(
                  label: '离线原件',
                  value: (report.totalOfflineBytes + offlineFileBytes)
                      .toDouble(),
                  color: palette['brandViolet'],
                  detail: formatBytes(
                    report.totalOfflineBytes + offlineFileBytes,
                  ),
                ),
            ],
            semanticsLabel:
                '本机缓存分类占用，总计 ${formatBytes(totalAll + offlineFileBytes)}',
          ),
        ],
      ),
    );
  }
}

class LocalCacheCategoriesCard extends StatelessWidget {
  const LocalCacheCategoriesCard({
    super.key,
    required this.report,
    required this.palette,
    required this.selected,
    required this.clearingLocal,
    required this.onToggleSelectAll,
    required this.onToggleCategory,
    required this.onClearCategories,
  });

  final IsleCacheReport report;
  final IslePalette palette;
  final Set<IsleCacheCategory> selected;
  final bool clearingLocal;
  final VoidCallback onToggleSelectAll;
  final void Function(IsleCacheCategory category, bool checked)
  onToggleCategory;
  final ValueChanged<Set<IsleCacheCategory>> onClearCategories;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allSelected = selected.length == IsleCacheCategory.values.length;
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
                onPressed: onToggleSelectAll,
                child: Text(allSelected ? '取消全选' : '全选'),
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
                final checked = selected.contains(cat);
                final color = cacheCategoryColor(cat, palette);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        key: ValueKey('cache-check-${cat.id}'),
                        visualDensity: VisualDensity.compact,
                        value: checked,
                        onChanged: (val) => onToggleCategory(cat, val == true),
                      ),
                      IsleSquircleBadge(
                        icon: cacheCategoryIcon(cat),
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
                        onPressed: clearingLocal
                            ? null
                            : () => onClearCategories({cat}),
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
                label: clearingLocal
                    ? '正在清理…'
                    : '清理所选缓存 (${selected.length})',
                icon: Icons.cleaning_services_rounded,
                variant: IslePillVariant.primary,
                compact: true,
                onPressed: clearingLocal || selected.isEmpty
                    ? null
                    : () => onClearCategories(selected.toSet()),
              ),
              IslePillButton(
                key: const ValueKey('clearAllLocalCachesBtn'),
                label: '一键清空全部临时缓存',
                icon: Icons.delete_sweep_rounded,
                compact: true,
                onPressed: clearingLocal
                    ? null
                    : () => onClearCategories(IsleCacheCategory.values.toSet()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class OfflineMediaVaultCard extends StatelessWidget {
  const OfflineMediaVaultCard({
    super.key,
    required this.report,
    required this.offlineFileBytes,
    required this.offlineFileCount,
    required this.palette,
    required this.canManage,
    required this.onManageVault,
    required this.onManagePhotos,
    required this.onManageVideos,
  });

  final IsleCacheReport report;
  final int offlineFileBytes;
  final int offlineFileCount;
  final IslePalette palette;
  final bool canManage;
  final VoidCallback onManageVault;
  final VoidCallback onManagePhotos;
  final VoidCallback onManageVideos;

  @override
  Widget build(BuildContext context) {
    final rose = palette['brandRose'];
    final terracotta = palette['brandTerracotta'];
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本机离线文件箱与媒体库',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          ListTile(
            key: const ValueKey('cacheOfflineFileVaultTile'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: IsleSquircleBadge(
              icon: Icons.offline_pin_rounded,
              color: palette['brandBlue'],
              size: 32,
              iconSize: 16.5,
            ),
            title: const Text('离线文件箱（独立隔离，不被清缓存误删）'),
            subtitle: Text(
              '${formatBytes(offlineFileBytes)} · $offlineFileCount 项文档',
            ),
            trailing: IslePillButton(
              key: const ValueKey('manageOfflineVaultBtn'),
              label: '管理',
              compact: true,
              onPressed: canManage ? onManageVault : null,
            ),
          ),
          const Divider(height: 4),
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
              onPressed: canManage ? onManagePhotos : null,
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
              onPressed: canManage ? onManageVideos : null,
            ),
          ),
        ],
      ),
    );
  }
}

class ServerDerivedCacheCard extends StatelessWidget {
  const ServerDerivedCacheCard({
    super.key,
    required this.status,
    required this.palette,
    required this.isAdmin,
    required this.clearingServer,
    required this.onClearServer,
  });

  final Map<String, dynamic> status;
  final IslePalette palette;
  final bool isAdmin;
  final bool clearingServer;
  final void Function(List<String> categories, String label) onClearServer;

  @override
  Widget build(BuildContext context) {
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
            trailing: isAdmin
                ? IslePillButton(
                    key: const ValueKey('clearServerThumbnailsBtn'),
                    label: '清理',
                    compact: true,
                    onPressed: clearingServer
                        ? null
                        : () => onClearServer(const ['thumbnails'], '缩略图缓存'),
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
            trailing: isAdmin
                ? IslePillButton(
                    key: const ValueKey('clearServerMapTilesBtn'),
                    label: '清理',
                    compact: true,
                    onPressed: clearingServer
                        ? null
                        : () => onClearServer(const ['map_tiles'], '地图瓦片缓存'),
                  )
                : null,
          ),
          if (isAdmin) ...[
            const SizedBox(height: 8),
            IslePillButton(
              key: const ValueKey('clearAllServerCachesBtn'),
              label: clearingServer ? '正在清理服务端…' : '一键清理全部服务端缓存',
              icon: Icons.dns_rounded,
              compact: true,
              onPressed: clearingServer
                  ? null
                  : () => onClearServer(
                      const ['thumbnails', 'map_tiles'],
                      '全部派生缓存',
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
