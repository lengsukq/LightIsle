import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'downloads_page.dart';
import 'file_destination_dialog.dart';
import 'external_file_opener.dart';
import 'file_preview_support.dart';
import 'file_name_validation.dart';
import 'file_share_dialog.dart';
import 'file_models.dart';
export 'file_models.dart' show FileEntry, TrashEntry;
import 'file_pdf_preview.dart';
import 'file_upload_stream.dart';
import 'file_export_service.dart';
export 'file_name_validation.dart' show validateFileName;
export 'file_name_validation.dart' show validateRelativePath;
export 'file_share_dialog.dart' show openMediaFileShare;
export 'file_export_service.dart'
    show exportOfflineMediaFile, exportMediaFile, exportMediaFiles;
import '../media/photo_gallery_viewer.dart';
import '../media/media_models.dart';
import 'file_upload_service.dart';

const int _pageSize = 100;
const int _maxTextPreviewSize = 1024 * 1024;

Future<void> openFileManager(
  BuildContext context, {
  required LightIsleApi api,
  required bool isAdmin,
  required String directory,
  required String title,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: Builder(
          builder: (context) =>
              BackButton(onPressed: () => Navigator.of(context).maybePop()),
        ),
      ),
      body: SafeArea(
        top: false,
        child: FilesPage(api: api, isAdmin: isAdmin, initialPath: directory),
      ),
    ),
  ),
);

/// Reuse the file browser's bounded, resumable uploader for every entry point.
/// The caller has already selected the category's generation-bound root.
Future<int> openFileUpload(
  BuildContext context, {
  required LightIsleApi api,
  required bool isAdmin,
  required String directory,
  FileType type = FileType.any,
  String title = '上传文件',
}) async {
  var completed = 0;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: Builder(
            builder: (context) =>
                BackButton(onPressed: () => Navigator.of(context).maybePop()),
          ),
        ),
        body: SafeArea(
          top: false,
          child: FilesPage(
            api: api,
            isAdmin: isAdmin,
            initialPath: directory,
            uploadOnly: true,
            initialUploadType: type,
            onUploaded: () => completed++,
          ),
        ),
      ),
    ),
  );
  return completed;
}

