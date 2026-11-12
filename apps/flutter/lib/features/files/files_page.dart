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
import 'duplicate_files_page.dart';
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
import 'files_page_state_models.dart';
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

  late final FilesDirectoryState _dir;
  final FilesSearchAndTrashState _filter = FilesSearchAndTrashState();
  final FilesDisplayPrefsState _prefsState = FilesDisplayPrefsState();
  final FilesSelectionAndTransferState _transfers =
      FilesSelectionAndTransferState();
  bool _disposed = false;
  late FileUploadService _uploadService;

  FileBrowserRepository get _browserRepository =>
      FileBrowserRepository(widget.api);
  FileBatchOperations get _batchOperations => FileBatchOperations(widget.api);

  FileUploadService _newUploadService() => FileUploadService(
    api: widget.api,
    accountName: widget.accountName,
    allowAutoRename: () => _prefsState.uploadAutoRename,
    onChanged: () => _refreshState(() {}),
    onUploaded: widget.onUploaded,
    formatError: _friendlyError,
  );

  @override
  void initState() {
    super.initState();
    _dir = FilesDirectoryState(
      path: widget.initialPath,
      rootIdentity: widget.api.selectedRoot?.identity ?? 'default',
    );
    _uploadService = _newUploadService();
    widget.taskCenter?.addListener(_onTaskCenterChange);
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
        _dir.rootIdentity != newRootIdentity) {
      _prefsState.preferencesGeneration++;
      _cancelUploads();
      _uploadService = _newUploadService();
      _dir.resetForIdentity(widget.initialPath, newRootIdentity);
      _filter.reset();
      _transfers.resetForRootChange();
      _prefsState.resetDefaults();
      unawaited(_initialize());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _prefsState.preferencesGeneration++;
    _filter.dispose();
    widget.taskCenter?.removeListener(_onTaskCenterChange);
    if (widget.taskCenter == null) _cancelUploads();
    super.dispose();
  }

  void _refreshState(VoidCallback action) {
    if (mounted && !_disposed) setState(action);
  }

  void _handlePopInvoked(bool didPop, Object? result) {
    if (didPop || _dir.loading) return;
    if (_transfers.selecting) {
      _refreshState(_transfers.clearSelection);
    } else if (_filter.showingTrash) {
      _toggleTrash();
    } else if (_filter.searching) {
      _loadFiles(target: _filter.preSearchPath ?? widget.initialPath);
    } else {
      final segments = _pathSegments();
      if (segments.length > 1) {
        _loadFiles(target: segments[segments.length - 2].$2);
      }
    }
  }

  Widget _buildReadOnlyBanner(ColorScheme colors, {required bool compact}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.lock_outline,
                size: 16,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  compact
                      ? '当前目录为只读 · 可浏览、下载或复制。'
                      : '当前目录为只读。你可以浏览、预览、下载或复制到有写权限的目录。',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBatchProgressBanner(ColorScheme colors) {
    final progress = _transfers.batchProgress!;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '正在批量${_transfers.batchActionLabel ?? '处理'} (${progress.index}/${progress.total}) · ${progress.currentName}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _transfers.batchStopRequested
                        ? null
                        : () => _refreshState(
                            () => _transfers.batchStopRequested = true,
                          ),
                    child: Text(
                      _transfers.batchStopRequested ? '正在停止…' : '停止后续项',
                    ),
                  ),
                ],
              ),
              LinearProgressIndicator(
                value: progress.total > 0
                    ? (progress.index / progress.total).clamp(0.0, 1.0)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.uploadOnly) return _uploadView(context);
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop:
          _dir.path == widget.initialPath &&
          !_filter.showingTrash &&
          !_filter.searching &&
          !_transfers.selecting,
      onPopInvokedWithResult: _handlePopInvoked,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < IsleLayout.compactPageWidth;
          final inset = IsleLayout.pageInset(constraints.maxWidth);
          final topInset = IsleLayout.pageTopInset(constraints.maxWidth);
          return RefreshIndicator(
            onRefresh: _refreshCurrentView,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(inset, topInset, inset, inset + 56),
              children: [
                _buildHeader(context),
                const SizedBox(height: 6),
                _buildToolbar(
                  context,
                  compact,
                  constraints.maxWidth - inset * 2,
                ),
                if (_filter.searching) ...[
                  const SizedBox(height: 6),
                  Text(
                    '共享目录搜索“${_filter.searchTerm}” · 仅搜索当前账号可访问的名称。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (!_filter.showingTrash &&
                    !_dir.canWrite &&
                    !_dir.loading &&
                    _dir.error == null)
                  _buildReadOnlyBanner(colors, compact: compact),
                if (_transfers.batchBusy && _transfers.batchProgress != null)
                  _buildBatchProgressBanner(colors),
                if (_dir.error != null)
                  Notice(
                    _dir.error!,
                    error: true,
                    diagnostic: _dir.error!.startsWith('读取目录失败：')
                        ? _dir.directoryDiagnostic
                        : null,
                    retryLabel: _transfers.lastFailedBatchRetry != null
                        ? '仅重试失败项'
                        : '重试',
                    onRetry: _transfers.lastFailedBatchRetry != null
                        ? _retryFailedBatchTransfer
                        : _filter.showingTrash
                        ? _loadTrash
                        : _filter.searching
                        ? _searchFiles
                        : () => _loadFiles(),
                  ),
                if (_transfers.downloadMessage != null) _downloadNotice(context),
                if ((widget.taskCenter?.jobs ?? _transfers.uploadJobs)
                    .isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildUploads(context),
                ],
                const SizedBox(height: 8),
                _buildFileList(context, compact),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RenameFileDialog extends StatefulWidget {
  const _RenameFileDialog({required this.initialName, this.isFolder = false});
  final String initialName;
  final bool isFolder;
  @override
  State<_RenameFileDialog> createState() => _RenameFileDialogState();
}

class _RenameFileDialogState extends State<_RenameFileDialog> {
  late final _controller = TextEditingController(text: widget.initialName);
  String? _issue;

  @override
  void initState() {
    super.initState();
    final name = widget.initialName;
    final dot = widget.isFolder ? -1 : name.lastIndexOf('.');
    final end = dot > 0 ? dot : name.length;
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: end);
  }

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

String _friendlyError(Object error) => userFacingError(error);

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
