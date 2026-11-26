import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int _epochMillisThreshold = 100000000000;
const int _maxAlbumFolderNameLength = 64;
const int _maxSelectedAlbumCount = 200;
const String _defaultAlbumFolderName = '未分类相簿';

final RegExp _controlCharsPattern = RegExp(r'[\x00-\x1f\x7f]');
final RegExp _forbiddenPathCharsPattern = RegExp(r'[/\\:*?"<>|]');
final RegExp _multiUnderscorePattern = RegExp(r'_+');
final RegExp _multiSpacePattern = RegExp(r'\s+');

/// Single source of truth for mobile photo backup SharedPreferences keys,
/// album scope normalization, folder organization rules, and scope isolation.
class PhotoBackupPrefsSchema {
  const PhotoBackupPrefsSchema({
    required this.origin,
    required this.accountName,
    required this.deviceId,
    required this.rootIdentity,
    required this.baseDirectory,
  });

  static const String installationIdKey = 'lightisle.photoBackup.installationId';

  static const String albumScopeCamera = 'camera';
  static const String albumScopeAll = 'all';
  static const String albumScopeSelected = 'selected';
  static const String albumScopeExcluded = 'excluded';

  static const String organizeFlat = 'flat';
  static const String organizeYearMonth = 'yearMonth';
  static const String organizeByAlbum = 'byAlbum';
  static const String organizeByAlbumYearMonth = 'byAlbumYearMonth';

  static const List<int> autoReleaseMinAgeOptions = [0, 7, 30, 90];
  static const int defaultAutoReleaseMinAgeDays = 30;

  final String origin;
  final String accountName;
  final String deviceId;
  final String rootIdentity;
  final String baseDirectory;

  static String normalizeAlbumScope(String? raw) => switch (raw) {
    albumScopeCamera => albumScopeCamera,
    albumScopeAll => albumScopeAll,
    albumScopeSelected => albumScopeSelected,
    albumScopeExcluded => albumScopeExcluded,
    _ => albumScopeCamera,
  };

  static String normalizeOrganizeMode(
    String? raw, {
    bool legacyByYearMonth = false,
  }) => switch (raw) {
    organizeFlat => organizeFlat,
    organizeYearMonth => organizeYearMonth,
    organizeByAlbum => organizeByAlbum,
    organizeByAlbumYearMonth => organizeByAlbumYearMonth,
    _ => legacyByYearMonth ? organizeYearMonth : organizeFlat,
  };

