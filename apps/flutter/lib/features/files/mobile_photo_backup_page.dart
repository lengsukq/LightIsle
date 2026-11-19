import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'mobile_photo_backup_state_models.dart';
import 'photo_backup_hash.dart';

part 'mobile_photo_backup_options.dart';
part 'mobile_photo_backup_background.dart';
part 'mobile_photo_backup_failures.dart';
part 'mobile_photo_backup_transfer.dart';
part 'mobile_photo_backup_pagination.dart';
part 'mobile_photo_backup_run.dart';

const _photosChannel = MethodChannel('lightisle/photos');
const _backgroundChannel = MethodChannel('lightisle/photos-background');
const _maxTrackedPhotoFailures = 512;
const _maxPhotoBackupBytes = 32 * 1024 * 1024 * 1024;

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
  void _updateState(VoidCallback action) => setState(action);

  late final LightIsleRoot? _boundRoot;
  final PhotoBackupRunProgressState _progress = PhotoBackupRunProgressState();
  final PhotoBackupOptionsState _options = PhotoBackupOptionsState();
  final PhotoBackupBackgroundState _background = PhotoBackupBackgroundState();
  final PhotoBackupPrepareSessionState _prepare =
      PhotoBackupPrepareSessionState();
  SharedPreferences? _prefs;

  bool get _isAndroid => widget.androidPlatformOverride ?? Platform.isAndroid;
  bool get _isIOS =>
      widget.iosPlatformOverride ?? (!_isAndroid && Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _boundRoot = widget.api.selectedRoot;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _progress.isForeground = true;
      if (_isAndroid) unawaited(_readBackgroundStatus());
      if (_options.onForeground) {
        if (_progress.busy) {
          if (_progress.cancel) _progress.resumeAfterCurrentRun = true;
        } else {
          unawaited(_run(older: _progress.pageCursor.isNotEmpty));
        }
      }
    } else {
      _progress.isForeground = false;
      if (_progress.busy) {
        _progress.cancel = true;
        _progress.resumeAfterCurrentRun = false;
        setState(() => _progress.message = '正在暂停；等待当前系统或网络请求结束…');
        _cancelActivePrepare();
      }
    }
  }

  @override
  void dispose() {
    _progress.cancel = true;
    _cancelActivePrepare();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _failureReasonLabel(String? reason) => switch (reason) {
    'icloud_not_downloaded' => '保存在 iCloud 云端，本机尚未下载原片',
    'oversized' => '超过单文件备份大小限制，尚未备份',
    'source_changed' => '原片在备份读取期间发生变化',
    'source_unreadable' => '无法读取本机原片，请检查权限或文件状态',
    _ => '原片暂不可用或发生变化',
  };

  Future<void> _showPendingFailuresDialog(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final visible = _progress.failureDetails
              .take(_progress.visibleFailureCount)
              .toList(growable: false);
          return AlertDialog(
            shape: IsleShapes.card(side: BorderSide(color: borderColor)),
            title: Text('待处理原片（${_progress.failureDetails.length} 项）'),
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
                          '${_failureReasonLabel(visible[i]['reason']?.toString())}'
                          '${visible[i]['id'] == null ? '' : ' · 手机编号 ${visible[i]['id']}'}',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                    if (_progress.failureDetails.length >
                        _progress.visibleFailureCount)
                      TextButton(
                        onPressed: () {
                          setState(() => _progress.visibleFailureCount += 50);
                          setDialogState(() {});
                        },
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

  Widget _buildPendingFailuresCard(
    BuildContext context,
    int icloudPendingCount,
  ) {
    final palette = IslePalette.of(context);
    final amber = palette['brandAmber'];
    return IsleSurface(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.zero,
      tint: amber,
      onTap: () => _showPendingFailuresDialog(context),
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
          '待处理原片（已记录 ${_progress.failureDetails.length} 项）',
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

  Widget _buildStatusCard(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
  ) {
    final palette = IslePalette.of(context);
    final rose = palette['brandRose'];
    final sage = palette['brandSage'];
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
                      _isAndroid ? '相册备份状态' : '前台备份状态',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 1.5),
                    Text(
                      '${widget.baseDirectory} · ${_options.albumScope == "camera" ? "仅相机拍摄" : "全部媒体"}',
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
            _progress.message,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.42,
            ),
          ),
          if (_progress.checked > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                IsleDonutGauge(
                  fraction:
                      ((_progress.uploaded + _progress.skipped) /
                              _progress.checked)
                          .clamp(0.0, 1.0),
                  color: sage,
                  size: 34,
                  strokeWidth: 3.3,
                  centerText:
                      '${(((_progress.uploaded + _progress.skipped) / _progress.checked).clamp(0.0, 1.0) * 100).round()}%',
                  centerStyle: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '已检查 ${_progress.checked} · 新增 ${_progress.uploaded} · 跳过 ${_progress.skipped}',
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
          if (_progress.busy) ...[
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
                  _progress.pageCursor.isEmpty ? '检查并备份最近照片' : '继续上次备份进度',
                ),
                onPressed: _progress.busy
                    ? null
                    : () => unawaited(
                        _run(older: _progress.pageCursor.isNotEmpty),
                      ),
              ),
              if (_isAndroid &&
                  _background.enabled &&
                  _background.sessionMatches)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.sync_rounded, size: 17),
                  label: const Text('立即检查后台备份'),
                  onPressed: _progress.busy || _background.busy
                      ? null
                      : () => unawaited(_requestBackgroundCheck()),
                ),
              if (!_progress.busy &&
                  (_progress.pageCursor.isNotEmpty ||
                      _progress.failureDetails.isNotEmpty))
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => unawaited(_run()),
                  child: Text(
                    _progress.pageCursor.isEmpty &&
                            _progress.failureDetails.isNotEmpty
                        ? '重新检查待处理项'
                        : '从最新照片重新检查',
                  ),
                ),
              if (!_progress.busy && _progress.nextCursor.isNotEmpty)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    _progress.pageCursor = _progress.nextCursor;
                    unawaited(_run(older: true));
                  },
                  child: const Text('继续更早的照片'),
                ),
              if (_progress.busy)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    setState(() {
                      _progress.cancel = true;
                      _progress.resumeAfterCurrentRun = false;
                      _progress.message = '正在暂停；等待当前系统或网络请求结束…';
                    });
                    _cancelActivePrepare();
                  },
                  child: const Text('暂停'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final icloudPendingCount = _progress.failureDetails
        .where((item) => item['reason'] == 'icloud_not_downloaded')
        .length;

    return Scaffold(
      appBar: IsleAppBar(
        title: Text(_isAndroid ? 'Android 照片增量备份' : 'iOS 照片前台备份'),
        actions: [
          IconButton(
            tooltip: '批量与备份记录',
            onPressed: _progress.busy
                ? null
                : () => _showBatchSettingsDialog(context),
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
              IsleHelpItem(
                title: _isAndroid ? '相机范围与后台调度' : '相机范围与 iCloud 原片',
                body: _isAndroid
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
          if (_progress.failureDetails.isNotEmpty)
            _buildPendingFailuresCard(context, icloudPendingCount),
          IsleWorkbenchSplit(
            primaryFlex: 6,
            secondaryFlex: 6,
            primary: _buildStatusCard(context, theme, colors),
            secondary: _buildOptionsSurface(context, theme, colors),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
