import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';

const int _pageSize = 100;
const int _maxUploadSize = 32 * 1024 * 1024 * 1024;
const int _uploadChunkSize = 4 * 1024 * 1024;
const int _maxTextPreviewSize = 1024 * 1024;
const int _maxImagePreviewSize = 24 * 1024 * 1024;
const MethodChannel _fileExportChannel = MethodChannel('lightisle/export');

class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.type,
    required this.size,
    required this.modified,
    required this.canWrite,
  });

  final String name;
  final String path;
  final String type;
  final int size;
  final DateTime? modified;
  final bool canWrite;

  bool get isFolder => type == 'folder';

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
    name: json['name']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    type: json['type']?.toString() ?? 'file',
    size: _asInt(json['size']),
    modified: DateTime.tryParse(json['modified']?.toString() ?? ''),
    canWrite: json['canWrite'] == true,
  );
}

class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.deletedAt,
  });

  final String id;
  final String name;
  final String originalPath;
  final DateTime? deletedAt;

  factory TrashEntry.fromJson(Map<String, dynamic> json) => TrashEntry(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    originalPath: json['originalPath']?.toString() ?? '',
    deletedAt: DateTime.tryParse(json['deletedAt']?.toString() ?? ''),
  );
}

enum _UploadStatus { checking, uploading, paused, failed, complete, cancelled }

class _UploadJob {
  _UploadJob({required this.file, required this.destination});

  final PlatformFile file;
  final String destination;
  _UploadStatus status = _UploadStatus.checking;
  String? uploadId;
  String? identityKey;
  String? digest;
  String? error;
  int offset = 0;
  int hashingBytes = 0;
  bool pauseRequested = false;
  bool cancelRequested = false;
  Completer<void>? pauseGate;
}

