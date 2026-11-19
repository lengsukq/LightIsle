part of 'mobile_photo_backup_page.dart';

extension _MobilePhotoBackupOptions on _MobilePhotoBackupState {
  String get _scope {
    final original =
        'lightisle.photoBackup.${widget.api.uri('/api/v2/me/storage').origin}.${widget.accountName}.${_options.deviceId}';
    return '$original.${_boundRoot?.identity ?? 'unassigned'}.${widget.baseDirectory}';
  }

  String get _scopedStatePrefix =>
      _options.albumScope == 'camera' ? '$_scope.camera' : _scope;

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
    await _prefs?.setString('$_scope.albumScope', _options.albumScope);
    await _prefs?.setBool('$_scope.onForeground', _options.onForeground);
    await _prefs?.setBool('$_scope.wifiOnly', _options.wifiOnly);
    await _prefs?.setInt('$_scope.batchPages', _options.batchPages);
    await _prefs?.setBool('$_scope.includeVideos', _options.includeVideos);
    await _prefs?.setBool(
      '$_scope.organizeByYearMonth',
      _options.organizeByYearMonth,
    );
    await _prefs?.setBool(
      '$_scope.allowICloudDownload',
      _options.allowICloudDownload,
    );
    if (_isAndroid && _background.enabled && _background.sessionMatches) {
      unawaited(_syncBackgroundOptions());
    }
  }

  String _targetDirectoryForEntry(String destinationDir, int modified) {
    if (!_options.organizeByYearMonth || modified <= 0) return destinationDir;
    final ms = modified > 100000000000 ? modified : modified * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    return '$destinationDir/$year/$month';
  }

  void _switchAlbumScope(String nextScope) {
    if (_progress.busy || nextScope == _options.albumScope) return;
    final prefs = _prefs;
    _updateState(() {
      _options.albumScope = nextScope;
      _progress.pageCursor =
          prefs?.getString('$_scopedStatePrefix.cursor') ?? '';
      _progress.nextCursor = '';
      _progress.visibleFailureCount = 50;
      _progress.lastVerifiedAt =
          prefs?.getInt('$_scopedStatePrefix.lastVerifiedAt') ?? 0;
      _progress.lastCompleteAt =
          prefs?.getInt('$_scopedStatePrefix.lastCompleteAt') ?? 0;
      try {
        _progress.failureDetails = prefs == null
            ? []
            : _readPhotoFailures(prefs, _photoFailureStorageKey());
      } catch (_) {
        _progress.failureDetails = [];
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
      _options.deviceId = id;
      _prefs = prefs;
      final savedScope = prefs.getString('$_scope.albumScope');
      if (savedScope == 'camera' || savedScope == 'all') {
        _options.albumScope = savedScope!;
      } else {
        final hasLegacyProgress =
            prefs.containsKey('$_scope.cursor') ||
            prefs.containsKey('$_scope.lastCompleteAt') ||
            prefs.containsKey('$_scope.failures.photos') ||
            prefs.containsKey('$_scope.failures.videos');
        _options.albumScope = hasLegacyProgress ? 'all' : 'camera';
      }
      _progress.pageCursor =
          prefs.getString('$_scopedStatePrefix.cursor') ?? '';
      _updateState(() {
        _options.onForeground = prefs.getBool('$_scope.onForeground') ?? false;
        _options.wifiOnly = prefs.getBool('$_scope.wifiOnly') ?? true;
        _options.batchPages =
            [10, 30, 100].contains(prefs.getInt('$_scope.batchPages'))
            ? prefs.getInt('$_scope.batchPages')!
            : 10;
        _options.includeVideos =
            prefs.getBool('$_scope.includeVideos') ?? false;
        _options.organizeByYearMonth =
            prefs.getBool('$_scope.organizeByYearMonth') ?? false;
        _options.allowICloudDownload =
            prefs.getBool('$_scope.allowICloudDownload') ?? false;
        _progress.lastVerifiedAt =
            prefs.getInt('$_scopedStatePrefix.lastVerifiedAt') ??
            prefs.getInt('$_scope.lastVerifiedAt') ??
            0;
        _progress.lastCompleteAt =
            prefs.getInt('$_scopedStatePrefix.lastCompleteAt') ??
            prefs.getInt('$_scope.lastCompleteAt') ??
            0;
        _progress.failureDetails = _readPhotoFailures(
          prefs,
          _photoFailureStorageKey(),
        );
      });
      if (_isAndroid) unawaited(_readBackgroundStatus());
      if (_options.onForeground) {
        unawaited(_run(older: _progress.pageCursor.isNotEmpty));
      }
    } catch (_) {
      if (mounted) {
        _updateState(() => _progress.message = '无法访问本机备份记录，请检查手机存储权限。');
      }
    }
  }

  Widget _buildOptionsSurface(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    Widget divider() => Divider(
      height: 1,
      thickness: 1,
      indent: 14,
      endIndent: 14,
      color: borderColor,
    );

    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '备份相册范围',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  segments: const [
                    ButtonSegment<String>(
                      value: 'camera',
                      icon: Icon(Icons.camera_alt_outlined, size: 16),
                      label: Text('仅相机拍摄（推荐）'),
                    ),
                    ButtonSegment<String>(
                      value: 'all',
                      icon: Icon(Icons.photo_library_outlined, size: 16),
                      label: Text('全部手机媒体'),
                    ),
                  ],
                  selected: {_options.albumScope},
                  onSelectionChanged: _progress.busy
                      ? null
                      : (selected) => _switchAlbumScope(selected.first),
                ),
              ],
            ),
          ),
          divider(),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            title: const Text(
              '进入此页面或返回前台时自动检查',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            value: _options.onForeground,
            onChanged: _progress.busy
                ? null
                : (value) {
                    _updateState(() => _options.onForeground = value);
                    unawaited(_saveOptions());
                  },
          ),
          divider(),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            title: const Text(
              '仅 Wi-Fi 备份',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            value: _options.wifiOnly,
            onChanged: _progress.busy
                ? null
                : (value) {
                    _updateState(() => _options.wifiOnly = value);
                    unawaited(_saveOptions());
                  },
          ),
          if (_isIOS) ...[
            divider(),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 2,
              ),
              title: const Text(
                'Wi-Fi 下允许下载 iCloud 原片后备份',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              value: _options.allowICloudDownload,
              onChanged: _progress.busy
                  ? null
                  : (value) {
                      _updateState(() => _options.allowICloudDownload = value);
                      unawaited(_saveOptions());
                    },
            ),
          ],
          if (_isAndroid && _personalDestination) ...[
            divider(),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 2,
              ),
              title: const Text(
                '系统后台自动备份（每 6 小时检查）',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              value: _background.enabled,
              onChanged: _background.busy
                  ? null
                  : (value) => unawaited(_configureBackground(value)),
            ),
          ],
          if (_isAndroid) _buildAndroidBackgroundStatus(theme, colors),
          divider(),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            title: const Text(
              '同时备份视频',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            value: _options.includeVideos,
            onChanged: _progress.busy
                ? null
                : (value) {
                    _updateState(() {
                      _options.includeVideos = value;
                      _progress.pageCursor = '';
                      _progress.nextCursor = '';
                      _progress.visibleFailureCount = 50;
                      try {
                        _progress.failureDetails = _prefs == null
                            ? []
                            : _readPhotoFailures(
                                _prefs!,
                                _photoFailureStorageKey(),
                              );
                      } catch (_) {
                        _progress.failureDetails = [];
                        _progress.message = '本机待处理记录无法读取，请重新检查备份。';
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
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            title: const Text(
              '按拍摄年月分目录（YYYY/MM）',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            value: _options.organizeByYearMonth,
            onChanged: _progress.busy
                ? null
                : (value) {
                    _updateState(() => _options.organizeByYearMonth = value);
                    unawaited(_saveOptions());
                  },
          ),
        ],
      ),
    );
  }

  Future<void> _showBatchSettingsDialog(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(color: IsleGlass.rimBorderColor(isDark)),
          ),
          title: const Text('批量与备份记录'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: _options.batchPages,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '单次前台检查批量',
                  ),
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('400 张 · 省电模式')),
                    DropdownMenuItem(value: 30, child: Text('1200 张 · 普通批量')),
                    DropdownMenuItem(value: 100, child: Text('4000 张 · 首次补跑')),
                  ],
                  onChanged: _progress.busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          _updateState(() => _options.batchPages = value);
                          setDialogState(() {});
                          unawaited(_saveOptions());
                        },
                ),
                const SizedBox(height: 12),
                IsleKeyValueRow(
                  label: '最近核对',
                  value: _progress.lastVerifiedAt > 0
                      ? DateTime.fromMillisecondsSinceEpoch(
                          _progress.lastVerifiedAt,
                        ).toLocal().toString().substring(0, 16)
                      : '尚无',
                ),
                IsleKeyValueRow(
                  label: '最近扫描至末尾',
                  value: _progress.lastCompleteAt > 0
                      ? DateTime.fromMillisecondsSinceEpoch(
                          _progress.lastCompleteAt,
                        ).toLocal().toString().substring(0, 16)
                      : '尚无',
                ),
                const SizedBox(height: 6),
                Text(
                  '大相册首次备份可选 1200 或 4000 张；客户端逐张校验，不会并发读取大量原片。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton.tonal(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }
}
