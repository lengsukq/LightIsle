import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/personal_storage_routing.dart';
import '../../core/widgets.dart';

/// A browser target is always a *registered, authenticated* NAS root and a
/// root-relative directory, never a macOS mount path or arbitrary filesystem
/// address. Null represents only the administrator's legacy shared folder.
typedef OpenStorageDirectory = void Function(
  LightIsleRoot? root,
  String directory,
);

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
  }) {
    final mount = volume['mount'];
    // No guessing by disk name or free capacity: APFS volumes can
    // share these values and user-facing labels can be duplicated.
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
        ? const Color(0xffef4444)
        : used >= 0.78
        ? const Color(0xfff59e0b)
        : (isSystemVolume ? const Color(0xff64748b) : const Color(0xff0ea5e9));
    return IsleSurface(
      key: ValueKey('physicalVolume:${volume['mount'] ?? volume['name']}'),
      radius: 16,
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
                color: isSystemVolume
                    ? const Color(0xff64748b)
                    : const Color(0xff0ea5e9),
                size: 32,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  volume['name']?.toString() ?? '存储卷',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (total > 0) ...[
                IsleDonutGauge(
                  fraction: used,
                  color: gaugeColor,
                  size: 30,
                  strokeWidth: 3.5,
                  centerText: '${(used * 100).round()}%',
                  centerStyle: text.labelSmall?.copyWith(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  semanticsLabel:
                      '${volume['name'] ?? '存储卷'} 已使用 ${(used * 100).round()}%',
                ),
                const SizedBox(width: 8),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  (volume['filesystem']?.toString() ?? '未知').toUpperCase(),
                  style: text.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: secondary,
                  ),
                ),
              ),
              if (volume['readOnly'] == true) ...[
                const SizedBox(width: 6),
                const IsleStatusBadge(label: '只读', color: Color(0xfff59e0b)),
              ],
              if (target != null && onOpen != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  color: secondary.withValues(alpha: 0.7),
                  size: 18,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${formatBytes(volume['free'] as num?)} 可用 / '
                  '${formatBytes(volume['total'] as num?)}',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: text.bodySmall?.copyWith(
                    color: secondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (matches.isEmpty)
                Flexible(
                  child: Text(
                    rootsError != null
                        ? '目录暂无法确认'
                        : isSystemVolume
                        ? '系统分区（仅容量）'
                        : '未登记为 NAS 目录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(color: secondary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          IsleSegmentedBar(
            height: 7,
            showLegend: total > 0,
            legendGap: 5,
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
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      detail: formatBytes(free),
                    ),
                  ]
                : const [],
          ),
          if (matches.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final root in matches)
              Row(
                children: [
                  Icon(
                    root.online
                        ? Icons.folder_outlined
                        : Icons.cloud_off_outlined,
                    size: 16,
                    color: secondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      root.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(44, 30),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                    ),
                    onPressed: root.online && onOpen != null
                        ? () => onOpen!(root, '.')
                        : null,
                    child: Text(root.online ? '浏览文件' : '离线'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildStandaloneRootsSection(BuildContext context, Color secondary) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const IsleSectionHeader(title: '已登记的 NAS 目录'),
        if (rootsError != null)
          Notice('无法验证已登记目录：$rootsError', error: true)
        else if (roots.isEmpty)
          const Notice('暂无已登记的 NAS 目录。请在 Mac 管理端添加后再浏览。')
        else
          IsleResponsiveGrid(
            minItemWidth: 300,
            maxColumns: standaloneRoots.length >= 2 ? 2 : 1,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final root in standaloneRoots)
                IsleSurface(
                  key: ValueKey('adminBrowseRoot:${root.id}'),
                  radius: 16,
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  onTap: root.online && onOpen != null
                      ? () => onOpen!(root, '.')
                      : null,
                  child: ListTile(
                    leading: Icon(
                      Icons.folder_outlined,
                      color: root.online ? const Color(0xff0ea5e9) : secondary,
                    ),
                    title: Text(root.name),
                    subtitle: Text(
                      root.online ? '查看此 NAS 目录下的文件' : '存储卷离线或已更换',
                    ),
                    trailing: Icon(
                      root.online
                          ? Icons.chevron_right_rounded
                          : Icons.cloud_off_outlined,
                    ),
                    enabled: root.online && onOpen != null,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const IsleSectionHeader(title: '存储卷'),
        if (volumes.isEmpty)
          const Notice('当前没有可用的存储卷信息。')
        else
          IsleResponsiveGrid(
            minItemWidth: 340,
            maxColumns: 2,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final volume in volumes)
                _buildVolumeCard(
                  context,
                  volume,
                  text: text,
                  secondary: secondary,
                ),
            ],
          ),
        _buildStandaloneRootsSection(context, secondary),
        const SizedBox(height: 8),
        const IsleHelpDisclosure(
          summary: '为什么不能直接打开整个 Macintosh HD？',
          details:
              '存储卷是 macOS 物理磁盘/分区，NAS 文件浏览仅允许进入已经在 Mac 端登记的共享目录。'
              '即使是管理员也不会通过移动端读取未授权的系统目录或 Recovery 分区。',
        ),
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
    const sections = <(String, String, IconData)>[
      ('files', '普通文件', Icons.folder_outlined),
      ('photos', '我的图库', Icons.photo_library_outlined),
      ('cinema', '我的影视', Icons.movie_outlined),
    ];
    final allocations = objectList(storage['locations']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const IsleSectionHeader(title: '我的存储目录'),
        if (allocations.isEmpty)
          const Notice('管理员还没有为你分配个人存储目录。')
        else
          IsleResponsiveGrid(
            minItemWidth: 280,
            maxColumns: 3,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (section, label, icon) in sections)
                if (allocations.any(
                  (entry) =>
                      entry['category'] ==
                      (section == 'cinema' ? 'videos' : section),
                ))
                  Builder(
                    builder: (context) {
                      final route = resolvePersonalRoute(
                        storage,
                        roots,
                        section,
                      );
                      final online =
                          route.kind == PersonalRouteKind.personal &&
                          route.root != null &&
                          route.path != null;
                      return IsleSurface(
                        radius: 16,
                        margin: EdgeInsets.zero,
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          key: ValueKey('memberStorage:$section'),
                          leading: Icon(icon),
                          title: Text(label),
                          subtitle: Text(
                            online
                                ? '${route.root!.name} · 已分配个人目录'
                                : '存储位置离线或绑定尚未验证',
                          ),
                          trailing: Icon(
                            online
                                ? Icons.chevron_right_rounded
                                : Icons.cloud_off_outlined,
                          ),
                          enabled: online && onOpen != null,
                          onTap: online && onOpen != null
                              ? () => onOpen!(route.root!, route.path!)
                              : null,
                        ),
                      );
                    },
                  ),
            ],
          ),
      ],
    );
  }
}
