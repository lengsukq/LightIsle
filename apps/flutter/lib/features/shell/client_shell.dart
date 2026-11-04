import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/personal_storage_routing.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../files/files_page.dart';
import '../files/upload_task_center.dart';
import '../files/upload_task_center_page.dart';
import '../media/photos_page.dart';
import '../media/cinema_page.dart';
import '../overview/overview_page.dart';
import '../settings/settings_page.dart';

class ClientShell extends StatefulWidget {
  const ClientShell({
    super.key,
    required this.api,
    required this.identity,
    required this.onLogout,
  });
  final LightIsleApi api;
  final Map<String, dynamic> identity;
  final Future<void> Function() onLogout;
  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell> {
  late final UploadTaskCenter _uploadCenter;
  int _index = 0;
  // Match the native Mac management dock: compact icons by default.
  bool _railExpanded = false;
  final Map<int, Widget> _pages = {};
  // Store only scroll positions, never mounted root-scoped pages or media
  // bytes. Each PageStorageKey includes the physical root generation.
  final PageStorageBucket _browseStateBucket = PageStorageBucket();
  String? _fileEntryOverride;
  Map<String, dynamic>? _myStoragePolicy;
  String? _personalRouteError;
  int? _manualRootSection;
  List<LightIsleRoot> _roots = const [];
  bool _rootsLoading = false;
  String? _rootsError;
  @override
  void initState() {
    super.initState();
    _uploadCenter = UploadTaskCenter(
      api: widget.api,
      accountName: widget.identity['username']?.toString() ?? '',
      userId: widget.identity['id'] is int ? widget.identity['id'] as int : 0,
      isAdmin: widget.identity['role'] == 'admin',
    );
    unawaited(_refreshRoots());
  }

  Widget _taskButton() => ListenableBuilder(
    listenable: _uploadCenter,
    builder: (context, _) => IconButton(
      key: const ValueKey('globalUploadTaskCenter'),
      tooltip: '传输任务（未结束 ${_uploadCenter.unfinished}）',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UploadTaskCenterPage(center: _uploadCenter),
        ),
      ),
      icon: Badge(
        isLabelVisible: _uploadCenter.unfinished > 0,
        label: Text('${_uploadCenter.unfinished}'),
        child: const Icon(Icons.sync_alt_rounded),
      ),
    ),
  );

  @override
  void dispose() {
    _uploadCenter.dispose();
    super.dispose();
  }

  Future<void> _refreshRoots() async {
    if (_rootsLoading) return;
    setState(() {
      _rootsLoading = true;
      _rootsError = null;
    });
    try {
      final response = await widget.api.get('/api/v2/roots');
      final raw = response['roots'];
      if (raw is! List) throw const FormatException('共享目录列表无效。');
      final roots = raw
          .map(
            (item) =>
                LightIsleRoot.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
      final defaultRoot = roots
          .where((root) => root.isDefault && root.online)
          .firstOrNull;
      final policy = await widget.api.get('/api/v2/me/storage');
      if (!mounted) return;
      final old = widget.api.selectedRoot;
      final isCurrent =
          old == null ||
          roots.any((root) => root.identity == old.identity && root.online);
      if (!isCurrent) widget.api.selectRoot(null);
      if (old == null && defaultRoot != null) {
        widget.api.selectRoot(defaultRoot);
      }
      setState(() {
        _roots = roots;
        _myStoragePolicy = policy;
        if (!isCurrent) {
          // Never silently show another drive's files after the previously
          // selected physical root is detached or its generation changes.
          _fileEntryOverride = null;
          _manualRootSection = null;
          _personalRouteError = '原存储卷已离线或更换。请重新选择已授权的存储目录。';
          _pages.clear();
        }
      });
      // Restore persisted uploads independently. The dashboard / storage
      // connection must not stay in a loading state while local picker
      // metadata or a platform preference service is unavailable.
      unawaited(_uploadCenter.restore(roots, policy));
      if (isCurrent || _index != 1) _applyPersonalRoute(_index);
      if (!isCurrent) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('原共享目录已离线或更换，请重新选择目录。')));
      }
    } on LightIsleApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _rootsError = error.statusCode == 404
            ? 'NAS 服务不支持 v2 多硬盘接口，请更新 Mac 端后重试。'
            : error.message;
        _personalRouteError = '无法确认个人目录位置，请检查 NAS 状态后重试。';
        _pages.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _rootsError = '读取共享目录失败，请重试：$error';
          _personalRouteError = '个人存储配置暂不可用，请重试。';
          _pages.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _rootsLoading = false);
    }
  }

  Future<void> _chooseRoot(String id) async {
    if (!_admin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('个人存储由管理员分配，请从文件、图库或影视进入对应目录。')),
      );
      return;
    }
    final chosen = id.isEmpty
        ? _roots.where((root) => root.isDefault && root.online).firstOrNull
        : _roots.where((r) => r.id == id).firstOrNull;
    if (id.isNotEmpty && (chosen == null || !chosen.online)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该共享目录不可用，请检查硬盘连接。')));
      return;
    }
    if (widget.api.selectedRoot?.identity == chosen?.identity) return;
    if (!await confirmAction(
      context,
      '切换共享目录',
      '切换将关闭当前文件传输、照片和视频页面。请先确认上传或下载任务已完成。',
      action: '切换目录',
    )) {
      return;
    }
    if (!mounted) return;
    widget.api.selectRoot(chosen);
    setState(() {
      _manualRootSection = _index;
      _fileEntryOverride = null;
      _personalRouteError = null;
      _pages.clear();
    });
  }

  void _browseAssignedDirectory(LightIsleRoot? requested, String directory) {
    final known = requested == null
        ? _roots.where((root) => root.isDefault && root.online).firstOrNull
        : _roots
              .where(
                (root) => root.identity == requested.identity && root.online,
              )
              .firstOrNull;
    final allowed = _admin
        ? directory == '.' && (requested == null || known != null)
        : known != null &&
              [1, 2, 3].any((section) {
                final assigned = _routeFor(section);
                return assigned.kind == PersonalRouteKind.personal &&
                    assigned.root?.identity == known.identity &&
                    assigned.path == directory;
              });
    if (!allowed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有此目录的访问权限，或该存储卷已离线。请刷新后重试。')),
      );
      return;
    }
    // Reuse the exact same file manager and generation-bound API as the
    // Files tab. The caller never supplies a physical macOS mount path.
    widget.api.selectRoot(known);
    HapticFeedback.selectionClick();
    setState(() {
      _index = 1;
      _manualRootSection = 1;
      _fileEntryOverride = directory;
      _personalRouteError = null;
      _pages.clear();
    });
  }

  PersonalStorageRoute _routeFor(int index) =>
      resolvePersonalRoute(_myStoragePolicy, _roots, switch (index) {
        1 => 'files',
        2 => 'photos',
        3 => 'cinema',
        _ => '',
      });

  void _applyPersonalRoute(int index) {
    if (_manualRootSection == index) return;
    if (index < 1 || index > 3) return;
    if (_myStoragePolicy == null) {
      setState(() {
        _personalRouteError = '无法读取个人硬盘配置，请刷新共享目录。';
        _pages.clear();
      });
      return;
    }
    final route = _routeFor(index);
    if (route.kind == PersonalRouteKind.offline) {
      setState(() {
        _personalRouteError = '该分类绑定的硬盘离线或已更换。请连接原硬盘，或在 Mac 管理端手动重建。';
        _pages.clear();
      });
      return;
    }
    final target = route.kind == PersonalRouteKind.personal
        ? route.root
        : _roots.where((root) => root.isDefault && root.online).firstOrNull;
    if (widget.api.selectedRoot?.identity != target?.identity) {
      widget.api.selectRoot(target);
      setState(() => _pages.clear());
    }
    if (_personalRouteError != null) {
      setState(() {
        _personalRouteError = null;
        _pages.clear();
      });
    }
  }

  static const _labels = ['概览', '文件', '图库', '影视', '设置'];
  static const _sectionThemes = [
    IsleSectionTheme.overview,
    IsleSectionTheme.files,
    IsleSectionTheme.photos,
    IsleSectionTheme.cinema,
    IsleSectionTheme.settings,
  ];
  bool get _admin => widget.identity['role'] == 'admin';
  // Never eagerly mount inactive tabs against the shared session client:
  // their initState requests would inherit whichever physical disk happens
  // to be selected by the visible tab.
  Widget _page(int index) {
    if (index != _index) return const SizedBox.shrink();
    return PageStorage(
      bucket: _browseStateBucket,
      child: _pages.putIfAbsent(
        index,
        () => KeyedSubtree(
          key: ValueKey(
            'root:${widget.api.selectedRoot?.identity ?? 'default'}:$index',
          ),
          child:
              _personalRouteError != null &&
                  index == _index &&
                  index >= 1 &&
                  index <= 3 &&
                  _manualRootSection != index
              ? Center(
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
                          label: const Text('重新检查'),
                        ),
                      ],
                    ),
                  ),
                )
              : switch (index) {
                  0 => OverviewPage(
                    api: widget.api,
                    isAdmin: _admin,
                    onNavigate: _select,
                    onBrowseDirectory: _browseAssignedDirectory,
                  ),
                  1 => FilesPage(
                    api: widget.api,
                    taskCenter: _uploadCenter,
                    isAdmin: _admin,
                    accountName: widget.identity['username']?.toString() ?? '',
                    initialPath:
                        _fileEntryOverride ??
                        (_routeFor(1).kind == PersonalRouteKind.personal &&
                                _manualRootSection != 1
                            ? _routeFor(1).path!
                            : '.'),
                    showPhotoBackup: false,
                  ),
                  2 => PhotosPage(
                    api: widget.api,
                    taskCenter: _uploadCenter,
                    isAdmin: _admin,
                    accountName: widget.identity['username']?.toString() ?? '',
                    offlineAccountId:
                        widget.identity['id'] is int &&
                            (widget.identity['id'] as int) > 0
                        ? 'uid:${widget.identity['id']}'
                        : '',
                    canBackup:
                        _manualRootSection != 2 &&
                        _routeFor(2).kind == PersonalRouteKind.personal,
                    uploadDirectory:
                        _manualRootSection != 2 &&
                            _routeFor(2).kind == PersonalRouteKind.personal
                        ? _routeFor(2).path!
                        : '图库',
                    backupDirectory:
                        _routeFor(2).kind == PersonalRouteKind.personal &&
                            _manualRootSection != 2
                        ? _routeFor(2).path!
                        : 'PhonePhotos',
                  ),
                  3 => CinemaPage(
                    api: widget.api,
                    taskCenter: _uploadCenter,
                    isAdmin: _admin,
                    // A stable, server-issued ID prevents re-created usernames
                    // from inheriting a former account's offline downloads.
                    accountName:
                        widget.identity['id'] is int &&
                            (widget.identity['id'] as int) > 0
                        ? 'uid:${widget.identity['id']}'
                        : '',
                    uploadDirectory:
                        _manualRootSection != 3 &&
                            _routeFor(3).kind == PersonalRouteKind.personal
                        ? _routeFor(3).path!
                        : '影视',
                  ),
                  _ => SettingsPage(
                    api: widget.api,
                    identity: widget.identity,
                    onLogout: widget.onLogout,
                    pendingUploads: () => _uploadCenter.unfinished,
                  ),
                },
        ),
      ),
    );
  }

  void _select(int index) {
    if (_index != index) {
      HapticFeedback.selectionClick();
      setState(() {
        _index = index;
        _manualRootSection = null;
        _fileEntryOverride = null;
        _pages.clear();
      });
      _applyPersonalRoute(index);
    }
  }

  Widget _rootPicker({required bool showName, bool unified = false}) {
    final scheme = Theme.of(context).colorScheme;
    final selectedName =
        widget.api.selectedRoot?.name ?? (_admin ? '默认目录' : '个人存储');
    final surface = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: EdgeInsets.symmetric(horizontal: unified ? 10 : 8, vertical: 6),
      decoration: unified
          ? BoxDecoration(
              color: scheme.onSurface.withValues(alpha: .045),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .38),
              ),
              borderRadius: BorderRadius.circular(11),
            )
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_rootsLoading)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          else
            Icon(
              _rootsError != null
                  ? Icons.sync_problem_rounded
                  : Icons.dns_outlined,
              size: unified ? 17 : 21,
              color: _rootsError != null
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          if (showName) ...[
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                selectedName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              _admin
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.refresh_rounded,
              color: scheme.onSurfaceVariant,
              size: 17,
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
          borderRadius: BorderRadius.circular(11),
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
                onPressed: () => setState(() => _railExpanded = !_railExpanded),
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
                compact ? _labels[_index] : '轻屿  /  ${_labels[_index]}',
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
            _taskButton(),
            const SizedBox(width: 6),
            IconButton(
              key: const ValueKey('macAccountButton'),
              tooltip: '设置与账号',
              onPressed: () => _select(4),
              visualDensity: VisualDensity.compact,
              iconSize: 21,
              style: IconButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                hoverColor: scheme.onSurface.withValues(alpha: .06),
              ),
              icon: const Icon(Icons.account_circle_outlined),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
          _select(4),
      if (defaultTargetPlatform == TargetPlatform.macOS)
        const SingleActivator(
          LogicalKeyboardKey.keyS,
          meta: true,
          control: true,
        ): () =>
            setState(() => _railExpanded = !_railExpanded),
      for (var i = 0; i < 5; i++)
        SingleActivator(
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
            LogicalKeyboardKey.digit5,
          ][i],
          meta: (defaultTargetPlatform == TargetPlatform.macOS),
          control: !(defaultTargetPlatform == TargetPlatform.macOS),
        ): () =>
            _select(i),
    };
    Widget content = CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desktop = switch (defaultTargetPlatform) {
              TargetPlatform.macOS ||
              TargetPlatform.windows ||
              TargetPlatform.linux => true,
              _ => false,
            };
            final rail = IsleLayout.useRail(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              desktop: desktop,
            );
            _page(_index);
            final animatedBody = IsleFluidTabSwitcher(
              index: _index,
              children: List.generate(5, (i) => _page(i)),
            );
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final canExtendRail = IsleLayout.extendedRail(
              width: constraints.maxWidth,
              textScale: textScale,
              expanded: true,
            );
            final extendedRail = canExtendRail && _railExpanded;
            return Scaffold(
              extendBody: !rail,
              backgroundColor: Colors.transparent,
              appBar: defaultTargetPlatform == TargetPlatform.macOS
                  ? _macUnifiedToolbar(
                      canExtendRail: canExtendRail,
                      extendedRail: extendedRail,
                      availableWidth: constraints.maxWidth,
                      textScale: textScale,
                    )
                  : AppBar(
                      backgroundColor: Colors.transparent,
                      toolbarHeight: rail ? 44 : 54,
                      title: Row(
                        children: [
                          if (!rail) ...[
                            const IsleBrandMark(size: 27),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                constraints.maxWidth >= 610
                                    ? '轻屿 LightIsle'
                                    : '轻屿',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                          if (rail && canExtendRail)
                            IconButton(
                              tooltip: extendedRail ? '收起侧栏' : '展开侧栏',
                              onPressed: () => setState(
                                () => _railExpanded = !_railExpanded,
                              ),
                              icon: Icon(
                                extendedRail
                                    ? Icons.menu_open_rounded
                                    : Icons.menu_rounded,
                              ),
                            ),
                        ],
                      ),
                      actions: [
                        _rootPicker(showName: constraints.maxWidth >= 680),
                        _taskButton(),
                        IconButton(
                          tooltip: '设置与账号',
                          onPressed: () => _select(4),
                          icon: const Icon(Icons.account_circle_outlined),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
              body: SafeArea(
                top: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (rail)
                      IsleFloatingRailDock(
                        child: NavigationRailTheme(
                          data: NavigationRailThemeData(
                            backgroundColor: Colors.transparent,
                            indicatorColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.16),
                            indicatorShape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            selectedIconTheme: IconThemeData(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            selectedLabelTextStyle: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                            unselectedLabelTextStyle: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                          child: NavigationRail(
                            selectedIndex: _index,
                            extended: extendedRail,
                            minWidth: 72,
                            minExtendedWidth: 190,
                            labelType: NavigationRailLabelType.none,
                            onDestinationSelected: _select,
                            destinations: List.generate(
                              5,
                              (i) => NavigationRailDestination(
                                icon: Icon(_sectionThemes[i].icon),
                                label: Text(_labels[i]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(child: IsleContent(child: animatedBody)),
                  ],
                ),
              ),
              bottomNavigationBar:
                  rail || MediaQuery.viewInsetsOf(context).bottom > 0
                  ? null
                  : IsleFloatingBottomNavDock(
                      child: NavigationBarTheme(
                        data: NavigationBarThemeData(
                          backgroundColor: Colors.transparent,
                          elevation: 0,
                          indicatorColor: Colors.transparent,
                          indicatorShape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          iconTheme: WidgetStateProperty.resolveWith((states) {
                            if (states.contains(WidgetState.selected)) {
                              return IconThemeData(
                                size: 22,
                                color: Theme.of(context).colorScheme.primary,
                              );
                            }
                            return IconThemeData(
                              size: 21,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(alpha: 0.72),
                            );
                          }),
                          labelTextStyle: WidgetStateProperty.resolveWith((
                            states,
                          ) {
                            if (states.contains(WidgetState.selected)) {
                              return Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  );
                            }
                            return Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant
                                      .withValues(alpha: 0.72),
                                );
                          }),
                        ),
                        child: NavigationBar(
                          height: 60,
                          labelBehavior:
                              constraints.maxWidth < 360 && textScale > 1.4
                              ? NavigationDestinationLabelBehavior.alwaysHide
                              : NavigationDestinationLabelBehavior.alwaysShow,
                          selectedIndex: _index,
                          onDestinationSelected: _select,
                          destinations: List.generate(
                            5,
                            (i) => NavigationDestination(
                              tooltip: _labels[i],
                              icon: Icon(_sectionThemes[i].icon),
                              selectedIcon: Icon(
                                _sectionThemes[i].icon,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              label: _labels[i],
                            ),
                          ),
                        ),
                      ),
                    ),
            );
          },
        ),
      ),
    );
    if ((defaultTargetPlatform == TargetPlatform.macOS)) {
      content = PlatformMenuBar(
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
                onSelected: () => _select(4),
              ),
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.quit,
              ),
            ],
          ),
          PlatformMenu(
            label: '前往',
            menus: List.generate(
              5,
              (i) => PlatformMenuItem(
                label: _labels[i],
                onSelected: () => _select(i),
              ),
            ),
          ),
          PlatformMenu(
            label: '编辑',
            menus: [
              for (final command in <(String, Intent, LogicalKeyboardKey)>[
                (
                  '剪切',
                  const CopySelectionTextIntent.cut(
                    SelectionChangedCause.toolbar,
                  ),
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
    }
    return content;
  }
}
