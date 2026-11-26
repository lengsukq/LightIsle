import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'mobile_photo_backup_background_service.dart';
import 'mobile_photo_backup_failure_store.dart';
import 'mobile_photo_backup_runner.dart';
import 'mobile_photo_backup_state_models.dart';
import 'mobile_photo_backup_transfer_client.dart';
import 'mobile_photo_space_release_service.dart';
import 'photo_backup_prefs_schema.dart';
import 'photo_backup_verified_ledger.dart';

const List<int> mobilePhotoBackupBatchOptions = [10, 30, 100];
const int _defaultBatchPages = 10;
const int _initialVisibleFailureCount = 50;
const int _failurePageStep = 50;
const String _legacyBaseDirectory = 'PhonePhotos';

final RegExp _installationIdPattern = RegExp(r'^[a-f0-9]{24}$');

/// Stateful ChangeNotifier controller owning mobile photo backup options,
/// foreground run lifecycle/cancellation, album selection, verified space
/// release ledger, failure tracking, and Android WorkManager coordination.
class MobilePhotoBackupController extends ChangeNotifier {
  MobilePhotoBackupController({
    required this.api,
    required this.accountName,
    this.baseDirectory = _legacyBaseDirectory,
    bool? androidPlatformOverride,
    bool? iosPlatformOverride,
  }) : boundRoot = api.selectedRoot,
       isAndroid = androidPlatformOverride ?? Platform.isAndroid,
       isIOS =
           iosPlatformOverride ??
           (!(androidPlatformOverride ?? Platform.isAndroid) &&
               Platform.isIOS) {
    _failureStore = MobilePhotoBackupFailureStore(
      isAndroid: isAndroid,
      isIOS: isIOS,
    );
    _transfer = MobilePhotoBackupTransferClient(
      api: api,
      boundRoot: boundRoot,
      isAndroid: isAndroid,
      isPersonalDestination: isPersonalDestination,
      prepareSession: prepare,
    );
    _backgroundCoordinator = MobilePhotoBackupBackgroundCoordinator(
      api: api,
      baseDirectory: baseDirectory,
      isAndroid: isAndroid,
      isPersonalDestination: isPersonalDestination,
      state: background,
      options: options,
      progress: progress,
      isDisposed: () => _disposed,
      onChanged: _notify,
    );
    _runner = MobilePhotoBackupRunner(
      api: api,
      baseDirectory: baseDirectory,
      isAndroid: isAndroid,
      isIOS: isIOS,
      progress: progress,
      options: options,
      failureStore: _failureStore,
      transfer: _transfer,
      prefsSchema: () => prefsSchema,
      checkActive: _ensureActive,
      isDisposed: () => _disposed,
      onChanged: _notify,
      onAssetVerified: _recordVerifiedBackupAsset,
    );
    _spaceReleaseService = MobilePhotoSpaceReleaseService(
      transfer: _transfer,
      verifiedLedger: _verifiedLedger,
      isIOS: isIOS,
      isDisposed: () => _disposed,
    );
  }

  final LightIsleApi api;
  final String accountName;
  final String baseDirectory;
  final LightIsleRoot? boundRoot;
  final bool isAndroid;
  final bool isIOS;

  final PhotoBackupRunProgressState progress = PhotoBackupRunProgressState();
  final PhotoBackupOptionsState options = PhotoBackupOptionsState();
  final PhotoBackupSpaceReleaseState spaceRelease =
      PhotoBackupSpaceReleaseState();
  final PhotoBackupBackgroundState background = PhotoBackupBackgroundState();
  final PhotoBackupPrepareSessionState prepare =
      PhotoBackupPrepareSessionState();

  final PhotoBackupVerifiedLedger _verifiedLedger =
      const PhotoBackupVerifiedLedger();
  late final MobilePhotoBackupFailureStore _failureStore;
  late final MobilePhotoBackupTransferClient _transfer;
  late final MobilePhotoBackupBackgroundCoordinator _backgroundCoordinator;
  late final MobilePhotoBackupRunner _runner;
  late final MobilePhotoSpaceReleaseService _spaceReleaseService;

  SharedPreferences? _prefs;
  bool _disposed = false;

  bool get isPersonalDestination => baseDirectory != _legacyBaseDirectory;

