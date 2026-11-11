import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DesktopConflictPolicy {
  trashAndReplace,
  keepBoth;

  String get wireValue => switch (this) {
    DesktopConflictPolicy.trashAndReplace => 'trashAndReplace',
    DesktopConflictPolicy.keepBoth => 'keepBoth',
  };

  String get label => switch (this) {
    DesktopConflictPolicy.trashAndReplace => '同名已修改文件：旧版移入 NAS 回收站并替换为新版（推荐）',
    DesktopConflictPolicy.keepBoth => '同名已修改文件：自动改名并保留两份',
  };

  String get shortLabel => switch (this) {
    DesktopConflictPolicy.trashAndReplace => '旧版进回收站并更新',
    DesktopConflictPolicy.keepBoth => '改名保留双份',
  };

  static DesktopConflictPolicy fromWire(String? raw) => switch (raw) {
    'keepBoth' => DesktopConflictPolicy.keepBoth,
    _ => DesktopConflictPolicy.trashAndReplace,
  };
}

enum DesktopBackupSchedule {
  off,
  every1h,
  every6h;

  String get wireValue => switch (this) {
    DesktopBackupSchedule.off => 'off',
    DesktopBackupSchedule.every1h => '1h',
    DesktopBackupSchedule.every6h => '6h',
  };

  Duration? get interval => switch (this) {
    DesktopBackupSchedule.off => null,
    DesktopBackupSchedule.every1h => const Duration(hours: 1),
    DesktopBackupSchedule.every6h => const Duration(hours: 6),
  };

  String get label => switch (this) {
    DesktopBackupSchedule.off => '仅手动运行',
    DesktopBackupSchedule.every1h => '客户端打开期间每 1 小时检查',
    DesktopBackupSchedule.every6h => '客户端打开期间每 6 小时检查',
  };

  static DesktopBackupSchedule fromWire(String? raw) => switch (raw) {
    '1h' => DesktopBackupSchedule.every1h,
    '6h' => DesktopBackupSchedule.every6h,
    _ => DesktopBackupSchedule.off,
  };
}

class DesktopBackupFileRecord {
  const DesktopBackupFileRecord({
    required this.size,
    required this.modifiedMs,
    required this.sha256,
    this.remoteName,
  });

  final int size;
  final int modifiedMs;
  final String sha256;
  final String? remoteName;

  Map<String, Object> toJson() => <String, Object>{
    's': size,
    'm': modifiedMs,
    'h': sha256,
    if (remoteName != null && remoteName!.isNotEmpty) 'r': remoteName!,
  };

  static DesktopBackupFileRecord? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final size = raw['s'];
    final modifiedMs = raw['m'];
    final digest = raw['h'];
    final remoteName = raw['r'];
    if (size is! int ||
        size < 0 ||
        modifiedMs is! int ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      return null;
    }
    return DesktopBackupFileRecord(
      size: size,
      modifiedMs: modifiedMs,
      sha256: digest,
      remoteName: remoteName is String && remoteName.isNotEmpty
          ? remoteName
          : null,
    );
  }
}

class DesktopBackupFailure {
  const DesktopBackupFailure({
    required this.relativePath,
    required this.reason,
    required this.failedAtMs,
  });

  final String relativePath;
  final String reason;
  final int failedAtMs;

  Map<String, Object> toJson() => <String, Object>{
    'path': relativePath,
    'reason': reason,
    'at': failedAtMs,
  };

  static DesktopBackupFailure? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final reason = raw['reason'];
    final at = raw['at'];
    if (path is! String || path.isEmpty || reason is! String) return null;
    return DesktopBackupFailure(
      relativePath: path,
      reason: reason,
      failedAtMs: at is int ? at : 0,
    );
  }
}

class DesktopBackupTask {
  const DesktopBackupTask({
    required this.id,
    required this.label,
    required this.localPath,
    this.bookmarkBase64,
    required this.rootId,
    required this.rootGeneration,
    required this.rootName,
    required this.remoteBasePath,
    this.conflictPolicy = DesktopConflictPolicy.trashAndReplace,
    this.ignoreHidden = true,
    this.enabled = true,
    this.lastRunAtMs = 0,
    this.lastCompleteAtMs = 0,
    this.lastSummary,
    this.lastError,
    this.lastSkippedSymlinks = 0,
  });

  final String id;
  final String label;
  final String localPath;
  final String? bookmarkBase64;
  final String rootId;
  final int rootGeneration;
  final String rootName;
  final String remoteBasePath;
  final DesktopConflictPolicy conflictPolicy;
  final bool ignoreHidden;
  final bool enabled;
  final int lastRunAtMs;
  final int lastCompleteAtMs;
  final String? lastSummary;
  final String? lastError;
  final int lastSkippedSymlinks;

