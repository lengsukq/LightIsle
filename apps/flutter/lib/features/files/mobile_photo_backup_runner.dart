import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import 'mobile_photo_backup_entry_uploader.dart';
import 'mobile_photo_backup_failure_store.dart';
import 'mobile_photo_backup_state_models.dart';
import 'mobile_photo_backup_transfer_client.dart';
import 'photo_backup_prefs_schema.dart';

const int _maxOversizedClampPerPage = 10000;

final RegExp _omittedAssetIdPattern = RegExp(r'^[0-9]{1,20}$');

class _BackupSessionKeys {
  _BackupSessionKeys(
    PhotoBackupPrefsSchema schema,
    String albumScope,
    this.failureStorageKey,
  ) : cursorKey = schema.cursorKey(albumScope),
      storeVersionKey = schema.storeVersionKey(albumScope),
      lastVerifiedKey = schema.lastVerifiedAtKey(albumScope),
      lastCompleteKey = schema.lastCompleteAtKey(albumScope),
      scanIncompleteKey = PhotoBackupPrefsSchema.scanIncompleteKey(
        failureStorageKey,
      );

  final String cursorKey;
  final String storeVersionKey;
  final String lastVerifiedKey;
  final String lastCompleteKey;
  final String failureStorageKey;
  final String scanIncompleteKey;
}

/// Executes a foreground mobile photo backup pass: validates permissions and
/// network constraints, walks paginated device media snapshots, delegates each
/// asset to [MobilePhotoBackupEntryUploader], and persists cursors/failures.
class MobilePhotoBackupRunner {
  MobilePhotoBackupRunner({
    required this.api,
    required this.baseDirectory,
    required this.isAndroid,
    required this.isIOS,
    required this.progress,
    required this.options,
    required this.failureStore,
    required this.transfer,
    required this.prefsSchema,
    required this.checkActive,
    required this.isDisposed,
    required this.onChanged,
  }) {
    _entryUploader = MobilePhotoBackupEntryUploader(
      api: api,
      isIOS: isIOS,
      progress: progress,
      options: options,
      failureStore: failureStore,
      transfer: transfer,
      prefsSchema: prefsSchema,
      checkActive: checkActive,
      isDisposed: isDisposed,
      onChanged: onChanged,
      onFailureCounts: _applyFailureCounts,
    );
  }

  final LightIsleApi api;
  final String baseDirectory;
  final bool isAndroid;
  final bool isIOS;
  final PhotoBackupRunProgressState progress;
  final PhotoBackupOptionsState options;
  final MobilePhotoBackupFailureStore failureStore;
  final MobilePhotoBackupTransferClient transfer;
  final PhotoBackupPrefsSchema Function() prefsSchema;
  final void Function() checkActive;
  final bool Function() isDisposed;
  final VoidCallback onChanged;

  late final MobilePhotoBackupEntryUploader _entryUploader;

  Future<String> execute({
    required SharedPreferences preferences,
    required bool older,
  }) async {
    final schema = prefsSchema();
    final failureStorageKey = schema.failureStorageKey(
      options.albumScope,
      includeVideos: options.includeVideos,
    );
    final keys = _BackupSessionKeys(
      schema,
      options.albumScope,
      failureStorageKey,
    );

    await _validatePreconditions();
    await _initializePaginationState(preferences, keys, older: older);

    final destinationDir = '$baseDirectory/${options.deviceId}';
    final ensuredSubdirs = <String>{};
    var dirsReady = false;
    var complete = false;
    var pages = 0;
    var restartedAfterLibraryChange = false;
    var failureStateInitialized = false;

    while (pages < options.batchPages && !progress.cancel && !isDisposed()) {
      checkActive();
      await _verifyWifiIfRequired();
      final before = progress.pageCursor;
      final page = await transfer.fetchPhotoPage(
        beforeCursor: before,
        includeVideos: options.includeVideos,
        albumScope: options.albumScope,
        checkActive: checkActive,
      );

      if (before.isNotEmpty) {
        final previousVersion = preferences.getString(keys.storeVersionKey);
        if (previousVersion != null &&
            previousVersion != page.storeVersionID) {
          if (restartedAfterLibraryChange) {
            throw StateError('相册持续变化，请稍后从最新照片重新检查。');
          }
          restartedAfterLibraryChange = true;
          await _restartAfterLibraryChange(
            preferences,
            keys,
            page.storeVersionID,
          );
          failureStateInitialized = false;
          pages = 0;
          continue;
        }
      }

      if (!failureStateInitialized) {
        await _initializeFailureState(
          preferences: preferences,
          failureStorageKey: keys.failureStorageKey,
          storeVersionID: page.storeVersionID,
          older: older,
        );
        failureStateInitialized = true;
      }

      if (page.rows.isNotEmpty && !dirsReady) {
        await transfer.ensureRemoteDestinationReady(
          baseDirectory,
          destinationDir,
          checkActive: checkActive,
        );
        dirsReady = true;
      }

      final pageResult = await _processPage(
        page: page,
        pageNumber: pages + 1,
        preferences: preferences,
        failureStorageKey: keys.failureStorageKey,
        destinationDir: destinationDir,
        ensuredSubdirs: ensuredSubdirs,
      );

      checkActive();
      if (pageResult.hasOmissions) {
        if (!await preferences.setBool(keys.scanIncompleteKey, true)) {
          throw StateError('无法保存未备份项目状态，未推进照片分页进度。');
        }
        progress.scanHasOmissions = true;
      }
      pages++;
      progress.oversizedSkipped += page.oversizedCount.clamp(
        0,
        _maxOversizedClampPerPage,
      );
      if (!pageResult.hadFailures && !pageResult.hasOmissions) {
        progress.lastVerifiedAt = DateTime.now().millisecondsSinceEpoch;
        await preferences.setInt(keys.lastVerifiedKey, progress.lastVerifiedAt);
      }

      if (page.nextCursor.isEmpty) {
        await _completeScanPagination(preferences, keys);
        complete = true;
        break;
      }
      await _advanceScanCursor(preferences, keys, page);
    }

    checkActive();
    return _buildCompletionMessage(complete: complete);
  }

