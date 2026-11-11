import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import 'photo_ai_models.dart';

/// Displays macOS Vision scene labels, recognized person tags (with avatars),
/// and selectable Live Text OCR content inside the photo detail panel.
class PhotoLiveTextCard extends StatefulWidget {
  const PhotoLiveTextCard({
    required this.api,
    required this.assetId,
    this.onSelectSceneLabel,
    this.onSelectPerson,
    super.key,
  });

  final LightIsleApi api;
  final int assetId;
  final ValueChanged<String>? onSelectSceneLabel;
  final void Function(int personId, String personName)? onSelectPerson;

  @override
  State<PhotoLiveTextCard> createState() => _PhotoLiveTextCardState();
}

class _PhotoLiveTextCardState extends State<PhotoLiveTextCard> {
  AssetAIDetail? _detail;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant PhotoLiveTextCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId || oldWidget.api != widget.api) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _detail = null;
    });
    try {
      final res = await PhotoAIRepository(widget.api)
          .fetchAssetAIDetail(widget.assetId);
      if (!mounted || gen != _generation) return;
      setState(() {
        _detail = res;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || gen != _generation) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _copyOcrText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制图中识别文字')));
  }

  Widget _buildFaceAvatar(AssetFaceRef face) {
    if (face.faceId <= 0) {
      return const Icon(Icons.face_retouching_natural, size: 15);
    }
    return ClipOval(
      child: SizedBox(
        width: 20,
        height: 20,
        child: AuthenticatedMediaImage(
          api: widget.api,
          memoryCache: IsleCacheManager.instance.sharedThumbnails,
          path: '/api/v2/photos/faces/${face.faceId}/thumbnail',
          maxBytes: 1024 * 1024,
          fit: BoxFit.cover,
          loadingBuilder: (_) =>
              const Icon(Icons.face_retouching_natural, size: 14),
          errorBuilder: (_, _, _) =>
              const Icon(Icons.face_retouching_natural, size: 14),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '正在读取离线智能识图与图中文字…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    final detail = _detail;
    if (detail == null) return const SizedBox.shrink();

    final hasScene = detail.sceneLabels.isNotEmpty;
    final hasFaces = detail.faces.isNotEmpty;
    final hasOcr = detail.ocrText.trim().isNotEmpty;
    if (!detail.indexed && !hasScene && !hasFaces && !hasOcr) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          '智能识图：等待后台离线索引（不上传云端）',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (!hasScene && !hasFaces && !hasOcr) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Text('智能识图与图中文字', style: Theme.of(context).textTheme.titleSmall),
        if (hasScene) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final label in detail.sceneLabels)
                widget.onSelectSceneLabel != null
                    ? ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(
                          Icons.auto_awesome_outlined,
                          size: 15,
                        ),
                        tooltip: '按场景「$label」搜索照片',
                        label: Text(label),
                        onPressed: () => widget.onSelectSceneLabel!(label),
                      )
                    : Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(
                          Icons.auto_awesome_outlined,
                          size: 15,
                        ),
                        label: Text(label),
                      ),
            ],
          ),
        ],
        if (hasFaces) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final face in detail.faces)
                (widget.onSelectPerson != null && face.personId > 0)
                    ? ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: _buildFaceAvatar(face),
                        tooltip: '查看「${face.displayLabel}」的照片',
                        label: Text(face.displayLabel),
                        onPressed: () => widget.onSelectPerson!(
                          face.personId,
                          face.displayLabel,
                        ),
                      )
                    : Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: _buildFaceAvatar(face),
                        label: Text(face.displayLabel),
                      ),
            ],
          ),
        ],
        if (hasOcr) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: IsleRadius.brItem,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.text_snippet_outlined,
                          size: 16,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '实况文本（离线 OCR）',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      ],
                    ),
                    TextButton.icon(
                      key: const ValueKey('copyPhotoOcrButton'),
                      onPressed: () => _copyOcrText(detail.ocrText),
                      icon: const Icon(Icons.copy_rounded, size: 15),
                      label: const Text('复制全文'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      detail.ocrText,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
