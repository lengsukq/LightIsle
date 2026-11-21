import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'photo_timeline_scrubber.dart';

/// Special selection sentinel returned by [showPhotosBatchAlbumSheet] when the
/// user picks the real-folder album flow instead of a legacy private album.
const int kPhotosBatchFolderAlbumChoice = -1;

/// Dialog for creating or renaming a shared or private photo album.
class AlbumNameDialog extends StatefulWidget {
  const AlbumNameDialog({
    this.initialName = '',
    this.privateAlbum = false,
    super.key,
  });

  final String initialName;
  final bool privateAlbum;

  @override
  State<AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<AlbumNameDialog> {
  static const int _maxNameRunes = 60;
  static const int _maxInputLength = 120;

  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final length = name.runes.length;
    if (length == 0) {
      setState(() => _error = '请输入相册名称。');
      return;
    }
    if (length > _maxNameRunes ||
        RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(name)) {
      setState(() => _error = '相册名称需为 1–60 个字符，且不能包含控制字符。');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      title: Text(
        widget.initialName.isEmpty
            ? widget.privateAlbum
                  ? '新建私人相册'
                  : '新建相册'
            : widget.privateAlbum
            ? '修改私人相册名称'
            : '修改相册名称',
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: _maxInputLength,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: '相册名称',
          errorText: _error,
          helperText: '最多 60 个字符',
          isDense: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.initialName.isEmpty ? '创建' : '保存'),
        ),
      ],
    );
  }
}

/// Prompts the user to confirm deleting an album while clarifying that original
/// media files stay untouched.
Future<bool> showDeletePhotoAlbumDialog(
  BuildContext context, {
  required MediaAlbum album,
  required bool isPrivate,
}) async {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      title: Text(isPrivate ? '删除私人相册？' : '删除相册？'),
      content: Text(
        isPrivate
            ? '只会删除“${album.name}”及其中的关联。原始照片、视频和共享相册都会保留。'
            : '只会删除“${album.name}”及其中的关联。原始照片和视频会保留。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(isPrivate ? '删除私人相册' : '删除相册'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Bottom sheet letting the user organize selected photos into either a
/// folder-backed album or a legacy private album.
Future<int?> showPhotosBatchAlbumSheet(
  BuildContext context, {
  required List<MediaAlbum> privateAlbums,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    shape: IsleShapes.sheet(
      side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
    ),
    builder: (sheetContext) {
      final sheetTheme = Theme.of(sheetContext);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Text(
              '整理到相册',
              style: sheetTheme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            IsleGroupCard(
              margin: EdgeInsets.zero,
              children: [
                ListTile(
                  key: const ValueKey('batchToFolderAlbumTile'),
                  dense: true,
                  leading: IsleSquircleBadge(
                    icon: Icons.folder_special_outlined,
                    color: sheetTheme.colorScheme.primary,
                    size: 32,
                    iconSize: 17,
                  ),
                  title: const Text('文件夹相册（复制或移动）'),
                  subtitle: const Text('整理到照片目录中的真实文件夹，支持新建相册与家庭共享'),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: () =>
                      Navigator.pop(sheetContext, kPhotosBatchFolderAlbumChoice),
                ),
              ],
            ),
            if (privateAlbums.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                child: Text(
                  '旧版私人相册',
                  style: sheetTheme.textTheme.labelMedium?.copyWith(
                    color: sheetTheme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IsleGroupCard(
                margin: EdgeInsets.zero,
                children: [
                  for (final album in privateAlbums)
                    ListTile(
                      dense: true,
                      leading: IsleSquircleBadge(
                        icon: Icons.photo_album_outlined,
                        color: sheetTheme.colorScheme.secondary,
                        size: 32,
                        iconSize: 17,
                      ),
                      title: Text(album.name),
                      subtitle: Text('${album.count} 项 · 仅自己可见'),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                      ),
                      onTap: () => Navigator.pop(sheetContext, album.id),
                    ),
                ],
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Bottom sheet displaying indexed capture year-months for direct timeline
/// jumping without paging through intermediate screens.
Future<PhotoTimelineMonth?> showPhotosTimelineMonthSheet(
  BuildContext context, {
  required List<PhotoTimelineMonth> months,
}) {
  return showModalBottomSheet<PhotoTimelineMonth>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .65,
        child: Column(
          children: [
            const ListTile(
              title: Text('跳转到拍摄年月'),
              subtitle: Text('可直接跳转至尚未加载的历史照片，不必逐页滚动。'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: months.length,
                itemBuilder: (context, index) {
                  final month = months[index];
                  return ListTile(
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: Text(month.label),
                    trailing: Text('${month.count} 项'),
                    onTap: () => Navigator.pop(sheetContext, month),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Explains why mobile photo backup requires an online personal photo space
/// and offers direct navigation to storage settings.
Future<bool> showMobileBackupSpaceRequiredDialog(BuildContext context) async {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final goStorage = await showIsleDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      title: const Text('尚未开启个人照片空间'),
      content: const Text(
        '手机相册备份需要先为当前账号分配在线的个人「照片」存储位置。'
        '若你刚刚手动切换了共享硬盘，请先切回个人照片空间后再开启备份。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('前往存储空间'),
        ),
      ],
    ),
  );
  return goStorage == true;
}
