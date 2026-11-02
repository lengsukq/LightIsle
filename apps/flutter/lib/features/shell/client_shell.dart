import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/personal_storage_routing.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../files/files_page.dart';
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
  int _index = 0;
  // Match the native Mac management dock: compact icons by default.
  bool _railExpanded = false;
  final Map<int, Widget> _pages = {};
  Map<String, dynamic>? _myStoragePolicy;
  String? _personalRouteError;
  int? _manualRootSection;
  List<LightIsleRoot> _roots = const [];
  bool _rootsLoading = false;
  String? _rootsError;
  @override
  void initState() {
    super.initState();
    unawaited(_refreshRoots());
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
      final policy = await widget.api.get('/api/v2/me/storage');
      if (!mounted) return;
      final old = widget.api.selectedRoot;
      final isCurrent =
          old == null ||
          roots.any((root) => root.identity == old.identity && root.online);
      if (!isCurrent) widget.api.selectRoot(null);
      setState(() {
        _roots = roots;
        _myStoragePolicy = policy;
        if (!isCurrent) _pages.clear();
      });
      _applyPersonalRoute(_index);
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
    final chosen = id.isEmpty
        ? null
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
    final target = route.kind == PersonalRouteKind.personal ? route.root : null;
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
    return _pages.putIfAbsent(
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
                ),
                1 => FilesPage(
                  api: widget.api,
                  isAdmin: _admin,
                  accountName: widget.identity['username']?.toString() ?? '',
                  initialPath:
                      _routeFor(1).kind == PersonalRouteKind.personal &&
                          _manualRootSection != 1
                      ? _routeFor(1).path!
                      : '.',
                  showPhotoBackup: false,
                ),
                2 => PhotosPage(
                  api: widget.api,
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
                      : '.',
                  backupDirectory:
                      _routeFor(2).kind == PersonalRouteKind.personal &&
                          _manualRootSection != 2
                      ? _routeFor(2).path!
                      : 'PhonePhotos',
                ),
                3 => CinemaPage(
                  api: widget.api,
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
                      : '.',
                ),
                _ => SettingsPage(
                  api: widget.api,
                  identity: widget.identity,
                  onLogout: widget.onLogout,
                ),
              },
      ),
    );
  }

  void _select(int index) {
    if (_index != index) {
      HapticFeedback.selectionClick();
      setState(() {
        _index = index;
        _manualRootSection = null;
        _pages.clear();
      });
      _applyPersonalRoute(index);
    }
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
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                toolbarHeight: rail ? 44 : 54,
                title: Row(
                  children: [
                    if (!rail) ...[
                      const IsleBrandMark(size: 27),
                      const SizedBox(width: 10),
                      Text(
                        constraints.maxWidth >= 610 ? '轻屿 LightIsle' : '轻屿',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                    if (rail && canExtendRail) ...[
                      IconButton(
                        tooltip: extendedRail ? '收起侧栏' : '展开侧栏',
                        onPressed: () =>
                            setState(() => _railExpanded = !_railExpanded),
                        icon: Icon(
                          extendedRail
                              ? Icons.menu_open_rounded
                              : Icons.menu_rounded,
                        ),
                      ),
                    ],
                  ],
                ),
                actions: [
                  PopupMenuButton<String>(
                    tooltip:
                        '当前存储位置：${widget.api.selectedRoot?.name ?? '默认共享目录'}。点击查看或切换。',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _rootsError != null
                                ? Icons.sync_problem_rounded
                                : Icons.storage_outlined,
                            color: _rootsError != null
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                          ),
                          if (constraints.maxWidth >= 680) ...[
                            const SizedBox(width: 5),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 118),
                              child: Text(
                                widget.api.selectedRoot?.name ?? '默认目录',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                            ),
                            const Icon(Icons.expand_more_rounded, size: 17),
                          ],
                        ],
                      ),
                    ),
                    onSelected: (value) {
                      if (value == '__refresh') {
                        unawaited(_refreshRoots());
                      } else {
                        unawaited(_chooseRoot(value));
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        enabled: false,
                        child: Text(
                          '当前位置：${widget.api.selectedRoot?.name ?? '默认共享目录'}',
                        ),
                      ),
                      const PopupMenuItem(value: '', child: Text('默认共享目录')),
                      ..._roots.map(
                        (root) => PopupMenuItem(
                          value: root.id,
                          enabled: root.online,
                          child: Text(
                            '${root.name}${root.online ? '' : ' · 离线'}',
                          ),
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: '__refresh',
                        enabled: !_rootsLoading,
                        child: Text(_rootsLoading ? '正在检查…' : '刷新共享目录状态'),
                      ),
                    ],
                  ),
                  if (_rootsLoading)
                    const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
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
                          indicatorColor: Theme.of(context).colorScheme.primary
                              .withValues(alpha: 0.16),
                          indicatorShape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
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
                                      .onSurfaceVariant,
                                );
                          }),
                        ),
                        child: NavigationBar(
                          height: 64,
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
