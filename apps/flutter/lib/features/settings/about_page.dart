import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const String repoUrl = 'https://github.com/lengsukq/LightIsle';

  Future<void> _openRepo(BuildContext context) async {
    final uri = Uri.parse(repoUrl);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        _copyRepo(context, note: '无法自动唤起浏览器，已将链接复制到剪贴板');
      }
    } catch (_) {
      if (context.mounted) {
        _copyRepo(context, note: '打开失败，已将链接复制到剪贴板');
      }
    }
  }

  void _copyRepo(BuildContext context, {String? note}) {
    Clipboard.setData(const ClipboardData(text: repoUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(note ?? '已复制 GitHub 仓库链接：$repoUrl'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final unifiedHeroCard = LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 520;

        Widget featureChip(IconData icon, String label) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: isDark ? 0.16 : 0.06),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: colors.primary.withValues(alpha: isDark ? 0.28 : 0.14),
                width: 0.6,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: colors.primary),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
              ],
            ),
          );
        }

        final brandInfoBlock = Column(
          crossAxisAlignment: isCompact
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: isCompact ? WrapAlignment.center : WrapAlignment.start,
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                  '轻屿 LightIsle',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                    fontSize: 22,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(
                      alpha: isDark ? 0.20 : 0.08,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: colors.primary.withValues(
                        alpha: isDark ? 0.35 : 0.20,
                      ),
                      width: 0.75,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.flutter_dash, size: 12, color: colors.primary),
                      const SizedBox(width: 4),
                      Text(
                        'v0.1.0 · Preview',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '运行在个人 Mac 上、面向家庭的轻量 NAS 管理工具',
              textAlign: isCompact ? TextAlign.center : TextAlign.start,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: isCompact ? WrapAlignment.center : WrapAlignment.start,
              children: [
                featureChip(Icons.laptop_mac_rounded, 'Mac 原生后台'),
                featureChip(Icons.backup_rounded, 'Time Machine 保护'),
                featureChip(Icons.code_rounded, '源码公开 · 非商业许可'),
              ],
            ),
          ],
        );

        final logoBadge = Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.primary.withValues(alpha: isDark ? 0.18 : 0.08),
            boxShadow: [
              BoxShadow(
                color: colors.primary.withValues(alpha: isDark ? 0.35 : 0.16),
                blurRadius: 20,
                spreadRadius: 1,
              ),
            ],
          ),
          padding: const EdgeInsets.all(11),
          child: const IsleBrandMark(size: 42),
        );

        final brandHeaderRow = isCompact
            ? Column(
                children: [
                  logoBadge,
                  const SizedBox(height: 14),
                  brandInfoBlock,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  logoBadge,
                  const SizedBox(width: 18),
                  Expanded(child: brandInfoBlock),
                ],
              );

        final insetGithubDock = Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : colors.primary.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : colors.outlineVariant.withValues(alpha: 0.35),
              width: 0.8,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.code_rounded,
                        size: 17,
                        color: isDark
                            ? const Color(0xFF58A6FF)
                            : const Color(0xFF24292F),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        'GitHub 源码仓库',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD97706).withValues(
                            alpha: isDark ? 0.25 : 0.12,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 10,
                              color: isDark
                                  ? const Color(0xFFFFC107)
                                  : const Color(0xFFB45309),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              'Star',
                              style: TextStyle(
                                color: isDark
                                    ? const Color(0xFFFFC107)
                                    : const Color(0xFFB45309),
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'lengsukq/LightIsle',
                    style: TextStyle(
                      color: isDark
                          ? const Color(0xFF58A6FF)
                          : const Color(0xFF0969DA),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _openRepo(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new_rounded, size: 14),
                      label: const Text(
                        '访问代码仓库',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _copyRepo(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.onSurface,
                      side: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: 0.5),
                        width: 0.7,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.copy_rounded, size: 13),
                    label: const Text('复制链接', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        );

        return IsleSurface(
          radius: 24,
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              brandHeaderRow,
              const SizedBox(height: 18),
              Divider(
                height: 1,
                thickness: 0.6,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : colors.outlineVariant.withValues(alpha: 0.35),
              ),
              const SizedBox(height: 16),
              insetGithubDock,
            ],
          ),
        );
      },
    );

    final principlesSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const IsleSectionHeader(
          title: '系统架构与数据原则',
          padding: EdgeInsets.fromLTRB(10, 20, 10, 8),
        ),
        IsleGroupCard(
          margin: EdgeInsets.zero,
          children: [
            IsleGroupTile(
              icon: Icons.laptop_mac_rounded,
              iconBgColor: const Color(0xFF007AFF),
              title: 'Mac 原生管理端独立运行',
              subtitle: 'NAS 服务、存储权限与设备通信由原生服务管理；关闭当前客户端不会中断 NAS 运行。',
            ),
            IsleGroupTile(
              icon: Icons.backup_rounded,
              iconBgColor: const Color(0xFF34C759),
              title: '原片由用户自主防护',
              subtitle: '原始照片、视频与文件建议通过 macOS Time Machine 或独立备份工具保护，客户端不替您冒险。',
            ),
            IsleGroupTile(
              icon: Icons.spa_rounded,
              iconBgColor: const Color(0xFFFF9500),
              title: '轻量透明，无企业级冗余',
              subtitle: '专为个人与家庭设计，不额外堆砌冗余复杂服务，保持整机稳定与资源轻简。',
            ),
          ],
        ),
      ],
    );

    final clientInfoSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const IsleSectionHeader(
          title: '关于客户端',
          padding: EdgeInsets.fromLTRB(10, 20, 10, 8),
        ),
        IsleGroupCard(
          margin: EdgeInsets.zero,
          children: [
            IsleGroupTile(
              icon: Icons.devices_rounded,
              iconBgColor: const Color(0xFF5856D6),
              title: '跨平台统一体验',
              subtitle: '支持 macOS、iOS、Android 等多平台，使用一致的文件与媒体流转界面。',
            ),
            IsleGroupTile(
              icon: Icons.lock_outline_rounded,
              iconBgColor: const Color(0xFF30B0C7),
              title: '凭据与会话安全',
              subtitle: '登录会话保存在设备的安全存储中，不保存明文密码；可随时改密或撤销。',
            ),
          ],
        ),
      ],
    );

    final footer = Text(
      '轻屿 LightIsle · 探索更自由的个人与家庭云\n'
      'PolyForm Noncommercial 1.0.0 · 商业使用需单独授权\n'
      'https://polyformproject.org/licenses/noncommercial/1.0.0\n'
      'Required Notice: Copyright (c) 2026 lengsukq (https://github.com/lengsukq)\n'
      'GitHub @lengsukq/LightIsle',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: colors.onSurfaceVariant.withValues(alpha: 0.65),
        height: 1.5,
      ),
    );

    return Scaffold(
      appBar: const IsleAppBar(title: Text('关于轻屿')),
      body: IsleListView(
        maxWidth: 760,
        children: [
          unifiedHeroCard,
          const SizedBox(height: 16),
          principlesSection,
          const SizedBox(height: 12),
          clientInfoSection,
          const SizedBox(height: 28),
          footer,
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
