import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'mobile_photo_backup_controller.dart';
import 'mobile_photo_backup_state_models.dart';
import 'photo_backup_prefs_schema.dart';

class MobilePhotoBackupPendingFailuresCard extends StatelessWidget {
  const MobilePhotoBackupPendingFailuresCard({
    super.key,
    required this.failureCount,
    required this.icloudPendingCount,
    required this.onTap,
  });

  final int failureCount;
  final int icloudPendingCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final amber = palette['brandAmber'];
    return IsleSurface(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.zero,
      tint: amber,
      onTap: onTap,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
        leading: IsleSquircleBadge(
          icon: Icons.error_outline_rounded,
          color: amber,
          size: 32,
          iconSize: 16.5,
        ),
        title: Text(
          '待处理原片（已记录 $failureCount 项）',
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          icloudPendingCount > 0
              ? '含 $icloudPendingCount 项 iCloud 云端未下载原片 · 点击查看明细'
              : '点击查看未完成原片原因明细',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
      ),
    );
  }
}

class MobilePhotoBackupStatusCard extends StatelessWidget {
  const MobilePhotoBackupStatusCard({super.key, required this.controller});

  final MobilePhotoBackupController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final rose = palette['brandRose'];
    final sage = palette['brandSage'];
    final progress = controller.progress;
    final background = controller.background;

    final progressRatio = progress.checked > 0
        ? ((progress.uploaded + progress.skipped) / progress.checked).clamp(
            0.0,
            1.0,
          )
        : 0.0;

