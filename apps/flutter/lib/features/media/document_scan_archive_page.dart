import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'document_scan_archive_service.dart';
import 'document_scan_archive_widgets.dart';
import 'media_models.dart';

export 'document_scan_archive_service.dart'
    show
        DocumentArchiveApi,
        DocumentArchiveDestination,
        DocumentCaptureResult,
        DocumentScannerBridge,
        DocumentScannerCapabilities,
        PriorityOcrResult,
        documentArchiveCategories,
        normalizeDocumentArchiveExtension;

/// Family Document & Receipt Scanner + Priority Vision OCR Search Page.
class DocumentScanArchivePage extends StatefulWidget {
  const DocumentScanArchivePage({
    super.key,
    required this.api,
    this.initialBaseDirectory,
    this.personalStorage,
    this.roots,
    this.isAdmin,
    this.scannerBridge = const DocumentScannerBridge(),
    this.ocrPollInterval = const Duration(milliseconds: 1500),
    this.maxOcrPollAttempts = 12,
  });

  final LightIsleApi api;
  final String? initialBaseDirectory;
  final Map<String, dynamic>? personalStorage;
  final List<LightIsleRoot>? roots;
  final bool? isAdmin;
  final DocumentScannerBridge scannerBridge;
  final Duration ocrPollInterval;
  final int maxOcrPollAttempts;

  @override
  State<DocumentScanArchivePage> createState() =>
      _DocumentScanArchivePageState();
}

class _DocumentScanArchivePageState extends State<DocumentScanArchivePage> {
  LightIsleApi? _isolatedApi;
  LightIsleRoot? _previousSharedRoot;
  bool _mutatedSharedRoot = false;
  LightIsleRoot? _boundRoot;

  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();

  DocumentScannerCapabilities _capabilities =
      const DocumentScannerCapabilities();
  String _baseDir = '图库';
  String? _blockedDestinationMessage;
  String _selectedCategory = documentArchiveCategories.first;
  String _filterCategory = '全部';
  String _searchMode = 'ocr';
  bool _hasSearchText = false;
  List<String> _pendingLocalPaths = const [];
  List<PhotoAsset> _archives = const [];
  ArchivedScanItem? _latestResult;

  bool _loadingArchives = false;
  bool _archiving = false;
  String? _statusMessage;
  String? _error;
  Timer? _searchDebounce;
  int _pollToken = 0;