  static List<String> normalizeSelectedAlbumIds(Iterable<String> raw) {
    final cleaned = raw
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && id.length <= 200)
        .toSet()
        .toList();
    cleaned.sort();
    if (cleaned.length > _maxSelectedAlbumCount) {
      return cleaned.sublist(0, _maxSelectedAlbumCount);
    }
    return cleaned;
  }

  static String albumSelectionSignature(List<String> selectedAlbumIds) {
    final normalized = normalizeSelectedAlbumIds(selectedAlbumIds);
    if (normalized.isEmpty) return 'none';
    return sha256
        .convert(utf8.encode(normalized.join('\n')))
        .toString()
        .substring(0, 12);
  }

  static String sanitizeAlbumFolderName(String? raw) {
    final cleaned = (raw ?? '')
        .replaceAll(_controlCharsPattern, ' ')
        .replaceAll(_forbiddenPathCharsPattern, '_')
        .replaceAll('..', '_')
        .replaceAll(_multiUnderscorePattern, '_')
        .replaceAll(_multiSpacePattern, ' ')
        .trim()
        .replaceAll(RegExp(r'^\.+|\.+$'), '')
        .trim();
    if (cleaned.isEmpty || RegExp(r'^[_.]+$').hasMatch(cleaned)) {
      return _defaultAlbumFolderName;
    }
    return cleaned.length > _maxAlbumFolderNameLength
        ? cleaned.substring(0, _maxAlbumFolderNameLength)
        : cleaned;
  }

  static String resolveTargetDirectory(
    String destinationDir, {
    required String organizeMode,
    required int modified,
    required String albumName,
  }) {
    final mode = normalizeOrganizeMode(organizeMode);
    final albumSegment = sanitizeAlbumFolderName(albumName);
    final yearMonth = _formatYearMonth(modified);
    return switch (mode) {
      organizeFlat => destinationDir,
      organizeYearMonth =>
        yearMonth != null ? '$destinationDir/$yearMonth' : destinationDir,
      organizeByAlbum => '$destinationDir/$albumSegment',
      organizeByAlbumYearMonth =>
        yearMonth != null
            ? '$destinationDir/$albumSegment/$yearMonth'
            : '$destinationDir/$albumSegment',
      _ => destinationDir,
    };
  }

  static String? _formatYearMonth(int modified) {
    if (modified <= 0) return null;
    final ms = modified > _epochMillisThreshold ? modified : modified * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    return '$year/$month';
  }

  String get scope =>
      'lightisle.photoBackup.$origin.$accountName.$deviceId.$rootIdentity.$baseDirectory';

  String get ledgerScope =>
      'lightisle.photoBackup.ledger.$origin.$accountName.$deviceId.$rootIdentity';

  String scopedStatePrefix(
    String albumScope, {
    List<String> selectedAlbumIds = const <String>[],
  }) {
    if (albumScope == albumScopeCamera) return '$scope.camera';
    if (albumScope == albumScopeSelected || albumScope == albumScopeExcluded) {
      return '$scope.$albumScope.${albumSelectionSignature(selectedAlbumIds)}';
    }
    return scope;
  }

  String get albumScopeKey => '$scope.albumScope';
  String get selectedAlbumIdsKey => '$scope.selectedAlbumIds';
  String get onForegroundKey => '$scope.onForeground';
  String get wifiOnlyKey => '$scope.wifiOnly';
  String get batchPagesKey => '$scope.batchPages';
  String get includeVideosKey => '$scope.includeVideos';
  String get organizeByYearMonthKey => '$scope.organizeByYearMonth';
  String get organizeModeKey => '$scope.organizeMode';
  String get allowICloudDownloadKey => '$scope.allowICloudDownload';
  String get autoPromptSpaceReleaseKey => '$scope.autoPromptSpaceRelease';
  String get autoReleaseMinAgeDaysKey => '$scope.autoReleaseMinAgeDays';
  String get verifiedLedgerKey => '$ledgerScope.$baseDirectory.v1';

  String get legacyCursorKey => '$scope.cursor';
  String get legacyLastVerifiedAtKey => '$scope.lastVerifiedAt';
  String get legacyLastCompleteAtKey => '$scope.lastCompleteAt';

  String legacyFailureStorageKey({required bool includeVideos}) =>
      '$scope.failures.${includeVideos ? "videos" : "photos"}';

  String cursorKey(
    String albumScope, {
    List<String> selectedAlbumIds = const <String>[],
  }) =>
      '${scopedStatePrefix(albumScope, selectedAlbumIds: selectedAlbumIds)}.cursor';

  String storeVersionKey(
    String albumScope, {
    List<String> selectedAlbumIds = const <String>[],
  }) =>
      '${scopedStatePrefix(albumScope, selectedAlbumIds: selectedAlbumIds)}.storeVersion';

  String lastVerifiedAtKey(
    String albumScope, {
    List<String> selectedAlbumIds = const <String>[],
  }) =>
      '${scopedStatePrefix(albumScope, selectedAlbumIds: selectedAlbumIds)}.lastVerifiedAt';

  String lastCompleteAtKey(
    String albumScope, {
    List<String> selectedAlbumIds = const <String>[],
  }) =>
      '${scopedStatePrefix(albumScope, selectedAlbumIds: selectedAlbumIds)}.lastCompleteAt';

  String failureStorageKey(
    String albumScope, {
    required bool includeVideos,
    List<String> selectedAlbumIds = const <String>[],
  }) =>
      '${scopedStatePrefix(albumScope, selectedAlbumIds: selectedAlbumIds)}.failures.${includeVideos ? "videos" : "photos"}';

  static String failureOmittedKey(String failureStorageKey) =>
      '$failureStorageKey.omitted';

  static String failureVersionKey(String failureStorageKey) =>
      '$failureStorageKey.version';

  static String scanIncompleteKey(String failureStorageKey) =>
      '$failureStorageKey.scanIncomplete';

  String uploadKey({
    required String rawId,
    required int modified,
    required String digest,
  }) => '$scope.upload.$rawId.$modified.$digest';

  String sentKey({
    required String id,
    required int modified,
    required int listedSize,
    required int generation,
    required String storeVersionId,
  }) => '$scope.sent.$id.$modified.$listedSize.$generation.$storeVersionId';

  String resolveAlbumScope(SharedPreferences prefs) {
    final saved = prefs.getString(albumScopeKey);
    if (saved == albumScopeCamera ||
        saved == albumScopeAll ||
        saved == albumScopeSelected ||
        saved == albumScopeExcluded) {
      return saved!;
    }
    final hasLegacyProgress =
        prefs.containsKey(legacyCursorKey) ||
        prefs.containsKey(legacyLastCompleteAtKey) ||
        prefs.containsKey(legacyFailureStorageKey(includeVideos: false)) ||
        prefs.containsKey(legacyFailureStorageKey(includeVideos: true));
    return hasLegacyProgress ? albumScopeAll : albumScopeCamera;
  }

  List<String> readSelectedAlbumIds(SharedPreferences prefs) {
    final raw = prefs.getStringList(selectedAlbumIdsKey);
    if (raw != null) return normalizeSelectedAlbumIds(raw);
    final encoded = prefs.getString(selectedAlbumIdsKey);
    if (encoded == null || encoded.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is List) {
        return normalizeSelectedAlbumIds(decoded.map((e) => e.toString()));
      }
    } catch (_) {}
    return <String>[];
  }

  String resolveOrganizeMode(SharedPreferences prefs) {
    final saved = prefs.getString(organizeModeKey);
    final legacy = prefs.getBool(organizeByYearMonthKey) ?? false;
    return normalizeOrganizeMode(saved, legacyByYearMonth: legacy);
  }

  bool readAutoPromptSpaceRelease(SharedPreferences prefs) =>
      prefs.getBool(autoPromptSpaceReleaseKey) ?? false;

  int readAutoReleaseMinAgeDays(SharedPreferences prefs) {
    final saved = prefs.getInt(autoReleaseMinAgeDaysKey);
    if (saved != null && autoReleaseMinAgeOptions.contains(saved)) {
      return saved;
    }
    return defaultAutoReleaseMinAgeDays;
  }

  int readLastVerifiedAt(
    SharedPreferences prefs,
    String albumScope, {
    List<String> selectedAlbumIds = const <String>[],
  }) =>
      prefs.getInt(
        lastVerifiedAtKey(albumScope, selectedAlbumIds: selectedAlbumIds),
      ) ??
      prefs.getInt(legacyLastVerifiedAtKey) ??
      0;

  int readLastCompleteAt(
    SharedPreferences prefs,
    String albumScope, {
    List<String> selectedAlbumIds = const <String>[],
  }) =>
      prefs.getInt(
        lastCompleteAtKey(albumScope, selectedAlbumIds: selectedAlbumIds),
      ) ??
      prefs.getInt(legacyLastCompleteAtKey) ??
      0;
}
