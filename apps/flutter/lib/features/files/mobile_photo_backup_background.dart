part of 'mobile_photo_backup_page.dart';

extension _MobilePhotoBackupBackground on _MobilePhotoBackupState {
  Widget _buildAndroidBackgroundStatus(ThemeData theme, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '系统任务：$_backgroundWorkLabel',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '最近进度或结果：$_backgroundResult',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (_backgroundLastCompletedAt case final completed?)
            Text(
              '上次扫描至相册末尾 ${_backupLocalTime(completed)}',
              style: theme.textTheme.bodySmall,
            ),
          if (_personalDestination && _backgroundExpiresAt != null)
            Text(
              '授权有效至 ${_backupLocalTime(_backgroundExpiresAt!)}',
              style: theme.textTheme.bodySmall,
            ),
          if (_personalDestination)
            TextButton(
              onPressed: _busy || _backgroundBusy
                  ? null
                  : () => unawaited(_configureBackground(true)),
              child: Text(_backgroundEnabled ? '续授权' : '授权后台备份'),
            ),
          if (_backgroundActionMessage != null) ...[
            const SizedBox(height: 4),
            Text(
              _backgroundActionMessage!,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ],
          if (_backgroundEnabled && !_backgroundSessionMatches) ...[
            const SizedBox(height: 4),
            Text(
              '当前登录会话与后台备份授权不一致；如需继续，请关闭后重新开启后台备份。',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _readBackgroundStatus() async {
    final generation = ++_backgroundStatusGeneration;
    try {
      final result = await _backgroundChannel.invokeMapMethod<String, dynamic>(
        'status',
      );
      if (!_isCurrentBackgroundStatusRead(generation)) return;
      _updateState(() {
        _applyBackgroundStatus(result);
      });
    } catch (_) {
      if (_isCurrentBackgroundStatusRead(generation)) {
        _updateState(() {
          _backgroundResult = '无法读取系统后台任务状态';
          _backgroundWorkState = 'unknown';
        });
      }
    }
  }

  bool _isCurrentBackgroundStatusRead(int generation) =>
      mounted && !_backgroundBusy && generation == _backgroundStatusGeneration;

  void _beginBackgroundWrite() {
    _backgroundStatusGeneration++;
    _updateState(() => _backgroundBusy = true);
  }

  void _finishBackgroundWrite() {
    _backgroundStatusGeneration++;
    if (mounted) _updateState(() => _backgroundBusy = false);
  }

  void _applyBackgroundStatus(Map<String, dynamic>? result) {
    _backgroundEnabled = result?['enabled'] == true;
    _backgroundSessionMatches = result?['sessionMatches'] == true;
    _backgroundExpiresAt = _backupTime(result?['expiresAt']);
    _backgroundLastCompletedAt = _backupTime(result?['lastCompletedAt']);
    _backgroundResult = result?['last']?.toString() ?? '尚未执行';
    _backgroundWorkState = result?['workState']?.toString() ?? 'unknown';
  }

  DateTime? _backupTime(Object? value) {
    final milliseconds = (value as num?)?.toInt() ?? 0;
    return milliseconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(milliseconds)
        : null;
  }

  String _backupLocalTime(DateTime value) {
    final locale = MaterialLocalizations.of(context);
    return '${locale.formatShortDate(value)} '
        '${locale.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
  }

  String get _backgroundWorkLabel => switch (_backgroundWorkState) {
    'enqueued' => '已排队，等待 Wi-Fi、电量和系统调度条件',
    'running' => '正在备份照片',
    'blocked' => '等待前序后台任务完成',
    'trigger_running' => '系统正在安排照片检查',
    'scheduled' => '后台计划已启用，等待系统条件',
    'none' => '当前没有排队或执行中的任务',
    _ => '暂时无法确定系统任务状态',
  };

  Future<void> _requestBackgroundCheck() async {
    if (_busy || _backgroundBusy || !_backgroundEnabled || _deviceId.isEmpty) {
      return;
    }
    _beginBackgroundWrite();
    _updateState(() {
      _backgroundActionMessage = null;
    });
    try {
      final result = await _backgroundChannel.invokeMapMethod<String, dynamic>(
        'enqueueScan',
        {
          'server': widget.api.uri('/api/v2/me/storage').origin,
          'cookie': widget.api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
        },
      );
      if (!mounted) return;
      _updateState(() {
        _applyBackgroundStatus(result);
        _backgroundActionMessage = '已提交后台检查；系统会在 Wi-Fi、电量等条件允许时执行，已有任务会继续沿用。';
      });
    } catch (_) {
      if (mounted) {
        _updateState(() {
          _backgroundActionMessage = '无法安排后台检查：请确认仍登录当前账号且系统后台备份已开启。';
        });
      }
    } finally {
      _finishBackgroundWrite();
    }
  }

  Future<void> _syncBackgroundOptions() async {
    if (!_isAndroid || !_backgroundEnabled || _backgroundBusy) return;
    try {
      final result = await _backgroundChannel.invokeMapMethod<String, dynamic>(
        'updateOptions',
        {
          'server': widget.api.uri('/api/v2/me/storage').origin,
          'cookie': widget.api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
          'albumScope': _albumScope,
          'organizeByYearMonth': _organizeByYearMonth,
        },
      );
      if (mounted && result != null) {
        _updateState(() => _applyBackgroundStatus(result));
      }
    } catch (_) {
      // Keep foreground preference write resilient even if native channel is absent in unit tests.
    }
  }

  Future<void> _configureBackground(bool enabled) async {
    if (_backgroundBusy || _deviceId.isEmpty) return;
    LightIsleRoot? destinationRoot;
    if (enabled) {
      destinationRoot = widget.api.selectedRoot;
      if (destinationRoot == null ||
          !_personalDestination ||
          !destinationRoot.online) {
        if (mounted) {
          _updateState(
            () => _backgroundActionMessage =
                '请在存储设置中为照片分配在线硬盘，再从图库打开个人照片备份。后台任务只支持安全的 v2 专属照片目录。',
          );
        }
        return;
      }
      try {
        final policy = await widget.api.get('/api/v2/me/storage');
        final locations = policy['locations'];
        final userId = policy['userId'];
        final expectedPath = 'Users/u$userId/photos';
        if (userId is! int ||
            userId <= 0 ||
            widget.baseDirectory != expectedPath ||
            locations is! List ||
            !locations.any(
              (value) =>
                  value is Map &&
                  value['category'] == 'photos' &&
                  value['rootID'] == destinationRoot!.id &&
                  value['rootGeneration'] == destinationRoot.generation &&
                  value['relativePath'] == expectedPath,
            )) {
          throw const FormatException('个人照片目录绑定已变化。');
        }
        final discovery = await widget.api.get('/api/v2/roots');
        final online = discovery['roots'];
        if (online is! List ||
            !online.any(
              (value) =>
                  value is Map &&
                  value['rootID'] == destinationRoot!.id &&
                  value['generation'] == destinationRoot.generation &&
                  value['online'] == true,
            )) {
          throw const FormatException('照片硬盘已离线或被替换。');
        }
      } catch (_) {
        if (mounted) {
          _updateState(
            () => _backgroundActionMessage =
                '照片硬盘连接或账号存储绑定无法验证。请回到图库刷新硬盘状态后重试；后台备份未开启。',
          );
        }
        return;
      }
      if (!mounted ||
          widget.api.selectedRoot?.identity != destinationRoot.identity) {
        return;
      }
      if (!await _permission(includeVideos: false)) {
        if (mounted) _updateState(() => _backgroundResult = '需要完整相册读取权限。');
        return;
      }
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启系统后台照片备份？'),
          content: const Text(
            'Android 会在 Wi-Fi 且电量充足时约每 6 小时安排一次任务，具体时间由系统决定。'
            '为使 App 关闭后仍可连接 NAS，当前账号的完整登录会话会使用 Android Keystore 加密保存在本机，'
            '最长保留 7 天；这不是专用的只写备份令牌。推荐使用限制目录权限的 NAS 成员账号。'
            '建议开启 Mac 的 HTTPS：如果使用 LAN HTTP，尽管会话在手机本机加密保存，网络传输仍不加密。'
            '退出登录、关闭后台备份或会话失效后会移除该授权。照片不会从手机删除。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('同意并开启'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    _beginBackgroundWrite();
    try {
      final result = enabled
          ? await _backgroundChannel.invokeMapMethod<String, dynamic>(
              'enable',
              {
                'server': widget.api.uri('/api/v2/me/storage').origin,
                'cookie':
                    widget.api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
                'certificateFingerprint':
                    widget.api.certificateFingerprint ?? '',
                'deviceId': _deviceId,
                'rootID': destinationRoot!.id,
                'rootGeneration': destinationRoot.generation,
                'photosPath': widget.baseDirectory,
                'albumScope': _albumScope,
                'organizeByYearMonth': _organizeByYearMonth,
              },
            )
          : await _backgroundChannel.invokeMapMethod<String, dynamic>(
              'disable',
              {
                'server': widget.api.uri('/api/v2/me/storage').origin,
                'cookie':
                    widget.api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
              },
            );
      if (!mounted) return;
      _updateState(() {
        _applyBackgroundStatus(result);
        _backgroundActionMessage = null;
      });
    } catch (_) {
      if (mounted) {
        _updateState(
          () => _backgroundResult = '后台配置失败：请确认登录状态、NAS 地址和证书指纹；原有前台备份仍可正常使用。',
        );
      }
    } finally {
      _finishBackgroundWrite();
    }
  }
}
