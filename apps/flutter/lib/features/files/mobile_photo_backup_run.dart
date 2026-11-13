part of 'mobile_photo_backup_page.dart';

extension _MobilePhotoBackupRun on _MobilePhotoBackupState {
  Future<_EntryBackupOutcome> _verifyAndUploadHashedAsset({
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String failureAssetKey,
    required String successKey,
    required String destinationDir,
    required String entryDir,
    required Set<String> ensuredSubdirs,
    required String safeID,
    required String rawID,
    required int modified,
    required String suffix,
    required int exactSize,
    required String digest,
    required List<String> chunkDigests,
    required Future<void> Function(String destination, String uploadKey)
    performUpload,
  }) async {
    await _ensureTargetSubdirectory(destinationDir, entryDir, ensuredSubdirs);
    final destination =
        '$entryDir/photo_${safeID}_${modified}_${digest.substring(0, 16)}.$suffix';
    final uploadKey = '$_scope.upload.$rawID.$modified.$digest';
    final alreadyPresent = await widget.api.remoteFileMatchesSHA256(
      destination,
      exactSize,
      digest,
      chunkSHA256s: chunkDigests,
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
      await _clearEntryFailure(preferences, failureStorageKey, failureAssetKey);
      _progress.skipped++;
      return _EntryBackupOutcome.skipped;
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
    await performUpload(destination, uploadKey);
    _ensureActive();
    await preferences.setString(
      successKey,
      _formatVerifiedSentRecord(digest, exactSize),
    );
    _ensureActive();
    await _clearEntryFailure(preferences, failureStorageKey, failureAssetKey);
    _progress.uploaded++;
    return _EntryBackupOutcome.uploaded;
  }

  Future<_EntryBackupOutcome> _backupAndroidStreamEntry({
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String failureAssetKey,
    required String successKey,
    required String destinationDir,
    required String entryDir,
    required Set<String> ensuredSubdirs,
    required String id,
    required String safeID,
    required String name,
    required int modified,
    required int listedSize,
    required int generation,
    required String suffix,
  }) async {
    final _NativeStreamInspection inspection;
    try {
      inspection = await _inspectAndroidStreamAsset(id);
    } on PlatformException catch (error) {
      _ensureActive();
      if (!_isRecoverablePhotoPrepareError(error.code)) rethrow;
      await _recordEntryFailure(
        preferences,
        failureStorageKey,
        failureAssetKey,
        _failureReasonForCode(error.code),
        name: name,
        assetId: id,
      );
      return _EntryBackupOutcome.failed;
    }
    if (inspection.size != listedSize ||
        inspection.modified != modified ||
        inspection.generation != generation) {
      await _recordEntryFailure(
        preferences,
        failureStorageKey,
        failureAssetKey,
        'source_changed',
        name: name,
        assetId: id,
      );
      return _EntryBackupOutcome.failed;
    }
    try {
      return await _verifyAndUploadHashedAsset(
        preferences: preferences,
        failureStorageKey: failureStorageKey,
        failureAssetKey: failureAssetKey,
        successKey: successKey,
        destinationDir: destinationDir,
        entryDir: entryDir,
        ensuredSubdirs: ensuredSubdirs,
        safeID: safeID,
        rawID: id,
        modified: modified,
        suffix: suffix,
        exactSize: inspection.size,
        digest: inspection.digest,
        chunkDigests: inspection.chunkDigests,
        performUpload: (destination, uploadKey) => _uploadFromChunkProvider(
          size: inspection.size,
          destination: destination,
          key: uploadKey,
          digest: inspection.digest,
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
        ),
      );
    } on PlatformException catch (error) {
      _ensureActive();
      if (error.code != 'photo_source_changed') rethrow;
      await _recordEntryFailure(
        preferences,
        failureStorageKey,
        failureAssetKey,
        'source_changed',
        name: name,
        assetId: id,
      );
      return _EntryBackupOutcome.failed;
    }
  }

  Future<_EntryBackupOutcome> _backupPreparedFileEntry({
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String failureAssetKey,
    required String successKey,
    required String destinationDir,
    required String entryDir,
    required Set<String> ensuredSubdirs,
    required String id,
    required String safeID,
    required String name,
    required int modified,
    required int listedSize,
    required String suffix,
  }) async {
    String? temporary;
    try {
      _ensureActive();
      final requestId = _newPrepareRequestId();
      _prepare.activeRequestId = requestId;
      _prepare.cancelledRequestId = null;
      Map<String, dynamic>? prepared;
      try {
        prepared = await _photosChannel.invokeMapMethod<String, dynamic>(
          'prepare',
          {
            'id': id,
            'requestId': requestId,
            'includeVideos': _options.includeVideos,
            if (_isIOS) 'allowICloudDownload': _options.allowICloudDownload,
          },
        );
      } on PlatformException catch (error) {
        _ensureActive();
        if (!_isRecoverablePhotoPrepareError(error.code)) rethrow;
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          failureAssetKey,
          _failureReasonForCode(error.code),
          name: name,
          assetId: id,
        );
        return _EntryBackupOutcome.failed;
      } finally {
        if (_prepare.activeRequestId == requestId) {
          _prepare.activeRequestId = null;
        }
        if (_prepare.cancelledRequestId == requestId) {
          _prepare.cancelledRequestId = null;
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
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          failureAssetKey,
          'source_changed',
          name: name,
          assetId: id,
        );
        return _EntryBackupOutcome.failed;
      }

      final file = File(temporary);
      final PhotoHashResult localHash;
      try {
        localHash = await _hashPreparedPhoto(file, exactSize);
      } on PhotoSourceChanged {
        _ensureActive();
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          failureAssetKey,
          'source_unreadable',
          name: name,
          assetId: id,
        );
        return _EntryBackupOutcome.failed;
      } on FileSystemException {
        _ensureActive();
        await _recordEntryFailure(
          preferences,
          failureStorageKey,
          failureAssetKey,
          'source_unreadable',
          name: name,
          assetId: id,
        );
        return _EntryBackupOutcome.failed;
      }
      _ensureActive();

      return await _verifyAndUploadHashedAsset(
        preferences: preferences,
        failureStorageKey: failureStorageKey,
        failureAssetKey: failureAssetKey,
        successKey: successKey,
        destinationDir: destinationDir,
        entryDir: entryDir,
        ensuredSubdirs: ensuredSubdirs,
        safeID: safeID,
        rawID: id,
        modified: modified,
        suffix: suffix,
        exactSize: exactSize,
        digest: localHash.digest,
        chunkDigests: localHash.chunkDigests,
        performUpload: (destination, uploadKey) => _upload(
          file,
          exactSize,
          destination,
          uploadKey,
          localHash.digest,
          localHash.chunkDigests,
        ),
      );
    } finally {
      if (temporary != null) {
        try {
          await _photosChannel.invokeMethod<bool>('release', {
            'path': temporary,
          });
        } catch (error) {
          debugPrint('LightIsle photo temp release failed: $error');
        }
      }
    }
  }

  Future<_EntryBackupOutcome> _processPhotoEntry({
    required Map<String, dynamic> entry,
    required int pageNumber,
    required bool supportsStream,
    required SharedPreferences preferences,
    required String failureStorageKey,
    required String storeVersionID,
    required String destinationDir,
    required Set<String> ensuredSubdirs,
  }) async {
    _ensureActive();
    final id = entry['id']?.toString() ?? '';
    final name = entry['name']?.toString() ?? '';
    final modified = (entry['modified'] as num?)?.toInt() ?? 0;
    final listedSize = (entry['size'] as num?)?.toInt() ?? -1;
    final generation = (entry['generation'] as num?)?.toInt() ?? 0;
    final validID = _isIOS
        ? RegExp(r'^(?:[lvr][.])?[A-Za-z0-9_-]{1,200}$').hasMatch(id)
        : RegExp(r'^[0-9]{1,20}$').hasMatch(id);
    if (!validID || (!_isIOS && listedSize <= 0)) {
      return _EntryBackupOutcome.omitted;
    }
    final safeID = _isIOS
        ? sha256.convert(utf8.encode(id)).toString().substring(0, 24)
        : id;
    _progress.checked++;
    if (mounted) {
      _updateState(
        () => _progress.message =
            '正在检查第 ${_progress.checked} 张照片（第 $pageNumber 页）…',
      );
    }

    final suffix = _extension(name);
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
        verifiedRecord.size <= _maxCachedRemoteVerifyBytes) {
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
        await _clearEntryFailure(
          preferences,
          failureStorageKey,
          failureAssetKey,
        );
        _progress.skipped++;
        return _EntryBackupOutcome.skipped;
      }
      _ensureActive();
      await preferences.remove(successKey);
      _ensureActive();
    }

    if (supportsStream) {
      return _backupAndroidStreamEntry(
        preferences: preferences,
        failureStorageKey: failureStorageKey,
        failureAssetKey: failureAssetKey,
        successKey: successKey,
        destinationDir: destinationDir,
        entryDir: entryDir,
        ensuredSubdirs: ensuredSubdirs,
        id: id,
        safeID: safeID,
        name: name,
        modified: modified,
        listedSize: listedSize,
        generation: generation,
        suffix: suffix,
      );
    }
    return _backupPreparedFileEntry(
      preferences: preferences,
      failureStorageKey: failureStorageKey,
      failureAssetKey: failureAssetKey,
      successKey: successKey,
      destinationDir: destinationDir,
      entryDir: entryDir,
      ensuredSubdirs: ensuredSubdirs,
      id: id,
      safeID: safeID,
      name: name,
      modified: modified,
      listedSize: listedSize,
      suffix: suffix,
    );
  }

  String _buildBackupCompletionMessage({required bool complete}) {
    final unit = _options.includeVideos ? '项' : '张';
    final progressTail =
        complete && _progress.failed == 0 && !_progress.scanHasOmissions
        ? ' 已检查至相册末尾。'
        : complete && _progress.failed > 0
        ? ' 已扫描至相册末尾，但 ${_progress.failed} 项原片尚未备份，已登记待处理，未标记完整。'
        : complete
        ? ' 已扫描至相册末尾，但有照片或视频未能备份，未标记完整。'
        : ' 已保存进度，可继续备份更早的照片。';
    final omissionNotice =
        _progress.scanHasOmissions && _progress.oversizedSkipped == 0
        ? ' 本轮或之前的批次存在无法识别或超出限制的项目，请从最新照片重新检查并在手机上核对。'
        : '';
    final capNotice = _progress.omittedFailures > 0
        ? ' 其中 ${_progress.omittedFailures} 项超过本机 512 条失败记录上限，完整状态会保持未完成；从最新照片重新检查可重试。'
        : '';
    final oversizedNotice = _progress.oversizedSkipped > 0
        ? ' 本批有 ${_progress.oversizedSkipped} 项超过备份单文件大小限制，尚未备份；请通过文件管理器单独上传。'
        : '';
    return '本轮结束：新增 ${_progress.uploaded} $unit，已备份跳过 ${_progress.skipped} $unit。'
        '$progressTail$omissionNotice$capNotice$oversizedNotice';
  }

  void _finalizeRunState(SharedPreferences preferences) {
    if (mounted) {
      try {
        _progress.failureDetails = _readPhotoFailures(
          preferences,
          _photoFailureStorageKey(),
        );
      } catch (error) {
        debugPrint('LightIsle photo failure read failed: $error');
        _progress.failureDetails = [];
      }
    }
    final resume =
        mounted &&
        _progress.resumeAfterCurrentRun &&
        _progress.isForeground &&
        _options.onForeground;
    _progress.resumeAfterCurrentRun = false;
    if (mounted) _updateState(() => _progress.busy = false);
    if (resume) {
      unawaited(
        Future<void>.microtask(() {
          if (mounted &&
              _progress.isForeground &&
              _options.onForeground &&
              !_progress.busy) {
            return _run(older: _progress.pageCursor.isNotEmpty);
          }
        }),
      );
    }
  }

  Future<void> _run({bool older = false}) async {
    if (_progress.busy ||
        _prefs == null ||
        _options.deviceId.isEmpty ||
        !mounted) {
      return;
    }
    final preferences = _prefs!;
    final keys = _BackupSessionKeys(
      _scopedStatePrefix,
      _photoFailureStorageKey(),
    );
    _updateState(_progress.beginRun);
    try {
      await _validateBackupPreconditions();
      await _initializePaginationState(preferences, keys, older: older);

      final base = widget.baseDirectory;
      final destinationDir = '$base/${_options.deviceId}';
      final ensuredSubdirs = <String>{};
      var dirsReady = false;
      var complete = false;
      var pages = 0;
      var restartedAfterLibraryChange = false;
      var failureStateInitialized = false;

      while (pages < _options.batchPages && !_progress.cancel && mounted) {
        _ensureActive();
        await _verifyWifiIfRequired();
        final before = _progress.pageCursor;
        final page = await _fetchPhotoPage(before);

        if (before.isNotEmpty) {
          final previousVersion = preferences.getString(keys.storeVersionKey);
          if (previousVersion != null &&
              previousVersion != page.storeVersionID) {
            if (restartedAfterLibraryChange) {
              throw StateError('相册持续变化，请稍后从最新照片重新检查。');
            }
            restartedAfterLibraryChange = true;
            _progress.pageCursor = '';
            _progress.nextCursor = '';
            if (!await preferences.remove(keys.cursorKey) ||
                !await preferences.setBool(keys.scanIncompleteKey, false)) {
              throw StateError('无法重置照片检查进度，请重试。');
            }
            _progress.scanHasOmissions = false;
            await preferences.setString(
              keys.storeVersionKey,
              page.storeVersionID,
            );
            _ensureActive();
            failureStateInitialized = false;
            pages = 0;
            continue;
          }
        }

        if (!failureStateInitialized) {
          final previousFailureVersion = preferences.getString(
            '${keys.failureStorageKey}.version',
          );
          final resetFailureSet =
              !older || previousFailureVersion != page.storeVersionID;
          final failureCounts = resetFailureSet
              ? await _resetPhotoFailures(
                  preferences,
                  keys.failureStorageKey,
                  page.storeVersionID,
                )
              : await _photoFailureCounts(preferences, keys.failureStorageKey);
          _progress.failed = failureCounts.total;
          _progress.omittedFailures = failureCounts.omitted;
          failureStateInitialized = true;
          _ensureActive();
        }

        if (page.rows.isNotEmpty && !dirsReady) {
          await _ensureRemoteDestinationReady(base, destinationDir);
          dirsReady = true;
        }

        var pageHadFailures = false;
        final recordedOmittedItems = await _recordOmittedPageItems(
          preferences,
          keys.failureStorageKey,
          page.storeVersionID,
          page.omittedItems,
        );
        var pageHasOmissions =
            page.oversizedCount > 0 ||
            page.invalidCount > 0 ||
            recordedOmittedItems;

        for (final entry in page.rows) {
          final outcome = await _processPhotoEntry(
            entry: entry,
            pageNumber: pages + 1,
            supportsStream: page.supportsStream,
            preferences: preferences,
            failureStorageKey: keys.failureStorageKey,
            storeVersionID: page.storeVersionID,
            destinationDir: destinationDir,
            ensuredSubdirs: ensuredSubdirs,
          );
          if (outcome == _EntryBackupOutcome.failed) pageHadFailures = true;
          if (outcome == _EntryBackupOutcome.omitted) pageHasOmissions = true;
        }

        _ensureActive();
        if (pageHasOmissions) {
          if (!await preferences.setBool(keys.scanIncompleteKey, true)) {
            throw StateError('无法保存未备份项目状态，未推进照片分页进度。');
          }
          _progress.scanHasOmissions = true;
        }
        pages++;
        _progress.oversizedSkipped += page.oversizedCount.clamp(
          0,
          _maxOversizedClampPerPage,
        );
        if (!pageHadFailures && !pageHasOmissions) {
          _progress.lastVerifiedAt = DateTime.now().millisecondsSinceEpoch;
          await preferences.setInt(
            keys.lastVerifiedKey,
            _progress.lastVerifiedAt,
          );
        }
        if (page.nextCursor.isEmpty) {
          if (!await preferences.remove(keys.cursorKey)) {
            throw StateError('无法完成照片分页记录，请重新检查。');
          }
          _ensureActive();
          _progress.pageCursor = '';
          _progress.nextCursor = '';
          complete = true;
          final failureCounts = await _photoFailureCounts(
            preferences,
            keys.failureStorageKey,
          );
          _progress.failed = failureCounts.total;
          _progress.omittedFailures = failureCounts.omitted;
          if (failureCounts.total == 0 && !_progress.scanHasOmissions) {
            _progress.lastCompleteAt = _progress.lastVerifiedAt;
            await preferences.setInt(
              keys.lastCompleteKey,
              _progress.lastCompleteAt,
            );
          }
          break;
        }
        if (!await preferences.setString(
          keys.storeVersionKey,
          page.storeVersionID,
        )) {
          throw StateError('无法保存手机相册版本，请重新检查。');
        }
        if (!await preferences.setString(keys.cursorKey, page.nextCursor)) {
          throw StateError('无法保存照片分页进度，请重新检查。');
        }
        _progress.pageCursor = page.nextCursor;
        _progress.nextCursor = page.nextCursor;
        _ensureActive();
      }

      _ensureActive();
      final doneSummary = _buildBackupCompletionMessage(complete: complete);
      _updateState(() => _progress.message = doneSummary);
    } on _PausePhotoBackup {
      if (mounted) {
        _updateState(
          () => _progress.message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。',
        );
      }
    } catch (error) {
      if (_progress.cancel || !mounted) {
        if (mounted) {
          _updateState(
            () => _progress.message = '已暂停；本轮已完成的分页进度已保存。未完成的照片将重新核对并从服务端偏移续传。',
          );
        }
        return;
      }
      if (mounted) {
        _updateState(
          () => _progress.message =
              '备份中断：${userFacingError(error)}。未删除手机原片或已完成的远端备份。',
        );
      }
    } finally {
      _finalizeRunState(preferences);
    }
  }
}

class _PausePhotoBackup implements Exception {
  const _PausePhotoBackup();
}
