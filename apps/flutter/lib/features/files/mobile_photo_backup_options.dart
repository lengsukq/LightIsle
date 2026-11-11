part of 'mobile_photo_backup_page.dart';

extension _MobilePhotoBackupOptions on _MobilePhotoBackupState {
  String get _scope {
    final original =
        'lightisle.photoBackup.${widget.api.uri('/api/v2/me/storage').origin}.${widget.accountName}.$_deviceId';
    return '$original.${_boundRoot?.identity ?? 'unassigned'}.${widget.baseDirectory}';
  }

  String get _scopedStatePrefix =>
      _albumScope == 'camera' ? '$_scope.camera' : _scope;

  bool get _personalDestination => widget.baseDirectory != 'PhonePhotos';

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
    await _prefs?.setString('$_scope.albumScope', _albumScope);
    await _prefs?.setBool('$_scope.onForeground', _onForeground);
    await _prefs?.setBool('$_scope.wifiOnly', _wifiOnly);
    await _prefs?.setInt('$_scope.batchPages', _batchPages);
    await _prefs?.setBool('$_scope.includeVideos', _includeVideos);
    await _prefs?.setBool('$_scope.organizeByYearMonth', _organizeByYearMonth);
    await _prefs?.setBool('$_scope.allowICloudDownload', _allowICloudDownload);
    if (_isAndroid && _backgroundEnabled && _backgroundSessionMatches) {
      unawaited(_syncBackgroundOptions());
    }
  }

  String _targetDirectoryForEntry(String destinationDir, int modified) {
    if (!_organizeByYearMonth || modified <= 0) return destinationDir;
    final ms = modified > 100000000000 ? modified : modified * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    return '$destinationDir/$year/$month';
  }

  void _switchAlbumScope(String nextScope) {
    if (_busy || nextScope == _albumScope) return;
    final prefs = _prefs;
    _updateState(() {
      _albumScope = nextScope;
      _pageCursor = prefs?.getString('$_scopedStatePrefix.cursor') ?? '';
      _nextCursor = '';
      _visibleFailureCount = 50;
      _lastVerifiedAt =
          prefs?.getInt('$_scopedStatePrefix.lastVerifiedAt') ?? 0;
      _lastCompleteAt =
          prefs?.getInt('$_scopedStatePrefix.lastCompleteAt') ?? 0;
      try {
        _failureDetails = prefs == null
            ? []
            : _readPhotoFailures(prefs, _photoFailureStorageKey());
      } catch (_) {
        _failureDetails = [];
      }
    });
    unawaited(_saveOptions());
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
      final savedScope = prefs.getString('$_scope.albumScope');
      if (savedScope == 'camera' || savedScope == 'all') {
        _albumScope = savedScope!;
      } else {
        final hasLegacyProgress =
            prefs.containsKey('$_scope.cursor') ||
            prefs.containsKey('$_scope.lastCompleteAt') ||
            prefs.containsKey('$_scope.failures.photos') ||
            prefs.containsKey('$_scope.failures.videos');
        _albumScope = hasLegacyProgress ? 'all' : 'camera';
      }
      _pageCursor = prefs.getString('$_scopedStatePrefix.cursor') ?? '';
      _updateState(() {
        _onForeground = prefs.getBool('$_scope.onForeground') ?? false;
        _wifiOnly = prefs.getBool('$_scope.wifiOnly') ?? true;
        _batchPages = [10, 30, 100].contains(prefs.getInt('$_scope.batchPages'))
            ? prefs.getInt('$_scope.batchPages')!
            : 10;
        _includeVideos = prefs.getBool('$_scope.includeVideos') ?? false;
        _organizeByYearMonth =
            prefs.getBool('$_scope.organizeByYearMonth') ?? false;
        _allowICloudDownload =
            prefs.getBool('$_scope.allowICloudDownload') ?? false;
        _lastVerifiedAt =
            prefs.getInt('$_scopedStatePrefix.lastVerifiedAt') ??
            prefs.getInt('$_scope.lastVerifiedAt') ??
            0;
        _lastCompleteAt =
            prefs.getInt('$_scopedStatePrefix.lastCompleteAt') ??
            prefs.getInt('$_scope.lastCompleteAt') ??
            0;
        _failureDetails = _readPhotoFailures(prefs, _photoFailureStorageKey());
      });
      if (_isAndroid) unawaited(_readBackgroundStatus());
      if (_onForeground) unawaited(_run(older: _pageCursor.isNotEmpty));
    } catch (_) {
      if (mounted) _updateState(() => _message = '无法访问本机备份记录，请检查手机存储权限。');
    }
  }

  Widget _buildOptionsSurface(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
  ) {
    Widget divider() => Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: colors.outlineVariant.withValues(alpha: 0.3),
    );

    return IsleSurface(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '备份相册范围',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isAndroid
                      ? (_albumScope == 'camera'
                            ? '仅扫描相机目录（DCIM），自动排除微信表情包、应用缓存图片与屏幕截图。'
                            : '扫描手机上的全部图片媒体（可能包含聊天缓存、下载图与屏幕截图）。')
                      : (_albumScope == 'camera'
                            ? '聚焦拍摄照片与实况影像，自动排除屏幕截图。'
                            : '扫描系统照片库中的全部项目（含屏幕截图与保存的图片）。'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment<String>(
                      value: 'camera',
                      icon: Icon(Icons.camera_alt_outlined, size: 17),
                      label: Text('仅相机拍摄（推荐）'),
                    ),
                    ButtonSegment<String>(
                      value: 'all',
                      icon: Icon(Icons.photo_library_outlined, size: 17),
                      label: Text('全部手机媒体'),
                    ),
                  ],
                  selected: {_albumScope},
                  onSelectionChanged: _busy
                      ? null
                      : (selected) => _switchAlbumScope(selected.first),
                ),
              ],
            ),
          ),
          divider(),
          SwitchListTile(
            title: const Text('进入此页面或返回前台时自动检查'),
            subtitle: const Text('只在 App 前台自动启动；不是 Android 系统后台定时任务。'),
            value: _onForeground,
            onChanged: _busy
                ? null
                : (value) {
                    _updateState(() => _onForeground = value);
                    unawaited(_saveOptions());
                  },
          ),
          divider(),
          SwitchListTile(
            title: const Text('仅 Wi-Fi 备份'),
            value: _wifiOnly,
            onChanged: _busy
                ? null
                : (value) {
                    _updateState(() => _wifiOnly = value);
                    unawaited(_saveOptions());
                  },
          ),
          if (_isIOS) ...[
            divider(),
            SwitchListTile(
              title: const Text('Wi-Fi 下允许下载 iCloud 原片后备份'),
              subtitle: const Text(
                '开启「优化 iPhone 存储空间」时，仅在连接 Wi-Fi 期间向 iCloud 请求尚未落盘的原片。',
              ),
              value: _allowICloudDownload,
              onChanged: _busy
                  ? null
                  : (value) {
                      _updateState(() => _allowICloudDownload = value);
                      unawaited(_saveOptions());
                    },
            ),
          ],
          if (_isAndroid && _personalDestination) ...[
            divider(),
            SwitchListTile(
              title: const Text('系统后台自动备份（每 6 小时检查）'),
              subtitle: const Text(
                '需明确授权；系统在 Wi-Fi 和电量允许时调度。完整登录会话以 Android Keystore 加密保存最多 7 天，关闭或退出登录即清除。',
              ),
              value: _backgroundEnabled,
              onChanged: _backgroundBusy
                  ? null
                  : (value) => unawaited(_configureBackground(value)),
            ),
          ],
          if (_isAndroid) _buildAndroidBackgroundStatus(theme, colors),
          divider(),
          SwitchListTile(
            title: const Text('同时备份视频'),
            subtitle: Text(
              _isAndroid
                  ? '需要系统视频读取授权。前台支持流式上传超 2 GiB 的 4K/长视频；定时后台备份仍只处理照片。'
                  : '包含普通视频和 Live Photo 的配套视频原片；可能明显增加存储和网络用量。',
            ),
            value: _includeVideos,
            onChanged: _busy
                ? null
                : (value) {
                    _updateState(() {
                      _includeVideos = value;
                      _pageCursor = '';
                      _nextCursor = '';
                      _visibleFailureCount = 50;
                      try {
                        _failureDetails = _prefs == null
                            ? []
                            : _readPhotoFailures(
                                _prefs!,
                                _photoFailureStorageKey(),
                              );
                      } catch (_) {
                        _failureDetails = [];
                        _message = '本机待处理记录无法读取，请重新检查备份。';
                      }
                    });
                    unawaited(_prefs?.remove('$_scopedStatePrefix.cursor'));
                    unawaited(
                      _prefs?.remove('$_scopedStatePrefix.storeVersion'),
                    );
                    unawaited(_saveOptions());
                  },
          ),
          divider(),
          SwitchListTile(
            title: const Text('按拍摄年月分目录（YYYY/MM）'),
            subtitle: const Text(
              '开启后前台备份按拍摄时间写入 设备目录/2026/05/…，方便在 Finder 中按月份浏览。',
            ),
            value: _organizeByYearMonth,
            onChanged: _busy
                ? null
                : (value) {
                    _updateState(() => _organizeByYearMonth = value);
                    unawaited(_saveOptions());
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedDisclosure(ThemeData theme, ColorScheme colors) {
    return IsleDisclosureCard(
      title: const Text('高级批量设置与备份记录'),
      initiallyExpanded: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int>(
                initialValue: _batchPages,
                decoration: InputDecoration(
                  labelText: '单次前台检查批量',
                  helperText: '大相册首次备份可选择 1200 或 4000 张；手机会逐张核验，不会并发大量读取原片。',
                  filled: true,
                  fillColor: colors.surfaceContainerHighest.withValues(
                    alpha: 0.35,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 10, child: Text('400 张 · 省电模式')),
                  DropdownMenuItem(value: 30, child: Text('1200 张 · 普通批量')),
                  DropdownMenuItem(value: 100, child: Text('4000 张 · 首次补跑')),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null) return;
                        _updateState(() => _batchPages = value);
                        unawaited(_saveOptions());
                      },
              ),
              const SizedBox(height: 10),
              Text(
                '最近成功核对：${_lastVerifiedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(_lastVerifiedAt).toLocal().toString().substring(0, 16) : "尚无"} · '
                '最近扫描至末尾：${_lastCompleteAt > 0 ? DateTime.fromMillisecondsSinceEpoch(_lastCompleteAt).toLocal().toString().substring(0, 16) : "尚无"}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
