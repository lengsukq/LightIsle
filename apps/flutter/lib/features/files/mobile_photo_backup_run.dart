part of 'mobile_photo_backup_page.dart';

extension _MobilePhotoBackupRun on _MobilePhotoBackupState {
  ({String digest, int size})? _parseVerifiedSentRecord(
    String? raw,
    int listedSize,
  ) {
    if (raw == null || raw.isEmpty) return null;
    final withSize = RegExp(r'^([a-f0-9]{64}):([1-9][0-9]{0,14})$')
        .firstMatch(raw);
    if (withSize != null) {
      final digest = withSize.group(1)!;
      final savedSize = int.tryParse(withSize.group(2)!);
      if (savedSize == null || savedSize <= 0) return null;
      if (!_isIOS && listedSize > 0 && savedSize != listedSize) return null;
      return (digest: digest, size: savedSize);
    }
    if (RegExp(r'^[a-f0-9]{64}$').hasMatch(raw) && listedSize > 0) {
      return (digest: raw, size: listedSize);
    }
    return null;
  }

  String _formatVerifiedSentRecord(String digest, int exactSize) =>
      _isIOS ? '$digest:$exactSize' : digest;

  Future<void> _ensureTargetSubdirectory(
    String destinationDir,
    String entryDir,
    Set<String> ensuredSubdirs,
  ) async {
    if (entryDir == destinationDir || ensuredSubdirs.contains(entryDir)) return;
    final yearSlash = entryDir.lastIndexOf('/');
    if (yearSlash > destinationDir.length) {
      await _ensureFolder(entryDir.substring(0, yearSlash));
      _ensureActive();
    }
    await _ensureFolder(entryDir);
    _ensureActive();
    ensuredSubdirs.add(entryDir);
  }

