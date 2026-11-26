import 'dart:collection';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/isle_formatters.dart';
import '../../core/user_facing_error.dart';
import 'mobile_photo_backup_transfer_client.dart';
import 'photo_backup_prefs_schema.dart';
import 'photo_backup_verified_ledger.dart';

/// Maximum unique native assets submitted in a single OS delete confirmation.
const int maxNativePhotoDeleteBatchSize = 500;

/// Coordinates fail-closed online/local verification and batched OS-confirmed
/// local original deletion for mobile photo backup space release.
class MobilePhotoSpaceReleaseService {
  const MobilePhotoSpaceReleaseService({
    required this.transfer,
    required this.verifiedLedger,
    required this.isIOS,
    required this.isDisposed,
  });

  final MobilePhotoBackupTransferClient transfer;
  final PhotoBackupVerifiedLedger verifiedLedger;
  final bool isIOS;
  final bool Function() isDisposed;

  Future<SpaceReleaseVerificationSummary> verifyCandidates({
    required List<VerifiedPhotoBackupRecord> candidates,
    required bool includeVideos,
    required void Function(int checked, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    if (candidates.isEmpty) {
      return const SpaceReleaseVerificationSummary(
        verified: <VerifiedPhotoBackupRecord>[],
        skipped: <SpaceReleaseSkippedItem>[],
        aborted: false,
        cancelled: false,
      );
    }
    try {
      final rootOnline = await transfer.verifyBoundRootOnline();
      if (!rootOnline) {
        return const SpaceReleaseVerificationSummary(
          verified: <VerifiedPhotoBackupRecord>[],
          skipped: <SpaceReleaseSkippedItem>[],
          aborted: true,
          cancelled: false,
          abortMessage: '照片存储硬盘已离线或已更换，无法核验远端原片；已中止释放并保留全部手机原片。',
        );
      }
    } catch (error) {
      return SpaceReleaseVerificationSummary(
        verified: const <VerifiedPhotoBackupRecord>[],
        skipped: const <SpaceReleaseSkippedItem>[],
        aborted: true,
        cancelled: false,
        abortMessage: '无法连接 NAS 确认硬盘状态（${userFacingError(error)}），已保留全部手机原片。',
      );
    }

    if (isIOS) {
      return _verifyIosGroupedCandidates(
        candidates: candidates,
        includeVideos: includeVideos,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    return _verifyIndividualCandidates(
      candidates: candidates,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<SpaceReleaseVerificationSummary> _verifyIndividualCandidates({
    required List<VerifiedPhotoBackupRecord> candidates,
    required void Function(int checked, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final verified = <VerifiedPhotoBackupRecord>[];
    final skipped = <SpaceReleaseSkippedItem>[];
    final total = candidates.length;
    for (var i = 0; i < total; i++) {
      if (isCancelled() || isDisposed()) {
        return SpaceReleaseVerificationSummary(
          verified: const <VerifiedPhotoBackupRecord>[],
          skipped: skipped,
          aborted: false,
          cancelled: true,
        );
      }
      onProgress(i + 1, total);
      final record = candidates[i];
      final outcome = await transfer.verifyRemoteAssetForRelease(record);
      if (outcome.shouldAbortBatch) {
        return SpaceReleaseVerificationSummary(
          verified: const <VerifiedPhotoBackupRecord>[],
          skipped: skipped,
          aborted: true,
          cancelled: false,
          abortMessage: outcome.reason,
        );
      }
      if (outcome.isVerified) {
        verified.add(record);
      } else {
        skipped.add(
          SpaceReleaseSkippedItem(
            record: record,
            reason: outcome.reason,
            status: outcome.status,
          ),
        );
      }
    }
    return SpaceReleaseVerificationSummary(
      verified: verified,
      skipped: skipped,
      aborted: false,
      cancelled: false,
    );
  }

  Future<SpaceReleaseVerificationSummary> _verifyIosGroupedCandidates({
    required List<VerifiedPhotoBackupRecord> candidates,
    required bool includeVideos,
    required void Function(int checked, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final groups = LinkedHashMap<String, List<VerifiedPhotoBackupRecord>>();
    for (final record in candidates) {
      final baseId = baseIosPhotoAssetId(record.assetId);
      groups.putIfAbsent(baseId, () => <VerifiedPhotoBackupRecord>[]).add(
        record,
      );
    }

    final Map<String, NativeIosAssetInspection> localStates;
    try {
      localStates = await transfer.inspectIosAssets(
        groups.keys.toList(growable: false),
      );
    } catch (error) {
      return SpaceReleaseVerificationSummary(
        verified: const <VerifiedPhotoBackupRecord>[],
        skipped: const <SpaceReleaseSkippedItem>[],
        aborted: true,
        cancelled: false,
        abortMessage:
            '无法核验本机 iOS 照片当前状态（${userFacingError(error)}），已中止释放并保留全部手机原片。',
      );
    }

    final verified = <VerifiedPhotoBackupRecord>[];
    final skipped = <SpaceReleaseSkippedItem>[];
    final total = candidates.length;
    var checked = 0;

    for (final entry in groups.entries) {
      final baseId = entry.key;
      final groupRecords = entry.value;
      if (isCancelled() || isDisposed()) {
        return SpaceReleaseVerificationSummary(
          verified: const <VerifiedPhotoBackupRecord>[],
          skipped: skipped,
          aborted: false,
          cancelled: true,
        );
      }

      final local = localStates[baseId];
      if (local == null) {
        checked += groupRecords.length;
        onProgress(checked, total);
        for (final record in groupRecords) {
          skipped.add(
            SpaceReleaseSkippedItem(
              record: record,
              reason: '未获取到该照片的本机状态核验信息，为保障安全已保留本机原片。',
              status: RemoteReleaseVerifyStatus.localModifiedOrIncomplete,
            ),
          );
        }
        continue;
      }

      final localBlockReason = _checkIosGroupLocalSafety(
        baseId: baseId,
        groupRecords: groupRecords,
        local: local,
        includeVideos: includeVideos,
      );
      if (localBlockReason != null) {
        checked += groupRecords.length;
        onProgress(checked, total);
        for (final record in groupRecords) {
          skipped.add(
            SpaceReleaseSkippedItem(
              record: record,
              reason: localBlockReason,
              status: RemoteReleaseVerifyStatus.localModifiedOrIncomplete,
            ),
          );
        }
        continue;
      }

      final outcomes = <VerifiedPhotoBackupRecord, RemoteReleaseVerifyOutcome>{};
      var allVerified = true;
      for (final record in groupRecords) {
        if (isCancelled() || isDisposed()) {
          return SpaceReleaseVerificationSummary(
            verified: const <VerifiedPhotoBackupRecord>[],
            skipped: skipped,
            aborted: false,
            cancelled: true,
          );
        }
        checked++;
        onProgress(checked, total);
        final outcome = await transfer.verifyRemoteAssetForRelease(record);
        if (outcome.shouldAbortBatch) {
          return SpaceReleaseVerificationSummary(
            verified: const <VerifiedPhotoBackupRecord>[],
            skipped: skipped,
            aborted: true,
            cancelled: false,
            abortMessage: outcome.reason,
          );
        }
        outcomes[record] = outcome;
        if (!outcome.isVerified) {
          allVerified = false;
        }
      }

      if (allVerified) {
        verified.addAll(groupRecords);
      } else {
        for (final record in groupRecords) {
          final outcome = outcomes[record]!;
          if (!outcome.isVerified) {
            skipped.add(
              SpaceReleaseSkippedItem(
                record: record,
                reason: outcome.reason,
                status: outcome.status,
              ),
            );
          } else {
            skipped.add(
              SpaceReleaseSkippedItem(
                record: record,
                reason: '同一项 iOS 照片（含 RAW 或 Live Photo 成分）存在未通过远端 SHA-256 核验的成分，整组已安全保留。',
                status: RemoteReleaseVerifyStatus.localModifiedOrIncomplete,
              ),
            );
          }
        }
      }
    }

    return SpaceReleaseVerificationSummary(
      verified: verified,
      skipped: skipped,
      aborted: false,
      cancelled: false,
    );
  }

  String? _checkIosGroupLocalSafety({
    required String baseId,
    required List<VerifiedPhotoBackupRecord> groupRecords,
    required NativeIosAssetInspection local,
    required bool includeVideos,
  }) {
    if (!local.exists) {
      // Already missing locally; remote SHA-256 will still run so stale ledger
      // entries can be cleaned cleanly without counting fake freedBytes.
      return null;
    }
    if (local.hasLiveVideo && !includeVideos) {
      return '该照片包含 Live Photo 动态视频，当前未开启“同时备份视频”，为避免删除时丢失动态视频已保留本机原片。';
    }
    final requiredIds = _resolveRequiredIosComponentIds(baseId, local);
    if (requiredIds.isEmpty) {
      return '无法确认该 iOS 照片的完整资源成分，已安全保留本机原片。';
    }
    final candidateIds = groupRecords.map((r) => r.assetId).toSet();
    final missingComponents = requiredIds
        .where((id) => !candidateIds.contains(id))
        .toList(growable: false);
    if (missingComponents.isNotEmpty) {
      final labels = missingComponents.map(_iosComponentLabel).toSet().join('、');
      return '该照片的 $labels 尚未全部入账或未包含在本次释放范围中，整项删除会导致未备份成分丢失，已安全保留。';
    }
    for (final record in groupRecords) {
      final currentGen =
          local.generations[record.assetId] ?? local.assetGeneration;
      if (record.assetGeneration <= 0 ||
          currentGen <= 0 ||
          currentGen != record.assetGeneration) {
        return '该照片在备份后已被二次编辑或缺少本机版本指纹，请重新备份后再释放，已保留本机原片。';
      }
    }
    return null;
  }

  Set<String> _resolveRequiredIosComponentIds(
    String baseId,
    NativeIosAssetInspection local,
  ) {
    final ids = <String>{...local.requiredAssetIds};
    if (local.hasPhoto) ids.add(baseId);
    if (local.hasRaw) ids.add('r.$baseId');
    if (local.hasLiveVideo) ids.add('l.$baseId');
    if (local.hasVideo && !local.hasPhoto) ids.add('v.$baseId');
    return ids;
  }

  String _iosComponentLabel(String assetId) {
    if (assetId.startsWith('l.')) return 'Live Photo 动态视频';
    if (assetId.startsWith('r.')) return 'RAW 伴随原片';
    if (assetId.startsWith('v.')) return '视频原片';
    return '主照片原片';
  }

  Future<SpaceReleaseExecutionResult> executeBatchedRelease({
    required List<VerifiedPhotoBackupRecord> verifiedRecords,
    required SharedPreferences? prefs,
    required PhotoBackupPrefsSchema schema,
    required bool hasDeviceId,
    required void Function(List<VerifiedPhotoBackupRecord> remaining)
    onLedgerUpdated,
    void Function(int currentBatch, int totalBatches, int deletedSoFar)?
    onBatchProgress,
  }) async {
    if (verifiedRecords.isEmpty) {
      return const SpaceReleaseExecutionResult(
        deleted: false,
        cancelled: false,
        deletedCount: 0,
        freedBytes: 0,
        alreadyMissingCount: 0,
        message: '没有通过远端 SHA-256 核验的可释放条目，本机原片未受影响。',
      );
    }

    final grouped = LinkedHashMap<String, List<VerifiedPhotoBackupRecord>>();
    for (final record in verifiedRecords) {
      final nativeId = isIOS
          ? baseIosPhotoAssetId(record.assetId)
          : record.assetId;
      grouped.putIfAbsent(nativeId, () => <VerifiedPhotoBackupRecord>[]).add(
        record,
      );
    }

    final uniqueNativeIds = grouped.keys.toList(growable: false);
    final totalBatches =
        (uniqueNativeIds.length + maxNativePhotoDeleteBatchSize - 1) ~/
        maxNativePhotoDeleteBatchSize;

    var totalDeletedCount = 0;
    var totalFreedBytes = 0;
    var totalAlreadyMissingCount = 0;
    var completedBatches = 0;

    for (var batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
      final start = batchIndex * maxNativePhotoDeleteBatchSize;
      final end = min(
        start + maxNativePhotoDeleteBatchSize,
        uniqueNativeIds.length,
      );
      final batchNativeIds = uniqueNativeIds.sublist(start, end);
      onBatchProgress?.call(batchIndex + 1, totalBatches, totalDeletedCount);

      final result = await transfer.requestDeleteAssets(batchNativeIds);
      if (result.cancelled || !result.deleted) {
        if (completedBatches == 0) {
          return const SpaceReleaseExecutionResult(
            deleted: false,
            cancelled: true,
            deletedCount: 0,
            freedBytes: 0,
            alreadyMissingCount: 0,
            message: '已取消系统删除确认，手机原片均已保留。',
          );
        }
        final partialMsg =
            '已在前 $completedBatches/$totalBatches 批释放 $totalDeletedCount 项本地原片'
            '（约 ${formatBytes(totalFreedBytes)}），后续批次已取消并保留剩余手机原片。';
        return SpaceReleaseExecutionResult(
          deleted: totalDeletedCount > 0 || totalAlreadyMissingCount > 0,
          cancelled: true,
          deletedCount: totalDeletedCount,
          freedBytes: totalFreedBytes,
          alreadyMissingCount: totalAlreadyMissingCount,
          message: partialMsg,
        );
      }

      completedBatches++;
      totalDeletedCount += result.deletedCount;
      totalAlreadyMissingCount += result.alreadyMissingCount;
      totalFreedBytes += _computeBatchFreedBytes(
        batchNativeIds: batchNativeIds,
        grouped: grouped,
        result: result,
      );

      final batchLedgerIds = <String>{};
      for (final nativeId in batchNativeIds) {
        for (final record in grouped[nativeId]!) {
          batchLedgerIds.add(record.assetId);
        }
      }
      if (prefs != null && hasDeviceId) {
        final remaining = await verifiedLedger.removeAssetIds(
          prefs,
          schema,
          batchLedgerIds,
        );
        if (!isDisposed()) {
          onLedgerUpdated(remaining);
        }
      }
    }

    final summary = _formatSummary(
      deletedCount: totalDeletedCount,
      freedBytes: totalFreedBytes,
      alreadyMissingCount: totalAlreadyMissingCount,
    );
    return SpaceReleaseExecutionResult(
      deleted: true,
      cancelled: false,
      deletedCount: totalDeletedCount,
      freedBytes: totalFreedBytes,
      alreadyMissingCount: totalAlreadyMissingCount,
      message: summary,
    );
  }

  int _computeBatchFreedBytes({
    required List<String> batchNativeIds,
    required LinkedHashMap<String, List<VerifiedPhotoBackupRecord>> grouped,
    required NativePhotoDeleteResult result,
  }) {
    if (result.deletedCount <= 0) return 0;
    if (result.deletedAssetIds.isNotEmpty) {
      final deletedKeys = result.deletedAssetIds
          .map((id) => isIOS ? baseIosPhotoAssetId(id) : id)
          .toSet();
      var sum = 0;
      for (final nativeId in batchNativeIds) {
        if (!deletedKeys.contains(nativeId)) continue;
        for (final record in grouped[nativeId]!) {
          sum += record.sizeBytes;
        }
      }
      return sum;
    }
    var batchTotalBytes = 0;
    for (final nativeId in batchNativeIds) {
      for (final record in grouped[nativeId]!) {
        batchTotalBytes += record.sizeBytes;
      }
    }
    if (result.alreadyMissingCount <= 0 ||
        result.deletedCount >= batchNativeIds.length) {
      return batchTotalBytes;
    }
    return ((batchTotalBytes * result.deletedCount) / batchNativeIds.length)
        .round();
  }

  String _formatSummary({
    required int deletedCount,
    required int freedBytes,
    required int alreadyMissingCount,
  }) {
    if (deletedCount > 0 && alreadyMissingCount > 0) {
      return '已由系统确认释放 $deletedCount 项本地原片（约 ${formatBytes(freedBytes)}），'
          '另有 $alreadyMissingCount 项已不在本机相册中并已同步更新记录，NAS 远端备份完整保留。';
    }
    if (deletedCount > 0) {
      return '已由系统确认释放 $deletedCount 项本地原片（约 ${formatBytes(freedBytes)}），NAS 远端备份完整保留。';
    }
    return '所选 $alreadyMissingCount 项原片已不在本机相册中，已同步更新本地记录。';
  }
}
