part of 'files_page.dart';

extension _FilesPageUploads on _FilesPageState {
  void _onTaskCenterChange() {
    if (!mounted || _disposed) return;
    final finished =
        widget.taskCenter?.jobs
            .where(
              (job) =>
                  job.status == FileUploadStatus.complete &&
                  job.rootIdentity == widget.api.selectedRoot?.identity &&
                  (job.actualDestination.startsWith('${_dir.path}/') ||
                      _dir.path == '.'),
            )
            .toSet() ??
        <FileUploadJob>{};
    final hasNew = finished
        .difference(_transfers.observedCompletedUploads)
        .isNotEmpty;
    _transfers.observedCompletedUploads
      ..clear()
      ..addAll(finished);
    _updateState(() {});
    if (hasNew && !widget.uploadOnly && !_dir.loading) {
      unawaited(_refreshCurrentView());
    }
  }

  Future<void> _chooseUploadSource() async {
    if (!_dir.canWrite || _transfers.uploadBusy) return;
    final type = await showModalBottomSheet<FileType>(
      context: context,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                '上传到当前文件夹',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('照片与视频'),
              subtitle: const Text('从系统相册选择'),
              onTap: () => Navigator.pop(context, FileType.media),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('文件'),
              subtitle: const Text('从设备或其他应用选择'),
              onTap: () => Navigator.pop(context, FileType.any),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (!mounted || type == null) return;
    await openFileUpload(
      context,
      api: widget.api,
      isAdmin: widget.isAdmin,
      accountName: widget.accountName,
      taskCenter: widget.taskCenter,
      directory: _dir.path,
      type: type,
      title: type == FileType.media ? '上传照片与视频' : '上传文件',
    );
    if (mounted) await _loadFiles();
  }

  Future<void> _pickUploads({FileType type = FileType.any}) async {
    if (!_dir.canWrite || _transfers.uploadBusy) return;
    _refreshState(() => _transfers.uploadBusy = true);
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: '选择要上传的文件',
        type: type,
        darwinOptions: const DarwinOptions(
          assetRepresentationMode: DarwinAssetRepresentationMode.current,
        ),
      );
    } catch (error) {
      _refreshState(() {
        _transfers.uploadBusy = false;
        _dir.error = '无法打开文件选择器：${_friendlyError(error)}';
      });
      return;
    }
    if (!mounted) return;
    if (files.isEmpty) {
      _refreshState(() => _transfers.uploadBusy = false);
      return;
    }
    final destinationDirectory = _dir.path;
    final jobs = <FileUploadJob>[];
    for (final file in files) {
      final issue = validateFileName(file.name);
      if (issue != null) {
        _refreshState(() => _dir.error = '“${file.name}”无法上传：$issue');
        continue;
      }
      jobs.add(
        FileUploadJob(
          file: file,
          destination: _joinRelative(destinationDirectory, file.name),
          rootIdentity: widget.api.selectedRoot?.identity,
        ),
      );
    }
    if (jobs.isEmpty) {
      _refreshState(() => _transfers.uploadBusy = false);
      return;
    }
    if (widget.taskCenter != null) {
      _refreshState(() => _dir.error = null);
      await widget.taskCenter!.enqueue(
        jobs.map((job) => job.file).toList(),
        directory: destinationDirectory,
        root: widget.api.selectedRoot,
        autoRename: _prefsState.uploadAutoRename,
      );
      _refreshState(() => _transfers.uploadBusy = false);
      return;
    }
    _refreshState(() {
      _transfers.uploadJobs.addAll(jobs);
      _dir.error = null;
    });
    for (final job in jobs) {
      if (!mounted || job.cancelRequested) continue;
      await _runUpload(job);
    }
    _refreshState(() => _transfers.uploadBusy = false);
    if (mounted) await _refreshCurrentView();
  }

  Future<void> _runUpload(FileUploadJob job) => _uploadService.run(job);
  void _togglePause(FileUploadJob job) {
    job.togglePause();
    _refreshState(() {});
  }

  Future<void> _confirmAndCancelUpload(
    FileUploadJob job, {
    bool discard = false,
  }) async {
    final hasProgress =
        job.status == FileUploadStatus.uploading ||
        (job.status == FileUploadStatus.paused && job.offset > 0) ||
        job.uploadId != null;
    if (hasProgress) {
      final approved = await confirmAction(
        context,
        '取消上传任务',
        '确认取消「${job.file.name}」？取消后将清理服务端已接收的临时分片，下次需重新上传。若仅需稍后继续，请使用「暂停上传」。',
        action: '确认取消',
        isDestructive: true,
      );
      if (!approved || !mounted) return;
    }
    if (widget.taskCenter != null) {
      widget.taskCenter!.cancel(job);
      return;
    }
    if (discard) {
      await _discardUpload(job);
    } else {
      _cancelUpload(job);
    }
  }

  void _cancelUpload(FileUploadJob job) {
    job.requestCancel();
    _refreshState(() {});
  }

  Future<void> _discardUpload(FileUploadJob job) async {
    job.requestCancel();
    await _uploadService.abort(job);
    job.status = FileUploadStatus.cancelled;
    _refreshState(() {});
  }

  void _cancelUploads() {
    for (final job in _transfers.uploadJobs) {
      if (job.status == FileUploadStatus.uploading ||
          job.status == FileUploadStatus.paused ||
          job.status == FileUploadStatus.checking) {
        job.requestCancel();
      }
    }
  }

  Future<void> _retryUpload(FileUploadJob job) async {
    if (_transfers.uploadBusy) return;
    _refreshState(() {
      _transfers.uploadBusy = true;
      job.prepareRetry();
    });
    await _runUpload(job);
    _refreshState(() => _transfers.uploadBusy = false);
  }

  bool get _hasActiveUploads => _transfers.uploadJobs.any(
    (job) =>
        job.status == FileUploadStatus.checking ||
        job.status == FileUploadStatus.uploading ||
        job.status == FileUploadStatus.paused,
  );

  Widget _uploadView(BuildContext context) => PopScope(
    canPop: widget.taskCenter != null || !_hasActiveUploads,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || widget.taskCenter != null) return;
      if (!_hasActiveUploads) {
        Navigator.of(context).pop();
        return;
      }
      final leave = await confirmAction(
        context,
        '结束本次上传？',
        '未完成的上传将取消，设备上的原文件会保留。',
        action: '结束上传',
      );
      if (!leave || !mounted) return;
      _cancelUploads();
      _updateState(() => _transfers.uploadBusy = false);
      if (context.mounted) Navigator.of(context).pop();
    },
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        IsleSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('保存位置', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Text(
                '${widget.api.selectedRoot?.name ?? _dir.rootName} / ${_dir.path == '.' ? '共享目录' : _dir.path}',
              ),
              const SizedBox(height: 12),
              Text(
                widget.taskCenter != null
                    ? '支持多选。离开此页面上传仍会继续，可在传输任务中心管理。'
                    : '支持多选。保持此页面打开，可暂停、继续或重试。',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    _dir.loading || _transfers.uploadBusy || !_dir.canWrite
                    ? null
                    : () => _pickUploads(type: widget.initialUploadType),
                icon: const Icon(Icons.add_rounded),
                label: Text(
                  (widget.taskCenter?.jobs ?? _transfers.uploadJobs).isEmpty
                      ? '选择要上传的内容'
                      : '继续添加',
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('同名自动改名'),
                subtitle: const Text('保留原文件和新文件'),
                value: _prefsState.uploadAutoRename,
                onChanged: _transfers.uploadBusy ? null : _setUploadAutoRename,
              ),
            ],
          ),
        ),
        if (_dir.loading) const LinearProgressIndicator(),
        if (_dir.error != null)
          Notice(_dir.error!, error: true, onRetry: _loadFiles),
        if (!_dir.loading && !_dir.canWrite && _dir.error == null)
          const Notice('此位置没有上传权限，请联系管理员开放写入权限。'),
        if (widget.taskCenter != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.sync_alt_rounded),
              label: const Text('查看传输任务'),
              onPressed: () => Navigator.of(context).push(
                buildIslePageRoute<void>(
                  builder: (_) =>
                      UploadTaskCenterPage(center: widget.taskCenter!),
                ),
              ),
            ),
          ),
        if ((widget.taskCenter?.jobs ?? _transfers.uploadJobs).isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildUploads(context),
        ],
        const SizedBox(height: 24),
      ],
    ),
  );

  Widget _buildUploads(BuildContext context) => FileUploadQueueView(
    jobs: widget.taskCenter?.jobs ?? _transfers.uploadJobs,
    retryBusy: _transfers.uploadBusy,
    onPause: (job) => widget.taskCenter == null
        ? _togglePause(job)
        : widget.taskCenter!.togglePause(job),
    onCancel: (job) => _confirmAndCancelUpload(job),
    onRetry: (job) => widget.taskCenter == null
        ? _retryUpload(job)
        : widget.taskCenter!.retry(job),
    onDiscard: (job) => _confirmAndCancelUpload(job, discard: true),
    onClear: (job) => widget.taskCenter == null
        ? _refreshState(() => _transfers.uploadJobs.remove(job))
        : widget.taskCenter!.clearFinished(),
  );
}
