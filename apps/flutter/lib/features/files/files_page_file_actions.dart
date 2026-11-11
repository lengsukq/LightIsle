part of 'files_page.dart';

extension _FilesPageFileActions on _FilesPageState {
  Future<void> _openExternal(FileEntry item) async {
    if (_downloading.contains(item.path)) return;
    _refreshState(() {
      _downloading.add(item.path);
      _downloadProgress[item.path] = 0;
      _downloadMessage = null;
    });
    try {
      final message = await ExternalFileOpener.open(
        api: widget.api,
        path: item.path,
        name: item.name,
        size: item.size,
        onProgress: (value) =>
            _refreshState(() => _downloadProgress[item.path] = value),
      );
      _refreshState(() => _downloadMessage = message);
    } catch (error) {
      _refreshState(
        () => _downloadMessage =
            '无法通过其他应用打开：${userFacingError(error)}。可以改用“下载”保存原文件。',
      );
    } finally {
      _refreshState(() {
        _downloading.remove(item.path);
        _downloadProgress.remove(item.path);
      });
    }
  }

  Future<void> _preview(FileEntry item) async {
    final kind = classifyFilePreview(item.name);
    if (kind == FilePreviewKind.image || kind == FilePreviewKind.video) {
      final playlist = FileMediaPlaylist.fromDirectory(_entries, item);
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PhotoGalleryViewer(
            api: widget.api,
            assets: playlist.assets,
            initialIndex: playlist.initialIndex,
            fileBrowserMode: true,
            canEditSharedFavorite: (_) => false,
            onSharedFavorite: (asset) async => asset,
            onPersonalFavorite: (asset) async => asset,
            onDetails: (_) async {},
            onLoadMore: () async => playlist.assets,
          ),
        ),
      );
      return;
    }
    if (kind == FilePreviewKind.pdf) {
      await showDialog<void>(
        context: context,
        builder: (_) => FilePdfPreviewDialog(
          api: widget.api,
          item: item,
          onOpenExternal: () => _openExternal(item),
          onDownload: () => _download(item),
        ),
      );
      return;
    }
    if (kind == FilePreviewKind.external) {
      _refreshState(() => _error = '该文件暂不支持在线预览，请通过右侧更多菜单保存文件或使用其他应用打开。');
      return;
    }
    final generation = _loadGeneration;
    final rootIdentity = _rootIdentity;
    final directory = _path;
    String? decodedText;
    String? failure;
    try {
      final data = await widget.api.bytes(
        '/api/v2/files/preview',
        query: {'path': item.path},
        maxBytes: _maxTextPreviewSize,
      );
      decodedText = decodePreviewText(data);
    } catch (error) {
      failure = error is FormatException
          ? '无法识别文本编码，原文件未更改。可尝试其他编辑器。'
          : _friendlyError(error);
    }
    // A slow preview must never present an old disk's file after navigating
    // or switching the selected physical root.
    if (!_browserRequestCurrent(generation, rootIdentity) ||
        directory != _path) {
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (_) => FileTextPreviewDialog(
        item: item,
        badge: _buildFileBadge(item),
        text: decodedText,
        error: failure,
        onOpenExternal: () => _openExternal(item),
        onDownload: () => _download(item),
      ),
    );
  }

  Future<void> _shareFile(FileEntry item) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FileShareDialog(
        api: widget.api,
        path: item.path,
        name: item.name,
        isFolder: item.isFolder,
      ),
    );
  }

  Future<void> _download(FileEntry item) async {
    if (_downloading.contains(item.path)) return;
    final fileName = item.isFolder
        ? '${item.name}.zip'
        : item.name.split('/').last.split('\\').last;
    final nameIssue = validateFileName(fileName);
    if (nameIssue != null) {
      _refreshState(() => _downloadMessage = '无法保存此文件：$nameIssue');
      return;
    }

    final mobileExport =
        widget.mobileExportOverride ??
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    Directory? temporaryDirectory;
    String? destination;
    try {
      if (mobileExport) {
        final temporaryRoot = await getTemporaryDirectory();
        temporaryDirectory =
            await (widget.exportDirectoryFactory?.call(temporaryRoot) ??
                temporaryRoot.createTemp('lightisle-export-'));
        destination = _joinNative(temporaryDirectory.path, fileName);
      } else {
        final directory = await FilePicker.getDirectoryPath(
          dialogTitle: '选择文件保存目录',
        );
        if (!mounted || directory == null || directory.isEmpty) return;
        final normalizedDirectory = _filePickerPath(directory);
        destination = await _destinationWithoutOverwrite(
          normalizedDirectory,
          fileName,
        );
        if (destination == null) return;
      }
    } catch (error) {
      _refreshState(
        () => _downloadMessage = '无法准备下载位置：${_friendlyError(error)}',
      );
      return;
    }
    if (!mounted) {
      await _removeTemporaryDirectory(temporaryDirectory);
      return;
    }

    _refreshState(() {
      _downloading.add(item.path);
      _downloadProgress[item.path] = 0;
      _downloadMessage = null;
    });
    try {
      await widget.api.download(
        item.isFolder ? '/api/v2/files/archive' : '/api/v2/files/content',
        destination,
        query: {'path': item.path},
        onProgress: (received, total) {
          if (total > 0) {
            _refreshState(
              () => _downloadProgress[item.path] = (received / total)
                  .clamp(0, 1)
                  .toDouble(),
            );
          }
        },
      );
      if (!mounted) return;
      if (mobileExport) {
        final exportResult = await fileExportChannel.invokeMethod<String>(
          'exportFile',
          {'path': destination, 'name': fileName},
        );
        _refreshState(() {
          _downloadMessage = exportResult == null
              ? '已取消导出，临时文件已清理。'
              : exportResult == 'shared'
              ? '已完成系统分享或保存。'
              : '已保存到所选位置：$exportResult';
          _downloadProgress.remove(item.path);
        });
      } else {
        _refreshState(() {
          _downloadMessage = '已下载到：$destination';
          _downloadProgress.remove(item.path);
        });
      }
    } catch (error) {
      _refreshState(() {
        _downloadMessage =
            '下载或导出失败：${_friendlyDownloadError(error, item.isFolder)}';
        _downloadProgress.remove(item.path);
      });
    } finally {
      await _removeTemporaryDirectory(temporaryDirectory);
      _refreshState(() => _downloading.remove(item.path));
    }
  }

  Future<String?> _destinationWithoutOverwrite(
    String directory,
    String fileName,
  ) async {
    final destination = _joinNative(directory, fileName);
    if (!await File(destination).exists()) return destination;

    final alternative = await _nextAvailableDestination(directory, fileName);
    if (!mounted) return null;
    final saveCopy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保留已有文件？'),
        content: Text(
          '此位置已有“$fileName”。原文件会保留，新文件将保存为“${_basename(alternative)}”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('另存为新文件'),
          ),
        ],
      ),
    );
    return saveCopy == true ? alternative : null;
  }

  Future<String> _nextAvailableDestination(
    String directory,
    String fileName,
  ) async {
    final dot = fileName.lastIndexOf('.');
    final hasExtension = dot > 0;
    final stem = hasExtension ? fileName.substring(0, dot) : fileName;
    final extension = hasExtension ? fileName.substring(dot) : '';
    for (var suffix = 2; suffix < 10000; suffix++) {
      final candidate = _joinNative(directory, '$stem ($suffix)$extension');
      if (!await File(candidate).exists()) return candidate;
    }
    throw const FileSystemException('无法生成不冲突的文件名。');
  }

  Future<void> _removeTemporaryDirectory(Directory? directory) async {
    if (directory == null) return;
    try {
      final cleanup = widget.exportDirectoryCleanup;
      if (cleanup != null) {
        await cleanup(directory);
      } else if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Temporary exports are private data; cleanup is best-effort on disk errors.
    }
  }

  bool _canWriteItem(FileEntry item) => item.canWrite || widget.isAdmin;
}
