import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'photo_ai_models.dart';

const List<String> documentArchiveCategories = <String>[
  '证件',
  '发票',
  '保修',
  '合同',
  '体检',
  '其他',
];

class DocumentScannerCapabilities {
  const DocumentScannerCapabilities({
    this.scanner = false,
    this.camera = false,
    this.picker = true,
  });

  final bool scanner;
  final bool camera;
  final bool picker;
}

class DocumentCaptureResult {
  const DocumentCaptureResult({
    this.paths = const [],
    this.cancelled = false,
    this.source = 'picker',
  });

  final List<String> paths;
  final bool cancelled;
  final String source;
}

/// Native bridge for `lightisle/document-scanner` (iOS VisionKit / Android
/// camera & document picker) with automatic desktop `FilePicker` fallback.
class DocumentScannerBridge {
  const DocumentScannerBridge();

  static const MethodChannel channel = MethodChannel(
    'lightisle/document-scanner',
  );

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<DocumentScannerCapabilities> capabilities() async {
    if (!_isMobile) return const DocumentScannerCapabilities(picker: true);
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>('isAvailable');
      return DocumentScannerCapabilities(
        scanner: raw?['scanner'] == true,
        camera: raw?['camera'] == true,
        picker: raw?['picker'] != false,
      );
    } on MissingPluginException {
      return const DocumentScannerCapabilities(picker: true);
    } on PlatformException {
      return const DocumentScannerCapabilities(picker: true);
    }
  }

  Future<DocumentCaptureResult> capture({String source = 'scanner'}) async {
    if (_isMobile) {
      try {
        final raw = await channel.invokeMapMethod<String, dynamic>(
          'scanDocument',
          <String, Object>{'source': source},
        );
        if (raw == null || raw['cancelled'] == true) {
          return const DocumentCaptureResult(cancelled: true);
        }
        final paths = (raw['paths'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().trim())
            .where((p) => p.isNotEmpty)
            .toList(growable: false);
        return DocumentCaptureResult(
          paths: paths,
          cancelled: paths.isEmpty,
          source: raw['source']?.toString() ?? source,
        );
      } on MissingPluginException {
        // Fall through to FilePicker below.
      }
    }
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) {
      return const DocumentCaptureResult(cancelled: true);
    }
    final paths = picked
        .map((f) => f.path?.trim() ?? '')
        .where((p) => p.isNotEmpty)
        .take(10)
        .toList(growable: false);
    return DocumentCaptureResult(
      paths: paths,
      cancelled: paths.isEmpty,
      source: 'picker',
    );
  }
}

class PriorityOcrResult {
  const PriorityOcrResult({
    required this.queued,
    required this.assetId,
    required this.path,
  });

  final bool queued;
  final int assetId;
  final String path;
}

class DocumentArchiveApi {
  const DocumentArchiveApi(this.api);

  final LightIsleApi api;

  static const int _chunkSizeBytes = 4 * 1024 * 1024;