  Future<void> _validatePreconditions() async {
    checkActive();
    if (!isAndroid && !isIOS) {
      throw StateError('照片备份只支持 Android 或 iOS 手机。');
    }
    final granted = await transfer.ensurePermission(
      includeVideos: options.includeVideos,
      checkActive: checkActive,
    );
    if (!granted) {
      throw StateError(
        isAndroid
            ? '需要在 Android 系统设置中授权访问所有照片；仅选定照片的权限不足以进行完整备份。'
            : '需要在 iOS 系统设置中授权访问所有照片；有限照片访问不足以进行完整备份。',
      );
    }
    checkActive();
  }

  Future<void> _initializePaginationState(
    SharedPreferences preferences,
    _BackupSessionKeys keys, {
    required bool older,
  }) async {
    if (!older) {
      progress.pageCursor = '';
      if (!await preferences.remove(keys.cursorKey)) {
        throw StateError('无法重置照片分页进度，请重试。');
      }
      if (!await preferences.setBool(keys.scanIncompleteKey, false)) {
        throw StateError('无法保存照片检查状态，请重试。');
      }
      checkActive();
    }
    progress.scanHasOmissions =
        older &&
        progress.pageCursor.isNotEmpty &&
        (preferences.getBool(keys.scanIncompleteKey) ?? true);
  }

  Future<void> _verifyWifiIfRequired() async {
    if (!options.wifiOnly) return;
    final wifi = await transfer.isWifi();
    checkActive();
    if (!wifi) {
      throw StateError('当前不在 Wi-Fi 网络下，按你的设置已暂停备份。');
    }
  }

  Future<void> _restartAfterLibraryChange(
    SharedPreferences preferences,
    _BackupSessionKeys keys,
    String newStoreVersionID,
  ) async {
    progress.pageCursor = '';
    progress.nextCursor = '';
    if (!await preferences.remove(keys.cursorKey) ||
        !await preferences.setBool(keys.scanIncompleteKey, false)) {
      throw StateError('无法重置照片检查进度，请重试。');
    }
    progress.scanHasOmissions = false;
    await preferences.setString(keys.storeVersionKey, newStoreVersionID);
    checkActive();
  }

  Future<void> _initializeFailureState({
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String storeVersionID,
    required bool older,
  }) async {
    final previousFailureVersion = preferences.getString(
      PhotoBackupPrefsSchema.failureVersionKey(failureStorageKey),
    );
    final shouldReset = !older || previousFailureVersion != storeVersionID;
    final failureCounts = shouldReset
        ? await failureStore.reset(
            preferences,
            failureStorageKey,
            storeVersionID,
          )
        : failureStore.readCounts(preferences, failureStorageKey);
    _applyFailureCounts(failureCounts);
    checkActive();
  }

  Future<({bool hadFailures, bool hasOmissions})> _processPage({
    required PhotoPageResponse page,
    required int pageNumber,
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String destinationDir,
    required Set<String> ensuredSubdirs,
  }) async {
    var hadFailures = false;
    final recordedOmittedItems = await _recordOmittedPageItems(
      preferences,
      failureStorageKey,
      page.storeVersionID,
      page.omittedItems,
    );
    var hasOmissions =
        page.oversizedCount > 0 || page.invalidCount > 0 || recordedOmittedItems;

    for (final entry in page.rows) {
      final outcome = await _entryUploader.processEntry(
        entry: entry,
        pageNumber: pageNumber,
        supportsStream: page.supportsStream,
        preferences: preferences,
        failureStorageKey: failureStorageKey,
        storeVersionID: page.storeVersionID,
        destinationDir: destinationDir,
        ensuredSubdirs: ensuredSubdirs,
      );
      if (outcome == EntryBackupOutcome.failed) hadFailures = true;
      if (outcome == EntryBackupOutcome.omitted) hasOmissions = true;
    }
    return (hadFailures: hadFailures, hasOmissions: hasOmissions);
  }

