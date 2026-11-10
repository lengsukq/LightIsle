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
import 'photo_backup_hash.dart';
import '../../core/widgets.dart';

part 'android_photo_backup_options.dart';
part 'android_photo_backup_background.dart';
part 'android_photo_backup_failures.dart';
part 'android_photo_backup_transfer.dart';
part 'android_photo_backup_run.dart';

const _photosChannel = MethodChannel('lightisle/photos');
const _backgroundChannel = MethodChannel('lightisle/photos-background');
const _maxTrackedPhotoFailures = 512;
const _maxPhotoBackupBytes = 32 * 1024 * 1024 * 1024;

class AndroidPhotoBackupPage extends StatefulWidget {
  const AndroidPhotoBackupPage({
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
  State<AndroidPhotoBackupPage> createState() => _AndroidPhotoBackupState();
}

class _AndroidPhotoBackupState extends State<AndroidPhotoBackupPage>
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
  String _message = '授权读取手机照片后，可把照片备份到你的 Mac。';
  String _pageCursor = '', _nextCursor = '', _deviceId = '';
  int _batchPages = 10;
  bool _includeVideos = false;
  bool _organizeByYearMonth = false;
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
          // The previous run may still be awaiting native cancellation and
          // temp-file cleanup. Queue one pass instead of losing this resume.
          if (_cancel) _resumeAfterCurrentRun = true;
        } else {
          unawaited(_run(older: _pageCursor.isNotEmpty));
        }
      }
    } else {
      _isForeground = false;
      // Prevent a long-running batch from consuming mobile data or continuing
      // indefinitely once its page is no longer in the foreground.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: IsleAppBar(
        title: Text(_isAndroid ? 'Android 照片增量备份' : 'iOS 照片前台备份'),
      ),
      body: IsleListView(
        children: [
          if (_failureDetails.isNotEmpty)
            IsleSurface(
              margin: const EdgeInsets.only(bottom: 12),
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                title: Text('待处理原片（已记录 ${_failureDetails.length} 项）'),
                subtitle: const Text('从最新照片重新检查可重试；过大的文件可通过文件管理器单独上传。'),
                children: [
                  for (final item in _failureDetails.take(_visibleFailureCount))
                    ListTile(
                      dense: true,
                      title: Text(
                        item['name']?.toString().isNotEmpty == true
                            ? item['name'].toString()
                            : '未记录名称的原片',
                      ),
                      subtitle: Text(
                        '${item['reason'] == 'oversized' ? '超过暂存大小限制，尚未备份' : '原片暂不可用或发生变化'}'
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
                            '目标位置：${widget.baseDirectory}',
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
                          : () =>
                                unawaited(_run(older: _pageCursor.isNotEmpty)),
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
                    if (!_busy && _pageCursor.isNotEmpty)
                      OutlinedButton(
                        onPressed: () => unawaited(_run()),
                        child: const Text('从最新照片重新检查'),
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
          IsleSurface(
            margin: const EdgeInsets.only(bottom: 12),
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('进入此页面或返回前台时自动检查'),
                  subtitle: const Text('只在 App 前台自动启动；不是 Android 系统后台定时任务。'),
                  value: _onForeground,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _onForeground = value);
                          unawaited(_saveOptions());
                        },
                ),
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: colors.outlineVariant.withValues(alpha: 0.3),
                ),
                SwitchListTile(
                  title: const Text('仅 Wi-Fi 备份'),
                  value: _wifiOnly,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _wifiOnly = value);
                          unawaited(_saveOptions());
                        },
                ),
                if (_isAndroid && _personalDestination) ...[
                  Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: colors.outlineVariant.withValues(alpha: 0.3),
                  ),
                  SwitchListTile(
                    title: const Text('系统后台自动备份（每 6 小时检查）'),
                    subtitle: const Text(
                      '需明确授权；系统在 Wi-Fi 和电量允许时调度。完整登录会话以 Android Keystore 加密保存最多 7 天，关闭或退出登录即清除。',
                    ),
                    value: _backgroundEnabled,
                    onChanged: _backgroundBusy
                        ? null
                        : (value) => unawaited(_configureBackground(value)),
                  ),
                ],
                if (_isAndroid) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '系统任务：$_backgroundWorkLabel',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '最近进度或结果：$_backgroundResult',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        if (_backgroundLastCompletedAt case final completed?)
                          Text(
                            '上次扫描至相册末尾 ${_backupLocalTime(completed)}',
                            style: theme.textTheme.bodySmall,
                          ),
                        if (_personalDestination && _backgroundExpiresAt != null)
                          Text(
                            '授权有效至 ${_backupLocalTime(_backgroundExpiresAt!)}',
                            style: theme.textTheme.bodySmall,
                          ),
                        if (_personalDestination)
                          TextButton(
                            onPressed: _busy || _backgroundBusy
                                ? null
                                : () => unawaited(_configureBackground(true)),
                            child: Text(_backgroundEnabled ? '续授权' : '授权后台备份'),
                          ),
                        if (_backgroundActionMessage != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _backgroundActionMessage!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.error,
                            ),
                          ),
                        ],
                        if (_backgroundEnabled &&
                            !_backgroundSessionMatches) ...[
                          const SizedBox(height: 4),
                          Text(
                            '当前登录会话与后台备份授权不一致；如需继续，请关闭后重新开启后台备份。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: colors.outlineVariant.withValues(alpha: 0.3),
                ),
                SwitchListTile(
                  title: const Text('同时备份视频'),
                  subtitle: Text(
                    _isAndroid
                        ? '需要系统视频读取授权。仅扩展前台扫描，Android 定时后台备份仍只处理照片。'
                        : '包含普通视频和 Live Photo 的配套视频原片；可能明显增加存储和网络用量。',
                  ),
                  value: _includeVideos,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() {
                            _includeVideos = value;
                            _pageCursor = '';
                            _nextCursor = '';
                            _visibleFailureCount = 50;
                            try {
                              _failureDetails = _prefs == null
                                  ? []
                                  : _readPhotoFailures(
                                      _prefs!,
                                      _photoFailureStorageKey(),
                                    );
                            } catch (_) {
                              _failureDetails = [];
                              _message = '本机待处理记录无法读取，请重新检查备份。';
                            }
                          });
                          unawaited(_prefs?.remove('$_scope.cursor'));
                          unawaited(_prefs?.remove('$_scope.storeVersion'));
                          unawaited(_saveOptions());
                        },
                ),
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: colors.outlineVariant.withValues(alpha: 0.3),
                ),
                SwitchListTile(
                  title: const Text('按拍摄年月分目录（YYYY/MM）'),
                  subtitle: const Text(
                    '开启后前台备份按拍摄时间写入 设备目录/2026/05/…，方便在 Finder 中按月份浏览。',
                  ),
                  value: _organizeByYearMonth,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _organizeByYearMonth = value);
                          unawaited(_saveOptions());
                        },
                ),
              ],
            ),
          ),
          IsleDisclosureCard(
            title: const Text('高级批量设置与备份记录'),
            initiallyExpanded: false,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: _batchPages,
                      decoration: InputDecoration(
                        labelText: '单次前台检查批量',
                        helperText:
                            '大相册首次备份可选择 1200 或 4000 张；手机会逐张校验，不会并发大量读取原片。',
                        filled: true,
                        fillColor: colors.surfaceContainerHighest.withValues(
                          alpha: 0.35,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: colors.outlineVariant.withValues(alpha: 0.4),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: colors.outlineVariant.withValues(alpha: 0.4),
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 10,
                          child: Text('400 张 · 省电模式'),
                        ),
                        DropdownMenuItem(
                          value: 30,
                          child: Text('1200 张 · 普通批量'),
                        ),
                        DropdownMenuItem(
                          value: 100,
                          child: Text('4000 张 · 首次补跑'),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => _batchPages = value);
                              unawaited(_saveOptions());
                            },
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '最近成功核对：${_lastVerifiedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(_lastVerifiedAt).toLocal().toString().substring(0, 16) : "尚无"} · '
                      '最近扫描到末尾：${_lastCompleteAt > 0 ? DateTime.fromMillisecondsSinceEpoch(_lastCompleteAt).toLocal().toString().substring(0, 16) : "尚无"}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          IsleHelpDisclosure(
            summary: '备份范围与限制',
            details: _isAndroid
                ? '前台可以选择备份照片及视频（视频需额外授权）；手机原片不删除；备份到 ${widget.baseDirectory}/设备目录并核对 SHA-256。超过 2 GiB 的安卓媒体当前尚不支持原片临时复制，需使用文件管理器手动上传。'
                : 'iOS 支持前台备份照片，也可另外选择视频和 Live Photo 的配套 MOV。只读取已在手机上的原片，不主动从 iCloud 下载；原片不删除，NAS 文件需经 SHA-256 校验。',
          ),
        ],
      ),
    );
  }
}
