import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'beta_diagnostic_report.dart';

/// Lightweight About page presenting version, data principles, repository link,
/// open-source licenses, and sanitized diagnostic export.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.api});

  static const String appVersion = '0.1.0';
  static const String repoUrl = 'https://github.com/lengsukq/LightIsle';

  final LightIsleApi? api;

  Future<void> _openRepo(BuildContext context) async {
    final uri = Uri.parse(repoUrl);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        _copyRepo(context, note: '无法自动打开浏览器，已复制仓库链接。');
      }
    } catch (_) {
      if (context.mounted) {
        _copyRepo(context, note: '无法自动打开浏览器，已复制仓库链接。');
      }
    }
  }

  void _copyRepo(BuildContext context, {String? note}) {
    Clipboard.setData(const ClipboardData(text: repoUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(note ?? '已复制 GitHub 仓库链接：$repoUrl'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);

    return Scaffold(
      appBar: const IsleAppBar(title: Text('关于轻屿')),
      body: IsleListView(
        maxWidth: IsleLayout.settingsWidth,
        children: [
          _buildIdentityCard(theme, colors, palette),
          const SizedBox(height: 12),
          IsleSectionHeader(
            title: '产品与数据原则',
            accentColor: palette['brandAmber'],
          ),
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              IsleGroupTile(
                icon: Icons.desktop_mac_rounded,
                iconBgColor: palette['brandBlue'],
                title: 'Mac 原生管理端独立运行',
                subtitle: '服务生命周期、硬盘登记与系统备份由本机 Mac 管理端掌控，客户端仅负责日常访问。',
              ),
              IsleGroupTile(
                icon: Icons.shield_outlined,
                iconBgColor: palette['brandSage'],
                title: '原片由用户自主防护',
                subtitle: '不自动搬迁或格式化磁盘；原片与视频建议配合 macOS Time Machine 独立保护。',
              ),
              IsleGroupTile(
                icon: Icons.auto_awesome_outlined,
                iconBgColor: palette['brandAmber'],
                title: '轻量透明，无企业级冗余',
                subtitle: '优先保障个人与家庭的文件、相册和影院日常顺畅，错误提示清晰、恢复由你掌控。',
              ),
            ],
          ),
          const SizedBox(height: 12),
          IsleSectionHeader(
            title: '源码与许可',
            accentColor: palette['brandViolet'],
          ),
          _buildRepositoryCard(context, theme, colors, palette),
          const SizedBox(height: 12),
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              IsleGroupTile(
                icon: Icons.description_outlined,
                iconBgColor: palette['brandViolet'],
                title: '开源与第三方许可',
                subtitle: '查看客户端使用的开源组件与协议声明',
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: '轻屿 LightIsle',
                  applicationVersion: appVersion,
                  applicationIcon: const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: IsleBrandMark(size: 48),
                  ),
                ),
              ),
              if (api != null)
                IsleGroupTile(
                  icon: Icons.bug_report_outlined,
                  iconBgColor: palette['brandBlue'],
                  title: '脱敏排障诊断报告',
                  subtitle: '导出不含密码与文件路径的诊断摘要以便反馈问题',
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: () => showBetaDiagnosticReport(context, api!),
                ),
            ],
          ),
          const SizedBox(height: 18),
          _buildLicenseFooter(theme, colors),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildIdentityCard(
    ThemeData theme,
    ColorScheme colors,
    IslePalette palette,
  ) {
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.hero,
      tint: palette['brandAmber'],
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          const IsleBrandMark(size: 56),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '轻屿 LightIsle',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    IsleBadgePill(
                      label: 'v$appVersion',
                      color: palette['accentPrimary'],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '运行在个人 Mac 上的轻量家庭私有云客户端。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRepositoryCard(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
    IslePalette palette,
  ) {
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.code_rounded, size: 18, color: colors.primary),
                  const SizedBox(width: 6),
                  Text(
                    'GitHub 源码仓库',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              IsleBadgePill(
                label: 'lengsukq/LightIsle',
                color: colors.primary,
              ),
              IsleBadgePill(
                label: '源码公开 · 非商业许可',
                color: palette['brandSage'],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '轻屿遵循 PolyForm 非商业许可公开源码，欢迎查阅文档或提交问题反馈。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _openRepo(context),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('访问代码仓库'),
              ),
              OutlinedButton.icon(
                onPressed: () => _copyRepo(context),
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制链接'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLicenseFooter(ThemeData theme, ColorScheme colors) {
    final style = theme.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      color: colors.onSurfaceVariant,
      height: 1.5,
    );
    return Column(
      children: [
        Text(
          'PolyForm Noncommercial 1.0.0',
          textAlign: TextAlign.center,
          style: style?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(
          'Required Notice: Copyright (c) 2026 lengsukq',
          textAlign: TextAlign.center,
          style: style,
        ),
      ],
    );
  }
}
