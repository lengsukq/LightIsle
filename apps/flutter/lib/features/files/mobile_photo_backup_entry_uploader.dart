import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import 'mobile_photo_backup_failure_store.dart';
import 'mobile_photo_backup_state_models.dart';
import 'mobile_photo_backup_transfer_client.dart';
import 'photo_backup_hash.dart';
import 'photo_backup_prefs_schema.dart';
import 'photo_backup_verified_ledger.dart';

const int _maxCachedRemoteVerifyBytes = 2 << 30;
const int _epochMillisThreshold = 100000000000;
const Set<String> _videoExtensions = {
  'mp4',
  'mov',
  'm4v',
  '3gp',
  'webm',
  'mkv',
  'avi',
};

final RegExp _sentRecordWithSizePattern = RegExp(
  r'^([a-f0-9]{64}):([1-9][0-9]{0,14})$',
);
final RegExp _sentRecordHashOnlyPattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp _iosAssetIdPattern = RegExp(r'^(?:[lvr][.])?[A-Za-z0-9_-]{1,200}$');
final RegExp _androidAssetIdPattern = RegExp(r'^[0-9]{1,20}$');

enum EntryBackupOutcome { uploaded, skipped, failed, omitted }

class _BackupAssetSpec {
  const _BackupAssetSpec({
    required this.id,
    required this.safeId,
    required this.name,
    required this.modified,
    required this.listedSize,
    required this.generation,
    required this.suffix,
    required this.albumName,
    required this.isVideo,
    required this.entryDir,
    required this.successKey,
    required this.failureAssetKey,
  });

  final String id;
  final String safeId;
  final String name;
  final int modified;
  final int listedSize;
  final int generation;
  final String suffix;
  final String albumName;
  final bool isVideo;
  final String entryDir;
  final String successKey;
  final String failureAssetKey;

  int get capturedAtMs => modified <= 0
      ? 0
      : (modified > _epochMillisThreshold ? modified : modified * 1000);

  String destinationPath(String digest) =>
      '$entryDir/photo_${safeId}_${modified}_${digest.substring(0, 16)}.$suffix';
}

/// Processes a single device photo/video entry: fast-path cached SHA-256 skip,
/// zero-copy Android stream or prepared file export/hash, conflict check,
/// chunked upload, and failure record updates.
class MobilePhotoBackupEntryUploader {
  const MobilePhotoBackupEntryUploader({
    required this.api,
    required this.isIOS,
    required this.progress,
    required this.options,
    required this.failureStore,
    required this.transfer,
    required this.prefsSchema,
    required this.checkActive,
    required this.isDisposed,
    required this.onChanged,
    required this.onFailureCounts,
    this.onAssetVerified,
  });

  final LightIsleApi api;
  final bool isIOS;
  final PhotoBackupRunProgressState progress;
  final PhotoBackupOptionsState options;
  final MobilePhotoBackupFailureStore failureStore;
  final MobilePhotoBackupTransferClient transfer;
  final PhotoBackupPrefsSchema Function() prefsSchema;
  final void Function() checkActive;
  final bool Function() isDisposed;
  final VoidCallback onChanged;
  final void Function(PhotoFailureCounts counts) onFailureCounts;
  final Future<void> Function(VerifiedPhotoBackupRecord record)? onAssetVerified;

  Future<EntryBackupOutcome> processEntry({
    required Map<String, dynamic> entry,
    required int pageNumber,
    required bool supportsStream,
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String storeVersionID,
    required String destinationDir,
    required Set<String> ensuredSubdirs,
  }) async {
    checkActive();
    final spec = _parseAssetSpec(
      entry: entry,
      destinationDir: destinationDir,
      storeVersionID: storeVersionID,
    );
    if (spec == null) return EntryBackupOutcome.omitted;

    progress.checked++;
    if (!isDisposed()) {
      progress.message = '正在检查第 ${progress.checked} 张照片（第 $pageNumber 页）…';
      onChanged();
    }

    final skippedByCache = await _trySkipViaCachedDigest(
      spec: spec,
      storeVersionID: storeVersionID,
      preferences: preferences,
      failureStorageKey: failureStorageKey,
    );
    if (skippedByCache) return EntryBackupOutcome.skipped;

    if (supportsStream) {
      return _backupAndroidStreamEntry(
        spec: spec,
        preferences: preferences,
        failureStorageKey: failureStorageKey,
        destinationDir: destinationDir,
        ensuredSubdirs: ensuredSubdirs,
      );
    }
    return _backupPreparedFileEntry(
      spec: spec,
      preferences: preferences,
      failureStorageKey: failureStorageKey,
      destinationDir: destinationDir,
      ensuredSubdirs: ensuredSubdirs,
    );
  }

