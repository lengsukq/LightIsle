import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'mobile_photo_backup_native_models.dart';
import 'mobile_photo_backup_state_models.dart';
import 'photo_backup_hash.dart';
import 'photo_backup_prefs_schema.dart';
import 'photo_backup_verified_ledger.dart';

export 'mobile_photo_backup_native_models.dart';

const MethodChannel mobilePhotosMethodChannel = MethodChannel(
  'lightisle/photos',
);
const int photoPageFetchLimit = 40;
const int _maxDirectRemoteSha256Bytes = 2 << 30;

const Set<String> _supportedPhotoExtensions = {
  'jpg',
  'jpeg',
  'png',
  'heic',
  'heif',
  'webp',
  'avif',
  'gif',
  'tiff',
  'bmp',
  'mp4',
  'mov',
  'm4v',
  '3gp',
  'webm',
  'mkv',
  'avi',
  'dng',
  'cr2',
  'cr3',
  'nef',
  'arw',
  'raf',
  'rw2',
  'orf',
  'pef',
};

final RegExp _photoApiPathPattern = RegExp(
  r'^(files(?:/.*)?|uploads(?:/.*)?)$',
);
final RegExp _pageCursorPattern = RegExp(r'^[0-9]{1,20}$');
final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

String normalizePhotoExtension(String name) {
  final lower = name.toLowerCase();
  final index = lower.lastIndexOf('.');
  final ext = index >= 0 ? lower.substring(index + 1) : '';
  return _supportedPhotoExtensions.contains(ext) ? ext : 'jpg';
}

/// Coordinates native `lightisle/photos` channel calls, prepare cancellation,
/// remote NAS folder checks, and resumable chunked uploads.
class MobilePhotoBackupTransferClient {
  MobilePhotoBackupTransferClient({
    required this.api,
    required this.boundRoot,
    required this.isAndroid,
    required this.isPersonalDestination,
    required this.prepareSession,
    this.channel = mobilePhotosMethodChannel,
  });

  final LightIsleApi api;
  final LightIsleRoot? boundRoot;
  final bool isAndroid;
  final bool isPersonalDestination;
  final PhotoBackupPrepareSessionState prepareSession;
  final MethodChannel channel;

  String photoApi(String suffix) {
    final root = boundRoot;
    if (root == null || !root.online || !isPersonalDestination) {
      throw StateError('请先为照片配置在线个人硬盘，再从图库开启照片备份。');
    }
    if (!_photoApiPathPattern.hasMatch(suffix)) {
      throw ArgumentError('照片备份接口不支持此操作。');
    }
    return '/api/v2/roots/${Uri.encodeComponent(root.id)}/$suffix';
  }

  Map<String, String> photoQuery([Map<String, String>? extra]) => {
    ...?extra,
    'rootGeneration': '${boundRoot?.generation ?? 0}',
  };

  Future<void> cancelPrepare(String requestId) async {
    try {
      await channel.invokeMethod<bool>('cancelPrepare', {
        'requestId': requestId,
      });
    } catch (_) {
      // Native prepare/stream cleanup owns cancellation races.
    }
  }

  void cancelActivePrepare() {
    final requestId = prepareSession.activeRequestId;
    if (requestId == null || prepareSession.cancelledRequestId == requestId) {
      return;
    }
    prepareSession.cancelledRequestId = requestId;
    unawaited(cancelPrepare(requestId));
  }

  Future<T> _runTrackedRequest<T>(
    String deviceId,
    Future<T> Function(String requestId) invoke,
  ) async {
    final requestId = prepareSession.nextRequestId(deviceId);
    prepareSession.activeRequestId = requestId;
    prepareSession.cancelledRequestId = null;
    try {
      return await invoke(requestId);
    } finally {
      if (prepareSession.activeRequestId == requestId) {
        prepareSession.activeRequestId = null;
      }
      if (prepareSession.cancelledRequestId == requestId) {
        prepareSession.cancelledRequestId = null;
      }
    }
  }

  Future<bool> ensurePermission({
    required bool includeVideos,
    void Function()? checkActive,
  }) async {
    final granted = await channel.invokeMethod<bool>('permission', {
      'includeVideos': includeVideos,
    });
    checkActive?.call();
    if (granted == true) return true;
    final requested = await channel.invokeMethod<bool>('requestPermission', {
      'includeVideos': includeVideos,
    });
    checkActive?.call();
    return requested == true;
  }

  Future<bool> isWifi() async =>
      await channel.invokeMethod<bool>('isWifi') == true;

