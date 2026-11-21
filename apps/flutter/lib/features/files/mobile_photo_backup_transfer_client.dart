import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import 'mobile_photo_backup_state_models.dart';
import 'photo_backup_hash.dart';

const MethodChannel mobilePhotosMethodChannel = MethodChannel(
  'lightisle/photos',
);
const int photoPageFetchLimit = 40;

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

class PausePhotoBackupException implements Exception {
  const PausePhotoBackupException();
}

class NativeStreamInspection {
  const NativeStreamInspection({
    required this.size,
    required this.modified,
    required this.generation,
    required this.digest,
    required this.chunkDigests,
  });

  final int size;
  final int modified;
  final int generation;
  final String digest;
  final List<String> chunkDigests;
}

class PhotoPageResponse {
  const PhotoPageResponse({
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

  Future<PhotoPageResponse> fetchPhotoPage({
    required String beforeCursor,
    required bool includeVideos,
    required String albumScope,
    required void Function() checkActive,
  }) async {
    final response = await channel.invokeMapMethod<String, dynamic>('list', {
      'beforeId': beforeCursor.isEmpty ? null : beforeCursor,
      'limit': photoPageFetchLimit,
      'includeVideos': includeVideos,
      'albumScope': albumScope,
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
    final yearSlash = entryDir.lastIndexOf('/');
    if (yearSlash > destinationDir.length) {
      await ensureFolder(
        entryDir.substring(0, yearSlash),
        checkActive: checkActive,
      );
      checkActive();
    }
    await ensureFolder(entryDir, checkActive: checkActive);
    checkActive();
    ensuredSubdirs.add(entryDir);
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
