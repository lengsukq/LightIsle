part of 'android_photo_backup_page.dart';

extension _AndroidPhotoBackupRun on _AndroidPhotoBackupState {
  Future<void> _run({bool older = false}) async {
    if (_busy || _prefs == null || _deviceId.isEmpty || !mounted) return;
    final preferences = _prefs!;
    _updateState(() {
      _busy = true;
      _cancel = false;
      _checked = 0;
      _uploaded = 0;
      _skipped = 0;
      _failed = 0;
      _omittedFailures = 0;
      _oversizedSkipped = 0;
      _nextCursor = '';
      _message = '正在核对权限与连接…';
    });
    try {
      _ensureActive();
      if (!_isAndroid && !_isIOS) {
        throw StateError('照片备份只支持 Android 或 iOS 手机。');
      }
      if (!await _permission(checkForegroundRun: true)) {
        throw StateError(
          _isAndroid
              ? '需要在 Android 系统设置中授权访问所有照片；仅选定照片的权限不足以进行完整备份。'
              : '需要在 iOS 系统设置中授权访问所有照片；有限照片访问不足以进行完整备份。',
        );
      }
      _ensureActive();
      if (!older) {
        _pageCursor = '';
        await preferences.remove('$_scope.cursor');
        _ensureActive();
      }
      final base = widget.baseDirectory;
      final destinationDir = '$base/$_deviceId';
      var dirsReady = false;
      var complete = false;
      var pages = 0;
      var restartedAfterLibraryChange = false;
      var failureStateInitialized = false;
      // Cap work per activation so a huge camera roll doesn't monopolize
      // battery or network. Persist only the last successfully scanned page
      // boundary; after interruption, retry the incomplete page safely.
      while (pages < _batchPages && !_cancel && mounted) {
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
          {
            'beforeId': before.isEmpty ? null : before,
            'limit': 40,
            'includeVideos': _includeVideos,
          },
        );
        _ensureActive();
        final rows = (response?['items'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((row) => row.cast<String, dynamic>())
            .toList();
        final storeVersion = response?['version']?.toString() ?? '';
        final oversizedCount =
            (response?['oversizedCount'] as num?)?.toInt() ?? 0;
        final storeVersionID = storeVersion.isNotEmpty
            ? sha256
                  .convert(utf8.encode(storeVersion))
                  .toString()
                  .substring(0, 16)
            : '';
        if (_isIOS && before.isNotEmpty) {
          final previousVersion = preferences.getString('$_scope.storeVersion');
          if (previousVersion != null && previousVersion != storeVersionID) {
            if (restartedAfterLibraryChange) {
              throw StateError('相册持续变化，请稍后从最新照片重新检查。');
            }
            restartedAfterLibraryChange = true;
            _pageCursor = '';
            _nextCursor = '';
            await preferences.remove('$_scope.cursor');
            await preferences.setString('$_scope.storeVersion', storeVersionID);
            _ensureActive();
            failureStateInitialized = false;
            pages = 0;
            continue;
          }
        }
        final failureStorageKey = _photoFailureStorageKey();
        if (!failureStateInitialized) {
          final previousFailureVersion = preferences.getString(
            '$failureStorageKey.version',
          );
          final resetFailureSet =
              !older || previousFailureVersion != storeVersionID;
          final failureCounts = resetFailureSet
              ? await _resetPhotoFailures(
                  preferences,
                  failureStorageKey,
                  storeVersionID,
                )
              : await _photoFailureCounts(preferences, failureStorageKey);
          _failed = failureCounts.total;
          _omittedFailures = failureCounts.omitted;
          failureStateInitialized = true;
          _ensureActive();
        }
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
              _photoApi('files'),
              query: _photoQuery({'path': destinationDir}),
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
        var pageHadFailures = false;
        for (final entry in rows) {
          _ensureActive();
          final id = entry['id']?.toString() ?? '';
          final modified = (entry['modified'] as num?)?.toInt() ?? 0;
          final listedSize = (entry['size'] as num?)?.toInt() ?? -1;
          final generation = (entry['generation'] as num?)?.toInt() ?? 0;
          final validID = _isIOS
              ? RegExp(r'^(?:[lv][.])?[A-Za-z0-9_-]{1,200}$').hasMatch(id)
              : RegExp(r'^[0-9]{1,20}$').hasMatch(id);
          if (!validID || (!_isIOS && listedSize <= 0)) {
            continue;
          }
          final safeID = _isIOS
              ? sha256.convert(utf8.encode(id)).toString().substring(0, 24)
              : id;
          _checked++;
          if (mounted) {
            _updateState(
              () => _message = '正在检查第 $_checked 张照片（第 ${pages + 1} 页）…',
            );
          }
          final suffix = _extension(entry['name']?.toString() ?? '');
          final successKey =
              '$_scope.sent.$id.$modified.$listedSize.$generation.$storeVersionID';
          final failureAssetKey = _photoFailureAssetKey(
            id,
            modified,
            listedSize,
            generation,
            storeVersionID,
          );
          final previousDigest = preferences.getString(successKey);
          // The fast path checks the stored NAS bytes against the recorded
          // full digest. Large files go through prepare so their recorded
          // local digest can be compared chunk by chunk with the NAS object.
          if (generation > 0 &&
              storeVersionID.isNotEmpty &&
              listedSize <= (2 << 30) &&
              previousDigest != null &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(previousDigest)) {
            final existing =
                '$destinationDir/photo_${id}_${modified}_${previousDigest.substring(0, 16)}.$suffix';
            final cachedMatch = await widget.api.remoteFileMatchesSHA256(
              existing,
              listedSize,
              previousDigest,
              checkActive: _ensureActive,
            );
            _ensureActive();
            if (cachedMatch) {
              final failureCounts = await _clearPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
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
                {
                  'id': id,
                  'requestId': requestId,
                  'includeVideos': _includeVideos,
                },
              );
            } on PlatformException catch (error) {
              _ensureActive();
              if (!_isRecoverablePhotoPrepareError(error.code)) rethrow;
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                'source_unavailable',
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
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
            final exactSize = (prepared?['size'] as num?)?.toInt() ?? -1;
            if (temporary == null ||
                temporary.isEmpty ||
                exactSize <= 0 ||
                exactSize > _maxPhotoBackupBytes ||
                (!_isIOS && exactSize != listedSize)) {
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                'source_changed',
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
            }
            final file = File(temporary);
            final PhotoHashResult localHash;
            try {
              localHash = await _hashPreparedPhoto(file, exactSize);
            } on PhotoSourceChanged {
              _ensureActive();
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                'source_unreadable',
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
            } on FileSystemException {
              _ensureActive();
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                'source_unreadable',
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
            }
            _ensureActive();
            final digest = localHash.digest;
            final destination =
                '$destinationDir/photo_${safeID}_${modified}_${digest.substring(0, 16)}.$suffix';
            final uploadKey = '$_scope.upload.$id.$modified.$digest';
            // The remote name embeds SHA-256 of the just-read bytes. A prior
            // successful write may have been committed before the response
            // was lost, or MediaStore's generation may have changed without
            // changing the photo bytes. Check before allocating a new upload.
            final alreadyPresent = await widget.api.remoteFileMatchesSHA256(
              destination,
              exactSize,
              digest,
              chunkSHA256s: localHash.chunkDigests,
              checkActive: _ensureActive,
            );
            _ensureActive();
            if (alreadyPresent) {
              await preferences.setString(successKey, digest);
              _ensureActive();
              await preferences.remove(uploadKey);
              _ensureActive();
              final failureCounts = await _clearPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              _skipped++;
              continue;
            }
            _ensureActive();
            // Distinguish a missing backup from a same-sized, corrupted or
            // manually replaced NAS file. Never allocate a new upload that
            // could overwrite an existing different original.
            final sameSizeExists = await widget.api.remoteFileHasSize(
              destination,
              exactSize,
            );
            _ensureActive();
            if (sameSizeExists) {
              throw StateError('NAS 目标文件已存在但 SHA-256 与手机不一致；请先人工核对，不能自动覆盖。');
            }
            _ensureActive();
            await _upload(
              file,
              exactSize,
              destination,
              uploadKey,
              digest,
              localHash.chunkDigests,
            );
            _ensureActive();
            await preferences.setString(successKey, digest);
            _ensureActive();
            final failureCounts = await _clearPhotoFailure(
              preferences,
              failureStorageKey,
              failureAssetKey,
            );
            _failed = failureCounts.total;
            _omittedFailures = failureCounts.omitted;
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
        // This omission must be visible; it is not a successful backup.
        _oversizedSkipped += oversizedCount.clamp(0, 10000);
        // Only advance the last verified timestamp after the whole page
        // succeeded. Never claim an incomplete or interrupted page succeeded.
        if (!pageHadFailures) {
          _lastVerifiedAt = DateTime.now().millisecondsSinceEpoch;
          await preferences.setInt('$_scope.lastVerifiedAt', _lastVerifiedAt);
        }
        if (following.isEmpty) {
          await preferences.remove('$_scope.cursor');
          _ensureActive();
          _pageCursor = '';
          _nextCursor = '';
          complete = true;
          final failureCounts = await _photoFailureCounts(
            preferences,
            failureStorageKey,
          );
          _failed = failureCounts.total;
          _omittedFailures = failureCounts.omitted;
          if (failureCounts.total == 0) {
            _lastCompleteAt = _lastVerifiedAt;
            await preferences.setInt('$_scope.lastCompleteAt', _lastCompleteAt);
          }
          break;
        }
        _pageCursor = following;
        _nextCursor = following;
        await preferences.setString('$_scope.cursor', following);
        if (_isIOS) {
          await preferences.setString('$_scope.storeVersion', storeVersionID);
        }
        _ensureActive();
      }
      _ensureActive();
      _updateState(
        () => _message =
            '本轮结束：新增 $_uploaded ${_includeVideos ? "项" : "张"}，已备份跳过 $_skipped ${_includeVideos ? "项" : "张"}。'
            '${complete && _failed == 0
                ? " 已检查至相册末尾。"
                : complete
                ? " 已扫描至相册末尾，但 $_failed 项读取失败，已登记待重试，未标记完整。"
                : " 已保存进度，可继续备份更早的照片。"}'
            '${_omittedFailures > 0 ? " 其中 $_omittedFailures 项超过本机 512 条失败记录上限，完整状态会保持未完成；从最新照片重新检查可重试。" : ""}'
            '${_oversizedSkipped > 0 ? " 另有 $_oversizedSkipped 项超过安卓 2 GiB 暂存上限，尚未备份；请通过文件管理器单独上传。" : ""}',
      );
    } on _PausePhotoBackup {
      if (mounted) {
        _updateState(
          () => _message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。',
        );
      }
    } catch (error) {
      if (_cancel || !mounted) {
        if (mounted) {
          _updateState(
            () => _message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。',
          );
        }
        return;
      }
      if (mounted) {
        _updateState(() => _message = '备份中断：$error。未删除手机原片或已完成的远端备份。');
      }
    } finally {
      final resume =
          mounted && _resumeAfterCurrentRun && _isForeground && _onForeground;
      _resumeAfterCurrentRun = false;
      if (mounted) _updateState(() => _busy = false);
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
}

class _PausePhotoBackup implements Exception {
  const _PausePhotoBackup();
}