  _BackupAssetSpec? _parseAssetSpec({
    required Map<String, dynamic> entry,
    required String destinationDir,
    required String storeVersionID,
  }) {
    final id = entry['id']?.toString() ?? '';
    final name = entry['name']?.toString() ?? '';
    final modified = (entry['modified'] as num?)?.toInt() ?? 0;
    final listedSize = (entry['size'] as num?)?.toInt() ?? -1;
    final generation = (entry['generation'] as num?)?.toInt() ?? 0;
    final validId = isIOS
        ? _iosAssetIdPattern.hasMatch(id)
        : _androidAssetIdPattern.hasMatch(id);
    if (!validId || (!isIOS && listedSize <= 0)) return null;

    final safeId = isIOS
        ? sha256.convert(utf8.encode(id)).toString().substring(0, 24)
        : id;
    final suffix = normalizePhotoExtension(name);
    final albumName = (entry['bucketName'] ?? entry['albumName'] ?? '')
        .toString()
        .trim();
    final isVideo =
        entry['isVideo'] == true ||
        _videoExtensions.contains(suffix) ||
        id.startsWith('v.') ||
        id.startsWith('l.');
    return _BackupAssetSpec(
      id: id,
      safeId: safeId,
      name: name,
      modified: modified,
      listedSize: listedSize,
      generation: generation,
      suffix: suffix,
      albumName: albumName,
      isVideo: isVideo,
      entryDir: _targetDirectoryForEntry(destinationDir, modified, albumName),
      successKey: prefsSchema().sentKey(
        id: id,
        modified: modified,
        listedSize: listedSize,
        generation: generation,
        storeVersionId: storeVersionID,
      ),
      failureAssetKey: failureStore.assetKey(
        id: id,
        modified: modified,
        listedSize: listedSize,
        generation: generation,
        storeVersionID: storeVersionID,
        includeVideos: options.includeVideos,
      ),
    );
  }

  Future<bool> _trySkipViaCachedDigest({
    required _BackupAssetSpec spec,
    required String storeVersionID,
    required SharedPreferences preferences,
    required String failureStorageKey,
  }) async {
    final verifiedRecord = _parseVerifiedSentRecord(
      preferences.getString(spec.successKey),
      spec.listedSize,
    );
    if (spec.generation <= 0 ||
        storeVersionID.isEmpty ||
        verifiedRecord == null ||
        verifiedRecord.size > _maxCachedRemoteVerifyBytes) {
      return false;
    }
    final existing = spec.destinationPath(verifiedRecord.digest);
    final cachedMatch = await api.remoteFileMatchesSHA256(
      existing,
      verifiedRecord.size,
      verifiedRecord.digest,
      checkActive: checkActive,
    );
    checkActive();
    if (cachedMatch) {
      await _recordVerifiedAsset(
        spec: spec,
        remotePath: existing,
        digest: verifiedRecord.digest,
        exactSize: verifiedRecord.size,
        chunkDigests: const <String>[],
      );
      await _clearEntryFailure(
        preferences,
        failureStorageKey,
        spec.failureAssetKey,
      );
      progress.skipped++;
      return true;
    }
    checkActive();
    await preferences.remove(spec.successKey);
    checkActive();
    return false;
  }

