import 'package:shared_preferences/shared_preferences.dart';

/// Single source of truth for mobile photo backup SharedPreferences keys and
/// scope resolution shared by `MobilePhotoBackupPage` and `PhotoBackupStatusPill`.
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

  final String origin;
  final String accountName;
  final String deviceId;
  final String rootIdentity;
  final String baseDirectory;

  String get scope =>
      'lightisle.photoBackup.$origin.$accountName.$deviceId.$rootIdentity.$baseDirectory';

  String scopedStatePrefix(String albumScope) =>
      albumScope == albumScopeCamera ? '$scope.camera' : scope;

  String get albumScopeKey => '$scope.albumScope';
  String get onForegroundKey => '$scope.onForeground';
  String get wifiOnlyKey => '$scope.wifiOnly';
  String get batchPagesKey => '$scope.batchPages';
  String get includeVideosKey => '$scope.includeVideos';
  String get organizeByYearMonthKey => '$scope.organizeByYearMonth';
  String get allowICloudDownloadKey => '$scope.allowICloudDownload';

  String get legacyCursorKey => '$scope.cursor';
  String get legacyLastVerifiedAtKey => '$scope.lastVerifiedAt';
  String get legacyLastCompleteAtKey => '$scope.lastCompleteAt';

  String legacyFailureStorageKey({required bool includeVideos}) =>
      '$scope.failures.${includeVideos ? "videos" : "photos"}';

  String cursorKey(String albumScope) =>
      '${scopedStatePrefix(albumScope)}.cursor';

  String storeVersionKey(String albumScope) =>
      '${scopedStatePrefix(albumScope)}.storeVersion';

  String lastVerifiedAtKey(String albumScope) =>
      '${scopedStatePrefix(albumScope)}.lastVerifiedAt';

  String lastCompleteAtKey(String albumScope) =>
      '${scopedStatePrefix(albumScope)}.lastCompleteAt';

  String failureStorageKey(String albumScope, {required bool includeVideos}) =>
      '${scopedStatePrefix(albumScope)}.failures.${includeVideos ? "videos" : "photos"}';

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
    if (saved == albumScopeCamera || saved == albumScopeAll) return saved!;
    final hasLegacyProgress =
        prefs.containsKey(legacyCursorKey) ||
        prefs.containsKey(legacyLastCompleteAtKey) ||
        prefs.containsKey(legacyFailureStorageKey(includeVideos: false)) ||
        prefs.containsKey(legacyFailureStorageKey(includeVideos: true));
    return hasLegacyProgress ? albumScopeAll : albumScopeCamera;
  }

  int readLastVerifiedAt(SharedPreferences prefs, String albumScope) =>
      prefs.getInt(lastVerifiedAtKey(albumScope)) ??
      prefs.getInt(legacyLastVerifiedAtKey) ??
      0;

  int readLastCompleteAt(SharedPreferences prefs, String albumScope) =>
      prefs.getInt(lastCompleteAtKey(albumScope)) ??
      prefs.getInt(legacyLastCompleteAtKey) ??
      0;
}
