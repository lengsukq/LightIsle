part of 'android_photo_backup_page.dart';

extension _AndroidPhotoBackupOptions on _AndroidPhotoBackupState {
  String get _scope {
    final original =
        'lightisle.photoBackup.${widget.api.uri('/api/v2/me/storage').origin}.${widget.accountName}.$_deviceId';
    return '$original.${_boundRoot?.identity ?? 'unassigned'}.${widget.baseDirectory}';
  }

  bool get _personalDestination => widget.baseDirectory != 'PhonePhotos';
  // Shared by the Android and iOS foreground photo import. Every photo
  // operation is v2-only and sends a frozen physical-root generation. The
  // server, not a client-provided pathname, enforces account permissions.
  String _photoApi(String suffix) {
    final root = _boundRoot;
    if (root == null || !root.online || !_personalDestination) {
      throw StateError('请先为照片配置在线个人硬盘，再从图库开启照片备份。');
    }
    if (!RegExp(r'^(files(?:/.*)?|uploads(?:/.*)?)$').hasMatch(suffix)) {
      throw ArgumentError('照片备份接口不支持此操作。');
    }
    return '/api/v2/roots/${Uri.encodeComponent(root.id)}/$suffix';
  }

  Map<String, String> _photoQuery([Map<String, String>? extra]) => {
    ...?extra,
    'rootGeneration': '${_boundRoot?.generation ?? 0}',
  };

  Future<void> _saveOptions() async {
    await _prefs?.setBool('$_scope.onForeground', _onForeground);
    await _prefs?.setBool('$_scope.wifiOnly', _wifiOnly);
    await _prefs?.setInt('$_scope.batchPages', _batchPages);
    await _prefs?.setBool('$_scope.includeVideos', _includeVideos);
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('lightisle.photoBackup.installationId');
      if (id == null || !RegExp(r'^[a-f0-9]{24}$').hasMatch(id)) {
        final random = Random.secure();
        id = List.generate(
          12,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await prefs.setString('lightisle.photoBackup.installationId', id);
      }
      if (!mounted) return;
      _deviceId = id;
      _prefs = prefs;
      _pageCursor = prefs.getString('$_scope.cursor') ?? '';
      _updateState(() {
        _onForeground = prefs.getBool('$_scope.onForeground') ?? false;
        _wifiOnly = prefs.getBool('$_scope.wifiOnly') ?? true;
        _batchPages = [10, 30, 100].contains(prefs.getInt('$_scope.batchPages'))
            ? prefs.getInt('$_scope.batchPages')!
            : 10;
        _includeVideos = prefs.getBool('$_scope.includeVideos') ?? false;
        _lastVerifiedAt = prefs.getInt('$_scope.lastVerifiedAt') ?? 0;
        _lastCompleteAt = prefs.getInt('$_scope.lastCompleteAt') ?? 0;
        _failureDetails = _readPhotoFailures(prefs, _photoFailureStorageKey());
      });
      if (_isAndroid) unawaited(_readBackgroundStatus());
      if (_onForeground) unawaited(_run(older: _pageCursor.isNotEmpty));
    } catch (_) {
      if (mounted) _updateState(() => _message = '无法访问本机备份记录，请检查手机存储权限。');
    }
  }
}
