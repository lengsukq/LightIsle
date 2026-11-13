part of 'mobile_photo_backup_page.dart';

const int _photoPageFetchLimit = 40;
const int _maxCachedRemoteVerifyBytes = 2 << 30;
const int _maxOversizedClampPerPage = 10000;

class _PhotoPageResponse {
  const _PhotoPageResponse({
    required this.supportsStream,
    required this.rows,
    required this.omittedItems,
    required this.storeVersionID,
    required this.oversizedCount,
    required this.invalidCount,
    required this.nextCursor,
  });

  final bool supportsStream;
  final List<Map<String, dynamic>> rows;
  final Iterable<Map<String, dynamic>> omittedItems;
  final String storeVersionID;
  final int oversizedCount;
  final int invalidCount;
  final String nextCursor;
}

class _BackupSessionKeys {
  _BackupSessionKeys(String statePrefix, this.failureStorageKey)
    : cursorKey = '$statePrefix.cursor',
      storeVersionKey = '$statePrefix.storeVersion',
      lastVerifiedKey = '$statePrefix.lastVerifiedAt',
      lastCompleteKey = '$statePrefix.lastCompleteAt',
      scanIncompleteKey = '$failureStorageKey.scanIncomplete';

  final String cursorKey;
  final String storeVersionKey;
  final String lastVerifiedKey;
  final String lastCompleteKey;
  final String failureStorageKey;
  final String scanIncompleteKey;
}

enum _EntryBackupOutcome { uploaded, skipped, failed, omitted }

extension _MobilePhotoBackupPagination on _MobilePhotoBackupState {
  ({String digest, int size})? _parseVerifiedSentRecord(
    String? raw,
    int listedSize,
  ) {
    if (raw == null || raw.isEmpty) return null;
    final withSize = RegExp(r'^([a-f0-9]{64}):([1-9][0-9]{0,14})$')
        .firstMatch(raw);
    if (withSize != null) {
      final digest = withSize.group(1)!;
      final savedSize = int.tryParse(withSize.group(2)!);
      if (savedSize == null || savedSize <= 0) return null;
      if (!_isIOS && listedSize > 0 && savedSize != listedSize) return null;
      return (digest: digest, size: savedSize);
    }
    if (RegExp(r'^[a-f0-9]{64}$').hasMatch(raw) && listedSize > 0) {
      return (digest: raw, size: listedSize);
    }
    return null;
  }

  String _formatVerifiedSentRecord(String digest, int exactSize) =>
      _isIOS ? '$digest:$exactSize' : digest;

  Future<void> _ensureTargetSubdirectory(
    String destinationDir,
    String entryDir,
    Set<String> ensuredSubdirs,
  ) async {
    if (entryDir == destinationDir || ensuredSubdirs.contains(entryDir)) return;
    final yearSlash = entryDir.lastIndexOf('/');
    if (yearSlash > destinationDir.length) {
      await _ensureFolder(entryDir.substring(0, yearSlash));
      _ensureActive();
    }
    await _ensureFolder(entryDir);
    _ensureActive();
    ensuredSubdirs.add(entryDir);
  }

  Future<void> _validateBackupPreconditions() async {
    _ensureActive();
    if (!_isAndroid && !_isIOS) {
      throw StateError('照片备份只支持 Android 或 iOS 手机。');
    }
    if (!await _permission(checkForegroundRun: true)) {
      throw StateError(
        _isAndroid
            ? '需要在 Android 系统设置中授权访问所有照片；仅选定照片的权限不足以进行完整备份。'
            : '需要在 iOS 系统设置中授权访问所有照片；有限照片访问不足以进行完整备份。',
      );
    }
    _ensureActive();
  }

  Future<void> _initializePaginationState(
    SharedPreferences preferences,
    _BackupSessionKeys keys, {
    required bool older,
  }) async {
    if (!older) {
      _progress.pageCursor = '';
      if (!await preferences.remove(keys.cursorKey)) {
        throw StateError('无法重置照片分页进度，请重试。');
      }
      if (!await preferences.setBool(keys.scanIncompleteKey, false)) {
        throw StateError('无法保存照片检查状态，请重试。');
      }
      _ensureActive();
    }
    _progress.scanHasOmissions =
        older &&
        _progress.pageCursor.isNotEmpty &&
        (preferences.getBool(keys.scanIncompleteKey) ?? true);
  }