  Future<List<DevicePhotoAlbum>> listAlbums({
    required bool includeVideos,
  }) async {
    final response = await channel.invokeMapMethod<String, dynamic>(
      'listAlbums',
      {'includeVideos': includeVideos},
    );
    final raw = response?['albums'];
    if (raw is! List) return const <DevicePhotoAlbum>[];
    return raw
        .whereType<Map>()
        .map((item) => DevicePhotoAlbum.fromMap(item.cast<String, dynamic>()))
        .where((album) => album.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, NativeIosAssetInspection>> inspectIosAssets(
    List<String> assetIds,
  ) async {
    final uniqueIds = assetIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueIds.isEmpty) return const <String, NativeIosAssetInspection>{};
    final out = <String, NativeIosAssetInspection>{};
    const chunkSize = 500;
    for (var offset = 0; offset < uniqueIds.length; offset += chunkSize) {
      final batch = uniqueIds.sublist(
        offset,
        min(offset + chunkSize, uniqueIds.length),
      );
      final response = await channel.invokeMapMethod<String, dynamic>(
        'inspectAssets',
        {'assetIds': batch},
      );
      final rawAssets = response?['assets'];
      if (rawAssets is! Map) {
        throw StateError('iOS 相册未返回有效的资产状态核验结果。');
      }
      rawAssets.forEach((key, value) {
        final id = key?.toString().trim() ?? '';
        if (id.isNotEmpty && value is Map) {
          out[id] = NativeIosAssetInspection.fromMap(
            value.cast<String, dynamic>(),
          );
        }
      });
    }
    return out;
  }

  Future<NativePhotoDeleteResult> requestDeleteAssets(
    List<String> assetIds,
  ) async {
    if (assetIds.isEmpty) {
      return const NativePhotoDeleteResult(
        deleted: true,
        cancelled: false,
        deletedCount: 0,
        alreadyMissingCount: 0,
      );
    }
    final response = await channel.invokeMapMethod<String, dynamic>(
      'requestDeleteAssets',
      {'assetIds': assetIds},
    );
    final rawDeletedIds = response?['deletedAssetIds'];
    final deletedAssetIds = rawDeletedIds is List
        ? rawDeletedIds
              .map((e) => e?.toString().trim() ?? '')
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return NativePhotoDeleteResult(
      deleted: response?['deleted'] == true,
      cancelled: response?['cancelled'] == true,
      deletedCount: (response?['deletedCount'] as num?)?.toInt() ?? 0,
      alreadyMissingCount:
          (response?['alreadyMissingCount'] as num?)?.toInt() ?? 0,
      deletedAssetIds: deletedAssetIds,
    );
  }

  Future<bool> verifyBoundRootOnline() async {
    final root = boundRoot;
    if (root == null || !root.online || !isPersonalDestination) return false;
    if (api.selectedRoot?.identity != root.identity) return false;
    final discovery = await api.get('/api/v2/roots');
    final roots = discovery['roots'];
    if (roots is! List) return false;
    return roots.any(
      (value) =>
          value is Map &&
          value['rootID'] == root.id &&
          value['generation'] == root.generation &&
          value['online'] == true,
    );
  }

  /// Online check for space release: calls GET /api/v2/roots/{rootID}/files/sha256
  /// with rootGeneration validation and fails closed on any mismatch or root issue.
  Future<RemoteReleaseVerifyOutcome> verifyRemoteAssetForRelease(
    VerifiedPhotoBackupRecord record, {
    void Function()? checkActive,
  }) async {
    final root = boundRoot;
    if (root == null ||
        !root.online ||
        !isPersonalDestination ||
        api.selectedRoot?.identity != root.identity) {
      return const RemoteReleaseVerifyOutcome(
        status: RemoteReleaseVerifyStatus.rootChangedOrOffline,
        reason: '照片存储硬盘已离线或已更换，已停止释放并保留全部手机原片。',
      );
    }
    try {
      checkActive?.call();
      if (record.sizeBytes > _maxDirectRemoteSha256Bytes) {
        if (record.chunkDigests.isEmpty) {
          return const RemoteReleaseVerifyOutcome(
            status: RemoteReleaseVerifyStatus.unverifiableLargeFile,
            reason: '超大原片缺少分块摘要记录，为保障安全已保留手机原片。',
          );
        }
        final matched = await api.remoteFileMatchesSHA256(
          record.remotePath,
          record.sizeBytes,
          record.sha256,
          chunkSHA256s: record.chunkDigests,
          checkActive: checkActive,
        );
        return matched
            ? const RemoteReleaseVerifyOutcome(
                status: RemoteReleaseVerifyStatus.verified,
                reason: 'SHA-256 核验通过',
              )
            : const RemoteReleaseVerifyOutcome(
                status: RemoteReleaseVerifyStatus.mismatch,
                reason: 'NAS 远端文件缺失或分块 SHA-256 不一致，已保留手机原片。',
              );
      }

      final result = await api.get(
        photoApi('files/sha256'),
        query: photoQuery({'path': record.remotePath}),
      );
      checkActive?.call();
      final actualDigest = result['sha256'];
      final actualSize = result['size'];
      if (result['algorithm'] != 'sha256' ||
          actualDigest is! String ||
          !_sha256Pattern.hasMatch(actualDigest) ||
          actualSize is! num) {
        return const RemoteReleaseVerifyOutcome(
          status: RemoteReleaseVerifyStatus.mismatch,
          reason: '服务端未返回有效的 SHA-256 校验结果，已保留手机原片。',
        );
      }
      if (actualDigest != record.sha256 ||
          actualSize.toInt() != record.sizeBytes) {
        return const RemoteReleaseVerifyOutcome(
          status: RemoteReleaseVerifyStatus.mismatch,
          reason: '远端原片 SHA-256 或文件大小与备份记录不一致，已保留手机原片。',
        );
      }
      return const RemoteReleaseVerifyOutcome(
        status: RemoteReleaseVerifyStatus.verified,
        reason: 'SHA-256 核验通过',
      );
    } on LightIsleApiException catch (error) {
      if (error.statusCode == HttpStatus.notFound) {
        return const RemoteReleaseVerifyOutcome(
          status: RemoteReleaseVerifyStatus.missing,
          reason: 'NAS 上未找到该备份文件（可能已被移动或删除），已保留手机原片。',
        );
      }
      if (_isRootOfflineOrReplacedError(error)) {
        return const RemoteReleaseVerifyOutcome(
          status: RemoteReleaseVerifyStatus.rootChangedOrOffline,
          reason: '照片硬盘离线或已更换，已中止释放并保留全部手机原片。',
        );
      }
      return RemoteReleaseVerifyOutcome(
        status: RemoteReleaseVerifyStatus.error,
        reason: '在线核验失败（${userFacingError(error)}），已保留手机原片。',
      );
    } catch (error) {
      return RemoteReleaseVerifyOutcome(
        status: RemoteReleaseVerifyStatus.error,
        reason: '在线核验失败（${userFacingError(error)}），已保留手机原片。',
      );
    }
  }

  bool _isRootOfflineOrReplacedError(LightIsleApiException error) =>
      error.statusCode == HttpStatus.serviceUnavailable ||
      error.code == 'root_generation_changed' ||
      error.code == 'root_not_found' ||
      error.code == 'root_unavailable' ||
      error.code == 'storage_destination_not_assigned';

  Future<PhotoPageResponse> fetchPhotoPage({
    required String beforeCursor,
    required bool includeVideos,
    required String albumScope,
    List<String> selectedAlbumIds = const <String>[],
    required void Function() checkActive,
  }) async {
    final includeAlbumFilter =
        albumScope == PhotoBackupPrefsSchema.albumScopeSelected ||
        albumScope == PhotoBackupPrefsSchema.albumScopeExcluded;
    final response = await channel.invokeMapMethod<String, dynamic>('list', {
      'beforeId': beforeCursor.isEmpty ? null : beforeCursor,
      'limit': photoPageFetchLimit,
      'includeVideos': includeVideos,
      'albumScope': albumScope,
      if (includeAlbumFilter) 'selectedAlbumIds': selectedAlbumIds,
      if (isAndroid) 'allowLargeOriginals': true,
    });
    checkActive();
    final oversizedCount = (response?['oversizedCount'] as num?)?.toInt() ?? 0;
    final invalidCount = (response?['invalidCount'] as num?)?.toInt() ?? 0;
    if (oversizedCount < 0 || invalidCount < 0) {
      throw StateError('手机照片检查结果无效，未保存本页进度。');
    }
    final following = response?['nextCursor']?.toString() ?? '';
    if (following.isNotEmpty &&
        (!_pageCursorPattern.hasMatch(following) ||
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
    return PhotoPageResponse(
      supportsStream: isAndroid && response?['supportsStream'] == true,
      rows: rows,
      omittedItems: omittedItems,
      storeVersionID: storeVersionID,
      oversizedCount: oversizedCount,
      invalidCount: invalidCount,
      nextCursor: following,
    );
  }

  /// Calls native `prepare` and returns its raw map without checking active
  /// status afterwards so callers can capture and release late temp files.
  Future<Map<String, dynamic>?> preparePhoto({
    required String deviceId,
    required String id,
    required bool includeVideos,
    required bool isIOS,
    required bool allowICloudDownload,
    required void Function() checkActive,
  }) {
    checkActive();
    return _runTrackedRequest(
      deviceId,
      (requestId) => channel.invokeMapMethod<String, dynamic>('prepare', {
        'id': id,
        'requestId': requestId,
        'includeVideos': includeVideos,
        if (isIOS) 'allowICloudDownload': allowICloudDownload,
      }),
    );
  }

  Future<void> releasePreparedPhoto(String path) async {
    try {
      await channel.invokeMethod<bool>('release', {'path': path});
    } catch (error) {
      debugPrint('LightIsle photo temp release failed: $error');
    }
  }

  Future<NativeStreamInspection> inspectAndroidStreamAsset({
    required String deviceId,
    required String id,
    required bool includeVideos,
    required void Function() checkActive,
  }) async {
    checkActive();
    return _runTrackedRequest(deviceId, (requestId) async {
      final inspected = await channel.invokeMapMethod<String, dynamic>(
        'inspectAndHash',
        {
          'id': id,
          'requestId': requestId,
          'includeVideos': includeVideos,
        },
      );
      checkActive();
      final size = (inspected?['size'] as num?)?.toInt() ?? -1;
      final modified = (inspected?['modified'] as num?)?.toInt() ?? -1;
      final generation = (inspected?['generation'] as num?)?.toInt() ?? 0;
      final digest = inspected?['sha256']?.toString() ?? '';
      final rawChunks = inspected?['chunkDigests'];
      final chunkDigests = rawChunks is List
          ? rawChunks.map((e) => e.toString()).toList(growable: false)
          : const <String>[];
      if (size <= 0 ||
          size > maxPhotoBackupBytes ||
          modified < 0 ||
          !_sha256Pattern.hasMatch(digest)) {
        throw PlatformException(code: 'photo_source_changed');
      }
      return NativeStreamInspection(
        size: size,
        modified: modified,
        generation: generation,
        digest: digest,
        chunkDigests: chunkDigests,
      );
    });
  }

  Future<Uint8List> readAndroidStreamChunk({
    required String deviceId,
    required String id,
    required bool includeVideos,
    required int offset,
    required int length,
    required NativeStreamInspection inspection,
    required void Function() checkActive,
  }) async {
    checkActive();
    return _runTrackedRequest(deviceId, (requestId) async {
      final bytes = await channel.invokeMethod<Uint8List>('readChunk', {
        'id': id,
        'requestId': requestId,
        'includeVideos': includeVideos,
        'offset': offset,
        'length': length,
        'expectedSize': inspection.size,
        'expectedModified': inspection.modified,
        'expectedGeneration': inspection.generation,
      });
      checkActive();
      if (bytes == null || bytes.length != length) {
        throw PlatformException(code: 'photo_source_changed');
      }
      return bytes;
    });
  }

  Future<void> ensureFolder(
    String path, {
    required void Function() checkActive,
  }) async {
    checkActive();
    try {
      await api.get(photoApi('files'), query: photoQuery({'path': path}));
      checkActive();
      return;
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 403) rethrow;
      checkActive();
    }
    checkActive();
    try {
      await api.send(
        'POST',
        photoApi('files/folders'),
        body: {'path': path},
        query: photoQuery(),
      );
      checkActive();
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 409) rethrow;
      checkActive();
    }
  }

  Future<void> ensureRemoteDestinationReady(
    String base,
    String destinationDir, {
    required void Function() checkActive,
  }) async {
    try {
      await api.get(
        photoApi('files'),
        query: photoQuery({'path': destinationDir}),
      );
      checkActive();
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 403) rethrow;
      checkActive();
      await ensureFolder(base, checkActive: checkActive);
      checkActive();
      await ensureFolder(destinationDir, checkActive: checkActive);
      checkActive();
    }
  }

