import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'document_scan_archive_service.dart';
import 'media_models.dart';
import 'media_ui.dart';

class ArchivedScanItem {
  const ArchivedScanItem({
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

  ArchivedScanItem copyWith({
    String? ocrText,
    bool? ocrIndexed,
    bool? polling,
  }) => ArchivedScanItem(
    assetId: assetId,
    remotePath: remotePath,
    category: category,
    note: note,
    ocrText: ocrText ?? this.ocrText,
    ocrIndexed: ocrIndexed ?? this.ocrIndexed,
    polling: polling ?? this.polling,
  );
}

class DocumentScanCaptureCard extends StatelessWidget {
  const DocumentScanCaptureCard({
    super.key,
    required this.capabilities,
    required this.baseDir,
    required this.boundRootName,
    required this.selectedCategory,
    required this.noteController,
    required this.pendingLocalPaths,
    required this.archiving,
    required this.blocked,
    required this.statusMessage,
    required this.onSelectCategory,
    required this.onCapture,
    required this.onRemovePendingIndex,
    required this.onUploadAndTriggerOcr,
  });

  final DocumentScannerCapabilities capabilities;
  final String baseDir;
  final String? boundRootName;
  final String selectedCategory;
  final TextEditingController noteController;
  final List<String> pendingLocalPaths;
  final bool archiving;
  final bool blocked;
  final String? statusMessage;
  final ValueChanged<String> onSelectCategory;
  final ValueChanged<String> onCapture;
  final ValueChanged<int> onRemovePendingIndex;
  final VoidCallback onUploadAndTriggerOcr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final scanLabel = capabilities.scanner
        ? '扫描票据（VisionKit）'
        : capabilities.camera
        ? '拍照扫票据'
        : '选择票据图片';
    final rootPrefix =
        boundRootName != null && boundRootName!.isNotEmpty
            ? '[$boundRootName] '
            : '';
    final targetDisplay = baseDir.isEmpty
        ? '家庭档案/$selectedCategory/'
        : '$baseDir/家庭档案/$selectedCategory/';

    return IsleSurface(
      margin: EdgeInsets.zero,
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
                      blocked
                          ? '目标照片硬盘不可用，已暂停归档'
                          : '存入 $rootPrefix$targetDisplay 并插队离线 OCR',
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
                  selected: selectedCategory == cat,
                  onSelected: archiving || blocked
                      ? null
                      : (_) => onSelectCategory(cat),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('archiveNoteField'),
            controller: noteController,
            enabled: !archiving && !blocked,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: '归档备注（可选）',
              hintText: '例如：空调保修卡、医保报销发票、身份证复印件…',
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
                onPressed: archiving || blocked
                    ? null
                    : () => onCapture(
                        capabilities.scanner
                            ? 'scanner'
                            : capabilities.camera
                            ? 'camera'
                            : 'picker',
                      ),
                icon: const Icon(Icons.document_scanner_outlined, size: 17),
                label: Text(scanLabel),
              ),
              OutlinedButton.icon(
                key: const ValueKey('documentPickImagesButton'),
                onPressed: archiving || blocked
                    ? null
                    : () => onCapture('picker'),
                icon: const Icon(Icons.photo_library_outlined, size: 17),
                label: const Text('相册/文件选图'),
              ),
            ],
          ),
          if (pendingLocalPaths.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '待归档页面（${pendingLocalPaths.length} 页）',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < pendingLocalPaths.length; i++)
                  InputChip(
                    avatar: const Icon(Icons.image_outlined, size: 16),
                    label: Text(
                      '第 ${i + 1} 页 · ${pendingLocalPaths[i].replaceAll('\\', '/').split('/').last}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    onDeleted: archiving
                        ? null
                        : () => onRemovePendingIndex(i),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('uploadAndOcrButton'),
              onPressed: archiving || blocked ? null : onUploadAndTriggerOcr,
              icon: archiving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onPrimary,
                      ),
                    )
                  : const Icon(Icons.cloud_upload_outlined, size: 18),
              label: Text(statusMessage ?? '上传归档并优先 Vision OCR 识别'),
            ),
          ] else if (statusMessage != null) ...[
            const SizedBox(height: 10),
            Text(statusMessage!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class DocumentScanLatestOcrCard extends StatelessWidget {
  const DocumentScanLatestOcrCard({
    super.key,
    required this.result,
    required this.onCopyText,
    required this.onRefreshPoll,
  });

  final ArchivedScanItem result;
  final Future<void> Function(String text) onCopyText;
  final VoidCallback onRefreshPoll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    return IsleSurface(
      key: const ValueKey('latestOcrResultCard'),
      margin: EdgeInsets.zero,
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
                  onPressed: () => unawaited(onCopyText(result.ocrText)),
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('一键复制'),
                )
              else if (!result.polling && result.assetId > 0)
                TextButton(
                  onPressed: onRefreshPoll,
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
              decoration: IsleDecorations.recessedWell(
                context,
                radius: IsleRadius.sm,
              ),
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
}

class DocumentArchiveAssetTile extends StatelessWidget {
  const DocumentArchiveAssetTile({
    super.key,
    required this.api,
    required this.item,
    required this.category,
    required this.onTap,
  });

  final LightIsleApi api;
  final PhotoAsset item;
  final String category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: IsleSurface(
        key: ValueKey('archiveAssetCard-${item.id}'),
        margin: EdgeInsets.zero,
        radius: IsleRadius.item,
        padding: const EdgeInsets.all(10),
        onTap: onTap,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(IsleRadius.sm),
              child: SizedBox(
                width: 56,
                height: 56,
                child: AuthenticatedMediaImage(
                  api: api,
                  memoryCache: IsleCacheManager.instance.sharedThumbnails,
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
                    '$category · ${formatMediaDate(item.takenAt)} · ${formatMediaSize(item.size)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette['textSecondary'],
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: palette['textTertiary']),
          ],
        ),
      ),
    );
  }
}
