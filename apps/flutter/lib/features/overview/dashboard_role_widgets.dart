import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';

/// Navigational shortcuts are shared, but the member sees them before usage
/// accounting while an administrator sees device health and metrics first.
class DashboardQuickLinks extends StatelessWidget {
  const DashboardQuickLinks({
    super.key,
    required this.onNavigate,
    required this.admin,
  });

  final ValueChanged<int> onNavigate;
  final bool admin;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final bigText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final width = constraints.maxWidth;
      final columns = bigText
          ? 1
          : width >= 800
          ? 3
          : width >= 440
          ? 2
          : 1;
      const gap = 9.0;
      final links = <(int, IconData, String, String, Color)>[
        (
          1,
          Icons.folder_rounded,
          '我的文件',
          '浏览与整理',
          IslePalette.of(context)['brandCyan'],
        ),
        (
          2,
          Icons.photo_library_rounded,
          '时光相册',
          '相册与收藏',
          IslePalette.of(context)['brandViolet'],
        ),
        (
          3,
          Icons.movie_rounded,
          '私人影院',
          '电影与剧集',
          IslePalette.of(context)['brandBlue'],
        ),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IsleSectionHeader(title: admin ? '我的内容' : '个人空间'),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final item in links)
                SizedBox(
                  width: (width - (columns - 1) * gap) / columns,
                  child: IsleSurface(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 11,
                    ),
                    onTap: () => onNavigate(item.$1),
                    child: Row(
                      children: [
                        IsleSquircleBadge(
                          icon: item.$2,
                          color: item.$5,
                          size: 34,
                          iconSize: 19,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.$3,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                item.$4,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// Per-disk quota data is an application ledger, not measured physical usage.
class MemberStorageSummary extends StatelessWidget {
  const MemberStorageSummary({super.key, required this.storage});

  final Map<String, dynamic> storage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quotas = objectList(storage['rootQuotas']);
    final count = objectList(storage['locations']).length;
    final complete = storage['usageComplete'] == true;
    return IsleSurface(
      radius: 18,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.storage_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '我的存储空间',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$count 个目录',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (quotas.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '尚未分配独立硬盘额度，可在设置中查看分类存储位置。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (var i = 0; i < quotas.length; i++) ...[
            const SizedBox(height: 12),
            Builder(
              builder: (context) {
                final quota = quotas[i];
                final bound = quota['quotaBytes'] as num?;
                final accounted = (quota['accountedBytes'] as num?) ?? 0;
                final reserved = (quota['reservedBytes'] as num?) ?? 0;
                final name = quota['name']?.toString();
                final diskId = quota['rootID']?.toString() ?? '';
                final suffix = diskId.length > 6
                    ? diskId.substring(0, 6)
                    : diskId;
                final label = name != null && name.isNotEmpty
                    ? name
                    : '硬盘 $suffix';
                final progress = bound != null && bound > 0
                    ? ((accounted + reserved) / bound)
                          .clamp(0.0, 1.0)
                          .toDouble()
                    : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${formatBytes(accounted)} / '
                          '${bound == null ? '不限额' : formatBytes(bound)}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 5,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                    if (reserved > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '上传预占 ${formatBytes(reserved)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
          if (!complete) ...[
            const SizedBox(height: 10),
            Text(
              '仅为已入账用量，部分渠道未统计，不等于硬盘实际占用。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
