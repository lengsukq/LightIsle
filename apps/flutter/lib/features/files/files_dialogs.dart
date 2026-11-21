import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import 'file_name_validation.dart';

const int _kMaxFileNameLength = 150;

class FilesRenameDialog extends StatefulWidget {
  const FilesRenameDialog({
    super.key,
    required this.initialName,
    this.isFolder = false,
  });

  final String initialName;
  final bool isFolder;

  @override
  State<FilesRenameDialog> createState() => _FilesRenameDialogState();
}

class _FilesRenameDialogState extends State<FilesRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  String? _issue;

  @override
  void initState() {
    super.initState();
    final name = widget.initialName;
    final dot = widget.isFolder ? -1 : name.lastIndexOf('.');
    final end = dot > 0 ? dot : name.length;
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: end);
  }

  void _save() {
    final name = _controller.text.trim();
    setState(() => _issue = validateFileName(name));
    if (_issue == null) Navigator.pop(context, name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      title: const Text('重命名'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: _kMaxFileNameLength,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          isDense: true,
          labelText: '名称',
          errorText: _issue,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class FilesCreateFolderDialog extends StatefulWidget {
  const FilesCreateFolderDialog({super.key});

  @override
  State<FilesCreateFolderDialog> createState() =>
      _FilesCreateFolderDialogState();
}

class _FilesCreateFolderDialogState extends State<FilesCreateFolderDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _validation;

  void _submit() {
    final value = _controller.text.trim();
    final issue = validateFileName(value);
    if (issue != null) {
      setState(() => _validation = issue);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建文件夹'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: _kMaxFileNameLength,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '文件夹名称',
              errorText: _validation,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}

Future<String?> showFilesCreateFolderDialog(BuildContext context) =>
    showIsleDialog<String>(
      context: context,
      builder: (_) => const FilesCreateFolderDialog(),
    );

Future<String?> showFilesRenameDialog(
  BuildContext context, {
  required String initialName,
  required bool isFolder,
}) => showIsleDialog<String>(
  context: context,
  builder: (_) =>
      FilesRenameDialog(initialName: initialName, isFolder: isFolder),
);

Future<FileType?> showFilesUploadSourceSheet(BuildContext context) =>
    showModalBottomSheet<FileType>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                '上传到当前文件夹',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('照片与视频'),
              subtitle: const Text('从系统相册选择'),
              onTap: () => Navigator.pop(sheetContext, FileType.media),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('文件'),
              subtitle: const Text('从设备或其他应用选择'),
              onTap: () => Navigator.pop(sheetContext, FileType.any),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

Future<bool> showFilesOverwriteConfirmDialog(
  BuildContext context, {
  required String fileName,
  required String alternativeName,
}) async {
  final saveCopy = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('保留已有文件？'),
      content: Text(
        '此位置已有“$fileName”。原文件会保留，新文件将保存为“$alternativeName”。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('另存为新文件'),
        ),
      ],
    ),
  );
  return saveCopy == true;
}
