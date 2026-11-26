import 'package:flutter/material.dart';

import '../../core/widgets.dart';
import 'mobile_photo_backup_controller.dart';
import 'mobile_photo_backup_failure_store.dart';
import 'photo_backup_prefs_schema.dart';

Future<void> showMobilePhotoBackupPendingFailuresDialog(
  BuildContext context,
  MobilePhotoBackupController controller,
) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final borderColor = IsleGlass.rimBorderColor(isDark);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final failures = controller.progress.failureDetails;
        final visibleCount = controller.progress.visibleFailureCount;
        final visible = failures.take(visibleCount).toList(growable: false);
        return AlertDialog(
          shape: IsleShapes.card(side: BorderSide(color: borderColor)),
          title: Text('待处理原片（${failures.length} 项）'),
          content: SizedBox(
            width: 440,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0)
                      Divider(height: 1, thickness: 1, color: borderColor),
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        visible[i]['name']?.toString().isNotEmpty == true
                            ? visible[i]['name'].toString()
                            : '未记录名称的原片',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '${photoFailureReasonLabel(visible[i]['reason']?.toString())}'
                        '${visible[i]['id'] == null ? '' : ' · 手机编号 ${visible[i]['id']}'}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                  ],
                  if (failures.length > visibleCount)
                    TextButton(
                      onPressed: controller.showMorePendingFailures,
                      child: const Text('显示更多待处理原片'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton.tonal(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> showMobilePhotoBackupBatchSettingsDialog(
  BuildContext context,
  MobilePhotoBackupController controller,
) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final progress = controller.progress;
        final options = controller.options;
        return AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(color: IsleGlass.rimBorderColor(isDark)),
          ),
          title: const Text('批量与备份记录'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: options.batchPages,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '单次前台检查批量',
                  ),
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('400 张 · 省电模式')),
                    DropdownMenuItem(value: 30, child: Text('1200 张 · 普通批量')),
                    DropdownMenuItem(value: 100, child: Text('4000 张 · 首次补跑')),
                  ],
                  onChanged: progress.busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          controller.setBatchPages(value);
                        },
                ),
                const SizedBox(height: 12),
                IsleKeyValueRow(
                  label: '最近核对',
                  value: _formatEpochTimestamp(progress.lastVerifiedAt),
                ),
                IsleKeyValueRow(
                  label: '最近扫描至末尾',
                  value: _formatEpochTimestamp(progress.lastCompleteAt),
                ),
                const SizedBox(height: 6),
                Text(
                  '大相册首次备份可选 1200 或 4000 张；客户端逐张校验，不会并发读取大量原片。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton.tonal(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('完成'),
            ),
          ],
        );
      },
    ),
  );
}

Future<bool> showMobilePhotoBackupBackgroundConsentDialog(
  BuildContext context,
) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('开启系统后台照片备份？'),
      content: const Text(
        'Android 会在 Wi-Fi 且电量充足时约每 6 小时安排一次任务，具体时间由系统决定。'
        '为使 App 关闭后仍可连接 NAS，当前账号的完整登录会话会使用 Android Keystore 加密保存在本机，'
        '最长保留 7 天；这不是专用的只写备份令牌。推荐使用限制目录权限的 NAS 成员账号。'
        '建议开启 Mac 的 HTTPS：如果使用 LAN HTTP，尽管会话在手机本机加密保存，网络传输仍不加密。'
        '退出登录、关闭后台备份或会话失效后会移除该授权。照片不会从手机删除。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('同意并开启'),
        ),
      ],
    ),
  );
  return accepted == true;
}

Future<int?> showMobilePhotoAutoReleaseConfirmDialog(
  BuildContext context, {
  required int initialMinAgeDays,
}) {
  var selectedDays =
      PhotoBackupPrefsSchema.autoReleaseMinAgeOptions.contains(
        initialMinAgeDays,
      )
      ? initialMinAgeDays
      : PhotoBackupPrefsSchema.defaultAutoReleaseMinAgeDays;
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('开启备份后自动发起释放确认？'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '开启后，每当本轮照片备份完全无错结束且未取消时，LightIsle 会自动筛选符合下方保留期的已备份条目，逐项在线核对 NAS 硬盘身份与原片 SHA-256，随后拉起系统原生删除确认弹窗。\n\n'
                '受 Android 与 iOS 系统安全机制约束，第三方 App 无法静默删除相册原片——仍需你点一次系统确认，任何校验失败或离线都会自动保留手机原片。',
                style: TextStyle(fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: selectedDays,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '自动筛选保留期',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 30,
                    child: Text('30 天前拍摄（推荐默认）', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: 90,
                    child: Text('90 天前拍摄', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: 7,
                    child: Text('7 天前拍摄', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: 0,
                    child: Text(
                      '不限时间（全部已验证项）',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() => selectedDays = value);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(selectedDays),
            child: const Text('确认开启'),
          ),
        ],
      ),
    ),
  );
}

String _formatEpochTimestamp(int epochMillis) {
  if (epochMillis <= 0) return '尚无';
  return DateTime.fromMillisecondsSinceEpoch(
    epochMillis,
  ).toLocal().toString().substring(0, 16);
}
