import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'document_scan_archive_service.dart';
import 'media_models.dart';
import 'media_ui.dart';

export 'document_scan_archive_service.dart'
    show
        DocumentArchiveApi,
        DocumentCaptureResult,
        DocumentScannerBridge,
        DocumentScannerCapabilities,
        PriorityOcrResult,
        documentArchiveCategories;

class _ArchivedScanItem {
  const _ArchivedScanItem({
    required this.assetId,
    required this.remotePath,
    required this.category,
    required this.note,
    this.ocrText = '',
    this.ocrIndexed = false,
    this.polling = false,
  });

  final int assetId;
  final String remotePath;
  final String category;
  final String note;
  final String ocrText;
  final bool ocrIndexed;
  final bool polling;

  _ArchivedScanItem copyWith({
    String? ocrText,
    bool? ocrIndexed,
    bool? polling,
  }) => _ArchivedScanItem(
    assetId: assetId,
    remotePath: remotePath,
    category: category,
    note: note,
    ocrText: ocrText ?? this.ocrText,
    ocrIndexed: ocrIndexed ?? this.ocrIndexed,
    polling: polling ?? this.polling,
  );
}

/// Family Document & Receipt Scanner + Priority Vision OCR Search Page.
class DocumentScanArchivePage extends StatefulWidget {
  const DocumentScanArchivePage({
    super.key,
    required this.api,
    this.initialBaseDirectory,
    this.personalStorage,
    this.scannerBridge = const DocumentScannerBridge(),
    this.ocrPollInterval = const Duration(milliseconds: 1500),
    this.maxOcrPollAttempts = 12,
  });

  final LightIsleApi api;
  final String? initialBaseDirectory;
  final Map<String, dynamic>? personalStorage;
  final DocumentScannerBridge scannerBridge;
  final Duration ocrPollInterval;
  final int maxOcrPollAttempts;

  @override
  State<DocumentScanArchivePage> createState() =>
      _DocumentScanArchivePageState();
}

class _DocumentScanArchivePageState extends State<DocumentScanArchivePage> {
  late final DocumentArchiveApi _archiveApi;
  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();

  DocumentScannerCapabilities _capabilities =
      const DocumentScannerCapabilities();
  String _baseDir = '图库';
  String _selectedCategory = documentArchiveCategories.first;
  String _filterCategory = '全部';
  String _searchMode = 'ocr';
  List<String> _pendingLocalPaths = const [];
  List<PhotoAsset> _archives = const [];
  _ArchivedScanItem? _latestResult;

  bool _loadingArchives = false;
  bool _archiving = false;
  String? _statusMessage;
  String? _error;
  Timer? _searchDebounce;
  int _pollToken = 0;