  Future<EntryBackupOutcome> _backupAndroidStreamEntry({
    required _BackupAssetSpec spec,
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String destinationDir,
    required Set<String> ensuredSubdirs,
  }) async {
    final NativeStreamInspection inspection;
    try {
      inspection = await transfer.inspectAndroidStreamAsset(
        deviceId: options.deviceId,
        id: spec.id,
        includeVideos: options.includeVideos,
        checkActive: checkActive,
      );
    } on PlatformException catch (error) {
      checkActive();
      if (!failureStore.isRecoverablePrepareError(error.code)) rethrow;
      await _recordEntryFailure(
        preferences,
        failureStorageKey,
        spec,
        failureStore.failureReasonForCode(error.code),
      );
      return EntryBackupOutcome.failed;
    }
    if (inspection.size != spec.listedSize ||
        inspection.modified != spec.modified ||
        inspection.generation != spec.generation) {
      await _recordEntryFailure(
        preferences,
        failureStorageKey,
        spec,
        'source_changed',
      );
      return EntryBackupOutcome.failed;
    }
    try {
      return await _verifyAndUploadHashedAsset(
        spec: spec,
        preferences: preferences,
        failureStorageKey: failureStorageKey,
        destinationDir: destinationDir,
        ensuredSubdirs: ensuredSubdirs,
        exactSize: inspection.size,
        digest: inspection.digest,
        chunkDigests: inspection.chunkDigests,
        performUpload: (destination, uploadKey) =>
            transfer.uploadFromChunkProvider(
              preferences: preferences,
              wifiOnly: options.wifiOnly,
              size: inspection.size,
              destination: destination,
              key: uploadKey,
              digest: inspection.digest,
              chunkSHA256s: inspection.chunkDigests,
              checkActive: checkActive,
              openChunk: (offset, length) async {
                final bytes = await transfer.readAndroidStreamChunk(
                  deviceId: options.deviceId,
                  id: spec.id,
                  includeVideos: options.includeVideos,
                  offset: offset,
                  length: length,
                  inspection: inspection,
                  checkActive: checkActive,
                );
                return Stream<List<int>>.value(bytes);
              },
            ),
      );
    } on PlatformException catch (error) {
      checkActive();
      if (error.code != 'photo_source_changed') rethrow;
      await _recordEntryFailure(
        preferences,
        failureStorageKey,
        spec,
        'source_changed',
      );
      return EntryBackupOutcome.failed;
    }
  }

  Future<EntryBackupOutcome> _backupPreparedFileEntry({
    required _BackupAssetSpec spec,
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String destinationDir,
    required Set<String> ensuredSubdirs,
  }) async {
    String? temporary;
    try {
      Map<String, dynamic>? prepared;
      try {
        prepared = await transfer.preparePhoto(
          deviceId: options.deviceId,
          id: spec.id,
          includeVideos: options.includeVideos,
          isIOS: isIOS,
          allowICloudDownload: options.allowICloudDownload,
          checkActive: checkActive,
        );
      } on PlatformException catch (error) {
        checkActive();
        if (!failureStore.isRecoverablePrepareError(error.code)) rethrow;
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          spec,
          failureStore.failureReasonForCode(error.code),
        );
        return EntryBackupOutcome.failed;
      }

      temporary = prepared?['path']?.toString();
      checkActive();
      final exactSize = (prepared?['size'] as num?)?.toInt() ?? -1;
      if (temporary == null ||
          temporary.isEmpty ||
          exactSize <= 0 ||
          exactSize > maxPhotoBackupBytes ||
          (!isIOS && exactSize != spec.listedSize)) {
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          spec,
          'source_changed',
        );
        return EntryBackupOutcome.failed;
      }

