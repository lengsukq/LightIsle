part of 'desktop_backup_engine.dart';

extension _DesktopBackupSync on DesktopBackupController {
  Future<LightIsleRoot> _verifyTargetRoot(DesktopBackupTask task) async {
    final response = await api.get('/api/v2/roots');
    final raw = response['roots'];
    if (raw is! List) {
      throw StateError('无法读取 NAS 存储卷列表，请检查服务器状态。');
    }
    final roots = raw
        .whereType<Map>()
        .map((m) => LightIsleRoot.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
    final byId = roots.where((r) => r.id == task.rootId).firstOrNull;
    if (byId == null) {
      throw StateError('目标硬盘「${task.rootName}」已解除登记，备份未写入其他硬盘。请编辑任务重新指定位置。');
    }
    if (byId.generation != task.rootGeneration) {
      throw StateError(
        '目标硬盘「${task.rootName}」代际已变更（可能更换了物理硬盘），备份已安全停止。请核对后重新保存任务。',
      );
    }
    if (!byId.online) {
      throw StateError('目标硬盘「${task.rootName}」当前离线，请检查硬盘连接后重试。');
    }
    return byId;
  }

  Future<DesktopBackupRunSummary> _executeSync({
    required LightIsleApi client,
    required DesktopBackupTask task,
    required String localRootPath,
    required Set<String>? onlyPaths,
    required int startedAtMs,
  }) async {
    _setProgress(
      DesktopBackupProgress(
        taskId: task.id,
        phase: '正在扫描本地文件夹…',
        completedFiles: 0,
        totalFiles: 0,
      ),
    );

    final fileIndex = await store.loadFileIndex(task.id);
    final (priorFailures, _) = await store.loadFailures(task.id);
    final failuresByPath = <String, DesktopBackupFailure>{
      if (onlyPaths != null)
        for (final f in priorFailures) f.relativePath: f,
    };

    final scanned = <_LocalScanItem>[];
    var skippedSymlinks = 0;

    Future<void> walkDirectory(Directory current, String relPrefix) async {
      _checkActive();
      final List<FileSystemEntity> children;
      try {
        children = await current.list(followLinks: false).toList();
      } catch (error) {
        final targetLabel = relPrefix.isEmpty ? '.' : relPrefix;
        failuresByPath[targetLabel] = DesktopBackupFailure(
          relativePath: targetLabel,
          reason: '目录无法读取：${userFacingError(error)}',
          failedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        return;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in children) {
        _checkActive();
        final name = _basename(entity.path);
        if (_shouldSkipName(name, ignoreHidden: task.ignoreHidden)) continue;
        final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.link) {
          skippedSymlinks++;
          continue;
        }
        final nameIssue = validateFileName(name);
        if (nameIssue != null) {
          failuresByPath[relPath] = DesktopBackupFailure(
            relativePath: relPath,
            reason: '文件名不符合 NAS 规范：$nameIssue',
            failedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
          continue;
        }
        if (type == FileSystemEntityType.directory) {
          await walkDirectory(Directory(entity.path), relPath);
        } else if (type == FileSystemEntityType.file) {
          if (onlyPaths != null && !onlyPaths.contains(relPath)) continue;
          final targetRel = _joinRemotePath(task.remoteBasePath, relPath);
          final pathIssue = validateRelativePath(targetRel);
          if (pathIssue != null) {
            failuresByPath[relPath] = DesktopBackupFailure(
              relativePath: relPath,
              reason: '目标相对路径无效：$pathIssue',
              failedAtMs: DateTime.now().millisecondsSinceEpoch,
            );
            continue;
          }
          scanned.add(
            _LocalScanItem(
              file: File(entity.path),
              relativePath: relPath,
              parentRelativeDir: relPrefix,
              fileName: name,
            ),
          );
        }
      }
    }

    await walkDirectory(Directory(localRootPath), '');
    if (onlyPaths != null) {
      final foundPaths = scanned.map((s) => s.relativePath).toSet();
      failuresByPath.removeWhere(
        (key, _) => onlyPaths.contains(key) && !foundPaths.contains(key),
      );
    }

    final byDir = <String, List<_LocalScanItem>>{};
    for (final item in scanned) {
      byDir
          .putIfAbsent(item.parentRelativeDir, () => <_LocalScanItem>[])
          .add(item);
    }

    if (task.remoteBasePath != '.') {
      await _ensureRemoteFolderChain(client, task.remoteBasePath);
    }

    var uploadedNew = 0;
    var updatedReplaced = 0;
    var skippedUnchanged = 0;
    var processed = 0;
    String? quotaStopError;
    final total = scanned.length;

    dirLoop:
    for (final dirEntry in byDir.entries) {
      _checkActive();
      final remoteDir = _joinRemotePath(task.remoteBasePath, dirEntry.key);
      Map<String, ({int size, String type})> remoteSnapshot;
      try {
        if (remoteDir != '.') {
          await _ensureRemoteFolderChain(client, remoteDir);
        }
        remoteSnapshot = await _listRemoteFolder(client, remoteDir);
      } catch (error) {
        if (_isStorageExhausted(error)) {
          quotaStopError = 'NAS 个人配额或磁盘空间已满，已自动暂停剩余文件上传，请清理空间或扩容后重试';
          failuresByPath[dirEntry.value.first.relativePath] =
              DesktopBackupFailure(
                relativePath: dirEntry.value.first.relativePath,
                reason: quotaStopError,
                failedAtMs: DateTime.now().millisecondsSinceEpoch,
              );
          break dirLoop;
        }
        final reason = '远端目录准备失败：${userFacingError(error)}';
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        for (final item in dirEntry.value) {
          failuresByPath[item.relativePath] = DesktopBackupFailure(
            relativePath: item.relativePath,
            reason: reason,
            failedAtMs: nowMs,
          );
          processed++;
        }
        continue;
      }

      for (final item in dirEntry.value) {
        _checkActive();
        _setProgress(
          DesktopBackupProgress(
            taskId: task.id,
            phase: '正在同步 (${processed + 1}/$total)',
            completedFiles: processed,
            totalFiles: total,
            currentFile: item.relativePath,
          ),
        );
        try {
          final outcome = await _syncSingleFile(
            client: client,
            task: task,
            item: item,
            remoteDir: remoteDir,
            remoteSnapshot: remoteSnapshot,
            fileIndex: fileIndex,
          );
          failuresByPath.remove(item.relativePath);
          switch (outcome) {
            case _FileSyncOutcome.uploadedNew:
              uploadedNew++;
            case _FileSyncOutcome.updated:
              updatedReplaced++;
            case _FileSyncOutcome.skipped:
              skippedUnchanged++;
          }
        } on _CancelledDesktopBackup {
          await store.saveFileIndex(task.id, fileIndex);
          await store.saveFailures(task.id, failuresByPath.values.toList());
          rethrow;
        } catch (error) {
          if (_isStorageExhausted(error)) {
            quotaStopError = 'NAS 个人配额或磁盘空间已满，已自动暂停剩余文件上传，请清理空间或扩容后重试';
            failuresByPath[item.relativePath] = DesktopBackupFailure(
              relativePath: item.relativePath,
              reason: quotaStopError,
              failedAtMs: DateTime.now().millisecondsSinceEpoch,
            );
            break dirLoop;
          }
          failuresByPath[item.relativePath] = DesktopBackupFailure(
            relativePath: item.relativePath,
            reason: error is PhotoSourceChanged
                ? '本地文件在备份期间正在被修改，请稍后重试'
                : userFacingError(error),
            failedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
        }
        processed++;
      }
    }

    await store.saveFileIndex(task.id, fileIndex);
    final finalFailures = failuresByPath.values.toList(growable: false);
    await store.saveFailures(task.id, finalFailures);

    final summary = DesktopBackupRunSummary(
      uploadedNew: uploadedNew,
      updatedReplaced: updatedReplaced,
      skippedUnchanged: skippedUnchanged,
      skippedSymlinks: skippedSymlinks,
      failedCount: finalFailures.length,
      cancelled: false,
    );
    final completedAt = DateTime.now().millisecondsSinceEpoch;
    final updatedTask = task.copyWith(
      lastRunAtMs: startedAtMs,
      lastCompleteAtMs: finalFailures.isEmpty && quotaStopError == null
          ? completedAt
          : task.lastCompleteAtMs,
      lastSummary: summary.formatLabel(),
      lastError:
          quotaStopError ??
          (finalFailures.isEmpty
              ? null
              : '有 ${finalFailures.length} 个文件未能完成同步，可点击「仅重试失败项」'),
      clearError: finalFailures.isEmpty && quotaStopError == null,
      lastSkippedSymlinks: skippedSymlinks,
    );
    await _persistTaskUpdate(updatedTask);
    return summary;
  }

  Future<_FileSyncOutcome> _syncSingleFile({
    required LightIsleApi client,
    required DesktopBackupTask task,
    required _LocalScanItem item,
    required String remoteDir,
    required Map<String, ({int size, String type})> remoteSnapshot,
    required Map<String, DesktopBackupFileRecord> fileIndex,
  }) async {
    final entityType = await FileSystemEntity.type(
      item.file.path,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.file) {
      throw const PhotoSourceChanged();
    }
    final stat = await item.file.stat();
    final size = stat.size;
    final mtimeMs = stat.modified.millisecondsSinceEpoch;
    final cached = fileIndex[item.relativePath];
    final expectedRemoteName = cached?.remoteName ?? item.fileName;
    final cachedRemoteEntry = remoteSnapshot[expectedRemoteName];

    if (cached != null &&
        cached.size == size &&
        cached.modifiedMs == mtimeMs &&
        cachedRemoteEntry != null &&
        cachedRemoteEntry.type == 'file' &&
        cachedRemoteEntry.size == size) {
      return _FileSyncOutcome.skipped;
    }

    final remoteDirect = remoteSnapshot[item.fileName];
    if (remoteDirect != null && remoteDirect.type == 'folder') {
      throw StateError('NAS 目标位置已存在同名文件夹「${item.fileName}」，未覆盖。');
    }

    final hash = await hashLocalBackupFile(
      item.file,
      size,
      checkActive: _checkActive,
    );
    final targetPath = _joinRemotePath(remoteDir, item.fileName);

    if (remoteDirect == null) {
      if (task.conflictPolicy == DesktopConflictPolicy.trashAndReplace) {
        final priorStagingName = _buildStagingFileName(
          item.fileName,
          hash.digest,
        );
        final priorStagingEntry = remoteSnapshot[priorStagingName];
        if (priorStagingEntry != null &&
            priorStagingEntry.type == 'file' &&
            priorStagingEntry.size == size) {
          final priorStagingPath = _joinRemotePath(remoteDir, priorStagingName);
          final ready = await client.remoteFileMatchesSHA256(
            priorStagingPath,
            size,
            hash.digest,
            chunkSHA256s: hash.chunkDigests,
            checkActive: _checkActive,
          );
          if (ready) {
            await client.send(
              'POST',
              '/api/v2/files/operations',
              body: <String, Object?>{
                'action': 'move',
                'from': priorStagingPath,
                'to': targetPath,
                'onConflict': '',
              },
            );
            remoteSnapshot.remove(priorStagingName);
            remoteSnapshot[item.fileName] = (size: size, type: 'file');
            fileIndex[item.relativePath] = DesktopBackupFileRecord(
              size: size,
              modifiedMs: mtimeMs,
              sha256: hash.digest,
            );
            return _FileSyncOutcome.updated;
          }
        }
      }
      await _resumableUploadAndVerify(
        client: client,
        taskId: task.id,
        source: item.file,
        size: size,
        destinationPath: targetPath,
        onConflict: '',
        hash: hash,
      );
      remoteSnapshot[item.fileName] = (size: size, type: 'file');
      fileIndex[item.relativePath] = DesktopBackupFileRecord(
        size: size,
        modifiedMs: mtimeMs,
        sha256: hash.digest,
      );
      return _FileSyncOutcome.uploadedNew;
    }

    if (remoteDirect.size == size) {
      final alreadyIdentical = await client.remoteFileMatchesSHA256(
        targetPath,
        size,
        hash.digest,
        chunkSHA256s: hash.chunkDigests,
        checkActive: _checkActive,
      );
      if (alreadyIdentical) {
        fileIndex[item.relativePath] = DesktopBackupFileRecord(
          size: size,
          modifiedMs: mtimeMs,
          sha256: hash.digest,
        );
        return _FileSyncOutcome.skipped;
      }
    }

    if (task.conflictPolicy == DesktopConflictPolicy.keepBoth) {
      final serverPath = await _resumableUploadAndVerify(
        client: client,
        taskId: task.id,
        source: item.file,
        size: size,
        destinationPath: targetPath,
        onConflict: 'rename',
        hash: hash,
      );
      final landedName = _basenamePosix(serverPath);
      remoteSnapshot[landedName] = (size: size, type: 'file');
      fileIndex[item.relativePath] = DesktopBackupFileRecord(
        size: size,
        modifiedMs: mtimeMs,
        sha256: hash.digest,
        remoteName: landedName == item.fileName ? null : landedName,
      );
      return _FileSyncOutcome.updated;
    }

    final stagingName = _buildStagingFileName(item.fileName, hash.digest);
    final stagingPath = _joinRemotePath(remoteDir, stagingName);
    var stagingReady = false;
    if (remoteSnapshot.containsKey(stagingName)) {
      if (remoteSnapshot[stagingName]?.type == 'file' &&
          remoteSnapshot[stagingName]?.size == size) {
        stagingReady = await client.remoteFileMatchesSHA256(
          stagingPath,
          size,
          hash.digest,
          chunkSHA256s: hash.chunkDigests,
          checkActive: _checkActive,
        );
      }
      if (!stagingReady) {
        await _trashRemoteFileIfPresent(client, stagingPath);
        remoteSnapshot.remove(stagingName);
      }
    }
    if (!stagingReady) {
      await _resumableUploadAndVerify(
        client: client,
        taskId: task.id,
        source: item.file,
        size: size,
        destinationPath: stagingPath,
        onConflict: '',
        hash: hash,
      );
    }
    _checkActive();
    await _trashRemoteFileIfPresent(client, targetPath);
    _checkActive();
    await client.send(
      'POST',
      '/api/v2/files/operations',
      body: <String, Object?>{
        'action': 'move',
        'from': stagingPath,
        'to': targetPath,
        'onConflict': '',
      },
    );
    remoteSnapshot.remove(stagingName);
    remoteSnapshot[item.fileName] = (size: size, type: 'file');
    fileIndex[item.relativePath] = DesktopBackupFileRecord(
      size: size,
      modifiedMs: mtimeMs,
      sha256: hash.digest,
    );
    return _FileSyncOutcome.updated;
  }

  Future<String> _resumableUploadAndVerify({
    required LightIsleApi client,
    required String taskId,
    required File source,
    required int size,
    required String destinationPath,
    required String onConflict,
    required PhotoHashResult hash,
  }) async {
    _checkActive();
    final hintKey =
        '${hash.digest.substring(0, 20)}.$size.${destinationPath.hashCode.toUnsigned(32)}';
    Map<String, dynamic>? state;
    final savedId = await store.readUploadHint(taskId, hintKey);
    if (savedId != null && savedId.isNotEmpty) {
      try {
        final existing = await client.get(
          '/api/v2/uploads/${Uri.encodeComponent(savedId)}',
        );
        if ((existing['size'] as num?)?.toInt() == size &&
            _sameParentDirectory(
              destinationPath,
              existing['path']?.toString(),
            )) {
          state = existing;
        }
      } on LightIsleApiException catch (e) {
        if (e.statusCode != HttpStatus.notFound) rethrow;
      }
      if (state == null) await store.clearUploadHint(taskId, hintKey);
    }

    if (state == null) {
      final rng = Random.secure();
      final reqId = List<String>.generate(
        16,
        (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await store.writeUploadHint(taskId, hintKey, reqId);
      try {
        state = await client.send(
          'POST',
          '/api/v2/uploads',
          body: <String, Object?>{
            'path': destinationPath,
            'size': size,
            'onConflict': onConflict,
            'uploadID': reqId,
          },
        );
      } catch (_) {
        _checkActive();
        try {
          state = await client.get(
            '/api/v2/uploads/${Uri.encodeComponent(reqId)}',
          );
        } catch (_) {
          rethrow;
        }
      }
    }

    final uploadId = state['id']?.toString() ?? '';
    final serverPath = state['path']?.toString() ?? '';
    var offset = (state['offset'] as num?)?.toInt() ?? -1;
    if (uploadId.isEmpty ||
        serverPath.isEmpty ||
        !_sameParentDirectory(destinationPath, serverPath) ||
        (onConflict.isEmpty && serverPath != destinationPath) ||
        offset < 0 ||
        offset > size) {
      throw StateError('服务器返回的上传任务状态异常，已中止当前文件写入。');
    }
    await store.writeUploadHint(taskId, hintKey, uploadId);

    while (offset < size) {
      _checkActive();
      final length = min(photoHashChunkBytes, size - offset);
      try {
        state = await client.uploadChunk(
          uploadId,
          source.openRead(offset, offset + length),
          length,
          offset,
        );
      } catch (_) {
        _checkActive();
        final latest = await client.get(
          '/api/v2/uploads/${Uri.encodeComponent(uploadId)}',
        );
        final next = (latest['offset'] as num?)?.toInt() ?? -1;
        if (next <= offset || next > size) rethrow;
        state = latest;
      }
      final next = (state['offset'] as num?)?.toInt() ?? -1;
      if (next <= offset || next > size) {
        throw StateError('文件分片上传进度未前进，请重试。');
      }
      offset = next;
    }

    _checkActive();
    final beforeComplete = await source.stat();
    if (beforeComplete.type != FileSystemEntityType.file ||
        beforeComplete.size != size) {
      throw const PhotoSourceChanged();
    }
    await client.send(
      'POST',
      '/api/v2/uploads/${Uri.encodeComponent(uploadId)}/complete',
    );
    _checkActive();
    final verified = await client.remoteFileMatchesSHA256(
      serverPath,
      size,
      hash.digest,
      chunkSHA256s: hash.chunkDigests,
      checkActive: _checkActive,
    );
    if (!verified) {
      throw StateError('NAS 落盘文件 SHA-256 校验不一致，未标记成功。');
    }
    await store.clearUploadHint(taskId, hintKey);
    return serverPath;
  }

  Future<void> _trashRemoteFileIfPresent(
    LightIsleApi client,
    String remotePath,
  ) async {
    try {
      await client.send(
        'DELETE',
        '/api/v2/files',
        query: <String, String>{'path': remotePath},
      );
    } on LightIsleApiException catch (error) {
      if (error.statusCode != HttpStatus.notFound) rethrow;
    }
  }

  Future<void> _ensureRemoteFolderChain(
    LightIsleApi client,
    String relativeFolder,
  ) async {
    if (relativeFolder.isEmpty || relativeFolder == '.') return;
    try {
      await client.get(
        '/api/v2/files',
        query: <String, String>{'path': relativeFolder, 'limit': '1'},
      );
      return;
    } on LightIsleApiException catch (error) {
      if (error.statusCode != HttpStatus.notFound) rethrow;
    }
    final segments = relativeFolder.split('/');
    var current = '';
    for (final segment in segments) {
      _checkActive();
      current = current.isEmpty ? segment : '$current/$segment';
      try {
        await client.get(
          '/api/v2/files',
          query: <String, String>{'path': current, 'limit': '1'},
        );
      } on LightIsleApiException catch (error) {
        if (error.statusCode != HttpStatus.notFound) rethrow;
        try {
          await client.send(
            'POST',
            '/api/v2/files/folders',
            body: <String, Object?>{'path': current},
          );
        } on LightIsleApiException catch (createErr) {
          if (createErr.statusCode != HttpStatus.conflict) rethrow;
        }
      }
    }
  }

  Future<Map<String, ({int size, String type})>> _listRemoteFolder(
    LightIsleApi client,
    String remoteFolder,
  ) async {
    final snapshot = <String, ({int size, String type})>{};
    var cursor = '';
    for (var page = 0; page < 200; page++) {
      _checkActive();
      final data = await client.get(
        '/api/v2/files',
        query: <String, String>{
          'path': remoteFolder,
          'limit': '200',
          if (cursor.isNotEmpty) 'cursor': cursor,
        },
      );
      final entries = data['entries'];
      if (entries is List) {
        for (final raw in entries) {
          if (raw is! Map) continue;
          final name = raw['name']?.toString() ?? '';
          final type = raw['type']?.toString() ?? '';
          final size = (raw['size'] as num?)?.toInt() ?? 0;
          if (name.isNotEmpty && (type == 'file' || type == 'folder')) {
            snapshot[name] = (size: size, type: type);
          }
        }
      }
      cursor = data['nextCursor']?.toString() ?? '';
      if (cursor.isEmpty) break;
    }
    return snapshot;
  }

  static bool _shouldSkipName(String name, {required bool ignoreHidden}) {
    if (name.isEmpty || name == '.' || name == '..') return true;
    if (DesktopBackupController._ignoredJunkNames.contains(name)) return true;
    if (name.startsWith('.lightisle-')) return true;
    if (ignoreHidden && name.startsWith('.')) return true;
    return false;
  }

  static String _joinRemotePath(String base, String child) {
    final cleanBase = base.trim().isEmpty ? '.' : base.trim();
    if (child.isEmpty || child == '.') return cleanBase;
    return cleanBase == '.' ? child : '$cleanBase/$child';
  }

  static String _basename(String fsPath) {
    var normalized = fsPath;
    while (normalized.length > 1 &&
        (normalized.endsWith('/') || normalized.endsWith('\\'))) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final slash = max(
      normalized.lastIndexOf('/'),
      normalized.lastIndexOf('\\'),
    );
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  static String _basenamePosix(String posixPath) {
    final slash = posixPath.lastIndexOf('/');
    return slash < 0 ? posixPath : posixPath.substring(slash + 1);
  }

  static bool _sameParentDirectory(String expectedPath, String? actualPath) {
    if (actualPath == null || validateRelativePath(actualPath) != null) {
      return false;
    }
    final expSlash = expectedPath.lastIndexOf('/');
    final actSlash = actualPath.lastIndexOf('/');
    final expDir = expSlash < 0 ? '' : expectedPath.substring(0, expSlash);
    final actDir = actSlash < 0 ? '' : actualPath.substring(0, actSlash);
    return expDir == actDir;
  }

  static String _buildStagingFileName(String originalName, String sha256Hex) {
    final dot = originalName.lastIndexOf('.');
    final hasExt = dot > 0 && dot < originalName.length - 1;
    final rawStem = hasExt ? originalName.substring(0, dot) : originalName;
    final ext = hasExt ? originalName.substring(dot) : '';
    final suffix = '_sync_${sha256Hex.substring(0, 8)}';
    final maxStemRunes = max(1, 140 - suffix.runes.length - ext.runes.length);
    final stemRunes = rawStem.runes.toList(growable: false);
    final safeStem = stemRunes.length <= maxStemRunes
        ? rawStem
        : String.fromCharCodes(stemRunes.take(maxStemRunes));
    final candidate = '$safeStem$suffix$ext';
    return candidate.startsWith('.lightisle-') ? 'sync_$candidate' : candidate;
  }

  static bool _isStorageExhausted(Object error) {
    if (error is LightIsleApiException) {
      if (error.statusCode == HttpStatus.insufficientStorage ||
          error.statusCode == HttpStatus.requestEntityTooLarge) {
        return true;
      }
      const codes = <String>{
        'quota_exceeded',
        'storage_quota_exceeded',
        'insufficient_storage',
        'disk_full',
        'no_space_left',
      };
      if (codes.contains(error.code)) return true;
    }
    return false;
  }
}
