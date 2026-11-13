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
    this.completedCount = 1,
  });
  final String name;
  final String path;
  final bool moved;
  final int completedCount;
}

/// Lists actual directories under the current user's assigned photos folder.
/// Legacy database albums remain available separately in the existing view.
class FolderAlbumsPage extends StatefulWidget {
  const FolderAlbumsPage({
    super.key,
    required this.api,
    this.source,
    this.sources = const [],
    this.canMove = false,
  });
  final LightIsleApi api;
  final PhotoAsset? source;
  final List<PhotoAsset> sources;
  final bool canMove;

  @override
  State<FolderAlbumsPage> createState() => _FolderAlbumsPageState();
}

class _FolderAlbumsPageState extends State<FolderAlbumsPage> {
  late final String? _root = widget.api.selectedRoot?.identity;
  final _items = <Map<String, dynamic>>[];
  final _shareTargets = <Map<String, dynamic>>[];
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
        if (!more) {
          _items.clear();
          _shareTargets
            ..clear()
            ..addAll(objectList(result['shareTargets']));
        }
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
      if (mounted && _sameRoot) await _load();
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _isPickingDestination =>
      widget.source != null || widget.sources.isNotEmpty;

  String _albumSubtitle(Map<String, dynamic> item) {
    final shared = item['shared'] == true;
    final canWrite = item['canWrite'] != false;
    if (shared) {
      final owner = item['ownerUsername']?.toString() ?? '';
      return '来自 @$owner · ${canWrite ? '可读写' : '只读'}';
    }
    if (_isPickingDestination) return '选择复制或移动';
    final shares = objectList(item['shares']);
    if (shares.isNotEmpty) return '照片目录中的文件夹 · 已共享给 ${shares.length} 人';
    return '照片目录中的文件夹';
  }

