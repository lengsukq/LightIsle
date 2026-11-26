import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

/// Engine availability snapshot returned by `GET /api/v2/downloads/status`.
class DownloadEngineCapabilities {
  const DownloadEngineCapabilities({
    required this.aria2Available,
    this.aria2Version = '',
    this.aria2Reason = '',
    this.ytdlpAvailable = false,
    this.ytdlpVersion = '',
    this.ytdlpReason = '',
    this.webArchiveAvailable = false,
    this.multiEngineSupported = false,
  });

  final bool aria2Available;
  final String aria2Version;
  final String aria2Reason;
  final bool ytdlpAvailable;
  final String ytdlpVersion;
  final String ytdlpReason;
  final bool webArchiveAvailable;
  final bool multiEngineSupported;

  bool get anyAvailable =>
      aria2Available || ytdlpAvailable || webArchiveAvailable;

  String get defaultEngine {
    if (aria2Available) return 'aria2';
    if (webArchiveAvailable) return 'webarchive';
    if (ytdlpAvailable) return 'ytdlp';
    return 'aria2';
  }

  factory DownloadEngineCapabilities.fromStatusJson(Map<String, dynamic> status) {
    final legacyAvailable = status['available'] == true;
    final multi =
        status.containsKey('aria2Available') ||
        status.containsKey('ytdlpAvailable') ||
        status.containsKey('webArchiveAvailable');
    return DownloadEngineCapabilities(
      aria2Available: status['aria2Available'] is bool
          ? status['aria2Available'] as bool
          : legacyAvailable,
      aria2Version:
          status['aria2Version']?.toString() ??
          status['version']?.toString() ??
          '',
      aria2Reason:
          status['aria2Reason']?.toString() ??
          status['reason']?.toString() ??
          '',
      ytdlpAvailable: status['ytdlpAvailable'] == true,
      ytdlpVersion: status['ytdlpVersion']?.toString() ?? '',
      ytdlpReason: status['ytdlpReason']?.toString() ?? '',
      webArchiveAvailable: status['webArchiveAvailable'] == true,
      multiEngineSupported: multi,
    );
  }
}

/// Displays the dialog to create a new remote NAS download task.
Future<Map<String, Object>?> showNewDownloadDialog(
  BuildContext context, {
  required LightIsleApi api,
  required String initialDestination,
  DownloadEngineCapabilities? capabilities,
}) => showDialog<Map<String, Object>>(
  context: context,
  builder: (_) => _NewDownloadDialog(
    api: api,
    initialDestination: initialDestination,
    capabilities:
        capabilities ?? const DownloadEngineCapabilities(aria2Available: true),
  ),
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
    required this.capabilities,
  });
  final LightIsleApi api;
  final String initialDestination;
  final DownloadEngineCapabilities capabilities;
  @override
  State<_NewDownloadDialog> createState() => _NewDownloadDialogState();
}

class _NewDownloadDialogState extends State<_NewDownloadDialog> {
  static const _ytdlpFormats = <(String, String)>[
    ('best', '最佳画质'),
    ('1080p', '1080P 优先'),
    ('720p', '720P 省空间'),
    ('audio', '仅提取音频'),
  ];

  final _url = TextEditingController();
  final _limit = TextEditingController();
  final _playlistMax = TextEditingController(text: '10');
  late String _destination = widget.initialDestination;
  late String _engine = widget.capabilities.defaultEngine;
  String _ytdlpFormat = 'best';
  bool _allowPlaylist = false;
  String? _error;

  bool get _selectedEngineAvailable => switch (_engine) {
    'ytdlp' => widget.capabilities.ytdlpAvailable,
    'webarchive' => widget.capabilities.webArchiveAvailable,
    _ => widget.capabilities.aria2Available,
  };