  @override
  void initState() {
    super.initState();
    _archiveApi = DocumentArchiveApi(widget.api);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _pollToken++;
    _searchDebounce?.cancel();
    _noteCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _archivePrefix {
    final root = _baseDir.isEmpty ? '家庭档案' : '$_baseDir/家庭档案';
    return _filterCategory == '全部' ? root : '$root/$_filterCategory';
  }

  Future<void> _bootstrap() async {
    final results = await Future.wait<Object>([
      widget.scannerBridge.capabilities(),
      _archiveApi.resolvePhotosBaseDir(
        preferred: widget.initialBaseDirectory,
        personalStorage: widget.personalStorage,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _capabilities = results[0] as DocumentScannerCapabilities;
      _baseDir = results[1] as String;
    });
    await _loadArchives();
  }

  Future<void> _loadArchives() async {
    if (_loadingArchives) return;
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

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) unawaited(_loadArchives());
    });
  }

  Future<void> _captureDocuments({required String source}) async {
    if (_archiving) return;
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

  String _buildRemoteFileName(int pageIndex, int totalPages, String note) {
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
    return '${stamp}_$label$suffix.jpg';
  }

  Future<void> _uploadAndTriggerOcr() async {
    if (_archiving || _pendingLocalPaths.isEmpty) return;
    final paths = List<String>.of(_pendingLocalPaths);
    final category = _selectedCategory;
    final note = _noteCtrl.text.trim();

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
      _ArchivedScanItem? lastQueued;

      for (var i = 0; i < paths.length; i++) {
        final file = File(paths[i]);
        if (!await file.exists()) continue;
        if (mounted) {
          setState(
            () => _statusMessage =
                '正在上传第 ${i + 1}/${paths.length} 页至 $targetDir…',
          );
        }
        final remoteName = _buildRemoteFileName(i, paths.length, note);
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
        lastQueued = _ArchivedScanItem(
          assetId: ocrRes.assetId,
          remotePath: ocrRes.path,
          category: category,
          note: note,
          polling: ocrRes.assetId > 0,
        );
      }

      if (!mounted) return;
      setState(() {
        _archiving = false;
        _pendingLocalPaths = const [];
        _noteCtrl.clear();
        _statusMessage = null;
        _latestResult = lastQueued;
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
        api: widget.api,
        asset: asset,
        category: _categoryFromPath(asset.path),
        onCopy: _copyText,
      ),
    );
  }

  Widget _buildCaptureCard(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    final scanLabel = _capabilities.scanner
        ? '扫描票据（VisionKit）'
        : _capabilities.camera
        ? '拍照扫票据'
        : '选择票据图片';

    return IsleSurface(
      radius: IsleRadius.card,
      tint: palette['brandBlue'],
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.document_scanner_rounded,
                color: palette['brandBlue'],
                size: 34,
                iconSize: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '票据快扫归档',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '存入 $_baseDir/家庭档案/$_selectedCategory/ 并插队离线 OCR',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette['textSecondary'],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final cat in documentArchiveCategories)
                ChoiceChip(
                  key: ValueKey('archiveCategory-$cat'),
                  visualDensity: VisualDensity.compact,
                  label: Text(cat),
                  selected: _selectedCategory == cat,
                  onSelected: _archiving
                      ? null
                      : (_) => setState(() => _selectedCategory = cat),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('archiveNoteField'),
            controller: _noteCtrl,
            enabled: !_archiving,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: '归档备注（可选）',
              hintText: '例如：空调保修卡、医保报销发票、身份证复印件…',
              border: OutlineInputBorder(),
              isDense: true,
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('documentScanPrimaryButton'),
                onPressed: _archiving
                    ? null
                    : () => unawaited(
                        _captureDocuments(
                          source: _capabilities.scanner
                              ? 'scanner'
                              : _capabilities.camera
                              ? 'camera'
                              : 'picker',
                        ),
                      ),
                icon: const Icon(Icons.document_scanner_outlined, size: 17),
                label: Text(scanLabel),
              ),
              OutlinedButton.icon(
                key: const ValueKey('documentPickImagesButton'),
                onPressed: _archiving
                    ? null
                    : () => unawaited(_captureDocuments(source: 'picker')),
                icon: const Icon(Icons.photo_library_outlined, size: 17),
                label: const Text('相册/文件选图'),
              ),
            ],
          ),
          if (_pendingLocalPaths.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '待归档页面（${_pendingLocalPaths.length} 页）',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _pendingLocalPaths.length; i++)
                  InputChip(
                    avatar: const Icon(Icons.image_outlined, size: 16),
                    label: Text(
                      '第 ${i + 1} 页 · ${_pendingLocalPaths[i].split('/').last}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    onDeleted: _archiving
                        ? null
                        : () => setState(() {
                            _pendingLocalPaths = [
                              for (var j = 0; j < _pendingLocalPaths.length; j++)
                                if (j != i) _pendingLocalPaths[j],
                            ];
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('uploadAndOcrButton'),
              onPressed: _archiving ? null : () => unawaited(_uploadAndTriggerOcr()),
              icon: _archiving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined, size: 18),
              label: Text(_statusMessage ?? '上传归档并优先 Vision OCR 识别'),
            ),
          ] else if (_statusMessage != null) ...[
            const SizedBox(height: 10),
            Text(_statusMessage!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _buildLatestOcrCard(BuildContext context, _ArchivedScanItem result) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    return IsleSurface(
      key: const ValueKey('latestOcrResultCard'),
      radius: IsleRadius.card,
      tint: palette['brandSage'],
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                result.polling
                    ? Icons.hourglass_top_rounded
                    : Icons.text_snippet_outlined,
                size: 18,
                color: palette['brandSage'],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.polling
                      ? '已归档至「${result.category}」，正在优先 Vision OCR 识别…'
                      : '已归档至「${result.category}」· 识别结果',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (result.ocrText.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('copyScannedOcrButton'),
                  onPressed: () => unawaited(_copyText(result.ocrText)),
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('一键复制'),
                )
              else if (!result.polling && result.assetId > 0)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _latestResult = result.copyWith(polling: true);
                    });
                    unawaited(_pollOcrResult(result.assetId));
                  },
                  child: const Text('刷新识别'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            result.remotePath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: palette['textTertiary'],
            ),
          ),
          const SizedBox(height: 8),
          if (result.polling)
            const LinearProgressIndicator(minHeight: 3)
          else if (result.ocrText.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: IsleDecorations.recessedWell(context, radius: 10),
              child: SelectableText(
                result.ocrText,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            )
          else
            Text(
              result.ocrIndexed
                  ? '已完成识别，未检测到可读文字（图片已安全归档）。'
                  : 'Mac 正在后台排队识别，稍后点击「刷新识别」或直接搜索关键词即可查看。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette['textSecondary'],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    final inset = IsleLayout.pageInset(MediaQuery.sizeOf(context).width);

    return Scaffold(
      appBar: AppBar(
        title: const Text('家庭档案与票据快扫'),
        actions: [
          IconButton(
            tooltip: '刷新档案',
            onPressed: _loadingArchives ? null : () => unawaited(_loadArchives()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadArchives,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(inset, 12, inset, 32),
          children: [
            _buildCaptureCard(context),
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
              _buildLatestOcrCard(context, _latestResult!),
            ],
            const SizedBox(height: 16),
            IsleSectionHeader(
              title: '档案库秒搜',
              accentColor: palette['brandAmber'],
              action: ChoiceChip(
                visualDensity: VisualDensity.compact,
                label: Text(_searchMode == 'ocr' ? '仅搜 OCR 文字' : '全字段搜索'),
                selected: _searchMode == 'ocr',
                onSelected: (_) {
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
              showClear: _searchCtrl.text.isNotEmpty,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => unawaited(_loadArchives()),
              onClear: () {
                _searchCtrl.clear();
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
                        onSelected: (_) {
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
                radius: IsleRadius.card,
                padding: const EdgeInsets.all(16),
                child: Text(
                  _searchCtrl.text.trim().isEmpty
                      ? '「$_filterCategory」暂无已归档票据，点击上方按钮即可扫码拍照归档。'
                      : '未在「$_filterCategory」中找到匹配「${_searchCtrl.text.trim()}」的档案。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette['textSecondary'],
                  ),
                ),
              )
            else
              for (final item in _archives)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: IsleSurface(
                    key: ValueKey('archiveAssetCard-${item.id}'),
                    radius: IsleRadius.item,
                    padding: const EdgeInsets.all(10),
                    onTap: () => unawaited(_openArchiveDetail(item)),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 56,
                            height: 56,
                            child: AuthenticatedMediaImage(
                              api: widget.api,
                              memoryCache:
                                  IsleCacheManager.instance.sharedThumbnails,
                              path: '/api/v2/photos/${item.id}/thumbnail',
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${_categoryFromPath(item.path)} · ${formatMediaDate(item.takenAt)} · ${formatMediaSize(item.size)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: palette['textSecondary'],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: palette['textTertiary'],
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
