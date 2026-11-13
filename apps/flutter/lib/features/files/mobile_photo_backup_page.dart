import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Widget _buildPendingFailuresCard(int icloudPendingCount) {
    return IsleSurface(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: Text('待处理原片（已记录 ${_progress.failureDetails.length} 项）'),
        subtitle: Text(
          icloudPendingCount > 0
              ? '含 $icloudPendingCount 项 iCloud 云端未下载原片；可在下方开启 Wi-Fi 下载后重新检查。'
              : '从最新照片重新检查可重试；过大的文件可通过文件管理器单独上传。',
        ),
        children: [
          for (final item in _progress.failureDetails.take(
            _progress.visibleFailureCount,
          ))
            ListTile(
              dense: true,
              title: Text(
                item['name']?.toString().isNotEmpty == true
                    ? item['name'].toString()
                    : '未记录名称的原片',
              ),
              subtitle: Text(
                '${_failureReasonLabel(item['reason']?.toString())}'
                '${item['id'] == null ? '' : ' · 手机编号 ${item['id']}'}',
              ),
            ),
          if (_progress.failureDetails.length > _progress.visibleFailureCount)
            TextButton(
              onPressed: () =>
                  setState(() => _progress.visibleFailureCount += 50),
              child: const Text('显示更多待处理原片'),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme, ColorScheme colors) {
    return IsleSurface(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IsleSquircleBadge(
                icon: Icons.cloud_sync_rounded,
                color: Color(0xff06b6d4),
                size: 36,
                iconSize: 19,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isAndroid ? '相册备份状态' : '前台备份状态',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '目标位置：${widget.baseDirectory} · ${_options.albumScope == "camera" ? "仅相机拍摄" : "全部媒体"}',
                      style: theme.textTheme.bodySmall?.copyWith(
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
              fontSize: 13.5,
              height: 1.45,
            ),
          ),
          if (_progress.checked > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                IsleDonutGauge(
                  fraction:
                      ((_progress.uploaded + _progress.skipped) /
                              _progress.checked)
                          .clamp(0.0, 1.0),
                  color: colors.primary,
                  size: 32,
                  strokeWidth: 3.5,
                  centerText:
                      '${(((_progress.uploaded + _progress.skipped) / _progress.checked).clamp(0.0, 1.0) * 100).round()}%',
                  centerStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
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
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: colors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_progress.busy) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 4,
                backgroundColor: colors.outlineVariant.withValues(alpha: 0.25),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.backup_rounded),
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
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('立即检查后台备份'),
                  onPressed: _progress.busy || _background.busy
                      ? null
                      : () => unawaited(_requestBackgroundCheck()),
                ),
              if (!_progress.busy &&
                  (_progress.pageCursor.isNotEmpty ||
                      _progress.failureDetails.isNotEmpty))
                OutlinedButton(
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
                  onPressed: () {
                    _progress.pageCursor = _progress.nextCursor;
                    unawaited(_run(older: true));
                  },
                  child: const Text('继续更早的照片'),
                ),
              if (_progress.busy)
                OutlinedButton(
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
    final icloudPendingCount = _progress.failureDetails
        .where((item) => item['reason'] == 'icloud_not_downloaded')
        .length;

    return Scaffold(
      appBar: IsleAppBar(
        title: Text(_isAndroid ? 'Android 照片增量备份' : 'iOS 照片前台备份'),
      ),
      body: IsleListView(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_progress.failureDetails.isNotEmpty)
                _buildPendingFailuresCard(icloudPendingCount),
              _buildStatusCard(theme, colors),
              _buildOptionsSurface(context, theme, colors),
              _buildAdvancedDisclosure(theme, colors),
              IsleHelpDisclosure(
                summary: '备份范围与限制',
                details: _isAndroid
                    ? '前台流式读取原片并分片直传（无需双倍本机缓存空间，单文件最高支持 32 GiB）；手机原片绝不删除，备份到 ${widget.baseDirectory}/设备目录并核对 SHA-256。'
                    : 'iOS 支持前台备份照片、RAW 原片、视频及 Live Photo 配套 MOV，已核验原片自动走版本快检免重复导出；原片绝不删除，NAS 文件经 SHA-256 核验。',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
