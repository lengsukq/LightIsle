import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
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

  Widget _buildDomainPanel(
    BuildContext context, {
    required String kind,
    required bool isDark,
    required IslePalette palette,
  }) {
    final group = _groups[kind]!;
    final isPhotos = kind == 'photos';
    final domainColor = isPhotos
        ? palette['brandRose']
        : palette['brandTerracotta'];

    return IsleSurface(
      padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: isPhotos
                    ? Icons.photo_library_rounded
                    : Icons.movie_rounded,
                color: domainColor,
                size: 32,
                iconSize: 17,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isPhotos ? '照片与视频' : '影视',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                      ),
                    ),
                    Text(
                      group.loaded ? '${group.items.length} 条记录' : '核对中…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: palette['secondaryText'],
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _busy || !_sameRoot ? null : () => _recheck(kind),
                child: const Text('重新检查'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (group.error != null) Notice(group.error!, error: true),
          if (group.loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: IsleRadius.brPill,
                child: const LinearProgressIndicator(minHeight: 3),
              ),
            ),
          if (group.loaded && group.scan == 'running')
            const Notice('检查正在进行，完成后会自动更新。')
          else if (group.loaded && group.scan == 'failed')
            const Notice('上次检查未完成，请检查硬盘连接后重新检查。', error: true)
          else if (group.loaded && group.scan == 'not_checked')
            const Notice('尚未完成检查，当前结果可能不完整。')
          else if (group.loaded && group.scan == 'finished')
            const Notice('最近一次检查已结束。'),
          if (group.loaded && group.items.isEmpty && group.error == null)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: IsleDecorations.recessedWell(
                context,
                radius: IsleRadius.md,
              ),
              child: Row(
                children: [
                  IsleSquircleBadge(
                    icon: Icons.verified_outlined,
                    color: palette['brandSage'],
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
          if (group.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: IsleGroupCard(
                margin: EdgeInsets.zero,
                children: [
                  for (final item in group.items)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 3,
                      ),
                      leading: IsleSquircleBadge(
                        icon: isPhotos
                            ? Icons.hide_image_outlined
                            : Icons.videocam_off_outlined,
                        color: palette['brandAmber'],
                        size: 32,
                        iconSize: 17,
                      ),
                      title: Text(
                        item['path']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '${_reason(item['reason'])} · 保留：${_dataLabel(item['data'])}${item['canManage'] == true ? '' : ' · 当前没有写入权限'}',
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: '处理缺失媒体',
                        shape: IsleShapes.menu(
                          side: BorderSide(
                            color: IsleGlass.rimBorderColor(isDark),
                            width: 1.0,
                          ),
                        ),
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
                ],
              ),
            ),
          if (group.cursor.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton(
                  onPressed: group.loading
                      ? null
                      : () => _load(kind, more: true),
                  child: const Text('加载更多'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final photoCount = _groups['photos']!.items.length;
    final cinemaCount = _groups['cinema']!.items.length;

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('缺失媒体'),
        actions: [
          IconButton(
            tooltip: '刷新列表',
            onPressed: !_sameRoot
                ? null
                : () {
                    _load('photos');
                    _load('cinema');
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
          IsleHelpButton(
            title: '缺失媒体与关联恢复说明',
            accentColor: palette['brandAmber'],
            items: const [
              IsleHelpItem(
                title: '为什么会产生缺失记录？',
                body: '当外接盘暂时离线、原文件被重命名或原路径替换为其他文件时，系统会保留原有的收藏、相册关联与播放进度，不擅自丢弃。',
              ),
              IsleHelpItem(
                title: '关联与放弃操作',
                body: '接回原盘点击「重新检查」可自动恢复原文件关联；也可手动将旧资料关联到同路径新文件，或放弃不再需要的旧记录（不删磁盘文件）。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.broken_image_outlined,
            accent: palette['brandAmber'],
            title: '缺失媒体与历史关联恢复',
            metrics: [
              IsleFocalMetric(
                label: '图库缺失',
                value: _groups['photos']!.loaded ? '$photoCount 项' : '读取中',
                icon: Icons.photo_library_outlined,
                color: palette['brandRose'],
              ),
              IsleFocalMetric(
                label: '影视缺失',
                value: _groups['cinema']!.loaded ? '$cinemaCount 项' : '读取中',
                icon: Icons.movie_outlined,
                color: palette['brandTerracotta'],
              ),
            ],
          ),
          if (!_sameRoot) const Notice('硬盘已变化或尚未选择，请返回后选择原硬盘。', error: true),
          if (_message != null) Notice(_message!),
          if (_sameRoot)
            LayoutBuilder(
              builder: (context, constraints) {
                final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final sideBySide =
                    constraints.maxWidth >= 880 && textScale <= 1.35;
                if (sideBySide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _buildDomainPanel(
                          context,
                          kind: 'photos',
                          isDark: isDark,
                          palette: palette,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildDomainPanel(
                          context,
                          kind: 'cinema',
                          isDark: isDark,
                          palette: palette,
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildDomainPanel(
                      context,
                      kind: 'photos',
                      isDark: isDark,
                      palette: palette,
                    ),
                    const SizedBox(height: 14),
                    _buildDomainPanel(
                      context,
                      kind: 'cinema',
                      isDark: isDark,
                      palette: palette,
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