  Future<void> _completeScanPagination(
    SharedPreferences preferences,
    _BackupSessionKeys keys,
  ) async {
    if (!await preferences.remove(keys.cursorKey)) {
      throw StateError('无法完成照片分页记录，请重新检查。');
    }
    checkActive();
    progress.pageCursor = '';
    progress.nextCursor = '';
    final failureCounts = failureStore.readCounts(
      preferences,
      keys.failureStorageKey,
    );
    _applyFailureCounts(failureCounts);
    if (failureCounts.total == 0 && !progress.scanHasOmissions) {
      progress.lastCompleteAt = progress.lastVerifiedAt;
      await preferences.setInt(keys.lastCompleteKey, progress.lastCompleteAt);
    }
  }

  Future<void> _advanceScanCursor(
    SharedPreferences preferences,
    _BackupSessionKeys keys,
    PhotoPageResponse page,
  ) async {
    if (!await preferences.setString(
      keys.storeVersionKey,
      page.storeVersionID,
    )) {
      throw StateError('无法保存手机相册版本，请重新检查。');
    }
    if (!await preferences.setString(keys.cursorKey, page.nextCursor)) {
      throw StateError('无法保存照片分页进度，请重新检查。');
    }
    progress.pageCursor = page.nextCursor;
    progress.nextCursor = page.nextCursor;
    checkActive();
  }

  Future<bool> _recordOmittedPageItems(
    SharedPreferences preferences,
    String failureStorageKey,
    String storeVersionID,
    Iterable<Map<String, dynamic>> omittedItems,
  ) async {
    var hasOmissions = false;
    for (final item in omittedItems) {
      checkActive();
      final id = item['id']?.toString() ?? '';
      if (!_omittedAssetIdPattern.hasMatch(id)) {
        hasOmissions = true;
        continue;
      }
      final modified = (item['modified'] as num?)?.toInt() ?? 0;
      final size = (item['size'] as num?)?.toInt() ?? 0;
      final generation = (item['generation'] as num?)?.toInt() ?? 0;
      final counts = await failureStore.record(
        preferences,
        failureStorageKey,
        failureStore.assetKey(
          id: id,
          modified: modified,
          listedSize: size,
          generation: generation,
          storeVersionID: storeVersionID,
          includeVideos: options.includeVideos,
        ),
        item['reason'] == 'oversized' ? 'oversized' : 'source_unavailable',
        name: item['name']?.toString() ?? '',
        assetId: id,
      );
      _applyFailureCounts(counts);
      hasOmissions = true;
      checkActive();
    }
    return hasOmissions;
  }

  void _applyFailureCounts(PhotoFailureCounts counts) {
    progress.failed = counts.total;
    progress.omittedFailures = counts.omitted;
  }

  String _buildCompletionMessage({required bool complete}) {
    final unit = options.includeVideos ? '项' : '张';
    final progressTail =
        complete && progress.failed == 0 && !progress.scanHasOmissions
        ? ' 已检查至相册末尾。'
        : complete && progress.failed > 0
        ? ' 已扫描至相册末尾，但 ${progress.failed} 项原片尚未备份，已登记待处理，未标记完整。'
        : complete
        ? ' 已扫描至相册末尾，但有照片或视频未能备份，未标记完整。'
        : ' 已保存进度，可继续备份更早的照片。';
    final omissionNotice =
        progress.scanHasOmissions && progress.oversizedSkipped == 0
        ? ' 本轮或之前的批次存在无法识别或超出限制的项目，请从最新照片重新检查并在手机上核对。'
        : '';
    final capNotice = progress.omittedFailures > 0
        ? ' 其中 ${progress.omittedFailures} 项超过本机 $maxTrackedPhotoFailures 条失败记录上限，完整状态会保持未完成；从最新照片重新检查可重试。'
        : '';
    final oversizedNotice = progress.oversizedSkipped > 0
        ? ' 本批有 ${progress.oversizedSkipped} 项超过备份单文件大小限制，尚未备份；请通过文件管理器单独上传。'
        : '';
    return '本轮结束：新增 ${progress.uploaded} $unit，已备份跳过 ${progress.skipped} $unit。'
        '$progressTail$omissionNotice$capNotice$oversizedNotice';
  }
}
