import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/offline_file_store.dart';
import '../media/offline_photo_store.dart';
import '../media/offline_video_store.dart';
import 'network_diagnostics_page.dart';

/// Account summary card displayed at the top (mobile/tablet) or left rail
/// (desktop) of `SettingsPage`.
class SettingsIdentityCard extends StatelessWidget {
  const SettingsIdentityCard({
    super.key,
    required this.api,
    required this.identity,
    required this.isAdmin,
    this.verticalCard = false,
    required this.onShowConnection,
    required this.onSwitchAccount,
    required this.onLogout,
  });

  final LightIsleApi api;
  final Map<String, dynamic> identity;
  final bool isAdmin;
  final bool verticalCard;
  final VoidCallback onShowConnection;
  final VoidCallback onSwitchAccount;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final badgeColor = isAdmin ? palette['brandViolet'] : palette['brandBlue'];

    final avatar = IsleSquircleBadge(
      icon: isAdmin ? Icons.admin_panel_settings_rounded : Icons.person_rounded,
      color: badgeColor,
      size: verticalCard ? 46 : 40,
      iconSize: verticalCard ? 22 : 19,
    );

    final connectionPill = IslePillButton(
      label: '连接详情',
      icon: Icons.lan_outlined,
      variant: IslePillVariant.tonal,
      compact: true,
      onPressed: onShowConnection,
    );

    final switchAccountPill = IslePillButton(
      key: const Key('settingsSwitchAccountButton'),
      label: '切换账号',
      icon: Icons.swap_horiz_rounded,
      variant: IslePillVariant.tonal,
      compact: true,
      onPressed: onSwitchAccount,
    );

    final logoutPill = IslePillButton(
      label: '退出登录 / 切换服务器',
      icon: Icons.logout_rounded,
      variant: IslePillVariant.danger,
      compact: true,
      onPressed: onLogout,
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
}

void showSettingsConnectionDialog(
  BuildContext context, {
  required LightIsleApi api,
  required Future<void> Function() onOpenAccountSwitcher,
}) {
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
            unawaited(onOpenAccountSwitcher());
          },
          icon: const Icon(Icons.alt_route_rounded),
          label: const Text('多地址与选线'),
        ),
        TextButton.icon(
          onPressed: () {
            Navigator.pop(dialogContext);
            Navigator.of(context).push(
              buildIslePageRoute<void>(
                builder: (_) => NetworkDiagnosticsPage(api: api),
              ),
            );
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

Future<void> confirmSettingsLogout(
  BuildContext context, {
  required LightIsleApi api,
  required Map<String, dynamic> identity,
  required Future<void> Function() onLogout,
  int Function()? pendingUploads,
}) async {
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
        '${canClear ? '你可以保留离线照片、影片与文件，或清理当前服务器、账号和存储位置的全部本地离线副本；其他硬盘位置的副本需分别清理。NAS 原始文件不会删除。' : '本客户端无法确认稳定账号 ID，已保存的本地文件不会自动删除。'}',
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
      await OfflineFileStore(api: api, accountIdentity: 'uid:$userId').clear();
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
