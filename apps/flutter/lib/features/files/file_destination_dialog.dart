import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/lightisle_api.dart';

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
  });
  final LightIsleApi api;
  final String sourceName;
  final String sourcePath;
  final String action;

  @override
  State<FileDestinationDialog> createState() => _FileDestinationDialogState();
}

class _FileDestinationDialogState extends State<FileDestinationDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.sourceName);
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

  String get _destination => _directory == '.'
      ? _name.text.trim()
      : '$_directory/${_name.text.trim()}';

  String? get _validationError {
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
      final data = await widget.api.get('/api/v1/files', query: {
        'path': directory,
        'limit': '100',
        'cursor': more ? _cursor : '',
      });
      if (!mounted || id != _generation || directory != _directory) return;
      final folders = (data['entries'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .where((e) => e['type'] == 'folder')
          .map((e) => (e['name']?.toString() ?? '', e['path']?.toString() ?? ''))
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
        setState(() => _error = '目录读取失败：$error');
      }
    } finally {
      if (mounted && id == _generation) setState(() => _loading = false);
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
      title: Text(widget.action == 'move' ? '移动或重命名' : '复制文件'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('来源：${widget.sourcePath}',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 4,
                children: [
                  for (final (label, path) in breadcrumbs)
                    TextButton(
                      onPressed: _loading || path == _directory
                          ? null : () => _browse(path),
                      child: Text(label),
                    ),
                ],
              ),
              Container(
                constraints: const BoxConstraints(maxHeight: 195, minHeight: 60),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (_directory != '.')
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.arrow_upward_rounded),
                        title: const Text('上一级'),
                        onTap: _loading ? null : () => _browse(
                          parts.length == 1 ? '.' : parts.take(parts.length-1).join('/')),
                      ),
                    for (final (name, path) in _folders)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(name, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _loading ? null : () => _browse(path),
                      ),
                    if (_loading)
                      const Center(child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      ))
                    else if (_folders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('当前没有子文件夹'),
                      ),
                    if (_cursor.isNotEmpty && !_loading)
                      TextButton(onPressed: () => _load(more: true),
                          child: const Text('更多文件夹')),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _name,
                maxLength: 150,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '目标文件名',
                  errorText: _validationError,
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _conflict,
                decoration: const InputDecoration(labelText: '目标文件已存在'),
                items: const [
                  DropdownMenuItem(value: 'rename', child: Text('自动改名，保留原文件')),
                  DropdownMenuItem(value: 'skip', child: Text('跳过')),
                  DropdownMenuItem(value: '', child: Text('拒绝并提示冲突')),
                ],
                onChanged: (value) => setState(() => _conflict = value ?? ''),
              ),
              const SizedBox(height: 8),
              Text('目标：$_destination',
                  style: Theme.of(context).textTheme.bodySmall),
              if (!_canWrite && !_loading)
                const Text('此目录不可写入，可以继续浏览其他授权目录。'),
              if (_error != null)
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: _canWrite && !_loading && _validationError == null
              ? () => Navigator.pop(context,
                  FileDestinationSelection(_destination, _conflict))
              : null,
          child: Text(widget.action == 'move' ? '移动' : '复制'),
        ),
      ],
    );
  }
}
