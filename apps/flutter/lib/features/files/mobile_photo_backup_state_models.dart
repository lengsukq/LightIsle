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
  String albumScope = 'camera';
  bool includeVideos = false;
  bool organizeByYearMonth = false;
  bool allowICloudDownload = false;
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