      final file = File(temporary);
      final PhotoHashResult localHash;
      try {
        localHash = await hashBackupPhoto(
          file,
          exactSize,
          checkActive: checkActive,
        );
      } on PhotoSourceChanged {
        checkActive();
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          spec,
          'source_unreadable',
        );
        return EntryBackupOutcome.failed;
      } on FileSystemException {
        checkActive();
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          spec,
          'source_unreadable',
        );
        return EntryBackupOutcome.failed;
      }
      checkActive();

      return await _verifyAndUploadHashedAsset(
        spec: spec,
        preferences: preferences,
        failureStorageKey: failureStorageKey,
        destinationDir: destinationDir,
        ensuredSubdirs: ensuredSubdirs,
        exactSize: exactSize,
        digest: localHash.digest,
        chunkDigests: localHash.chunkDigests,
        performUpload: (destination, uploadKey) => transfer.uploadFile(
          preferences: preferences,
          wifiOnly: options.wifiOnly,
          source: file,
          size: exactSize,
          destination: destination,
          key: uploadKey,
          digest: localHash.digest,
          chunkDigests: localHash.chunkDigests,
          checkActive: checkActive,
        ),
      );
    } finally {
      if (temporary != null) {
        await transfer.releasePreparedPhoto(temporary);
      }
    }
  }

  Future<EntryBackupOutcome> _verifyAndUploadHashedAsset({
    required _BackupAssetSpec spec,
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String destinationDir,
    required Set<String> ensuredSubdirs,
    required int exactSize,
    required String digest,
    required List<String> chunkDigests,
    required Future<void> Function(String destination, String uploadKey)
    performUpload,
  }) async {
    await transfer.ensureTargetSubdirectory(
      destinationDir,
      spec.entryDir,
      ensuredSubdirs,
      checkActive: checkActive,
    );
    final destination = spec.destinationPath(digest);
    final uploadKey = prefsSchema().uploadKey(
      rawId: spec.id,
      modified: spec.modified,
      digest: digest,
    );
    final alreadyPresent = await api.remoteFileMatchesSHA256(
      destination,
      exactSize,
      digest,
      chunkSHA256s: chunkDigests,
      checkActive: checkActive,
    );
    checkActive();
    if (alreadyPresent) {
      await preferences.setString(
        spec.successKey,
        _formatVerifiedSentRecord(digest, exactSize),
      );
      checkActive();
      await preferences.remove(uploadKey);
      checkActive();
      await _recordVerifiedAsset(
        spec: spec,
        remotePath: destination,
        digest: digest,
        exactSize: exactSize,
        chunkDigests: chunkDigests,
      );
      checkActive();
      await _clearEntryFailure(
        preferences,
        failureStorageKey,
        spec.failureAssetKey,
      );
      progress.skipped++;
      return EntryBackupOutcome.skipped;
    }

    checkActive();
    final sameSizeExists = await api.remoteFileHasSize(destination, exactSize);
    checkActive();
    if (sameSizeExists) {
      throw StateError('NAS 目标文件已存在但 SHA-256 与手机不一致；请先人工核对，不能自动覆盖。');
    }

    checkActive();
    await performUpload(destination, uploadKey);
    checkActive();
    await preferences.setString(
      spec.successKey,
      _formatVerifiedSentRecord(digest, exactSize),
    );
    checkActive();
    await _recordVerifiedAsset(
      spec: spec,
      remotePath: destination,
      digest: digest,
      exactSize: exactSize,
      chunkDigests: chunkDigests,
    );
    checkActive();
    await _clearEntryFailure(
      preferences,
      failureStorageKey,
      spec.failureAssetKey,
    );
    progress.uploaded++;
    return EntryBackupOutcome.uploaded;
  }

  Future<void> _recordVerifiedAsset({
    required _BackupAssetSpec spec,
    required String remotePath,
    required String digest,
    required int exactSize,
    required List<String> chunkDigests,
  }) async {
    final callback = onAssetVerified;
    if (callback == null || exactSize <= 0) return;
    await callback(
      VerifiedPhotoBackupRecord(
        assetId: spec.id,
        remotePath: remotePath,
        sha256: digest,
        sizeBytes: exactSize,
        capturedAtMs: spec.capturedAtMs,
        backedUpAtMs: DateTime.now().millisecondsSinceEpoch,
        isVideo: spec.isVideo,
        albumName: spec.albumName,
        chunkDigests: chunkDigests,
        assetGeneration: spec.generation,
      ),
    );
  }

  ({String digest, int size})? _parseVerifiedSentRecord(
    String? raw,
    int listedSize,
  ) {
    if (raw == null || raw.isEmpty) return null;
    final withSize = _sentRecordWithSizePattern.firstMatch(raw);
    if (withSize != null) {
      final digest = withSize.group(1)!;
      final savedSize = int.tryParse(withSize.group(2)!);
      if (savedSize == null || savedSize <= 0) return null;
      if (!isIOS && listedSize > 0 && savedSize != listedSize) return null;
      return (digest: digest, size: savedSize);
    }
    if (_sentRecordHashOnlyPattern.hasMatch(raw) && listedSize > 0) {
      return (digest: raw, size: listedSize);
    }
    return null;
  }

  String _formatVerifiedSentRecord(String digest, int exactSize) =>
      isIOS ? '$digest:$exactSize' : digest;

  String _targetDirectoryForEntry(
    String destinationDir,
    int modified,
    String albumName,
  ) => PhotoBackupPrefsSchema.resolveTargetDirectory(
    destinationDir,
    organizeMode: options.organizeMode,
    modified: modified,
    albumName: albumName,
  );

  Future<void> _recordEntryFailure(
    SharedPreferences preferences,
    String failureStorageKey,
    _BackupAssetSpec spec,
    String reason,
  ) async {
    final counts = await failureStore.record(
      preferences,
      failureStorageKey,
      spec.failureAssetKey,
      reason,
      name: spec.name,
      assetId: spec.id,
    );
    onFailureCounts(counts);
  }

  Future<void> _clearEntryFailure(
    SharedPreferences preferences,
    String failureStorageKey,
    String failureAssetKey,
  ) async {
    final counts = await failureStore.clear(
      preferences,
      failureStorageKey,
      failureAssetKey,
    );
    onFailureCounts(counts);
  }
}
