import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/widgets.dart';

/// Desktop floating navigation rail plus direct Files Workbench entry.
class ClientShellRailDock extends StatelessWidget {
  const ClientShellRailDock({
    super.key,
    required this.selectedIndex,
    required this.extendedRail,
    required this.filesActive,
    required this.activeTone,
    required this.labels,
    required this.sectionThemes,
    required this.onSelect,
    required this.onOpenFiles,
  });

  final int selectedIndex;
  final bool extendedRail;
  final bool filesActive;
  final Color activeTone;
  final List<String> labels;
  final List<IsleSectionTheme> sectionThemes;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final showCompanionFilesEntry = MediaQuery.sizeOf(context).height >= 420;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IsleFloatingRailDock(
          child: NavigationRailTheme(
            data: NavigationRailThemeData(
              backgroundColor: Colors.transparent,
              indicatorColor: activeTone.withValues(alpha: 0.15),
              indicatorShape: IsleShapes.sm(),
              selectedIconTheme: IconThemeData(size: 20.5, color: activeTone),
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
                selectedIndex: selectedIndex,
                extended: extendedRail,
                minWidth: 64,
                minExtendedWidth: 184,
                labelType: NavigationRailLabelType.none,
                onDestinationSelected: onSelect,
                destinations: List.generate(
                  labels.length,
                  (i) => NavigationRailDestination(
                    icon: Icon(sectionThemes[i].icon),
                    label: Text(labels[i]),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showCompanionFilesEntry)
          Padding(
            padding: EdgeInsets.only(
              left: extendedRail ? 12 : 4,
              right: extendedRail ? 4 : 0,
            ),
            child: Tooltip(
              message: '直达文件工作台',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const ValueKey('railFilesWorkbenchButton'),
                  borderRadius: IsleRadius.brPill,
                  onTap: onOpenFiles,
                  child: AnimatedContainer(
                    duration: IsleMotion.reducedMotion(context)
                        ? Duration.zero
                        : IsleMotion.quick,
                    curve: IsleMotion.silk,
                    width: extendedRail ? 176 : 44,
                    height: 44,
                    padding: EdgeInsets.symmetric(
                      horizontal: extendedRail ? 14 : 0,
                    ),
                    decoration: IsleDecorations.capsuleControl(
                      context,
                      selected: filesActive,
                      accent: palette['brandAmber'],
                    ),
                    child: Row(
                      mainAxisAlignment: extendedRail
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.folder_rounded,
                          size: 19,
                          color: filesActive
                              ? palette['brandAmber']
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        if (extendedRail) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '文件工作台',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontSize: 12.5,
                                    fontWeight: filesActive
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    color: filesActive
                                        ? palette['brandAmber']
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Mobile floating bottom navigation dock for the primary client sections.
class ClientShellBottomNavDock extends StatelessWidget {
  const ClientShellBottomNavDock({
    super.key,
    required this.selectedIndex,
    required this.maxWidth,
    required this.textScale,
    required this.activeTone,
    required this.labels,
    required this.sectionThemes,
    required this.onSelect,
  });

  final int selectedIndex;
  final double maxWidth;
  final double textScale;
  final Color activeTone;
  final List<String> labels;
  final List<IsleSectionTheme> sectionThemes;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
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
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.78),
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
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.78),
            );
          }),
        ),
        child: NavigationBar(
          height: 50,
          labelBehavior: maxWidth < 360 && textScale > 1.4
              ? NavigationDestinationLabelBehavior.alwaysHide
              : NavigationDestinationLabelBehavior.alwaysShow,
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelect,
          destinations: List.generate(
            labels.length,
            (i) => NavigationDestination(
              tooltip: labels[i],
              icon: Icon(sectionThemes[i].icon),
              selectedIcon: Icon(sectionThemes[i].icon, color: activeTone),
              label: labels[i],
            ),
          ),
        ),
      ),
    );
  }
}

/// Native macOS application menu bar wrapper for `ClientShell`.
class ClientShellMacPlatformMenuBar extends StatelessWidget {
  const ClientShellMacPlatformMenuBar({
    super.key,
    required this.labels,
    required this.onSelect,
    required this.onOpenFiles,
    required this.child,
  });

  final List<String> labels;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpenFiles;
  final Widget child;

  @override
  Widget build(BuildContext context) => PlatformMenuBar(
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
            onSelected: () => onSelect(3),
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
            labels.length,
            (i) => PlatformMenuItem(
              label: labels[i],
              onSelected: () => onSelect(i),
            ),
          ),
          PlatformMenuItem(label: '文件管理', onSelected: onOpenFiles),
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
    child: child,
  );
}
