import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/isle_theme.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

class MissingMediaPage extends StatefulWidget {
  const MissingMediaPage({super.key, required this.api, required this.isAdmin});
  final LightIsleApi api;
  final bool isAdmin;

  @override
  State<MissingMediaPage> createState() => _MissingMediaPageState();
}

class _MissingGroup {
  List<Map<String, dynamic>> items = [];
  String cursor = '';
  String scan = 'not_checked';
  String? error;
  bool loading = false;
  bool loaded = false;
}

class _MissingMediaPageState extends State<MissingMediaPage> {
  final _groups = <String, _MissingGroup>{
    'photos': _MissingGroup(),
    'cinema': _MissingGroup(),
  };
  late final String? _rootIdentity = widget.api.selectedRoot?.identity;
  bool _busy = false;
  String? _message;

  bool get _sameRoot =>
      _rootIdentity != null &&
      widget.api.selectedRoot?.identity == _rootIdentity;

  @override
  void initState() {
    super.initState();
    _load('photos');
    _load('cinema');
  }

  Future<void> _load(String kind, {bool more = false}) async {
    final group = _groups[kind]!;
    if (group.loading || !_sameRoot) return;
    setState(() {
      group.loading = true;
      group.error = null;
    });
    try {
      final result = await widget.api.get(
        '/api/v2/missing-media/$kind',
        query: {
          'limit': '30',
          if (more && group.cursor.isNotEmpty) 'after': group.cursor,
        },
      );
      if (!mounted || !_sameRoot) return;
      setState(() {
        group.items = [
          ...(more ? group.items : <Map<String, dynamic>>[]),
          ...objectList(result['items']),
        ];
        group.cursor = result['nextCursor']?.toString() ?? '';
        final scan = result['scan'];
        group.scan = scan is Map
            ? scan['state']?.toString() ?? 'not_checked'
            : 'not_checked';
        group.loaded = true;
      });
    } catch (error) {
      if (mounted && _sameRoot) {
        setState(() => group.error = '读取失败，列表可能不完整：${userFacingError(error)}');
      }
    } finally {
      if (mounted) setState(() => group.loading = false);
    }
  }

