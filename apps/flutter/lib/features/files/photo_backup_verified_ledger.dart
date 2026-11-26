import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'photo_backup_prefs_schema.dart';

const int maxVerifiedPhotoLedgerEntries = 2000;
final RegExp _sha256HexPattern = RegExp(r'^[a-f0-9]{64}$');

enum SpaceReleaseFilter { all, olderThan30Days, olderThan90Days, videosOnly, byAlbum }

enum RemoteReleaseVerifyStatus {
  verified,
  missing,
  mismatch,
  unverifiableLargeFile,
  rootChangedOrOffline,
  error,
}

class RemoteReleaseVerifyOutcome {
  const RemoteReleaseVerifyOutcome({
    required this.status,
    required this.reason,
  });

  final RemoteReleaseVerifyStatus status;
  final String reason;

  bool get isVerified => status == RemoteReleaseVerifyStatus.verified;
  bool get shouldAbortBatch =>
      status == RemoteReleaseVerifyStatus.rootChangedOrOffline;
}

class SpaceReleaseSkippedItem {
  const SpaceReleaseSkippedItem({
    required this.record,
    required this.reason,
    required this.status,
  });

  final VerifiedPhotoBackupRecord record;
  final String reason;
  final RemoteReleaseVerifyStatus status;
}

class SpaceReleaseVerificationSummary {
  const SpaceReleaseVerificationSummary({
    required this.verified,
    required this.skipped,
    required this.aborted,
    required this.cancelled,
    this.abortMessage,
  });

  final List<VerifiedPhotoBackupRecord> verified;
  final List<SpaceReleaseSkippedItem> skipped;
  final bool aborted;
  final bool cancelled;
  final String? abortMessage;

  int get verifiedBytes =>
      verified.fold<int>(0, (sum, item) => sum + item.sizeBytes);
}

class SpaceReleaseExecutionResult {
  const SpaceReleaseExecutionResult({
    required this.deleted,
    required this.cancelled,
    required this.deletedCount,
    required this.freedBytes,
    required this.alreadyMissingCount,
    required this.message,
  });

  final bool deleted;
  final bool cancelled;
  final int deletedCount;
  final int freedBytes;
  final int alreadyMissingCount;
  final String message;
}

/// Immutable record of a local asset that was uploaded or verified on NAS
/// under a specific `origin + account + deviceId + rootIdentity` scope.
class VerifiedPhotoBackupRecord {
  const VerifiedPhotoBackupRecord({
    required this.assetId,
    required this.remotePath,
    required this.sha256,
    required this.sizeBytes,
    required this.capturedAtMs,
    required this.backedUpAtMs,
    required this.isVideo,
    required this.albumName,
    this.chunkDigests = const <String>[],
  });

  final String assetId;
  final String remotePath;
  final String sha256;
  final int sizeBytes;
  final int capturedAtMs;
  final int backedUpAtMs;
  final bool isVideo;
  final String albumName;
  final List<String> chunkDigests;

  String get displayName {
    final slash = remotePath.lastIndexOf('/');
    return slash >= 0 ? remotePath.substring(slash + 1) : remotePath;
  }

  Map<String, dynamic> toJson() => {
    'assetId': assetId,
    'remotePath': remotePath,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'capturedAtMs': capturedAtMs,
    'backedUpAtMs': backedUpAtMs,
    'isVideo': isVideo,
    'albumName': albumName,
    if (chunkDigests.isNotEmpty) 'chunkDigests': chunkDigests,
  };

  static VerifiedPhotoBackupRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final assetId = raw['assetId']?.toString().trim() ?? '';
    final remotePath = raw['remotePath']?.toString().trim() ?? '';
    final sha256 = raw['sha256']?.toString().trim() ?? '';
    final sizeBytes = (raw['sizeBytes'] as num?)?.toInt() ?? 0;
    final capturedAtMs = (raw['capturedAtMs'] as num?)?.toInt() ?? 0;
    final backedUpAtMs = (raw['backedUpAtMs'] as num?)?.toInt() ?? 0;
    if (assetId.isEmpty ||
        remotePath.isEmpty ||
        !_sha256HexPattern.hasMatch(sha256) ||
        sizeBytes <= 0) {
      return null;
    }
    final rawChunks = raw['chunkDigests'];
    final chunkDigests = rawChunks is List
        ? rawChunks
              .map((e) => e.toString())
              .where(_sha256HexPattern.hasMatch)
              .toList(growable: false)
        : const <String>[];
    return VerifiedPhotoBackupRecord(
      assetId: assetId,
      remotePath: remotePath,
      sha256: sha256,
      sizeBytes: sizeBytes,
      capturedAtMs: capturedAtMs,
      backedUpAtMs: backedUpAtMs,
      isVideo: raw['isVideo'] == true,
      albumName: raw['albumName']?.toString().trim() ?? '',
      chunkDigests: chunkDigests,
    );
  }
}

