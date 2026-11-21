import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'photo_backup_prefs_schema.dart';

const int maxTrackedPhotoFailures = 512;
const int _maxOmittedPhotoFailures = 1 << 30;
const int _maxFailureNameLength = 160;
const int _maxFailureAssetIdLength = 202;

const Set<String> _iosRecoverablePrepareErrorCodes = {
  'asset_unavailable',
  'icloud_download_required',
  'photo_export_failed',
  'photo_size_invalid',
  'invalid_asset',
};

const Set<String> _androidRecoverablePrepareErrorCodes = {
  'photo_prepare_failed',
  'photo_source_changed',
};

class PhotoFailureCounts {
  const PhotoFailureCounts(this.tracked, this.omitted);

  final int tracked;
  final int omitted;

  int get total => tracked + omitted;
}

String photoFailureReasonLabel(String? reason) => switch (reason) {
  'icloud_not_downloaded' => '保存在 iCloud 云端，本机尚未下载原片',
  'oversized' => '超过单文件备份大小限制，尚未备份',
  'source_changed' => '原片在备份读取期间发生变化',
  'source_unreadable' => '无法读取本机原片，请检查权限或文件状态',
  _ => '原片暂不可用或发生变化',
};

/// Persists bounded retryable photo-backup failure records in SharedPreferences
/// and classifies recoverable native export/prepare errors per platform.
class MobilePhotoBackupFailureStore {
  const MobilePhotoBackupFailureStore({
    required this.isAndroid,
    required this.isIOS,
  });

  final bool isAndroid;
  final bool isIOS;

  String assetKey({
    required String id,
    required int modified,
    required int listedSize,
    required int generation,
    required String storeVersionID,
    required bool includeVideos,
  }) => sha256
      .convert(
        utf8.encode(
          '$id|$modified|$listedSize|$generation|$storeVersionID|$includeVideos',
        ),
      )
      .toString();

  List<Map<String, dynamic>> read(
    SharedPreferences preferences,
    String storageKey,
  ) {
    final encoded = preferences.getString(storageKey);
    if (encoded == null || encoded.isEmpty) return <Map<String, dynamic>>[];
    final decoded = jsonDecode(encoded);
    if (decoded is! List || decoded.length > maxTrackedPhotoFailures) {
      throw StateError('本机失败重试记录无效，不能确认备份完整。');
    }
    final rows = <Map<String, dynamic>>[];
    for (final value in decoded) {
      if (value is! Map || value['key'] is! String) {
        throw StateError('本机失败重试记录无效，不能确认备份完整。');
      }
      rows.add(value.cast<String, dynamic>());
    }
    return rows;
  }

  PhotoFailureCounts readCounts(
    SharedPreferences preferences,
    String storageKey,
  ) {
    final rows = read(preferences, storageKey);
    final omitted =
        preferences.getInt(PhotoBackupPrefsSchema.failureOmittedKey(storageKey)) ??
        0;
    return PhotoFailureCounts(
      rows.length,
      omitted.clamp(0, _maxOmittedPhotoFailures).toInt(),
    );
  }

  Future<PhotoFailureCounts> record(
    SharedPreferences preferences,
    String storageKey,
    String assetKey,
    String reason, {
    String name = '',
    String assetId = '',
  }) async {
    final rows = read(preferences, storageKey);
    final index = rows.indexWhere((row) => row['key'] == assetKey);
    final safeName = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    final safeId = assetId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '');
    final row = <String, dynamic>{
      'key': assetKey,
      'reason': reason,
      if (safeName.isNotEmpty)
        'name': safeName.substring(0, min(safeName.length, _maxFailureNameLength)),
      if (safeId.isNotEmpty)
        'id': safeId.substring(0, min(safeId.length, _maxFailureAssetIdLength)),
    };
    if (index >= 0) {
      rows[index] = row;
    } else if (rows.length < maxTrackedPhotoFailures) {
      rows.add(row);
    } else {
      final omittedKey = PhotoBackupPrefsSchema.failureOmittedKey(storageKey);
      final omitted = preferences.getInt(omittedKey) ?? 0;
      if (!await preferences.setInt(
        omittedKey,
        (omitted + 1).clamp(0, _maxOmittedPhotoFailures).toInt(),
      )) {
        throw StateError('无法保存失败重试遗漏数，未推进照片分页进度。');
      }
    }
    if (!await preferences.setString(storageKey, jsonEncode(rows))) {
      throw StateError('无法保存失败重试记录，未推进照片分页进度。');
    }
    return readCounts(preferences, storageKey);
  }

  Future<PhotoFailureCounts> clear(
    SharedPreferences preferences,
    String storageKey,
    String assetKey,
  ) async {
    final rows = read(preferences, storageKey);
    final count = rows.length;
    rows.removeWhere((row) => row['key'] == assetKey);
    if (rows.length != count) {
      if (!await preferences.setString(storageKey, jsonEncode(rows))) {
        throw StateError('无法更新失败重试记录，未推进照片分页进度。');
      }
    }
    return readCounts(preferences, storageKey);
  }

  Future<PhotoFailureCounts> reset(
    SharedPreferences preferences,
    String storageKey,
    String storeVersionID,
  ) async {
    if (!await preferences.setString(storageKey, '[]')) {
      throw StateError('无法重置失败重试记录，未推进照片分页进度。');
    }
    if (!await preferences.setInt(
      PhotoBackupPrefsSchema.failureOmittedKey(storageKey),
      0,
    )) {
      throw StateError('无法重置失败重试遗漏数，未推进照片分页进度。');
    }
    if (!await preferences.setString(
      PhotoBackupPrefsSchema.failureVersionKey(storageKey),
      storeVersionID,
    )) {
      throw StateError('无法保存失败重试版本，未推进照片分页进度。');
    }
    return const PhotoFailureCounts(0, 0);
  }

  bool isRecoverablePrepareError(String code) => isIOS
      ? _iosRecoverablePrepareErrorCodes.contains(code)
      : isAndroid && _androidRecoverablePrepareErrorCodes.contains(code);

  String failureReasonForCode(String code) {
    if (code == 'icloud_download_required') return 'icloud_not_downloaded';
    if (code == 'photo_source_changed') return 'source_changed';
    return 'source_unavailable';
  }
}
