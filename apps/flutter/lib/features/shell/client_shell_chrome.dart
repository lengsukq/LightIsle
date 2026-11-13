part of 'client_shell.dart';

extension _ClientShellChrome on _ClientShellState {
  bool get _isMobileTouchPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Widget _taskButton({bool unified = false}) => ListenableBuilder(
    listenable: _uploadCenter,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final unfinished = _uploadCenter.unfinished;
      final touchMin = (!unified && _isMobileTouchPlatform) ? 44.0 : 34.0;
      return Tooltip(
        message: '传输任务（未结束 $unfinished）',
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: touchMin, minHeight: touchMin),
          child: Center(
            child: InkWell(
              key: const ValueKey('globalUploadTaskCenter'),
              borderRadius: IsleRadius.brPill,
              onTap: () => Navigator.of(context).push(
                buildIslePageRoute<void>(
                  builder: (_) => UploadTaskCenterPage(center: _uploadCenter),
                ),
              ),
              child: Container(
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: IsleDecorations.capsuleControl(
                  context,
                  selected: unfinished > 0,
                ),
                child: Badge(
                  isLabelVisible: unfinished > 0,
                  label: Text('$unfinished'),
                  backgroundColor: scheme.primary,
                  textColor: scheme.onPrimary,
                  child: Icon(
                    Icons.swap_vert_rounded,
                    size: 19,
                    color: unfinished > 0
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
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
    final initial = rawName.isNotEmpty
        ? rawName.characters.first.toUpperCase()
        : '';
    final touchMin = (!unified && _isMobileTouchPlatform) ? 44.0 : 34.0;

    return Tooltip(
      message: '设置与账号${rawName.isNotEmpty ? '（$rawName）' : ''}',
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: touchMin, minHeight: touchMin),
        child: Center(
          child: InkWell(
            key: const ValueKey('macAccountButton'),
            borderRadius: IsleRadius.brPill,
            onTap: () => _select(3),
            child: Container(
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: const EdgeInsets.all(5),
              decoration: IsleDecorations.capsuleControl(context),
              child: initial.isNotEmpty
                  ? Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
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
        ),
      ),
    );
  }

  Widget _buildRouteErrorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: IsleEmptyStateCard(
        _personalRouteError!,
        icon: Icons.storage_rounded,
        title: '存储目录暂不可用',
        action: IslePillButton(
          label: '重新检查并恢复浏览',
          icon: Icons.refresh_rounded,
          variant: IslePillVariant.primary,
          onPressed: _rootsLoading ? null : _refreshRoots,
        ),
      ),
    ),
  );

  Widget _buildDashboardFilesContainer() {
    if (_personalRouteError != null && _manualRootSection != 0) {
      return _buildRouteErrorView();
    }
    final filesRoute = _routeForCategory('files');
    final resolvedInitialPath =
        _fileEntryOverride ??
        (filesRoute.kind == PersonalRouteKind.personal &&
                _manualRootSection != 0
            ? filesRoute.path!
            : '.');
    final expectedKey = ValueKey<String>(
      'root:${widget.api.selectedRoot?.identity ?? 'default'}:files:$resolvedInitialPath',
    );
    if (_dashboardFilesWidget?.key != expectedKey) {
      _dashboardFilesWidget = KeyedSubtree(
        key: expectedKey,
        child: FilesPage(
          api: widget.api,
          taskCenter: _uploadCenter,
          isAdmin: _admin,
          accountName: widget.identity['username']?.toString() ?? '',
          initialPath: resolvedInitialPath,
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 14, 6),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: dark ? 0.50 : 0.68),
            border: Border(
              bottom: BorderSide(
                color: IsleGlass.rimBorderColor(dark),
                width: 0.6,
              ),
            ),
          ),
          child: Row(
            children: [
              IslePillButton(
                key: const ValueKey('backToDashboardFromFiles'),
                label: '返回仪表盘',
                icon: Icons.arrow_back_ios_new_rounded,
                compact: true,
                onPressed: () => _updateState(() {
                  _showingDashboardFiles = false;
                  _fileEntryOverride = null;
                }),
              ),
              const SizedBox(width: 10),
              Icon(Icons.folder_open_rounded, size: 16, color: scheme.primary),
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
      padding: EdgeInsets.symmetric(horizontal: showName ? 11 : 8, vertical: 5),
      decoration: IsleDecorations.capsuleControl(
        context,
        danger: _rootsError != null,
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
              size: 16.5,
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
              _admin ? Icons.expand_more_rounded : Icons.refresh_rounded,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              size: 16,
            ),
          ],
        ],
      ),
    );

    if (!_admin) {
      return Tooltip(
        message: '刷新当前账号的存储分配与连接状态',
        child: InkWell(
          key: const ValueKey('shellRootPickerSurface'),
          borderRadius: IsleRadius.brPill,
          onTap: _rootsLoading ? null : () => unawaited(_refreshRoots()),
          child: surface,
        ),
      );
    }

    return PopupMenuButton<String>(
      key: const ValueKey('shellRootPicker'),
      tooltip: '查看或切换已登记的 NAS 存储目录',
      shape: IsleShapes.item(),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final compact = availableWidth < 720 || textScale > 1.45;
    return PreferredSize(
      preferredSize: const Size.fromHeight(52),
      child: RepaintBoundary(
        child: IsleGlassBackdrop(
          blur: IsleGlass.sigmaRegular,
          child: Container(
            key: const ValueKey('macUnifiedToolbar'),
            height: 52,
            decoration: BoxDecoration(
              color: IsleLayout.opaqueNavigation(context)
                  ? scheme.surface
                  : IsleGlass.regularTint(dark, scheme.surface),
              border: Border(
                bottom: BorderSide(
                  color: IsleGlass.rimBorderColor(dark),
                  width: 0.6,
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
                      hoverColor: scheme.onSurface.withValues(alpha: 0.06),
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
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => unawaited(
                      const MethodChannel('lightisle/native-video')
                          .invokeMethod<void>('startWindowDrag')
                          .catchError((_) {}),
                    ),
                    onDoubleTap: () => unawaited(
                      const MethodChannel('lightisle/native-video')
                          .invokeMethod<void>('doubleClickTitlebar')
                          .catchError((_) {}),
                    ),
                    child: SizedBox(
                      height: 52,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          compact
                              ? _ClientShellState._labels[_index]
                              : '轻屿  /  ${_ClientShellState._labels[_index]}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface.withValues(alpha: 0.88),
                              ),
                        ),
                      ),
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
        ),
      ),
    );
  }

  Widget _wrapMacPlatformMenus(Widget content) => PlatformMenuBar(
    menus: [
      PlatformMenu(
        label: '轻屿',
        menus: [
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.about,
          ),
          PlatformMenuItem(
            label: '设置…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.comma,
              meta: true,
            ),
            onSelected: () => _select(3),
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.quit,
          ),
        ],
      ),
      PlatformMenu(
        label: '前往',
        menus: [
          ...List.generate(
            _ClientShellState._labels.length,
            (i) => PlatformMenuItem(
              label: _ClientShellState._labels[i],
              onSelected: () => _select(i),
            ),
          ),
          PlatformMenuItem(label: '文件管理', onSelected: _openDashboardFiles),
        ],
      ),
      PlatformMenu(
        label: '编辑',
        menus: [
          for (final command in <(String, Intent, LogicalKeyboardKey)>[
            (
              '剪切',
              const CopySelectionTextIntent.cut(SelectionChangedCause.toolbar),
              LogicalKeyboardKey.keyX,
            ),
            ('复制', CopySelectionTextIntent.copy, LogicalKeyboardKey.keyC),
            (
              '粘贴',
              const PasteTextIntent(SelectionChangedCause.toolbar),
              LogicalKeyboardKey.keyV,
            ),
            (
              '全选',
              const SelectAllTextIntent(SelectionChangedCause.toolbar),
              LogicalKeyboardKey.keyA,
            ),
          ])
            PlatformMenuItem(
              label: command.$1,
              shortcut: SingleActivator(command.$3, meta: true),
              onSelected: () {
                final focusContext =
                    FocusManager.instance.primaryFocus?.context;
                if (focusContext != null) {
                  Actions.maybeInvoke(focusContext, command.$2);
                }
              },
            ),
        ],
      ),
    ],
    child: content,
  );

  Widget _buildRailDock(BuildContext context, {required bool extendedRail}) =>
      IsleFloatingRailDock(
        child: NavigationRailTheme(
          data: NavigationRailThemeData(
            backgroundColor: Colors.transparent,
            indicatorColor: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.16),
            indicatorShape: IsleShapes.md(),
            selectedIconTheme: IconThemeData(
              color: Theme.of(context).colorScheme.primary,
            ),
            selectedLabelTextStyle: Theme.of(context).textTheme.labelMedium
                ?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
            unselectedLabelTextStyle: Theme.of(context).textTheme.labelMedium
                ?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          child: AnimatedSize(
            duration: IsleMotion.reducedMotion(context)
                ? Duration.zero
                : IsleMotion.normal,
            curve: IsleMotion.curve,
            alignment: Alignment.centerLeft,
            child: NavigationRail(
              selectedIndex: _index,
              extended: extendedRail,
              minWidth: 72,
              minExtendedWidth: 190,
              labelType: NavigationRailLabelType.none,
              onDestinationSelected: _select,
              destinations: List.generate(
                _ClientShellState._labels.length,
                (i) => NavigationRailDestination(
                  icon: Icon(_ClientShellState._sectionThemes[i].icon),
                  label: Text(_ClientShellState._labels[i]),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _buildBottomNavDock(
    BuildContext context, {
    required double maxWidth,
    required double textScale,
  }) => IsleFloatingBottomNavDock(
    child: NavigationBarTheme(
      data: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        indicatorColor: Theme.of(context).colorScheme.primary
            .withValues(alpha: 0.14),
        indicatorShape: const StadiumBorder(),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(
              size: 22,
              color: Theme.of(context).colorScheme.primary,
            );
          }
          return IconThemeData(
            size: 21,
            color: Theme.of(context).colorScheme.onSurfaceVariant
                .withValues(alpha: 0.72),
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            );
          }
          return Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurfaceVariant
                .withValues(alpha: 0.72),
          );
        }),
      ),
      child: NavigationBar(
        height: 52,
        labelBehavior: maxWidth < 360 && textScale > 1.4
            ? NavigationDestinationLabelBehavior.alwaysHide
            : NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: List.generate(
          _ClientShellState._labels.length,
          (i) => NavigationDestination(
            tooltip: _ClientShellState._labels[i],
            icon: Icon(_ClientShellState._sectionThemes[i].icon),
            selectedIcon: Icon(
              _ClientShellState._sectionThemes[i].icon,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: _ClientShellState._labels[i],
          ),
        ),
      ),
    ),
  );
}