  String get rootIdentity => '$rootId@$rootGeneration';

  DesktopBackupTask copyWith({
    String? label,
    String? localPath,
    String? bookmarkBase64,
    bool clearBookmark = false,
    String? rootId,
    int? rootGeneration,
    String? rootName,
    String? remoteBasePath,
    DesktopConflictPolicy? conflictPolicy,
    bool? ignoreHidden,
    bool? enabled,
    int? lastRunAtMs,
    int? lastCompleteAtMs,
    String? lastSummary,
    bool clearSummary = false,
    String? lastError,
    bool clearError = false,
    int? lastSkippedSymlinks,
  }) => DesktopBackupTask(
    id: id,
    label: label ?? this.label,
    localPath: localPath ?? this.localPath,
    bookmarkBase64: clearBookmark
        ? null
        : (bookmarkBase64 ?? this.bookmarkBase64),
    rootId: rootId ?? this.rootId,
    rootGeneration: rootGeneration ?? this.rootGeneration,
    rootName: rootName ?? this.rootName,
    remoteBasePath: remoteBasePath ?? this.remoteBasePath,
    conflictPolicy: conflictPolicy ?? this.conflictPolicy,
    ignoreHidden: ignoreHidden ?? this.ignoreHidden,
    enabled: enabled ?? this.enabled,
    lastRunAtMs: lastRunAtMs ?? this.lastRunAtMs,
    lastCompleteAtMs: lastCompleteAtMs ?? this.lastCompleteAtMs,
    lastSummary: clearSummary ? null : (lastSummary ?? this.lastSummary),
    lastError: clearError ? null : (lastError ?? this.lastError),
    lastSkippedSymlinks: lastSkippedSymlinks ?? this.lastSkippedSymlinks,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'localPath': localPath,
    if (bookmarkBase64 != null && bookmarkBase64!.isNotEmpty)
      'bookmarkBase64': bookmarkBase64,
    'rootId': rootId,
    'rootGeneration': rootGeneration,
    'rootName': rootName,
    'remoteBasePath': remoteBasePath,
    'conflictPolicy': conflictPolicy.wireValue,
    'ignoreHidden': ignoreHidden,
    'enabled': enabled,
    'lastRunAtMs': lastRunAtMs,
    'lastCompleteAtMs': lastCompleteAtMs,
    if (lastSummary != null) 'lastSummary': lastSummary,
    if (lastError != null) 'lastError': lastError,
    'lastSkippedSymlinks': lastSkippedSymlinks,
  };

  static DesktopBackupTask? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final label = raw['label'];
    final localPath = raw['localPath'];
    final rootId = raw['rootId'];
    final rootGeneration = raw['rootGeneration'];
    final rootName = raw['rootName'];
    final remoteBasePath = raw['remoteBasePath'];
    if (id is! String ||
        id.isEmpty ||
        label is! String ||
        label.isEmpty ||
        localPath is! String ||
        localPath.isEmpty ||
        rootId is! String ||
        rootId.isEmpty ||
        rootGeneration is! int ||
        rootGeneration < 1 ||
        remoteBasePath is! String ||
        remoteBasePath.isEmpty) {
      return null;
    }
    return DesktopBackupTask(
      id: id,
      label: label,
      localPath: localPath,
      bookmarkBase64: raw['bookmarkBase64'] as String?,
      rootId: rootId,
      rootGeneration: rootGeneration,
      rootName: rootName is String && rootName.isNotEmpty ? rootName : rootId,
      remoteBasePath: remoteBasePath,
      conflictPolicy: DesktopConflictPolicy.fromWire(
        raw['conflictPolicy'] as String?,
      ),
      ignoreHidden: raw['ignoreHidden'] != false,
      enabled: raw['enabled'] != false,
      lastRunAtMs: raw['lastRunAtMs'] is int ? raw['lastRunAtMs'] as int : 0,
      lastCompleteAtMs: raw['lastCompleteAtMs'] is int
          ? raw['lastCompleteAtMs'] as int
          : 0,
      lastSummary: raw['lastSummary'] as String?,
      lastError: raw['lastError'] as String?,
      lastSkippedSymlinks: raw['lastSkippedSymlinks'] is int
          ? raw['lastSkippedSymlinks'] as int
          : 0,
    );
  }
}

class DesktopBackupStore {
  DesktopBackupStore({
    required String serverOrigin,
    required int userId,
    required String accountName,
  }) : _scopePrefix =
           'lightisle.desktopBackup.v1.${sha256.convert(utf8.encode('$serverOrigin\u0000$userId\u0000$accountName')).toString().substring(0, 24)}';

  static const int maxIndexEntries = 20000;
  static const int maxSavedFailures = 80;

