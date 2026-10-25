import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

/// Optional local hint for resuming a server-owned upload. Its failure must
/// never cause a transfer to fail or pretend a remote staging file was removed.
class UploadResumeStore {
  UploadResumeStore({
    Future<SharedPreferences> Function()? openPreferences,
    void Function(Object)? reportFailure,
  }) : _openPreferences = openPreferences ?? SharedPreferences.getInstance,
       _reportFailure = reportFailure ?? _logFailure;

  final Future<SharedPreferences> Function() _openPreferences;
  final void Function(Object) _reportFailure;

  Future<String?> read(String key) async {
    try {
      return (await _openPreferences()).getString(key);
    } catch (error) {
      _reportFailure(error);
      return null;
    }
  }

  Future<void> write(String key, String uploadID) async {
    try {
      final persisted = await (await _openPreferences()).setString(key, uploadID);
      if (!persisted) throw StateError('upload resume preference was not stored');
    } catch (error) {
      _reportFailure(error);
    }
  }

  Future<void> remove(String? key) async {
    if (key == null) return;
    try {
      final removed = await (await _openPreferences()).remove(key);
      if (!removed) throw StateError('upload resume preference was not removed');
    } catch (error) {
      _reportFailure(error);
    }
  }

  static void _logFailure(Object error) {
    // Avoid logging resume keys, file paths, upload IDs or user credentials.
    developer.log(
      '本地上传续传记录读写失败：${error.runtimeType}',
      name: 'lightisle.upload',
    );
  }
}