  PhotoBackupPrefsSchema get prefsSchema => PhotoBackupPrefsSchema(
    origin: api.uri('/api/v2/me/storage').origin,
    accountName: accountName,
    deviceId: options.deviceId,
    rootIdentity: boundRoot?.identity ?? 'unassigned',
    baseDirectory: baseDirectory,
  );

  String get _failureStorageKey => prefsSchema.failureStorageKey(
    options.albumScope,
    includeVideos: options.includeVideos,
    selectedAlbumIds: options.selectedAlbumIds,
  );

  int get icloudPendingCount => progress.failureDetails
      .where((item) => item['reason'] == 'icloud_not_downloaded')
      .length;

  String get backgroundWorkLabel =>
      photoBackupWorkStateLabel(background.workState);

  String get albumScopeSummaryLabel {
    final count = options.selectedAlbumIds.length;
    return switch (options.albumScope) {
      PhotoBackupPrefsSchema.albumScopeCamera => '仅相机拍摄',
      PhotoBackupPrefsSchema.albumScopeAll => '全部媒体',
      PhotoBackupPrefsSchema.albumScopeSelected =>
        count > 0 ? '仅已选 $count 个相簿' : '仅已选相簿（未勾选）',
      PhotoBackupPrefsSchema.albumScopeExcluded =>
        count > 0 ? '全部媒体（排除 $count 个相簿）' : '全部媒体（未排除相簿）',
      _ => '全部媒体',
    };
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _ensureActive() {
    if (progress.cancel || _disposed || !progress.isForeground) {
      throw const PausePhotoBackupException();
    }
    final root = boundRoot;
    if (root == null ||
        !root.online ||
        !isPersonalDestination ||
        api.selectedRoot?.identity != root.identity) {
      throw const PausePhotoBackupException();
    }
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = await _ensureInstallationId(prefs);
      if (_disposed) return;

      options.deviceId = id;
      _prefs = prefs;
      final schema = prefsSchema;
      options.albumScope = schema.resolveAlbumScope(prefs);
      options.selectedAlbumIds = schema.readSelectedAlbumIds(prefs);
      progress.pageCursor =
          prefs.getString(
            schema.cursorKey(
              options.albumScope,
              selectedAlbumIds: options.selectedAlbumIds,
            ),
          ) ??
          '';
      options.onForeground = prefs.getBool(schema.onForegroundKey) ?? false;
      options.wifiOnly = prefs.getBool(schema.wifiOnlyKey) ?? true;
      final savedBatch = prefs.getInt(schema.batchPagesKey);
      options.batchPages = mobilePhotoBackupBatchOptions.contains(savedBatch)
          ? savedBatch!
          : _defaultBatchPages;
      options.includeVideos = prefs.getBool(schema.includeVideosKey) ?? false;
      options.organizeMode = schema.resolveOrganizeMode(prefs);
      options.allowICloudDownload =
          prefs.getBool(schema.allowICloudDownloadKey) ?? false;
      options.autoPromptSpaceRelease = schema.readAutoPromptSpaceRelease(prefs);
      options.autoReleaseMinAgeDays = schema.readAutoReleaseMinAgeDays(prefs);
      progress.lastVerifiedAt = schema.readLastVerifiedAt(
        prefs,
        options.albumScope,
        selectedAlbumIds: options.selectedAlbumIds,
      );
      progress.lastCompleteAt = schema.readLastCompleteAt(
        prefs,
        options.albumScope,
        selectedAlbumIds: options.selectedAlbumIds,
      );
      progress.failureDetails = _failureStore.read(prefs, _failureStorageKey);
      spaceRelease.verifiedRecords = _verifiedLedger.read(prefs, schema);
      _notify();

      if (isAndroid) unawaited(readBackgroundStatus());
      if (options.onForeground) {
        unawaited(run(older: progress.pageCursor.isNotEmpty));
      }
    } catch (_) {
      if (!_disposed) {
        progress.message = '无法访问本机备份记录，请检查手机存储权限。';
        _notify();
      }
    }
  }

  Future<String> _ensureInstallationId(SharedPreferences prefs) async {
    final existing = prefs.getString(PhotoBackupPrefsSchema.installationIdKey);
    if (existing != null && _installationIdPattern.hasMatch(existing)) {
      return existing;
    }
    final random = Random.secure();
    final generated = List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await prefs.setString(PhotoBackupPrefsSchema.installationIdKey, generated);
    return generated;
  }