class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.api,
    required this.isAdmin,
    this.accountName = '',
    @visibleForTesting this.mobileExportOverride,
    @visibleForTesting this.exportDirectoryFactory,
    @visibleForTesting this.exportDirectoryCleanup,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;

  @visibleForTesting
  final bool? mobileExportOverride;

  @visibleForTesting
  final Future<Directory> Function(Directory parent)? exportDirectoryFactory;

  @visibleForTesting
  final Future<void> Function(Directory directory)? exportDirectoryCleanup;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final TextEditingController _searchController = TextEditingController();
  String _path = '.';
  String _rootName = '共享文件';
  List<FileEntry> _entries = [];
  final Set<String> _selectedPaths = <String>{};
  String _nextCursor = '';
  bool _canWrite = false;
  bool _loading = false;
  bool _showingTrash = false;
  bool _searching = false;
  bool _searchTruncated = false;
  bool _trashLoading = false;
  String _searchTerm = '';
  String? _error;
  List<TrashEntry> _trashEntries = [];
  int _loadGeneration = 0;
  bool _uploadBusy = false;
  final List<_UploadJob> _uploadJobs = [];
  final Map<String, double> _downloadProgress = {};
  final Set<String> _downloading = {};
  String? _downloadMessage;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFiles());
  }

  @override
  void didUpdateWidget(covariant FilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.isAdmin != widget.isAdmin ||
        oldWidget.accountName != widget.accountName) {
      _cancelUploads();
      unawaited(_loadFiles());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchController.dispose();
    _cancelUploads();
    super.dispose();
  }

  void _refreshState(VoidCallback action) {
    if (mounted && !_disposed) setState(action);
  }

  Future<void> _loadFiles({
    String? target,
    bool more = false,
    bool keepSearch = false,
  }) async {
    final generation = ++_loadGeneration;
    final directory = target ?? _path;
    if (!more) {
      _refreshState(() {
        _loading = true;
        _error = null;
      });
    } else {
      _refreshState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final root = await widget.api.get('/api/v1/files/root');
      final query = <String, String>{
        'path': directory,
        'limit': '$_pageSize',
        'cursor': more ? _nextCursor : '',
      };
      final response = await widget.api.get('/api/v1/files', query: query);
      if (generation != _loadGeneration || !mounted) return;
      final page = _mapList(response['entries'])
          .map(FileEntry.fromJson)
          .toList(growable: false);
      _refreshState(() {
        _rootName = root['name']?.toString().trim().isNotEmpty == true
            ? root['name'].toString()
            : '共享文件';
        _path = directory;
        _canWrite = response['canWrite'] == true || widget.isAdmin;
        _entries = more ? [..._entries, ...page] : page;
        if (!more) _selectedPaths.clear();
        _nextCursor = response['nextCursor']?.toString() ?? '';
        _searchTruncated = false;
        _showingTrash = false;
        if (!keepSearch) {
          _searching = false;
          _searchTerm = '';
          _searchController.clear();
        }
      });
    } catch (error) {
      if (generation == _loadGeneration && mounted) {
        _refreshState(() => _error = '读取目录失败：${_friendlyError(error)}');
      }
    } finally {
      if (generation == _loadGeneration && mounted) {
        _refreshState(() => _loading = false);
      }
    }
  }

  Future<void> _searchFiles() async {
    final term = _searchController.text.trim();
    if (term.runes.length < 2) {
      _refreshState(() => _error = '请输入至少两个字符再搜索。');
      return;
    }
    final generation = ++_loadGeneration;
    _refreshState(() {
      _loading = true;
      _error = null;
      _searching = true;
      _searchTerm = term;
      _showingTrash = false;
      _entries = [];
      _selectedPaths.clear();
      _nextCursor = '';
      _searchTruncated = false;
    });
    try {
      final response = await widget.api.get(
        '/api/v1/files/search',
        query: {'path': '.', 'query': term, 'limit': '$_pageSize'},
      );
      if (generation != _loadGeneration || !mounted) return;
      _refreshState(() {
        _path = '.';
        _selectedPaths.clear();
        _canWrite = response['canWrite'] == true || widget.isAdmin;
        _entries = _mapList(response['entries'])
            .map(FileEntry.fromJson)
            .toList(growable: false);
        _nextCursor = '';
        _searchTruncated = response['truncated'] == true;
      });
    } catch (error) {
      if (generation == _loadGeneration && mounted) {
        _refreshState(() => _error = '搜索失败：${_friendlyError(error)}');
      }
    } finally {
      if (generation == _loadGeneration && mounted) {
        _refreshState(() => _loading = false);
      }
    }
  }

  Future<void> _loadTrash() async {
    _refreshState(() {
      _trashLoading = true;
      _error = null;
      _showingTrash = true;
      _searching = false;
      _selectedPaths.clear();
    });
    try {
      final response = await widget.api.get('/api/v1/files/trash');
      if (!mounted) return;
      final rows =
          _mapList(response['entries']).map(TrashEntry.fromJson).toList()..sort(
            (a, b) => (b.deletedAt ?? DateTime(0)).compareTo(
              a.deletedAt ?? DateTime(0),
            ),
          );
      _refreshState(() => _trashEntries = rows);
    } catch (error) {
      if (mounted) {
        _refreshState(() => _error = '读取回收站失败：${_friendlyError(error)}');
      }
    } finally {
      if (mounted) _refreshState(() => _trashLoading = false);
    }
  }

  Future<void> _toggleTrash() async {
    if (_showingTrash) {
      await _loadFiles(target: _path);
    } else {
      await _loadTrash();
    }
  }

  Future<void> _createFolder() async {
    if (!_canWrite) return;
    final name = await _askFolderName();
    if (name == null) return;
    final path = _joinRelative(_path, name);
    _refreshState(() => _error = null);
    try {
      await widget.api.send(
        'POST',
        '/api/v1/files/folders',
        body: {'path': path},
      );
      await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _error = '新建文件夹失败：${_friendlyError(error)}');
    }
  }

  Future<String?> _askFolderName() async {
    final controller = TextEditingController();
    String? validation;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final value = controller.text.trim();
            final issue = validateFileName(value);
            if (issue != null) {
              setDialogState(() => validation = issue);
            } else {
              Navigator.pop(dialogContext, value);
            }
          }

          return AlertDialog(
            title: const Text('新建文件夹'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 150,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: '文件夹名称',
                    errorText: validation,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('创建')),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _operate(FileEntry item, String action) async {
    if (action == 'move' && !_canWriteItem(item)) return;
    final target = await _askTargetPath(item, action);
    if (target == null || target == item.path) return;
    final issue = validateRelativePath(target);
    if (issue != null) {
      _refreshState(() => _error = issue);
      return;
    }
    if (item.isFolder && target.startsWith('${item.path}/')) {
      _refreshState(() => _error = '不能将文件夹移动或复制到自己的子目录中。');
      return;
    }
    _refreshState(() => _error = null);
    try {
      await widget.api.send(
        'POST',
        '/api/v1/files/operations',
        body: {'action': action, 'from': item.path, 'to': target},
      );
      await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _error = '文件操作失败：${_friendlyError(error)}');
    }
  }

  Future<String?> _askTargetPath(FileEntry item, String action) async {
    final controller = TextEditingController(
      text: action == 'move' ? item.path : _copyPath(item),
    );
    String? validation;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final value = controller.text.trim();
            final issue = validateRelativePath(value);
            if (issue != null) {
              setDialogState(() => validation = issue);
            } else {
              Navigator.pop(dialogContext, value);
            }
          }

          return AlertDialog(
            title: Text(action == 'move' ? '移动或重命名' : '复制文件'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('输入共享目录中的完整相对路径。现有项目不会被覆盖。'),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 1024,
                  decoration: InputDecoration(
                    labelText: '目标路径',
                    errorText: validation,
                  ),
                  textInputAction: TextInputAction.done,
                  onChanged: (value) => setDialogState(() {
                    validation = validateRelativePath(value.trim());
                  }),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submit,
                child: Text(action == 'move' ? '移动' : '复制'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _trash(FileEntry item) async {
    if (!_canWriteItem(item)) return;
    final confirmed = await confirmAction(
      context,
      '移到回收站',
      '“${item.name}”会移入回收站，可以之后恢复。',
      action: '移入回收站',
    );
    if (!confirmed) return;
    _refreshState(() => _error = null);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v1/files',
        query: {'path': item.path},
      );
      await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _error = '移入回收站失败：${_friendlyError(error)}');
    }
  }

  Future<void> _restoreTrash(TrashEntry item) async {
    if (!await confirmAction(
      context,
      '恢复文件',
      '恢复到原位置“${item.originalPath}”。如果该路径已存在，文件不会被覆盖。',
      action: '恢复',
    )) {
      return;
    }
    try {
      await widget.api.send(
        'POST',
        '/api/v1/files/trash/${Uri.encodeComponent(item.id)}/restore',
      );
      await _loadTrash();
    } catch (error) {
      _refreshState(() => _error = '恢复失败：${_friendlyError(error)}');
    }
  }

  Future<void> _refreshCurrentView() async {
    if (_searching) {
      await _searchFiles();
    } else {
      await _loadFiles(target: _path);
    }
  }

  Future<void> _purgeTrash(TrashEntry item) async {
    if (!widget.isAdmin) return;
    if (!await confirmAction(
      context,
      '永久删除文件？',
      '“${item.name}”将被永久删除，此操作无法撤销。',
      action: '永久删除',
    )) {
      return;
    }
    try {
      await widget.api.send(
        'DELETE',
        '/api/v1/files/trash/${Uri.encodeComponent(item.id)}',
      );
      await _loadTrash();
    } catch (error) {
      _refreshState(() => _error = '永久删除失败：${_friendlyError(error)}');
    }
  }

  void _toggleSelected(FileEntry item, bool? selected) {
    if (!_canWriteItem(item)) return;
    if (selected == true &&
        !_selectedPaths.contains(item.path) &&
        _selectedPaths.length >= 50) {
      _refreshState(() => _error = '每次最多选择 50 项移入回收站。');
      return;
    }
    _refreshState(() {
      if (selected == true) {
        _selectedPaths.add(item.path);
      } else {
        _selectedPaths.remove(item.path);
      }
      _error = null;
    });
  }

  Future<void> _batchTrash() async {
    final paths = _selectedPaths.toList(growable: false);
    if (paths.isEmpty) return;
    if (paths.length > 50) {
      _refreshState(() => _error = '每次最多选择 50 项移入回收站。');
      return;
    }
    final byPath = {for (final entry in _entries) entry.path: entry};
    if (paths.any(
      (path) => byPath[path] == null || !_canWriteItem(byPath[path]!),
    )) {
      _refreshState(() => _error = '所选项目包含只读或已变更的项目，请刷新后重试。');
      return;
    }
    if (!await confirmAction(
      context,
      '批量移到回收站',
      '将选中的 ${paths.length} 项移到回收站？之后可以逐项恢复。',
      action: '移入回收站',
    )) {
      return;
    }

    _refreshState(() => _error = null);
    try {
      final response = await widget.api.send(
        'POST',
        '/api/v1/files/batch',
        body: {'action': 'trash', 'paths': paths},
      );
      final results = _mapList(response['results']);
      final failed = results
          .where((result) => result['success'] != true)
          .length;
      final succeeded = results.length - failed;
      await _refreshCurrentView();
      if (failed > 0) {
        _refreshState(() {
          _selectedPaths.addAll(
            results
                .where((result) => result['success'] != true)
                .map((result) => result['path']?.toString() ?? '')
                .where((path) => path.isNotEmpty),
          );
          _error = '$failed 项移入回收站失败，$succeeded 项已完成。请检查权限后重试。';
        });
      } else if (results.length != paths.length) {
        _refreshState(() => _error = '服务端没有返回完整的操作结果，请刷新目录确认文件状态。');
      }
    } catch (error) {
      _refreshState(() => _error = '批量操作失败：${_friendlyError(error)}');
    }
  }

  Future<void> _preview(FileEntry item) async {
    final extension = _extension(item.name);
    final textFile = const {'txt', 'md', 'json', 'log'}.contains(extension);
    final imageFile = const {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
    }.contains(extension);
    final videoFile = const {'mp4', 'webm', 'm4v'}.contains(extension);
    if (videoFile) {
      await showDialog<void>(
        context: context,
        builder: (_) => _FileVideoPreviewDialog(api: widget.api, item: item),
      );
      return;
    }
    if (!textFile && !imageFile) {
      _refreshState(() => _error = '该文件暂不支持在线预览，请下载后使用本机应用打开。');
      return;
    }
    final limit = textFile ? _maxTextPreviewSize : _maxImagePreviewSize;
    Uint8List? data;
    String? failure;
    try {
      data = await widget.api.bytes(
        '/api/v1/files/preview',
        query: {'path': item.path},
        maxBytes: limit,
      );
    } catch (error) {
      failure = _friendlyError(error);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 720,
          child: failure != null
              ? Text('无法预览：$failure')
              : textFile
              ? ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 560),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      utf8.decode(data!, allowMalformed: true),
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 560),
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: Image.memory(
                      data!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Text('图片数据无法显示。'),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareFile(FileEntry item) async {
    if (item.isFolder) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CreateFileShareDialog(api: widget.api, item: item),
    );
  }

  Future<void> _download(FileEntry item) async {
    if (_downloading.contains(item.path)) return;
    final fileName = item.isFolder
        ? '${item.name}.zip'
        : item.name.split('/').last.split('\\').last;
    final nameIssue = validateFileName(fileName);
    if (nameIssue != null) {
      _refreshState(() => _downloadMessage = '无法保存此文件：$nameIssue');
      return;
    }

    final mobileExport =
        widget.mobileExportOverride ??
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    Directory? temporaryDirectory;
    String? destination;
    try {
      if (mobileExport) {
        final temporaryRoot = await getTemporaryDirectory();
        temporaryDirectory =
            await (widget.exportDirectoryFactory?.call(temporaryRoot) ??
                temporaryRoot.createTemp('lightisle-export-'));
        destination = _joinNative(temporaryDirectory.path, fileName);
      } else {
        final directory = await FilePicker.getDirectoryPath(
          dialogTitle: '选择文件保存目录',
        );
        if (!mounted || directory == null || directory.isEmpty) return;
        final normalizedDirectory = _filePickerPath(directory);
        destination = await _destinationWithoutOverwrite(
          normalizedDirectory,
          fileName,
        );
        if (destination == null) return;
      }
    } catch (error) {
      _refreshState(
        () => _downloadMessage = '无法准备下载位置：${_friendlyError(error)}',
      );
      return;
    }
    if (!mounted) {
      await _removeTemporaryDirectory(temporaryDirectory);
      return;
    }

    _refreshState(() {
      _downloading.add(item.path);
      _downloadProgress[item.path] = 0;
      _downloadMessage = null;
    });
    try {
      await widget.api.download(
        item.isFolder ? '/api/v1/files/archive' : '/api/v1/files/content',
        destination,
        query: {'path': item.path},
        onProgress: (received, total) {
          if (total > 0) {
            _refreshState(
              () => _downloadProgress[item.path] = (received / total)
                  .clamp(0, 1)
                  .toDouble(),
            );
          }
        },
      );
      if (!mounted) return;
      if (mobileExport) {
        final exportResult = await _fileExportChannel.invokeMethod<String>(
          'exportFile',
          {'path': destination, 'name': fileName},
        );
        _refreshState(() {
          _downloadMessage = exportResult == null
              ? '已取消导出，临时文件已清理。'
              : exportResult == 'shared'
              ? '已完成系统分享或保存。'
              : '已保存到所选位置：$exportResult';
          _downloadProgress.remove(item.path);
        });
      } else {
        _refreshState(() {
          _downloadMessage = '已下载到：$destination';
          _downloadProgress.remove(item.path);
        });
      }
    } catch (error) {
      _refreshState(() {
        _downloadMessage =
            '下载或导出失败：${_friendlyDownloadError(error, item.isFolder)}';
        _downloadProgress.remove(item.path);
      });
    } finally {
      await _removeTemporaryDirectory(temporaryDirectory);
      _refreshState(() => _downloading.remove(item.path));
    }
  }

  Future<String?> _destinationWithoutOverwrite(
    String directory,
    String fileName,
  ) async {
    final destination = _joinNative(directory, fileName);
    if (!await File(destination).exists()) return destination;

    final alternative = await _nextAvailableDestination(directory, fileName);
    if (!mounted) return null;
    final saveCopy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保留已有文件？'),
        content: Text(
          '此位置已有“$fileName”。原文件会保留，新文件将保存为“${_basename(alternative)}”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('另存为新文件'),
          ),
        ],
      ),
    );
    return saveCopy == true ? alternative : null;
  }

  Future<String> _nextAvailableDestination(
    String directory,
    String fileName,
  ) async {
    final dot = fileName.lastIndexOf('.');
    final hasExtension = dot > 0;
    final stem = hasExtension ? fileName.substring(0, dot) : fileName;
    final extension = hasExtension ? fileName.substring(dot) : '';
    for (var suffix = 2; suffix < 10000; suffix++) {
      final candidate = _joinNative(directory, '$stem ($suffix)$extension');
      if (!await File(candidate).exists()) return candidate;
    }
    throw const FileSystemException('无法生成不冲突的文件名。');
  }

  Future<void> _removeTemporaryDirectory(Directory? directory) async {
    if (directory == null) return;
    try {
      final cleanup = widget.exportDirectoryCleanup;
      if (cleanup != null) {
        await cleanup(directory);
      } else if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Temporary exports are private data; cleanup is best-effort on disk errors.
    }
  }

  Future<void> _pickUploads() async {
    if (!_canWrite || _uploadBusy) return;
    _refreshState(() => _uploadBusy = true);
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件');
    } catch (error) {
      _refreshState(() {
        _uploadBusy = false;
        _error = '无法打开文件选择器：${_friendlyError(error)}';
      });
      return;
    }
    if (!mounted) return;
    if (files.isEmpty) {
      _refreshState(() => _uploadBusy = false);
      return;
    }
    final destinationDirectory = _path;
    final jobs = <_UploadJob>[];
    for (final file in files) {
      final issue = validateFileName(file.name);
      if (issue != null) {
        _refreshState(() => _error = '“${file.name}”无法上传：$issue');
        continue;
      }
      jobs.add(
        _UploadJob(
          file: file,
          destination: _joinRelative(destinationDirectory, file.name),
        ),
      );
    }
    if (jobs.isEmpty) {
      _refreshState(() => _uploadBusy = false);
      return;
    }
    _refreshState(() {
      _uploadJobs.addAll(jobs);
      _error = null;
    });
    for (final job in jobs) {
      if (!mounted || job.cancelRequested) continue;
      await _runUpload(job);
    }
    _refreshState(() => _uploadBusy = false);
    if (mounted) await _refreshCurrentView();
  }

  Future<void> _runUpload(_UploadJob job) async {
    _FileRangeReader? reader;
    job.error = null;
    job.status = _UploadStatus.checking;
    job.offset = 0;
    _refreshState(() {});
    try {
      final size = await job.file.length();
      if (size == null || size < 0) {
        throw const FormatException('无法读取文件大小。');
      }
      if (size > _maxUploadSize) {
        throw const FormatException('文件超过 32 GiB 的上传上限。');
      }
      final digest = await _fingerprint(job, size);
      _checkCancelled(job);
      job.digest = digest;
      job.identityKey = _uploadPreferenceKey(job.destination, size, digest);

      var state = await _resumeOrBeginUpload(job, size);
      job.uploadId = state['id']?.toString();
      var offset = _asInt(state['offset']);
      if (job.uploadId == null ||
          job.uploadId!.isEmpty ||
          _asInt(state['size']) != size ||
          state['path']?.toString() != job.destination ||
          offset < 0 ||
          offset > size) {
        throw const FormatException('服务端返回的上传状态与所选文件不匹配。');
      }
      job.offset = offset;
      job.status = _UploadStatus.uploading;
      _refreshState(() {});
      reader = _FileRangeReader(job);

      while (offset < size) {
        await _waitForResume(job);
        _checkCancelled(job);
        final length = math.min(_uploadChunkSize, size - offset);
        try {
          state = await widget.api.uploadChunk(
            job.uploadId!,
            reader.readRange(offset, length),
            length,
            offset,
          );
        } catch (error) {
          // The server may have committed this chunk even when its response
          // was lost. Re-read the authoritative offset before retrying.
          final latest = await _readUploadState(job.uploadId!);
          if (latest == null) rethrow;
          final latestOffset = _asInt(latest['offset']);
          if (latestOffset <= offset) rethrow;
          state = latest;
        }
        var nextOffset = _asInt(state['offset']);
        if (nextOffset <= offset || nextOffset > size) {
          final latest = await _readUploadState(job.uploadId!);
          if (latest == null) throw const FormatException('无法确认服务端上传进度。');
          nextOffset = _asInt(latest['offset']);
          if (nextOffset <= offset || nextOffset > size) {
            throw const FormatException('服务端上传进度没有前进，请重试。');
          }
        }
        offset = nextOffset;
        job.offset = offset;
        _refreshState(() {});
      }
      await _waitForResume(job);
      _checkCancelled(job);
      await widget.api.send(
        'POST',
        '/api/v1/uploads/${Uri.encodeComponent(job.uploadId!)}/complete',
      );
      await _removeUploadPreference(job.identityKey);
      job.status = _UploadStatus.complete;
      job.offset = size;
    } on _UploadCancelled {
      job.status = _UploadStatus.cancelled;
      await _abortUpload(job);
    } catch (error) {
      if (job.cancelRequested) {
        job.status = _UploadStatus.cancelled;
        await _abortUpload(job);
      } else {
        job.status = _UploadStatus.failed;
        job.error = _friendlyError(error);
      }
    } finally {
      await reader?.close();
    }
    _refreshState(() {});
  }

  Future<String> _fingerprint(_UploadJob job, int size) async {
    job.hashingBytes = 0;
    final stream = job.file.readAsByteStream().map((chunk) {
      _checkCancelled(job);
      job.hashingBytes += chunk.length;
      if (size > 0 && job.hashingBytes % (4 * 1024 * 1024) < chunk.length) {
        _refreshState(() {});
      }
      return chunk;
    });
    final digest = await sha256.bind(stream).first;
    if (job.hashingBytes != size) {
      throw const FormatException('文件大小在校验期间发生变化，请重新选择文件。');
    }
    return digest.toString();
  }

  Future<Map<String, dynamic>> _resumeOrBeginUpload(
    _UploadJob job,
    int size,
  ) async {
    final identityKey = job.identityKey!;
    final activeId = job.uploadId;
    if (activeId != null && activeId.isNotEmpty) {
      final activeState = await _readUploadState(activeId);
      if (activeState != null &&
          activeState['path']?.toString() == job.destination &&
          _asInt(activeState['size']) == size) {
        return activeState;
      }
      job.uploadId = null;
    }
    String? savedId;
    try {
      savedId = (await SharedPreferences.getInstance()).getString(identityKey);
    } catch (_) {
      // The active page can still resume from the server's offset, even when
      // local preferences are unavailable for a later app launch.
    }
    if (savedId != null && savedId.isNotEmpty) {
      final savedState = await _readUploadState(savedId);
      if (savedState != null &&
          savedState['path']?.toString() == job.destination &&
          _asInt(savedState['size']) == size) {
        job.uploadId = savedId;
        return savedState;
      }
      await _removeUploadPreference(identityKey);
    }
    _checkCancelled(job);
    final state = await widget.api.send(
      'POST',
      '/api/v1/uploads',
      body: {'path': job.destination, 'size': size},
    );
    final id = state['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const FormatException('服务器没有返回上传任务编号。');
    }
    job.uploadId = id;
    try {
      await (await SharedPreferences.getInstance()).setString(identityKey, id);
    } catch (_) {
      // Keep the upload usable in this session without persistent resume.
    }
    return state;
  }

  Future<Map<String, dynamic>?> _readUploadState(String id) async {
    try {
      return await widget.api.get('/api/v1/uploads/${Uri.encodeComponent(id)}');
    } catch (error) {
      if (error is LightIsleApiException && error.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> _waitForResume(_UploadJob job) async {
    while (job.pauseRequested && !job.cancelRequested) {
      job.status = _UploadStatus.paused;
      job.pauseGate ??= Completer<void>();
      _refreshState(() {});
      await job.pauseGate!.future;
      job.pauseGate = null;
    }
    _checkCancelled(job);
    if (job.status == _UploadStatus.paused) {
      job.status = _UploadStatus.uploading;
    }
  }

  void _togglePause(_UploadJob job) {
    if (job.status == _UploadStatus.paused || job.pauseRequested) {
      job.pauseRequested = false;
      job.status = _UploadStatus.uploading;
      final gate = job.pauseGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      job.pauseGate = null;
    } else if (job.status == _UploadStatus.uploading) {
      job.pauseRequested = true;
      job.status = _UploadStatus.paused;
    }
    _refreshState(() {});
  }

  void _cancelUpload(_UploadJob job) {
    job.cancelRequested = true;
    job.pauseRequested = false;
    final gate = job.pauseGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    _refreshState(() {});
  }

  Future<void> _discardUpload(_UploadJob job) async {
    job.cancelRequested = true;
    await _abortUpload(job);
    job.status = _UploadStatus.cancelled;
    _refreshState(() {});
  }

  void _cancelUploads() {
    for (final job in _uploadJobs) {
      if (job.status == _UploadStatus.uploading ||
          job.status == _UploadStatus.paused ||
          job.status == _UploadStatus.checking) {
        job.cancelRequested = true;
        job.pauseRequested = false;
        final gate = job.pauseGate;
        if (gate != null && !gate.isCompleted) gate.complete();
      }
    }
  }

  void _checkCancelled(_UploadJob job) {
    if (job.cancelRequested) throw const _UploadCancelled();
  }

  Future<void> _abortUpload(_UploadJob job) async {
    final id = job.uploadId;
    var aborted = id == null || id.isEmpty;
    if (id != null && id.isNotEmpty) {
      try {
        await widget.api.send(
          'DELETE',
          '/api/v1/uploads/${Uri.encodeComponent(id)}',
        );
        aborted = true;
      } catch (_) {
        // The server still owns the durable staging record if the connection
        // drops. The matching identity remains available for retry.
      }
    }
    if (aborted) await _removeUploadPreference(job.identityKey);
  }

  Future<void> _removeUploadPreference(String? key) async {
    if (key == null) return;
    try {
      await (await SharedPreferences.getInstance()).remove(key);
    } catch (_) {}
  }

  Future<void> _retryUpload(_UploadJob job) async {
    if (_uploadBusy) return;
    _refreshState(() {
      _uploadBusy = true;
      job.cancelRequested = false;
      job.pauseRequested = false;
    });
    await _runUpload(job);
    _refreshState(() => _uploadBusy = false);
  }

  String _uploadPreferenceKey(String destination, int size, String digest) {
    final identity = sha256.convert(
      utf8.encode(
        '${widget.api.uri('/').origin}\u0000${widget.accountName}\u0000$destination\u0000$size\u0000$digest',
      ),
    );
    return 'lightisle_upload_v3_$identity';
  }

  Future<void> _copyPathToClipboard(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('下载路径已复制。')));
  }

  bool _canWriteItem(FileEntry item) => item.canWrite || widget.isAdmin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        return ListView(
          padding: EdgeInsets.all(compact ? 16 : 24),
          children: [
            _buildHeader(context),
            const SizedBox(height: 14),
            _buildToolbar(context, compact),
            if (_searching) ...[
              const SizedBox(height: 8),
              Text(
                '共享目录搜索“$_searchTerm” · 仅搜索当前账号可访问的名称。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (!_showingTrash && !_canWrite && !_loading)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Material(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline,
                          color: colors.onSecondaryContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '当前目录为只读。你可以浏览、预览和下载文件。',
                            style: TextStyle(
                              color: colors.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Notice(
                _error!,
                error: true,
                onRetry: _showingTrash
                    ? _loadTrash
                    : _searching
                    ? _searchFiles
                    : () => _loadFiles(),
              ),
            if (_downloadMessage != null) _downloadNotice(context),
            if (_uploadJobs.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildUploads(context),
            ],
            const SizedBox(height: 16),
            _buildFileList(context, compact),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IslePageHeader(
          title: '文件管理',
          subtitle: '浏览共享目录、管理文件并查看回收站。',
          icon: Icons.folder_open_rounded,
          trailing: IconButton.filledTonal(
            tooltip: _showingTrash ? '刷新回收站' : '刷新目录',
            onPressed: _loading || _trashLoading
                ? null
                : () => _showingTrash ? _loadTrash() : _loadFiles(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        _buildBreadcrumbs(context),
      ],
    );
  }

  Widget _buildBreadcrumbs(BuildContext context) {
    final segments = _pathSegments();
    final colors = Theme.of(context).colorScheme;
    return IsleSurface(
      padding: const EdgeInsets.all(8),
      radius: IsleTokens.itemRadius,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        runSpacing: 2,
        children: [
          for (var index = 0; index < segments.length; index++) ...[
            if (index > 0)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            _breadcrumbSegment(
              context,
              segments[index],
              index == segments.length - 1,
            ),
          ],
        ],
      ),
    );
  }

  Widget _breadcrumbSegment(
    BuildContext context,
    (String, String) segment,
    bool active,
  ) {
    final colors = Theme.of(context).colorScheme;
    final label = Text(
      segment.$1,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: active ? colors.primary : colors.onSurfaceVariant,
        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width < 360 ? 112 : 190,
      ),
      child: Tooltip(
        message: segment.$1,
        child: active
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: label,
                ),
              )
            : TextButton(
                onPressed: _loading || _showingTrash
                    ? null
                    : () => _loadFiles(target: segment.$2),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: label,
              ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, bool compact) {
    final search = TextField(
      controller: _searchController,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _searchFiles(),
      decoration: InputDecoration(
        hintText: '搜索文件名（至少 2 个字符）',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清除搜索',
                onPressed: () {
                  _searchController.clear();
                  if (_searching) _loadFiles(target: '.');
                },
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    );
    final actions = <Widget>[
      if (compact)
        OutlinedButton.icon(
          onPressed: _loading ? null : _searchFiles,
          icon: const Icon(Icons.search_rounded),
          label: const Text('搜索'),
        ),
      if (!_showingTrash && _canWrite)
        OutlinedButton.icon(
          onPressed: _loading ? null : _createFolder,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('新建文件夹'),
        ),
      if (!_showingTrash && _canWrite)
        FilledButton.icon(
          onPressed: _loading || _uploadBusy ? null : _pickUploads,
          icon: const Icon(Icons.upload_file_rounded),
          label: const Text('上传文件'),
        ),
      OutlinedButton.icon(
        onPressed: _trashLoading ? null : _toggleTrash,
        icon: Icon(
          _showingTrash ? Icons.folder_open_outlined : Icons.delete_outline,
        ),
        label: Text(_showingTrash ? '返回文件' : '回收站'),
      ),
    ];
    final content = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          )
        : Column(
            children: [
              Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _searchFiles,
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('搜索'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, runSpacing: 8, children: actions),
              ),
            ],
          );
    return IsleSurface(
      padding: EdgeInsets.all(compact ? 14 : 18),
      radius: IsleTokens.cardRadius,
      child: content,
    );
  }

  Widget _buildFileList(BuildContext context, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final title = _showingTrash
        ? '回收站'
        : _searching
        ? '搜索结果'
        : '$_rootName · ${_path == '.' ? '全部文件' : _path}';
    return IsleSurface(
      padding: EdgeInsets.zero,
      radius: IsleTokens.cardRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : 20,
              vertical: 14,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (!_showingTrash && _entries.isNotEmpty)
                  Text(
                    '${_entries.length} 项',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (!_showingTrash && _selectedPaths.isNotEmpty)
            _selectionToolbar(context, compact),
          const Divider(height: 1),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else if (_showingTrash && _trashLoading)
            const LinearProgressIndicator(minHeight: 2)
          else if (_showingTrash)
            _trashEntries.isEmpty
                ? _emptyState(context, '回收站是空的。', Icons.delete_outline)
                : Column(
                    children: _trashEntries
                        .map((entry) => _trashTile(context, entry, compact))
                        .toList(),
                  )
          else if (_entries.isEmpty)
            _emptyState(
              context,
              _searching ? '没有找到匹配的文件或文件夹。' : '此文件夹目前是空的。',
              Icons.folder_open_outlined,
            )
          else
            Column(
              children: [
                ..._entries.map((entry) => _fileTile(context, entry, compact)),
                if (_searchTruncated)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '搜索结果已达到服务端上限，请缩小关键词。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                if (_nextCursor.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : () => _loadFiles(more: true),
                      icon: const Icon(Icons.expand_more),
                      label: const Text('加载更多文件'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _selectionToolbar(BuildContext context, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final selectedCount = _selectedPaths.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 0, compact ? 12 : 20, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(alpha: .58),
          borderRadius: BorderRadius.circular(IsleTokens.itemRadius),
          border: Border.all(color: colors.primary.withValues(alpha: .18)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '已选 $selectedCount 项 · 每次最多 50 项',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _loading
                        ? null
                        : () => _refreshState(_selectedPaths.clear),
                    icon: const Icon(Icons.clear_all_rounded),
                    label: const Text('清除选择'),
                  ),
                  FilledButton.icon(
                    onPressed: _loading ? null : _batchTrash,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('批量移到回收站'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileBadge(FileEntry item) {
    if (item.isFolder) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          gradient: const LinearGradient(
            colors: [Color(0xff38bdf8), Color(0xff0284c7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xff0284c7).withValues(alpha: 0.28),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(Icons.folder_rounded, color: Colors.white, size: 21),
      );
    }

    final ext = _extension(item.name);
    final (colors, icon) = switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' => (
        const [Color(0xfff43f5e), Color(0xffec4899)],
        Icons.image_rounded,
      ),
      'mp4' || 'mov' || 'm4v' || 'webm' || 'mkv' => (
        const [Color(0xff8b5cf6), Color(0xff6366f1)],
        Icons.movie_rounded,
      ),
      'mp3' || 'flac' || 'wav' || 'm4a' || 'aac' => (
        const [Color(0xfff59e0b), Color(0xffea580c)],
        Icons.music_note_rounded,
      ),
      'pdf' => (
        const [Color(0xffef4444), Color(0xffb91c1c)],
        Icons.picture_as_pdf_rounded,
      ),
      'zip' || '7z' || 'rar' || 'tar' || 'gz' || 'dmg' => (
        const [Color(0xff64748b), Color(0xff475569)],
        Icons.archive_rounded,
      ),
      'txt' ||
      'md' ||
      'log' ||
      'json' ||
      'yaml' ||
      'xml' ||
      'ts' ||
      'js' ||
      'swift' ||
      'go' => (
        const [Color(0xff0ea5e9), Color(0xff2563eb)],
        Icons.description_rounded,
      ),
      _ => (
        const [Color(0xff94a3b8), Color(0xff64748b)],
        Icons.insert_drive_file_rounded,
      ),
    };

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }

  Widget _fileTile(BuildContext context, FileEntry item, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final writable = _canWriteItem(item);
    final selected = _selectedPaths.contains(item.path);
    final modified = item.modified == null
        ? '修改时间未知'
        : _formatDate(item.modified!);
    return Column(
      children: [
        ListTile(
          minTileHeight: 64,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 20,
            vertical: 2,
          ),
          selected: selected,
          selectedTileColor: colors.primaryContainer.withValues(alpha: .42),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (writable)
                Semantics(
                  label: '选择 ${item.name} 移入回收站',
                  child: Checkbox(
                    value: selected,
                    onChanged: (value) => _toggleSelected(item, value),
                  ),
                ),
              const SizedBox(width: 4),
              _buildFileBadge(item),
            ],
          ),
          title: Text(
            item.name,
            softWrap: true,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${item.isFolder ? '文件夹' : formatBytes(item.size)} · $modified',
          ),
          onTap: _loading
              ? null
              : item.isFolder
              ? () => _loadFiles(target: item.path)
              : () => _preview(item),
          trailing: PopupMenuButton<String>(
            tooltip: '文件操作',
            onSelected: (value) {
              switch (value) {
                case 'preview':
                  _preview(item);
                case 'download':
                  _download(item);
                case 'share':
                  _shareFile(item);
                case 'copy':
                  _operate(item, 'copy');
                case 'move':
                  _operate(item, 'move');
                case 'trash':
                  _trash(item);
              }
            },
            itemBuilder: (context) => [
              if (!item.isFolder)
                const PopupMenuItem(
                  value: 'preview',
                  child: ListTile(
                    leading: Icon(Icons.visibility_outlined),
                    title: Text('预览'),
                  ),
                ),
              PopupMenuItem(
                value: 'download',
                child: ListTile(
                  leading: Icon(
                    item.isFolder
                        ? Icons.archive_outlined
                        : Icons.download_outlined,
                  ),
                  title: Text(item.isFolder ? '下载文件夹 ZIP' : '下载'),
                ),
              ),
              if (!item.isFolder)
                const PopupMenuItem(
                  value: 'share',
                  child: ListTile(
                    leading: Icon(Icons.ios_share_outlined),
                    title: Text('分享文件'),
                  ),
                ),
              if (_canWrite)
                const PopupMenuItem(
                  value: 'copy',
                  child: ListTile(
                    leading: Icon(Icons.copy_outlined),
                    title: Text('复制'),
                  ),
                ),
              if (writable)
                const PopupMenuItem(
                  value: 'move',
                  child: ListTile(
                    leading: Icon(Icons.drive_file_move_outline),
                    title: Text('移动或重命名'),
                  ),
                ),
              if (writable)
                const PopupMenuItem(
                  value: 'trash',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('移到回收站'),
                  ),
                ),
            ],
          ),
        ),
        if (_downloading.contains(item.path))
          Padding(
            padding: const EdgeInsets.only(left: 70, right: 20, bottom: 8),
            child: LinearProgressIndicator(value: _downloadProgress[item.path]),
          ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }

  Widget _trashTile(
    BuildContext context,
    TrashEntry item,
    bool compact,
  ) => Column(
    children: [
      ListTile(
        minTileHeight: 72,
        contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 20,
          vertical: 2,
        ),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            gradient: const LinearGradient(
              colors: [Color(0xfff87171), Color(0xffdc2626)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xffdc2626).withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            Icons.delete_outline_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
        title: Text(
          item.name,
          softWrap: true,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '原路径：${item.originalPath}\n${item.deletedAt == null ? '' : _formatDate(item.deletedAt!)}',
          softWrap: true,
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 4,
          children: [
            IconButton(
              tooltip: '恢复',
              onPressed: () => _restoreTrash(item),
              icon: const Icon(Icons.restore),
            ),
            if (widget.isAdmin)
              IconButton(
                tooltip: '永久删除',
                onPressed: () => _purgeTrash(item),
                color: Theme.of(context).colorScheme.error,
                icon: const Icon(Icons.delete_forever_outlined),
              ),
          ],
        ),
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
    ],
  );

  Widget _buildUploads(BuildContext context) {
    return IsleSurface(
      radius: IsleTokens.cardRadius,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '上传任务',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          for (final job in _uploadJobs.reversed) _uploadTile(context, job),
        ],
      ),
    );
  }

  Widget _uploadTile(BuildContext context, _UploadJob job) {
    final size = job.file.lengthSync() ?? 0;
    final progress = size > 0
        ? (job.offset / size).clamp(0, 1).toDouble()
        : 0.0;
    final label = switch (job.status) {
      _UploadStatus.checking =>
        '正在计算 SHA-256 ${size == 0 ? '' : '${(job.hashingBytes / size * 100).clamp(0, 100).round()}%'}',
      _UploadStatus.uploading =>
        '上传中 ${formatBytes(job.offset)} / ${formatBytes(size)}',
      _UploadStatus.paused =>
        '已暂停 ${formatBytes(job.offset)} / ${formatBytes(size)}',
      _UploadStatus.failed => job.error ?? '上传失败',
      _UploadStatus.complete => '上传完成 · ${formatBytes(size)}',
      _UploadStatus.cancelled => '已取消',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '$label · ${job.destination}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (job.status == _UploadStatus.uploading ||
                  job.status == _UploadStatus.paused)
                IconButton(
                  tooltip: job.status == _UploadStatus.paused ? '继续上传' : '暂停上传',
                  onPressed: () => _togglePause(job),
                  icon: Icon(
                    job.status == _UploadStatus.paused
                        ? Icons.play_arrow
                        : Icons.pause,
                  ),
                ),
              if (job.status == _UploadStatus.uploading ||
                  job.status == _UploadStatus.paused ||
                  job.status == _UploadStatus.checking)
                IconButton(
                  tooltip: '取消上传',
                  onPressed: () => _cancelUpload(job),
                  icon: const Icon(Icons.close),
                ),
              if (job.status == _UploadStatus.failed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '重试上传',
                      onPressed: _uploadBusy ? null : () => _retryUpload(job),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: '取消并清除上传任务',
                      onPressed: () => _discardUpload(job),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              if (job.status == _UploadStatus.complete ||
                  job.status == _UploadStatus.cancelled)
                IconButton(
                  tooltip: '移除任务',
                  onPressed: () => _refreshState(() => _uploadJobs.remove(job)),
                  icon: const Icon(Icons.clear),
                ),
            ],
          ),
          if (job.status == _UploadStatus.uploading ||
              job.status == _UploadStatus.paused)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: LinearProgressIndicator(
                value: size == 0 ? null : progress,
              ),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }

  Widget _downloadNotice(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Material(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.download_done_outlined),
            const SizedBox(width: 10),
            Expanded(child: SelectableText(_downloadMessage!)),
            if (_downloadMessage!.startsWith('已下载到：'))
              IconButton(
                tooltip: '复制下载路径',
                onPressed: () => _copyPathToClipboard(
                  _downloadMessage!.substring('已下载到：'.length),
                ),
                icon: const Icon(Icons.copy),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _emptyState(BuildContext context, String text, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.primary.withValues(alpha: isDark ? 0.16 : 0.08),
              border: Border.all(
                color: colors.primary.withValues(alpha: isDark ? 0.25 : 0.18),
                width: 0.75,
              ),
            ),
            child: Icon(icon, size: 26, color: colors.primary),
          ),
          const SizedBox(height: 14),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  List<(String, String)> _pathSegments() {
    final result = <(String, String)>[(_rootName, '.')];
    if (_path == '.' || _path.isEmpty) return result;
    final names = _path.split('/');
    for (var i = 0; i < names.length; i++) {
      result.add((names[i], names.take(i + 1).join('/')));
    }
    return result;
  }
}

class _CreateFileShareDialog extends StatefulWidget {
  const _CreateFileShareDialog({required this.api, required this.item});

  final LightIsleApi api;
  final FileEntry item;

  @override
  State<_CreateFileShareDialog> createState() => _CreateFileShareDialogState();
}

class _CreateFileShareDialogState extends State<_CreateFileShareDialog> {
  static const _hourOptions = <int>[1, 6, 24, 72, 168];
  final TextEditingController _linkController = TextEditingController();
  int _hours = 24;
  bool _creating = false;
  String? _error;
  String? _copyMessage;

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating || _linkController.text.isNotEmpty) return;
    setState(() {
      _creating = true;
      _error = null;
      _copyMessage = null;
    });
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v1/file-shares',
        body: {'path': widget.item.path, 'hours': _hours},
      );
      final token = result['token']?.toString() ?? '';
      if (token.isEmpty) {
        throw const FormatException('服务端没有返回分享链接，请刷新分享列表确认创建状态。');
      }
      final link = widget.api
          .uri('/api/v1/public/file/${Uri.encodeComponent(token)}')
          .toString();
      if (mounted) setState(() => _linkController.text = link);
    } catch (error) {
      if (mounted) setState(() => _error = _shareErrorMessage(error));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copy() async {
    final link = _linkController.text;
    if (link.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) setState(() => _copyMessage = '已复制分享链接。');
    } catch (_) {
      _linkController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: link.length,
      );
      if (mounted) setState(() => _copyMessage = '无法访问剪贴板，链接已选中，请手动复制。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final created = _linkController.text.isNotEmpty;
    return AlertDialog(
      title: Text(
        '限时分享 · ${widget.item.name}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('生成仅可下载此文件的临时链接。获得链接的人无需登录；链接到期、文件变化或读取授权撤销后会失效。'),
            const SizedBox(height: 16),
            if (!created)
              DropdownButtonFormField<int>(
                initialValue: _hours,
                decoration: const InputDecoration(labelText: '有效期'),
                items: [
                  for (final hours in _hourOptions)
                    DropdownMenuItem<int>(
                      value: hours,
                      child: Text(_hourLabel(hours)),
                    ),
                ],
                onChanged: _creating
                    ? null
                    : (value) {
                        if (value != null) setState(() => _hours = value);
                      },
              )
            else ...[
              TextField(
                controller: _linkController,
                readOnly: true,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '分享链接（仅此时显示）',
                  helperText: '保存或发送给需要下载的人。关闭此窗口后无法再次查看。',
                ),
                onTap: () => _linkController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _linkController.text.length,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('复制分享链接'),
                ),
              ),
              if (_copyMessage != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _copyMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!created)
          FilledButton.icon(
            onPressed: _creating ? null : _create,
            icon: _creating
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link_rounded),
            label: Text(_creating ? '正在生成…' : '生成分享链接'),
          ),
        TextButton(
          onPressed: _creating ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

String _hourLabel(int hours) => switch (hours) {
  1 => '1 小时',
  6 => '6 小时',
  24 => '1 天',
  72 => '3 天',
  168 => '7 天',
  _ => '$hours 小时',
};

String _shareErrorMessage(Object error) {
  if (error is LightIsleApiException) {
    return switch (error.code) {
      'too_many_shares' => '有效分享链接已达到上限。请先撤销不再使用的链接。',
      'file_too_large_to_share' => '文件超过 2 GiB，无法创建下载分享。',
      'file_permission_denied' => '当前账号已无法读取此文件，请刷新目录后重试。',
      'invalid_share_request' => '分享时长或文件路径无效，请重新选择后重试。',
      'authentication_required' => '登录状态已失效，请重新登录。',
      _ => error.message,
    };
  }
  return error.toString();
}

String _friendlyDownloadError(Object error, bool archive) {
  if (archive && error is LightIsleApiException) {
    if (error.code == 'archive_limit_exceeded' || error.statusCode == 413) {
      return '文件夹超过 ZIP 导出限制（2 GiB 或 2,000 项），请下载较小的子文件夹。';
    }
    if (error.code == 'archive_source_changed') {
      return '文件夹内容在下载前发生变化，请刷新目录后重试。';
    }
  }
  return _friendlyError(error);
}

class _FileVideoPreviewDialog extends StatefulWidget {
  const _FileVideoPreviewDialog({required this.api, required this.item});

  final LightIsleApi api;
  final FileEntry item;

  @override
  State<_FileVideoPreviewDialog> createState() =>
      _FileVideoPreviewDialogState();
}

class _FileVideoPreviewDialogState extends State<_FileVideoPreviewDialog>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  late final Future<void> _initialization = _initialize();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _initialize() async {
    try {
      final source = await widget.api.mediaUri(
        '/api/v1/files/preview',
        query: {'path': widget.item.path},
      );
      if (!mounted) return;
      final controller = VideoPlayerController.networkUrl(
        source,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      _controller = controller;
      await controller.initialize();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        setState(() => _error = '无法播放此视频：${_friendlyError(error)}');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      final controller = _controller;
      if (controller?.value.isPlaying == true) unawaited(controller!.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 840, maxHeight: 560),
      child: FutureBuilder<void>(
        future: _initialization,
        builder: (context, snapshot) {
          if (_error != null || snapshot.hasError) {
            return Center(
              child: Text(
                _error ?? '无法播放此视频，请下载后使用本机应用打开。',
                textAlign: TextAlign.center,
              ),
            );
          }
          final controller = _controller;
          if (controller == null || !controller.value.isInitialized) {
            return const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: AspectRatio(
                    aspectRatio: value.aspectRatio > 0
                        ? value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(controller),
                  ),
                ),
                VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: value.isPlaying ? '暂停' : '播放',
                      onPressed: () async {
                        if (value.isPlaying) {
                          await controller.pause();
                        } else {
                          await controller.play();
                        }
                      },
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                      ),
                    ),
                    Text(_videoTime(value.position)),
                    const Text(' / '),
                    Text(_videoTime(value.duration)),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

String _videoTime(Duration value) {
  final totalSeconds = value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

class _FileRangeReader {
  _FileRangeReader(this.job);

  final _UploadJob job;
  StreamIterator<Uint8List>? _iterator;
  Uint8List? _buffer;
  int _bufferOffset = 0;
  int _position = 0;

  Future<void> _start() async {
    _iterator ??= StreamIterator<Uint8List>(job.file.readAsByteStream());
  }

  Future<void> _seek(int target) async {
    await _iterator?.cancel();
    _iterator = StreamIterator<Uint8List>(job.file.readAsByteStream());
    _buffer = null;
    _bufferOffset = 0;
    _position = 0;
    var remaining = target;
    while (remaining > 0) {
      if (!await _nextBuffer()) {
        throw const FormatException('无法读取文件到服务端要求的上传位置。');
      }
      final available = _buffer!.length - _bufferOffset;
      final take = math.min(available, remaining);
      _bufferOffset += take;
      _position += take;
      remaining -= take;
    }
  }

  Future<bool> _nextBuffer() async {
    if (_buffer != null && _bufferOffset < _buffer!.length) return true;
    await _start();
    if (!await _iterator!.moveNext()) return false;
    _buffer = _iterator!.current;
    _bufferOffset = 0;
    if (_buffer!.isEmpty) return _nextBuffer();
    return true;
  }

  Stream<List<int>> readRange(int start, int length) async* {
    if (_position != start) await _seek(start);
    var remaining = length;
    while (remaining > 0) {
      if (job.cancelRequested) throw const _UploadCancelled();
      if (!await _nextBuffer()) {
        throw const FormatException('无法重新读取文件内容，上传已暂停。');
      }
      final available = _buffer!.length - _bufferOffset;
      final take = math.min(available, remaining);
      await _waitForUploadResume(job);
      if (job.cancelRequested) throw const _UploadCancelled();
      final begin = _bufferOffset;
      _bufferOffset += take;
      _position += take;
      remaining -= take;
      yield begin == 0 && take == _buffer!.length
          ? _buffer!
          : _buffer!.sublist(begin, begin + take);
    }
  }

  Future<void> close() async {
    await _iterator?.cancel();
    _iterator = null;
  }
}

Future<void> _waitForUploadResume(_UploadJob job) async {
  while (job.pauseRequested && !job.cancelRequested) {
    job.status = _UploadStatus.paused;
    job.pauseGate ??= Completer<void>();
    await job.pauseGate!.future;
    job.pauseGate = null;
  }
  if (job.cancelRequested) throw const _UploadCancelled();
  if (job.status == _UploadStatus.paused) job.status = _UploadStatus.uploading;
}

class _UploadCancelled implements Exception {
  const _UploadCancelled();
}

List<Map<String, dynamic>> _mapList(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList()
    : <Map<String, dynamic>>[];

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String? validateFileName(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '名称不能为空。';
  if (value == '.' || value == '..') return '不能使用“.”或“..”作为名称。';
  if (value.startsWith('.lightisle-')) return '此名称为系统保留名称。';
  if (value.contains('/') || value.contains('\\')) return '名称不能包含路径分隔符。';
  if (value.runes.length > 150) return '名称不能超过 150 个字符。';
  if (value.contains('\u0000')) return '名称包含无效字符。';
  return null;
}

String? validateRelativePath(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value == '.') return '请输入目标路径。';
  if (value.length > 1024) return '路径不能超过 1024 个字符。';
  if (value.startsWith('/') || value.startsWith('\\') || value.contains('\\')) {
    return '请使用共享目录内的相对路径。';
  }
  final parts = value.split('/');
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return '路径中不能包含空段、“.”或“..”。';
  }
  if (parts.any((part) => part.startsWith('.lightisle-'))) {
    return '路径包含系统保留名称。';
  }
  if (parts.any((part) => part.runes.length > 150)) {
    return '每个路径部分最多 150 个字符。';
  }
  if (value.contains('\u0000')) return '路径包含无效字符。';
  return null;
}

String _joinRelative(String directory, String name) =>
    directory == '.' || directory.isEmpty ? name : '$directory/$name';

String _copyPath(FileEntry item) {
  final dot = item.name.lastIndexOf('.');
  final hasExtension = dot > 0;
  final stem = hasExtension ? item.name.substring(0, dot) : item.name;
  final extension = hasExtension ? item.name.substring(dot) : '';
  final copyName = '$stem - 副本$extension';
  final slash = item.path.lastIndexOf('/');
  return slash < 0 ? copyName : '${item.path.substring(0, slash + 1)}$copyName';
}

String _friendlyError(Object error) {
  final value = error.toString().replaceFirst(
    RegExp(r'^(Exception|Error):\s*'),
    '',
  );
  const translations = {
    'path_not_allowed': '路径不合法或包含系统保留名称。',
    'unsupported_file_type': '该操作只支持普通文件或文件夹。',
    'not_found': '文件或目录不存在。',
    'file_already_exists': '目标位置已存在同名项目。',
    'upload_busy': '此目标已有上传任务，请使用原任务续传或先取消它。',
    'upload_too_large': '文件超过服务端允许的大小。',
    'permission_denied': '当前账号没有此路径的写入权限。',
    'file_permission_denied': '当前账号没有访问此路径的权限。',
    'upload_owner_mismatch': '上传任务属于另一个账号。',
    'shared_volume_offline': '共享存储当前不可用，请稍后重试。',
    'offset_mismatch': '服务端上传进度已变化，正在重新读取进度。',
    'upload_state_corrupt': '服务器无法恢复这次上传，请取消并重新上传。',
    'storage_durability_failure': '存储未能确认写入，请刷新确认文件状态后重试。',
    'upload_outcome_uncertain': '服务器无法确认文件是否已完整发布，请先刷新目录确认。',
  };
  if (translations.containsKey(value)) return translations[value]!;
  final status = RegExp(r'(?:HTTP\s*)?(\d{3})').firstMatch(value)?.group(1);
  return switch (status) {
    '401' => '登录状态已失效，请重新登录。',
    '403' => '当前账号没有权限执行此操作。',
    '404' => '文件或服务端任务已不存在。',
    '409' => '目标已变化或已存在，请刷新后重试。',
    '413' => '文件超过服务端允许的大小。',
    '503' => '共享存储或服务暂时不可用。',
    _ => value.isEmpty ? '未知错误。' : value,
  };
}

String _formatDate(DateTime date) {
  final local = date.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String _joinNative(String directory, String name) {
  final separator = Platform.pathSeparator;
  final clean = directory.endsWith(separator)
      ? directory.substring(0, directory.length - separator.length)
      : directory;
  return '$clean$separator$name';
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _filePickerPath(String path) {
  final uri = Uri.tryParse(path);
  if (uri != null && uri.scheme == 'file') return uri.toFilePath();
  return path;
}
