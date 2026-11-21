import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'files_browser_view.dart';
import 'files_controller.dart';
import 'files_item_cards.dart';
import 'files_shell_widgets.dart';
import 'files_status_and_upload_views.dart';
import 'files_ui_actions.dart';
import 'upload_task_center.dart';

export 'file_export_service.dart'
    show exportOfflineMediaFile, exportMediaFile, exportMediaFiles;
export 'file_models.dart' show FileEntry, TrashEntry;
export 'file_name_validation.dart' show validateFileName;
export 'file_name_validation.dart' show validateRelativePath;
export 'file_share_dialog.dart' show openMediaFileShare;

Future<void> openFileManager(
  BuildContext context, {
  required LightIsleApi api,
  required bool isAdmin,
  required String directory,
  required String title,
  UploadTaskCenter? taskCenter,
  String accountName = '',
  String? accountId,
}) => Navigator.of(context).push<void>(
  buildIslePageRoute<void>(
    builder: (_) => Scaffold(
      appBar: IsleAppBar(title: Text(title)),
      body: SafeArea(
        top: false,
        child: FilesPage(
          api: api,
          isAdmin: isAdmin,
          initialPath: directory,
          taskCenter: taskCenter,
          accountName: accountName,
          accountId: accountId,
        ),
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
    buildIslePageRoute<void>(
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
    this.accountId,
    this.initialPath = '.',
    this.uploadOnly = false,
    this.initialUploadType = FileType.any,
    this.onUploaded,
    this.taskCenter,
    this.compactEmbeddedHeader = false,
    @visibleForTesting this.mobileExportOverride,
    @visibleForTesting this.exportDirectoryFactory,
    @visibleForTesting this.exportDirectoryCleanup,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final String? accountId;

  /// The authenticated user's configured files directory.
  final String initialPath;
  final bool uploadOnly;
  final FileType initialUploadType;
  final VoidCallback? onUploaded;
  final UploadTaskCenter? taskCenter;

  /// When embedded inside ClientShell's mobile file workspace, hides the
  /// redundant page title row and merges refresh into the breadcrumb bar.
  final bool compactEmbeddedHeader;

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
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _highlightedItemKey = GlobalKey();
  late final FilesController _controller;
  late final FilesUiActions _actions;

  FilesPageConfig _buildConfig() => FilesPageConfig(
    api: widget.api,
    isAdmin: widget.isAdmin,
    accountName: widget.accountName,
    accountId: widget.accountId,
    initialPath: widget.initialPath,
    uploadOnly: widget.uploadOnly,
    initialUploadType: widget.initialUploadType,
    onUploaded: widget.onUploaded,
    taskCenter: widget.taskCenter,
    mobileExportOverride: widget.mobileExportOverride,
    exportDirectoryFactory: widget.exportDirectoryFactory,
    exportDirectoryCleanup: widget.exportDirectoryCleanup,
  );

  @override
  void initState() {
    super.initState();
    _controller = FilesController(
      config: _buildConfig(),
      onHighlightActivated: _scrollToHighlightedItem,
      onRestoreScrollOffset: _scheduleRestoreScroll,
      readScrollOffset: () =>
          _scrollController.hasClients ? _scrollController.offset : 0.0,
      onNoticeMessage: _showNoticeSnackBar,
    );
    _actions = FilesUiActions(
      controller: _controller,
      openUploadRoute: _openUploadRoute,
    );
    unawaited(_controller.initialize(deferInitialNotify: true));
  }

  @override
  void didUpdateWidget(covariant FilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.updateConfig(_buildConfig());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<int> _openUploadRoute(
    BuildContext context, {
    required String directory,
    required FileType type,
    required String title,
  }) => openFileUpload(
    context,
    api: _controller.api,
    isAdmin: _controller.isAdmin,
    accountName: _controller.accountName,
    taskCenter: _controller.taskCenter,
    directory: directory,
    type: type,
    title: title,
  );

  void _showNoticeSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToHighlightedItem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final itemContext = _highlightedItemKey.currentContext;
      if (itemContext == null) return;
      final reduced = IsleMotion.reducedMotion(context);
      unawaited(
        Scrollable.ensureVisible(
          itemContext,
          alignment: 0.35,
          duration: reduced
              ? Duration.zero
              : const Duration(milliseconds: 260),
        ),
      );
    });
  }

  void _scheduleRestoreScroll(double offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final maxExtent = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(offset.clamp(0.0, maxExtent).toDouble());
    });
  }

  void _handlePopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    _controller.handlePopBack();
  }

  bool _isEditingText() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    if (focusContext.widget is EditableText) return true;
    return focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _handleEscapeShortcut() {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _controller.handleEscapeKey(isEditingText: _isEditingText());
  }

  void _handleSelectAllShortcut() {
    _controller.handleSelectAllKey(isEditingText: _isEditingText());
  }

  @override
  Widget build(BuildContext context) {
    final useMeta =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        if (widget.uploadOnly) {
          return FilesUploadOnlyView(
            controller: _controller,
            actions: _actions,
          );
        }
        final dir = _controller.dir;
        final filter = _controller.filter;
        final transfers = _controller.transfers;

        return IsleChildPopScope(
          canPop: _controller.canPopPage,
          onPopInvokedWithResult: _handlePopInvoked,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape):
                  _handleEscapeShortcut,
              SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: useMeta,
                control: !useMeta,
              ): _handleSelectAllShortcut,
            },
            child: Focus(
              autofocus: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact =
                      constraints.maxWidth < IsleLayout.compactPageWidth;
                  final inset = IsleLayout.pageInset(constraints.maxWidth);
                  final topInset = IsleLayout.pageTopInset(
                    constraints.maxWidth,
                  );
                  final contentWidth = (constraints.maxWidth - inset * 2).clamp(
                    0.0,
                    IsleLayout.workbenchMaxWidth,
                  );
                  return RefreshIndicator(
                    onRefresh: _controller.refreshCurrentView,
                    child: ListView(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        inset,
                        topInset,
                        inset,
                        inset + 56,
                      ),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: IsleLayout.workbenchMaxWidth,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                FilesHeader(
                                  controller: _controller,
                                  compactEmbeddedHeader:
                                      widget.compactEmbeddedHeader,
                                ),
                                const SizedBox(height: 8),
                                FilesToolbar(
                                  controller: _controller,
                                  actions: _actions,
                                  compact: compact,
                                  availableWidth: contentWidth,
                                ),
                                if (filter.searching) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    '${filter.searchScopeSubdir != null && !filter.searchEntireRoot ? '在当前目录“${filter.searchScopeSubdir!.split('/').last}”中' : '在当前整盘中'}搜索“${filter.searchTerm}” · 仅搜索当前账号可访问的名称。',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                                if (!filter.showingTrash &&
                                    !dir.canWrite &&
                                    !dir.loading &&
                                    dir.error == null)
                                  FilesReadOnlyBanner(compact: compact),
                                if (transfers.batchBusy &&
                                    transfers.batchProgress != null)
                                  FilesBatchProgressBanner(
                                    controller: _controller,
                                  ),
                                if (dir.error != null)
                                  Notice(
                                    dir.error!,
                                    error: true,
                                    diagnostic: dir.error!.startsWith('读取目录失败：')
                                        ? dir.directoryDiagnostic
                                        : null,
                                    retryLabel:
                                        transfers.lastFailedBatchRetry != null
                                        ? '仅重试失败项'
                                        : '重试',
                                    onRetry:
                                        transfers.lastFailedBatchRetry != null
                                        ? () => unawaited(
                                            _actions.retryFailedBatchTransfer(
                                              context,
                                            ),
                                          )
                                        : filter.showingTrash
                                        ? () => unawaited(
                                            _controller.loadTrash(),
                                          )
                                        : filter.searching
                                        ? () => unawaited(
                                            _controller.searchFiles(),
                                          )
                                        : () => unawaited(
                                            _controller.loadFiles(),
                                          ),
                                  ),
                                if (transfers.downloadMessage != null)
                                  FilesDownloadNotice(
                                    message: transfers.downloadMessage!,
                                    onCopyPath: (path) => unawaited(
                                      _actions.copyPathToClipboard(
                                        context,
                                        path,
                                      ),
                                    ),
                                  ),
                                if (_controller.uploadJobs.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  FilesUploadQueueSection(
                                    controller: _controller,
                                    actions: _actions,
                                  ),
                                ],
                                const SizedBox(height: 10),
                                FilesBrowserSurface(
                                  controller: _controller,
                                  actions: _actions,
                                  highlightedItemKey: _highlightedItemKey,
                                  compact: compact,
                                  availableWidth: contentWidth,
                                ),
                                const SizedBox(height: 16),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