    return IsleSurface(
      margin: EdgeInsets.zero,
      tint: rose,
      radius: IsleRadius.hero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.cloud_sync_rounded,
                color: rose,
                size: 38,
                iconSize: 19,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.isAndroid ? '相册备份状态' : '前台备份状态',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 1.5),
                    Text(
                      '${controller.baseDirectory} · ${controller.albumScopeSummaryLabel}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            progress.message,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.42,
            ),
          ),
          if (progress.checked > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                IsleDonutGauge(
                  fraction: progressRatio,
                  color: sage,
                  size: 34,
                  strokeWidth: 3.3,
                  centerText: '${(progressRatio * 100).round()}%',
                  centerStyle: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '已检查 ${progress.checked} · 新增 ${progress.uploaded} · 跳过 ${progress.skipped}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                      color: sage,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (progress.busy) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 4,
                backgroundColor: colors.outlineVariant.withValues(alpha: 0.25),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.backup_rounded, size: 17),
                label: Text(
                  progress.pageCursor.isEmpty ? '检查并备份最近照片' : '继续上次备份进度',
                ),
                onPressed: progress.busy
                    ? null
                    : () => unawaited(
                        controller.run(older: progress.pageCursor.isNotEmpty),
                      ),
              ),
              if (controller.isAndroid &&
                  background.enabled &&
                  background.sessionMatches)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.sync_rounded, size: 17),
                  label: const Text('立即检查后台备份'),
                  onPressed: progress.busy || background.busy
                      ? null
                      : () => unawaited(controller.requestBackgroundCheck()),
                ),
              if (!progress.busy &&
                  (progress.pageCursor.isNotEmpty ||
                      progress.failureDetails.isNotEmpty))
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => unawaited(controller.run()),
                  child: Text(
                    progress.pageCursor.isEmpty &&
                            progress.failureDetails.isNotEmpty
                        ? '重新检查待处理项'
                        : '从最新照片重新检查',
                  ),
                ),
              if (!progress.busy && progress.nextCursor.isNotEmpty)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: controller.continueOlderPhotos,
                  child: const Text('继续更早的照片'),
                ),
              if (progress.busy)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: controller.pauseRun,
                  child: const Text('暂停'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class MobilePhotoBackupOptionsCard extends StatelessWidget {
  const MobilePhotoBackupOptionsCard({
    super.key,
    required this.controller,
    required this.onConfigureBackground,
    required this.onOpenAlbumPicker,
  });

  final MobilePhotoBackupController controller;
  final Future<void> Function(bool enabled) onConfigureBackground;
  final VoidCallback onOpenAlbumPicker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final rose = palette['brandRose'];
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final progress = controller.progress;
    final options = controller.options;
    final background = controller.background;
    final isCustomAlbumScope =
        options.albumScope == PhotoBackupPrefsSchema.albumScopeSelected ||
        options.albumScope == PhotoBackupPrefsSchema.albumScopeExcluded;

    Widget divider() => Divider(
      height: 1,
      thickness: 1,
      indent: 14,
      endIndent: 14,
      color: borderColor,
    );

    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '备份相册范围',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('selectPhotoAlbumsTile'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        foregroundColor: isCustomAlbumScope
                            ? rose
                            : colors.primary,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: progress.busy ? null : onOpenAlbumPicker,
                      icon: const Icon(
                        Icons.collections_bookmark_outlined,
                        size: 15,
                      ),
                      label: Text(
                        isCustomAlbumScope
                            ? controller.albumScopeSummaryLabel
                            : '指定 / 排除相簿',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  segments: const [
                    ButtonSegment<String>(
                      value: PhotoBackupPrefsSchema.albumScopeCamera,
                      icon: Icon(Icons.camera_alt_outlined, size: 16),
                      label: Text('仅相机拍摄（推荐）'),
                    ),
                    ButtonSegment<String>(
                      value: PhotoBackupPrefsSchema.albumScopeAll,
                      icon: Icon(Icons.photo_library_outlined, size: 16),
                      label: Text('全部手机媒体'),
                    ),
                  ],
                  selected: isCustomAlbumScope
                      ? const <String>{}
                      : {options.albumScope},
                  onSelectionChanged: progress.busy
                      ? null
                      : (selected) {
                          if (selected.isEmpty) return;
                          controller.switchAlbumScope(selected.first);
                        },
                ),
              ],
            ),
          ),
          divider(),
          _BackupOptionSwitch(
            title: '进入此页面或返回前台时自动检查',
            value: options.onForeground,
            onChanged: progress.busy ? null : controller.setOnForeground,
          ),
          divider(),
          _BackupOptionSwitch(
            title: '仅 Wi-Fi 备份',
            value: options.wifiOnly,
            onChanged: progress.busy ? null : controller.setWifiOnly,
          ),
          if (controller.isIOS) ...[
            divider(),
            _BackupOptionSwitch(
              title: 'Wi-Fi 下允许下载 iCloud 原片后备份',
              value: options.allowICloudDownload,
              onChanged: progress.busy
                  ? null
                  : controller.setAllowICloudDownload,
            ),
          ],
          if (controller.isAndroid && controller.isPersonalDestination) ...[
            divider(),
            _BackupOptionSwitch(
              title: '系统后台自动备份（每 6 小时检查）',
              value: background.enabled,
              onChanged: background.busy
                  ? null
                  : (value) => unawaited(onConfigureBackground(value)),
            ),
          ],
          if (controller.isAndroid)
            MobilePhotoBackupAndroidBackgroundSection(
              background: background,
              workStateLabel: controller.backgroundWorkLabel,
              isPersonalDestination: controller.isPersonalDestination,
              isActionsDisabled: progress.busy || background.busy,
              onAuthorize: () => unawaited(onConfigureBackground(true)),
            ),
          divider(),
          _BackupOptionSwitch(
            title: '同时备份视频',
            value: options.includeVideos,
            onChanged: progress.busy ? null : controller.setIncludeVideos,
          ),
          divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: DropdownButtonFormField<String>(
              key: const ValueKey('photoOrganizeModeDropdown'),
              isExpanded: true,
              initialValue: options.organizeMode,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'NAS 归档目录规则',
              ),
              items: const [
                DropdownMenuItem(
                  value: PhotoBackupPrefsSchema.organizeFlat,
                  child: Text(
                    '不分子目录（平铺存放）',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: PhotoBackupPrefsSchema.organizeYearMonth,
                  child: Text(
                    '按拍摄年月（YYYY/MM）',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: PhotoBackupPrefsSchema.organizeByAlbum,
                  child: Text(
                    '按相簿名分类（<相簿名>）',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: PhotoBackupPrefsSchema.organizeByAlbumYearMonth,
                  child: Text(
                    '按相簿与年月（<相簿名>/YYYY/MM）',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: progress.busy
                  ? null
                  : (value) {
                      if (value != null) controller.setOrganizeMode(value);
                    },
            ),
          ),
        ],
      ),
    );
  }
}

class MobilePhotoBackupSpaceReleaseCard extends StatelessWidget {
  const MobilePhotoBackupSpaceReleaseCard({
    super.key,
    required this.controller,
    required this.onOpenManualRelease,
    required this.onToggleAutoRelease,
  });

