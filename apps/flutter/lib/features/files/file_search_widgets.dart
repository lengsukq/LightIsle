import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';

const List<(String, String)> kFileSearchKinds = <(String, String)>[
  ('', '全部'),
  ('image', '图片'),
  ('video', '视频'),
  ('audio', '音频'),
  ('document', '文档'),
  ('archive', '压缩包'),
  ('folder', '文件夹'),
];

String fileSearchKindLabel(String kind) {
  for (final entry in kFileSearchKinds) {
    if (entry.$1 == kind) return entry.$2;
  }
  return '全部';
}

///Finder-style scope switcher (`当前目录` ↔ `当前整盘`) + file kind chips.
class FileSearchScopeAndKindBar extends StatelessWidget {
  const FileSearchScopeAndKindBar({
    super.key,
    required this.busy,
    required this.selectedKind,
    required this.onSelectKind,
    this.subdirLabel,
    required this.searchEntireRoot,
    this.onToggleScope,
  });

  final bool busy;
  final String selectedKind;
  final ValueChanged<String> onSelectKind;
  final String? subdirLabel;
  final bool searchEntireRoot;
  final ValueChanged<bool>? onToggleScope;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasSubdirScope =
        subdirLabel != null && subdirLabel!.isNotEmpty && onToggleScope != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasSubdirScope) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                Text(
                  '搜索范围：',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                ChoiceChip(
                  key: const ValueKey('filesSearchScopeSubdirChip'),
                  avatar: const Icon(Icons.folder_outlined, size: 15),
                  label: Text(
                    '当前目录“$subdirLabel”',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: !searchEntireRoot,
                  visualDensity: VisualDensity.compact,
                  onSelected: busy
                      ? null
                      : (selected) {
                          if (!searchEntireRoot && !selected) return;
                          onToggleScope?.call(false);
                        },
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  key: const ValueKey('filesSearchScopeRootChip'),
                  avatar: const Icon(Icons.dns_outlined, size: 15),
                  label: const Text('当前整盘', style: TextStyle(fontSize: 12)),
                  selected: searchEntireRoot,
                  visualDensity: VisualDensity.compact,
                  onSelected: busy
                      ? null
                      : (selected) {
                          if (searchEntireRoot && !selected) return;
                          onToggleScope?.call(true);
                        },
                ),
              ],
            ),
          ),
        ],
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              for (final entry in kFileSearchKinds)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: ValueKey(
                      'filesSearchKind_${entry.$1.isEmpty ? 'all' : entry.$1}',
                    ),
                    label: Text(entry.$2, style: const TextStyle(fontSize: 12)),
                    selected: selectedKind == entry.$1,
                    visualDensity: VisualDensity.compact,
                    onSelected: busy
                        ? null
                        : (selected) {
                            if (!selected && selectedKind == entry.$1) return;
                            onSelectKind(entry.$1);
                          },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact recent search history strip shown lightly when the search box is
/// focused with empty input or during empty search state recovery.
class FileSearchHistoryStrip extends StatelessWidget {
  const FileSearchHistoryStrip({
    super.key,
    required this.terms,
    required this.busy,
    required this.onTapTerm,
    required this.onRemoveTerm,
    required this.onClearAll,
  });

  final List<String> terms;
  final bool busy;
  final ValueChanged<String> onTapTerm;
  final ValueChanged<String> onRemoveTerm;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.history_rounded,
                size: 14,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '最近搜索',
                style: TextStyle(
                  fontSize: 11.5,
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              TextButton(
                key: const ValueKey('filesClearSearchHistoryButton'),
                onPressed: busy ? null : onClearAll,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(36, 26),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('清空', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final term in terms)
                InputChip(
                  label: Text(
                    term,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: busy ? null : () => onTapTerm(term),
                  onDeleted: busy ? null : () => onRemoveTerm(term),
                  deleteButtonTooltipMessage: '删除记录',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Renders [text] while highlighting every whitespace-separated keyword token
/// from [query] without altering surrounding typography.
class HighlightedSearchText extends StatelessWidget {
  const HighlightedSearchText({
    super.key,
    required this.text,
    required this.query,
    this.style,
    this.highlightStyle,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  final String text;
  final String query;
  final TextStyle? style;
  final TextStyle? highlightStyle;
  final int maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final tokens = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (tokens.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: overflow, style: style);
    }

    final pattern = RegExp(
      tokens.map(RegExp.escape).join('|'),
      caseSensitive: false,
    );
    final matches = pattern.allMatches(text).toList(growable: false);
    if (matches.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: overflow, style: style);
    }

    final colors = Theme.of(context).colorScheme;
    final resolvedHighlight =
        highlightStyle ??
        (style ?? const TextStyle()).copyWith(
          backgroundColor: colors.primaryContainer.withValues(alpha: 0.72),
          color: colors.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: resolvedHighlight,
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// Clear empty search recovery view separating kind-filter mismatch and
/// subdir scope limitation from an actually empty directory.
class FileSearchEmptyState extends StatelessWidget {
  const FileSearchEmptyState({
    super.key,
    required this.searchTerm,
    required this.searchKind,
    required this.subdirLabel,
    required this.searchingSubdir,
    required this.onResetKind,
    required this.onExpandToRoot,
    required this.onExitSearch,
  });

  final String searchTerm;
  final String searchKind;
  final String? subdirLabel;
  final bool searchingSubdir;
  final VoidCallback onResetKind;
  final VoidCallback onExpandToRoot;
  final VoidCallback onExitSearch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasKindFilter = searchKind.isNotEmpty;
    final kindLabel = fileSearchKindLabel(searchKind);
    final title = hasKindFilter
        ? '在“$kindLabel”类型下未找到“$searchTerm”'
        : searchingSubdir && subdirLabel != null
        ? '当前目录“$subdirLabel”下未找到“$searchTerm”'
        : '整个共享空间中未找到“$searchTerm”';
    final subtitle = hasKindFilter
        ? '可以切回“全部”类型查看其他格式匹配，或调整关键词。'
        : searchingSubdir
        ? '可以尝试扩大到当前整盘搜索，或更换其他关键词。'
        : '请尝试更简短的关键词、检查拼写，或开启「全文搜索」。';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        children: [
          Icon(
            hasKindFilter
                ? Icons.filter_alt_off_outlined
                : Icons.search_off_rounded,
            size: 52,
            color: colors.outline,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (hasKindFilter)
                FilledButton.icon(
                  key: const ValueKey('filesSearchResetKindButton'),
                  onPressed: onResetKind,
                  icon: const Icon(Icons.clear_all_rounded, size: 17),
                  label: const Text('切回全部类型'),
                ),
              if (searchingSubdir)
                OutlinedButton.icon(
                  key: const ValueKey('filesSearchExpandRootButton'),
                  onPressed: onExpandToRoot,
                  icon: const Icon(Icons.dns_outlined, size: 17),
                  label: const Text('扩大到当前整盘'),
                ),
              OutlinedButton.icon(
                key: const ValueKey('filesSearchExitEmptyButton'),
                onPressed: onExitSearch,
                style: OutlinedButton.styleFrom(shape: IsleShapes.pill()),
                icon: const Icon(Icons.arrow_back_rounded, size: 17),
                label: const Text('返回原目录'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
