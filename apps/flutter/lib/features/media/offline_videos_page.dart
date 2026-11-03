import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'local_video_page.dart';
import 'media_ui.dart';
import 'offline_video_store.dart';

class OfflineVideosPage extends StatefulWidget {
  const OfflineVideosPage({
    super.key,
    required this.api,
    required this.accountName,
  });

  final LightIsleApi api;
  final String accountName;

  @override
  State<OfflineVideosPage> createState() => _OfflineVideosPageState();
}

class _OfflineVideosPageState extends State<OfflineVideosPage> {
  late final OfflineVideoStore _store = OfflineVideoStore(
    api: widget.api,
    accountName: widget.accountName,
  );
  List<OfflineVideo> _items = [];
  bool _loading = true;
  String? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _maintain(String action) async {
    if (_busy != null || _loading) return;
    if (action == 'clear') {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('清空当前离线影片库？'),
          content: const Text(
            '将永久删除当前账号、服务器和存储位置下的所有本机离线影片。NAS 原文件不会删除，其他账号及硬盘位置不受影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除所有本机副本'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    setState(() => _busy = 'maintenance');
    try {
      if (action == 'clear') {
        await _store.clear();
      } else {
        final removed = await _store.cleanupUnusedFiles();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已清理 $removed 个没有关联索引的旧缓存文件。')),
          );
        }
      }
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '本机缓存整理失败：$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _store.list();
      if (mounted) setState(() => _items = rows);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(OfflineVideo item) async {
    try {
      final file = await _store.fileFor(item);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LocalVideoPage(path: file.path),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '打开离线视频失败：$error');
    }
  }

  Future<void> _remove(OfflineVideo item) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除离线副本？'),
        content: Text('只删除设备中的“${item.title}”，NAS 原文件不会改变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除副本'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => _busy = item.fileName);
    try {
      await _store.remove(item);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '删除失败：$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String _formatBytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('离线影片'),
      actions: [
        PopupMenuButton<String>(
          tooltip: '离线存储管理',
          enabled: !_loading && _busy == null,
          onSelected: (action) => unawaited(_maintain(action)),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'cleanup', child: Text('清理未关联的旧缓存')),
            PopupMenuItem(value: 'clear', child: Text('清空当前离线影片库')),
          ],
        ),
        IconButton(
          tooltip: '刷新离线库',
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: SafeArea(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : IsleListView(
              children: [
                if (_error != null)
                  Notice(_error!, error: true, onRetry: _refresh),
                if (_items.isEmpty)
                  MediaEmptyState(
                    icon: Icons.offline_pin_outlined,
                    title: '还没有离线影片',
                    message: '在影院详情选择“保存到离线库”，即可在断网时播放。',
                  )
                else
                  IsleGroupCard(
                    children: [
                      for (final item in _items)
                        ListTile(
                          leading: const Icon(Icons.offline_pin_outlined),
                          title: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_formatBytes(item.size)} · 已保存在本设备',
                          ),
                          enabled: _busy == null,
                          onTap: () => unawaited(_play(item)),
                          trailing: IconButton(
                            tooltip: '删除离线副本',
                            onPressed: _busy == null
                                ? () => _remove(item)
                                : null,
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
    ),
  );
}
