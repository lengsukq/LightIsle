import 'dart:async';

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
  int revision = 0;
  bool tracking = false;
  int scanRevision = 0;
  Timer? timer;
}

class _MissingMediaPageState extends State<MissingMediaPage>
    with WidgetsBindingObserver {
  final _groups = <String, _MissingGroup>{
    'photos': _MissingGroup(),
    'cinema': _MissingGroup(),
  };
  late final String? _rootIdentity = widget.api.selectedRoot?.identity;
  late final int _rootSelectionRevision = widget.api.rootSelectionRevision;
  bool _busy = false;
  bool _visible = true;
  String? _message;

  bool get _sameRoot =>
      _rootIdentity != null &&
      widget.api.rootSelectionRevision == _rootSelectionRevision &&
      widget.api.selectedRoot?.identity == _rootIdentity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load('photos');
    _load('cinema');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final group in _groups.values) {
      group.scanRevision++;
      group.timer?.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    for (final kind in _groups.keys) {
      final group = _groups[kind]!;
      if (!_visible) {
        group.scanRevision++;
        group.timer?.cancel();
        group.timer = null;
      } else {
        _scheduleScan(kind);
      }
    }
  }

  Future<void> _load(
    String kind, {
    bool more = false,
    bool force = false,
  }) async {
    final group = _groups[kind]!;
    if ((group.loading && !force) || !_sameRoot) return;
    final revision = ++group.revision;
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
      if (!mounted || !_sameRoot || group.revision != revision) return;
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
      if (group.scan == 'running' && !group.tracking) _trackScan(kind);
    } catch (error) {
      if (mounted && _sameRoot && group.revision == revision) {
        setState(() => group.error = '读取失败，列表可能不完整：${userFacingError(error)}');
      }
    } finally {
      if (mounted && group.revision == revision) {
        setState(() => group.loading = false);
      }
    }
  }

  void _trackScan(String kind) {
    final group = _groups[kind]!;
    group.timer?.cancel();
    setState(() {
      group.timer = null;
      group.tracking = true;
      group.scanRevision++;
      group.revision++;
      group.loading = false;
      group.error = null;
      group.scan = 'running';
    });
    _scheduleScan(kind);
  }

  void _scheduleScan(String kind) {
    final group = _groups[kind]!;
    if (!mounted ||
        !_sameRoot ||
        !_visible ||
        !group.tracking ||
        group.timer != null) {
      return;
    }
    final revision = group.scanRevision;
    group.timer = Timer(const Duration(seconds: 3), () {
      group.timer = null;
      _pollScan(kind, revision);
    });
  }

  Future<void> _pollScan(String kind, int revision) async {
    final group = _groups[kind]!;
    if (!mounted ||
        !_sameRoot ||
        !_visible ||
        !group.tracking ||
        group.scanRevision != revision) {
      return;
    }
    try {
      final result = await widget.api.get(
        '/api/v2/missing-media/$kind',
        query: {'limit': '1'},
      );
      if (!mounted ||
          !_sameRoot ||
          !_visible ||
          !group.tracking ||
          group.scanRevision != revision) {
        return;
      }
      final scan = result['scan'];
      final state = scan is Map
          ? scan['state']?.toString() ?? 'not_checked'
          : 'not_checked';
      setState(() => group.scan = state);
      if (state == 'running') {
        _scheduleScan(kind);
      } else {
        group.tracking = false;
        await _load(kind, force: true);
      }
    } catch (error) {
      if (!mounted ||
          !_sameRoot ||
          !_visible ||
          !group.tracking ||
          group.scanRevision != revision) {
        return;
      }
      setState(() {
        group.tracking = false;
        group.scan = 'not_checked';
        group.error = '无法自动读取检查进度，请刷新列表核对：${userFacingError(error)}';
      });
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
        _trackScan(kind);
        setState(() => _message = '检查已开始，完成后列表会自动更新。只有确认是原文件时才会自动恢复关联。');
      }
    } catch (error) {
      if (mounted && _sameRoot) {
        if (error is LightIsleApiException && error.code == 'scan_running') {
          _trackScan(kind);
          setState(() => _message = '检查正在进行，完成后列表会自动更新。');
        } else {
          setState(() => _message = '无法开始检查：${userFacingError(error)}');
        }
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
      if (mounted && _sameRoot) {
        setState(() {
          _groups[kind]!.items.removeWhere(
            (entry) => entry['id'] == item['id'],
          );
          _groups[kind]!.cursor = '';
          _message = '旧记录已放弃；磁盘文件未被删除。';
        });
      }
    } catch (error) {
      if (mounted && _sameRoot) {
        setState(
          () => _message = '未能确认处理结果，请核对列表后再操作：${userFacingError(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _sameRoot) await _load(kind, force: true);
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
      if (mounted && _sameRoot) {
        setState(() {
          _groups[kind]!.items.removeWhere(
            (entry) => entry['id'] == item['id'],
          );
          _groups[kind]!.cursor = '';
          _message = '旧资料已关联到当前文件。';
        });
      }
    } catch (error) {
      if (mounted && _sameRoot) {
        setState(
          () => _message = '未能确认关联结果，请核对列表后再操作：${userFacingError(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _sameRoot) await _load(kind, force: true);
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
        IsleIntroCard(
          icon: Icons.broken_image_outlined,
          title: '缺失媒体与历史关联恢复',
          description: widget.isAdmin
              ? '当前硬盘各目录的缺失媒体。原有收藏、相册关联和观看资料会保留。'
              : '只显示你在当前硬盘个人目录中的缺失媒体。原有收藏、相册关联和观看资料会保留。',
        ),
        if (!_sameRoot) const Notice('硬盘已变化或尚未选择，请返回后选择原硬盘。', error: true),
        if (_message != null) Notice(_message!),
        if (_sameRoot)
          for (final kind in ['photos', 'cinema']) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IsleSquircleBadge(
                        icon: kind == 'photos'
                            ? Icons.photo_library_rounded
                            : Icons.movie_rounded,
                        color: kind == 'photos'
                            ? const Color(0xffec4899)
                            : const Color(0xfff97316),
                        size: 28,
                        iconSize: 15,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        kind == 'photos' ? '照片与视频' : '影视',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton(
                        onPressed: _busy || !_sameRoot
                            ? null
                            : () => _recheck(kind),
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
                ],
              ),
            ),
            if (_groups[kind]!.error != null)
              Notice(_groups[kind]!.error!, error: true),
            if (_groups[kind]!.loading) const LinearProgressIndicator(),
            if (_groups[kind]!.loaded && _groups[kind]!.scan == 'running')
              const Notice('检查正在进行，当前结果尚不完整；完成后会自动更新。')
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
              IsleSurface(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                radius: 14,
                child: Row(
                  children: [
                    IsleSquircleBadge(
                      icon: Icons.verified_outlined,
                      color: const Color(0xff10b981),
                      size: 28,
                      iconSize: 16,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '当前没有已发现的缺失记录。',
                        style: TextStyle(fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            if (_groups[kind]!.items.isNotEmpty)
              IsleResponsiveGrid(
                minItemWidth: 320,
                maxColumns: 2,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in _groups[kind]!.items)
                    IsleSurface(
                      margin: EdgeInsets.zero,
                      padding: EdgeInsets.zero,
                      radius: 14,
                      child: ListTile(
                        dense: true,
                        leading: IsleSquircleBadge(
                          icon: kind == 'photos'
                              ? Icons.hide_image_outlined
                              : Icons.videocam_off_outlined,
                          color: const Color(0xfff59e0b),
                          size: 32,
                          iconSize: 17,
                        ),
                        title: Text(item['path']?.toString() ?? ''),
                        subtitle: Text(
                          '${_reason(item['reason'])} · 保留：${_dataLabel(item['data'])}${item['canManage'] == true ? '' : ' · 当前没有写入权限，请联系管理员'}',
                        ),
                        trailing: PopupMenuButton<String>(
                          tooltip: '处理缺失媒体',
                          enabled:
                              !_busy && _sameRoot && item['canManage'] == true,
                          onSelected: (value) {
                            if (value == 'attach') _attach(kind, item);
                            if (value == 'discard') _discard(kind, item);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'attach',
                              child: Text('关联当前文件'),
                            ),
                            PopupMenuItem(
                              value: 'discard',
                              child: Text('放弃旧记录'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
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
