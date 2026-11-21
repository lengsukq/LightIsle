import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'download_task_row.dart';
import 'downloads_dialogs.dart';

/// The NAS performs these downloads; leaving this page does not cancel them.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.api,
    this.initialDestination = '.',
  });
  final LightIsleApi api;
  final String initialDestination;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _tasks = const [];
  bool _loading = false,
      _loaded = false,
      _available = false,
      _networkAllowed = true,
      _foreground = true;
  String? _error;
  String _reason = '', _busy = '';
  late String _destination = widget.initialDestination;
  int _generation = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      ++_generation;
      _loading = false;
      _loaded = false;
      _busy = '';
      _tasks = const [];
      _available = false;
      _networkAllowed = true;
      _destination = widget.initialDestination;
      unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_foreground) unawaited(_load());
  }

  void _schedule() {
    _timer?.cancel();
    if (!mounted || !_foreground) return;
    _timer = Timer(const Duration(seconds: 3), () {
      if (ModalRoute.of(context)?.isCurrent == false || _busy.isNotEmpty) {
        _schedule();
      } else {
        unawaited(_load());
      }
    });
  }

  Future<void> _load() async {
    if (_loading || _busy.isNotEmpty || !_foreground || !mounted) return;
    final generation = ++_generation;
    final api = widget.api;
    _timer?.cancel();
    setState(() => _loading = true);
    try {
      final status = await api.get('/api/v2/downloads/status');
      if (status['available'] is! bool) throw const FormatException('下载服务状态无效');
      List<Map<String, dynamic>> tasks = const [];
      try {
        final result = await api.get('/api/v2/downloads');
        final raw = result['tasks'];
        if (raw != null && raw is! List) {
          throw const FormatException('下载任务列表无效');
        }
        tasks = objectList(raw);
        if ((raw is List && tasks.length != raw.length) ||
            tasks.any((t) => t['id'] is! String || t['status'] is! String)) {
          throw const FormatException('下载任务内容无效');
        }
      } on LightIsleApiException catch (error) {
        if (status['available'] == true ||
            error.code != 'download_unavailable') {
          rethrow;
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _tasks = tasks;
        _available = status['available'] != false;
        _networkAllowed = status['networkAllowed'] != false;
        _reason = status['reason']?.toString() ?? '';
        _loaded = true;
        _error = null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '读取下载中心失败：${userFacingError(error)}');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        _schedule();
      }
    }
  }

  Future<void> _perform(String key, Future<void> Function() operation) async {
    if (_busy.isNotEmpty) return;
    final api = widget.api;
    final generation = ++_generation;
    _timer?.cancel();
    setState(() {
      _busy = key;
      _loading = false;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '操作失败：${userFacingError(error)}');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = '');
        final actionError = _error;
        await _load();
        if (mounted && identical(widget.api, api) && actionError != null) {
          setState(() => _error = actionError);
        }
      }
    }
  }

  Future<void> _create() async {
    if (!_available || !_networkAllowed || _busy.isNotEmpty) return;
    final api = widget.api;
    final request = await showNewDownloadDialog(
      context,
      api: widget.api,
      initialDestination: _destination,
    );
    if (request == null || !mounted || !identical(api, widget.api)) return;
    _destination = request['destination'] as String;
    await _perform('create', () async {
      await api.send('POST', '/api/v2/downloads', body: request);
    });
  }

  Future<void> _action(Map<String, dynamic> task, String action) async {
    final api = widget.api;
    final id = Uri.encodeComponent(task['id'] as String);
    if (action == 'cancel' || action == 'delete') {
      final confirmed = await confirmAction(
        context,
        action == 'delete' ? '删除下载记录' : '取消下载',
        action == 'delete'
            ? '删除此任务记录？已保存到共享目录的文件会保留。'
            : '停止此任务并清理未完成的下载？已保存到共享目录的文件会保留。',
        action: action == 'delete' ? '删除记录' : '取消下载',
        isDestructive: true,
      );
      if (!confirmed || !mounted || !identical(api, widget.api)) return;
    }
    await _perform('$id:$action', () async {
      if (action == 'delete') {
        await api.send('DELETE', '/api/v2/downloads/$id');
      } else {
        await api.send(
          'POST',
          '/api/v2/downloads/$id/actions',
          body: {'action': action},
        );
      }
    });
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _buildTaskRow(Map<String, dynamic> task) => DownloadTaskRow(
    task: task,
    canAct: _busy.isEmpty,
    available: _available,
    networkAllowed: _networkAllowed,
    onAction: _action,
  );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final accent = palette['brandAmber'];
    final activeCount = _tasks
        .where(
          (t) => const ['queued', 'running', 'paused'].contains(t['status']),
        )
        .length;
    final completedCount = _tasks
        .where((t) => t['status'] == 'completed')
        .length;

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('下载中心'),
        actions: [
          IconButton(
            tooltip: '刷新下载任务',
            onPressed: _loading || _busy.isNotEmpty ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
          IsleHelpButton(
            title: '远程下载说明',
            accentColor: accent,
            items: const [
              IsleHelpItem(
                title: 'Mac 后台持续下载',
                body: '下载任务由家里的 Mac 直接拉取并写入目标共享目录，离开此页面或关闭手机客户端不会中断下载。',
              ),
              IsleHelpItem(
                title: '同名文件安全保护',
                body: '下载完成后归档写入目标目录时若遇到同名不一致文件，将暂停覆盖并提示在 Mac 端核对，确保已有文件安全。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.download_for_offline_rounded,
            accent: accent,
            title: '远程下载队列',
            metrics: [
              IsleFocalMetric(
                label: '进行中',
                value: '$activeCount',
                accent: accent,
              ),
              IsleFocalMetric(
                label: '已完成',
                value: '$completedCount',
                accent: palette['brandSage'],
              ),
              IsleFocalMetric(
                label: '引擎状态',
                value: !_loaded ? '检测中' : (_available ? '就绪' : '不可用'),
                accent: _available
                    ? palette['brandBlue']
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
            actions: [
              if (_loaded && _available && _networkAllowed)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _busy.isEmpty ? _create : null,
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: Text(_busy == 'create' ? '正在创建…' : '新建下载'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_error != null) Notice(_error!, error: true, onRetry: _load),
          if (_loading && !_loaded)
            const IsleLoadingState(compact: true, label: '正在读取下载任务…'),
          if (_loaded && !_available)
            Notice(
              _reason == 'aria2_not_installed'
                  ? 'Mac 尚未安装下载组件 aria2，暂时不能新建下载。已有记录可查看；已下载的任务仍可重试保存文件。'
                  : 'Mac 的下载服务暂时不可用。已有记录可查看；已下载的任务仍可重试保存文件。',
            ),
          if (_loaded && !_networkAllowed)
            const Notice('新建或继续网络下载需要管理员权限，已有任务和已下载的文件仍可管理。'),
          if (_loaded && _tasks.isEmpty && _available && _networkAllowed)
            const IsleEmptyStateCard(
              '还没有下载任务。添加一个下载链接即可开始。',
              icon: Icons.download_done_rounded,
            ),
          if (_tasks.isNotEmpty) ...[
            IsleSectionHeader(
              title: '任务记录（${_tasks.length}）',
              accentColor: accent,
            ),
            IsleAdaptiveBuilder(
              builder: (context, tier, width) {
                final textScale =
                    MediaQuery.textScalerOf(context).scale(14) / 14;
                if (tier == IsleViewportTier.expanded &&
                    _tasks.length > 1 &&
                    textScale <= 1.35) {
                  final cardWidth = (width - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final task in _tasks)
                        SizedBox(
                          width: cardWidth,
                          child: IsleSurface(
                            margin: EdgeInsets.zero,
                            padding: EdgeInsets.zero,
                            child: _buildTaskRow(task),
                          ),
                        ),
                    ],
                  );
                }
                return IsleSurface(
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _tasks.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 1,
                            indent: 52,
                            color: borderColor,
                          ),
                        _buildTaskRow(_tasks[i]),
                      ],
                    ],
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
