import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

/// Displays the dialog to create a new remote NAS download task.
Future<Map<String, Object>?> showNewDownloadDialog(
  BuildContext context, {
  required LightIsleApi api,
  required String initialDestination,
}) => showDialog<Map<String, Object>>(
  context: context,
  builder: (_) =>
      _NewDownloadDialog(api: api, initialDestination: initialDestination),
);

/// Displays the list of files published/archived by a download task.
Future<void> showPublishedDownloadFilesDialog(
  BuildContext context, {
  required Map<String, dynamic> task,
  required List<Map<String, dynamic>> published,
  required int totalCount,
}) {
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
  LightIsleApi? _ownedDefaultApi;

  LightIsleApi get _effectiveApi => _ownedDefaultApi ?? widget.api;

  @override
  void initState() {
    super.initState();
    if (widget.api.selectedRoot != null && !widget.api.selectedRoot!.isDefault) {
      final snap = widget.api.sessionSnapshot;
      if (snap != null) {
        _ownedDefaultApi = LightIsleApi.fromSessionSnapshot(snap);
      }
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _ownedDefaultApi?.close();
    super.dispose();
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
      final response = await _effectiveApi.get(
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
      if (mounted) {
        setState(() => _error = '读取文件夹失败：${userFacingError(error)}');
      }
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
                  child: Material(
                    type: MaterialType.transparency,
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
