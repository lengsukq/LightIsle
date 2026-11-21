import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import 'mobile_photo_backup_state_models.dart';

const MethodChannel mobilePhotosBackgroundMethodChannel = MethodChannel(
  'lightisle/photos-background',
);

String photoBackupWorkStateLabel(String workState) => switch (workState) {
  'enqueued' => '已排队，等待 Wi-Fi、电量和系统调度条件',
  'running' => '正在备份照片',
  'blocked' => '等待前序后台任务完成',
  'trigger_running' => '系统正在安排照片检查',
  'scheduled' => '后台计划已启用，等待系统条件',
  'none' => '当前没有排队或执行中的任务',
  _ => '暂时无法确定系统任务状态',
};

/// Coordinates Android WorkManager background photo backup status reads,
/// option sync, immediate scan requests, and verified enable/disable writes.
class MobilePhotoBackupBackgroundCoordinator {
  MobilePhotoBackupBackgroundCoordinator({
    required this.api,
    required this.baseDirectory,
    required this.isAndroid,
    required this.isPersonalDestination,
    required this.state,
    required this.options,
    required this.progress,
    required this.isDisposed,
    required this.onChanged,
    this.channel = mobilePhotosBackgroundMethodChannel,
  });

  final LightIsleApi api;
  final String baseDirectory;
  final bool isAndroid;
  final bool isPersonalDestination;
  final PhotoBackupBackgroundState state;
  final PhotoBackupOptionsState options;
  final PhotoBackupRunProgressState progress;
  final bool Function() isDisposed;
  final VoidCallback onChanged;
  final MethodChannel channel;

  bool _isCurrentStatusRead(int generation) =>
      !isDisposed() && !state.busy && generation == state.statusGeneration;

  void _beginWrite() {
    state.statusGeneration++;
    state.busy = true;
    onChanged();
  }

  void _finishWrite() {
    state.statusGeneration++;
    if (!isDisposed()) {
      state.busy = false;
      onChanged();
    }
  }

  void _applyStatus(Map<String, dynamic>? result) {
    state.enabled = result?['enabled'] == true;
    state.sessionMatches = result?['sessionMatches'] == true;
    state.expiresAt = _parseEpochMillis(result?['expiresAt']);
    state.lastCompletedAt = _parseEpochMillis(result?['lastCompletedAt']);
    state.result = result?['last']?.toString() ?? '尚未执行';
    state.workState = result?['workState']?.toString() ?? 'unknown';
  }

  DateTime? _parseEpochMillis(Object? value) {
    final milliseconds = (value as num?)?.toInt() ?? 0;
    return milliseconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(milliseconds)
        : null;
  }

  Map<String, String> _sessionAuthPayload() => {
    'server': api.uri('/api/v2/me/storage').origin,
    'cookie': api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
  };

