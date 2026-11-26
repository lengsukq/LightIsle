import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'file_extras_api.dart';

enum FilesQuickViewMode { browse, large, recent }

/// Collapsible capsule bar showing the user's pinned/starred folders and files.
class FilesPinsCapsuleBar extends StatelessWidget {
  const FilesPinsCapsuleBar({
    super.key,
    required this.pins,
    required this.collapsed,
    required this.busy,
    required this.onToggleCollapsed,
    required this.onTapPin,
    required this.onRemovePin,
  });

  final List<FilePinEntry> pins;
  final bool collapsed;
  final bool busy;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<FilePinEntry> onTapPin;
  final ValueChanged<FilePinEntry> onRemovePin;

  @override
  Widget build(BuildContext context) {
    if (pins.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final amber = palette['brandAmber'];

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        radius: IsleRadius.md,
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.star_rounded, size: 15, color: amber),
                const SizedBox(width: 5),
                Text(
                  '常用置顶（${pins.length}）',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                const Spacer(),
                InkWell(
                  key: const ValueKey('filesPinsCollapseToggle'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: onToggleCollapsed,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          collapsed ? '展开' : '收起',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        Icon(
                          collapsed
                              ? Icons.expand_more_rounded
                              : Icons.expand_less_rounded,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (!collapsed) ...[
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final pin in pins)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InputChip(
                          key: ValueKey('file-pin-chip-${pin.path}'),
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(
                            pin.isFolder
                                ? Icons.folder_rounded
                                : Icons.description_outlined,
                            size: 15,
                            color: pin.exists ? amber : colors.onSurfaceVariant,
                          ),
                          label: Text(
                            pin.exists
                                ? pin.displayName
                                : '${pin.displayName}（已移动）',
                            style: TextStyle(
                              fontSize: 12,
                              color: pin.exists
                                  ? null
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                          onPressed: busy || !pin.exists
                              ? null
                              : () => onTapPin(pin),
                          deleteIcon: const Icon(Icons.close_rounded, size: 14),
                          deleteButtonTooltipMessage: '取消置顶',
                          onDeleted: busy ? null : () => onRemovePin(pin),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact quick-filter strip: Browse / Large Files / Recent Files + Offline Vault.
class FilesQuickFilterStrip extends StatelessWidget {
  const FilesQuickFilterStrip({
    super.key,
    required this.mode,
    required this.disabled,
    required this.onSelectMode,
    required this.onOpenOfflineVault,
    this.offlineCount = 0,
  });

  final FilesQuickViewMode mode;
  final bool disabled;
  final ValueChanged<FilesQuickViewMode> onSelectMode;
  final VoidCallback onOpenOfflineVault;
  final int offlineCount;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ChoiceChip(
              key: const ValueKey('filesQuickFilterBrowse'),
              visualDensity: VisualDensity.compact,
              label: const Text('目录浏览', style: TextStyle(fontSize: 12)),
              selected: mode == FilesQuickViewMode.browse,
              onSelected: disabled
                  ? null
                  : (_) => onSelectMode(FilesQuickViewMode.browse),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              key: const ValueKey('filesQuickFilterLarge'),
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.storage_rounded, size: 14),
              label: const Text('大文件', style: TextStyle(fontSize: 12)),
              selected: mode == FilesQuickViewMode.large,
              onSelected: disabled
                  ? null
                  : (_) => onSelectMode(FilesQuickViewMode.large),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              key: const ValueKey('filesQuickFilterRecent'),
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.schedule_rounded, size: 14),
              label: const Text('近期新增', style: TextStyle(fontSize: 12)),
              selected: mode == FilesQuickViewMode.recent,
              onSelected: disabled
                  ? null
                  : (_) => onSelectMode(FilesQuickViewMode.recent),
            ),
            const SizedBox(width: 6),
            ActionChip(
              key: const ValueKey('filesOpenOfflineVaultChip'),
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                Icons.offline_pin_outlined,
                size: 15,
                color: palette['brandBlue'],
              ),
              label: Text(
                offlineCount > 0 ? '离线文件箱 ($offlineCount)' : '离线文件箱',
                style: const TextStyle(fontSize: 12),
              ),
              onPressed: onOpenOfflineVault,
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders the `/files/insights?mode=large|recent` fast-filter results surface.
class FilesInsightsPanel extends StatelessWidget {
  const FilesInsightsPanel({
    super.key,
    required this.mode,
    required this.loading,
    required this.error,
    required this.response,
    required this.minBytes,
    required this.recentDays,
    required this.onChangeMinBytes,
    required this.onChangeRecentDays,
    required this.onRetry,
    required this.onOpenItem,
    required this.onOpenContainingFolder,
    required this.onTrashItem,
  });

  final FilesQuickViewMode mode;
  final bool loading;
  final String? error;
  final FileInsightsResponse? response;
  final int minBytes;
  final int recentDays;
  final ValueChanged<int> onChangeMinBytes;
  final ValueChanged<int> onChangeRecentDays;
  final VoidCallback onRetry;
  final ValueChanged<FileInsightItem> onOpenItem;
  final ValueChanged<FileInsightItem> onOpenContainingFolder;
  final ValueChanged<FileInsightItem> onTrashItem;

  static const _sizeOptions = <(int, String)>[
    (50 << 20, '≥ 50 MiB'),
    (100 << 20, '≥ 100 MiB'),
    (500 << 20, '≥ 500 MiB'),
    (1 << 30, '≥ 1 GiB'),
  ];

  static const _dayOptions = <(int, String)>[
    (3, '近 3 天'),
    (7, '近 7 天'),
    (30, '近 30 天'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final isLarge = mode == FilesQuickViewMode.large;
    final data = response;

    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      radius: IsleRadius.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                  isLarge ? '大文件快筛' : '近期新增快筛',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Wrap(
                  spacing: 6,
                  children: isLarge
                      ? [
                          for (final opt in _sizeOptions)
                            ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                opt.$2,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              selected: minBytes == opt.$1,
                              onSelected: loading
                                  ? null
                                  : (_) => onChangeMinBytes(opt.$1),
                            ),
                        ]
                      : [
                          for (final opt in _dayOptions)
                            ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                opt.$2,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              selected: recentDays == opt.$1,
                              onSelected: loading
                                  ? null
                                  : (_) => onChangeRecentDays(opt.$1),
                            ),
                        ],
                ),
              ],
            ),
          ),
          if (data != null && !loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text(
                '命中 ${data.matchedFiles} 个文件（共 ${formatBytes(data.totalBytes)}，扫描 ${data.scannedFiles} 项）'
                '${data.timedOut ? ' · 扫描已触达限时，仅展示部分结果' : (data.truncated ? ' · 结果已按上限截断' : '')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 11.5,
                ),
              ),
            ),
          const Divider(height: 1),
          if (loading)
            const LinearProgressIndicator(minHeight: 2)
          else if (error != null)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Notice(error!, error: true, onRetry: onRetry),
            )
          else if (data == null || data.items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                isLarge
                    ? '当前目录下没有达到阈值的大文件。'
                    : '近 $recentDays 天内没有新增或修改的文件。',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            )
          else
            Column(
              children: [
                for (var i = 0; i < data.items.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 52),
                  _buildInsightTile(context, data.items[i], palette),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildInsightTile(
    BuildContext context,
    FileInsightItem item,
    IslePalette palette,
  ) {
    final colors = Theme.of(context).colorScheme;
    final modText = item.modified == null
        ? ''
        : ' · ${formatDateTime(item.modified!.toLocal())}';
    final dirLabel = item.parentDir == '.' ? '根目录' : item.parentDir;

    return ListTile(
      dense: true,
      leading: IsleSquircleBadge(
        icon: Icons.insert_drive_file_outlined,
        color: palette['brandAmber'],
        size: 32,
        iconSize: 16.5,
      ),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
      ),
      subtitle: Text(
        '${formatBytes(item.size)} · $dirLabel$modText',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
      ),
      onTap: () => onOpenItem(item),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '打开所在目录',
            visualDensity: VisualDensity.compact,
            onPressed: () => onOpenContainingFolder(item),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
          ),
          if (item.canWrite)
            IconButton(
              tooltip: '移入回收站',
              visualDensity: VisualDensity.compact,
              color: colors.error,
              onPressed: () => onTrashItem(item),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
            ),
        ],
      ),
    );
  }
}