/// Bounded local ledger of verified backed-up assets scoped by
/// `origin + account + deviceId + rootIdentity`. Used exclusively as a
/// candidate index for space release; online SHA-256 verification is always
/// required before requesting OS deletion.
class PhotoBackupVerifiedLedger {
  const PhotoBackupVerifiedLedger({
    this.maxEntries = maxVerifiedPhotoLedgerEntries,
  });

  final int maxEntries;

  List<VerifiedPhotoBackupRecord> read(
    SharedPreferences prefs,
    PhotoBackupPrefsSchema schema,
  ) {
    final encoded = prefs.getString(schema.verifiedLedgerKey);
    if (encoded == null || encoded.isEmpty) return <VerifiedPhotoBackupRecord>[];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return <VerifiedPhotoBackupRecord>[];
      final records = <VerifiedPhotoBackupRecord>[];
      for (final item in decoded) {
        final parsed = VerifiedPhotoBackupRecord.fromJson(item);
        if (parsed != null) records.add(parsed);
      }
      return records;
    } catch (_) {
      return <VerifiedPhotoBackupRecord>[];
    }
  }

  Future<List<VerifiedPhotoBackupRecord>> upsert(
    SharedPreferences prefs,
    PhotoBackupPrefsSchema schema,
    VerifiedPhotoBackupRecord record,
  ) async {
    if (record.assetId.isEmpty ||
        record.remotePath.isEmpty ||
        record.sizeBytes <= 0 ||
        !_sha256HexPattern.hasMatch(record.sha256)) {
      return read(prefs, schema);
    }
    final byId = <String, VerifiedPhotoBackupRecord>{
      for (final existing in read(prefs, schema)) existing.assetId: existing,
    };
    byId[record.assetId] = record;
    final updated = _enforceBounds(byId.values.toList());
    await _write(prefs, schema, updated);
    return updated;
  }

  Future<List<VerifiedPhotoBackupRecord>> removeAssetIds(
    SharedPreferences prefs,
    PhotoBackupPrefsSchema schema,
    Set<String> assetIds,
  ) async {
    final current = read(prefs, schema);
    if (assetIds.isEmpty || current.isEmpty) return current;
    final remaining = current
        .where((item) => !assetIds.contains(item.assetId))
        .toList();
    if (remaining.length != current.length) {
      await _write(prefs, schema, remaining);
    }
    return remaining;
  }

  List<VerifiedPhotoBackupRecord> _enforceBounds(
    List<VerifiedPhotoBackupRecord> records,
  ) {
    records.sort((a, b) => b.backedUpAtMs.compareTo(a.backedUpAtMs));
    if (records.length <= maxEntries) return records;
    return records.sublist(0, maxEntries);
  }

  Future<void> _write(
    SharedPreferences prefs,
    PhotoBackupPrefsSchema schema,
    List<VerifiedPhotoBackupRecord> records,
  ) async {
    final payload = jsonEncode(
      records.map((item) => item.toJson()).toList(growable: false),
    );
    await prefs.setString(schema.verifiedLedgerKey, payload);
  }

  static List<VerifiedPhotoBackupRecord> filterRecords(
    List<VerifiedPhotoBackupRecord> records, {
    required SpaceReleaseFilter filter,
    String? albumName,
    int? minAgeDaysOverride,
    DateTime? now,
  }) {
    final reference = (now ?? DateTime.now()).millisecondsSinceEpoch;
    int? ageDays = minAgeDaysOverride;
    if (ageDays == null) {
      if (filter == SpaceReleaseFilter.olderThan30Days) ageDays = 30;
      if (filter == SpaceReleaseFilter.olderThan90Days) ageDays = 90;
    }
    final cutoffMs = ageDays != null && ageDays > 0
        ? reference - Duration(days: ageDays).inMilliseconds
        : null;

    return records.where((item) {
      if (cutoffMs != null) {
        final stamp = item.capturedAtMs > 0
            ? item.capturedAtMs
            : item.backedUpAtMs;
        if (stamp <= 0 || stamp > cutoffMs) return false;
      }
      if (filter == SpaceReleaseFilter.videosOnly && !item.isVideo) {
        return false;
      }
      if (filter == SpaceReleaseFilter.byAlbum &&
          albumName != null &&
          albumName.isNotEmpty &&
          item.albumName != albumName) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  static int totalBytes(Iterable<VerifiedPhotoBackupRecord> records) =>
      records.fold<int>(0, (sum, item) => sum + item.sizeBytes);

  static List<String> distinctAlbums(
    Iterable<VerifiedPhotoBackupRecord> records,
  ) {
    final names = records
        .map((item) => item.albumName.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    names.sort();
    return names;
  }
}
