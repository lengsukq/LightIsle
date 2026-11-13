import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/personal_storage_routing.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/desktop_backup_engine.dart';
import '../files/desktop_folder_backup_page.dart';
import '../files/mobile_photo_backup_page.dart';
import 'storage_page.dart';

Widget? buildPlatformBackupSettingsEntry(
  BuildContext context, {
  required LightIsleApi api,
  required Map<String, dynamic> identity,
  DesktopBackupController? desktopBackupController,
}) {
  final isAdmin = identity['role'] == 'admin';
  final accountName = identity['username']?.toString() ?? '';
  final rawId = identity['id'];
  final userId = rawId is num
      ? rawId.toInt()
      : int.tryParse(rawId?.toString() ?? '') ?? 0;

  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => IsleGroupTile(
      key: const ValueKey('settingsMobilePhotoBackupTile'),
      icon: Icons.cloud_upload_rounded,
      iconBgColor: Theme.of(context).colorScheme.primary,
      title: '手机相册备份',
      subtitle: '相机原片与原画视频增量备份、iCloud 按需下载与完整性核验',
      onTap: () => _openMobilePhotoBackupFromSettings(
        context,
        api: api,
        accountName: accountName,
        isAdmin: isAdmin,
      ),
    ),
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => IsleGroupTile(
      key: const ValueKey('settingsDesktopFolderBackupTile'),
      icon: Icons.drive_folder_upload_rounded,
      iconBgColor: Theme.of(context).colorScheme.primary,
      title: '本机文件夹备份',
      subtitle: '桌面本地文件夹单向增量备份到 NAS，支持断网续传与安全防丢更新',
      onTap: () {
        Navigator.of(context).push(
          buildIslePageRoute<void>(
            builder: (_) => DesktopFolderBackupPage(
              api: api,
              userId: userId,
              accountName: accountName,
              isAdmin: isAdmin,
              controller: desktopBackupController,
            ),
          ),
        );
      },
    ),
    _ => null,
  };
}

Future<void> _openMobilePhotoBackupFromSettings(
  BuildContext context, {
  required LightIsleApi api,
  required String accountName,
  required bool isAdmin,
}) async {
  PersonalStorageRoute route;
  try {
    final rootsResp = await api.get('/api/v2/roots');
    final rawRoots = rootsResp['roots'];
    final roots = rawRoots is List
        ? rawRoots
              .whereType<Map>()
              .map((m) => LightIsleRoot.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
        : const <LightIsleRoot>[];
    final policy = await api.get('/api/v2/me/storage');
    route = resolvePersonalRoute(policy, roots, 'photos');
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法读取个人照片备份目录：${userFacingError(error)}')),
      );
    }
    return;
  }

  if (!context.mounted) return;
  if (route.kind != PersonalRouteKind.personal ||
      route.root == null ||
      route.path == null) {
    final offline = route.kind == PersonalRouteKind.offline;
    final openStorage = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(offline ? '个人照片硬盘当前离线' : '尚未分配个人照片空间'),
        content: Text(
          offline
              ? '当前账号照片分类绑定的物理硬盘未连接或代际已变更。为保护原片不串盘，备份已暂停，请检查硬盘连接或前往存储空间核对。'
              : '开启手机相册原片备份前，需要先在「存储空间」中为当前账号绑定在线的个人照片目录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('前往存储空间'),
          ),
        ],
      ),
    );
    if (openStorage == true && context.mounted) {
      await Navigator.of(context).push(
        buildIslePageRoute<void>(
          builder: (_) => StoragePage(api: api, isAdmin: isAdmin),
        ),
      );
    }
    return;
  }

  final snapshot = api.sessionSnapshot;
  LightIsleApi? isolated;
  final prevRoot = api.selectedRoot;
  final LightIsleApi backupApi;
  if (snapshot != null) {
    isolated = LightIsleApi.fromSessionSnapshot(snapshot)
      ..selectRoot(route.root);
    backupApi = isolated;
  } else {
    api.selectRoot(route.root);
    backupApi = api;
  }

  try {
    await Navigator.of(context).push(
      buildIslePageRoute<void>(
        builder: (_) => MobilePhotoBackupPage(
          api: backupApi,
          accountName: accountName,
          baseDirectory: route.path!,
        ),
      ),
    );
  } finally {
    if (isolated != null) {
      isolated.close();
    } else {
      api.selectRoot(prevRoot);
    }
  }
}
