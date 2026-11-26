import 'photo_backup_prefs_schema.dart';
import 'photo_backup_verified_ledger.dart';

/// Represents a device photo album/folder discovered via Android MediaStore
/// buckets or iOS PHAssetCollection.
class DevicePhotoAlbum {
  const DevicePhotoAlbum({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.count,
    required this.totalBytes,
    required this.coverAssetId,
    required this.isCamera,
    required this.kind,
  });

  final String id;
  final String name;
  final String relativePath;
  final int count;
  final int totalBytes;
  final String coverAssetId;
  final bool isCamera;
  final String kind;

  factory DevicePhotoAlbum.fromMap(Map<String, dynamic> map) => DevicePhotoAlbum(
    id: map['id']?.toString() ?? '',
    name: map['name']?.toString().trim().isNotEmpty == true
        ? map['name'].toString().trim()
        : '未命名相簿',
    relativePath: map['relativePath']?.toString() ?? '',
    count: (map['count'] as num?)?.toInt() ?? 0,
    totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
    coverAssetId: map['coverAssetId']?.toString() ?? '',
    isCamera: map['isCamera'] == true,
    kind: map['kind']?.toString() ?? 'bucket',
  );
}

/// Encapsulates foreground backup run counters, pagination cursors, failure
/// diagnostics, and status messages for [MobilePhotoBackupPage].
class PhotoBackupRunProgressState {
  bool busy = false;
  bool cancel = false;
  bool isForeground = true;
  bool resumeAfterCurrentRun = false;

  int checked = 0;
  int uploaded = 0;
  int skipped = 0;
  int failed = 0;
  int omittedFailures = 0;
  int oversizedSkipped = 0;
  bool scanHasOmissions = false;

  List<Map<String, dynamic>> failureDetails = <Map<String, dynamic>>[];
  int visibleFailureCount = 50;
  String message = '授权读取手机照片后，可把照片与原画视频安全备份到你的 Mac。';
  String pageCursor = '';
  String nextCursor = '';
  int lastVerifiedAt = 0;
  int lastCompleteAt = 0;

  void beginRun() {
    busy = true;
    cancel = false;
    checked = 0;
    uploaded = 0;
    skipped = 0;
    failed = 0;
    omittedFailures = 0;
    oversizedSkipped = 0;
    nextCursor = '';
    message = '正在核对权限与连接…';
  }
}

/// Encapsulates persisted user backup preferences and installation identity
/// for [MobilePhotoBackupPage].
class PhotoBackupOptionsState {
  String deviceId = '';
  bool onForeground = false;
  bool wifiOnly = true;
  int batchPages = 10;
  String albumScope = PhotoBackupPrefsSchema.albumScopeCamera;
  List<String> selectedAlbumIds = <String>[];
  bool includeVideos = false;
  String organizeMode = PhotoBackupPrefsSchema.organizeFlat;
  bool allowICloudDownload = false;
  bool autoPromptSpaceRelease = false;
  int autoReleaseMinAgeDays =
      PhotoBackupPrefsSchema.defaultAutoReleaseMinAgeDays;

  bool get organizeByYearMonth =>
      organizeMode == PhotoBackupPrefsSchema.organizeYearMonth ||
      organizeMode == PhotoBackupPrefsSchema.organizeByAlbumYearMonth;

  set organizeByYearMonth(bool value) {
    organizeMode = value
        ? PhotoBackupPrefsSchema.organizeYearMonth
        : PhotoBackupPrefsSchema.organizeFlat;
  }
}

/// Encapsulates local space-release ledger cache and auto-prompt coordination.
class PhotoBackupSpaceReleaseState {
  List<VerifiedPhotoBackupRecord> verifiedRecords =
      <VerifiedPhotoBackupRecord>[];
  bool pendingAutoReleasePrompt = false;
  String? lastReleaseSummary;

  int get releasableCount => verifiedRecords.length;

  int get releasableBytes =>
      PhotoBackupVerifiedLedger.totalBytes(verifiedRecords);
}

/// Encapsulates Android WorkManager background photo backup authorization and
/// status telemetry for [MobilePhotoBackupPage].
class PhotoBackupBackgroundState {
  bool enabled = false;
  bool busy = false;
  bool sessionMatches = false;
  DateTime? expiresAt;
  DateTime? lastCompletedAt;
  String result = '后台备份未开启';
  String workState = 'none';
  String? actionMessage;
  int statusGeneration = 0;
}

/// Encapsulates active native asset preparation/stream request IDs and
/// cancellation tracking for [MobilePhotoBackupPage].
class PhotoBackupPrepareSessionState {
  String? activeRequestId;
  String? cancelledRequestId;
  int sequence = 0;

  String nextRequestId(String deviceId) =>
      '$deviceId-${DateTime.now().microsecondsSinceEpoch}-${sequence++}';
}