  final String _scopePrefix;

  String get _tasksKey => '$_scopePrefix.tasks';
  String get _scheduleKey => '$_scopePrefix.schedule';
  String _indexKey(String taskId) => '$_scopePrefix.index.$taskId';
  String _failuresKey(String taskId) => '$_scopePrefix.failures.$taskId';
  String _omittedFailuresKey(String taskId) =>
      '$_scopePrefix.failures.$taskId.omitted';
  String _uploadHintKey(String taskId, String fileDigestKey) =>
      '$_scopePrefix.upload.$taskId.$fileDigestKey';

  Future<List<DesktopBackupTask>> loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tasksKey);
    if (raw == null || raw.isEmpty) return const <DesktopBackupTask>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <DesktopBackupTask>[];
      return decoded
          .map(DesktopBackupTask.tryFromJson)
          .whereType<DesktopBackupTask>()
          .toList(growable: false);
    } catch (_) {
      return const <DesktopBackupTask>[];
    }
  }

  Future<void> saveTasks(List<DesktopBackupTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tasksKey,
      jsonEncode(tasks.map((t) => t.toJson()).toList(growable: false)),
    );
  }

  Future<DesktopBackupSchedule> loadSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    return DesktopBackupSchedule.fromWire(prefs.getString(_scheduleKey));
  }

  Future<void> saveSchedule(DesktopBackupSchedule schedule) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scheduleKey, schedule.wireValue);
  }

  Future<Map<String, DesktopBackupFileRecord>> loadFileIndex(
    String taskId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey(taskId));
    if (raw == null || raw.isEmpty) {
      return <String, DesktopBackupFileRecord>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, DesktopBackupFileRecord>{};
      final out = <String, DesktopBackupFileRecord>{};
      for (final entry in decoded.entries) {
        final record = DesktopBackupFileRecord.tryFromJson(entry.value);
        if (entry.key is String && record != null) {
          out[entry.key as String] = record;
        }
      }
      return out;
    } catch (_) {
      return <String, DesktopBackupFileRecord>{};
    }
  }

  Future<void> saveFileIndex(
    String taskId,
    Map<String, DesktopBackupFileRecord> index,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final bounded = index.length <= maxIndexEntries
        ? index
        : Map<String, DesktopBackupFileRecord>.fromEntries(
            index.entries.skip(index.length - maxIndexEntries),
          );
    await prefs.setString(
      _indexKey(taskId),
      jsonEncode(bounded.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  Future<(List<DesktopBackupFailure>, int)> loadFailures(String taskId) async {
    final prefs = await SharedPreferences.getInstance();
    final omitted = (prefs.getInt(_omittedFailuresKey(taskId)) ?? 0).clamp(
      0,
      1 << 20,
    );
    final raw = prefs.getString(_failuresKey(taskId));
    if (raw == null || raw.isEmpty) {
      return (const <DesktopBackupFailure>[], omitted);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return (const <DesktopBackupFailure>[], omitted);
      final items = decoded
          .map(DesktopBackupFailure.tryFromJson)
          .whereType<DesktopBackupFailure>()
          .toList(growable: false);
      return (items, omitted);
    } catch (_) {
      return (const <DesktopBackupFailure>[], omitted);
    }
  }

  Future<void> saveFailures(
    String taskId,
    List<DesktopBackupFailure> failures,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (failures.isEmpty) {
      await prefs.remove(_failuresKey(taskId));
      await prefs.remove(_omittedFailuresKey(taskId));
      return;
    }
    final kept = failures.take(maxSavedFailures).toList(growable: false);
    final omitted = failures.length - kept.length;
    await prefs.setString(
      _failuresKey(taskId),
      jsonEncode(kept.map((f) => f.toJson()).toList(growable: false)),
    );
    if (omitted > 0) {
      await prefs.setInt(_omittedFailuresKey(taskId), omitted);
    } else {
      await prefs.remove(_omittedFailuresKey(taskId));
    }
  }

  Future<String?> readUploadHint(String taskId, String fileDigestKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_uploadHintKey(taskId, fileDigestKey));
  }

  Future<void> writeUploadHint(
    String taskId,
    String fileDigestKey,
    String uploadId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uploadHintKey(taskId, fileDigestKey), uploadId);
  }

  Future<void> clearUploadHint(String taskId, String fileDigestKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_uploadHintKey(taskId, fileDigestKey));
  }

  Future<void> removeTaskData(String taskId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_indexKey(taskId));
    await prefs.remove(_failuresKey(taskId));
    await prefs.remove(_omittedFailuresKey(taskId));
    final uploadPrefix = '$_scopePrefix.upload.$taskId.';
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(uploadPrefix)).toList()) {
      await prefs.remove(key);
    }
  }
}