  Future<void> _leaveShared(Map<String, dynamic> item) async {
    if (_busy || !_sameRoot) return;
    final name = item['name']?.toString() ?? '';
    final ownerUsername = item['ownerUsername']?.toString() ?? '';
    final ownerId = int.tryParse(item['ownerUserId']?.toString() ?? '') ?? 0;
    final memberId = int.tryParse(item['memberUserId']?.toString() ?? '') ?? 0;
    if (!await confirmAction(
      context,
      '退出共享相册？',
      '将从你的照片目录移除来自 @$ownerUsername 的“$name”受控软链接；对方相册中的原始照片不会删除。',
      action: '退出共享',
    )) {
      return;
    }
    if (!mounted || !_sameRoot) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final memberSegment = memberId > 0 ? '$memberId' : 'me';
      await widget.api.send(
        'DELETE',
        '/api/v2/photos/folder-albums/${Uri.encodeComponent(name)}/shares/$memberSegment',
        query: {if (ownerId > 0) 'ownerUserId': '$ownerId'},
      );
      if (mounted && _sameRoot) await _load();
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manageShares(Map<String, dynamic> item) async {
    if (_busy || !_sameRoot) return;
    final name = item['name']?.toString() ?? '';
    final shares = objectList(item['shares']);
    final validTargets = <Map<String, dynamic>>[];
    final seenMemberIds = <int>{};
    for (final target in _shareTargets) {
      final uid = int.tryParse(target['userId']?.toString() ?? '') ?? 0;
      if (uid > 0 && seenMemberIds.add(uid)) {
        validTargets.add(target);
      }
    }
    int? selectedMemberId = validTargets.isNotEmpty
        ? int.tryParse(validTargets.first['userId']?.toString() ?? '')
        : null;
    bool canWrite = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('共享“$name”'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('在所选家庭成员的照片目录中创建受控软链接；对方无需复制文件即可浏览。'),
                const SizedBox(height: 12),
                if (validTargets.isEmpty)
                  const Text('暂无其他已分配照片目录的家庭成员。')
                else ...[
                  DropdownButtonFormField<int>(
                    initialValue: seenMemberIds.contains(selectedMemberId)
                        ? selectedMemberId
                        : null,
                    decoration: const InputDecoration(labelText: '选择家庭成员'),
                    items: [
                      for (final target in validTargets)
                        DropdownMenuItem<int>(
                          value: int.parse(target['userId'].toString()),
                          child: Text(target['username']?.toString() ?? ''),
                        ),
                    ],
                    onChanged: (val) =>
                        setDialogState(() => selectedMemberId = val),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: canWrite,
                    title: const Text('允许上传（写入计入我的配额）'),
                    onChanged: (val) =>
                        setDialogState(() => canWrite = val == true),
                  ),
                ],
                if (shares.isNotEmpty) ...[
                  const Divider(),
                  const Text('已共享成员：'),
                  for (final s in shares)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('@${s['memberUsername']}'),
                      subtitle: Text(s['canWrite'] == true ? '可读写' : '只读'),
                      trailing: TextButton(
                        onPressed: () async {
                          final memberId =
                              int.tryParse(
                                s['memberUserId']?.toString() ?? '',
                              ) ??
                              0;
                          Navigator.pop(dialogContext);
                          await _removeShare(name, memberId);
                        },
                        child: const Text('移除'),
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            if (validTargets.isNotEmpty)
              FilledButton(
                onPressed: (selectedMemberId ?? 0) <= 0
                    ? null
                    : () async {
                        final targetId = selectedMemberId!;
                        Navigator.pop(dialogContext);
                        await _setShare(name, targetId, canWrite);
                      },
                child: const Text('确认共享'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _setShare(String name, int memberId, bool canWrite) async {
    if (_busy || !_sameRoot) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/photos/folder-albums/${Uri.encodeComponent(name)}/shares',
        body: {'memberUserId': memberId, 'canWrite': canWrite},
      );
      if (mounted && _sameRoot) await _load();
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeShare(String name, int memberId) async {
    if (_busy || !_sameRoot || memberId <= 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/photos/folder-albums/${Uri.encodeComponent(name)}/shares/$memberId',
      );
      if (mounted && _sameRoot) await _load();
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      if (mounted && _sameRoot) await _load();
    } catch (error) {
      if (mounted && _sameRoot) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(Map<String, dynamic> item) async {
    final name = item['name']?.toString() ?? '';
    final path = item['path']?.toString() ?? '';
    if (name.isEmpty || path.isEmpty || !_sameRoot || _busy) return;
    final batch = widget.sources.isNotEmpty
        ? widget.sources
        : widget.source != null
        ? <PhotoAsset>[widget.source!]
        : const <PhotoAsset>[];
    if (batch.isEmpty) {
      Navigator.pop(context, FolderAlbumSelection(name: name, path: path));
      return;
    }
    if (batch.length == 1 && '$path/${batch.first.name}' == batch.first.path) {
      setState(() => _error = '照片已经在这个相册中。');
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          batch.length == 1 ? '加入“$name”' : '加入“$name”（共 ${batch.length} 项）',
        ),
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
    var done = 0;
    try {
      final isBatch = widget.sources.isNotEmpty;
      for (final asset in batch) {
        if (!mounted || !_sameRoot) break;
        final to = '$path/${asset.name}';
        if (asset.path == to) {
          done++;
          continue;
        }
        await widget.api.send(
          'POST',
          '/api/v2/files/operations',
          body: {
            'action': action,
            'from': asset.path,
            'to': to,
            'conflict': isBatch ? 'rename' : '',
          },
        );
        done++;
      }
      if (mounted && _sameRoot) {
        Navigator.pop(
          context,
          FolderAlbumSelection(
            name: name,
            path: path,
            moved: action == 'move',
            completedCount: done,
          ),
        );
      }
    } catch (error) {
      if (mounted && _sameRoot) {
        setState(
          () => _error = done > 0
              ? '已完成 $done/${batch.length} 项，剩余停止：${userFacingError(error)}'
              : userFacingError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const IsleAppBar(title: Text('文件夹相册')),
    body: IsleListView(
      children: [
        IsleIntroCard(
          icon: Icons.photo_album_rounded,
          title: '目录直连相册',
          description: '相册直接对应照片目录中的文件夹；含有文件的相册不能直接删除。',
          actions: [
            if (_sameRoot)
              OutlinedButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('新建相册'),
              ),
          ],
        ),
        if (!_sameRoot) const Notice('硬盘已变化或尚未选择，请返回后选择原硬盘。', error: true),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_loading && _items.isEmpty)
          const IsleLoadingState(label: '正在加载文件夹相册…')
        else if (_loading)
          const LinearProgressIndicator(),
        Builder(
          builder: (context) {
            final visibleItems = _isPickingDestination
                ? _items
                      .where((item) => item['canWrite'] != false)
                      .toList(growable: false)
                : _items;
            if (_sameRoot &&
                _loaded &&
                !_loading &&
                visibleItems.isEmpty &&
                _cursor.isEmpty &&
                _error == null) {
              return IsleEmptyStateCard(
                _isPickingDestination
                    ? '当前没有可写入的目标相册。可先新建相册，或选择非只读共享相册。'
                    : '照片目录中还没有文件夹相册。',
                icon: Icons.folder_special_outlined,
              );
            }
            if (!_sameRoot || visibleItems.isEmpty) {
              return const SizedBox.shrink();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IsleSectionHeader(title: '相册列表（${visibleItems.length}）'),
                IsleResponsiveGrid(
                  minItemWidth: 280,
                  maxColumns: 3,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final item in visibleItems)
                      IsleSurface(
                        padding: EdgeInsets.zero,
                        radius: 14,
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          visualDensity: VisualDensity.compact,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          leading: IsleSquircleBadge(
                            icon: item['shared'] == true
                                ? Icons.folder_shared_outlined
                                : Icons.folder_outlined,
                            color: item['shared'] == true
                                ? const Color(0xff0ea5e9)
                                : const Color(0xffec4899),
                            size: 34,
                            iconSize: 18,
                          ),
                          title: Text(
                            item['name']?.toString() ?? '',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(_albumSubtitle(item)),
                          onTap: _busy ? null : () => _select(item),
                          trailing: _isPickingDestination
                              ? null
                              : item['shared'] == true
                              ? IconButton(
                                  tooltip: '退出共享',
                                  onPressed: _busy
                                      ? null
                                      : () => _leaveShared(item),
                                  icon: const Icon(Icons.logout_rounded),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: '共享给家人',
                                      onPressed: _busy
                                          ? null
                                          : () => _manageShares(item),
                                      icon: const Icon(Icons.share_outlined),
                                    ),
                                    IconButton(
                                      tooltip: '删除空相册',
                                      onPressed: _busy
                                          ? null
                                          : () => _delete(item),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
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
