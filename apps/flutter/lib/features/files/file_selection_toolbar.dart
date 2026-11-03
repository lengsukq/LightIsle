import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';

/// Presentation only. FilesPage owns selection and permission checks, so this
/// toolbar cannot mutate a file or grant permissions on its own.
class FileSelectionToolbar extends StatelessWidget {
  const FileSelectionToolbar({
    super.key,
    required this.compact,
    required this.selectedCount,
    required this.hasLoadedEntries,
    required this.allLoadedSelected,
    required this.canWriteSelection,
    required this.canSaveFiles,
    required this.busy,
    required this.onToggleAll,
    required this.onSave,
    required this.onCopy,
    required this.onMove,
    required this.onClear,
    required this.onDone,
    required this.onTrash,
  });

  final bool compact;
  final int selectedCount;
  final bool hasLoadedEntries;
  final bool allLoadedSelected;
  final bool canWriteSelection;
  final bool canSaveFiles;
  final bool busy;
  final VoidCallback onToggleAll;
  final VoidCallback onSave;
  final VoidCallback onCopy;
  final VoidCallback onMove;
  final VoidCallback onClear;
  final VoidCallback onDone;
  final VoidCallback onTrash;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final anySelected = selectedCount > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 10 : 20, 0, compact ? 10 : 20, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(alpha: .65),
          borderRadius: BorderRadius.circular(IsleTokens.itemRadius),
          border: Border.all(color: colors.primary.withValues(alpha: .28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '已选 $selectedCount 项 · 每次最多 50 项',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy || !hasLoadedEntries ? null : onToggleAll,
                    icon: const Icon(Icons.select_all_rounded, size: 16),
                    label: Text(allLoadedSelected ? '取消全选' : '全选当前页'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || !canSaveFiles ? null : onSave,
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: const Text('保存原文件'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || !anySelected || !canWriteSelection
                        ? null
                        : onCopy,
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: const Text('复制到'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || !anySelected || !canWriteSelection
                        ? null
                        : onMove,
                    icon: const Icon(Icons.drive_file_move_outline, size: 16),
                    label: const Text('移动到'),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : onClear,
                    icon: const Icon(Icons.clear_all_rounded, size: 16),
                    label: const Text('清除选择'),
                  ),
                  TextButton(
                    onPressed: busy ? null : onDone,
                    child: const Text('完成'),
                  ),
                  FilledButton.icon(
                    onPressed: busy || !anySelected || !canWriteSelection
                        ? null
                        : onTrash,
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: const Text('批量移到回收站'),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
