import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'mobile_photo_album_picker_sheet.dart';
import 'mobile_photo_backup_controller.dart';
import 'mobile_photo_backup_dialogs.dart';
import 'mobile_photo_backup_widgets.dart';
import 'mobile_photo_space_release_sheet.dart';

class MobilePhotoBackupPage extends StatefulWidget {
  const MobilePhotoBackupPage({
    super.key,
    required this.api,
    required this.accountName,
    this.baseDirectory = 'PhonePhotos',
    @visibleForTesting this.androidPlatformOverride,
    @visibleForTesting this.iosPlatformOverride,
  });

  final LightIsleApi api;
  final String accountName;

  /// Bound photos category directory for scoped personal storage.
  final String baseDirectory;
  @visibleForTesting
  final bool? androidPlatformOverride;
  @visibleForTesting
  final bool? iosPlatformOverride;

  @override
  State<MobilePhotoBackupPage> createState() => _MobilePhotoBackupState();
}

class _MobilePhotoBackupState extends State<MobilePhotoBackupPage>
    with WidgetsBindingObserver {
  late final MobilePhotoBackupController _controller;
  bool _spaceReleaseSheetOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = MobilePhotoBackupController(
      api: widget.api,
      accountName: widget.accountName,
      baseDirectory: widget.baseDirectory,
      androidPlatformOverride: widget.androidPlatformOverride,
      iosPlatformOverride: widget.iosPlatformOverride,
    );
    _controller.addListener(_handleControllerChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_controller.init());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.handleAppLifecycleState(state);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted || _spaceReleaseSheetOpen) return;
    if (_controller.consumePendingAutoReleasePrompt()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _spaceReleaseSheetOpen) return;
        unawaited(
          _openSpaceReleaseSheet(
            autoTriggered: true,
            initialMinAgeDays: _controller.options.autoReleaseMinAgeDays,
          ),
        );
      });
    }
  }

  Future<void> _openSpaceReleaseSheet({
    bool autoTriggered = false,
    int? initialMinAgeDays,
  }) async {
    if (_spaceReleaseSheetOpen || !mounted) return;
    _spaceReleaseSheetOpen = true;
    try {
      await showMobilePhotoSpaceReleaseSheet(
        context,
        _controller,
        autoTriggered: autoTriggered,
        initialMinAgeDays: initialMinAgeDays,
      );
    } finally {
      _spaceReleaseSheetOpen = false;
    }
  }

  Future<void> _handleToggleAutoSpaceRelease(bool enabled) async {
    if (!enabled) {
      _controller.setAutoPromptSpaceRelease(false);
      return;
    }
    if (!mounted) return;
    final selectedAgeDays = await showMobilePhotoAutoReleaseConfirmDialog(
      context,
      initialMinAgeDays: _controller.options.autoReleaseMinAgeDays,
    );
    if (!mounted || selectedAgeDays == null) return;
    _controller.setAutoReleaseMinAgeDays(selectedAgeDays);
    _controller.setAutoPromptSpaceRelease(true);
  }

  Future<void> _handleConfigureBackground(bool enabled) =>
      _controller.configureBackground(
        enabled: enabled,
        confirmEnable: () async {
          if (!mounted) return false;
          return showMobilePhotoBackupBackgroundConsentDialog(context);
        },
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final palette = IslePalette.of(context);
        final failures = _controller.progress.failureDetails;
        return Scaffold(
          appBar: IsleAppBar(
            title: Text(
              _controller.isAndroid ? 'Android 照片增量备份' : 'iOS 照片前台备份',
            ),
            actions: [
              IconButton(
                tooltip: '批量与备份记录',
                onPressed: _controller.progress.busy
                    ? null
                    : () => showMobilePhotoBackupBatchSettingsDialog(
                        context,
                        _controller,
                      ),
                icon: const Icon(Icons.tune_rounded, size: 20),
              ),
              IsleHelpButton(
                title: '照片备份说明',
                accentColor: palette['brandRose'],
                items: [
                  const IsleHelpItem(
                    title: '原画直传与防覆盖校验',
                    body:
                        '按字节计算 SHA-256 摘要，已备份且内容相同的原片自动跳过；同名但内容不同的文件绝不会覆盖 NAS 原件。',
                  ),
                  const IsleHelpItem(
                    title: '按相簿备份与安全释放',
                    body:
                        '支持按相簿/目录精细勾选或排除，并可按年月或相簿名归档。释放本地空间前会在线核验 NAS 硬盘身份与原片 SHA-256，仅对 100% 校验一致的条目拉起系统删除确认窗。',
                  ),
                  IsleHelpItem(
                    title: _controller.isAndroid
                        ? '相机范围与后台调度'
                        : '相机范围与 iCloud 原片',
                    body: _controller.isAndroid
                        ? '「仅相机拍摄」只扫描 DCIM 相机目录，自动过滤聊天缓存与截图；系统后台备份由 WorkManager 在连接 Wi-Fi 且电量充足时每 6 小时调度，会话通过 Android Keystore 加密保存（最长 7 天）。'
                        : '「仅相机拍摄」自动过滤屏幕截图；若开启了「优化 iPhone 存储空间」，勾选允许下载 iCloud 原片即可在连接 Wi-Fi 时拉取云端原片备份。',
                  ),
                ],
              ),
            ],
          ),
          body: IsleListView(
            maxWidth: IsleLayout.workbenchMaxWidth,
            children: [
              if (failures.isNotEmpty)
                MobilePhotoBackupPendingFailuresCard(
                  failureCount: failures.length,
                  icloudPendingCount: _controller.icloudPendingCount,
                  onTap: () => showMobilePhotoBackupPendingFailuresDialog(
                    context,
                    _controller,
                  ),
                ),
              IsleWorkbenchSplit(
                primaryFlex: 6,
                secondaryFlex: 6,
                primary: MobilePhotoBackupStatusCard(controller: _controller),
                secondary: MobilePhotoBackupOptionsCard(
                  controller: _controller,
                  onConfigureBackground: _handleConfigureBackground,
                  onOpenAlbumPicker: () => unawaited(
                    showMobilePhotoAlbumPickerSheet(context, _controller),
                  ),
                ),
              ),
              if (_controller.isPersonalDestination)
                MobilePhotoBackupSpaceReleaseCard(
                  controller: _controller,
                  onOpenManualRelease: () =>
                      unawaited(_openSpaceReleaseSheet()),
                  onToggleAutoRelease: _handleToggleAutoSpaceRelease,
                ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}
