import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/isle_action_menu.dart';
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
import 'file_browser_preferences.dart';
import 'file_selection_toolbar.dart';
import 'file_selection_snapshot.dart';
import 'file_browser_repository.dart';
import 'file_batch_operations.dart';
import 'file_media_playlist.dart';
import 'file_text_preview_dialog.dart';
import 'file_upload_queue_view.dart';
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
import 'file_upload_service.dart';
import 'upload_task_center.dart';
import 'upload_task_center_page.dart';

part 'files_page_preferences.dart';
part 'files_page_browser.dart';
part 'files_page_selection.dart';
part 'files_page_file_actions.dart';
part 'files_page_uploads.dart';
part 'files_page_shell_widgets.dart';
part 'files_page_file_widgets.dart';

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
      appBar: IsleAppBar(title: Text(title)),
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
  UploadTaskCenter? taskCenter,
  String accountName = '',
}) async {
  var completed = 0;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: IsleAppBar(title: Text(title)),
        body: SafeArea(
          top: false,
          child: FilesPage(
            api: api,
            isAdmin: isAdmin,
            initialPath: directory,
            uploadOnly: true,
            initialUploadType: type,
            onUploaded: () => completed++,
            taskCenter: taskCenter,
            accountName: accountName,
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
    this.taskCenter,
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
  final UploadTaskCenter? taskCenter;

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
  void _updateState(VoidCallback action) => setState(action);

  final TextEditingController _searchController = TextEditingController();
  late String _path;
  late String _rootIdentity;
  String _rootName = '共享文件';
  List<FileEntry> _entries = [];
  final Set<String> _failedThumbnails = <String>{};
  final Set<String> _selectedPaths = <String>{};
  String _nextCursor = '';
  String _fileSort = 'name';
  String _fileSortDirection = 'asc';
  String _fileView = 'list';
  bool _uploadAutoRename = false;
  int _preferencesGeneration = 0;
  Future<void> _preferenceWrites = Future<void>.value();
  bool _canWrite = false;
  bool _loading = false;
  bool _showingTrash = false;
  bool _searching = false;
  bool _searchTruncated = false;
  bool _trashLoading = false;
  String _searchTerm = '';
  String? _error;
  String? _directoryDiagnostic;
  List<TrashEntry> _trashEntries = [];
  int _loadGeneration = 0;
  bool _uploadBusy = false;
  final List<FileUploadJob> _uploadJobs = [];
  final Set<FileUploadJob> _observedCompletedUploads = {};
  final Map<String, double> _downloadProgress = {};
  final Set<String> _downloading = {};
  String? _downloadMessage;
  bool _disposed = false;
  bool _selecting = false;
  bool _batchBusy = false;

  late FileUploadService _uploadService;
  FileBrowserRepository get _browserRepository =>
      FileBrowserRepository(widget.api);
  FileBatchOperations get _batchOperations => FileBatchOperations(widget.api);

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
    widget.taskCenter?.addListener(_onTaskCenterChange);
    _path = widget.initialPath;
    _rootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant FilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.taskCenter, widget.taskCenter)) {
      oldWidget.taskCenter?.removeListener(_onTaskCenterChange);
      widget.taskCenter?.addListener(_onTaskCenterChange);
    }
    final newRootIdentity = widget.api.selectedRoot?.identity ?? 'default';
    if (oldWidget.api != widget.api ||
        oldWidget.isAdmin != widget.isAdmin ||
        oldWidget.accountName != widget.accountName ||
        oldWidget.initialPath != widget.initialPath ||
        _rootIdentity != newRootIdentity) {
      // Invalidate outstanding requests before awaiting local preferences.
      // Never render the prior account/root's files under a new identity.
      _loadGeneration++;
      _preferencesGeneration++;
      _rootIdentity = newRootIdentity;
      _cancelUploads();
      _uploadService = _newUploadService();
      // didUpdateWidget is followed by build, so direct state reset is safe.
      {
        _path = widget.initialPath;
        _rootName = '共享文件';
        _entries = [];
        _selectedPaths.clear();
        _failedThumbnails.clear();
        _selecting = false;
        _showingTrash = false;
        _searching = false;
        _searchController.clear();
        _canWrite = false;
        _nextCursor = '';
        _error = null;
        _directoryDiagnostic = null;
        _loading = true;
        _fileView = 'list';
        _fileSort = 'name';
        _fileSortDirection = 'asc';
        _uploadAutoRename = false;
      }
      unawaited(_initialize());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _preferencesGeneration++;
    _searchController.dispose();
    widget.taskCenter?.removeListener(_onTaskCenterChange);
    if (widget.taskCenter == null) _cancelUploads();
    super.dispose();
  }

  void _refreshState(VoidCallback action) {
    if (mounted && !_disposed) setState(action);
  }

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
          final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
          return ListView(
            padding: EdgeInsets.all(IsleLayout.pageInset(constraints.maxWidth)),
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
              // A failed directory read is not evidence of read-only
              // permissions. Do not show the contradictory blue notice
              // alongside the real error.
              if (!_showingTrash && !_canWrite && !_loading && _error == null)
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
                  diagnostic: _error!.startsWith('读取目录失败：')
                      ? _directoryDiagnostic
                      : null,
                  onRetry: _showingTrash
                      ? _loadTrash
                      : _searching
                      ? _searchFiles
                      : () => _loadFiles(),
                ),
              if (_downloadMessage != null) _downloadNotice(context),
              if ((widget.taskCenter?.jobs ?? _uploadJobs).isNotEmpty) ...[
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
    if (error.code == 'archive_busy') {
      return '当前打包下载较多，请稍后重试。';
    }
    if (error.code == 'archive_source_changed') {
      return '文件夹内容在下载前发生变化，请刷新目录后重试。';
    }
  }
  return _friendlyError(error);
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String _joinRelative(String directory, String name) =>
    directory == '.' || directory.isEmpty ? name : '$directory/$name';

String _friendlyError(Object error) {
  // LightIsleApiException.toString deliberately contains only the user
  // message. Inspect its structured code first or every non-HTTP-specific
  // file operation loses the precise Core failure category.
  final value = error is LightIsleApiException
      ? error.code
      : error.toString().replaceFirst(RegExp(r'^(Exception|Error):\s*'), '');
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
    'shared_volume_offline': '共享磁盘离线，请在 Mac「数据与存储」检查原硬盘并确认重新连接。',
    'offset_mismatch': '服务端上传进度已变化，正在重新读取进度。',
    'upload_state_corrupt': '服务器无法恢复这次上传，请取消并重新上传。',
    'storage_durability_failure': '存储未能确认写入，请刷新确认文件状态后重试。',
    'upload_outcome_uncertain': '服务器无法确认文件是否已完整发布，请先刷新目录确认。',
  };
  if (translations.containsKey(value)) return translations[value]!;
  // Code-based translations must win even if the response was HTTP 503.
  // A diagnostic code is more specific than the transport status.
  if (error is LightIsleApiException) return userFacingError(error);
  final status = RegExp(r'^HTTP\s+(\d{3})$').firstMatch(value)?.group(1);
  return switch (status) {
    '401' => '登录状态已失效，请重新登录。',
    '403' => '当前账号没有权限执行此操作。',
    '404' => '文件或服务端任务已不存在。',
    '409' => '目标已变化或已存在，请刷新后重试。',
    '413' => '文件超过服务端允许的大小。',
    '507' => '目标硬盘剩余空间不足，请清理空间后重新尝试续传。',
    '503' => '服务器返回 HTTP 503，但未说明具体原因。请核对 Mac 服务日志。',
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
