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

part 'client_shell_chrome.dart';

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
  bool _showingDashboardFiles = false;
  // Match the native Mac management dock: compact icons by default.
  bool _railExpanded = false;
  final Map<int, Widget> _pages = {};
  Widget? _dashboardFilesWidget;
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

  void _updateState(VoidCallback fn) => setState(fn);

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
        if (isCurrent) _personalRouteError = null;
        if (!isCurrent) {
          // Never silently show another drive's files after the previously
          // selected physical root is detached or its generation changes.
          _fileEntryOverride = null;
          _manualRootSection = null;
          _personalRouteError = '原存储卷已离线或更换。请重新选择已授权的存储目录。';
          _pages.clear();
          _dashboardFilesWidget = null;
        }
      });
      // Restore persisted uploads independently. The dashboard / storage
      // connection must not stay in a loading state while local picker
      // metadata or a platform preference service is unavailable.
      unawaited(_uploadCenter.restore(roots, policy));
      if (isCurrent || _index != 0 || _showingDashboardFiles) {
        _applyPersonalRoute(_index);
      }
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
        // Preserve per-page view state during a transient network failure.
        // The error layer hides mounted content until the root is verified.
        // A genuinely changed physical root still clears pages above.
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _rootsError = '读取共享目录失败，请重试：$error';
          _personalRouteError = '个人存储配置暂不可用，请重试。';
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
      _dashboardFilesWidget = null;
    });
  }

  void _openDashboardFiles() {
    HapticFeedback.selectionClick();
    setState(() {
      _index = 0;
      _showingDashboardFiles = true;
      _manualRootSection = null;
      _fileEntryOverride = null;
      _dashboardFilesWidget = null;
    });
    _applyPersonalRoute(0);
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
              ['files', 'photos', 'cinema'].any((category) {
                final assigned = _routeForCategory(category);
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
    // Reuse the exact same file manager and generation-bound API inside the
    // Dashboard file workspace. The caller never supplies a physical macOS mount path.
    widget.api.selectRoot(known);
    HapticFeedback.selectionClick();
    setState(() {
      _index = 0;
      _showingDashboardFiles = true;
      _manualRootSection = 0;
      _fileEntryOverride = directory;
      _personalRouteError = null;
      _dashboardFilesWidget = null;
    });
  }

  PersonalStorageRoute _routeForCategory(String category) =>
      resolvePersonalRoute(_myStoragePolicy, _roots, category);

  String _categoryForSection(int index) {
    if (index == 0 && _showingDashboardFiles) return 'files';
    return switch (index) {
      1 => 'photos',
      2 => 'cinema',
      _ => '',
    };
  }

  void _applyPersonalRoute(int index) {
    if (_manualRootSection == index) return;
    final category = _categoryForSection(index);
    if (category.isEmpty) return;
    if (_myStoragePolicy == null) {
      setState(() {
        _personalRouteError = '无法读取个人硬盘配置，请刷新共享目录。';
      });
      return;
    }
    final route = _routeForCategory(category);
    if (route.kind == PersonalRouteKind.offline) {
      setState(() {
        _personalRouteError = '该分类绑定的硬盘离线或已更换。请连接原硬盘，或在 Mac 管理端手动重建。';
      });
      return;
    }
    final target = route.kind == PersonalRouteKind.personal
        ? route.root
        : _roots.where((root) => root.isDefault && root.online).firstOrNull;
    if (widget.api.selectedRoot?.identity != target?.identity) {
      widget.api.selectRoot(target);
      setState(() {
        _pages.clear();
        _dashboardFilesWidget = null;
      });
    }
    if (_personalRouteError != null) {
      setState(() => _personalRouteError = null);
    }
  }

  static const _labels = ['仪表盘', '相册', '影视', '设置'];
  static const _sectionThemes = [
    IsleSectionTheme.overview,
    IsleSectionTheme.photos,
    IsleSectionTheme.cinema,
    IsleSectionTheme.settings,
  ];
  bool get _admin => widget.identity['role'] == 'admin';

  // Lazy mount tabs on first visit, then keep visited tabs mounted in _pages
  // so IsleFluidTabSwitcher preserves scroll offsets, filter state, and
  // transition animations across tab switches.
  Widget _page(int index) {
    if (index == 0 && _showingDashboardFiles) {
      return _buildDashboardFilesContainer();
    }
    if (_personalRouteError != null &&
        (index == 1 || index == 2) &&
        _manualRootSection != index) {
      if (index != _index) return const SizedBox.shrink();
      return _buildRouteErrorView();
    }
    if (index != _index && !_pages.containsKey(index)) {
      return const SizedBox.shrink();
    }
    final photosRoute = _routeForCategory('photos');
    final cinemaRoute = _routeForCategory('cinema');
    return PageStorage(
      bucket: _browseStateBucket,
      child: _pages.putIfAbsent(
        index,
        () => KeyedSubtree(
          key: ValueKey(
            'root:${widget.api.selectedRoot?.identity ?? 'default'}:$index',
          ),
          child: switch (index) {
            0 => OverviewPage(
              api: widget.api,
              isAdmin: _admin,
              onNavigate: (target) {
                if (target < 0) {
                  _openDashboardFiles();
                } else {
                  _select(target);
                }
              },
              onOpenFiles: _openDashboardFiles,
              onBrowseDirectory: _browseAssignedDirectory,
            ),
            1 => PhotosPage(
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
                  _manualRootSection != 1 &&
                  photosRoute.kind == PersonalRouteKind.personal,
              uploadDirectory:
                  _manualRootSection != 1 &&
                      photosRoute.kind == PersonalRouteKind.personal
                  ? photosRoute.path!
                  : '图库',
              backupDirectory:
                  photosRoute.kind == PersonalRouteKind.personal &&
                      _manualRootSection != 1
                  ? photosRoute.path!
                  : 'PhonePhotos',
            ),
            2 => CinemaPage(
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
                  _manualRootSection != 2 &&
                      cinemaRoute.kind == PersonalRouteKind.personal
                  ? cinemaRoute.path!
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
    if (index < 0 || index >= _labels.length) return;
    if (_index == index && index == 0 && _showingDashboardFiles) {
      HapticFeedback.selectionClick();
      setState(() {
        _showingDashboardFiles = false;
        _fileEntryOverride = null;
      });
      return;
    }
    if (_index != index) {
      HapticFeedback.selectionClick();
      setState(() {
        _index = index;
        _showingDashboardFiles = false;
        _manualRootSection = null;
        _fileEntryOverride = null;
      });
      _applyPersonalRoute(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
          _select(3),
      if (defaultTargetPlatform == TargetPlatform.macOS)
        const SingleActivator(
          LogicalKeyboardKey.keyS,
          meta: true,
          control: true,
        ): () =>
            setState(() => _railExpanded = !_railExpanded),
      for (var i = 0; i < _labels.length; i++)
        SingleActivator(
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
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
              children: List.generate(_labels.length, (i) => _page(i)),
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
                      toolbarHeight: rail ? 44 : 48,
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
                        const SizedBox(width: 6),
                        _taskButton(),
                        const SizedBox(width: 6),
                        _accountButton(),
                        const SizedBox(width: 10),
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
                              _labels.length,
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
                          height: 52,
                          labelBehavior:
                              constraints.maxWidth < 360 && textScale > 1.4
                              ? NavigationDestinationLabelBehavior.alwaysHide
                              : NavigationDestinationLabelBehavior.alwaysShow,
                          selectedIndex: _index,
                          onDestinationSelected: _select,
                          destinations: List.generate(
                            _labels.length,
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
                _labels.length,
                (i) => PlatformMenuItem(
                  label: _labels[i],
                  onSelected: () => _select(i),
                ),
              ),
              PlatformMenuItem(
                label: '文件管理',
                onSelected: _openDashboardFiles,
              ),
            ],
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
