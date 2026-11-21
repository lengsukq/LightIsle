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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        title: const Text('新建文件夹相册'),
        content: TextField(
          onChanged: (value) => input = value,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(isDense: true, labelText: '相册名称'),
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

  String? _albumSubtitle(Map<String, dynamic> item) {
    final shared = item['shared'] == true;
    final canWrite = item['canWrite'] != false;
    if (shared) {
      final owner = item['ownerUsername']?.toString() ?? '';
      return '来自 @$owner · ${canWrite ? '可读写' : '只读'}';
    }
    final shares = objectList(item['shares']);
    if (shares.isNotEmpty) return '已共享给 ${shares.length} 人';
    return null;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(color: borderColor, width: 1.0),
          ),
          title: Text('共享“$name”'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (validTargets.isEmpty)
                    const Text('暂无其他已分配照片目录的家庭成员。')
                  else ...[
                    DropdownButtonFormField<int>(
                      initialValue: seenMemberIds.contains(selectedMemberId)
                          ? selectedMemberId
                          : null,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '选择家庭成员',
                      ),
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
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: canWrite,
                      title: const Text(
                        '允许上传（写入计入我的配额）',
                        style: TextStyle(fontSize: 13),
                      ),
                      onChanged: (val) =>
                          setDialogState(() => canWrite = val == true),
                    ),
                  ],
                  if (shares.isNotEmpty) ...[
                    Divider(height: 16, thickness: 1, color: borderColor),
                    const Text(
                      '已共享成员：',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final s in shares)
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '@${s['memberUsername']}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          s['canWrite'] == true ? '可读写' : '只读',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        trailing: TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
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

  Widget _buildAlbumTile(Map<String, dynamic> item, IslePalette palette) {
    final shared = item['shared'] == true;
    final sub = _albumSubtitle(item);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      leading: IsleSquircleBadge(
        icon: shared ? Icons.folder_shared_outlined : Icons.folder_outlined,
        color: shared ? palette['brandBlue'] : palette['brandRose'],
        size: 32,
        iconSize: 16.5,
      ),
      title: Text(
        item['name']?.toString() ?? '',
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
      subtitle: sub == null
          ? null
          : Text(sub, style: const TextStyle(fontSize: 12)),
      onTap: _busy ? null : () => _select(item),
      trailing: _isPickingDestination
          ? const Icon(Icons.chevron_right_rounded, size: 18)
          : PopupMenuButton<String>(
              tooltip: '更多操作',
              enabled: !_busy,
              icon: const Icon(Icons.more_horiz_rounded, size: 18),
              onSelected: (action) {
                switch (action) {
                  case 'share':
                    _manageShares(item);
                  case 'delete':
                    _delete(item);
                  case 'leave':
                    _leaveShared(item);
                }
              },
              itemBuilder: (_) => [
                if (shared)
                  const PopupMenuItem(
                    value: 'leave',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.logout_rounded, size: 18),
                      title: Text('退出共享'),
                    ),
                  )
                else ...[
                  const PopupMenuItem(
                    value: 'share',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.share_outlined, size: 18),
                      title: Text('共享给家人'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline, size: 18),
                      title: Text('删除空相册'),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final rose = palette['brandRose'];
    final sharedCount = _items.where((i) => i['shared'] == true).length;

    return Scaffold(
      appBar: const IsleAppBar(title: Text('文件夹相册')),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.photo_album_rounded,
            accent: rose,
            title: '目录直连相册',
            metrics: [
              IsleFocalMetric(
                label: '全部相册',
                value: '${_items.length}',
                accent: rose,
              ),
              IsleFocalMetric(
                label: '来自家人共享',
                value: '$sharedCount',
                accent: palette['brandBlue'],
              ),
            ],
            actions: [
              if (_sameRoot)
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 17),
                  label: const Text('新建相册'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (!_sameRoot) const Notice('硬盘已变化或尚未选择，请返回后选择原硬盘。', error: true),
          if (_error != null) Notice(_error!, error: true, onRetry: _load),
          if (_loading && _items.isEmpty)
            const IsleLoadingState(compact: true, label: '正在加载文件夹相册…')
          else if (_loading)
            const LinearProgressIndicator(minHeight: 2),
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
                  IsleSectionHeader(
                    title: '相册列表（${visibleItems.length}）',
                    accentColor: rose,
                  ),
                  IsleAdaptiveBuilder(
                    builder: (context, tier, width) {
                      final textScale =
                          MediaQuery.textScalerOf(context).scale(14) / 14;
                      if (tier == IsleViewportTier.expanded &&
                          visibleItems.length > 1 &&
                          textScale <= 1.35) {
                        final cardWidth = (width - 12) / 2;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            for (final item in visibleItems)
                              SizedBox(
                                width: cardWidth,
                                child: IsleSurface(
                                  margin: EdgeInsets.zero,
                                  padding: EdgeInsets.zero,
                                  child: _buildAlbumTile(item, palette),
                                ),
                              ),
                          ],
                        );
                      }
                      return IsleSurface(
                        margin: EdgeInsets.zero,
                        padding: EdgeInsets.zero,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < visibleItems.length; i++) ...[
                              if (i > 0)
                                Divider(
                                  height: 1,
                                  thickness: 1,
                                  indent: 54,
                                  color: borderColor,
                                ),
                              _buildAlbumTile(visibleItems[i], palette),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
          if (_sameRoot && _cursor.isNotEmpty)
            Align(
              alignment: Alignment.center,
              child: TextButton(
                onPressed: _loading ? null : () => _load(more: true),
                child: const Text('加载更多'),
              ),
            ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