class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.api,
    required this.isAdmin,
    this.accountName = '',
    this.initialPath = '.',
    this.showPhotoBackup = false,
    this.uploadOnly = false,
    this.initialUploadType = FileType.any,
    this.onUploaded,
    @visibleForTesting this.mobileExportOverride,
    @visibleForTesting this.exportDirectoryFactory,
    @visibleForTesting this.exportDirectoryCleanup,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;

  /// The authenticated user's configured files directory.
  final String initialPath;
  final bool showPhotoBackup;
  final bool uploadOnly;
  final FileType initialUploadType;
  final VoidCallback? onUploaded;

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
  late String _path;
  String _rootName = '共享文件';
  List<FileEntry> _entries = [];
  final Set<String> _failedThumbnails = <String>{};
  final Set<String> _selectedPaths = <String>{};
  String _nextCursor = '';
  String _fileSort = 'name';
  String _fileSortDirection = 'asc';
  bool _uploadAutoRename = false;
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
  final List<FileUploadJob> _uploadJobs = [];
  final Map<String, double> _downloadProgress = {};
  final Set<String> _downloading = {};
  String? _downloadMessage;
  bool _disposed = false;
  bool _selecting = false;
  bool _batchBusy = false;

  late FileUploadService _uploadService;

  FileUploadService _newUploadService() => FileUploadService(
    api: widget.api,
    accountName: widget.accountName,
    allowAutoRename: () => _uploadAutoRename,
    onChanged: () => _refreshState(() {}),
    onUploaded: widget.onUploaded,
    formatError: _friendlyError,
  );

  @override
  void initState() {
    super.initState();
    _uploadService = _newUploadService();
    _path = widget.initialPath;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _loadFiles();
    if (mounted && widget.uploadOnly && _canWrite && _error == null) {
      await _pickUploads(type: widget.initialUploadType);
    }
  }

  @override
  void didUpdateWidget(covariant FilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.isAdmin != widget.isAdmin ||
        oldWidget.accountName != widget.accountName) {
      _cancelUploads();
      _uploadService = _newUploadService();
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
      final root = await widget.api.get('/api/v2/files/root');
      final query = <String, String>{
        'path': directory,
        'limit': '$_pageSize',
        'cursor': more ? _nextCursor : '',
        'sort': _fileSort,
        'dir': _fileSortDirection,
      };
      final response = await widget.api.get('/api/v2/files', query: query);
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
        '/api/v2/files/search',
        query: {
          'path': widget.initialPath,
          'query': term,
          'limit': '$_pageSize',
        },
      );
      if (generation != _loadGeneration || !mounted) return;
      _refreshState(() {
        _path = widget.initialPath;
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
      final response = await widget.api.get('/api/v2/files/trash');
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
        '/api/v2/files/folders',
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
    final selection = await showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: widget.api,
        sourceName: item.name,
        sourcePath: item.path,
        action: action,
      ),
    );
    if (selection == null || !mounted) return;
    if (item.isFolder && selection.path.startsWith('${item.path}/')) {
      _refreshState(() => _error = '不能将文件夹移动或复制到自己的子目录中。');
      return;
    }
    _refreshState(() => _error = null);
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v2/files/operations',
        body: <String, Object>{
          'action': action,
          'from': item.path,
          'to': selection.path,
          'conflict': selection.conflict,
        },
      );
      if (!mounted) return;
      await _refreshCurrentView();
      if (!mounted) return;
      final message = result['skipped'] == true
          ? '目标已存在，已安全跳过'
          : '操作完成：${result['finalTo']?.toString() ?? selection.path}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      _refreshState(() => _error = '文件操作失败：${_friendlyError(error)}');
    }
  }

  Future<void> _rename(FileEntry item) async {
    if (!_canWriteItem(item)) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameFileDialog(initialName: item.name),
    );
    if (!mounted || name == null || name == item.name) return;
    final slash = item.path.lastIndexOf('/');
    final destination = slash < 0
        ? name
        : '${item.path.substring(0, slash)}/$name';
    try {
      await widget.api.send(
        'POST',
        '/api/v2/files/operations',
        body: {
          'action': 'move',
          'from': item.path,
          'to': destination,
          'conflict': '',
        },
      );
      if (mounted) await _refreshCurrentView();
    } catch (error) {
      _refreshState(() => _error = '重命名失败：${_friendlyError(error)}');
    }
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
        '/api/v2/files',
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
        '/api/v2/files/trash/${Uri.encodeComponent(item.id)}/restore',
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
        '/api/v2/files/trash/${Uri.encodeComponent(item.id)}',
      );
      await _loadTrash();
    } catch (error) {
      _refreshState(() => _error = '永久删除失败：${_friendlyError(error)}');
    }
  }

  Future<void> _batchTransfer(String action) async {
    if (_batchBusy || _loading || _selectedPaths.isEmpty) return;
    final byPath = {for (final item in _entries) item.path: item};
    final paths = _selectedPaths.toList(growable: false);
    if (paths.length > 50 ||
        paths.any((p) => byPath[p] == null || !_canWriteItem(byPath[p]!))) {
      _refreshState(() => _error = '选择已变更或包含只读项目，请刷新目录再试。');
      return;
    }
    final destination = await showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: widget.api,
        sourceName: '',
        sourcePath: '',
        action: action,
        directoryOnly: true,
      ),
    );
    if (destination == null || !mounted) return;
    final rootIdentity = widget.api.selectedRoot?.identity;
    final valid = <FileEntry>[];
    final invalid = <String>[];
    for (final path in paths) {
      final item = byPath[path]!;
      final target = destination.path == '.'
          ? item.name
          : '${destination.path}/${item.name}';
      if ((action == 'move' && target == path) ||
          (item.isFolder && (target == path || target.startsWith('$path/')))) {
        invalid.add(path);
      } else {
        valid.add(item);
      }
    }
    if (invalid.isNotEmpty) {
      _refreshState(
        () => _error = '有 ${invalid.length} 个项目的目标为原位置或自身子目录，请重新选择其他目录。',
      );
      return;
    }
    final confirmed = await confirmAction(
      context,
      action == 'move' ? '批量移动文件' : '批量复制文件',
      '将 ${valid.length} 项${action == 'move' ? '移动' : '复制'}到'
      '“${destination.path == '.' ? '根目录' : destination.path}”？'
      '同名文件自动改名，原目标文件不会覆盖。'
      '中途失败时已完成的项目会保留，剩余项目可重试。',
      action: action == 'move' ? '开始移动' : '开始复制',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _batchBusy = true;
      _error = null;
    });
    final failures = <String>[];
    var completed = 0;
    try {
      for (var i = 0; i < valid.length; i++) {
        final item = valid[i];
        if (!mounted || widget.api.selectedRoot?.identity != rootIdentity) {
          failures.addAll(valid.skip(i).map((e) => e.path));
          break;
        }
        final target = destination.path == '.'
            ? item.name
            : '${destination.path}/${item.name}';
        try {
          await widget.api.send(
            'POST',
            '/api/v2/files/operations',
            body: {
              'action': action,
              'from': item.path,
              'to': target,
              'conflict': 'rename',
            },
          );
          completed++;
        } catch (_) {
          failures.add(item.path);
        }
      }
      if (mounted) {
        await _refreshCurrentView();
        if (mounted) {
          setState(() {
            _selectedPaths
              ..clear()
              ..addAll(failures);
            _error = failures.isEmpty
                ? null
                : '已完成 $completed 项，${failures.length} 项未完成；失败项目仍保留选择，可检查权限后重试。';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '批量${action == 'move' ? '移动' : '复制'}已完成 $completed/${valid.length} 项。',
              ),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _batchBusy = false);
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
        '/api/v2/files/batch',
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

  Future<void> _openExternal(FileEntry item) async {
    if (_downloading.contains(item.path)) return;
    _refreshState(() {
      _downloading.add(item.path);
      _downloadProgress[item.path] = 0;
      _downloadMessage = null;
    });
    try {
      final message = await ExternalFileOpener.open(
        api: widget.api,
        path: item.path,
        name: item.name,
        size: item.size,
        onProgress: (value) =>
            _refreshState(() => _downloadProgress[item.path] = value),
      );
      _refreshState(() => _downloadMessage = message);
    } catch (error) {
      _refreshState(
        () => _downloadMessage =
            '无法通过其他应用打开：\${_friendlyError(error)}。可以改用“下载”保存原文件。',
      );
    } finally {
      _refreshState(() {
        _downloading.remove(item.path);
        _downloadProgress.remove(item.path);
      });
    }
  }

  Future<void> _preview(FileEntry item) async {
    final kind = classifyFilePreview(item.name);
    if (kind == FilePreviewKind.image || kind == FilePreviewKind.video) {
      // Files and Photos always use the same viewer and media controls.
      // A static snapshot of this directory is the file-browser playlist.
      final entries = <FileEntry>[
        for (final file in _entries)
          if (!file.isFolder &&
              (classifyFilePreview(file.name) == FilePreviewKind.image ||
                  classifyFilePreview(file.name) == FilePreviewKind.video))
            file,
      ];
      if (!entries.any((entry) => entry.path == item.path)) {
        entries.insert(0, item);
      }
      final assets = <PhotoAsset>[
        for (var i = 0; i < entries.length; i++)
          PhotoAsset(
            id: i + 1,
            path: entries[i].path,
            name: entries[i].name,
            type: classifyFilePreview(entries[i].name) == FilePreviewKind.video
                ? 'video'
                : 'photo',
            size: entries[i].size,
            takenAt: (entries[i].modified?.millisecondsSinceEpoch ?? 0) ~/ 1000,
            favorite: false,
            canWrite: entries[i].canWrite,
          ),
      ];
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PhotoGalleryViewer(
            api: widget.api,
            assets: assets,
            initialIndex: assets.indexWhere((asset) => asset.path == item.path),
            fileBrowserMode: true,
            canEditSharedFavorite: (_) => false,
            onSharedFavorite: (asset) async => asset,
            onPersonalFavorite: (asset) async => asset,
            onDetails: (_) async {},
            onLoadMore: () async => assets,
          ),
        ),
      );
      return;
    }
    if (kind == FilePreviewKind.pdf) {
      await showDialog<void>(
        context: context,
        builder: (_) => FilePdfPreviewDialog(
          api: widget.api,
          item: item,
          onOpenExternal: () => _openExternal(item),
          onDownload: () => _download(item),
        ),
      );
      return;
    }
    if (kind == FilePreviewKind.external) {
      _refreshState(() => _error = '该文件暂不支持在线预览，请通过右侧更多菜单保存文件或使用其他应用打开。');
      return;
    }
    String? decodedText;
    String? failure;
    try {
      final data = await widget.api.bytes(
        '/api/v2/files/preview',
        query: {'path': item.path},
        maxBytes: _maxTextPreviewSize,
      );
      decodedText = decodePreviewText(data);
    } catch (error) {
      failure = error is FormatException
          ? '无法识别文本编码，原文件未更改。可尝试其他编辑器。'
          : _friendlyError(error);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (context) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 820),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(
                    alpha: isDark ? 0.88 : 0.94,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.16)
                        : theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.45,
                          ),
                    width: 0.85,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.45 : 0.15,
                      ),
                      blurRadius: 36,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
                      child: Row(
                        children: [
                          _buildFileBadge(item),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${formatBytes(item.size)} · QuickLook 快速查看',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '其他应用打开',
                            onPressed: () {
                              Navigator.pop(context);
                              _openExternal(item);
                            },
                            icon: const Icon(Icons.open_in_new_rounded),
                          ),
                          IconButton(
                            tooltip: '下载文件',
                            onPressed: () {
                              Navigator.pop(context);
                              _download(item);
                            },
                            icon: const Icon(Icons.download_rounded),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.35,
                            ),
                    ),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: failure != null
                            ? Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text('无法预览：$failure'),
                              )
                            : Container(
                                constraints: const BoxConstraints(
                                  maxHeight: 520,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.black.withValues(alpha: 0.45)
                                      : theme
                                            .colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.08)
                                        : theme.colorScheme.outlineVariant
                                              .withValues(alpha: 0.3),
                                  ),
                                ),
                                padding: const EdgeInsets.all(16),
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    decodedText!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontFamily: 'monospace',
                                      height: 1.55,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _shareFile(FileEntry item) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FileShareDialog(
        api: widget.api,
        path: item.path,
        name: item.name,
        isFolder: item.isFolder,
      ),
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
        item.isFolder ? '/api/v2/files/archive' : '/api/v2/files/content',
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
        final exportResult = await fileExportChannel.invokeMethod<String>(
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

  Future<void> _chooseUploadSource() async {
    if (!_canWrite || _uploadBusy) return;
    final type = await showModalBottomSheet<FileType>(
      context: context,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                '上传到当前文件夹',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('照片与视频'),
              subtitle: const Text('从系统相册选择'),
              onTap: () => Navigator.pop(context, FileType.media),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('文件'),
              subtitle: const Text('从设备或其他应用选择'),
              onTap: () => Navigator.pop(context, FileType.any),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (!mounted || type == null) return;
    await openFileUpload(
      context,
      api: widget.api,
      isAdmin: widget.isAdmin,
      directory: _path,
      type: type,
      title: type == FileType.media ? '上传照片与视频' : '上传文件',
    );
    if (mounted) await _loadFiles();
  }

  Future<void> _pickUploads({FileType type = FileType.any}) async {
    if (!_canWrite || _uploadBusy) return;
    _refreshState(() => _uploadBusy = true);
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: '选择要上传的文件',
        type: type,
        darwinOptions: const DarwinOptions(
          // Prefer current/original representations; never request compression.
          assetRepresentationMode: DarwinAssetRepresentationMode.current,
        ),
      );
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
    final jobs = <FileUploadJob>[];
    for (final file in files) {
      final issue = validateFileName(file.name);
      if (issue != null) {
        _refreshState(() => _error = '“${file.name}”无法上传：$issue');
        continue;
      }
      jobs.add(
        FileUploadJob(
          file: file,
          destination: _joinRelative(destinationDirectory, file.name),
          rootIdentity: widget.api.selectedRoot?.identity,
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

  Future<void> _runUpload(FileUploadJob job) => _uploadService.run(job);

  void _togglePause(FileUploadJob job) {
    job.togglePause();
    _refreshState(() {});
  }

  void _cancelUpload(FileUploadJob job) {
    job.requestCancel();
    _refreshState(() {});
  }

  Future<void> _discardUpload(FileUploadJob job) async {
    job.requestCancel();
    await _uploadService.abort(job);
    job.status = FileUploadStatus.cancelled;
    _refreshState(() {});
  }

  void _cancelUploads() {
    for (final job in _uploadJobs) {
      if (job.status == FileUploadStatus.uploading ||
          job.status == FileUploadStatus.paused ||
          job.status == FileUploadStatus.checking) {
        job.requestCancel();
      }
    }
  }

  Future<void> _retryUpload(FileUploadJob job) async {
    if (_uploadBusy) return;
    _refreshState(() {
      _uploadBusy = true;
      job.prepareRetry();
    });
    await _runUpload(job);
    _refreshState(() => _uploadBusy = false);
  }

  Future<void> _copyPathToClipboard(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('下载路径已复制。')));
  }

  bool _canWriteItem(FileEntry item) => item.canWrite || widget.isAdmin;

  bool get _hasActiveUploads => _uploadJobs.any(
    (job) =>
        job.status == FileUploadStatus.checking ||
        job.status == FileUploadStatus.uploading ||
        job.status == FileUploadStatus.paused,
  );

  Widget _uploadView(BuildContext context) => PopScope(
    canPop: !_hasActiveUploads,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      if (!_hasActiveUploads) {
        Navigator.of(context).pop();
        return;
      }
      final leave = await confirmAction(
        context,
        '结束本次上传？',
        '未完成的上传将取消，设备上的原文件会保留。',
        action: '结束上传',
      );
      if (!leave || !mounted) return;
      _cancelUploads();
      setState(() => _uploadBusy = false);
      if (context.mounted) Navigator.of(context).pop();
    },
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        IsleSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('保存位置', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Text(
                '${widget.api.selectedRoot?.name ?? _rootName} / ${_path == '.' ? '共享目录' : _path}',
              ),
              const SizedBox(height: 12),
              const Text('支持多选。保持此页面打开，可暂停、继续或重试。'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loading || _uploadBusy || !_canWrite
                    ? null
                    : () => _pickUploads(type: widget.initialUploadType),
                icon: const Icon(Icons.add_rounded),
                label: Text(_uploadJobs.isEmpty ? '选择要上传的内容' : '继续添加'),
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('同名自动改名'),
                subtitle: const Text('保留原文件和新文件'),
                value: _uploadAutoRename,
                onChanged: _uploadBusy
                    ? null
                    : (value) => setState(() => _uploadAutoRename = value),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Notice(_error!, error: true, onRetry: _loadFiles),
        if (!_loading && !_canWrite && _error == null)
          const Notice('此位置没有上传权限，请联系管理员开放写入权限。'),
        if (_uploadJobs.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildUploads(context),
        ],
        const SizedBox(height: 24),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.uploadOnly) return _uploadView(context);
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop:
          _path == widget.initialPath &&
          !_showingTrash &&
          !_searching &&
          !_selecting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _loading) return;
        if (_selecting) {
          _refreshState(() {
            _selecting = false;
            _selectedPaths.clear();
          });
        } else if (_showingTrash) {
          _toggleTrash();
        } else if (_searching) {
          _loadFiles(target: widget.initialPath);
        } else {
          final segments = _pathSegments();
          if (segments.length > 1) {
            _loadFiles(target: segments[segments.length - 2].$2);
          }
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 700;
          return ListView(
            padding: EdgeInsets.all(compact ? 16 : 24),
            children: [
              _buildHeader(context),
              const SizedBox(height: 14),
              _buildToolbar(
                context,
                compact,
                constraints.maxWidth - (compact ? 32 : 48),
              ),
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
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IslePageHeader(
          title: '文件',
          subtitle: '浏览共享目录、管理文件并查看回收站。',
          icon: Icons.folder_open_rounded,
          trailing: IconButton(
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
            ? Container(
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: label,
              )
            : TextButton(
                onPressed: _loading || _showingTrash
                    ? null
                    : () => _loadFiles(target: segment.$2),
                style: TextButton.styleFrom(
                  minimumSize: const Size(36, 36),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: label,
              ),
      ),
    );
  }

  Future<void> _openDownloads() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DownloadsPage(api: widget.api, initialDestination: _path),
      ),
    );
    if (mounted) await _loadFiles();
  }

  Widget _buildToolbar(
    BuildContext context,
    bool compact,
    double availableWidth,
  ) {
    final iconActions = IsleLayout.compactToolbar(
      availableWidth,
      MediaQuery.textScalerOf(context).scale(14) / 14,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_showingTrash)
          TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _searchFiles(),
            decoration: InputDecoration(
              isDense: true,
              hintText: iconActions ? '搜索文件名' : '搜索文件名（至少 2 个字符）',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              suffixIcon: IconButton(
                tooltip: _searching ? '清除搜索' : '搜索',
                onPressed: _loading
                    ? null
                    : () {
                        if (_searching) {
                          _searchController.clear();
                          _loadFiles(target: widget.initialPath);
                        } else {
                          _searchFiles();
                        }
                      },
                icon: Icon(
                  _searching
                      ? Icons.close_rounded
                      : Icons.arrow_forward_rounded,
                  size: 20,
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (_showingTrash)
              TextButton.icon(
                onPressed: _toggleTrash,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('返回文件'),
              )
            else if (_canWrite && iconActions)
              IconButton.filled(
                tooltip: '上传文件',
                onPressed: _loading || _uploadBusy ? null : _chooseUploadSource,
                icon: const Icon(Icons.add_rounded),
              )
            else if (_canWrite)
              FilledButton.icon(
                onPressed: _loading || _uploadBusy ? null : _chooseUploadSource,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('上传文件'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(40, 38),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
              ),
            if (!_showingTrash && _canWrite) ...[
              const SizedBox(width: 6),
              if (compact || iconActions)
                IconButton(
                  tooltip: '新建文件夹',
                  onPressed: _loading ? null : _createFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                )
              else
                OutlinedButton.icon(
                  onPressed: _loading ? null : _createFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('新建文件夹'),
                ),
            ],
            const Spacer(),
            if (!_showingTrash && !_searching)
              PopupMenuButton<String>(
                tooltip: '文件排序方式',
                icon: const Icon(Icons.sort_rounded),
                onSelected: (value) {
                  final values = value.split(':');
                  _refreshState(() {
                    _fileSort = values[0];
                    _fileSortDirection = values[1];
                  });
                  unawaited(_loadFiles());
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'name:asc', child: Text('名称 · 升序')),
                  PopupMenuItem(value: 'name:desc', child: Text('名称 · 降序')),
                  PopupMenuItem(
                    value: 'mtime:desc',
                    child: Text('修改时间 · 最新优先'),
                  ),
                  PopupMenuItem(value: 'mtime:asc', child: Text('修改时间 · 最早优先')),
                  PopupMenuItem(value: 'size:desc', child: Text('文件大小 · 从大到小')),
                  PopupMenuItem(value: 'size:asc', child: Text('文件大小 · 从小到大')),
                ],
              ),
            PopupMenuButton<String>(
              tooltip: '更多文件操作',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (value) {
                switch (value) {
                  case 'folder':
                    _createFolder();
                  case 'select':
                    _refreshState(() {
                      _selecting = !_selecting;
                      _selectedPaths.clear();
                    });
                  case 'downloads':
                    _openDownloads();
                  case 'trash':
                    _toggleTrash();
                  case 'rename':
                    _refreshState(() => _uploadAutoRename = !_uploadAutoRename);
                }
              },
              itemBuilder: (_) => [
                if (!_showingTrash && _canWrite)
                  const PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
                if (!_showingTrash && _canWrite)
                  PopupMenuItem(
                    value: 'select',
                    child: Text(_selecting ? '结束多选' : '选择文件'),
                  ),
                if (!_showingTrash)
                  const PopupMenuItem(value: 'downloads', child: Text('下载中心')),
                if (!_showingTrash)
                  const PopupMenuItem(value: 'trash', child: Text('回收站')),
                if (!_showingTrash && _canWrite)
                  CheckedPopupMenuItem(
                    value: 'rename',
                    checked: _uploadAutoRename,
                    child: const Text('同名自动改名'),
                  ),
              ],
            ),
          ],
        ),
      ],
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
          if (!compact || _showingTrash || _searching)
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
      padding: EdgeInsets.fromLTRB(compact ? 10 : 20, 0, compact ? 10 : 20, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(alpha: .65),
          borderRadius: BorderRadius.circular(IsleTokens.itemRadius),
          border: Border.all(color: colors.primary.withValues(alpha: .28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
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
                  OutlinedButton.icon(
                    onPressed: _loading || _batchBusy || selectedCount == 0
                        ? null
                        : () => _batchTransfer('copy'),
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: const Text('复制到'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading || _batchBusy || selectedCount == 0
                        ? null
                        : () => _batchTransfer('move'),
                    icon: const Icon(Icons.drive_file_move_outline, size: 16),
                    label: const Text('移动到'),
                  ),
                  TextButton.icon(
                    onPressed: _loading || _batchBusy
                        ? null
                        : () => _refreshState(_selectedPaths.clear),
                    icon: const Icon(Icons.clear_all_rounded, size: 16),
                    label: const Text('清除选择'),
                  ),
                  FilledButton.icon(
                    onPressed: _loading || _batchBusy ? null : _batchTrash,
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: const Text('批量移到回收站'),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static final RegExp _thumbnailExtensions = RegExp(
    r'\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$',
    caseSensitive: false,
  );

  bool _thumbnailEligible(String name) => _thumbnailExtensions.hasMatch(name);

  /// Server-rendered 512px JPEG for image/video files; falls back to the
  /// extension badge when the pipeline cannot serve one (unsupported source,
  /// oversized file, FFmpeg-less server for exotic containers).
  Widget _fileThumbnail(FileEntry item) {
    final key = '${item.path}@${item.modified}';
    if (_failedThumbnails.contains(key)) return _buildFileBadgeIcon(item);
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: SizedBox(
        width: 40,
        height: 40,
        child: AuthenticatedMediaImage(
          api: widget.api,
          path: '/api/v2/files/thumbnail',
          query: {'path': item.path, 'size': '512'},
          maxBytes: 4 * 1024 * 1024,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) {
            _failedThumbnails.add(key);
            return _buildFileBadgeIcon(item);
          },
        ),
      ),
    );
  }

  Widget _buildFileBadge(FileEntry item) {
    if (!item.isFolder && _thumbnailEligible(item.name)) {
      return _fileThumbnail(item);
    }
    return _buildFileBadgeIcon(item);
  }

  Widget _buildFileBadgeIcon(FileEntry item) {
    if (item.isFolder) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: const Color(0xff0284c7).withValues(alpha: 0.12),
        ),
        child: const Icon(
          Icons.folder_rounded,
          color: Color(0xff0284c7),
          size: 21,
        ),
      );
    }

    final ext = _extension(item.name);
    final (tint, icon) = switch (ext) {
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'heic' => (const Color(0xfff43f5e), Icons.image_rounded),
      'mp4' ||
      'mov' ||
      'm4v' ||
      'webm' ||
      'mkv' => (const Color(0xff8b5cf6), Icons.movie_rounded),
      'mp3' ||
      'flac' ||
      'wav' ||
      'm4a' ||
      'aac' => (const Color(0xfff59e0b), Icons.music_note_rounded),
      'pdf' => (const Color(0xffef4444), Icons.picture_as_pdf_rounded),
      'zip' ||
      '7z' ||
      'rar' ||
      'tar' ||
      'gz' ||
      'dmg' => (const Color(0xff64748b), Icons.archive_rounded),
      'txt' ||
      'md' ||
      'log' ||
      'json' ||
      'yaml' ||
      'xml' ||
      'ts' ||
      'js' ||
      'swift' ||
      'go' => (const Color(0xff0ea5e9), Icons.description_rounded),
      _ => (const Color(0xff94a3b8), Icons.insert_drive_file_rounded),
    };

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: tint.withValues(alpha: 0.12),
      ),
      child: Icon(icon, color: tint, size: 20),
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
          minTileHeight: 52,
          contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 20,
            vertical: 0,
          ),
          selected: selected,
          selectedTileColor: colors.primaryContainer.withValues(alpha: .42),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (writable && _selecting)
                Semantics(
                  label: '选择 ${item.name} 移入回收站',
                  child: Checkbox(
                    value: selected,
                    onChanged: (value) {
                      HapticFeedback.selectionClick();
                      _toggleSelected(item, value);
                    },
                  ),
                ),
              const SizedBox(width: 4),
              _buildFileBadge(item),
            ],
          ),
          title: Text(
            item.name,
            softWrap: true,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
          ),
          subtitle: Text(
            '${item.isFolder ? '文件夹' : formatBytes(item.size)} · $modified',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          onLongPress: writable
              ? () => _refreshState(() {
                  _selecting = true;
                  _toggleSelected(item, !selected);
                })
              : null,
          onTap: _loading
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  if (_selecting && writable) {
                    _toggleSelected(item, !selected);
                    return;
                  }
                  if (item.isFolder) {
                    _loadFiles(target: item.path);
                  } else {
                    _preview(item);
                  }
                },
          trailing: PopupMenuButton<String>(
            tooltip: '文件操作',
            onSelected: (value) {
              switch (value) {
                case 'preview':
                  _preview(item);
                case 'download':
                  _download(item);
                case 'openExternal':
                  _openExternal(item);
                case 'share':
                  _shareFile(item);
                case 'copy':
                  _operate(item, 'copy');
                case 'move':
                  _operate(item, 'move');
                case 'rename':
                  _rename(item);
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
              if (!item.isFolder)
                const PopupMenuItem(
                  value: 'openExternal',
                  child: ListTile(
                    leading: Icon(Icons.open_in_new_rounded),
                    title: Text('其他应用打开'),
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
              if (item.isFolder)
                const PopupMenuItem(
                  value: 'share',
                  child: ListTile(
                    leading: Icon(Icons.ios_share_outlined),
                    title: Text('分享文件夹 ZIP'),
                  ),
                ),
              if (writable)
                const PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    leading: Icon(Icons.drive_file_rename_outline),
                    title: Text('重命名'),
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

  Widget _uploadTile(BuildContext context, FileUploadJob job) {
    final size = job.file.lengthSync() ?? 0;
    final progress = size > 0
        ? (job.offset / size).clamp(0, 1).toDouble()
        : 0.0;
    final label = switch (job.status) {
      FileUploadStatus.checking =>
        '正在计算 SHA-256 ${size == 0 ? '' : '${(job.hashingBytes / size * 100).clamp(0, 100).round()}%'}',
      FileUploadStatus.uploading =>
        '上传中 ${formatBytes(job.offset)} / ${formatBytes(size)}',
      FileUploadStatus.paused =>
        '已暂停 ${formatBytes(job.offset)} / ${formatBytes(size)}',
      FileUploadStatus.failed => job.error ?? '上传失败',
      FileUploadStatus.complete => '上传完成 · ${formatBytes(size)}',
      FileUploadStatus.cancelled => '已取消',
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
                      '$label · ${job.actualDestination}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (job.status == FileUploadStatus.uploading ||
                  job.status == FileUploadStatus.paused)
                IconButton(
                  tooltip: job.status == FileUploadStatus.paused
                      ? '继续上传'
                      : '暂停上传',
                  onPressed: () => _togglePause(job),
                  icon: Icon(
                    job.status == FileUploadStatus.paused
                        ? Icons.play_arrow
                        : Icons.pause,
                  ),
                ),
              if (job.status == FileUploadStatus.uploading ||
                  job.status == FileUploadStatus.paused ||
                  job.status == FileUploadStatus.checking)
                IconButton(
                  tooltip: '取消上传',
                  onPressed: () => _cancelUpload(job),
                  icon: const Icon(Icons.close),
                ),
              if (job.status == FileUploadStatus.failed)
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
              if (job.status == FileUploadStatus.complete ||
                  job.status == FileUploadStatus.cancelled)
                IconButton(
                  tooltip: '移除任务',
                  onPressed: () => _refreshState(() => _uploadJobs.remove(job)),
                  icon: const Icon(Icons.clear),
                ),
            ],
          ),
          if (job.status == FileUploadStatus.uploading ||
              job.status == FileUploadStatus.paused)
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
    if (widget.initialPath != '.' &&
        (_path == widget.initialPath ||
            _path.startsWith('${widget.initialPath}/'))) {
      final label = widget.initialPath.endsWith('/photos')
          ? '我的照片'
          : widget.initialPath.endsWith('/videos')
          ? '我的视频'
          : '我的文件';
      final result = <(String, String)>[(label, widget.initialPath)];
      if (_path == widget.initialPath) return result;
      final relative = _path
          .substring(widget.initialPath.length + 1)
          .split('/');
      for (var i = 0; i < relative.length; i++) {
        result.add((
          relative[i],
          '${widget.initialPath}/${relative.take(i + 1).join('/')}',
        ));
      }
      return result;
    }
    final result = <(String, String)>[(_rootName, '.')];
    if (_path == '.' || _path.isEmpty) return result;
    final names = _path.split('/');
    for (var i = 0; i < names.length; i++) {
      result.add((names[i], names.take(i + 1).join('/')));
    }
    return result;
  }
}

class _RenameFileDialog extends StatefulWidget {
  const _RenameFileDialog({required this.initialName});
  final String initialName;
  @override
  State<_RenameFileDialog> createState() => _RenameFileDialogState();
}

class _RenameFileDialogState extends State<_RenameFileDialog> {
  late final _controller = TextEditingController(text: widget.initialName);
  String? _issue;
  void _save() {
    final name = _controller.text.trim();
    setState(() => _issue = validateFileName(name));
    if (_issue == null) Navigator.pop(context, name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 150,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _save(),
      decoration: InputDecoration(labelText: '名称', errorText: _issue),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
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

List<Map<String, dynamic>> _mapList(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList()
    : <Map<String, dynamic>>[];

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String _joinRelative(String directory, String name) =>
    directory == '.' || directory.isEmpty ? name : '$directory/$name';

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
    'insufficient_storage_space': '目标硬盘剩余空间不足，上传进度已保留。请清理空间后续传。',
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
    '507' => '目标硬盘剩余空间不足，请清理空间后重新尝试续传。',
    '503' => '共享存储或服务暂时不可用。',
    _ => userFacingError(error),
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