  Future<void> _recheck(String kind) async {
    if (_busy || !_sameRoot) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.api.send('POST', '/api/v2/missing-media/$kind/recheck');
      if (mounted && _sameRoot) {
        setState(() => _message = '检查已开始；完成后请刷新。只有确认是原文件时才会自动恢复关联。');
      }
    } catch (error) {
      if (mounted && _sameRoot) {
        setState(() => _message = '无法开始检查：${userFacingError(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard(String kind, Map<String, dynamic> item) async {
    if (_busy || !_sameRoot) return;
    final confirmed = await confirmAction(
      context,
      '放弃旧记录？',
      '将放弃“${item['path']}”的收藏、相册关联或观看资料，包括其他成员关联的资料。不会删除磁盘上的文件；操作无法撤销。',
      action: '放弃记录',
    );
    if (!confirmed || !mounted || !_sameRoot) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/missing-media/$kind/${item['id']}',
        body: {'confirm': true},
      );
      if (mounted && _sameRoot) setState(() => _message = '旧记录已放弃；磁盘文件未被删除。');
    } catch (error) {
      if (mounted && _sameRoot) {
        setState(() => _message = '无法放弃旧记录：${userFacingError(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _sameRoot) await _load(kind);
  }

  Future<void> _attach(String kind, Map<String, dynamic> item) async {
    if (_busy || !_sameRoot) return;
    final confirmed = await confirmAction(
      context,
      '关联当前文件？',
      '确认原位置“${item['path']}”现在的文件就是要关联的照片或影片？旧收藏、相册关联或观看资料会合并到当前文件；如果不是同一文件，请取消。',
      action: '确认关联',
    );
    if (!confirmed || !mounted || !_sameRoot) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/missing-media/$kind/${item['id']}/attach',
        body: {'confirm': true},
      );
      if (mounted && _sameRoot) setState(() => _message = '旧资料已关联到当前文件。');
    } catch (error) {
      if (mounted && _sameRoot) {
        setState(() => _message = '无法关联：${userFacingError(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _sameRoot) await _load(kind);
  }

  String _reason(Object? value) => switch (value) {
    'identity_changed' => '原位置出现了不同的文件',
    'identity_unverified' => '无法确认当前文件是否为原文件',
    _ => '原位置暂时找不到文件',
  };

  String _dataLabel(Object? value) {
    const labels = {
      'favorites': '收藏',
      'albums': '相册关联',
      'progress': '观看进度',
      'metadata': '影视资料',
    };
    if (value is! List) return '旧资料';
    final names = value
        .map((entry) => labels[entry] ?? entry.toString())
        .toList();
    return names.isEmpty ? '旧资料' : names.join('、');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const IsleAppBar(title: Text('缺失媒体')),
    body: IsleListView(
      children: [
        Notice(
          widget.isAdmin
              ? '当前硬盘各目录的缺失媒体。原有收藏、相册关联和观看资料会保留。'
              : '只显示你在当前硬盘个人目录中的缺失媒体。原有收藏、相册关联和观看资料会保留。',
        ),
        if (!_sameRoot) const Notice('硬盘已变化或尚未选择，请返回后选择原硬盘。', error: true),
        if (_message != null) Notice(_message!),
        if (_sameRoot)
          for (final kind in ['photos', 'cinema']) ...[
            IsleSectionHeader(title: kind == 'photos' ? '照片与视频' : '影视'),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy || !_sameRoot ? null : () => _recheck(kind),
                  child: const Text('重新检查'),
                ),
                TextButton(
                  onPressed: _groups[kind]!.loading || !_sameRoot
                      ? null
                      : () => _load(kind),
                  child: const Text('刷新'),
                ),
              ],
            ),
            if (_groups[kind]!.error != null)
              Notice(_groups[kind]!.error!, error: true),
            if (_groups[kind]!.loading) const LinearProgressIndicator(),
            if (_groups[kind]!.loaded && _groups[kind]!.scan == 'running')
              const Notice('检查正在进行，当前结果尚不完整；完成后请刷新。')
            else if (_groups[kind]!.loaded && _groups[kind]!.scan == 'failed')
              const Notice('上次检查未完成，结果可能不完整。请检查硬盘连接后重新检查。', error: true)
            else if (_groups[kind]!.loaded &&
                _groups[kind]!.scan == 'not_checked')
              const Notice('尚未完成检查，当前结果可能不完整。')
            else if (_groups[kind]!.loaded && _groups[kind]!.scan == 'finished')
              const Notice('最近一次检查已结束；如果只检查了部分目录，其他目录可能尚未核对。'),
            if (_groups[kind]!.loaded &&
                _groups[kind]!.items.isEmpty &&
                _groups[kind]!.error == null)
              const Notice('当前没有已发现的缺失记录。'),
            for (final item in _groups[kind]!.items)
              ListTile(
                title: Text(item['path']?.toString() ?? ''),
                subtitle: Text(
                  '${_reason(item['reason'])} · 保留：${_dataLabel(item['data'])}${item['canManage'] == true ? '' : ' · 当前没有写入权限，请联系管理员'}',
                ),
                trailing: PopupMenuButton<String>(
                  tooltip: '处理缺失媒体',
                  enabled: !_busy && _sameRoot && item['canManage'] == true,
                  onSelected: (value) {
                    if (value == 'attach') _attach(kind, item);
                    if (value == 'discard') _discard(kind, item);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'attach', child: Text('关联当前文件')),
                    PopupMenuItem(value: 'discard', child: Text('放弃旧记录')),
                  ],
                ),
              ),
            if (_groups[kind]!.cursor.isNotEmpty)
              TextButton(
                onPressed: _groups[kind]!.loading
                    ? null
                    : () => _load(kind, more: true),
                child: const Text('加载更多'),
              ),
          ],
      ],
    ),
  );
}
