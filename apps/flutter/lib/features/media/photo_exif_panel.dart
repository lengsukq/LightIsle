import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Lightroom-style EXIF & technical inspection panel shared between the full-
/// screen viewer sidebar and the detailed metadata sheet.
class PhotoExifPanel extends StatelessWidget {
  const PhotoExifPanel({
    super.key,
    required this.asset,
    this.darkOverlay = false,
  });

  final PhotoAsset asset;
  final bool darkOverlay;

  String get _capturedLabel {
    if (asset.capturedAt.isNotEmpty) {
      final parsed = DateTime.tryParse(asset.capturedAt);
      if (parsed != null) return parsed.toLocal().toString().split('.').first;
    }
    return formatMediaDate(asset.takenAt);
  }

  List<String> get _parameterBadges => [
    if (asset.focalLength > 0) '${asset.focalLength.round()} mm',
    if (asset.fNumber > 0)
      'f/${asset.fNumber < 10 ? asset.fNumber.toStringAsFixed(1) : asset.fNumber.round()}',
    if (asset.exposureSeconds > 0)
      asset.exposureSeconds >= 1
          ? '${asset.exposureSeconds.toStringAsFixed(1)}s'
          : '1/${(1 / asset.exposureSeconds).round()}s',
    if (asset.iso > 0) 'ISO ${asset.iso}',
    if (asset.isLivePhoto) '实况照片',
    if (asset.isRaw) 'RAW 原片',
    if (asset.isVideo && asset.durationSeconds > 0)
      formatMediaSeconds(asset.durationSeconds),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final primaryText = darkOverlay ? Colors.white : scheme.onSurface;
    final secondaryText = darkOverlay
        ? Colors.white70
        : scheme.onSurfaceVariant;
    final cardColor = darkOverlay
        ? Colors.white.withValues(alpha: 0.06)
        : (isDark
              ? Colors.white.withValues(alpha: 0.035)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.30));
    final borderColor = darkOverlay
        ? Colors.white.withValues(alpha: 0.14)
        : IsleGlass.rimBorderColor(isDark);

    final cameraLine = [
      asset.cameraMake.trim(),
      asset.cameraModel.trim(),
    ].where((s) => s.isNotEmpty).join(' ');

    final rows = <(IconData, String, String)>[
      (Icons.event_outlined, '拍摄时间', _capturedLabel),
      (Icons.storage_outlined, '文件大小', formatMediaSize(asset.size)),
      if (asset.width > 0 && asset.height > 0)
        (
          Icons.aspect_ratio_outlined,
          '画面尺寸',
          '${asset.width} × ${asset.height}',
        ),
      if (asset.isVideo && asset.durationSeconds > 0)
        (
          Icons.schedule_outlined,
          '视频时长',
          formatMediaSeconds(asset.durationSeconds),
        ),
      if (asset.container.isNotEmpty || asset.videoCodec.isNotEmpty)
        (
          Icons.movie_outlined,
          '容器与编码',
          [
            asset.container,
            asset.videoCodec,
            asset.audioCodec,
          ].where((s) => s.isNotEmpty).join(' · '),
        ),
      if (asset.latitude != null && asset.longitude != null)
        (
          Icons.place_outlined,
          '地理坐标',
          '${asset.latitude!.abs().toStringAsFixed(5)}°'
              '${asset.latitude! >= 0 ? 'N' : 'S'}, '
              '${asset.longitude!.abs().toStringAsFixed(5)}°'
              '${asset.longitude! >= 0 ? 'E' : 'W'}',
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cameraLine.isNotEmpty || asset.lensModel.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 1.0),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.photo_camera_outlined,
                  size: 17,
                  color: darkOverlay ? const Color(0xFF9CDCF5) : scheme.primary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (cameraLine.isNotEmpty)
                        Text(
                          cameraLine,
                          style: TextStyle(
                            color: primaryText,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      if (asset.lensModel.isNotEmpty) ...[
                        const SizedBox(height: 1.5),
                        Text(
                          asset.lensModel,
                          style: TextStyle(
                            color: secondaryText,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (_parameterBadges.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final badge in _parameterBadges)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: borderColor, width: 1.0),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: primaryText,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1.0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: borderColor),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7.5,
                  ),
                  child: Row(
                    children: [
                      Icon(rows[i].$1, size: 15.5, color: secondaryText),
                      const SizedBox(width: 8),
                      Text(
                        rows[i].$2,
                        style: TextStyle(color: secondaryText, fontSize: 12),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          rows[i].$3,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: primaryText,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (asset.path.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 1.0),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 15, color: secondaryText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    asset.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: secondaryText,
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制文件路径',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 26,
                  ),
                  padding: EdgeInsets.zero,
                  color: secondaryText,
                  iconSize: 14.5,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: asset.path));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制文件路径'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Wide-desktop right sidebar in [PhotoGalleryViewer] toggled by `I` or the
/// toolbar info icon.
class PhotoViewerInfoSidebar extends StatelessWidget {
  const PhotoViewerInfoSidebar({
    super.key,
    required this.asset,
    required this.onClose,
    this.onOpenFullDetails,
  });

  final PhotoAsset asset;
  final VoidCallback onClose;
  final VoidCallback? onOpenFullDetails;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(18),
        bottomLeft: Radius.circular(18),
      ),
      child: IsleGlassBackdrop(
        blur: 22,
        child: Container(
          width: 320,
          padding: EdgeInsets.fromLTRB(14, safe.top + 12, 14, safe.bottom + 14),
          decoration: BoxDecoration(
            color: const Color(0xE010151E),
            border: Border(
              left: BorderSide(
                color: Colors.white.withValues(alpha: 0.16),
                width: 1.0,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '照片与 EXIF 信息',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '收起信息栏 (Esc / I)',
                    color: Colors.white70,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 19),
                  ),
                ],
              ),
              Text(
                asset.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: PhotoExifPanel(asset: asset, darkOverlay: true),
                ),
              ),
              if (onOpenFullDetails != null) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.24),
                      width: 1.0,
                    ),
                  ),
                  onPressed: onOpenFullDetails,
                  icon: const Icon(Icons.photo_album_outlined, size: 17),
                  label: const Text('相册管理与人物场景标签'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
