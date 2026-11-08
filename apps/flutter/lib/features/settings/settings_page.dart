import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import '../../core/user_facing_error.dart';
import 'account_security_page.dart';
import 'admin_activity_page.dart';
import 'admin_diagnostics_page.dart';
import 'network_diagnostics_page.dart';
import 'dav_page.dart';
import 'storage_page.dart';
import 'accounts_page.dart';
import 'upload_maintenance_page.dart';
import 'missing_media_page.dart';
import 'about_page.dart';
import 'automation_page.dart';

export 'accounts_page.dart';
export 'grants_page.dart';
export 'upload_maintenance_page.dart';
export 'about_page.dart';
export 'automation_page.dart';
import '../files/file_shares_page.dart';
import '../files/downloads_page.dart';
import '../media/offline_video_store.dart';
import '../media/offline_photo_store.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.identity,
    required this.onLogout,
    this.pendingUploads,
  });

  final LightIsleApi api;
  final Map<String, dynamic> identity;
  final Future<void> Function() onLogout;

  /// Read on demand to avoid displaying stale counts in an open settings tab.
  final int Function()? pendingUploads;

  void _go(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _entry(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) => IsleGroupTile(
    icon: icon,
    iconBgColor: color,
    title: title,
    subtitle: subtitle,
    onTap: onTap,
  );

  Widget _section(
    BuildContext context, {
    required String title,
    required int index,
    required List<Widget> entries,
  }) => IsleAnimatedEntrance(
    delay: Duration(milliseconds: 35 * index),
    child: Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IsleSectionHeader(
            title: title,
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
          ),
          IsleGroupCard(margin: EdgeInsets.zero, children: entries),
        ],
      ),
    ),
  );

  void _showConnection(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连接详情'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '当前服务器',
                  style: Theme.of(dialogContext).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                SelectableText(api.uri('/').origin),
                const SizedBox(height: 16),
                const Text('登录状态保存在系统安全存储中，不保存密码。'),
                const SizedBox(height: 8),
                const Text('退出登录会清除本机的登录会话，NAS 服务不会停止。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              _go(context, NetworkDiagnosticsPage(api: api));
            },
            icon: const Icon(Icons.speed_rounded),
            label: const Text('测试当前连接'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _identityCard(BuildContext context, bool isAdmin) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final badgeColor = isAdmin
        ? const Color(0xFF007AFF)
        : const Color(0xFF34C759);
    final accentGrad = isAdmin
        ? const [Color(0xFF007AFF), Color(0xFF5856D6)]
        : const [Color(0xFF34C759), Color(0xFF30B0C7)];

    return IsleSurface(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow =
              constraints.maxWidth < 560 ||
              MediaQuery.textScalerOf(context).scale(14) > 17;

          final avatar = IsleSquircleBadge(
            icon: isAdmin
                ? Icons.admin_panel_settings_rounded
                : Icons.person_rounded,
            color: badgeColor,
            gradient: accentGrad,
            shadow: true,
            size: 40,
            iconSize: 21,
            iconColor: Colors.white,
          );

          final profileInfo = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      identity['username']?.toString() ?? '当前账号',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(
                          alpha: isDark ? 0.25 : 0.12,
                        ),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: badgeColor.withValues(
                            alpha: isDark ? 0.35 : 0.22,
                          ),
                          width: 0.75,
                        ),
                      ),
                      child: Text(
                        isAdmin ? '家庭管理员' : '家庭成员',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: badgeColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  isAdmin ? '家庭管理员 · 可管理成员与存储' : '家庭成员 · 仅管理自己的内容',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          );

          final connectionPill = Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _showConnection(context),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth > 0
                      ? constraints.maxWidth
                      : double.infinity,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : colors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : colors.primary.withValues(alpha: 0.18),
                    width: 0.75,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lan_outlined, size: 15.5, color: colors.primary),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '连接详情',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

          final errorColor = colors.error;
          final logoutPill = Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _confirmLogout(context),
              hoverColor: errorColor.withValues(alpha: 0.08),
              splashColor: errorColor.withValues(alpha: 0.16),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth > 0
                      ? constraints.maxWidth
                      : double.infinity,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? errorColor.withValues(alpha: 0.14)
                      : const Color(0xFFFFECEB),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: errorColor.withValues(alpha: isDark ? 0.35 : 0.22),
                    width: 0.75,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.logout_rounded,
                      size: 15.5,
                      color: errorColor,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '退出登录 / 切换服务器',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: errorColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [avatar, const SizedBox(width: 10), profileInfo]),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 6,
                  children: [connectionPill, logoutPill],
                ),
              ],
            );
          }

          return Row(
            children: [
              avatar,
              const SizedBox(width: 12),
              profileInfo,
              const SizedBox(width: 12),
              connectionPill,
              const SizedBox(width: 8),
              logoutPill,
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final userId = identity['id'];
    final canClear = userId is int && userId > 0;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: Text(
          '下次连接需要重新输入密码。'
          '${(pendingUploads?.call() ?? 0) > 0 ? '当前仍有 ${pendingUploads!()} 个上传任务未结束；退出后传输将暂停，重新登录时可尝试断点续传。' : ''}'
          '${canClear ? '你可以保留离线照片和影片，或清理当前服务器、账号和存储位置的两种本地副本；其他硬盘位置的副本需分别清理。NAS 原始文件不会删除。' : '本客户端无法确认稳定账号 ID，已保存的本地文件不会自动删除。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'keep'),
            child: const Text('保留离线文件并退出'),
          ),
          if (canClear)
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'clear'),
              child: const Text('清理当前离线库并退出'),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'clear') {
      try {
        await OfflineVideoStore(api: api, accountName: 'uid:$userId').clear();
        await OfflinePhotoStore(api: api, accountId: 'uid:$userId').clear();
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '本机离线副本尚未全部清理，已完成部分可能不再存在；未退出，请重新尝试：${userFacingError(error)}',
              ),
            ),
          );
        }
        return;
      }
    }
    await onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = identity['role'] == 'admin';

    final familyAndStorageSection = _section(
      context,
      title: '家庭与存储',
      index: 0,
      entries: [
        _entry(
          context,
          icon: Icons.people_alt_rounded,
          title: '账号与目录授权',
          subtitle: '成员、目录与读写权限',
          color: const Color(0xFF007AFF),
          onTap: () => _go(
            context,
            AccountsPage(
              api: api,
              currentUsername: identity['username']?.toString(),
            ),
          ),
        ),
        _entry(
          context,
          icon: Icons.storage_rounded,
          title: '存储与成员配额',
          subtitle: '逐盘配置空间与容量',
          color: const Color(0xFF34C759),
          onTap: () => _go(context, StoragePage(api: api, isAdmin: true)),
        ),
        _entry(
          context,
          icon: Icons.notifications_active_outlined,
          title: '存储与任务通知',
          subtitle: '磁盘、备份与后台任务',
          color: const Color(0xFFFF3B30),
          onTap: () => _go(
            context,
            AdminActivityPage(api: api, kind: AdminActivity.alerts),
          ),
        ),
        _entry(
          context,
          icon: Icons.monitor_heart_outlined,
          title: '设备诊断与 Key 状态',
          subtitle: '性能历史、网卡、磁盘 SMART 和第三方配置状态',
          color: const Color(0xFF5856D6),
          onTap: () => _go(context, AdminDiagnosticsPage(api: api)),
        ),
      ],
    );

    final mySpaceSection = _section(
      context,
      title: '我的空间',
      index: 0,
      entries: [
        _entry(
          context,
          icon: Icons.storage_rounded,
          title: '我的存储空间',
          subtitle: '查看各硬盘额度及已计用量',
          color: const Color(0xFF34C759),
          onTap: () => _go(context, StoragePage(api: api, isAdmin: false)),
        ),
      ],
    );

    final filesAndConnectionSection = _section(
      context,
      title: '文件与连接',
      index: 1,
      entries: [
        _entry(
          context,
          icon: Icons.speed_rounded,
          title: '连接测速',
          subtitle: '延迟、上下行速度与 NAS 连接稳定性',
          color: const Color(0xFF30B0C7),
          onTap: () => _go(context, NetworkDiagnosticsPage(api: api)),
        ),
        _entry(
          context,
          icon: Icons.downloading_rounded,
          title: '下载中心',
          subtitle: '离线下载、进度和任务',
          color: const Color(0xFF007AFF),
          onTap: () => _go(context, DownloadsPage(api: api)),
        ),
        _entry(
          context,
          icon: Icons.link_rounded,
          title: '我的文件分享',
          subtitle: '查看及撤销分享链接',
          color: const Color(0xFFFF9500),
          onTap: () => _go(context, FileSharesPage(api: api)),
        ),
        _entry(
          context,
          icon: Icons.folder_shared_rounded,
          title: 'WebDAV 访问',
          subtitle: '通过独立密码连接设备',
          color: const Color(0xFFAF52DE),
          onTap: () => _go(
            context,
            DavPage(api: api, accountId: identity['id']?.toString()),
          ),
        ),
      ],
    );

    final accountSecuritySection = _section(
      context,
      title: '账号与安全',
      index: 2,
      entries: [
        _entry(
          context,
          icon: Icons.folder_off_outlined,
          title: isAdmin ? '缺失媒体与资料' : '我的缺失媒体',
          subtitle: '检查找不到的照片、影视及保留的资料',
          color: const Color(0xFFFF9500),
          onTap: () => _go(context, MissingMediaPage(api: api, isAdmin: isAdmin)),
        ),
        _entry(
          context,
          icon: Icons.security_rounded,
          title: '密码与登录会话',
          subtitle: '改密、管理已登录设备',
          color: const Color(0xFFFF9500),
          onTap: () => _go(
            context,
            AccountSecurityPage(api: api, onSignedOut: onLogout),
          ),
        ),
        if (isAdmin)
          _entry(
            context,
            icon: Icons.terminal_rounded,
            title: '本机脚本自动化',
            subtitle: '定时调度本地脚本、通知渠道与执行日志',
            color: const Color(0xFF10B981),
            onTap: () => _go(context, AutomationPage(api: api)),
          ),
        if (isAdmin)
          _entry(
            context,
            icon: Icons.policy_outlined,
            title: '安全审计',
            subtitle: '查看管理员操作记录',
            color: const Color(0xFF8E8E93),
            onTap: () => _go(
              context,
              AdminActivityPage(api: api, kind: AdminActivity.audit),
            ),
          ),
        if (isAdmin)
          _entry(
            context,
            icon: Icons.cloud_upload_rounded,
            title: '上传维护',
            subtitle: '处理残留与过期上传',
            color: const Color(0xFF007AFF),
            onTap: () => _go(context, UploadMaintenancePage(api: api)),
          ),
      ],
    );

    const helpDisclosure = IsleHelpDisclosure(
      summary: '关于 LightIsle 客户端与数据',
      details:
          'Mac 原生管理端负责运行 NAS、存储权限和配置恢复。'
          '关闭这个客户端不会停止 NAS；原始文件需要通过 Time Machine 或其他工具备份。',
    );

    final aboutAndDataSection = IsleAnimatedEntrance(
      delay: const Duration(milliseconds: 105),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const IsleSectionHeader(
            title: '关于与数据说明',
            padding: EdgeInsets.fromLTRB(6, 12, 6, 6),
          ),
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              IsleGroupTile(
                icon: Icons.auto_awesome_rounded,
                iconBgColor: const Color(0xFF5856D6),
                title: '关于轻屿 LightIsle',
                subtitle: 'GitHub 源码仓库、非商业许可与开发信息',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF238636).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: const Color(0xFF238636).withValues(alpha: 0.4),
                          width: 0.7,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.code_rounded, size: 11, color: Color(0xFF238636)),
                          SizedBox(width: 3),
                          Text(
                            'GitHub',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF238636),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right_rounded, size: 20),
                  ],
                ),
                onTap: () => _go(context, const AboutPage()),
              ),
            ],
          ),
          const SizedBox(height: 8),
          helpDisclosure,
        ],
      ),
    );

    final versionFooter = Text(
      '轻屿 LightIsle · Flutter 开发预览 0.1.0',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant
            .withValues(alpha: 0.7),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final isWide = availableWidth >= 600 && textScale <= 1.35;

        final Widget contentLayout;
        if (isWide) {
          contentLayout = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isAdmin) familyAndStorageSection,
                    if (!isAdmin) ...[
                      mySpaceSection,
                      const SizedBox(height: 6),
                      accountSecuritySection,
                    ],
                    if (isAdmin) ...[
                      const SizedBox(height: 6),
                      accountSecuritySection,
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    filesAndConnectionSection,
                    const SizedBox(height: 6),
                    aboutAndDataSection,
                  ],
                ),
              ),
            ],
          );
        } else {
          contentLayout = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isAdmin) familyAndStorageSection,
              if (!isAdmin) mySpaceSection,
              filesAndConnectionSection,
              accountSecuritySection,
              const SizedBox(height: 4),
              aboutAndDataSection,
            ],
          );
        }

        return IsleListView(
          maxWidth: isWide ? 1080 : IsleLayout.settingsWidth,
          children: [
            IslePageHeader(
              title: '设置',
              hideSubtitleOnCompact: true,
              subtitle: isAdmin ? '家庭管理、存储权限与服务维护' : '个人空间、连接与账号安全',
              icon: Icons.tune_rounded,
            ),
            _identityCard(context, isAdmin),
            const SizedBox(height: 6),
            contentLayout,
            const SizedBox(height: 20),
            versionFooter,
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}