  static String cleanRelativeDir(String raw) {
    final normalized = raw
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized == '.' || normalized.isEmpty) return '';
    return normalized;
  }

  Future<String> resolvePhotosBaseDir({
    String? preferred,
    Map<String, dynamic>? personalStorage,
  }) async {
    final pref = cleanRelativeDir(preferred ?? '');
    if (pref.isNotEmpty && pref != '图库') return pref;

    final fromSnapshot = _extractPhotosLocation(personalStorage);
    if (fromSnapshot.isNotEmpty) return fromSnapshot;

    try {
      final fetched = await api.get('/api/v2/me/storage');
      final fromServer = _extractPhotosLocation(fetched);
      if (fromServer.isNotEmpty) return fromServer;
    } catch (_) {
      // Fallback below.
    }
    return pref.isNotEmpty ? pref : '图库';
  }

  String _extractPhotosLocation(Map<String, dynamic>? storage) {
    if (storage == null) return '';
    for (final loc in objectList(storage['locations'])) {
      if (loc['category']?.toString() != 'photos') continue;
      final rel = cleanRelativeDir(
        loc['relativePath']?.toString() ?? loc['path']?.toString() ?? '',
      );
      if (rel.isNotEmpty) return rel;
    }
    return '';
  }

  Future<void> ensureFolders(String baseDir, String category) async {
    final archiveRoot = baseDir.isEmpty ? '家庭档案' : '$baseDir/家庭档案';
    final categoryDir = '$archiveRoot/$category';
    for (final dir in [archiveRoot, categoryDir]) {
      try {
        await api.send('POST', '/api/v2/files/folders', body: {'path': dir});
      } on LightIsleApiException catch (error) {
        if (error.statusCode == 409 || error.code == 'file_already_exists') {
          continue;
        }
        rethrow;
      }
    }
  }

  Future<String> uploadFile(File localFile, String remotePath) async {
    final size = await localFile.length();
    final begin = await api.send(
      'POST',
      '/api/v2/uploads',
      body: <String, Object>{
        'path': remotePath,
        'size': size,
        'onConflict': 'rename',
      },
    );
    final uploadId = begin['id']?.toString() ?? '';
    final finalPath = begin['path']?.toString().trim().isNotEmpty == true
        ? begin['path']!.toString().trim()
        : remotePath;
    if (uploadId.isEmpty) {
      throw const FormatException('服务器未返回上传任务编号。');
    }

    var offset = (begin['offset'] as num?)?.toInt() ?? 0;
    final raf = await localFile.open(mode: FileMode.read);
    try {
      while (offset < size) {
        final remaining = size - offset;
        final chunkLen = remaining > _chunkSizeBytes
            ? _chunkSizeBytes
            : remaining;
        await raf.setPosition(offset);
        final bytes = await raf.read(chunkLen);
        await api.uploadChunk(
          uploadId,
          Stream<List<int>>.value(bytes),
          bytes.length,
          offset,
        );
        offset += bytes.length;
      }
    } finally {
      await raf.close();
    }

    await api.send('POST', '/api/v2/uploads/$uploadId/complete');
    return finalPath;
  }

  Future<void> writeNoteMetadata({
    required String remoteImagePath,
    required String category,
    required String note,
  }) async {
    final trimmed = note.trim();
    if (trimmed.isEmpty) return;
    final dot = remoteImagePath.lastIndexOf('.');
    final stem = dot > 0 ? remoteImagePath.substring(0, dot) : remoteImagePath;
    final notePath = '$stem.txt';
    final nowIso = DateTime.now().toIso8601String();
    final content =
        '分类：$category\n'
        '归档时间：$nowIso\n'
        '原件：$remoteImagePath\n'
        '备注：$trimmed\n';
    try {
      await api.send(
        'PUT',
        '/api/v2/files/text',
        body: <String, Object>{
          'path': notePath,
          'content': content,
          'create': true,
        },
      );
    } catch (_) {
      // Note metadata sidecar is best-effort and must not block OCR indexing.
    }
  }

  Future<PriorityOcrResult> triggerPriorityOcr(String remotePath) async {
    final res = await api.send(
      'POST',
      '/api/v2/photos/ocr-priority',
      body: <String, Object>{'path': remotePath},
    );
    return PriorityOcrResult(
      queued: res['queued'] == true,
      assetId: (res['assetId'] as num?)?.toInt() ?? 0,
      path: res['path']?.toString() ?? remotePath,
    );
  }

  Future<AssetAIDetail> fetchOcrDetail(int assetId) {
    return PhotoAIRepository(api).fetchAssetAIDetail(assetId);
  }

  Future<List<PhotoAsset>> searchArchives({
    required String pathPrefix,
    String query = '',
    String searchMode = 'ocr',
  }) async {
    final params = <String, String>{
      'pathPrefix': pathPrefix,
      'limit': '60',
      if (query.trim().isNotEmpty) 'q': query.trim(),
      if (query.trim().isNotEmpty) 'searchMode': searchMode,
    };
    final res = await api.get('/api/v2/photos', query: params);
    final out = <PhotoAsset>[];
    for (final raw in objectList(res['assets'])) {
      try {
        out.add(PhotoAsset.fromJson(raw));
      } catch (_) {
        // Ignore malformed entries.
      }
    }
    return out;
  }
}

/// Modal detail sheet for inspecting an archived receipt/document image and
/// copying its offline macOS Vision OCR text.
class ArchiveItemDetailSheet extends StatefulWidget {
  const ArchiveItemDetailSheet({
    super.key,
    required this.api,
    required this.asset,
    required this.category,
    required this.onCopy,
  });

  final LightIsleApi api;
  final PhotoAsset asset;
  final String category;
  final Future<void> Function(String text) onCopy;

  @override
  State<ArchiveItemDetailSheet> createState() => _ArchiveItemDetailSheetState();
}

class _ArchiveItemDetailSheetState extends State<ArchiveItemDetailSheet> {
  AssetAIDetail? _aiDetail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDetail());
  }

  Future<void> _loadDetail() async {
    try {
      final res = await PhotoAIRepository(
        widget.api,
      ).fetchAssetAIDetail(widget.asset.id);
      if (!mounted) return;
      setState(() {
        _aiDetail = res;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = _aiDetail?.ocrText.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.asset.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '分类：${widget.category} · ${widget.asset.path}',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: AuthenticatedMediaImage(
                  api: widget.api,
                  path: '/api/v2/files/preview',
                  query: {'path': widget.asset.path},
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '离线 Vision OCR 识别文字',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (text.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => unawaited(widget.onCopy(text)),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('一键复制'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (_loading)
              const LinearProgressIndicator(minHeight: 3)
            else if (text.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: IsleDecorations.recessedWell(context, radius: 10),
                child: SelectableText(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                ),
              )
            else
              Text(
                '暂未检测到 OCR 识别文字，可在 Mac 完成离线识别后再查看。',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}
