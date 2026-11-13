import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'file_export_service.dart';
import 'file_models.dart';
import 'file_pdf_preview.dart';

const _computerBase = '/api/v2/computer-files';

class ComputerFilesPage extends StatefulWidget {
  const ComputerFilesPage({
    super.key,
    required this.api,
    required this.isAdmin,
  });
  final LightIsleApi api;
  final bool isAdmin;
  @override
  State<ComputerFilesPage> createState() => _ComputerFilesPageState();
}

class _ComputerFilesPageState extends State<ComputerFilesPage> {
  bool _enabled = false,
      _busy = true,
      _saving = false,
      _grantLoading = false,
      _grantReady = false;
  String _mode = 'none', _path = '', _cursor = '', _grantMode = 'none';
  String? _error, _message, _member;
  List<FileEntry> _entries = [];
  List<Map<String, dynamic>> _members = [];
  List<String> _folders = [];
  final List<String> _history = [];
  int _generation = 0;
  int _grantGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final status = await widget.api.get('$_computerBase/status');
      _enabled = status['enabled'] == true;
      _mode = status['mode']?.toString() ?? 'none';
      if (_enabled && _mode != 'none') {
        _history.clear();
        await _browse('');
      } else {
        _entries = [];
        _path = '';
      }
      if (widget.isAdmin && _enabled) {
        final result = await widget.api.get('/api/v2/users');
        _members = objectList(result['users'])
            .where((u) => u['role'] == 'member')
            .toList();
      }
    } catch (e) {
      _error = userFacingError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _browse(
    String next, {
    String cursor = '',
    bool push = false,
  }) async {
    final generation = ++_generation;
    try {
      final result = await widget.api.get(
        _computerBase,
        query: {'path': next, if (cursor.isNotEmpty) 'cursor': cursor},
      );
      if (!mounted || generation != _generation) return;
      final rows = objectList(result['entries'])
          .map(FileEntry.fromJson)
          .toList();
      setState(() {
        if (push) _history.add(_path);
        _path = result['path']?.toString() ?? next;
        _entries = cursor.isEmpty ? rows : [..._entries, ...rows];
        _cursor = result['nextCursor']?.toString() ?? '';
        _error = null;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = '无法读取目录：${userFacingError(e)}。请检查磁盘连接及 Mac 的文件和隐私权限。',
        );
      }
    }
  }

  Future<void> _loadGrant(String? id) async {
    final generation = ++_grantGeneration;
    setState(() {
      _member = id;
      _grantMode = 'none';
      _folders = [];
      _grantLoading = id != null;
      _grantReady = false;
    });
    if (id == null) return;
    try {
      final grant = await widget.api.get('$_computerBase/grants/$id');
      if (mounted && _member == id && generation == _grantGeneration) {
        setState(() {
          _grantMode = grant['mode']?.toString() ?? 'none';
          _folders = objectList(grant['folders'])
              .map((f) => f['path']?.toString() ?? '')
              .where((p) => p.isNotEmpty)
              .toList();
          _grantReady = true;
        });
      }
    } catch (e) {
      if (mounted && generation == _grantGeneration) {
        setState(() => _error = userFacingError(e));
      }
    } finally {
      if (mounted && _member == id && generation == _grantGeneration) {
        setState(() => _grantLoading = false);
      }
    }
  }

  Future<void> _saveGrant() async {
    if (_member == null || _saving || _grantLoading || !_grantReady) return;
    final member = _member;
    final generation = _grantGeneration;
    final mode = _grantMode;
    final folders = List<String>.of(_folders);
    if (mode == 'folders' && folders.isEmpty) {
      setState(() => _error = '请先浏览并添加至少一个文件夹。');
      return;
    }
    if (mode == 'all' &&
        !await confirmAction(
          context,
          '授权整台电脑',
          '该成员可以查看和下载 Mac 允许轻屿读取的所有文件，包括其他成员的私人文件。确认授权？',
        )) {
      return;
    }
    if (!mounted ||
        generation != _grantGeneration ||
        _member != member ||
        !_grantReady ||
        _grantLoading ||
        _grantMode != mode ||
        !listEquals(_folders, folders)) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'PUT',
        '$_computerBase/grants/$member',
        body: {'mode': mode, 'paths': folders},
      );
      if (mounted) setState(() => _message = '成员权限已保存');
    } catch (e) {
      if (mounted) setState(() => _error = '授权未保存：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _download(FileEntry item) async {
    try {
      final message = await exportMediaFile(
        widget.api,
        path: item.path,
        name: item.isFolder ? '${item.name}.zip' : item.name,
        endpoint: item.isFolder
            ? '$_computerBase/archive'
            : '$_computerBase/content',
      );
      if (mounted) setState(() => _message = message);
    } catch (e) {
      if (mounted) setState(() => _error = '下载失败：${userFacingError(e)}');
    }
  }

  Future<void> _preview(FileEntry item) async {
    final extension = item.name.split('.').last.toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp'}.contains(extension)) {
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: SizedBox(
            width: 800,
            height: 600,
            child: FutureBuilder(
              future: widget.api.bytes(
                '$_computerBase/preview',
                query: {'path': item.path},
                maxBytes: 64 << 20,
              ),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('无法预览，请尝试下载原文件。'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Image.memory(snapshot.data!, fit: BoxFit.contain);
              },
            ),
          ),
        ),
      );
    } else if (const {'mp4', 'm4v', 'webm'}.contains(extension)) {
      await Navigator.of(context).push<void>(
        buildIslePageRoute(
          builder: (_) => _ComputerVideo(api: widget.api, item: item),
        ),
      );
    } else if (extension == 'pdf') {
      await showDialog<void>(
        context: context,
        builder: (_) => FilePdfPreviewDialog(
          api: widget.api,
          item: item,
          previewEndpoint: '$_computerBase/preview',
          onOpenExternal: () => _download(item),
          onDownload: () => _download(item),
        ),
      );
    } else if (const {'txt', 'md', 'json', 'log'}.contains(extension)) {
      try {
        final bytes = await widget.api.bytes(
          '$_computerBase/preview',
          query: {'path': item.path},
          maxBytes: 1 << 20,
        );
        final text = utf8.decode(bytes);
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(item.name),
            content: SizedBox(
              width: 700,
              child: SingleChildScrollView(child: SelectableText(text)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      } catch (e) {
        if (mounted) {
          setState(() => _error = '无法预览，请下载后打开：${userFacingError(e)}');
        }
      }
    } else {
      setState(() => _message = '暂不支持在线预览，请下载后打开。');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _history.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop || _history.isEmpty) return;
      final parent = _history.removeLast();
      _browse(parent);
    },
    child: Scaffold(
      appBar: IsleAppBar(
        title: const Text('电脑文件'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('只读浏览、查看和下载 Mac 当前允许访问的文件。'),
          if (_busy && _entries.isEmpty)
            const IsleLoadingState(label: '正在连接电脑文件…')
          else if (_busy)
            const LinearProgressIndicator(),
          if (_error != null) Notice(_error!, error: true),
          if (_message != null) Notice(_message!),
          if (!_busy && !_enabled) const Notice('此功能未开启，请在 Mac 的轻屿设置 → 安全中开启。'),
          if (!_busy && _enabled && _mode == 'none')
            const Notice('暂无访问权限，请联系管理员授权。'),
          if (_enabled && _mode != 'none') ...[
            Row(
              children: [
                IconButton(
                  tooltip: '返回上级目录',
                  onPressed: _history.isEmpty
                      ? null
                      : () {
                          final parent = _history.removeLast();
                          _browse(parent);
                        },
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: SelectableText(_path.isEmpty ? '已授权的文件夹' : _path),
                ),
                IconButton(
                  tooltip: '刷新目录内容',
                  onPressed: () => _browse(_path),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_entries.isEmpty && !_busy) const Notice('此文件夹为空，或没有可显示的普通文件。'),
            for (final item in _entries)
              ListTile(
                leading: Icon(
                  item.isFolder
                      ? Icons.folder_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(item.name),
                onTap: () => item.isFolder
                    ? _browse(item.path, push: true)
                    : _preview(item),
                trailing: IconButton(
                  onPressed: () => _download(item),
                  tooltip: item.isFolder ? '下载文件夹' : '下载',
                  icon: const Icon(Icons.download_outlined),
                ),
              ),
            if (_cursor.isNotEmpty)
              TextButton(
                onPressed: () => _browse(_path, cursor: _cursor),
                child: const Text('加载更多'),
              ),
            if (widget.isAdmin) ...[
              const Divider(),
              const Text(
                '成员访问权限',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Text('整机权限可能包含其他成员的私人文件及敏感资料。'),
              DropdownButton<String>(
                value: _member,
                isExpanded: true,
                hint: const Text('选择成员'),
                items: [
                  for (final member in _members)
                    DropdownMenuItem(
                      value: member['id'].toString(),
                      child: Text(member['username'].toString()),
                    ),
                ],
                onChanged: _saving ? null : _loadGrant,
              ),
              if (_member != null)
                DropdownButton<String>(
                  value: _grantMode,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('无权限')),
                    DropdownMenuItem(value: 'folders', child: Text('指定文件夹')),
                    DropdownMenuItem(value: 'all', child: Text('整台电脑')),
                  ],
                  onChanged: !_grantReady || _grantLoading || _saving
                      ? null
                      : (value) => setState(() => _grantMode = value ?? 'none'),
                ),
              if (_member != null && !_grantReady && !_grantLoading)
                TextButton(
                  onPressed: () => _loadGrant(_member),
                  child: const Text('重新读取权限'),
                ),
              if (_member != null &&
                  _grantReady &&
                  _grantMode == 'folders') ...[
                TextButton.icon(
                  onPressed: _path.isEmpty || _folders.contains(_path)
                      ? null
                      : () => setState(() => _folders.add(_path)),
                  icon: const Icon(Icons.add),
                  label: const Text('将当前文件夹加入授权'),
                ),
                for (final folder in _folders)
                  ListTile(
                    title: Text(folder),
                    trailing: IconButton(
                      tooltip: '移除文件夹授权',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _folders.remove(folder)),
                    ),
                  ),
              ],
              if (_member != null)
                FilledButton(
                  onPressed: _saving || _grantLoading || !_grantReady
                      ? null
                      : _saveGrant,
                  child: Text(
                    _saving
                        ? '正在保存…'
                        : _grantLoading
                        ? '正在读取权限…'
                        : '保存权限',
                  ),
                ),
            ],
          ],
        ],
      ),
    ),
  );
}

class _ComputerVideo extends StatefulWidget {
  const _ComputerVideo({required this.api, required this.item});
  final LightIsleApi api;
  final FileEntry item;
  @override
  State<_ComputerVideo> createState() => _ComputerVideoState();
}

class _ComputerVideoState extends State<_ComputerVideo> {
  VideoPlayerController? _controller;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uri = await widget.api.mediaUri(
        '$_computerBase/preview',
        query: {'path': widget.item.path},
      );
      final player = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      _controller = player;
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {});
      await player.play();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(title: Text(widget.item.name)),
    body: Center(
      child: _error != null
          ? Text('无法播放：$_error')
          : _controller?.value.isInitialized == true
          ? AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: GestureDetector(
                onTap: () {
                  if (_controller!.value.isPlaying) {
                    _controller!.pause();
                  } else {
                    _controller!.play();
                  }
                },
                child: VideoPlayer(_controller!),
              ),
            )
          : const CircularProgressIndicator(),
    ),
  );
}