  Future<void> _verifyWifiIfRequired() async {
    if (!_options.wifiOnly) return;
    final isWifi = await _photosChannel.invokeMethod<bool>('isWifi');
    _ensureActive();
    if (isWifi != true) {
      throw StateError('当前不在 Wi-Fi 网络下，按你的设置已暂停备份。');
    }
  }

  Future<_PhotoPageResponse> _fetchPhotoPage(String beforeCursor) async {
    final response = await _photosChannel.invokeMapMethod<String, dynamic>(
      'list',
      {
        'beforeId': beforeCursor.isEmpty ? null : beforeCursor,
        'limit': _photoPageFetchLimit,
        'includeVideos': _options.includeVideos,
        'albumScope': _options.albumScope,
        if (_isAndroid) 'allowLargeOriginals': true,
      },
    );
    _ensureActive();
    final oversizedCount = (response?['oversizedCount'] as num?)?.toInt() ?? 0;
    final invalidCount = (response?['invalidCount'] as num?)?.toInt() ?? 0;
    if (oversizedCount < 0 || invalidCount < 0) {
      throw StateError('手机照片检查结果无效，未保存本页进度。');
    }
    final following = response?['nextCursor']?.toString() ?? '';
    if (following.isNotEmpty &&
        (!RegExp(r'^[0-9]{1,20}$').hasMatch(following) ||
            following == beforeCursor)) {
      throw StateError('手机照片分页结果异常，未保存本页进度。');
    }
    final storeVersion = response?['version']?.toString() ?? '';
    final storeVersionID = storeVersion.isNotEmpty
        ? sha256.convert(utf8.encode(storeVersion)).toString().substring(0, 16)
        : '';
    final rows = (response?['items'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((row) => row.cast<String, dynamic>())
        .toList();
    final omittedItems = (response?['omittedItems'] as List<dynamic>? ?? [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>());
    return _PhotoPageResponse(
      supportsStream: _isAndroid && response?['supportsStream'] == true,
      rows: rows,
      omittedItems: omittedItems,
      storeVersionID: storeVersionID,
      oversizedCount: oversizedCount,
      invalidCount: invalidCount,
      nextCursor: following,
    );
  }

  Future<void> _ensureRemoteDestinationReady(
    String base,
    String destinationDir,
  ) async {
    try {
      await widget.api.get(
        _photoApi('files'),
        query: _photoQuery({'path': destinationDir}),
      );
      _ensureActive();
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 403) rethrow;
      _ensureActive();
      await _ensureFolder(base);
      _ensureActive();
      await _ensureFolder(destinationDir);
      _ensureActive();
    }
  }

  Future<bool> _recordOmittedPageItems(
    SharedPreferences preferences,
    String failureStorageKey,
    String storeVersionID,
    Iterable<Map<String, dynamic>> omittedItems,
  ) async {
    var hasOmissions = false;
    for (final item in omittedItems) {
      _ensureActive();
      final id = item['id']?.toString() ?? '';
      if (!RegExp(r'^[0-9]{1,20}$').hasMatch(id)) {
        hasOmissions = true;
        continue;
      }
      final modified = (item['modified'] as num?)?.toInt() ?? 0;
      final size = (item['size'] as num?)?.toInt() ?? 0;
      final generation = (item['generation'] as num?)?.toInt() ?? 0;
      final failureCounts = await _recordPhotoFailure(
        preferences,
        failureStorageKey,
        _photoFailureAssetKey(id, modified, size, generation, storeVersionID),
        item['reason'] == 'oversized' ? 'oversized' : 'source_unavailable',
        name: item['name']?.toString() ?? '',
        assetId: id,
      );
      _progress.failed = failureCounts.total;
      _progress.omittedFailures = failureCounts.omitted;
      hasOmissions = true;
      _ensureActive();
    }
    return hasOmissions;
  }

  Future<void> _recordEntryFailure(
    SharedPreferences preferences,
    String failureStorageKey,
    String failureAssetKey,
    String reason, {
    required String name,
    required String assetId,
  }) async {
    final failureCounts = await _recordPhotoFailure(
      preferences,
      failureStorageKey,
      failureAssetKey,
      reason,
      name: name,
      assetId: assetId,
    );
    _progress.failed = failureCounts.total;
    _progress.omittedFailures = failureCounts.omitted;
  }

  Future<void> _clearEntryFailure(
    SharedPreferences preferences,
    String failureStorageKey,
    String failureAssetKey,
  ) async {
    final failureCounts = await _clearPhotoFailure(
      preferences,
      failureStorageKey,
      failureAssetKey,
    );
    _progress.failed = failureCounts.total;
    _progress.omittedFailures = failureCounts.omitted;
  }
}