  Future<void> _run({bool older = false}) async {
    if (_busy || _prefs == null || _deviceId.isEmpty || !mounted) return;
    final preferences = _prefs!;
    final statePrefix = _scopedStatePrefix;
    final cursorKey = '$statePrefix.cursor';
    final storeVersionKey = '$statePrefix.storeVersion';
    final lastVerifiedKey = '$statePrefix.lastVerifiedAt';
    final lastCompleteKey = '$statePrefix.lastCompleteAt';
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
        if (!await preferences.remove(cursorKey)) {
          throw StateError('无法重置照片分页进度，请重试。');
        }
        if (!await preferences.setBool(
          '${_photoFailureStorageKey()}.scanIncomplete',
          false,
        )) {
          throw StateError('无法保存照片检查状态，请重试。');
        }
        _ensureActive();
      }
      final scanIncompleteKey = '${_photoFailureStorageKey()}.scanIncomplete';
      _scanHasOmissions =
          older &&
          _pageCursor.isNotEmpty &&
          (preferences.getBool(scanIncompleteKey) ?? true);
      final base = widget.baseDirectory;
      final destinationDir = '$base/$_deviceId';
      final ensuredSubdirs = <String>{};
      var dirsReady = false;
      var complete = false;
      var pages = 0;
      var restartedAfterLibraryChange = false;
      var failureStateInitialized = false;

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
            'albumScope': _albumScope,
            if (_isAndroid) 'allowLargeOriginals': true,
          },
        );
        _ensureActive();
        final supportsStream =
            _isAndroid && response?['supportsStream'] == true;
        final rows = (response?['items'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((row) => row.cast<String, dynamic>())
            .toList();
        final storeVersion = response?['version']?.toString() ?? '';
        final oversizedCount =
            (response?['oversizedCount'] as num?)?.toInt() ?? 0;
        final invalidCount = (response?['invalidCount'] as num?)?.toInt() ?? 0;
        if (oversizedCount < 0 || invalidCount < 0) {
          throw StateError('手机照片检查结果无效，未保存本页进度。');
        }
        final storeVersionID = storeVersion.isNotEmpty
            ? sha256
                  .convert(utf8.encode(storeVersion))
                  .toString()
                  .substring(0, 16)
            : '';
        if (before.isNotEmpty) {
          final previousVersion = preferences.getString(storeVersionKey);
          if (previousVersion != null && previousVersion != storeVersionID) {
            if (restartedAfterLibraryChange) {
              throw StateError('相册持续变化，请稍后从最新照片重新检查。');
            }
            restartedAfterLibraryChange = true;
            _pageCursor = '';
            _nextCursor = '';
            if (!await preferences.remove(cursorKey) ||
                !await preferences.setBool(scanIncompleteKey, false)) {
              throw StateError('无法重置照片检查进度，请重试。');
            }
            _scanHasOmissions = false;
            await preferences.setString(storeVersionKey, storeVersionID);
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
        var pageHasOmissions = oversizedCount > 0 || invalidCount > 0;
        final omittedItems = (response?['omittedItems'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>());
        for (final item in omittedItems) {
          _ensureActive();
          final id = item['id']?.toString() ?? '';
          if (!RegExp(r'^[0-9]{1,20}$').hasMatch(id)) {
            pageHasOmissions = true;
            continue;
          }
          final modified = (item['modified'] as num?)?.toInt() ?? 0;
          final size = (item['size'] as num?)?.toInt() ?? 0;
          final generation = (item['generation'] as num?)?.toInt() ?? 0;
          final failureCounts = await _recordPhotoFailure(
            preferences,
            failureStorageKey,
            _photoFailureAssetKey(
              id,
              modified,
              size,
              generation,
              storeVersionID,
            ),
            item['reason'] == 'oversized' ? 'oversized' : 'source_unavailable',
            name: item['name']?.toString() ?? '',
            assetId: id,
          );
          _failed = failureCounts.total;
          _omittedFailures = failureCounts.omitted;
          pageHasOmissions = true;
          _ensureActive();
        }

        for (final entry in rows) {
          _ensureActive();
          final id = entry['id']?.toString() ?? '';
          final modified = (entry['modified'] as num?)?.toInt() ?? 0;
          final listedSize = (entry['size'] as num?)?.toInt() ?? -1;
          final generation = (entry['generation'] as num?)?.toInt() ?? 0;
          final validID = _isIOS
              ? RegExp(r'^(?:[lvr][.])?[A-Za-z0-9_-]{1,200}$').hasMatch(id)
              : RegExp(r'^[0-9]{1,20}$').hasMatch(id);
          if (!validID || (!_isIOS && listedSize <= 0)) {
            pageHasOmissions = true;
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
          final entryDir = _targetDirectoryForEntry(destinationDir, modified);
          final successKey =
              '$_scope.sent.$id.$modified.$listedSize.$generation.$storeVersionID';
          final failureAssetKey = _photoFailureAssetKey(
            id,
            modified,
            listedSize,
            generation,
            storeVersionID,
          );
          final verifiedRecord = _parseVerifiedSentRecord(
            preferences.getString(successKey),
            listedSize,
          );
          if (generation > 0 &&
              storeVersionID.isNotEmpty &&
              verifiedRecord != null &&
              verifiedRecord.size <= (2 << 30)) {
            final existing =
                '$entryDir/photo_${safeID}_${modified}_${verifiedRecord.digest.substring(0, 16)}.$suffix';
            final cachedMatch = await widget.api.remoteFileMatchesSHA256(
              existing,
              verifiedRecord.size,
              verifiedRecord.digest,
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

          if (supportsStream) {
            _NativeStreamInspection inspection;
            try {
              inspection = await _inspectAndroidStreamAsset(id);
            } on PlatformException catch (error) {
              _ensureActive();
              if (!_isRecoverablePhotoPrepareError(error.code)) rethrow;
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                _failureReasonForCode(error.code),
                name: entry['name']?.toString() ?? '',
                assetId: id,
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
            }
            if (inspection.size != listedSize ||
                inspection.modified != modified ||
                inspection.generation != generation) {
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                'source_changed',
                name: entry['name']?.toString() ?? '',
                assetId: id,
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
            }
            await _ensureTargetSubdirectory(
              destinationDir,
              entryDir,
              ensuredSubdirs,
            );
            final digest = inspection.digest;
            final destination =
                '$entryDir/photo_${safeID}_${modified}_${digest.substring(0, 16)}.$suffix';
            final uploadKey = '$_scope.upload.$id.$modified.$digest';
            final alreadyPresent = await widget.api.remoteFileMatchesSHA256(
              destination,
              inspection.size,
              digest,
              chunkSHA256s: inspection.chunkDigests,
              checkActive: _ensureActive,
            );
            _ensureActive();
            if (alreadyPresent) {
              await preferences.setString(
                successKey,
                _formatVerifiedSentRecord(digest, inspection.size),
              );
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
            final sameSizeExists = await widget.api.remoteFileHasSize(
              destination,
              inspection.size,
            );
            _ensureActive();
            if (sameSizeExists) {
              throw StateError('NAS 目标文件已存在但 SHA-256 与手机不一致；请先人工核对，不能自动覆盖。');
            }
            _ensureActive();
            try {
              await _uploadFromChunkProvider(
                size: inspection.size,
                destination: destination,
                key: uploadKey,
                digest: digest,
                chunkSHA256s: inspection.chunkDigests,
                openChunk: (offset, length) async {
                  final bytes = await _readAndroidStreamChunk(
                    id: id,
                    offset: offset,
                    length: length,
                    inspection: inspection,
                  );
                  return Stream<List<int>>.value(bytes);
                },
              );
            } on PlatformException catch (error) {
              _ensureActive();
              if (error.code != 'photo_source_changed') rethrow;
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                'source_changed',
                name: entry['name']?.toString() ?? '',
                assetId: id,
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
            }
            _ensureActive();
            await preferences.setString(
              successKey,
              _formatVerifiedSentRecord(digest, inspection.size),
            );
            _ensureActive();
            final failureCounts = await _clearPhotoFailure(
              preferences,
              failureStorageKey,
              failureAssetKey,
            );
            _failed = failureCounts.total;
            _omittedFailures = failureCounts.omitted;
            _uploaded++;
            continue;
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
                  if (_isIOS) 'allowICloudDownload': _allowICloudDownload,
                },
              );
            } on PlatformException catch (error) {
              _ensureActive();
              if (!_isRecoverablePhotoPrepareError(error.code)) rethrow;
              final failureCounts = await _recordPhotoFailure(
                preferences,
                failureStorageKey,
                failureAssetKey,
                _failureReasonForCode(error.code),
                name: entry['name']?.toString() ?? '',
                assetId: id,
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
                name: entry['name']?.toString() ?? '',
                assetId: id,
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
                name: entry['name']?.toString() ?? '',
                assetId: id,
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
                name: entry['name']?.toString() ?? '',
                assetId: id,
              );
              _failed = failureCounts.total;
              _omittedFailures = failureCounts.omitted;
              pageHadFailures = true;
              continue;
            }
            _ensureActive();
            await _ensureTargetSubdirectory(
              destinationDir,
              entryDir,
              ensuredSubdirs,
            );
            final digest = localHash.digest;
            final destination =
                '$entryDir/photo_${safeID}_${modified}_${digest.substring(0, 16)}.$suffix';
            final uploadKey = '$_scope.upload.$id.$modified.$digest';
            final alreadyPresent = await widget.api.remoteFileMatchesSHA256(
              destination,
              exactSize,
              digest,
              chunkSHA256s: localHash.chunkDigests,
              checkActive: _ensureActive,
            );
            _ensureActive();
            if (alreadyPresent) {
              await preferences.setString(
                successKey,
                _formatVerifiedSentRecord(digest, exactSize),
              );
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
            await preferences.setString(
              successKey,
              _formatVerifiedSentRecord(digest, exactSize),
            );
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
              } catch (_) {}
            }
          }
        }

        _ensureActive();
        if (pageHasOmissions) {
          if (!await preferences.setBool(scanIncompleteKey, true)) {
            throw StateError('无法保存未备份项目状态，未推进照片分页进度。');
          }
          _scanHasOmissions = true;
        }
        pages++;
        _oversizedSkipped += oversizedCount.clamp(0, 10000);
        if (!pageHadFailures && !pageHasOmissions) {
          _lastVerifiedAt = DateTime.now().millisecondsSinceEpoch;
          await preferences.setInt(lastVerifiedKey, _lastVerifiedAt);
        }
        if (following.isEmpty) {
          if (!await preferences.remove(cursorKey)) {
            throw StateError('无法完成照片分页记录，请重新检查。');
          }
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
          if (failureCounts.total == 0 && !_scanHasOmissions) {
            _lastCompleteAt = _lastVerifiedAt;
            await preferences.setInt(lastCompleteKey, _lastCompleteAt);
          }
          break;
        }
        if (!await preferences.setString(storeVersionKey, storeVersionID)) {
          throw StateError('无法保存手机相册版本，请重新检查。');
        }
        if (!await preferences.setString(cursorKey, following)) {
          throw StateError('无法保存照片分页进度，请重新检查。');
        }
        _pageCursor = following;
        _nextCursor = following;
        _ensureActive();
      }
      _ensureActive();
      _updateState(
        () => _message =
            '本轮结束：新增 $_uploaded ${_includeVideos ? "项" : "张"}，已备份跳过 $_skipped ${_includeVideos ? "项" : "张"}。'
            '${complete && _failed == 0 && !_scanHasOmissions
                ? " 已检查至相册末尾。"
                : complete && _failed > 0
                ? " 已扫描至相册末尾，但 $_failed 项原片尚未备份，已登记待处理，未标记完整。"
                : complete
                ? " 已扫描至相册末尾，但有照片或视频未能备份，未标记完整。"
                : " 已保存进度，可继续备份更早的照片。"}'
            '${_scanHasOmissions && _oversizedSkipped == 0 ? " 本轮或之前的批次存在无法识别或超出限制的项目，请从最新照片重新检查并在手机上核对。" : ""}'
            '${_omittedFailures > 0 ? " 其中 $_omittedFailures 项超过本机 512 条失败记录上限，完整状态会保持未完成；从最新照片重新检查可重试。" : ""}'
            '${_oversizedSkipped > 0 ? " 本批有 $_oversizedSkipped 项超过备份单文件大小限制，尚未备份；请通过文件管理器单独上传。" : ""}',
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
        _updateState(
          () => _message = '备份中断：${userFacingError(error)}。未删除手机原片或已完成的远端备份。',
        );
      }
    } finally {
      if (mounted) {
        try {
          _failureDetails = _readPhotoFailures(
            preferences,
            _photoFailureStorageKey(),
          );
        } catch (_) {
          _failureDetails = [];
        }
      }
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
