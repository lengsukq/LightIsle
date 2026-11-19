import 'package:flutter/material.dart';

import '../../core/isle_style.dart';
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
    final palette = IslePalette.of(context);
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
                          '高级排障',
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
