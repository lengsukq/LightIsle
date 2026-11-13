import 'package:flutter/material.dart';

import '../../core/widgets.dart';

/// Default-collapsed administrator troubleshooting links so low-frequency
/// diagnostics and maintenance never clutter daily settings or auto-fetch.
class AdminTroubleshootingSection extends StatefulWidget {
  const AdminTroubleshootingSection({
    super.key,
    required this.onOpenDiagnostics,
    required this.onOpenAudit,
    required this.onOpenUploadMaintenance,
  });

  final VoidCallback onOpenDiagnostics;
  final VoidCallback onOpenAudit;
  final VoidCallback onOpenUploadMaintenance;

  @override
  State<AdminTroubleshootingSection> createState() =>
      _AdminTroubleshootingSectionState();
}

class _AdminTroubleshootingSectionState
    extends State<AdminTroubleshootingSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return IsleAnimatedEntrance(
      delay: const Duration(milliseconds: 95),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const IsleSectionHeader(
            title: '管理员排障',
            padding: EdgeInsets.fromLTRB(6, 12, 6, 6),
          ),
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              InkWell(
                key: const ValueKey('adminTroubleshootingToggle'),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      IsleSquircleBadge(
                        icon: Icons.build_circle_outlined,
                        color: colors.secondary,
                        size: 32,
                        iconSize: 17,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '高级排障',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _expanded
                                  ? '包含设备诊断、上传维护与安全审计'
                                  : '默认折叠，仅在需要排查故障时展开',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0.0,
                        duration: IsleMotion.reducedMotion(context)
                            ? Duration.zero
                            : IsleMotion.fast,
                        curve: IsleMotion.curve,
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IsleAnimatedExpand(
                expanded: _expanded,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IsleGroupTile(
                      icon: Icons.monitor_heart_outlined,
                      iconBgColor: colors.primary,
                      title: '设备诊断与 Key 状态',
                      subtitle: '性能历史、网卡、磁盘 SMART 和第三方配置状态',
                      onTap: widget.onOpenDiagnostics,
                    ),
                    IsleGroupTile(
                      icon: Icons.cloud_upload_rounded,
                      iconBgColor: colors.primary,
                      title: '上传维护',
                      subtitle: '处理残留与过期上传',
                      onTap: widget.onOpenUploadMaintenance,
                    ),
                    IsleGroupTile(
                      icon: Icons.policy_outlined,
                      iconBgColor: colors.primary,
                      title: '安全审计',
                      subtitle: '查看管理员操作记录',
                      onTap: widget.onOpenAudit,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
