import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/personal_storage_routing.dart';
import '../../core/widgets.dart';

typedef OpenStorageDirectory = void Function(
  LightIsleRoot? root,
  String directory,
);

/// Physical drive bay cards with hardware slot header, warm ochre/sage capacity
/// gauges, and recessed bound-directory chips.
class AdminVolumeBrowser extends StatelessWidget {
  const AdminVolumeBrowser({
    super.key,
    required this.volumes,
    required this.roots,
    required this.onOpen,
    this.rootsError,
  });

  final List<Map<String, dynamic>> volumes;
  final List<LightIsleRoot> roots;
  final OpenStorageDirectory? onOpen;
  final String? rootsError;

  Widget _buildVolumeCard(
    BuildContext context,
    Map<String, dynamic> volume, {
    required TextTheme text,
    required Color secondary,
    required IslePalette palette,
    required bool isDark,
  }) {
    final mount = volume['mount'];
    final matches = mount is String
        ? roots.where((root) => root.volumeMount == mount).toList()
        : <LightIsleRoot>[];
    final available = matches.where((root) => root.online).toList();
    final target = available.length == 1 ? available.single : null;
    final total = ((volume['total'] as num?) ?? 0).toDouble();
    final free = ((volume['free'] as num?) ?? 0).toDouble();
    final used = total > 0
        ? (1 - free / total).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final usedBytes = (total - free).clamp(0.0, total);
    final isSystemVolume =
        mount == '/' ||
        (mount is String &&
            (mount.contains('/Recovery') || mount.contains('/Preboot')));
    final gaugeColor = used >= 0.9
        ? palette['error']
        : used >= 0.78
        ? palette['warning']
        : (isSystemVolume ? palette['brandIndigo'] : palette['brandSage']);

    return IsleSurface(
      key: ValueKey('physicalVolume:${volume['mount'] ?? volume['name']}'),
      radius: IsleRadius.card,
      tint: isSystemVolume ? null : palette['brandSage'],
      margin: EdgeInsets.zero,
      onTap: target != null && onOpen != null
          ? () => onOpen!(target, '.')
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: isSystemVolume
                    ? Icons.laptop_mac_rounded
                    : Icons.dns_rounded,
                color: gaugeColor,
                size: 32,
                iconSize: 16.5,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      volume['name']?.toString() ?? '存储卷',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      '${formatBytes(volume['free'] as num?)} 可用 / ${formatBytes(volume['total'] as num?)}',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: text.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (total > 0) ...[
                IsleDonutGauge(
                  fraction: used,
                  color: gaugeColor,
                  size: 30,
                  strokeWidth: 3.4,
                  centerText: '${(used * 100).round()}%',
                  centerStyle: text.labelSmall?.copyWith(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  semanticsLabel:
                      '${volume['name'] ?? '存储卷'} 已使用 ${(used * 100).round()}%',
                ),
                const SizedBox(width: 6),
              ],
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6.5,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: palette['cardItemBottom'],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: IsleGlass.rimBorderColor(isDark),
                    width: 0.9,
                  ),
                ),
                child: Text(
                  (volume['filesystem']?.toString() ?? '未知').toUpperCase(),
                  style: text.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.35,
                    color: secondary,
                  ),
                ),
              ),
              if (volume['readOnly'] == true) ...[
                const SizedBox(width: 5),
                IsleStatusBadge(label: '只读', color: palette['warning']),
              ],
              if (target != null && onOpen != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  color: secondary.withValues(alpha: 0.7),
                  size: 17,
                ),
              ],
            ],
          ),
          if (matches.isEmpty) ...[
            const SizedBox(height: 6),
            Text(
              rootsError != null
                  ? '目录暂无法确认'
                  : isSystemVolume
                  ? '系统分区（仅容量）'
                  : '未登记为 NAS 目录',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelSmall?.copyWith(fontSize: 11, color: secondary),
            ),
          ],
          const SizedBox(height: 8),
          IsleSegmentedBar(
            height: 6.5,
            showLegend: total > 0,
            legendGap: 4,
            legendSpacing: 10,
            legendRunSpacing: 2,
            segments: total > 0
                ? [
                    IsleChartSegment(
                      label: '已用',
                      value: usedBytes,
                      color: gaugeColor,
                      detail: formatBytes(usedBytes),
                    ),
                    IsleChartSegment(
                      label: '可用',
                      value: free.clamp(0.0, total),
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      detail: formatBytes(free),
                    ),
                  ]
                : const [],
          ),
          if (matches.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: IsleDecorations.recessedWell(
                context,
                radius: IsleRadius.sm,
              ),
              child: Column(
                children: [
                  for (final root in matches)
                    Row(
                      children: [
                        Icon(
                          root.online
                              ? Icons.folder_rounded
                              : Icons.cloud_off_outlined,
                          size: 15,
                          color: root.online
                              ? palette['brandAmber']
                              : secondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            root.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(40, 26),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                          ),
                          onPressed: root.online && onOpen != null
                              ? () => onOpen!(root, '.')
                              : null,
                          child: Text(
                            root.online ? '浏览文件' : '离线',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStandaloneRootsSection(
    BuildContext context,
    Color secondary,
    IslePalette palette,
    bool isDark,
  ) {
    final mountedPaths = volumes
        .map((v) => v['mount'])
        .whereType<String>()
        .where((m) => m.isNotEmpty)
        .toSet();
    final standaloneRoots = volumes.isEmpty
        ? roots
        : roots
              .where(
                (r) =>
                    r.volumeMount == null ||
                    r.volumeMount!.isEmpty ||
                    !mountedPaths.contains(r.volumeMount),
              )
              .toList();
    if (rootsError == null && roots.isNotEmpty && standaloneRoots.isEmpty) {
      return const SizedBox.shrink();
    }
    final borderColor = IsleGlass.rimBorderColor(isDark);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        IsleSectionHeader(
          title: '已登记的 NAS 目录',
          accentColor: palette['brandAmber'],
        ),
        if (rootsError != null)
          Notice('无法验证已登记目录：$rootsError', error: true)
        else if (roots.isEmpty)
          const Notice('暂无已登记的 NAS 目录。请在 Mac 管理端添加后再浏览。')
        else
          IsleSurface(
            margin: EdgeInsets.zero,
            padding: EdgeInsets.zero,
            radius: IsleRadius.card,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < standaloneRoots.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.7,
                      indent: 48,
                      color: borderColor,
                    ),
                  Builder(
                    builder: (context) {
                      final root = standaloneRoots[i];
                      return ListTile(
                        key: ValueKey('adminBrowseRoot:${root.id}'),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 2,
                        ),
                        leading: IsleSquircleBadge(
                          icon: Icons.folder_rounded,
                          color: root.online
                              ? palette['brandAmber']
                              : secondary,
                          size: 32,
                          iconSize: 16.5,
                        ),
                        title: Text(
                          root.name,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: root.online
                            ? null
                            : const Text(
                                '存储卷离线或已更换',
                                style: TextStyle(fontSize: 12),
                              ),
                        trailing: Icon(
                          root.online
                              ? Icons.chevron_right_rounded
                              : Icons.cloud_off_outlined,
                          size: 18,
                        ),
                        enabled: root.online && onOpen != null,
                        onTap: root.online && onOpen != null
                            ? () => onOpen!(root, '.')
                            : null,
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final secondary = theme.colorScheme.onSurfaceVariant;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '存储卷与磁盘槽位',
          accentColor: palette['brandSage'],
          helpTitle: '存储卷与访问边界',
          helpBody:
              '存储卷对应 macOS 物理磁盘或 APFS 分区；移动端文件浏览仅开放已在 Mac 管理端登记的 NAS 目录，不会直接读取 Macintosh HD 系统分区或未授权目录。',
        ),
        if (volumes.isEmpty)
          const Notice('当前没有可用的存储卷信息。')
        else
          IsleResponsiveGrid(
            minItemWidth: 280,
            maxColumns: 2,
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final volume in volumes)
                _buildVolumeCard(
                  context,
                  volume,
                  text: text,
                  secondary: secondary,
                  palette: palette,
                  isDark: isDark,
                ),
            ],
          ),
        _buildStandaloneRootsSection(context, secondary, palette, isDark),
      ],
    );
  }
}

class MemberStorageBrowser extends StatelessWidget {
  const MemberStorageBrowser({
    super.key,
    required this.storage,
    required this.roots,
    required this.onOpen,
  });

  final Map<String, dynamic> storage;
  final List<LightIsleRoot> roots;
  final OpenStorageDirectory? onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final sections = <(String, String, IconData, Color)>[
      ('files', '普通文件', Icons.folder_rounded, palette['brandAmber']),
      ('photos', '我的图库', Icons.photo_library_rounded, palette['brandRose']),
      ('cinema', '我的影视', Icons.movie_rounded, palette['brandTerracotta']),
    ];
    final allocations = objectList(storage['locations']);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final assignedSections = sections
        .where(
          (entry) => allocations.any(
            (a) =>
                a['category'] == (entry.$1 == 'cinema' ? 'videos' : entry.$1),
          ),
        )
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        IsleSectionHeader(
          title: '我的存储目录',
          accentColor: palette['brandAmber'],
        ),
        if (assignedSections.isEmpty)
          const Notice('管理员还没有为你分配个人存储目录。')
        else
          IsleSurface(
            margin: EdgeInsets.zero,
            padding: EdgeInsets.zero,
            radius: IsleRadius.card,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < assignedSections.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.7,
                      indent: 48,
                      color: borderColor,
                    ),
                  Builder(
                    builder: (context) {
                      final (section, label, icon, tone) = assignedSections[i];
                      final route = resolvePersonalRoute(
                        storage,
                        roots,
                        section,
                      );
                      final online =
                          route.kind == PersonalRouteKind.personal &&
                          route.root != null &&
                          route.path != null;
                      return ListTile(
                        key: ValueKey('memberStorage:$section'),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 3,
                        ),
                        leading: IsleSquircleBadge(
                          icon: icon,
                          color: online ? tone : secondary,
                          size: 32,
                          iconSize: 16.5,
                        ),
                        title: Text(
                          label,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          online ? route.root!.name : '存储位置离线或绑定尚未验证',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Icon(
                          online
                              ? Icons.chevron_right_rounded
                              : Icons.cloud_off_outlined,
                          size: 18,
                        ),
                        enabled: online && onOpen != null,
                        onTap: online && onOpen != null
                            ? () => onOpen!(route.root!, route.path!)
                            : null,
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