  Future<void> readStatus() async {
    final generation = ++state.statusGeneration;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('status');
      if (!_isCurrentStatusRead(generation)) return;
      _applyStatus(result);
      onChanged();
    } catch (_) {
      if (_isCurrentStatusRead(generation)) {
        state.result = '无法读取系统后台任务状态';
        state.workState = 'unknown';
        onChanged();
      }
    }
  }

  Future<void> requestScan() async {
    if (progress.busy ||
        state.busy ||
        !state.enabled ||
        options.deviceId.isEmpty) {
      return;
    }
    _beginWrite();
    state.actionMessage = null;
    onChanged();
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'enqueueScan',
        _sessionAuthPayload(),
      );
      if (isDisposed()) return;
      _applyStatus(result);
      state.actionMessage = '已提交后台检查；系统会在 Wi-Fi、电量等条件允许时执行，已有任务会继续沿用。';
      onChanged();
    } catch (_) {
      if (!isDisposed()) {
        state.actionMessage = '无法安排后台检查：请确认仍登录当前账号且系统后台备份已开启。';
        onChanged();
      }
    } finally {
      _finishWrite();
    }
  }

  Future<void> syncOptions() async {
    if (!isAndroid || !state.enabled || state.busy) return;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'updateOptions',
        {
          ..._sessionAuthPayload(),
          'albumScope': options.albumScope,
          'organizeByYearMonth': options.organizeByYearMonth,
        },
      );
      if (!isDisposed() && result != null) {
        _applyStatus(result);
        onChanged();
      }
    } catch (_) {
      // Keep foreground preference write resilient even if native channel is absent in unit tests.
    }
  }

  Future<void> _verifyPersonalPhotosBinding(
    LightIsleRoot destinationRoot,
  ) async {
    final policy = await api.get('/api/v2/me/storage');
    final locations = policy['locations'];
    final userId = policy['userId'];
    final expectedPath = 'Users/u$userId/photos';
    if (userId is! int ||
        userId <= 0 ||
        baseDirectory != expectedPath ||
        locations is! List ||
        !locations.any(
          (value) =>
              value is Map &&
              value['category'] == 'photos' &&
              value['rootID'] == destinationRoot.id &&
              value['rootGeneration'] == destinationRoot.generation &&
              value['relativePath'] == expectedPath,
        )) {
      throw const FormatException('个人照片目录绑定已变化。');
    }
    final discovery = await api.get('/api/v2/roots');
    final online = discovery['roots'];
    if (online is! List ||
        !online.any(
          (value) =>
              value is Map &&
              value['rootID'] == destinationRoot.id &&
              value['generation'] == destinationRoot.generation &&
              value['online'] == true,
        )) {
      throw const FormatException('照片硬盘已离线或被替换。');
    }
  }

  Future<void> configure({
    required bool enabled,
    required Future<bool> Function() requestPermission,
    required Future<bool> Function() confirmEnable,
  }) async {
    if (state.busy || options.deviceId.isEmpty) return;
    LightIsleRoot? destinationRoot;
    if (enabled) {
      destinationRoot = api.selectedRoot;
      if (destinationRoot == null ||
          !isPersonalDestination ||
          !destinationRoot.online) {
        if (!isDisposed()) {
          state.actionMessage =
              '请在存储设置中为照片分配在线硬盘，再从图库打开个人照片备份。后台任务只支持安全的 v2 专属照片目录。';
          onChanged();
        }
        return;
      }
      try {
        await _verifyPersonalPhotosBinding(destinationRoot);
      } catch (_) {
        if (!isDisposed()) {
          state.actionMessage =
              '照片硬盘连接或账号存储绑定无法验证。请回到图库刷新硬盘状态后重试；后台备份未开启。';
          onChanged();
        }
        return;
      }
      if (isDisposed() ||
          api.selectedRoot?.identity != destinationRoot.identity) {
        return;
      }
      if (!await requestPermission()) {
        if (!isDisposed()) {
          state.result = '需要完整相册读取权限。';
          onChanged();
        }
        return;
      }
      if (isDisposed()) return;
      final accepted = await confirmEnable();
      if (!accepted || isDisposed()) return;
    }
    _beginWrite();
    try {
      final result = enabled
          ? await channel.invokeMapMethod<String, dynamic>('enable', {
              ..._sessionAuthPayload(),
              'certificateFingerprint': api.certificateFingerprint ?? '',
              'deviceId': options.deviceId,
              'rootID': destinationRoot!.id,
              'rootGeneration': destinationRoot.generation,
              'photosPath': baseDirectory,
              'albumScope': options.albumScope,
              'organizeByYearMonth': options.organizeByYearMonth,
            })
          : await channel.invokeMapMethod<String, dynamic>(
              'disable',
              _sessionAuthPayload(),
            );
      if (isDisposed()) return;
      _applyStatus(result);
      state.actionMessage = null;
      onChanged();
    } catch (_) {
      if (!isDisposed()) {
        state.result = '后台配置失败：请确认登录状态、NAS 地址和证书指纹；原有前台备份仍可正常使用。';
        onChanged();
      }
    } finally {
      _finishWrite();
    }
  }
}
