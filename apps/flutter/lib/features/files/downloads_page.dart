import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

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
        setState(() => _error = '读取下载中心失败：${_message(error)}');
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
        setState(() => _error = '操作失败：${_message(error)}');
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
    final request = await showDialog<Map<String, Object>>(
      context: context,
      builder: (_) =>
          _NewDownloadDialog(api: widget.api, initialDestination: _destination),
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

  Future<void> _showPublishedFilesDialog(
    BuildContext context,
    Map<String, dynamic> task,
    List<Map<String, dynamic>> published,
    int totalCount,
  ) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(side: BorderSide(color: borderColor)),
        title: Text('文件处理记录（$totalCount 项）'),
        content: SizedBox(
          width: 440,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < published.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: borderColor),
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      published[i]['target']?.toString() ?? '',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    subtitle: Text(
                      published[i]['status'] == 'published'
                          ? '已保存'
                          : published[i]['status'] == 'recovery_required'
                          ? '需要核对'
                          : '等待核对',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
                if (task['publishedFilesTruncated'] == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '这里只显示前 ${published.length} 项，其余处理记录仍由服务端保留。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

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
                            child: _taskRow(context, task, palette),
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
                        _taskRow(context, _tasks[i], palette),
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

  Widget _taskRow(
    BuildContext context,
    Map<String, dynamic> task,
    IslePalette palette,
  ) {
    final status = task['status'] as String;
    final total = _number(task['totalBytes']),
        done = _number(task['completedBytes']);
    final published = objectList(task['publishedFiles']);
    final publishedCount = _number(task['publishedFilesTotal']) > 0
        ? _number(task['publishedFilesTotal'])
        : published.length;
    final active = const ['queued', 'running', 'paused'].contains(status);
    final canAct = _busy.isEmpty;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final statusColor = switch (status) {
      'completed' => palette['brandSage'],
      'running' => colors.primary,
      'paused' => palette['brandAmber'],
      'failed' => colors.error,
      _ => colors.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: status == 'completed'
                    ? Icons.download_done_rounded
                    : Icons.downloading_rounded,
                color: statusColor,
                size: 32,
                iconSize: 16.5,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task['filename']?.toString().isNotEmpty == true
                          ? task['filename'].toString()
                          : task['url']?.toString() ?? '下载任务',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${status == 'running' && task['phase'] == 'publishing' ? '正在保存' : _statusLabel(status)} · 保存到 ${task['destination'] == '.' ? '共享根目录' : task['destination']}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IsleBadgePill(
                label: status == 'running' && task['phase'] == 'publishing'
                    ? '正在保存'
                    : _statusLabel(status),
                color: statusColor,
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 42),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: (done / total).clamp(0.0, 1.0),
                      minHeight: 5,
                      semanticsLabel: '下载进度',
                      backgroundColor: colors.outlineVariant.withValues(
                        alpha: 0.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatBytes(done)} / ${formatBytes(total)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (task['partialPublish'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 42),
              child: Text(
                '部分文件已保存，任务尚未全部完成。重试会核对已有文件。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (task['recoveryRequired'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 42),
              child: Text(
                '已有文件与任务记录不一致，请先在 Mac 核对文件；不会自动覆盖。',
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
          if (task['error']?.toString().isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 42),
              child: Text(
                userFacingError(task['error'].toString()),
                style: TextStyle(color: colors.error, fontSize: 12.5),
              ),
            ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Row(
              children: [
                if (task['phase'] != 'publishing' &&
                    (status == 'queued' || status == 'running'))
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: canAct && _available
                        ? () => _action(task, 'pause')
                        : null,
                    child: const Text('暂停', style: TextStyle(fontSize: 12.5)),
                  ),
                if (status == 'paused')
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: canAct && _available && _networkAllowed
                        ? () => _action(task, 'resume')
                        : null,
                    child: const Text('继续', style: TextStyle(fontSize: 12.5)),
                  ),
                if (status == 'failed' || status == 'cancelled')
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed:
                        canAct &&
                            ((_available && _networkAllowed) ||
                                task['phase'] == 'publishing')
                        ? () => _action(task, 'retry')
                        : null,
                    child: const Text('重试', style: TextStyle(fontSize: 12.5)),
                  ),
                if (!active)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: canAct ? () => _action(task, 'delete') : null,
                    child: const Text('删除记录', style: TextStyle(fontSize: 12.5)),
                  ),
                if (published.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => _showPublishedFilesDialog(
                      context,
                      task,
                      published,
                      publishedCount,
                    ),
                    icon: const Icon(Icons.help_outline_rounded, size: 14.5),
                    label: Text(
                      '文件处理记录（$publishedCount 项）',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                const Spacer(),
                if (active)
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    enabled: canAct,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    style: IconButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    shape: IsleShapes.md(
                      side: BorderSide(
                        color: IsleGlass.rimBorderColor(isDark),
                        width: 1.0,
                      ),
                    ),
                    onSelected: (act) => _action(task, act),
                    itemBuilder: (_) => [
                      isleActionMenuItem(
                        value: 'cancel',
                        icon: Icons.cancel_outlined,
                        label: '取消下载',
                      ),
                      isleActionMenuItem(
                        value: 'delete',
                        icon: Icons.delete_outline_rounded,
                        label: '删除记录',
                        destructive: true,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

int _number(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toInt() : 0;
String _statusLabel(String value) =>
    const {
      'queued': '排队中',
      'running': '下载中',
      'paused': '已暂停',
      'completed': '已完成',
      'failed': '未完成',
      'cancelled': '已取消',
    }[value] ??
    '状态未知';
String _message(Object error) => userFacingError(error);

class _NewDownloadDialog extends StatefulWidget {
  const _NewDownloadDialog({
    required this.api,
    required this.initialDestination,
  });
  final LightIsleApi api;
  final String initialDestination;
  @override
  State<_NewDownloadDialog> createState() => _NewDownloadDialogState();
}

class _NewDownloadDialogState extends State<_NewDownloadDialog> {
  final _url = TextEditingController(), _limit = TextEditingController();
  late String _destination = widget.initialDestination;
  String? _error;
  @override
  void dispose() {
    _url.dispose();
    _limit.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _url.text.trim(), uri = Uri.tryParse(_url.text.trim());
    final network =
        uri != null &&
        const ['http', 'https', 'ftp'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
    final magnet = RegExp(
      r'^magnet:\?xt=urn:btih:[A-Za-z0-9]{32,40}(&[A-Za-z0-9_.%*-]+=[^&]*)*$',
    ).hasMatch(raw);
    final limit = _limit.text.trim().isEmpty
        ? 0.0
        : double.tryParse(_limit.text.trim());
    if (raw.isEmpty || raw.length > 2048 || (!network && !magnet)) {
      setState(() => _error = '请输入有效的 HTTP、HTTPS、FTP 或磁力链接。');
      return;
    }
    if (limit == null ||
        !limit.isFinite ||
        limit < 0 ||
        limit > 1024 ||
        (_limit.text.trim().isNotEmpty && limit == 0)) {
      setState(() => _error = '大小上限请输入 0 到 1024 之间的正数，或留空。');
      return;
    }
    Navigator.pop(context, <String, Object>{
      'url': raw,
      'destination': _destination,
      'maxBytes': (limit * 1024 * 1024 * 1024).round(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      title: Text(
        '新建下载',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '下载链接',
                  hintText: 'https://… 或 magnet:?…',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '保存到：${_destination == '.' ? '共享根目录' : _destination}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      final selection = await showDialog<String>(
                        context: context,
                        builder: (_) => _DownloadFolderDialog(api: widget.api),
                      );
                      if (selection != null && mounted) {
                        setState(() => _destination = selection);
                      }
                    },
                    icon: const Icon(Icons.folder_open_rounded, size: 17),
                    label: const Text('选择文件夹'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _limit,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '大小上限（GiB，可选）',
                  helperText: '留空使用服务端上限，最大 1024 GiB',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 12.5, color: colors.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开始下载')),
      ],
    );
  }
}

class _DownloadFolderDialog extends StatefulWidget {
  const _DownloadFolderDialog({required this.api});
  final LightIsleApi api;
  @override
  State<_DownloadFolderDialog> createState() => _DownloadFolderDialogState();
}

class _DownloadFolderDialogState extends State<_DownloadFolderDialog> {
  String _path = '.', _cursor = '';
  bool _loading = false, _writable = false;
  final List<Map<String, dynamic>> _folders = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({String? path, bool more = false}) async {
    if (_loading) return;
    if (path != null) {
      _path = path;
      _cursor = '';
      _folders.clear();
      _writable = false;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api.get(
        '/api/v2/files',
        query: {'path': _path, 'limit': '100', if (more) 'cursor': _cursor},
      );
      if (!mounted) return;
      final raw = response['entries'];
      if (raw is! List) throw const FormatException('文件夹列表无效');
      setState(() {
        if (!more) _folders.clear();
        _folders.addAll(objectList(raw).where((e) => e['type'] == 'folder'));
        _cursor = response['nextCursor']?.toString() ?? '';
        _writable = response['canWrite'] == true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '读取文件夹失败：${_message(error)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);

    return Dialog(
      shape: IsleShapes.card(
        side: BorderSide(color: borderColor, width: 1.0),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.sizeOf(context).height * .76,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择保存位置',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_path != '.')
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _loading
                          ? null
                          : () => _load(
                              path: _path.contains('/')
                                  ? _path.substring(0, _path.lastIndexOf('/'))
                                  : '.',
                            ),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                      label: const Text('上一级'),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _path == '.' ? '共享根目录' : _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 12.5, color: colors.error),
                  ),
                ),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: Container(
                  decoration: IsleDecorations.recessedWell(context, radius: 12),
                  clipBehavior: Clip.antiAlias,
                  child: ListView(
                    children: [
                      for (var i = 0; i < _folders.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 1,
                            indent: 44,
                            color: borderColor,
                          ),
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: Icon(
                            Icons.folder_rounded,
                            size: 18,
                            color: palette['brandAmber'],
                          ),
                          title: Text(
                            _folders[i]['name']?.toString() ?? '',
                            style: const TextStyle(fontSize: 13.5),
                          ),
                          onTap: _loading
                              ? null
                              : () => _load(
                                  path:
                                      _folders[i]['path']?.toString() ??
                                      (_path == '.'
                                          ? '${_folders[i]['name']}'
                                          : '$_path/${_folders[i]['name']}'),
                                ),
                        ),
                      ],
                      if (_cursor.isNotEmpty)
                        TextButton(
                          onPressed: _loading ? null : () => _load(more: true),
                          child: const Text('加载更多文件夹'),
                        ),
                      if (!_loading && _error == null && _folders.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            '没有子文件夹',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: !_loading && _error == null && _writable
                        ? () => Navigator.pop(context, _path)
                        : null,
                    child: const Text('保存到这里'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
