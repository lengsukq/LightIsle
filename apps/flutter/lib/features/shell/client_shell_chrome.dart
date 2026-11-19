part of 'client_shell.dart';

extension _ClientShellChrome on _ClientShellState {
  bool get _isMobileTouchPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Color _activeSectionColor(BuildContext context) {
    final palette = IslePalette.of(context);
    if (_showingDashboardFiles && _index == 0) {
      return palette['brandAmber'];
    }
    return switch (_index) {
      0 => palette['accentPrimary'],
      1 => palette['brandRose'],
      2 => palette['brandTerracotta'],
      _ => palette['brandViolet'],
    };
  }

  Widget _taskButton({bool unified = false}) => ListenableBuilder(
    listenable: _uploadCenter,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final palette = IslePalette.of(context);
      final unfinished = _uploadCenter.unfinished;
      final touchMin = (!unified && _isMobileTouchPlatform) ? 42.0 : 32.0;
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
              child: AnimatedContainer(
                duration: IsleMotion.reducedMotion(context)
                    ? Duration.zero
                    : IsleMotion.quick,
                curve: IsleMotion.silk,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
                decoration: IsleDecorations.capsuleControl(
                  context,
                  selected: unfinished > 0,
                  accent: palette['brandAmber'],
                ),
                child: Badge(
                  isLabelVisible: unfinished > 0,
                  label: Text('$unfinished'),
                  backgroundColor: palette['brandAmber'],
                  textColor: Colors.white,
                  child: Icon(
                    Icons.swap_vert_rounded,
                    size: 18,
                    color: unfinished > 0
                        ? palette['brandAmber']
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
    final palette = IslePalette.of(context);
    final rawName = widget.identity['username']?.toString().trim() ?? '';
    final initial = rawName.isNotEmpty
        ? rawName.characters.first.toUpperCase()
        : '';
    final touchMin = (!unified && _isMobileTouchPlatform) ? 42.0 : 32.0;

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
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.all(4.5),
              decoration: IsleDecorations.capsuleControl(
                context,
                selected: _index == 3,
                accent: palette['brandViolet'],
              ),
              child: initial.isNotEmpty
                  ? Container(
                      width: 21,
                      height: 21,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            scheme.primary.withValues(alpha: 0.22),
                            palette['brandAmber'].withValues(alpha: 0.18),
                          ],
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        initial,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface,
                          height: 1.1,
                        ),
                      ),
                    )
                  : Icon(
                      Icons.person_rounded,
                      size: 18,
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
      padding: const EdgeInsets.all(20),
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
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final dark = style.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 14, 6),
          decoration: BoxDecoration(
            color: style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal ||
                    style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline
                ? palette['chrome']
                : palette['chrome'].withValues(alpha: dark ? 0.72 : 0.88),
            border: Border(
              bottom: BorderSide(
                color: style.rimBorderColor(),
                width: style.effectiveBorderWidth(),
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
                accent: palette['brandAmber'],
                onPressed: () => _updateState(() {
                  _showingDashboardFiles = false;
                  _fileEntryOverride = null;
                }),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.folder_open_rounded,
                size: 16,
                color: palette['brandAmber'],
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '文件工作台 · ${widget.api.selectedRoot?.name ?? (_admin ? '默认目录' : '个人存储')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
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
    final palette = IslePalette.of(context);
    final selectedName =
        widget.api.selectedRoot?.name ?? (_admin ? '默认目录' : '个人存储');
    final surface = Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: EdgeInsets.symmetric(
        horizontal: showName ? 10.5 : 8,
        vertical: 4.5,
      ),
      decoration: IsleDecorations.capsuleControl(
        context,
        danger: _rootsError != null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_rootsLoading)
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _rootsError != null
                    ? scheme.error
                    : palette['brandSage'],
              ),
            ),
          const SizedBox(width: 6),
          Icon(
            _rootsError != null
                ? Icons.sync_problem_rounded
                : Icons.storage_rounded,
            size: 15,
            color: _rootsError != null ? scheme.error : scheme.onSurfaceVariant,
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
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: -0.15,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              _admin ? Icons.expand_more_rounded : Icons.refresh_rounded,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              size: 15,
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
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final dark = style.dark;
    final isOpaque = IsleLayout.opaqueNavigation(context) ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final compact = availableWidth < 720 || textScale > 1.45;
    final sectionColor = _activeSectionColor(context);
    final activeTitle = _showingDashboardFiles && _index == 0
        ? '文件管理'
        : _ClientShellState._labels[_index];

    return PreferredSize(
      preferredSize: const Size.fromHeight(52),
      child: RepaintBoundary(
        child: IsleGlassBackdrop(
          blur: isOpaque ? 0 : IsleGlass.sigmaRegular,
          child: Container(
            key: const ValueKey('macUnifiedToolbar'),
            height: 52,
            decoration: BoxDecoration(
              color: isOpaque
                  ? palette['chrome']
                  : IsleGlass.regularTint(dark, palette['chrome']),
              border: Border(
                bottom: BorderSide(
                  color: style.rimBorderColor(),
                  width: style.effectiveBorderWidth(),
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
                    iconSize: 19,
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
                const SizedBox(width: 9),
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
                      child: Row(
                        children: [
                          if (!compact) ...[
                            Text(
                              '轻屿',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2,
                                    color: scheme.onSurface,
                                  ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 7),
                              child: AnimatedContainer(
                                duration: IsleMotion.reducedMotion(context)
                                    ? Duration.zero
                                    : IsleMotion.quick,
                                curve: IsleMotion.silk,
                                width: 4.5,
                                height: 4.5,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: sectionColor,
                                ),
                              ),
                            ),
                          ],
                          Flexible(
                            child: AnimatedSwitcher(
                              duration: IsleMotion.reducedMotion(context)
                                  ? Duration.zero
                                  : IsleMotion.fast,
                              switchInCurve: IsleMotion.gentleSpring,
                              switchOutCurve: IsleMotion.exitCurve,
                              layoutBuilder: (currentChild, previousChildren) =>
                                  Stack(
                                    alignment: Alignment.centerLeft,
                                    children: <Widget>[
                                      ...previousChildren,
                                      ?currentChild,
                                    ],
                                  ),
                              transitionBuilder: (child, anim) => FadeTransition(
                                opacity: anim,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.16),
                                    end: Offset.zero,
                                  ).animate(anim),
                                  child: child,
                                ),
                              ),
                              child: Text(
                                activeTitle,
                                key: ValueKey<String>(activeTitle),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: sectionColor,
                                    ),
                              ),
                            ),
                          ),
                        ],
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

  Widget _buildRailDock(BuildContext context, {required bool extendedRail}) {
    final activeTone = _activeSectionColor(context);
    final palette = IslePalette.of(context);
    final showCompanionFilesOrb =
        MediaQuery.sizeOf(context).height >= 540 && !extendedRail;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IsleFloatingRailDock(
          child: NavigationRailTheme(
            data: NavigationRailThemeData(
              backgroundColor: Colors.transparent,
              indicatorColor: activeTone.withValues(alpha: 0.15),
              indicatorShape: IsleShapes.sm(),
              selectedIconTheme: IconThemeData(
                size: 20.5,
                color: activeTone,
              ),
              unselectedIconTheme: IconThemeData(
                size: 19.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              selectedLabelTextStyle: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: activeTone,
                  ),
              unselectedLabelTextStyle: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(
                    fontSize: 12.5,
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
                minWidth: 64,
                minExtendedWidth: 184,
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
        ),
        if (showCompanionFilesOrb)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Tooltip(
              message: '直达文件工作台',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: IsleRadius.brPill,
                  onTap: _openDashboardFiles,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: IsleDecorations.capsuleControl(
                      context,
                      selected: _showingDashboardFiles && _index == 0,
                      accent: palette['brandAmber'],
                    ),
                    child: Icon(
                      Icons.folder_rounded,
                      size: 19,
                      color: _showingDashboardFiles && _index == 0
                          ? palette['brandAmber']
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomNavDock(
    BuildContext context, {
    required double maxWidth,
    required double textScale,
  }) {
    final style = IsleThemeStyle.of(context);
    final activeTone = _activeSectionColor(context);
    final indicatorShape = style.preset.cornerStyle == IsleCornerStyle.sharp
        ? style.shapeFor(IsleRadius.sm)
        : style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal
        ? StadiumBorder(
            side: BorderSide(color: style.rimBorderColor(), width: 1.5),
          )
        : const StadiumBorder();
    return IsleFloatingBottomNavDock(
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.transparent,
          elevation: 0,
          indicatorColor: activeTone.withValues(alpha: 0.15),
          indicatorShape: indicatorShape,
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return IconThemeData(size: 20.5, color: activeTone);
            }
            return IconThemeData(
              size: 19.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.78),
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: activeTone,
              );
            }
            return Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.78),
            );
          }),
        ),
        child: NavigationBar(
          height: 50,
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
                color: activeTone,
              ),
              label: _ClientShellState._labels[i],
            ),
          ),
        ),
      ),
    );
  }
}
