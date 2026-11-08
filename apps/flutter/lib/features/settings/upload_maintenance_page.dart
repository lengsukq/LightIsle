import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';

class UploadMaintenancePage extends StatefulWidget {
  const UploadMaintenancePage({super.key, required this.api});
  final LightIsleApi api;
  @override
  State<UploadMaintenancePage> createState() => _UploadMaintenancePageState();
}

class _UploadMaintenancePageState extends State<UploadMaintenancePage> {
  List<Map<String, dynamic>> _items = [];
  String _cursor = '';
  String? _error, _message;
  bool _busy = false, _loaded = false;
  int _days = 30;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.get(
        '/api/v2/admin/uploads',
        query: {
          'limit': '20',
          if (more && _cursor.isNotEmpty) 'after': _cursor,
        },
      );
      if (mounted) {
        setState(() {
          _items = [
            ...(more ? _items : <Map<String, dynamic>>[]),
            ...objectList(r['uploads']),
          ];
          _cursor = r['nextCursor']?.toString() ?? '';
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> item) async {
    if (!await confirmAction(
      context,
      '取消上传',
      '将清理 ${item['path']} 的未完成上传，之后需要重新上传。',
      action: '取消并清理',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send('DELETE', '/api/v2/admin/uploads/${item['id']}');
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  Future<void> _cleanup() async {
    final days = _days;
    if (!await confirmAction(
      context,
      '清理过期上传',
      '清理至少 $days 天未活动的上传分片，清理后无法续传。不会删除已完成的原始文件。',
      action: '清理分片',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final r = await widget.api.send(
        'POST',
        '/api/v2/admin/uploads/cleanup-expired',
        body: {'inactiveForSeconds': days * 86400},
      );
      if (mounted) {
        setState(
          () => _message =
              '已清理 ${r['removed']} 项，跳过 ${r['skipped']} 项。${(r['pendingReservations'] as num? ?? 0) > 0 ? '${r['pendingReservations']} 项容量预占仍需在管理员任务中心检查。' : ''}${r['hasMore'] == true ? '仍有更多，可再次执行清理。' : ''}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(
      title: const Text('上传维护'),
      actions: [
        IconButton(
          tooltip: '刷新上传',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: IsleListView(
      children: [
        if (_message != null) Notice(_message!),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_loaded && _items.isEmpty) const Notice('没有待维护的上传。'),
        DropdownButtonFormField<int>(
          initialValue: _days,
          decoration: const InputDecoration(labelText: '未活动时间'),
          items: [7, 30, 90]
              .map((d) => DropdownMenuItem(value: d, child: Text('$d 天')))
              .toList(),
          onChanged: _busy ? null : (v) => setState(() => _days = v!),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy ? null : _cleanup,
            child: const Text('清理过期上传'),
          ),
        ),
        if (_items.isNotEmpty)
          IsleResponsiveGrid(
            minItemWidth: 300,
            maxColumns: 3,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final item in _items)
                IsleSurface(
                  radius: 16,
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    leading: IsleSquircleBadge(
                      icon: Icons.cloud_upload_outlined,
                      color: IslePalette.of(context)['brandCyan'],
                      size: 36,
                      iconSize: 19,
                    ),
                    title: Text(
                      item['path']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '账号：${item['ownerName'] ?? '已删除'} · '
                      '${formatBytes(item['offset'] as num?)} / ${formatBytes(item['size'] as num?)}'
                      '${item['orphan'] == true || item['corrupt'] == true ? '\n上传分片异常' : ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _cancel(item),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      child: const Text('取消并清理'),
                    ),
                  ),
                ),
            ],
          ),
        if (!_busy && _cursor.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: () => _load(more: true),
                child: const Text('加载更多'),
              ),
            ),
          ),
      ],
    ),
  );
}
