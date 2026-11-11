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
import 'photo_backup_hash.dart';

part 'mobile_photo_backup_options.dart';
part 'mobile_photo_backup_background.dart';
part 'mobile_photo_backup_failures.dart';
part 'mobile_photo_backup_transfer.dart';
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
  bool _busy = false, _cancel = false, _onForeground = false, _wifiOnly = true;
  bool _backgroundEnabled = false, _backgroundBusy = false;
  bool _backgroundSessionMatches = false;
  DateTime? _backgroundExpiresAt;
  DateTime? _backgroundLastCompletedAt;
  bool _isForeground = true, _resumeAfterCurrentRun = false;
  String _backgroundResult = '后台备份未开启';
  String _backgroundWorkState = 'none';
  String? _backgroundActionMessage;
  int _backgroundStatusGeneration = 0;
  int _checked = 0, _uploaded = 0, _skipped = 0;
  int _failed = 0, _omittedFailures = 0;
  List<Map<String, dynamic>> _failureDetails = [];
  int _visibleFailureCount = 50;
  String _message = '授权读取手机照片后，可把照片与原画视频安全备份到你的 Mac。';
  String _pageCursor = '', _nextCursor = '', _deviceId = '';
  int _batchPages = 10;
  String _albumScope = 'camera';
  bool _includeVideos = false;
  bool _organizeByYearMonth = false;
  bool _allowICloudDownload = false;
  int _oversizedSkipped = 0;
  bool _scanHasOmissions = false;
  int _lastVerifiedAt = 0, _lastCompleteAt = 0;
  String? _activePrepareRequestId, _cancelledPrepareRequestId;
  int _prepareSequence = 0;
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
      _isForeground = true;
      if (_isAndroid) unawaited(_readBackgroundStatus());
      if (_onForeground) {
        if (_busy) {
          if (_cancel) _resumeAfterCurrentRun = true;
        } else {
          unawaited(_run(older: _pageCursor.isNotEmpty));
        }
      }
    } else {
      _isForeground = false;
      if (_busy) {
        _cancel = true;
        _resumeAfterCurrentRun = false;
        setState(() => _message = '正在暂停；等待当前系统或网络请求结束…');
        _cancelActivePrepare();
      }
    }
  }

  @override
  void dispose() {
    _cancel = true;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final icloudPendingCount = _failureDetails
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
              if (_failureDetails.isNotEmpty)
                IsleSurface(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: EdgeInsets.zero,
                  child: ExpansionTile(
                    title: Text('待处理原片（已记录 ${_failureDetails.length} 项）'),
                    subtitle: Text(
                      icloudPendingCount > 0
                          ? '含 $icloudPendingCount 项 iCloud 云端未下载原片；可在下方开启 Wi-Fi 下载后重新检查。'
                          : '从最新照片重新检查可重试；过大的文件可通过文件管理器单独上传。',
                    ),
                    children: [
                      for (final item in _failureDetails.take(
                        _visibleFailureCount,
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
                      if (_failureDetails.length > _visibleFailureCount)
                        TextButton(
                          onPressed: () =>
                              setState(() => _visibleFailureCount += 50),
                          child: const Text('显示更多待处理原片'),
                        ),
                    ],
                  ),
                ),
              IsleSurface(
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
                                '目标位置：${widget.baseDirectory} · ${_albumScope == "camera" ? "仅相机拍摄" : "全部媒体"}',
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
                      _message,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                    if (_checked > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '已检查 $_checked · 新增 $_uploaded · 跳过 $_skipped',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: colors.primary,
                        ),
                      ),
                    ],
                    if (_busy) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          minHeight: 4,
                          backgroundColor: colors.outlineVariant.withValues(
                            alpha: 0.25,
                          ),
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
                            _pageCursor.isEmpty ? '检查并备份最近照片' : '继续上次备份进度',
                          ),
                          onPressed: _busy
                              ? null
                              : () => unawaited(
                                  _run(older: _pageCursor.isNotEmpty),
                                ),
                        ),
                        if (_isAndroid &&
                            _backgroundEnabled &&
                            _backgroundSessionMatches)
                          OutlinedButton.icon(
                            icon: const Icon(Icons.sync_rounded),
                            label: const Text('立即检查后台备份'),
                            onPressed: _busy || _backgroundBusy
                                ? null
                                : () => unawaited(_requestBackgroundCheck()),
                          ),
                        if (!_busy &&
                            (_pageCursor.isNotEmpty ||
                                _failureDetails.isNotEmpty))
                          OutlinedButton(
                            onPressed: () => unawaited(_run()),
                            child: Text(
                              _pageCursor.isEmpty && _failureDetails.isNotEmpty
                                  ? '重新检查待处理项'
                                  : '从最新照片重新检查',
                            ),
                          ),
                        if (!_busy && _nextCursor.isNotEmpty)
                          OutlinedButton(
                            onPressed: () {
                              _pageCursor = _nextCursor;
                              unawaited(_run(older: true));
                            },
                            child: const Text('继续更早的照片'),
                          ),
                        if (_busy)
                          OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _cancel = true;
                                _resumeAfterCurrentRun = false;
                                _message = '正在暂停；等待当前系统或网络请求结束…';
                              });
                              _cancelActivePrepare();
                            },
                            child: const Text('暂停'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
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