  LightIsleApi get _activeApi => _isolatedApi ?? widget.api;
  DocumentArchiveApi get _archiveApi => DocumentArchiveApi(_activeApi);

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _pollToken++;
    _searchDebounce?.cancel();
    _noteCtrl.dispose();
    _searchCtrl.dispose();
    _releaseBoundClient();
    super.dispose();
  }

  void _releaseBoundClient() {
    _isolatedApi?.close();
    _isolatedApi = null;
    if (_mutatedSharedRoot) {
      widget.api.selectRoot(_previousSharedRoot);
      _mutatedSharedRoot = false;
      _previousSharedRoot = null;
    }
  }

  void _bindDestinationRoot(LightIsleRoot? targetRoot) {
    _releaseBoundClient();
    _boundRoot = targetRoot;
    if (targetRoot == null) return;
    final snapshot = widget.api.sessionSnapshot;
    if (snapshot != null) {
      _isolatedApi = LightIsleApi.fromSessionSnapshot(snapshot)
        ..selectRoot(targetRoot);
    } else if (widget.api.selectedRoot?.identity != targetRoot.identity) {
      _previousSharedRoot = widget.api.selectedRoot;
      widget.api.selectRoot(targetRoot);
      _mutatedSharedRoot = true;
    }
  }

  String get _archivePrefix {
    final root = _baseDir.isEmpty ? '家庭档案' : '$_baseDir/家庭档案';
    return _filterCategory == '全部' ? root : '$root/$_filterCategory';
  }

  Future<void> _bootstrap() async {
    final results = await Future.wait<Object>([
      widget.scannerBridge.capabilities(),
      DocumentArchiveApi(widget.api).resolvePhotosDestination(
        preferred: widget.initialBaseDirectory,
        personalStorage: widget.personalStorage,
        roots: widget.roots,
        isAdmin: widget.isAdmin,
      ),
    ]);
    if (!mounted) return;
    final capabilities = results[0] as DocumentScannerCapabilities;
    final destination = results[1] as DocumentArchiveDestination;
    if (!destination.isBlocked) {
      _bindDestinationRoot(destination.boundRoot);
    } else {
      _releaseBoundClient();
      _boundRoot = null;
    }
    setState(() {
      _capabilities = capabilities;
      _baseDir = destination.baseDir;
      _blockedDestinationMessage = destination.blockedMessage;
      if (destination.isBlocked) {
        _archives = const [];
      }
    });
    if (!destination.isBlocked) {
      await _loadArchives();
    }
  }

  Future<void> _loadArchives() async {
    if (_loadingArchives || _blockedDestinationMessage != null) return;
    setState(() {
      _loadingArchives = true;
      _error = null;
    });
    try {
      final items = await _archiveApi.searchArchives(
        pathPrefix: _archivePrefix,
        query: _searchCtrl.text,
        searchMode: _searchMode,
      );
      if (!mounted) return;
      setState(() {
        _archives = items;
        _loadingArchives = false;
      });
    } on LightIsleApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 404) {
        setState(() {
          _archives = const [];
          _loadingArchives = false;
        });
      } else {
        setState(() {
          _error = userFacingError(error);
          _loadingArchives = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(error);
        _loadingArchives = false;
      });
    }
  }

  void _onSearchChanged(String value) {
    final nonEmpty = value.isNotEmpty;
    if (nonEmpty != _hasSearchText) {
      setState(() => _hasSearchText = nonEmpty);
    }
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) unawaited(_loadArchives());
    });
  }

  Future<void> _captureDocuments({required String source}) async {
    if (_archiving || _blockedDestinationMessage != null) return;
    setState(() => _error = null);
    try {
      final captured = await widget.scannerBridge.capture(source: source);
      if (!mounted || captured.cancelled || captured.paths.isEmpty) return;
      setState(() {
        _pendingLocalPaths = [
          ..._pendingLocalPaths,
          ...captured.paths,
        ].take(10).toList(growable: false);
      });
    } catch (error) {
      if (mounted) setState(() => _error = userFacingError(error));
    }
  }

  String _buildRemoteFileName(
    String localPath,
    int pageIndex,
    int totalPages,
    String note,
  ) {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final sanitizedNote = note
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    final clipped = sanitizedNote.length > 24
        ? sanitizedNote.substring(0, 24)
        : sanitizedNote;
    final suffix = totalPages > 1 ? '_p${pageIndex + 1}' : '';
    final label = clipped.isEmpty ? _selectedCategory : clipped;
    final ext = normalizeDocumentArchiveExtension(localPath);
    return '${stamp}_$label$suffix.$ext';
  }

  void _removePendingPathOnce(String targetPath) {
    final next = List<String>.of(_pendingLocalPaths);
    final idx = next.indexOf(targetPath);
    if (idx < 0) return;
    next.removeAt(idx);
    _pendingLocalPaths = List<String>.unmodifiable(next);
  }

  Future<void> _uploadAndTriggerOcr() async {
    if (_archiving ||
        _pendingLocalPaths.isEmpty ||
        _blockedDestinationMessage != null) {
      return;
    }
    final paths = List<String>.of(_pendingLocalPaths);
    final category = _selectedCategory;
    final note = _noteCtrl.text.trim();
    ArchivedScanItem? lastQueued;

    setState(() {
      _archiving = true;
      _error = null;
      _statusMessage = '正在准备 家庭档案/$category 目录…';
    });

    try {
      await _archiveApi.ensureFolders(_baseDir, category);
      final targetDir = _baseDir.isEmpty
          ? '家庭档案/$category'
          : '$_baseDir/家庭档案/$category';

      for (var i = 0; i < paths.length; i++) {
        final localPath = paths[i];
        final file = File(localPath);
        if (!await file.exists()) {
          if (mounted) {
            setState(() => _removePendingPathOnce(localPath));
          }
          continue;
        }
        if (mounted) {
          setState(
            () => _statusMessage =
                '正在上传第 ${i + 1}/${paths.length} 页至 $targetDir…',
          );
        }
        final remoteName = _buildRemoteFileName(
          localPath,
          i,
          paths.length,
          note,
        );
        final finalPath = await _archiveApi.uploadFile(
          file,
          '$targetDir/$remoteName',
        );
        if (note.isNotEmpty) {
          await _archiveApi.writeNoteMetadata(
            remoteImagePath: finalPath,
            category: category,
            note: note,
          );
        }
        if (mounted) {
          setState(() => _statusMessage = '已归档，正在触发优先 Vision OCR…');
        }
        final ocrRes = await _archiveApi.triggerPriorityOcr(finalPath);
        lastQueued = ArchivedScanItem(
          assetId: ocrRes.assetId,
          remotePath: ocrRes.path,
          category: category,
          note: note,
          polling: ocrRes.assetId > 0,
        );
        if (mounted) {
          setState(() {
            _removePendingPathOnce(localPath);
            _latestResult = lastQueued;
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _archiving = false;
        _noteCtrl.clear();
        _statusMessage = null;
        if (lastQueued != null) _latestResult = lastQueued;
      });
      unawaited(_loadArchives());
      if (lastQueued != null && lastQueued.assetId > 0) {
        unawaited(_pollOcrResult(lastQueued.assetId));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _archiving = false;
        _statusMessage = null;
        _error = userFacingError(error);
      });
      if (lastQueued != null) {
        unawaited(_loadArchives());
        if (lastQueued.assetId > 0) {
          unawaited(_pollOcrResult(lastQueued.assetId));
        }
      }
    }
  }

  Future<void> _pollOcrResult(int assetId) async {
    final token = ++_pollToken;
    for (var attempt = 0; attempt < widget.maxOcrPollAttempts; attempt++) {
      if (!mounted || token != _pollToken) return;
      try {
        final detail = await _archiveApi.fetchOcrDetail(assetId);
        if (!mounted || token != _pollToken) return;
        final text = detail.ocrText.trim();
        if (detail.indexed || text.isNotEmpty) {
          setState(() {
            if (_latestResult?.assetId == assetId) {
              _latestResult = _latestResult!.copyWith(
                ocrText: text,
                ocrIndexed: true,
                polling: false,
              );
            }
          });
          return;
        }
      } catch (_) {
        // Keep polling within bounded window.
      }
      if (attempt + 1 < widget.maxOcrPollAttempts) {
        await Future<void>.delayed(widget.ocrPollInterval);
      }
    }
    if (mounted && token == _pollToken && _latestResult?.assetId == assetId) {
      setState(() {
        _latestResult = _latestResult!.copyWith(polling: false);
      });
    }
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已复制识别文字')),
    );
  }

  String _categoryFromPath(String path) {
    final parts = path.split('/');
    final idx = parts.indexOf('家庭档案');
    if (idx >= 0 && idx + 1 < parts.length) return parts[idx + 1];
    return '档案';
  }

  Future<void> _openArchiveDetail(PhotoAsset asset) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ArchiveItemDetailSheet(
        api: _activeApi,
        asset: asset,
        category: _categoryFromPath(asset.path),
        onCopy: _copyText,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    final blocked = _blockedDestinationMessage != null;

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('家庭档案与票据快扫'),
        actions: [
          IconButton(
            tooltip: '刷新档案',
            onPressed: _loadingArchives
                ? null
                : () => unawaited(blocked ? _bootstrap() : _loadArchives()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: blocked ? _bootstrap : _loadArchives,
        child: IsleListView(
          maxWidth: IsleLayout.secondaryPageWidth,
          children: [
            if (_blockedDestinationMessage != null) ...[
              Notice(
                _blockedDestinationMessage!,
                error: true,
                onRetry: () => unawaited(_bootstrap()),
              ),
              const SizedBox(height: 10),
            ],
            DocumentScanCaptureCard(
              capabilities: _capabilities,
              baseDir: _baseDir,
              boundRootName: _boundRoot?.name,
              selectedCategory: _selectedCategory,
              noteController: _noteCtrl,
              pendingLocalPaths: _pendingLocalPaths,
              archiving: _archiving,
              blocked: blocked,
              statusMessage: _statusMessage,
              onSelectCategory: (cat) => setState(() => _selectedCategory = cat),
              onCapture: (src) => unawaited(_captureDocuments(source: src)),
              onRemovePendingIndex: (index) => setState(() {
                _pendingLocalPaths = [
                  for (var j = 0; j < _pendingLocalPaths.length; j++)
                    if (j != index) _pendingLocalPaths[j],
                ];
              }),
              onUploadAndTriggerOcr: () => unawaited(_uploadAndTriggerOcr()),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Notice(
                _error!,
                error: true,
                onRetry: () => unawaited(_loadArchives()),
              ),
            ],
            if (_latestResult != null) ...[
              const SizedBox(height: 12),
              DocumentScanLatestOcrCard(
                result: _latestResult!,
                onCopyText: _copyText,
                onRefreshPoll: () {
                  final current = _latestResult;
                  if (current == null || current.assetId <= 0) return;
                  setState(() {
                    _latestResult = current.copyWith(polling: true);
                  });
                  unawaited(_pollOcrResult(current.assetId));
                },
              ),
            ],
            const SizedBox(height: 16),
            IsleSectionHeader(
              title: '档案库秒搜',
              accentColor: palette['brandAmber'],
              action: ChoiceChip(
                visualDensity: VisualDensity.compact,
                label: Text(_searchMode == 'ocr' ? '仅搜 OCR 文字' : '全字段搜索'),
                selected: _searchMode == 'ocr',
                onSelected: blocked
                    ? null
                    : (_) {
                        setState(() {
                          _searchMode = _searchMode == 'ocr' ? 'all' : 'ocr';
                        });
                        unawaited(_loadArchives());
                      },
              ),
            ),
            IsleSearchBar(
              key: const ValueKey('archiveOcrSearchField'),
              controller: _searchCtrl,
              maxLength: 64,
              hintText: '输入发票号、保修产品、医院或证件关键词秒搜…',
              showClear: _hasSearchText,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => unawaited(_loadArchives()),
              onClear: () {
                _searchCtrl.clear();
                setState(() => _hasSearchText = false);
                unawaited(_loadArchives());
              },
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final cat in ['全部', ...documentArchiveCategories])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(cat),
                        selected: _filterCategory == cat,
                        onSelected: blocked
                            ? null
                            : (_) {
                                setState(() => _filterCategory = cat);
                                unawaited(_loadArchives());
                              },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (_loadingArchives && _archives.isEmpty)
              const IsleLoadingState(compact: true, label: '正在检索家庭档案…')
            else if (_archives.isEmpty)
              IsleSurface(
                margin: EdgeInsets.zero,
                radius: IsleRadius.card,
                padding: const EdgeInsets.all(16),
                child: Text(
                  blocked
                      ? '照片存储硬盘恢复在线后，即可检索与归档家庭票据。'
                      : _searchCtrl.text.trim().isEmpty
                      ? '「$_filterCategory」暂无已归档票据，点击上方按钮即可扫码拍照归档。'
                      : '未在「$_filterCategory」中找到匹配「${_searchCtrl.text.trim()}」的档案。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette['textSecondary'],
                  ),
                ),
              )
            else
              for (final item in _archives)
                DocumentArchiveAssetTile(
                  api: _activeApi,
                  item: item,
                  category: _categoryFromPath(item.path),
                  onTap: () => unawaited(_openArchiveDetail(item)),
                ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