  @override
  void dispose() {
    _url.dispose();
    _limit.dispose();
    _playlistMax.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_selectedEngineAvailable) {
      setState(() {
        _error = _engine == 'ytdlp'
            ? 'Mac 尚未安装 yt-dlp，请先在 Mac 安装或切换至网页离线保存。'
            : '当前所选下载引擎暂不可用，请切换其他可用引擎。';
      });
      return;
    }
    final raw = _url.text.trim(), uri = Uri.tryParse(raw);
    final httpOnly =
        uri != null &&
        const ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
    final network =
        uri != null &&
        const ['http', 'https', 'ftp'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
    final magnet = RegExp(
      r'^magnet:\?xt=urn:btih:[A-Za-z0-9]{32,40}(&[A-Za-z0-9_.%*-]+=[^&]*)*$',
    ).hasMatch(raw);

    if (_engine == 'aria2') {
      if (raw.isEmpty || raw.length > 2048 || (!network && !magnet)) {
        setState(() => _error = '请输入有效的 HTTP、HTTPS、FTP 或磁力链接。');
        return;
      }
    } else {
      if (raw.isEmpty || raw.length > 2048 || !httpOnly) {
        setState(() => _error = '请输入有效的 HTTP 或 HTTPS 网页/视频链接。');
        return;
      }
    }

    final limit = _limit.text.trim().isEmpty
        ? 0.0
        : double.tryParse(_limit.text.trim());
    if (limit == null ||
        !limit.isFinite ||
        limit < 0 ||
        limit > 1024 ||
        (_limit.text.trim().isNotEmpty && limit == 0)) {
      setState(() => _error = '大小上限请输入 0 到 1024 之间的正数，或留空。');
      return;
    }

    var playlistMaxItems = 0;
    if (_engine == 'ytdlp' && _allowPlaylist) {
      final parsed = int.tryParse(_playlistMax.text.trim());
      if (parsed == null || parsed < 1 || parsed > 20) {
        setState(() => _error = '播放列表最多条目数请输入 1 到 20 之间的整数。');
        return;
      }
      playlistMaxItems = parsed;
    }

    final payload = <String, Object>{
      'url': raw,
      'destination': _destination,
      'maxBytes': (limit * 1024 * 1024 * 1024).round(),
    };
    if (widget.capabilities.multiEngineSupported || _engine != 'aria2') {
      payload['engine'] = _engine;
      if (_engine == 'ytdlp') {
        payload['options'] = <String, Object>{
          'format': _ytdlpFormat,
          'allowPlaylist': _allowPlaylist,
          if (_allowPlaylist) 'playlistMaxItems': playlistMaxItems,
        };
      }
    }
    Navigator.pop(context, payload);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final caps = widget.capabilities;
    final urlHint = switch (_engine) {
      'ytdlp' => 'https://www.bilibili.com/video/… 或 YouTube 链接',
      'webarchive' => 'https://example.com/article（保存正文与内联图片）',
      _ => 'https://… 或 magnet:?…',
    };

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
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (caps.multiEngineSupported) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('dlEngineChipAria2'),
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        caps.aria2Available ? '常规下载 (aria2)' : 'aria2 (未安装)',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: _engine == 'aria2',
                      onSelected: (_) => setState(() {
                        _engine = 'aria2';
                        _error = null;
                      }),
                    ),
                    ChoiceChip(
                      key: const ValueKey('dlEngineChipYtdlp'),
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        caps.ytdlpAvailable
                            ? '视频/音频 (yt-dlp)'
                            : 'yt-dlp (未安装)',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: _engine == 'ytdlp',
                      onSelected: (_) => setState(() {
                        _engine = 'ytdlp';
                        _error = null;
                      }),
                    ),
                    ChoiceChip(
                      key: const ValueKey('dlEngineChipWebArchive'),
                      visualDensity: VisualDensity.compact,
                      label: const Text(
                        '网页离线保存',
                        style: TextStyle(fontSize: 12),
                      ),
                      selected: _engine == 'webarchive',
                      onSelected: (_) => setState(() {
                        _engine = 'webarchive';
                        _error = null;
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_engine == 'ytdlp' && !caps.ytdlpAvailable)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Notice(
                      'Mac 尚未安装 yt-dlp，请在 Mac 端安装（如 brew install yt-dlp）后自动生效；此期间仍可正常使用「网页离线保存」。',
                    ),
                  ),
                if (_engine == 'aria2' && !caps.aria2Available)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Notice(
                      'Mac 尚未安装 aria2，无法使用常规/磁力下载；可切换至「网页离线保存」。',
                    ),
                  ),
                if (_engine == 'webarchive')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '抓取网页正文并安全内联图片为单个离线 HTML 文件，不依赖 aria2 或 yt-dlp。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: _engine == 'webarchive' ? '网页链接' : '下载链接',
                  hintText: urlHint,
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
              if (_engine == 'ytdlp') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const ValueKey('dlYtdlpFormatDropdown'),
                  initialValue: _ytdlpFormat,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '画质 / 格式偏好',
                  ),
                  items: [
                    for (final opt in _ytdlpFormats)
                      DropdownMenuItem(value: opt.$1, child: Text(opt.$2)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _ytdlpFormat = v);
                  },
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('dlYtdlpPlaylistSwitch'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('允许下载播放列表', style: TextStyle(fontSize: 13)),
                  subtitle: const Text(
                    '默认仅下载单集；开启后可限制最多抓取条数（上限 20）',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  value: _allowPlaylist,
                  onChanged: (v) => setState(() => _allowPlaylist = v),
                ),
                if (_allowPlaylist)
                  TextField(
                    key: const ValueKey('dlYtdlpPlaylistMaxField'),
                    controller: _playlistMax,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '播放列表最大条数（1–20）',
                    ),
                  ),
              ],
              if (_engine != 'webarchive') ...[
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
              ],
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
        FilledButton(
          onPressed: _selectedEngineAvailable ? _submit : null,
          child: Text(_engine == 'webarchive' ? '开始保存' : '开始下载'),
        ),
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
    final palette = IslePalette.of(context);
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