  Future<void> ensureTargetSubdirectory(
    String destinationDir,
    String entryDir,
    Set<String> ensuredSubdirs, {
    required void Function() checkActive,
  }) async {
    if (entryDir == destinationDir || ensuredSubdirs.contains(entryDir)) return;
    final prefix = '$destinationDir/';
    if (!entryDir.startsWith(prefix)) {
      await ensureFolder(entryDir, checkActive: checkActive);
      checkActive();
      ensuredSubdirs.add(entryDir);
      return;
    }
    var current = destinationDir;
    for (final segment
        in entryDir.substring(prefix.length).split('/').where((s) => s.isNotEmpty)) {
      current = '$current/$segment';
      if (ensuredSubdirs.contains(current)) continue;
      await ensureFolder(current, checkActive: checkActive);
      checkActive();
      ensuredSubdirs.add(current);
    }
  }

  Future<Map<String, dynamic>?> _existingUpload({
    required SharedPreferences preferences,
    required String key,
    required int size,
    required String destination,
    required void Function() checkActive,
  }) async {
    checkActive();
    final id = preferences.getString(key);
    if (id == null || id.isEmpty) return null;
    try {
      final state = await api.get(
        photoApi('uploads/${Uri.encodeComponent(id)}'),
        query: photoQuery(),
      );
      checkActive();
      final offset = (state['offset'] as num?)?.toInt() ?? -1;
      if (state['path'] == destination &&
          state['size'] == size &&
          offset >= 0 &&
          offset <= size) {
        return state;
      }
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404) rethrow;
      checkActive();
    }
    checkActive();
    await preferences.remove(key);
    checkActive();
    return null;
  }

  Future<void> uploadFromChunkProvider({
    required SharedPreferences preferences,
    required bool wifiOnly,
    required int size,
    required String destination,
    required String key,
    required String digest,
    required List<String> chunkSHA256s,
    required Future<Stream<List<int>>> Function(int offset, int length) openChunk,
    required void Function() checkActive,
  }) async {
    checkActive();
    var state = await _existingUpload(
      preferences: preferences,
      key: key,
      size: size,
      destination: destination,
      checkActive: checkActive,
    );
    checkActive();
    if (state == null) {
      checkActive();
      state = await api.send(
        'POST',
        photoApi('uploads'),
        body: {'path': destination, 'size': size},
        query: photoQuery(),
      );
    }
    final id = state['id']?.toString() ?? '';
    if (id.isEmpty || state['path'] != destination || state['size'] != size) {
      throw StateError('服务端上传会话与备份照片不一致。');
    }
    await preferences.setString(key, id);
    checkActive();
    var offset = (state['offset'] as num?)?.toInt() ?? -1;
    if (offset < 0 || offset > size) throw StateError('无效的续传偏移量。');
    while (offset < size) {
      checkActive();
      if (wifiOnly) {
        final wifi = await isWifi();
        checkActive();
        if (!wifi) throw StateError('Wi-Fi 已断开，当前上传已暂停。');
      }
      final length = min(photoHashChunkBytes, size - offset);
      final chunkStream = await openChunk(offset, length);
      checkActive();
      try {
        state = await api.uploadChunk(id, chunkStream, length, offset);
        checkActive();
      } catch (_) {
        checkActive();
        final latest = await api.get(
          photoApi('uploads/${Uri.encodeComponent(id)}'),
          query: photoQuery(),
        );
        checkActive();
        final next = (latest['offset'] as num?)?.toInt() ?? -1;
        if (latest['path'] != destination ||
            latest['size'] != size ||
            next <= offset ||
            next > size) {
          rethrow;
        }
        state = latest;
      }
      final next = (state['offset'] as num?)?.toInt() ?? -1;
      if (next <= offset || next > size) throw StateError('上传进度未前进，备份已暂停。');
      offset = next;
    }
    checkActive();
    await api.send(
      'POST',
      photoApi('uploads/${Uri.encodeComponent(id)}/complete'),
      query: photoQuery(),
    );
    checkActive();
    final matches = await api.remoteFileMatchesSHA256(
      destination,
      size,
      digest,
      chunkSHA256s: chunkSHA256s,
      checkActive: checkActive,
    );
    checkActive();
    if (!matches) {
      throw StateError('NAS 原片 SHA-256 与手机不一致，不能标记备份成功。');
    }
    await preferences.remove(key);
    checkActive();
  }

  Future<void> uploadFile({
    required SharedPreferences preferences,
    required bool wifiOnly,
    required File source,
    required int size,
    required String destination,
    required String key,
    required String digest,
    required List<String> chunkDigests,
    required void Function() checkActive,
  }) => uploadFromChunkProvider(
    preferences: preferences,
    wifiOnly: wifiOnly,
    size: size,
    destination: destination,
    key: key,
    digest: digest,
    chunkSHA256s: chunkDigests,
    openChunk: (offset, length) async =>
        source.openRead(offset, offset + length),
    checkActive: checkActive,
  );
}
