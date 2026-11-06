import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'media_models.dart';

class FolderAlbumSelection {
  const FolderAlbumSelection({
    required this.name,
    required this.path,
    this.moved = false,
  });
  final String name;
  final String path;
  final bool moved;
}

/// Lists actual directories under the current user's assigned photos folder.
/// Legacy database albums remain available separately in the existing view.
class FolderAlbumsPage extends StatefulWidget {
  const FolderAlbumsPage({
    super.key,
    required this.api,
    this.source,
    this.canMove = false,
  });
  final LightIsleApi api;
  final PhotoAsset? source;
  final bool canMove;

  @override
  State<FolderAlbumsPage> createState() => _FolderAlbumsPageState();
}

class _FolderAlbumsPageState extends State<FolderAlbumsPage> {
  late final String? _root = widget.api.selectedRoot?.identity;
  final _items = <Map<String, dynamic>>[];
  String _cursor = '';
  String? _error;
  bool _loading = false, _busy = false, _loaded = false;
  bool get _sameRoot =>
      _root != null && widget.api.selectedRoot?.identity == _root;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_loading || !_sameRoot) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.api.get(
        '/api/v2/photos/folder-albums',
        query: {if (more && _cursor.isNotEmpty) 'cursor': _cursor},
      );
      if (!mounted || !_sameRoot) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(objectList(result['albums']));
        _cursor = result['nextCursor']?.toString() ?? '';
        _loaded = true;
      });
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    if (_busy || !_sameRoot) return;
    var input = '';
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建文件夹相册'),
        content: TextField(
          onChanged: (value) => input = value,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: '相册名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted || !_sameRoot) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/photos/folder-albums',
        body: {'name': name},
      );
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _sameRoot && _error == null) await _load();
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    if (_busy || !_sameRoot) return;
    final name = item['name']?.toString() ?? '';
    if (!await confirmAction(
      context,
      '删除空相册？',
      '相册“$name”只有为空时才能删除；里面有照片或其他文件时会保留。',
      action: '删除空相册',
    )) {
      return;
    }
    if (!mounted || !_sameRoot) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/photos/folder-albums/${Uri.encodeComponent(name)}',
      );
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _sameRoot && _error == null) await _load();
  }

  Future<void> _select(Map<String, dynamic> item) async {
    final name = item['name']?.toString() ?? '';
    final path = item['path']?.toString() ?? '';
    if (name.isEmpty || path.isEmpty || !_sameRoot || _busy) return;
    final source = widget.source;
    if (source == null) {
      Navigator.pop(context, FolderAlbumSelection(name: name, path: path));
      return;
    }
    if ('$path/${source.name}' == source.path) {
      setState(() => _error = '照片已经在这个相册中。');
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('加入“$name”'),
        content: const Text('复制会保留原位置；移动后原位置不再保留该文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: widget.canMove
                ? () => Navigator.pop(dialogContext, 'move')
                : null,
            child: const Text('移动'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'copy'),
            child: const Text('复制'),
          ),
        ],
      ),
    );
    if (action == null || !mounted || !_sameRoot) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/files/operations',
        body: {
          'action': action,
          'from': source.path,
          'to': '$path/${source.name}',
          'conflict': '',
        },
      );
      if (mounted && _sameRoot) {
        Navigator.pop(
          context,
          FolderAlbumSelection(name: name, path: path, moved: action == 'move'),
        );
      }
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const IsleAppBar(title: Text('文件夹相册')),
    body: IsleListView(
      children: [
        const Notice('相册直接对应照片目录中的文件夹；含有文件的相册不能直接删除。'),
        if (!_sameRoot) const Notice('硬盘已变化或尚未选择，请返回后选择原硬盘。', error: true),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_loading) const LinearProgressIndicator(),
        if (_sameRoot)
          OutlinedButton.icon(
            onPressed: _busy ? null : _create,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('新建相册'),
          ),
        if (_sameRoot &&
            _loaded &&
            _items.isEmpty &&
            _cursor.isEmpty &&
            _error == null)
          const Notice('照片目录中还没有文件夹相册。'),
        if (_sameRoot)
          for (final item in _items)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(item['name']?.toString() ?? ''),
              subtitle: Text(widget.source == null ? '照片目录中的文件夹' : '选择复制或移动'),
              onTap: _busy ? null : () => _select(item),
              trailing: widget.source != null
                  ? null
                  : IconButton(
                      tooltip: '删除空相册',
                      onPressed: _busy ? null : () => _delete(item),
                      icon: const Icon(Icons.delete_outline),
                    ),
            ),
        if (_sameRoot && _cursor.isNotEmpty)
          TextButton(
            onPressed: _loading ? null : () => _load(more: true),
            child: const Text('加载更多'),
          ),
      ],
    ),
  );
}
