import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/login_history_store.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../auth/login_history_section.dart';
import '../files/desktop_backup_engine.dart';
import '../files/downloads_page.dart';
import '../files/file_shares_page.dart';
import '../media/cinema_decode_preference.dart';
import '../media/offline_photo_store.dart';
import '../media/offline_video_store.dart';
import 'about_page.dart';
import 'account_security_page.dart';
import 'accounts_page.dart';
import 'admin_activity_page.dart';
import 'admin_diagnostics_page.dart';
import 'admin_smb_page.dart';
import 'appearance_page.dart';
import 'apps_center_page.dart';
import 'automation_page.dart';
import 'beta_diagnostic_report.dart';
import 'cache_management_page.dart';
import 'dav_page.dart';
import 'missing_media_page.dart';
import 'network_diagnostics_page.dart';
import 'settings_backup_entries.dart';
import 'settings_troubleshooting_section.dart';
import 'storage_page.dart';
import 'upload_maintenance_page.dart';

export 'about_page.dart';
export 'appearance_page.dart';
export 'accounts_page.dart';
export 'admin_smb_page.dart';
export 'apps_center_page.dart';
export 'automation_page.dart';
export 'cache_management_page.dart';
export 'grants_page.dart';
export 'upload_maintenance_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.identity,
    required this.onLogout,
    this.pendingUploads,
    this.historyStore,
    this.latencyProber,
    this.onSwitchAccount,
    this.desktopBackupController,
    @visibleForTesting this.switchApiFactory,
  });

  final LightIsleApi api;
  final Map<String, dynamic> identity;
  final Future<void> Function() onLogout;

  /// Read on demand to avoid displaying stale counts in an open settings tab.
  final int Function()? pendingUploads;
  final LoginHistoryStore? historyStore;
  final ServerLatencyProber? latencyProber;
  final FutureOr<void> Function(LightIsleApi, Map<String, dynamic>)?
  onSwitchAccount;
  final DesktopBackupController? desktopBackupController;
  @visibleForTesting
  final LightIsleApi Function(
    String serverUrl, {
    String? certificateFingerprint,
  })?
  switchApiFactory;

  void _go(BuildContext context, Widget page) {
    Navigator.of(context).push(buildIslePageRoute<void>(builder: (_) => page));
  }

  Widget _entry(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required VoidCallback onTap,
  }) => IsleGroupTile(
    icon: icon,
    iconBgColor: color,
    title: title,
    onTap: onTap,
  );

  Widget _section(
    BuildContext context, {
    required String title,
    required Color accentColor,
    required int index,
    required List<Widget> entries,
  }) => IsleAnimatedEntrance(
    delay: Duration(milliseconds: 30 * index),
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IsleSectionHeader(
            title: title,
            accentColor: accentColor,
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 7),
          ),
          IsleGroupCard(margin: EdgeInsets.zero, children: entries),
        ],
      ),
    ),
  );

  void _showConnection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        title: const Text('连接详情'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
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
                const SizedBox(height: 12),
                const Text('退出登录仅清除本机会话，不会停止 Mac 端服务。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            key: const Key('connectionMultiAddressButton'),
            onPressed: () {
              Navigator.pop(dialogContext);
              unawaited(_openAccountSwitcher(context));
            },
            icon: const Icon(Icons.alt_route_rounded),
            label: const Text('多地址与选线'),
          ),
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

  Widget _identityCard(
    BuildContext context,
    bool isAdmin, {
    bool verticalCard = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final badgeColor = isAdmin
        ? palette['brandViolet']
        : palette['brandBlue'];

    final avatar = IsleSquircleBadge(
      icon: isAdmin
          ? Icons.admin_panel_settings_rounded
          : Icons.person_rounded,
      color: badgeColor,
      size: verticalCard ? 46 : 40,
      iconSize: verticalCard ? 22 : 19,
    );

    final connectionPill = IslePillButton(
      label: '连接详情',
      icon: Icons.lan_outlined,
      variant: IslePillVariant.tonal,
      compact: true,
      onPressed: () => _showConnection(context),
    );

    final switchAccountPill = IslePillButton(
      key: const Key('settingsSwitchAccountButton'),
      label: '切换账号',
      icon: Icons.swap_horiz_rounded,
      variant: IslePillVariant.tonal,
      compact: true,
      onPressed: () => _openAccountSwitcher(context),
    );

    final logoutPill = IslePillButton(
      label: '退出登录 / 切换服务器',
      icon: Icons.logout_rounded,
      variant: IslePillVariant.danger,
      compact: true,
      onPressed: () => _confirmLogout(context),
    );

    if (verticalCard) {
      return IsleSurface(
        radius: IsleRadius.hero,
        tint: badgeColor,
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                avatar,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        identity['username']?.toString() ?? '当前账号',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      IsleStatusBadge(
                        label: isAdmin ? '家庭管理员' : '家庭成员',
                        color: badgeColor,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: IsleDecorations.recessedWell(context, radius: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 15,
                    color: palette['brandSage'],
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      api.uri('/').origin,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [connectionPill, switchAccountPill, logoutPill],
            ),
          ],
        ),
      );
    }

    return IsleSurface(
      radius: IsleRadius.hero,
      tint: badgeColor,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow =
              constraints.maxWidth < 560 ||
              MediaQuery.textScalerOf(context).scale(14) > 17;

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
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        letterSpacing: -0.25,
                      ),
                    ),
                    IsleStatusBadge(
                      label: isAdmin ? '家庭管理员' : '家庭成员',
                      color: badgeColor,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  api.uri('/').origin,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colors.onSurfaceVariant,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          );

          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [avatar, const SizedBox(width: 12), profileInfo]),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 6,
                  children: [connectionPill, switchAccountPill, logoutPill],
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
              switchAccountPill,
              const SizedBox(width: 8),
              logoutPill,
            ],
          );
        },
      ),
    );
  }

  Future<void> _openAccountSwitcher(BuildContext context) async {
    await showAccountSwitcherDialog(
      context: context,
      currentServer: api.uri('/').origin,
      currentUsername: identity['username']?.toString() ?? '',
      historyStore: historyStore ?? LoginHistoryStore(),
      onSwitchAccount: onSwitchAccount ?? (_, _) => onLogout(),
      onUseNewAccount: () => _confirmLogout(context),
      pendingUploads: pendingUploads,
      latencyProber: latencyProber,
      apiFactory: switchApiFactory,
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final userId = identity['id'];
    final canClear = userId is int && userId > 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
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
    final palette = IslePalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final isDesktop = constraints.maxWidth >= 980 && textScale <= 1.35;
        final isTablet =
            !isDesktop && constraints.maxWidth >= 600 && textScale <= 1.35;

        return IsleListView(
          maxWidth: isDesktop || isTablet
              ? IsleLayout.workbenchMaxWidth
              : IsleLayout.settingsWidth,
          children: [
            IslePageHeader(
              accentColor: palette['brandViolet'],
              title: '设置',
            ),
            const SizedBox(height: 6),
            if (isDesktop) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 296,
                    child: _identityCard(context, isAdmin, verticalCard: true),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: _buildResponsiveSectionsLayout(
                      context,
                      isAdmin: isAdmin,
                      isWide: true,
                    ),
                  ),
                ],
              ),
            ] else ...[
              _identityCard(context, isAdmin),
              const SizedBox(height: 6),
              _buildResponsiveSectionsLayout(
                context,
                isAdmin: isAdmin,
                isWide: isTablet,
              ),
            ],
            const SizedBox(height: 20),
            _buildVersionFooter(context),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Widget _buildResponsiveSectionsLayout(
    BuildContext context, {
    required bool isAdmin,
    required bool isWide,
  }) {
    final primarySpaceSection = isAdmin
        ? _buildFamilyAndStorageSection(context)
        : _buildMySpaceSection(context);
    final appearanceSection = _buildAppearanceSection(context);
    final filesSection = _buildFilesAndConnectionSection(
      context,
      isAdmin: isAdmin,
    );
    final securitySection = _buildAccountSecuritySection(
      context,
      isAdmin: isAdmin,
    );
    final aboutSection = _buildAboutAndDataSection(context);
    final troubleshootingSection = isAdmin
        ? AdminTroubleshootingSection(
            onOpenDiagnostics: () =>
                _go(context, AdminDiagnosticsPage(api: api)),
            onOpenAudit: () => _go(
              context,
              AdminActivityPage(api: api, kind: AdminActivity.audit),
            ),
            onOpenUploadMaintenance: () =>
                _go(context, UploadMaintenancePage(api: api)),
          )
        : null;

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                primarySpaceSection,
                const SizedBox(height: 6),
                appearanceSection,
                const SizedBox(height: 6),
                securitySection,
                if (troubleshootingSection != null) ...[
                  const SizedBox(height: 6),
                  troubleshootingSection,
                ],
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [filesSection, const SizedBox(height: 6), aboutSection],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        primarySpaceSection,
        appearanceSection,
        filesSection,
        securitySection,
        if (troubleshootingSection != null) ...[
          const SizedBox(height: 6),
          troubleshootingSection,
        ],
        const SizedBox(height: 4),
        aboutSection,
      ],
    );
  }

  Widget _buildAppearanceSection(BuildContext context) {
    final palette = IslePalette.of(context);
    final style = IsleThemeStyle.of(context);
    final accent = palette['accentSecondary'];
    return IsleAnimatedEntrance(
      delay: const Duration(milliseconds: 20),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IsleSectionHeader(
              title: '外观与显示',
              accentColor: accent,
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 7),
            ),
            IsleGroupCard(
              margin: EdgeInsets.zero,
              children: [
                IsleGroupTile(
                  key: const Key('settingsAppearanceTile'),
                  icon: Icons.palette_outlined,
                  iconBgColor: accent,
                  title: '外观与主题',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IsleBadgePill(
                        label: style.preset.displayName,
                        color: palette['accentPrimary'],
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
                  onTap: () => _go(context, const AppearancePage()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFamilyAndStorageSection(BuildContext context) {
    final palette = IslePalette.of(context);
    final amber = palette['brandAmber'];
    return _section(
      context,
      title: '家庭与存储',
      accentColor: amber,
      index: 0,
      entries: [
        _entry(
          context,
          icon: Icons.people_alt_rounded,
          color: palette['brandBlue'],
          title: '账号与目录授权',
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
          color: amber,
          title: '存储与成员配额',
          onTap: () => _go(context, StoragePage(api: api, isAdmin: true)),
        ),
        _entry(
          context,
          icon: Icons.folder_shared_rounded,
          color: palette['brandSage'],
          title: 'Mac 文件共享 (SMB)',
          onTap: () => _go(context, AdminSmbPage(api: api)),
        ),
        _entry(
          context,
          icon: Icons.notifications_active_outlined,
          color: palette['brandTerracotta'],
          title: '存储与任务通知',
          onTap: () => _go(
            context,
            AdminActivityPage(api: api, kind: AdminActivity.alerts),
          ),
        ),
      ],
    );
  }

  Widget _buildMySpaceSection(BuildContext context) {
    final palette = IslePalette.of(context);
    final amber = palette['brandAmber'];
    return _section(
      context,
      title: '我的空间',
      accentColor: amber,
      index: 0,
      entries: [
        _entry(
          context,
          icon: Icons.storage_rounded,
          color: amber,
          title: '我的存储空间',
          onTap: () => _go(context, StoragePage(api: api, isAdmin: false)),
        ),
      ],
    );
  }

  Widget _buildFilesAndConnectionSection(
    BuildContext context, {
    required bool isAdmin,
  }) {
    final palette = IslePalette.of(context);
    final mineral = palette['brandBlue'];
    final backupEntry = buildPlatformBackupSettingsEntry(
      context,
      api: api,
      identity: identity,
      desktopBackupController: desktopBackupController,
    );
    return _section(
      context,
      title: '文件与连接',
      accentColor: mineral,
      index: 1,
      entries: [
        ?backupEntry,
        _entry(
          context,
          icon: Icons.apps_rounded,
          color: palette['brandViolet'],
          title: '应用中心',
          onTap: () => _go(context, AppsCenterPage(api: api, isAdmin: isAdmin)),
        ),
        _entry(
          context,
          icon: Icons.speed_rounded,
          color: mineral,
          title: '连接测速',
          onTap: () => _go(context, NetworkDiagnosticsPage(api: api)),
        ),
        _entry(
          context,
          icon: Icons.downloading_rounded,
          color: palette['brandAmber'],
          title: '下载中心',
          onTap: () => _go(context, DownloadsPage(api: api)),
        ),
        _entry(
          context,
          icon: Icons.smart_display_rounded,
          color: palette['brandTerracotta'],
          title: '影视播放与本地解码',
          onTap: () => unawaited(showCinemaDecodeSettingsDialog(context)),
        ),
        _entry(
          context,
          icon: Icons.link_rounded,
          color: palette['brandRose'],
          title: '我的文件分享',
          onTap: () => _go(context, FileSharesPage(api: api)),
        ),
        _entry(
          context,
          icon: Icons.cleaning_services_rounded,
          color: palette['brandSage'],
          title: '缓存与本地存储管理',
          onTap: () => _go(
            context,
            CacheManagementPage(
              api: api,
              isAdmin: isAdmin,
              accountId: identity['id'] is int && (identity['id'] as int) > 0
                  ? 'uid:${identity['id']}'
                  : '',
            ),
          ),
        ),
        _entry(
          context,
          icon: Icons.folder_shared_rounded,
          color: mineral,
          title: 'WebDAV 访问',
          onTap: () => _go(
            context,
            DavPage(api: api, accountId: identity['id']?.toString()),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountSecuritySection(
    BuildContext context, {
    required bool isAdmin,
  }) {
    final palette = IslePalette.of(context);
    final sage = palette['brandSage'];
    return _section(
      context,
      title: '账号与安全',
      accentColor: sage,
      index: 2,
      entries: [
        _entry(
          context,
          icon: Icons.folder_off_outlined,
          color: palette['brandRose'],
          title: isAdmin ? '缺失媒体与资料' : '我的缺失媒体',
          onTap: () =>
              _go(context, MissingMediaPage(api: api, isAdmin: isAdmin)),
        ),
        _entry(
          context,
          icon: Icons.security_rounded,
          color: sage,
          title: '密码与登录会话',
          onTap: () => _go(
            context,
            AccountSecurityPage(
              api: api,
              onSignedOut: onLogout,
              currentUsername: identity['username']?.toString(),
              historyStore: historyStore,
            ),
          ),
        ),
        if (isAdmin)
          _entry(
            context,
            icon: Icons.terminal_rounded,
            color: palette['brandTerracotta'],
            title: '本机脚本自动化',
            onTap: () => _go(context, AutomationPage(api: api)),
          ),
      ],
    );
  }

  Widget _buildAboutAndDataSection(BuildContext context) {
    final palette = IslePalette.of(context);
    final plum = palette['brandViolet'];
    return IsleAnimatedEntrance(
      delay: const Duration(milliseconds: 90),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IsleSectionHeader(
            title: '关于',
            accentColor: plum,
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 7),
          ),
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              IsleGroupTile(
                icon: Icons.auto_awesome_rounded,
                iconBgColor: plum,
                title: '关于轻屿 LightIsle',
                trailing: _buildGithubBadgeTrailing(palette),
                onTap: () => _go(context, const AboutPage()),
              ),
              IsleGroupTile(
                icon: Icons.bug_report_outlined,
                iconBgColor: palette['brandBlue'],
                title: 'Beta 故障报告',
                onTap: () => showBetaDiagnosticReport(context, api),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGithubBadgeTrailing(IslePalette palette) {
    final sage = palette['brandSage'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: sage.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: sage.withValues(alpha: 0.35), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.code_rounded, size: 11, color: sage),
              const SizedBox(width: 3),
              Text(
                'GitHub',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: sage,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right_rounded, size: 18),
      ],
    );
  }

  Widget _buildVersionFooter(BuildContext context) {
    return Text(
      '轻屿 LightIsle · 0.1.0',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.68),
      ),
    );
  }
}
