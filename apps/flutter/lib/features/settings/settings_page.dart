import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/login_history_store.dart';
import '../../core/widgets.dart';
import '../auth/login_history_section.dart';
import '../files/desktop_backup_engine.dart';
import '../files/downloads_page.dart';
import '../files/file_shares_page.dart';
import '../media/cinema_decode_preference.dart';
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
import 'settings_identity_card.dart';
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

  Widget _identityCard(
    BuildContext context,
    bool isAdmin, {
    bool verticalCard = false,
  }) => SettingsIdentityCard(
    api: api,
    identity: identity,
    isAdmin: isAdmin,
    verticalCard: verticalCard,
    onShowConnection: () => showSettingsConnectionDialog(
      context,
      api: api,
      onOpenAccountSwitcher: () => _openAccountSwitcher(context),
    ),
    onSwitchAccount: () => unawaited(_openAccountSwitcher(context)),
    onLogout: () => unawaited(
      confirmSettingsLogout(
        context,
        api: api,
        identity: identity,
        onLogout: onLogout,
        pendingUploads: pendingUploads,
      ),
    ),
  );

  Future<void> _openAccountSwitcher(BuildContext context) async {
    await showAccountSwitcherDialog(
      context: context,
      currentServer: api.uri('/').origin,
      currentUsername: identity['username']?.toString() ?? '',
      historyStore: historyStore ?? LoginHistoryStore(),
      onSwitchAccount: onSwitchAccount ?? (_, _) => onLogout(),
      onUseNewAccount: () => confirmSettingsLogout(
        context,
        api: api,
        identity: identity,
        onLogout: onLogout,
        pendingUploads: pendingUploads,
      ),
      pendingUploads: pendingUploads,
      latencyProber: latencyProber,
      apiFactory: switchApiFactory,
    );
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

  String get _canonicalAccountId =>
      identity['id'] is int && (identity['id'] as int) > 0
      ? 'uid:${identity['id']}'
      : '';

  Widget _buildResponsiveSectionsLayout(
    BuildContext context, {
    required bool isAdmin,
    required bool isWide,
  }) {
    final primarySpaceSection = isAdmin
        ? _buildFamilyAndStorageSection(context, foldSmbIntoRemoteOps: !isWide)
        : _buildMySpaceSection(context);
    final appearanceSection = _buildAppearanceSection(context);
    final filesSection = _buildFilesAndConnectionSection(
      context,
      isAdmin: isAdmin,
    );
    final securitySection = _buildAccountSecuritySection(context);
    final aboutSection = _buildAboutAndDataSection(context);
    final troubleshootingSection = isAdmin
        ? AdminTroubleshootingSection(
            onOpenSmb: !isWide
                ? () => _go(context, AdminSmbPage(api: api))
                : null,
            onOpenAutomation: () => _go(context, AutomationPage(api: api)),
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

  Widget _buildFamilyAndStorageSection(
    BuildContext context, {
    required bool foldSmbIntoRemoteOps,
  }) {
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
              currentAccountId:
                  _canonicalAccountId.isEmpty ? null : _canonicalAccountId,
            ),
          ),
        ),
        _entry(
          context,
          icon: Icons.storage_rounded,
          color: amber,
          title: '存储与成员配额',
          onTap: () => _go(
            context,
            StoragePage(
              api: api,
              isAdmin: true,
              accountId:
                  _canonicalAccountId.isEmpty ? null : _canonicalAccountId,
            ),
          ),
        ),
        if (!foldSmbIntoRemoteOps)
          _entry(
            context,
            icon: Icons.folder_shared_rounded,
            color: palette['brandSage'],
            title: 'Mac 文件共享 (SMB)',
            onTap: () => _go(context, AdminSmbPage(api: api)),
          ),
        _entry(
          context,
          icon: Icons.folder_off_outlined,
          color: palette['brandRose'],
          title: '缺失媒体与资料',
          onTap: () => _go(context, MissingMediaPage(api: api, isAdmin: true)),
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
          onTap: () => _go(
            context,
            StoragePage(
              api: api,
              isAdmin: false,
              accountId:
                  _canonicalAccountId.isEmpty ? null : _canonicalAccountId,
            ),
          ),
        ),
        _entry(
          context,
          icon: Icons.folder_off_outlined,
          color: palette['brandRose'],
          title: '我的缺失媒体',
          onTap: () => _go(context, MissingMediaPage(api: api, isAdmin: false)),
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
              accountId: _canonicalAccountId,
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
            DavPage(
              api: api,
              accountId:
                  _canonicalAccountId.isEmpty ? null : _canonicalAccountId,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountSecuritySection(BuildContext context) {
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
                onTap: () => _go(context, AboutPage(api: api)),
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
