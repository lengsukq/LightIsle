import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'isle_folder_picker_sheet.dart';

/// Select a destination inside the authorized NAS tree; server remains the
/// authority for path safety, grants, and collision-safe publishing.
class FileDestinationSelection {
  const FileDestinationSelection(this.path, this.conflict);
  final String path;
  final String conflict;
}

class FileDestinationDialog extends StatefulWidget {
  const FileDestinationDialog({
    super.key,
    required this.api,
    required this.sourceName,
    required this.sourcePath,
    required this.action,
    this.directoryOnly = false,
  });
  final LightIsleApi api;
  final String sourceName;
  final String sourcePath;
  final String action;
  final bool directoryOnly;

  @override
  State<FileDestinationDialog> createState() => _FileDestinationDialogState();
}

class _FileDestinationDialogState extends State<FileDestinationDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.sourceName,
  );
  String _directory = '.';
  String _cursor = '';
  String _conflict = 'rename';
  bool _canWrite = false;
  bool _loading = false;
  int _generation = 0;
  String? _error;
  final List<(String, String)> _folders = [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    ++_generation;
    _name.dispose();
    super.dispose();
  }

  String? get _sourceParentDirectory {
    final src = widget.sourcePath.trim();
    if (src.isEmpty || src == '.') return null;
    if (widget.directoryOnly) return src;
    final slash = src.lastIndexOf('/');
    return slash <= 0 ? null : src.substring(0, slash);
  }

  String get _destination => widget.directoryOnly
      ? _directory
      : _directory == '.'
      ? _name.text.trim()
      : '$_directory/${_name.text.trim()}';

  String? get _validationError {
    if (widget.directoryOnly) return null;
    final value = _name.text.trim();
    if (value.isEmpty || value == '.' || value == '..') {
      return '请输入目标文件名';
    }
    if (value.startsWith('.lightisle-') ||
        value.contains('/') ||
        value.contains(String.fromCharCode(92)) ||
        value.runes.any((c) => c < 32)) {
      return '文件名包含不允许的字符或内部保留名称';
    }
    if (widget.action == 'move' && _destination == widget.sourcePath) {
      return '移动目标与来源相同';
    }
    if (_destination.startsWith('${widget.sourcePath}/') &&
        widget.sourcePath.isNotEmpty) {
      return '不能将目录复制或移动到自身的子目录';
    }
    return null;
  }

  Future<void> _browse(String path) async {
    setState(() {
      _directory = path;
      _cursor = '';
      _folders.clear();
      _canWrite = false;
    });
    await _load();
  }

  Future<void> _load({bool more = false}) async {
    final id = ++_generation;
    final directory = _directory;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.get(
        '/api/v2/files',
        query: {
          'path': directory,
          'limit': '100',
          'cursor': more ? _cursor : '',
        },
      );
      if (!mounted || id != _generation || directory != _directory) return;
      final folders = (data['entries'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .where((e) => e['type'] == 'folder')
          .map(
            (e) => (e['name']?.toString() ?? '', e['path']?.toString() ?? ''),
          )
          .where((e) => e.$1.isNotEmpty && e.$2.isNotEmpty)
          .toList();
      setState(() {
        if (!more) _folders.clear();
        _folders.addAll(folders);
        _cursor = data['nextCursor']?.toString() ?? '';
        _canWrite = data['canWrite'] == true;
      });
    } catch (error) {
      if (mounted && id == _generation) {
        setState(() => _error = '目录读取失败：${userFacingError(error)}');
      }
    } finally {
      if (mounted && id == _generation) setState(() => _loading = false);
    }
  }

  String? _validateFolderName(String value) {
    if (value.isEmpty || value == '.' || value == '..') {
      return '请输入有效的文件夹名称';
    }
    if (value.startsWith('.lightisle-') ||
        value.contains('/') ||
        value.contains(String.fromCharCode(92)) ||
        value.runes.any((c) => c < 32)) {
      return '文件夹名称包含不允许的字符或保留前缀';
    }
    return null;
  }

  Future<void> _createSubfolder() async {
    if (!_canWrite || _loading) return;
    var input = '';
    String? validation;
    final folderName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final value = input.trim();
            final issue = _validateFolderName(value);
            if (issue != null) {
              setDialogState(() => validation = issue);
            } else {
              Navigator.pop(dialogContext, value);
            }
          }

          return AlertDialog(
            title: const Text('新建文件夹'),
            content: TextField(
              autofocus: true,
              maxLength: 150,
              textInputAction: TextInputAction.done,
              onChanged: (value) {
                input = value;
                if (validation != null) {
                  setDialogState(() => validation = null);
                }
              },
              decoration: InputDecoration(
                labelText: '文件夹名称',
                errorText: validation,
              ),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('创建')),
            ],
          );
        },
      ),
    );
    if (folderName == null || !mounted) return;
    final targetPath = _directory == '.'
        ? folderName
        : '$_directory/$folderName';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/files/folders',
        body: {'path': targetPath},
      );
      if (mounted) await _browse(targetPath);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '新建文件夹失败：${userFacingError(error)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final parts = _directory == '.' ? <String>[] : _directory.split('/');
    final breadcrumbs = <(String, String)>[('根目录', '.')];
    for (var i = 0; i < parts.length; i++) {
      breadcrumbs.add((parts[i], parts.take(i + 1).join('/')));
    }
    return AlertDialog(
      title: Text(
        widget.action == 'grant'
            ? '选择授权文件夹'
            : widget.directoryOnly
            ? (widget.action == 'move' ? '选择批量移动目录' : '选择批量复制目录')
            : (widget.action == 'move' ? '移动到…' : '复制文件'),
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.action == 'grant'
                    ? '请从当前 NAS 存储根选择要授权给成员的文件夹。'
                    : widget.directoryOnly
                    ? '请在有写入权限的目录中选择批量操作的目标位置。'
                    : '来源：${widget.sourcePath}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              IsleFolderBrowserCard(
                directory: _directory,
                breadcrumbs: breadcrumbs,
                folders: _folders,
                canWrite: _canWrite,
                loading: _loading,
                hasMore: _cursor.isNotEmpty,
                sourceParentDirectory: _sourceParentDirectory,
                onBrowse: _browse,
                onLoadMore: () => _load(more: true),
                onCreateSubfolder: _createSubfolder,
              ),
              const SizedBox(height: 14),
              if (!widget.directoryOnly)
                TextField(
                  controller: _name,
                  maxLength: 150,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: '目标文件名',
                    errorText: _validationError,
                  ),
                ),
              if (widget.action != 'grant')
                DropdownButtonFormField<String>(
                  initialValue: _conflict,
                  decoration: const InputDecoration(labelText: '目标文件已存在'),
                  items: const [
                    DropdownMenuItem(
                      value: 'rename',
                      child: Text('自动改名，保留原文件'),
                    ),
                    DropdownMenuItem(value: 'skip', child: Text('跳过')),
                    DropdownMenuItem(value: '', child: Text('拒绝并提示冲突')),
                  ],
                  onChanged: (value) => setState(() => _conflict = value ?? ''),
                ),
              const SizedBox(height: 8),
              Text(
                '目标：$_destination',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!_canWrite && !_loading) const Text('此目录不可写入，可以继续浏览其他授权目录。'),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canWrite && !_loading && _validationError == null
              ? () => Navigator.pop(
                  context,
                  FileDestinationSelection(_destination, _conflict),
                )
              : null,
          child: Text(
            widget.action == 'grant'
                ? '使用此文件夹'
                : widget.directoryOnly
                ? '使用此目录'
                : (widget.action == 'move' ? '移动' : '复制'),
          ),
        ),
      ],
    );
  }
}
