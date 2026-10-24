import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/isle_theme.dart';

const _photosChannel = MethodChannel('lightisle/photos');
const _backgroundChannel = MethodChannel('lightisle/photos-background');

class AndroidPhotoBackupPage extends StatefulWidget {
  const AndroidPhotoBackupPage({
    super.key,
    required this.api,
    required this.accountName,
    @visibleForTesting this.androidPlatformOverride,
  });
  final LightIsleApi api;
  final String accountName;
  @visibleForTesting
  final bool? androidPlatformOverride;

  @override
  State<AndroidPhotoBackupPage> createState() => _AndroidPhotoBackupState();
}

class _AndroidPhotoBackupState extends State<AndroidPhotoBackupPage>
    with WidgetsBindingObserver {
  bool _busy = false, _cancel = false, _onForeground = false, _wifiOnly = true;
  bool _backgroundEnabled = false, _backgroundBusy = false;
  bool _backgroundSessionMatches = false;
  bool _isForeground = true, _resumeAfterCurrentRun = false;
  String _backgroundResult = '后台备份未开启';
  String _backgroundWorkState = 'none';
  String? _backgroundActionMessage;
  int _backgroundStatusGeneration = 0;
  int _checked = 0, _uploaded = 0, _skipped = 0;
  String _message = '授权读取手机照片后，可把照片备份到你的 Mac。';
  String _pageCursor = '', _nextCursor = '', _deviceId = '';
  String? _activePrepareRequestId, _cancelledPrepareRequestId;
  int _prepareSequence = 0;
  SharedPreferences? _prefs;

  String get _scope =>
      'lightisle.photoBackup.${widget.api.uri('/api/v1/files').origin}.${widget.accountName}.$_deviceId';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
  }

  Future<void> _readBackgroundStatus() async {
    final generation = ++_backgroundStatusGeneration;
    try {
      final result = await _backgroundChannel.invokeMapMethod<String, dynamic>(
        'status',
      );
      if (!_isCurrentBackgroundStatusRead(generation)) return;
      setState(() {
        _applyBackgroundStatus(result);
      });
    } catch (_) {
      if (_isCurrentBackgroundStatusRead(generation)) {
        setState(() {
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
    setState(() => _backgroundBusy = true);
  }

  void _finishBackgroundWrite() {
    _backgroundStatusGeneration++;
    if (mounted) setState(() => _backgroundBusy = false);
  }

  void _applyBackgroundStatus(Map<String, dynamic>? result) {
    _backgroundEnabled = result?['enabled'] == true;
    _backgroundSessionMatches = result?['sessionMatches'] == true;
    _backgroundResult = result?['last']?.toString() ?? '尚未执行';
    _backgroundWorkState = result?['workState']?.toString() ?? 'unknown';
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
    setState(() {
      _backgroundActionMessage = null;
    });
    try {
      final result = await _backgroundChannel.invokeMapMethod<String, dynamic>(
        'enqueueScan',
        {
          'server': widget.api.uri('/api/v1/files').origin,
          'cookie': widget.api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
        },
      );
      if (!mounted) return;
      setState(() {
        _applyBackgroundStatus(result);
        _backgroundActionMessage = '已提交后台检查；系统会在 Wi-Fi、电量等条件允许时执行，已有任务会继续沿用。';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _backgroundActionMessage = '无法安排后台检查：请确认仍登录当前账号且系统后台备份已开启。';
        });
      }
    } finally {
      _finishBackgroundWrite();
    }
  }

  Future<void> _configureBackground(bool enabled) async {
    if (_backgroundBusy || _deviceId.isEmpty) return;
    if (enabled) {
      if (!await _permission()) {
        if (mounted) setState(() => _backgroundResult = '需要完整相册读取权限。');
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
                'server': widget.api.uri('/api/v1/files').origin,
                'cookie':
                    widget.api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
                'certificateFingerprint':
                    widget.api.certificateFingerprint ?? '',
                'deviceId': _deviceId,
              },
            )
          : await _backgroundChannel.invokeMapMethod<String, dynamic>(
              'disable',
              {
                'server': widget.api.uri('/api/v1/files').origin,
                'cookie':
                    widget.api.mediaHeaders[HttpHeaders.cookieHeader] ?? '',
              },
            );
      if (!mounted) return;
      setState(() {
        _applyBackgroundStatus(result);
        _backgroundActionMessage = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _backgroundResult = '后台配置失败：请确认登录状态、NAS 地址和证书指纹；原有前台备份仍可正常使用。',
        );
      }
    } finally {
      _finishBackgroundWrite();
    }
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
      setState(() {
        _onForeground = prefs.getBool('$_scope.onForeground') ?? false;
        _wifiOnly = prefs.getBool('$_scope.wifiOnly') ?? true;
      });
      unawaited(_readBackgroundStatus());
      if (_onForeground) unawaited(_run(older: _pageCursor.isNotEmpty));
    } catch (_) {
      if (mounted) setState(() => _message = '无法访问本机备份记录，请检查手机存储权限。');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isForeground = true;
      unawaited(_readBackgroundStatus());
      if (_onForeground) {
        if (_busy) {
          // The previous run may still be awaiting native cancellation and
          // temp-file cleanup. Queue one pass instead of losing this resume.
          if (_cancel) _resumeAfterCurrentRun = true;
        } else {
          unawaited(_run(older: _pageCursor.isNotEmpty));
        }
      }
    } else {
      _isForeground = false;
      // Prevent a long-running batch from consuming mobile data or continuing
      // indefinitely once its page is no longer in the foreground.
      if (_busy) {
        _cancel = true;
        _resumeAfterCurrentRun = false;
        setState(() => _message = '正在暂停；等待当前系统或网络请求结束…');
        _cancelActivePrepare();
      }
    }
  }

  Future<void> _cancelPrepare(String requestId) async {
    try {
      await _photosChannel.invokeMethod<bool>('cancelPrepare', {
        'requestId': requestId,
      });
    } catch (_) {
      // The native prepare still owns temp-file cleanup if cancellation wins
      // before it returns a path. A late successful result is released below.
    }
  }

  void _cancelActivePrepare() {
    final requestId = _activePrepareRequestId;
    if (requestId == null || _cancelledPrepareRequestId == requestId) return;
    _cancelledPrepareRequestId = requestId;
    unawaited(_cancelPrepare(requestId));
  }

  String _newPrepareRequestId() =>
      '$_deviceId-${DateTime.now().microsecondsSinceEpoch}-${_prepareSequence++}';

  Future<void> _saveOptions() async {
    await _prefs?.setBool('$_scope.onForeground', _onForeground);
    await _prefs?.setBool('$_scope.wifiOnly', _wifiOnly);
  }

  void _ensureActive() {
    if (_cancel || !mounted || !_isForeground) {
      throw const _PausePhotoBackup();
    }
  }

  Future<bool> _permission({bool checkForegroundRun = false}) async {
    final granted = await _photosChannel.invokeMethod<bool>('permission');
    if (checkForegroundRun) _ensureActive();
    if (granted == true) {
      return true;
    }
    final requested = await _photosChannel.invokeMethod<bool>(
      'requestPermission',
    );
    if (checkForegroundRun) _ensureActive();
    return requested == true;
  }

  String _extension(String name) {
    final lower = name.toLowerCase();
    final index = lower.lastIndexOf('.');
    final ext = index >= 0 ? lower.substring(index + 1) : '';
    return {
          'jpg',
          'jpeg',
          'png',
          'heic',
          'heif',
          'webp',
          'avif',
          'gif',
          'tiff',
          'bmp',
        }.contains(ext)
        ? ext
        : 'jpg';
  }

  Future<void> _ensureFolder(String path) async {
    _ensureActive();
    try {
      // Existing delegated folders may be writable for members even when
      // they cannot CREATE a directory in the parent root.
      await widget.api.get('/api/v1/files', query: {'path': path});
      _ensureActive();
      return;
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 403) rethrow;
      _ensureActive();
    }
    _ensureActive();
    try {
      await widget.api.send(
        'POST',
        '/api/v1/files/folders',
        body: {'path': path},
      );
      _ensureActive();
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 409) rethrow;
      _ensureActive();
    }
  }

  Future<Map<String, dynamic>?> _existingUpload(
    String key,
    int size,
    String destination,
  ) async {
    _ensureActive();
    final id = _prefs?.getString(key);
    if (id == null || id.isEmpty) return null;
    try {
      final state = await widget.api.get(
        '/api/v1/uploads/${Uri.encodeComponent(id)}',
      );
      _ensureActive();
      final offset = (state['offset'] as num?)?.toInt() ?? -1;
      if (state['path'] == destination &&
          state['size'] == size &&
          offset >= 0 &&
          offset <= size) {
        return state;
      }
    } on LightIsleApiException catch (e) {
      if (e.statusCode != 404) rethrow;
      _ensureActive();
    }
    _ensureActive();
    await _prefs?.remove(key);
    _ensureActive();
    return null;
  }

  Future<void> _upload(
    File source,
    int size,
    String destination,
    String key,
    String digest,
  ) async {
    _ensureActive();
    var state = await _existingUpload(key, size, destination);
    _ensureActive();
    if (state == null) {
      _ensureActive();
      state = await widget.api.send(
        'POST',
        '/api/v1/uploads',
        body: {'path': destination, 'size': size},
      );
    }
    final id = state['id']?.toString() ?? '';
    if (id.isEmpty || state['path'] != destination || state['size'] != size) {
      throw StateError('服务端上传会话与备份照片不一致。');
    }
    await _prefs?.setString(key, id);
    _ensureActive();
    var offset = (state['offset'] as num?)?.toInt() ?? -1;
    if (offset < 0 || offset > size) throw StateError('无效的续传偏移量。');
    while (offset < size) {
      _ensureActive();
      if (_wifiOnly) {
        final isWifi = await _photosChannel.invokeMethod<bool>('isWifi');
        _ensureActive();
        if (isWifi != true) throw StateError('Wi-Fi 已断开，当前上传已暂停。');
      }
      final length = min(4 * 1024 * 1024, size - offset);
      try {
        state = await widget.api.uploadChunk(
          id,
          source.openRead(offset, offset + length),
          length,
          offset,
        );
        _ensureActive();
      } catch (_) {
        _ensureActive();
        // Response loss is not proof the chunk failed. Use authoritative
        // server offset before ever replaying bytes.
        final latest = await widget.api.get(
          '/api/v1/uploads/${Uri.encodeComponent(id)}',
        );
        _ensureActive();
        final next = (latest['offset'] as num?)?.toInt() ?? -1;
        if (latest['path'] != destination ||
            latest['size'] != size ||
            next <= offset ||
            next > size) {
          rethrow;
        }
        state = latest;
      }
      final next = (state['offset'] as num?)?.toInt() ?? -1;
      if (next <= offset || next > size) throw StateError('上传进度未前进，备份已暂停。');
      offset = next;
    }
    _ensureActive();
    await widget.api.send(
      'POST',
      '/api/v1/uploads/${Uri.encodeComponent(id)}/complete',
    );
    _ensureActive();
    // Rehash the original bytes independently on NAS. Size and a success
    // response alone cannot establish actual content integrity.
    final matches = await widget.api.remoteFileMatchesSHA256(
      destination,
      size,
      digest,
    );
    _ensureActive();
    if (!matches) {
      throw StateError('NAS 原片 SHA-256 与手机不一致，不能标记备份成功。');
    }
    await _prefs?.remove(key);
    _ensureActive();
  }

  Future<void> _run({bool older = false}) async {
    if (_busy || _prefs == null || _deviceId.isEmpty || !mounted) return;
    final preferences = _prefs!;
    setState(() {
      _busy = true;
      _cancel = false;
      _checked = 0;
      _uploaded = 0;
      _skipped = 0;
      _nextCursor = '';
      _message = '正在核对权限与连接…';
    });
    try {
      _ensureActive();
      if (!(widget.androidPlatformOverride ?? Platform.isAndroid)) {
        throw StateError('仅支持 Android 手机。');
      }
      if (!await _permission(checkForegroundRun: true)) {
        throw StateError('需要在 Android 系统设置中授权访问所有照片；仅选定照片的权限不足以进行完整备份。');
      }
      _ensureActive();
      if (!older) {
        _pageCursor = '';
        await preferences.remove('$_scope.cursor');
        _ensureActive();
      }
      const base = 'PhonePhotos';
      final destinationDir = '$base/$_deviceId';
      var dirsReady = false;
      var complete = false;
      var pages = 0;
      // Cap work per activation so a huge camera roll doesn't monopolize
      // battery or network. Persist only the last successfully scanned page
      // boundary; after interruption, retry the incomplete page safely.
      while (pages < 10 && !_cancel && mounted) {
        _ensureActive();
        if (_wifiOnly) {
          final isWifi = await _photosChannel.invokeMethod<bool>('isWifi');
          _ensureActive();
          if (isWifi != true) {
            throw StateError('当前不在 Wi-Fi 网络下，按你的设置已暂停备份。');
          }
        }
        final before = _pageCursor;
        final response = await _photosChannel.invokeMapMethod<String, dynamic>(
          'list',
          {'beforeId': before.isEmpty ? null : before, 'limit': 40},
        );
        _ensureActive();
        final rows = (response?['items'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((row) => row.cast<String, dynamic>())
            .toList();
        final storeVersion = response?['version']?.toString() ?? '';
        final storeVersionID = storeVersion.isNotEmpty
            ? sha256
                  .convert(utf8.encode(storeVersion))
                  .toString()
                  .substring(0, 16)
            : '';
        final following = response?['nextCursor']?.toString() ?? '';
        if (following.isNotEmpty &&
            (!RegExp(r'^[0-9]{1,20}$').hasMatch(following) ||
                following == before)) {
          throw StateError('手机照片分页结果异常，未保存本页进度。');
        }
        if (rows.isNotEmpty && !dirsReady) {
          try {
            // A member may have access to the final device folder but not
            // to its parent. Reuse that authorization when it already exists.
            await widget.api.get(
              '/api/v1/files',
              query: {'path': destinationDir},
            );
            _ensureActive();
          } on LightIsleApiException catch (e) {
            if (e.statusCode != 404 && e.statusCode != 403) rethrow;
            _ensureActive();
            await _ensureFolder(base);
            _ensureActive();
            await _ensureFolder(destinationDir);
            _ensureActive();
          }
          dirsReady = true;
        }
        for (final entry in rows) {
          _ensureActive();
          final id = entry['id']?.toString() ?? '';
          final modified = (entry['modified'] as num?)?.toInt() ?? 0;
          final listedSize = (entry['size'] as num?)?.toInt() ?? -1;
          final generation = (entry['generation'] as num?)?.toInt() ?? 0;
          if (!RegExp(r'^[0-9]{1,20}$').hasMatch(id) || listedSize <= 0) {
            continue;
          }
          _checked++;
          if (mounted) {
            setState(() => _message = '正在检查第 $_checked 张照片（第 ${pages + 1} 页）…');
          }
          final suffix = _extension(entry['name']?.toString() ?? '');
          final successKey =
              '$_scope.sent.$id.$modified.$listedSize.$generation.$storeVersionID';
          final previousDigest = preferences.getString(successKey);
          // The fast path must not read/copy/hash hundreds of photos just
          // to decide they were already backed up. Android's MediaStore
          // identity+mtime+size and our original SHA marker are checked
          // against an authenticated remote size probe. New/changed photos
          // still get a full SHA-256 before their upload path is allocated.
          if (generation > 0 &&
              storeVersionID.isNotEmpty &&
              previousDigest != null &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(previousDigest)) {
            final existing =
                '$destinationDir/photo_${id}_${modified}_${previousDigest.substring(0, 16)}.$suffix';
            final cachedMatch = await widget.api.remoteFileMatchesSHA256(
              existing,
              listedSize,
              previousDigest,
            );
            _ensureActive();
            if (cachedMatch) {
              _skipped++;
              continue;
            }
            _ensureActive();
            await preferences.remove(successKey);
            _ensureActive();
          }
          String? temporary;
          try {
            _ensureActive();
            final requestId = _newPrepareRequestId();
            _activePrepareRequestId = requestId;
            _cancelledPrepareRequestId = null;
            Map<String, dynamic>? prepared;
            try {
              prepared = await _photosChannel.invokeMapMethod<String, dynamic>(
                'prepare',
                {'id': id, 'requestId': requestId},
              );
            } finally {
              if (_activePrepareRequestId == requestId) {
                _activePrepareRequestId = null;
              }
              if (_cancelledPrepareRequestId == requestId) {
                _cancelledPrepareRequestId = null;
              }
            }
            temporary = prepared?['path']?.toString();
            _ensureActive();
            if (temporary == null ||
                temporary.isEmpty ||
                prepared?['size'] != listedSize) {
              throw StateError('手机照片在读取期间发生变化，请稍后重试。');
            }
            final file = File(temporary);
            final digest =
                (await sha256
                        .bind(
                          file.openRead().map((chunk) {
                            _ensureActive();
                            return chunk;
                          }),
                        )
                        .first)
                    .toString();
            _ensureActive();
            final destination =
                '$destinationDir/photo_${id}_${modified}_${digest.substring(0, 16)}.$suffix';
            final uploadKey = '$_scope.upload.$id.$modified.$digest';
            // The remote name embeds SHA-256 of the just-read bytes. A prior
            // successful write may have been committed before the response
            // was lost, or MediaStore's generation may have changed without
            // changing the photo bytes. Check before allocating a new upload.
            final alreadyPresent = await widget.api.remoteFileMatchesSHA256(
              destination,
              listedSize,
              digest,
            );
            _ensureActive();
            if (alreadyPresent) {
              await preferences.setString(successKey, digest);
              _ensureActive();
              await preferences.remove(uploadKey);
              _ensureActive();
              _skipped++;
              continue;
            }
            _ensureActive();
            // Distinguish a missing backup from a same-sized, corrupted or
            // manually replaced NAS file. Never allocate a new upload that
            // could overwrite an existing different original.
            final sameSizeExists = await widget.api.remoteFileHasSize(
              destination,
              listedSize,
            );
            _ensureActive();
            if (sameSizeExists) {
              throw StateError('NAS 目标文件已存在但 SHA-256 与手机不一致；请先人工核对，不能自动覆盖。');
            }
            _ensureActive();
            await _upload(file, listedSize, destination, uploadKey, digest);
            _ensureActive();
            await preferences.setString(successKey, digest);
            _ensureActive();
            _uploaded++;
          } finally {
            if (temporary != null) {
              try {
                await _photosChannel.invokeMethod<bool>('release', {
                  'path': temporary,
                });
              } catch (_) {
                // Only files under our private Android cache are releasable.
              }
            }
          }
        }
        _ensureActive();
        pages++;
        if (following.isEmpty) {
          await preferences.remove('$_scope.cursor');
          _ensureActive();
          _pageCursor = '';
          _nextCursor = '';
          complete = true;
          break;
        }
        _pageCursor = following;
        _nextCursor = following;
        await preferences.setString('$_scope.cursor', following);
        _ensureActive();
      }
      _ensureActive();
      setState(
        () => _message =
            '本轮完成：新增 $_uploaded 张，已备份跳过 $_skipped 张。'
            '${complete ? " 已检查至相册末尾。" : " 已保存进度，可继续备份更早的照片。"}',
      );
    } on _PausePhotoBackup {
      if (mounted) {
        setState(() => _message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。');
      }
    } catch (error) {
      if (_cancel || !mounted) {
        if (mounted) {
          setState(() => _message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。');
        }
        return;
      }
      if (mounted) {
        setState(() => _message = '备份中断：$error。未删除手机原片或已完成的远端备份。');
      }
    } finally {
      final resume =
          mounted && _resumeAfterCurrentRun && _isForeground && _onForeground;
      _resumeAfterCurrentRun = false;
      if (mounted) setState(() => _busy = false);
      if (resume) {
        unawaited(
          Future<void>.microtask(() {
            if (mounted && _isForeground && _onForeground && !_busy) {
              return _run(older: _pageCursor.isNotEmpty);
            }
          }),
        );
      }
    }
  }

  @override
  void dispose() {
    _cancel = true;
    _cancelActivePrepare();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Android 照片增量备份')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const IsleSurface(
          child: Text(
            '可手动前台备份，或另外明确开启系统 WorkManager 后台备份。'
            '首次备份需要完整照片权限。前台每批最多 400 张，后台单轮最多 30 张且超过 100 MiB 的单张照片仍需前台处理。'
            '原片不删除，备份存入 PhonePhotos/设备目录，并以两端 SHA-256 完整哈希验证。',
          ),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          title: const Text('进入此页面或返回前台时自动检查'),
          subtitle: const Text('只在 App 前台自动启动；不是 Android 系统后台定时任务。'),
          value: _onForeground,
          onChanged: _busy
              ? null
              : (value) {
                  setState(() => _onForeground = value);
                  unawaited(_saveOptions());
                },
        ),
        SwitchListTile(
          title: const Text('仅 Wi-Fi 备份'),
          value: _wifiOnly,
          onChanged: _busy
              ? null
              : (value) {
                  setState(() => _wifiOnly = value);
                  unawaited(_saveOptions());
                },
        ),
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
        Text(
          '系统任务：$_backgroundWorkLabel',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          '最近进度或结果：$_backgroundResult',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_backgroundActionMessage != null)
          Text(
            _backgroundActionMessage!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (_backgroundEnabled && !_backgroundSessionMatches)
          Text(
            '当前登录会话与后台备份授权不一致；如需继续，请关闭后重新开启后台备份。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 10),
        if (_busy) const LinearProgressIndicator(),
        Text(_message, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 10),
        if (_checked > 0) Text('已检查 $_checked · 新增 $_uploaded · 跳过 $_skipped'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.backup_rounded),
              label: Text(_pageCursor.isEmpty ? '检查并备份最近照片' : '继续上次备份进度'),
              onPressed: _busy
                  ? null
                  : () => unawaited(_run(older: _pageCursor.isNotEmpty)),
            ),
            if (_backgroundEnabled && _backgroundSessionMatches)
              OutlinedButton.icon(
                icon: const Icon(Icons.sync_rounded),
                label: const Text('立即检查后台备份'),
                onPressed: _busy || _backgroundBusy
                    ? null
                    : () => unawaited(_requestBackgroundCheck()),
              ),
            if (!_busy && _pageCursor.isNotEmpty)
              OutlinedButton(
                onPressed: () => unawaited(_run()),
                child: const Text('从最新照片重新检查'),
              ),
            if (!_busy && _nextCursor.isNotEmpty)
              OutlinedButton(
                onPressed: () {
                  _pageCursor = _nextCursor;
                  unawaited(_run(older: true));
                },
                child: const Text('继续更早的照片'),
              ),
            if (_busy)
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _cancel = true;
                    _resumeAfterCurrentRun = false;
                    _message = '正在暂停；等待当前系统或网络请求结束…';
                  });
                  _cancelActivePrepare();
                },
                child: const Text('暂停'),
              ),
          ],
        ),
      ],
    ),
  );
}

class _PausePhotoBackup implements Exception {
  const _PausePhotoBackup();
}
