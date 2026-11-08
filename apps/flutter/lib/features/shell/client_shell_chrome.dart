part of 'client_shell.dart';

extension _ClientShellChrome on _ClientShellState {
  Widget _taskButton({bool unified = false}) => ListenableBuilder(
    listenable: _uploadCenter,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final unfinished = _uploadCenter.unfinished;
      return Tooltip(
        message: '传输任务（未结束 $unfinished）',
        child: InkWell(
          key: const ValueKey('globalUploadTaskCenter'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => UploadTaskCenterPage(center: _uploadCenter),
            ),
          ),
          child: Container(
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: .045),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .32),
                width: .6,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Badge(
              isLabelVisible: unfinished > 0,
              label: Text('$unfinished'),
              backgroundColor: scheme.primary,
              textColor: scheme.onPrimary,
              child: Icon(
                Icons.swap_vert_rounded,
                size: 20,
                color: unfinished > 0
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _accountButton({bool unified = false}) {
    final scheme = Theme.of(context).colorScheme;
    final rawName = widget.identity['username']?.toString().trim() ?? '';
    final initial =
        rawName.isNotEmpty ? rawName.characters.first.toUpperCase() : '';

    return Tooltip(
      message: '设置与账号${rawName.isNotEmpty ? '（$rawName）' : ''}',
      child: InkWell(
        key: const ValueKey('macAccountButton'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => _select(3),
        child: Container(
          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: .045),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .32),
              width: .6,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: initial.isNotEmpty
              ? Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      height: 1.1,
                    ),
                  ),
                )
              : Icon(
                  Icons.person_rounded,
                  size: 19,
                  color: scheme.onSurfaceVariant,
                ),
        ),
      ),
    );
  }

  Widget _buildRouteErrorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.storage_outlined, size: 40),
          const SizedBox(height: 12),
          Text(_personalRouteError!, textAlign: TextAlign.center),
          TextButton.icon(
            onPressed: _rootsLoading ? null : _refreshRoots,
            icon: const Icon(Icons.refresh),
            label: const Text('重新检查并恢复浏览'),
          ),
        ],
      ),
    ),
  );

  Widget _buildDashboardFilesContainer() {
    if (_personalRouteError != null && _manualRootSection != 0) {
      return _buildRouteErrorView();
    }
    final filesRoute = _routeForCategory('files');
    _dashboardFilesWidget ??= KeyedSubtree(
      key: ValueKey(
        'root:${widget.api.selectedRoot?.identity ?? 'default'}:files:${_fileEntryOverride ?? ''}',
      ),
      child: FilesPage(
        api: widget.api,
        taskCenter: _uploadCenter,
        isAdmin: _admin,
        accountName: widget.identity['username']?.toString() ?? '',
        initialPath:
            _fileEntryOverride ??
            (filesRoute.kind == PersonalRouteKind.personal &&
                    _manualRootSection != 0
                ? filesRoute.path!
                : '.'),
        showPhotoBackup: false,
      ),
    );
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 2, 12, 2),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.55),
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.25),
                width: 0.6,
              ),
            ),
          ),
          child: Row(
            children: [
              TextButton.icon(
                key: const ValueKey('backToDashboardFromFiles'),
                onPressed: () => _updateState(() {
                  _showingDashboardFiles = false;
                  _fileEntryOverride = null;
                }),
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 15),
                label: const Text('返回仪表盘'),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.folder_open_rounded,
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '文件管理 · ${widget.api.selectedRoot?.name ?? (_admin ? '默认目录' : '个人存储')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _dashboardFilesWidget!),
      ],
    );
  }

  Widget _rootPicker({required bool showName, bool unified = false}) {
    final scheme = Theme.of(context).colorScheme;
    final selectedName =
        widget.api.selectedRoot?.name ?? (_admin ? '默认目录' : '个人存储');
    final surface = Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: EdgeInsets.symmetric(horizontal: showName ? 10 : 8, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: .045),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: .32),
          width: .6,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_rootsLoading)
            const SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          else
            Icon(
              _rootsError != null
                  ? Icons.sync_problem_rounded
                  : Icons.storage_rounded,
              size: 17,
              color: _rootsError != null
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          if (showName) ...[
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                selectedName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              _admin
                  ? Icons.expand_more_rounded
                  : Icons.refresh_rounded,
              color: scheme.onSurfaceVariant.withValues(alpha: .8),
              size: 16,
            ),
          ],
        ],
      ),
    );

    // Ordinary members cannot choose physical NAS roots. A popup containing
    // only disabled choices felt broken; tapping their status now refreshes
    // the actual allocated storage binding instead.
    if (!_admin) {
      return Tooltip(
        message: '刷新当前账号的存储分配与连接状态',
        child: InkWell(
          key: const ValueKey('shellRootPickerSurface'),
          borderRadius: BorderRadius.circular(10),
          onTap: _rootsLoading ? null : () => unawaited(_refreshRoots()),
          child: surface,
        ),
      );
    }

    return PopupMenuButton<String>(
      key: const ValueKey('shellRootPicker'),
      tooltip: '查看或切换已登记的 NAS 存储目录',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == '__refresh') {
          unawaited(_refreshRoots());
        } else {
          unawaited(_chooseRoot(value));
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text('当前位置：${widget.api.selectedRoot?.name ?? '默认共享目录'}'),
        ),
        const PopupMenuItem<String>(value: '', child: Text('默认共享目录')),
        ..._roots.map(
          (root) => PopupMenuItem<String>(
            value: root.id,
            enabled: root.online,
            child: Text('${root.name}${root.online ? '' : ' · 离线'}'),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '__refresh',
          enabled: !_rootsLoading,
          child: Text(_rootsLoading ? '正在检查…' : '刷新共享目录状态'),
        ),
      ],
      child: KeyedSubtree(
        key: const ValueKey('shellRootPickerSurface'),
        child: surface,
      ),
    );
  }

  PreferredSizeWidget _macUnifiedToolbar({
    required bool canExtendRail,
    required bool extendedRail,
    required double availableWidth,
    required double textScale,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // AppKit's native window controls occupy the first ~80 points of the
    // full-size titlebar. Never draw interactive Flutter widgets beneath them.
    final compact = availableWidth < 720 || textScale > 1.45;
    return PreferredSize(
      preferredSize: const Size.fromHeight(52),
      child: Container(
        key: const ValueKey('macUnifiedToolbar'),
        height: 52,
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: .34),
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .26),
              width: .6,
            ),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 91,
              key: ValueKey('macTrafficLightClearance'),
            ),
            if (canExtendRail)
              IconButton(
                key: const ValueKey('macSidebarToggle'),
                tooltip: extendedRail ? '收起侧栏' : '展开侧栏',
                onPressed: () =>
                    _updateState(() => _railExpanded = !_railExpanded),
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                style: IconButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  hoverColor: scheme.onSurface.withValues(alpha: .06),
                ),
                icon: Icon(
                  extendedRail
                      ? Icons.view_sidebar_rounded
                      : Icons.view_sidebar_outlined,
                ),
              ),
            if (canExtendRail) const SizedBox(width: 4),
            const IsleBrandMark(size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                compact
                    ? _ClientShellState._labels[_index]
                    : '轻屿  /  ${_ClientShellState._labels[_index]}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withValues(alpha: .86),
                ),
              ),
            ),
            _rootPicker(
              unified: true,
              showName: !compact && availableWidth >= 820,
            ),
            const SizedBox(width: 6),
            _taskButton(unified: true),
            const SizedBox(width: 6),
            _accountButton(unified: true),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
