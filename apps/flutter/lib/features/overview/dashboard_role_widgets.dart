import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';

/// Navigational shortcuts and the primary File Manager entry point on the
/// Dashboard (since File Management is now housed inside the Dashboard
/// launchpad rather than occupying a top-level bottom navigation tab).
class DashboardQuickLinks extends StatelessWidget {
  const DashboardQuickLinks({
    super.key,
    required this.onNavigate,
    required this.admin,
    this.onOpenFiles,
    this.onOpenShares,
    this.onQuickUpload,
  });

  final ValueChanged<int> onNavigate;
  final bool admin;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenShares;
  final VoidCallback? onQuickUpload;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final bigText = MediaQuery.textScalerOf(context).scale(14) > 19;
      final width = constraints.maxWidth;
      final columns = bigText
          ? (width >= 640 ? 2 : 1)
          : width >= 680
          ? 4
          : width >= 300
          ? 2
          : 1;
      final gap = width < IsleLayout.compactPageWidth ? 8.0 : 10.0;
      final cardWidth = (width - (columns - 1) * gap) / columns;
      final compactCard = cardWidth < 210;
      final accentColor = theme.colorScheme.primary;
      final links = <(
        String,
        VoidCallback,
        IconData,
        String,
        String,
        bool,
      )>[
        (
          'dashboardFilesEntry',
          onOpenFiles ?? () => onNavigate(-1),
          Icons.folder_outlined,
          '文件管理',
          '浏览、上传与整理 NAS 目录',
          true,
        ),
        (
          'dashboardPhotosEntry',
          () => onNavigate(1),
          Icons.photo_library_outlined,
          '时光相册',
          '回忆故事流与文件夹相册',
          false,
        ),
        (
          'dashboardCinemaEntry',
          () => onNavigate(2),
          Icons.movie_outlined,
          '私人影院',
          '海报墙、热播走廊与续播',
          false,
        ),
        if (onOpenShares != null)
          (
            'dashboardSharesEntry',
            onOpenShares!,
            Icons.ios_share_rounded,
            '我的分享',
            '管理已创建的公开分享链接',
            false,
          )
        else if (onQuickUpload != null)
          (
            'dashboardUploadEntry',
            onQuickUpload!,
            Icons.cloud_upload_outlined,
            '快速上传',
            '直接选择文件或照片入队',
            false,
          ),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IsleSectionHeader(
            title: admin ? '快捷工作台与文件入口' : '个人空间与文件管理',
            action: onQuickUpload != null
                ? TextButton.icon(
                    onPressed: onQuickUpload,
                    icon: const Icon(Icons.upload_file_rounded, size: 16),
                    label: const Text('快速上传'),
                  )
                : null,
          ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < links.length; i++)
                Builder(
                  builder: (context) {
                    final item = links[i];
                    return SizedBox(
                      width: cardWidth,
                      child: IsleAnimatedEntrance(
                        delay: Duration(milliseconds: 28 * i),
                        child: IsleSurface(
                          key: ValueKey(item.$1),
                          radius:
                              compactCard ? IsleRadius.item : IsleRadius.card,
                          padding: EdgeInsets.symmetric(
                            horizontal: compactCard ? 10 : 14,
                            vertical: compactCard ? 10 : 13,
                          ),
                          onTap: item.$2,
                          child: Row(
                            children: [
                              IsleSquircleBadge(
                                icon: item.$3,
                                color: accentColor,
                                size: compactCard ? 34 : 40,
                                iconSize: compactCard ? 18 : 20,
                              ),
                              SizedBox(width: compactCard ? 9 : 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            item.$4,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleSmall
                                                ?.copyWith(
                                                  fontSize:
                                                      compactCard ? 13.5 : 14,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: -0.2,
                                                ),
                                          ),
                                        ),
                                        if (item.$6 && !compactCard) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1.5,
                                            ),
                                            decoration: ShapeDecoration(
                                              color: theme
                                                  .colorScheme
                                                  .surfaceContainerHighest
                                                  .withValues(alpha: 0.65),
                                              shape: IsleShapes.squircle(6),
                                            ),
                                            child: Text(
                                              '主入口',
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.$5,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontSize: compactCard ? 11 : 12,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!compactCard)
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.45),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
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
      radius: IsleRadius.card,
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
            )
          else ...[
            const SizedBox(height: 14),
            IsleResponsiveGrid(
              minItemWidth: 280,
              maxColumns: 2,
              spacing: 14,
              runSpacing: 14,
              children: [
                for (var i = 0; i < quotas.length; i++)
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