  final MobilePhotoBackupController controller;
  final VoidCallback onOpenManualRelease;
  final Future<void> Function(bool enabled) onToggleAutoRelease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final sage = palette['brandSage'];
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final progress = controller.progress;
    final options = controller.options;
    final space = controller.spaceRelease;

    return IsleSurface(
      margin: const EdgeInsets.only(top: 12),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              children: [
                IsleSquircleBadge(
                  icon: Icons.cleaning_services_outlined,
                  color: sage,
                  size: 36,
                  iconSize: 18,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '安全释放手机空间',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        space.releasableCount > 0
                            ? '已备份可释放估算：${formatBytes(space.releasableBytes)}（${space.releasableCount} 项）'
                            : '备份完成后可在此在线核验 NAS 原片并安全释放本机存储',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: space.releasableCount > 0
                              ? sage
                              : colors.onSurfaceVariant,
                          fontWeight: space.releasableCount > 0
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (space.lastReleaseSummary != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text(
                space.lastReleaseSummary!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const ValueKey('manualSpaceReleaseButton'),
                onPressed: progress.busy ? null : onOpenManualRelease,
                icon: const Icon(Icons.verified_user_outlined, size: 17),
                label: Text(
                  space.releasableCount > 0
                      ? '释放本机空间（${space.releasableCount} 项）'
                      : '查看并释放本机空间',
                ),
              ),
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            indent: 14,
            endIndent: 14,
            color: borderColor,
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('autoPromptSpaceReleaseSwitch'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            title: const Text(
              '备份无错完成后自动发起释放确认',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '默认关闭；仅在无错完成且远端 SHA-256 核验通过后弹出系统确认框，绝不静默删图',
              style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
            ),
            value: options.autoPromptSpaceRelease,
            onChanged: progress.busy
                ? null
                : (value) => unawaited(onToggleAutoRelease(value)),
          ),
          if (options.autoPromptSpaceRelease)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
              child: DropdownButtonFormField<int>(
                key: const ValueKey('autoReleaseMinAgeDropdown'),
                isExpanded: true,
                initialValue: options.autoReleaseMinAgeDays,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '自动释放筛选保留期',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 30,
                    child: Text('30 天前拍摄（默认）', overflow: TextOverflow.ellipsis),
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
                onChanged: progress.busy
                    ? null
                    : (value) {
                        if (value != null) {
                          controller.setAutoReleaseMinAgeDays(value);
                        }
                      },
              ),
            ),
        ],
      ),
    );
  }
}

class _BackupOptionSwitch extends StatelessWidget {
  const _BackupOptionSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      title: Text(
        title,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

class MobilePhotoBackupAndroidBackgroundSection extends StatelessWidget {
  const MobilePhotoBackupAndroidBackgroundSection({
    super.key,
    required this.background,
    required this.workStateLabel,
    required this.isPersonalDestination,
    required this.isActionsDisabled,
    required this.onAuthorize,
  });

  final PhotoBackupBackgroundState background;
  final String workStateLabel;
  final bool isPersonalDestination;
  final bool isActionsDisabled;
  final VoidCallback onAuthorize;

  String _formatLocalTime(BuildContext context, DateTime value) {
    final locale = MaterialLocalizations.of(context);
    return '${locale.formatShortDate(value)} '
        '${locale.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '系统任务：$workStateLabel',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '最近进度或结果：${background.result}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (background.lastCompletedAt case final completed?)
            Text(
              '上次扫描至相册末尾 ${_formatLocalTime(context, completed)}',
              style: theme.textTheme.bodySmall,
            ),
          if (isPersonalDestination && background.expiresAt != null)
            Text(
              '授权有效至 ${_formatLocalTime(context, background.expiresAt!)}',
              style: theme.textTheme.bodySmall,
            ),
          if (isPersonalDestination)
            TextButton(
              onPressed: isActionsDisabled ? null : onAuthorize,
              child: Text(background.enabled ? '续授权' : '授权后台备份'),
            ),
          if (background.actionMessage != null) ...[
            const SizedBox(height: 4),
            Text(
              background.actionMessage!,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ],
          if (background.enabled && !background.sessionMatches) ...[
            const SizedBox(height: 4),
            Text(
              '当前登录会话与后台备份授权不一致；如需继续，请关闭后重新开启后台备份。',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }
}
