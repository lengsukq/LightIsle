part of 'android_photo_backup_page.dart';

extension _AndroidPhotoBackupFailures on _AndroidPhotoBackupState {
  String _photoFailureStorageKey() =>
      '$_scope.failures.${_includeVideos ? "videos" : "photos"}';
  String _photoFailureAssetKey(
    String id,
    int modified,
    int listedSize,
    int generation,
    String storeVersionID,
  ) => sha256
      .convert(
        utf8.encode(
          '$id|$modified|$listedSize|$generation|$storeVersionID|$_includeVideos',
        ),
      )
      .toString();
  List<Map<String, dynamic>> _readPhotoFailures(
    SharedPreferences preferences,
    String storageKey,
  ) {
    final encoded = preferences.getString(storageKey);
    if (encoded == null || encoded.isEmpty) return <Map<String, dynamic>>[];
    final decoded = jsonDecode(encoded);
    if (decoded is! List || decoded.length > _maxTrackedPhotoFailures) {
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

  Future<_PhotoFailureCounts> _photoFailureCounts(
    SharedPreferences preferences,
    String storageKey,
  ) async {
    final rows = _readPhotoFailures(preferences, storageKey);
    final omitted = preferences.getInt('$storageKey.omitted') ?? 0;
    return _PhotoFailureCounts(rows.length, omitted.clamp(0, 1 << 30).toInt());
  }

  Future<_PhotoFailureCounts> _recordPhotoFailure(
    SharedPreferences preferences,
    String storageKey,
    String assetKey,
    String reason,
  ) async {
    final rows = _readPhotoFailures(preferences, storageKey);
    final index = rows.indexWhere((row) => row['key'] == assetKey);
    if (index >= 0) {
      rows[index] = <String, dynamic>{'key': assetKey, 'reason': reason};
    } else if (rows.length < _maxTrackedPhotoFailures) {
      rows.add(<String, dynamic>{'key': assetKey, 'reason': reason});
    } else {
      final omitted = preferences.getInt('$storageKey.omitted') ?? 0;
      if (!await preferences.setInt(
        '$storageKey.omitted',
        (omitted + 1).clamp(0, 1 << 30).toInt(),
      )) {
        throw StateError('无法保存失败重试遗漏数，未推进照片分页进度。');
      }
    }
    if (!await preferences.setString(storageKey, jsonEncode(rows))) {
      throw StateError('无法保存失败重试记录，未推进照片分页进度。');
    }
    return _photoFailureCounts(preferences, storageKey);
  }

  Future<_PhotoFailureCounts> _clearPhotoFailure(
    SharedPreferences preferences,
    String storageKey,
    String assetKey,
  ) async {
    final rows = _readPhotoFailures(preferences, storageKey);
    final count = rows.length;
    rows.removeWhere((row) => row['key'] == assetKey);
    if (rows.length != count) {
      if (!await preferences.setString(storageKey, jsonEncode(rows))) {
        throw StateError('无法更新失败重试记录，未推进照片分页进度。');
      }
    }
    return _photoFailureCounts(preferences, storageKey);
  }

  Future<_PhotoFailureCounts> _resetPhotoFailures(
    SharedPreferences preferences,
    String storageKey,
    String storeVersionID,
  ) async {
    if (!await preferences.setString(storageKey, '[]')) {
      throw StateError('无法重置失败重试记录，未推进照片分页进度。');
    }
    if (!await preferences.setInt('$storageKey.omitted', 0)) {
      throw StateError('无法重置失败重试遗漏数，未推进照片分页进度。');
    }
    if (!await preferences.setString('$storageKey.version', storeVersionID)) {
      throw StateError('无法保存失败重试版本，未推进照片分页进度。');
    }
    return const _PhotoFailureCounts(0, 0);
  }

  bool _isRecoverablePhotoPrepareError(String code) => _isIOS
      ? const {
          'asset_unavailable',
          'photo_export_failed',
          'photo_size_invalid',
          'invalid_asset',
        }.contains(code)
      : _isAndroid && code == 'photo_prepare_failed';
}

class _PhotoFailureCounts {
  const _PhotoFailureCounts(this.tracked, this.omitted);

  final int tracked;
  final int omitted;

  int get total => tracked + omitted;
}
