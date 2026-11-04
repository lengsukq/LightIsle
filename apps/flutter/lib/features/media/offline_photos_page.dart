import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../files/files_page.dart';
import 'offline_photo_store.dart';
import 'photo_zoom_surface.dart';

/// Browses only app-private, verified offline photo originals. The page makes
/// no network request on open, preview, deletion or export.
class OfflinePhotosPage extends StatefulWidget {
  const OfflinePhotosPage({
    super.key,
    required this.api,
    required this.accountId,
  });
  final LightIsleApi api;
  final String accountId;

  @override
  State<OfflinePhotosPage> createState() => _OfflinePhotosPageState();
}

class _OfflinePhotosPageState extends State<OfflinePhotosPage> {
  late final OfflinePhotoStore _store = OfflinePhotoStore(
    api: widget.api,
    accountId: widget.accountId,
  );
  List<OfflinePhoto> _items = const [];
  bool _loading = true, _busy = false;
  String? _message;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final epoch = ++_epoch;
    if (mounted) {
      setState(() {
        _loading = true;
        _message = null;
      });
    }
    try {
      final list = await _store.list();
      if (mounted && epoch == _epoch) {
        setState(() => _items = list.reversed.toList());
      }
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() => _message = userFacingError(error));
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Future<void> _view(OfflinePhoto photo) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final original = await _store.fileFor(photo);
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: Scaffold(
            appBar: IsleAppBar(title: Text(photo.title)),
            body: Column(
              children: [
                Expanded(
                  child: photo.previewable
                      ? PhotoZoomSurface(
                          onSwipeDown: () => Navigator.of(context).pop(),
                          child: Image.file(
                            original,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stack) =>
                                const Center(
                                  child: Text('系统无法解码此原图，请选择“导出原件”使用专业软件打开。'),
                                ),
                          ),
                        )
                      : const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              '这是已完整保存的 HEIC/RAW 等相机原件。'
                              '当前 Flutter 图像解码器不支持直接显示这种格式，'
                              '请通过系统导出保存原始文件；不会修改或转码。',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, 'export'),
                      icon: const Icon(Icons.save_alt),
                      label: const Text('导出原件'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (action == 'export') {
        final message = await exportOfflineMediaFile(original, photo.title);
        if (mounted) setState(() => _message = message);
      }
    } catch (error) {
      if (mounted) setState(() => _message = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(OfflinePhoto photo) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final file = await _store.fileFor(photo);
      final result = await exportOfflineMediaFile(file, photo.title);
      if (mounted) setState(() => _message = result);
    } catch (error) {
      if (mounted) setState(() => _message = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(OfflinePhoto photo) async {
    if (_busy) return;
    final choice = await confirmAction(
      context,
      '删除离线照片',
      '仅删除当前设备上“${photo.title}”的离线副本，NAS 原件不会受到影响。',
      action: '删除本机副本',
      isDestructive: true,
    );
    if (!choice || !mounted) return;
    setState(() => _busy = true);
    try {
      await _store.remove(photo);
      if (mounted) {
        setState(() {
          _items = _items.where((p) => p.fileName != photo.fileName).toList();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(
      title: const Text('本机离线照片'),
      actions: [
        IconButton(
          tooltip: '刷新本机离线照片',
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: IsleListView(
      children: [
        if (_loading || _busy) const LinearProgressIndicator(),
        if (_message != null) Notice(_message!, error: true, onRetry: _refresh),
        if (!_loading && _items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('还没有保存的离线照片。请在图库中打开照片，选择“离线保存”。')),
          ),
        if (_items.isNotEmpty)
          IsleResponsiveGrid(
            minItemWidth: 320,
            maxColumns: 2,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final photo in _items)
                IsleSurface(
                  radius: 16,
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      photo.previewable
                          ? Icons.photo_outlined
                          : Icons.insert_drive_file_outlined,
                    ),
                    title: Text(
                      photo.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${(photo.size / (1 << 20)).toStringAsFixed(1)} MiB'
                      ' · ${photo.previewable ? '可预览' : '原件可导出'}',
                    ),
                    onTap: _busy ? null : () => _view(photo),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '导出离线原件',
                          onPressed: _busy ? null : () => _export(photo),
                          icon: const Icon(Icons.save_alt),
                        ),
                        IconButton(
                          tooltip: '删除本机副本',
                          onPressed: _busy ? null : () => _remove(photo),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        const IsleHelpDisclosure(
          summary: '离线副本不会修改 NAS 原件',
          details:
              '离线副本按账号和物理硬盘位置分别存储。本页无需 NAS 在线。'
              'RAW/HEIC 原件可完整保存并通过系统导出，即使手机无法预览也不会丢失原始文件。',
        ),
      ],
    ),
  );
}
