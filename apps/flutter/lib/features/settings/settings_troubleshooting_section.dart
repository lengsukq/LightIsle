import 'package:flutter/material.dart';

import '../../core/widgets.dart';

/// Default-collapsed administrator remote-ops & troubleshooting links so
/// low-frequency Mac host administration never clutters daily settings.
class AdminTroubleshootingSection extends StatefulWidget {
  const AdminTroubleshootingSection({
    super.key,
    required this.onOpenDiagnostics,
    required this.onOpenAudit,
    required this.onOpenUploadMaintenance,
    this.onOpenAutomation,
    this.onOpenSmb,
  });

  final VoidCallback onOpenDiagnostics;
  final VoidCallback onOpenAudit;
  final VoidCallback onOpenUploadMaintenance;
  final VoidCallback? onOpenAutomation;
  final VoidCallback? onOpenSmb;

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
    final palette = IslePalette.of(context);
    return IsleAnimatedEntrance(
      delay: const Duration(milliseconds: 95),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const IsleSectionHeader(
            title: 'Mac 远程运维',
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
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      IsleSquircleBadge(
                        icon: Icons.build_circle_outlined,
                        color: palette['brandAmber'],
                        size: 32,
                        iconSize: 17,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Mac 远程运维（高级）',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
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
                    Divider(
                      height: 1,
                      color: IsleGlass.rimBorderColor(
                        theme.brightness == Brightness.dark,
                      ),
                    ),
                    if (widget.onOpenSmb != null)
                      IsleGroupTile(
                        icon: Icons.folder_shared_rounded,
                        iconBgColor: palette['brandSage'],
                        title: 'Mac 文件共享 (SMB)',
                        onTap: widget.onOpenSmb,
                      ),
                    if (widget.onOpenAutomation != null)
                      IsleGroupTile(
                        icon: Icons.terminal_rounded,
                        iconBgColor: palette['brandTerracotta'],
                        title: '本机脚本自动化',
                        onTap: widget.onOpenAutomation,
                      ),
                    IsleGroupTile(
                      icon: Icons.monitor_heart_outlined,
                      iconBgColor: palette['brandBlue'],
                      title: '设备诊断与 Key 状态',
                      onTap: widget.onOpenDiagnostics,
                    ),
                    IsleGroupTile(
                      icon: Icons.cloud_upload_rounded,
                      iconBgColor: palette['brandCyan'],
                      title: '上传维护',
                      onTap: widget.onOpenUploadMaintenance,
                    ),
                    IsleGroupTile(
                      icon: Icons.policy_outlined,
                      iconBgColor: palette['brandIndigo'],
                      title: '安全审计',
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