  Future<void> _recordVerifiedBackupAsset(
    VerifiedPhotoBackupRecord record,
  ) async {
    final prefs = _prefs;
    if (prefs == null || options.deviceId.isEmpty) return;
    final updated = await _verifiedLedger.upsert(prefs, prefsSchema, record);
    if (!_disposed) {
      spaceRelease.verifiedRecords = updated;
    }
  }

  void handleAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      progress.isForeground = true;
      if (isAndroid) unawaited(readBackgroundStatus());
      if (options.onForeground) {
        if (progress.busy) {
          if (progress.cancel) progress.resumeAfterCurrentRun = true;
        } else {
          unawaited(run(older: progress.pageCursor.isNotEmpty));
        }
      }
      return;
    }

    progress.isForeground = false;
    if (progress.busy) {
      progress.cancel = true;
      progress.resumeAfterCurrentRun = false;
      progress.message = '正在暂停；等待当前系统或网络请求结束…';
      _notify();
      _transfer.cancelActivePrepare();
    }
  }

  void pauseRun() {
    progress.cancel = true;
    progress.resumeAfterCurrentRun = false;
    progress.message = '正在暂停；等待当前系统或网络请求结束…';
    _notify();
    _transfer.cancelActivePrepare();
  }

  void continueOlderPhotos() {
    if (progress.busy || progress.nextCursor.isEmpty) return;
    progress.pageCursor = progress.nextCursor;
    unawaited(run(older: true));
  }

  Future<void> run({bool older = false}) async {
    if (progress.busy ||
        _prefs == null ||
        options.deviceId.isEmpty ||
        _disposed) {
      return;
    }
    final preferences = _prefs!;
    progress.beginRun();
    spaceRelease.pendingAutoReleasePrompt = false;
    _notify();
    try {
      final outcome = await _runner.execute(
        preferences: preferences,
        older: older,
      );
      _ensureActive();
      progress.message = outcome.summary;
      if (outcome.completedCleanly &&
          options.autoPromptSpaceRelease &&
          eligibleAutoReleaseRecords().isNotEmpty) {
        spaceRelease.pendingAutoReleasePrompt = true;
      }
      _notify();
    } on PausePhotoBackupException {
      if (!_disposed) {
        progress.message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。';
        _notify();
      }
    } catch (error) {
      if (progress.cancel || _disposed) {
        if (!_disposed) {
          progress.message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。';
          _notify();
        }
        return;
      }
      progress.message =
          '备份中断：${userFacingError(error)}。未删除手机原片或已完成的远端备份。';
      _notify();
    } finally {
      _finalizeRunState(preferences);
    }
  }

  void _finalizeRunState(SharedPreferences preferences) {
    if (!_disposed) {
      try {
        progress.failureDetails = _failureStore.read(
          preferences,
          _failureStorageKey,
        );
      } catch (error) {
        debugPrint('LightIsle photo failure read failed: $error');
        progress.failureDetails = [];
      }
    }
    final resume =
        !_disposed &&
        progress.resumeAfterCurrentRun &&
        progress.isForeground &&
        options.onForeground;
    progress.resumeAfterCurrentRun = false;
    if (!_disposed) {
      progress.busy = false;
      _notify();
    }
    if (resume) {
      unawaited(
        Future<void>.microtask(() {
          if (!_disposed &&
              progress.isForeground &&
              options.onForeground &&
              !progress.busy) {
            return run(older: progress.pageCursor.isNotEmpty);
          }
        }),
      );
    }
  }

  Future<void> _saveOptions() async {
    final schema = prefsSchema;
    await _prefs?.setString(schema.albumScopeKey, options.albumScope);
    await _prefs?.setStringList(
      schema.selectedAlbumIdsKey,
      options.selectedAlbumIds,
    );
    await _prefs?.setBool(schema.onForegroundKey, options.onForeground);
    await _prefs?.setBool(schema.wifiOnlyKey, options.wifiOnly);
    await _prefs?.setInt(schema.batchPagesKey, options.batchPages);
    await _prefs?.setBool(schema.includeVideosKey, options.includeVideos);
    await _prefs?.setString(schema.organizeModeKey, options.organizeMode);
    await _prefs?.setBool(
      schema.organizeByYearMonthKey,
      options.organizeByYearMonth,
    );
    await _prefs?.setBool(
      schema.allowICloudDownloadKey,
      options.allowICloudDownload,
    );
    await _prefs?.setBool(
      schema.autoPromptSpaceReleaseKey,
      options.autoPromptSpaceRelease,
    );
    await _prefs?.setInt(
      schema.autoReleaseMinAgeDaysKey,
      options.autoReleaseMinAgeDays,
    );
    if (isAndroid && background.enabled && background.sessionMatches) {
      unawaited(_backgroundCoordinator.syncOptions());
    }
  }

  void _reloadScopedProgressState() {
    final prefs = _prefs;
    final schema = prefsSchema;
    progress.pageCursor =
        prefs?.getString(
          schema.cursorKey(
            options.albumScope,
            selectedAlbumIds: options.selectedAlbumIds,
          ),
        ) ??
        '';
    progress.nextCursor = '';
    progress.visibleFailureCount = _initialVisibleFailureCount;
    progress.lastVerifiedAt =
        prefs?.getInt(
          schema.lastVerifiedAtKey(
            options.albumScope,
            selectedAlbumIds: options.selectedAlbumIds,
          ),
        ) ??
        0;
    progress.lastCompleteAt =
        prefs?.getInt(
          schema.lastCompleteAtKey(
            options.albumScope,
            selectedAlbumIds: options.selectedAlbumIds,
          ),
        ) ??
        0;
    try {
      progress.failureDetails = prefs == null
          ? []
          : _failureStore.read(prefs, _failureStorageKey);
    } catch (_) {
      progress.failureDetails = [];
    }
  }

  void switchAlbumScope(String nextScope) {
    final normalized = PhotoBackupPrefsSchema.normalizeAlbumScope(nextScope);
    if (progress.busy || normalized == options.albumScope) return;
    options.albumScope = normalized;
    _reloadScopedProgressState();
    _notify();
    unawaited(_saveOptions());
  }

  void updateAlbumSelection({
    required String albumScope,
    required List<String> selectedAlbumIds,
  }) {
    if (progress.busy) return;
    options.albumScope = PhotoBackupPrefsSchema.normalizeAlbumScope(albumScope);
    options.selectedAlbumIds =
        PhotoBackupPrefsSchema.normalizeSelectedAlbumIds(selectedAlbumIds);
    _reloadScopedProgressState();
    _notify();
    unawaited(_saveOptions());
  }

  Future<List<DevicePhotoAlbum>> loadDeviceAlbums() async {
    if (!isAndroid && !isIOS) {
      throw StateError('读取相簿列表只支持 Android 或 iOS 手机。');
    }
    final granted = await _transfer.ensurePermission(
      includeVideos: options.includeVideos,
    );
    if (!granted) {
      throw StateError(
        isAndroid
            ? '需要授权访问手机照片，才能加载相簿列表。'
            : '需要在 iOS 系统设置中授权访问全部照片，才能加载相簿列表。',
      );
    }
    return _transfer.listAlbums(includeVideos: options.includeVideos);
  }

  void setOnForeground(bool value) {
    if (progress.busy) return;
    options.onForeground = value;
    _notify();
    unawaited(_saveOptions());
  }

  void setWifiOnly(bool value) {
    if (progress.busy) return;
    options.wifiOnly = value;
    _notify();
    unawaited(_saveOptions());
  }

  void setAllowICloudDownload(bool value) {
    if (progress.busy) return;
    options.allowICloudDownload = value;
    _notify();
    unawaited(_saveOptions());
  }

  void setIncludeVideos(bool value) {
    if (progress.busy) return;
    options.includeVideos = value;
    progress.pageCursor = '';
    progress.nextCursor = '';
    progress.visibleFailureCount = _initialVisibleFailureCount;
    try {
      progress.failureDetails = _prefs == null
          ? []
          : _failureStore.read(_prefs!, _failureStorageKey);
    } catch (_) {
      progress.failureDetails = [];
      progress.message = '本机待处理记录无法读取，请重新检查备份。';
    }
    _notify();
    final schema = prefsSchema;
    unawaited(
      _prefs?.remove(
        schema.cursorKey(
          options.albumScope,
          selectedAlbumIds: options.selectedAlbumIds,
        ),
      ),
    );
    unawaited(
      _prefs?.remove(
        schema.storeVersionKey(
          options.albumScope,
          selectedAlbumIds: options.selectedAlbumIds,
        ),
      ),
    );
    unawaited(_saveOptions());
  }

  void setOrganizeMode(String mode) {
    if (progress.busy) return;
    options.organizeMode = PhotoBackupPrefsSchema.normalizeOrganizeMode(mode);
    _notify();
    unawaited(_saveOptions());
  }

  void setOrganizeByYearMonth(bool value) {
    setOrganizeMode(
      value
          ? PhotoBackupPrefsSchema.organizeYearMonth
          : PhotoBackupPrefsSchema.organizeFlat,
    );
  }

  void setAutoPromptSpaceRelease(bool value) {
    if (progress.busy) return;
    options.autoPromptSpaceRelease = value;
    _notify();
    unawaited(_saveOptions());
  }

  void setAutoReleaseMinAgeDays(int days) {
    if (progress.busy) return;
    options.autoReleaseMinAgeDays =
        PhotoBackupPrefsSchema.autoReleaseMinAgeOptions.contains(days)
        ? days
        : PhotoBackupPrefsSchema.defaultAutoReleaseMinAgeDays;
    _notify();
    unawaited(_saveOptions());
  }

  bool consumePendingAutoReleasePrompt() {
    if (!spaceRelease.pendingAutoReleasePrompt) return false;
    spaceRelease.pendingAutoReleasePrompt = false;
    return true;
  }

  List<VerifiedPhotoBackupRecord> eligibleAutoReleaseRecords({DateTime? now}) =>
      PhotoBackupVerifiedLedger.filterRecords(
        spaceRelease.verifiedRecords,
        filter: SpaceReleaseFilter.all,
        minAgeDaysOverride: options.autoReleaseMinAgeDays,
        now: now,
      );

  /// Online verification before any OS deletion request: confirms the bound
  /// physical root (rootID + generation) is online, checks iOS local asset
  /// completeness & edit freshness when applicable, then verifies every item's
  /// remote SHA-256 via `GET /api/v2/roots/{rootID}/files/sha256`.
  Future<SpaceReleaseVerificationSummary> verifyCandidatesForRelease(
    List<VerifiedPhotoBackupRecord> candidates, {
    required void Function(int checked, int total) onProgress,
    required bool Function() isCancelled,
  }) => _spaceReleaseService.verifyCandidates(
    candidates: candidates,
    includeVideos: options.includeVideos,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  /// Submits ONLY 100% online-verified asset IDs to the OS native delete
  /// confirmation dialog in batches of at most 500 unique native assets
  /// (Android 11+ MediaStore.createDeleteRequest / iOS PHPhotoLibrary).
  Future<SpaceReleaseExecutionResult> executeNativeSpaceRelease(
    List<VerifiedPhotoBackupRecord> verifiedRecords, {
    void Function(int currentBatch, int totalBatches, int deletedSoFar)?
    onBatchProgress,
  }) async {
    final result = await _spaceReleaseService.executeBatchedRelease(
      verifiedRecords: verifiedRecords,
      prefs: _prefs,
      schema: prefsSchema,
      hasDeviceId: options.deviceId.isNotEmpty,
      onLedgerUpdated: (remaining) {
        spaceRelease.verifiedRecords = remaining;
      },
      onBatchProgress: onBatchProgress,
    );
    if (result.deleted && !_disposed) {
      spaceRelease.lastReleaseSummary = result.message;
      _notify();
    }
    return result;
  }

  void setBatchPages(int value) {
    if (progress.busy) return;
    options.batchPages = value;
    _notify();
    unawaited(_saveOptions());
  }

  void showMorePendingFailures() {
    progress.visibleFailureCount += _failurePageStep;
    _notify();
  }

  Future<void> readBackgroundStatus() => _backgroundCoordinator.readStatus();

  Future<void> requestBackgroundCheck() => _backgroundCoordinator.requestScan();

  Future<void> configureBackground({
    required bool enabled,
    required Future<bool> Function() confirmEnable,
  }) => _backgroundCoordinator.configure(
    enabled: enabled,
    requestPermission: () => _transfer.ensurePermission(includeVideos: false),
    confirmEnable: confirmEnable,
  );

  @override
  void dispose() {
    _disposed = true;
    progress.cancel = true;
    _transfer.cancelActivePrepare();
    super.dispose();
  }
}
