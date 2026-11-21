import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'file_models.dart';

final RegExp _fileThumbnailExtensions = RegExp(
  r'\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$',
  caseSensitive: false,
);

String fileExtensionLower(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool isFileThumbnailEligible(String name) =>
    _fileThumbnailExtensions.hasMatch(name);

String fileRelativeParentLabel(String path) {
  final slash = path.lastIndexOf('/');
  if (slash <= 0) return '根目录';
  return path.substring(0, slash);
}

String fileKindLabel(FileEntry item) {
  if (item.isFolder) return '文件夹';
  final ext = fileExtensionLower(item.name);
  if (ext.isEmpty) return '文稿';
  return switch (ext) {
    'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' =>
      '${ext.toUpperCase()} 图像',
    'mp4' || 'mov' || 'm4v' || 'webm' || 'mkv' => '${ext.toUpperCase()} 影片',
    'mp3' || 'flac' || 'wav' || 'm4a' || 'aac' => '${ext.toUpperCase()} 音频',
    'pdf' => 'PDF 文稿',
    'zip' || '7z' || 'rar' || 'tar' || 'gz' || 'dmg' =>
      '${ext.toUpperCase()} 归档',
    _ => '${ext.toUpperCase()} 文件',
  };
}

/// Static folder/file type icon badge used in list rows, cards, and fallback slots.
class FileBadgeIcon extends StatelessWidget {
  const FileBadgeIcon({super.key, required this.item});

  final FileEntry item;

  @override
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final isBrutal =
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final badgeRadius = style.borderRadiusFor(IsleRadius.sm);
    if (item.isFolder) {
      final folderTint = palette['brandAmber'];
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: badgeRadius,
          color: folderTint.withValues(alpha: isBrutal ? 0.22 : 0.14),
          border: Border.all(
            color: isBrutal
                ? style.rimBorderColor()
                : folderTint.withValues(alpha: 0.24),
            width: isBrutal ? 1.5 : 0.85,
          ),
        ),
        child: Icon(Icons.folder_rounded, color: folderTint, size: 19),
      );
    }

    final ext = fileExtensionLower(item.name);
    final (Color tint, IconData icon) = switch (ext) {
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'heic' => (palette['brandRose'], Icons.image_rounded),
      'mp4' ||
      'mov' ||
      'm4v' ||
      'webm' ||
      'mkv' => (palette['brandViolet'], Icons.movie_rounded),
      'mp3' ||
      'flac' ||
      'wav' ||
      'm4a' ||
      'aac' => (palette['brandTerracotta'], Icons.music_note_rounded),
      'pdf' => (
        Theme.of(context).colorScheme.error,
        Icons.picture_as_pdf_rounded,
      ),
      'zip' ||
      '7z' ||
      'rar' ||
      'tar' ||
      'gz' ||
      'dmg' => (palette['brandBlue'], Icons.archive_rounded),
      'txt' ||
      'md' ||
      'log' ||
      'json' ||
      'yaml' ||
      'xml' ||
      'ts' ||
      'js' ||
      'swift' ||
      'go' => (palette['brandSage'], Icons.description_rounded),
      _ => (
        Theme.of(context).colorScheme.onSurfaceVariant,
        Icons.insert_drive_file_rounded,
      ),
    };

    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: tint.withValues(alpha: 0.13),
        border: Border.all(color: tint.withValues(alpha: 0.18), width: 0.85),
      ),
      child: Icon(icon, color: tint, size: 18),
    );
  }
}

/// File entry badge that renders a bounded authenticated thumbnail when
/// eligible, falling back to [FileBadgeIcon].
class FileEntryBadge extends StatelessWidget {
  const FileEntryBadge({
    super.key,
    required this.api,
    required this.item,
    required this.failedThumbnails,
  });

  final LightIsleApi api;
  final FileEntry item;
  final Set<String> failedThumbnails;

  @override
  Widget build(BuildContext context) {
    if (item.isFolder || !isFileThumbnailEligible(item.name)) {
      return FileBadgeIcon(item: item);
    }
    final key = '${item.path}@${item.modified}';
    if (failedThumbnails.contains(key)) return FileBadgeIcon(item: item);
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(
        width: 34,
        height: 34,
        child: AuthenticatedMediaImage(
          api: api,
          path: '/api/v2/files/thumbnail',
          query: {'path': item.path, 'size': '512'},
          maxBytes: 4 * 1024 * 1024,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) {
            failedThumbnails.add(key);
            return FileBadgeIcon(item: item);
          },
        ),
      ),
    );
  }
}

/// Cover artwork rendered inside file grid cards and desktop quick inspector.
class FileCardCover extends StatelessWidget {
  const FileCardCover({
    super.key,
    required this.api,
    required this.item,
    required this.failedThumbnails,
  });

  final LightIsleApi api;
  final FileEntry item;
  final Set<String> failedThumbnails;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    if (item.isFolder) {
      final folderTint = palette['brandAmber'];
      return ColoredBox(
        color: folderTint.withValues(alpha: 0.10),
        child: Center(
          child: Icon(Icons.folder_rounded, size: 46, color: folderTint),
        ),
      );
    }
    final thumbnailKey = '${item.path}@${item.modified}';
    if (!isFileThumbnailEligible(item.name) ||
        failedThumbnails.contains(thumbnailKey)) {
      return ColoredBox(
        color: palette['cardItemBottom'],
        child: Center(child: FileBadgeIcon(item: item)),
      );
    }
    return AuthenticatedMediaImage(
      api: api,
      path: '/api/v2/files/thumbnail',
      query: {'path': item.path, 'size': '512'},
      maxBytes: 4 * 1024 * 1024,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) {
        failedThumbnails.add(thumbnailKey);
        return Center(child: FileBadgeIcon(item: item));
      },
    );
  }
}

/// Desktop file table header bar.
class FileDesktopColumnHeader extends StatelessWidget {
  const FileDesktopColumnHeader({super.key, required this.selecting});

  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: colors.onSurfaceVariant,
      letterSpacing: 0.2,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      color: palette['cardItemBottom'].withValues(alpha: 0.72),
      child: Row(
        children: [
          if (selecting) const SizedBox(width: 34),
          const SizedBox(width: 42),
          Expanded(flex: 6, child: Text('名称', style: headerStyle)),
          SizedBox(width: 110, child: Text('种类', style: headerStyle)),
          SizedBox(
            width: 96,
            child: Text(
              '大小',
              textAlign: TextAlign.right,
              style: headerStyle,
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(width: 144, child: Text('修改时间', style: headerStyle)),
          const SizedBox(width: 44),
        ],
      ),
    );
  }
}

/// Desktop side inspector card for a single selected file or folder.
class FileDesktopSelectionInspector extends StatelessWidget {
  const FileDesktopSelectionInspector({
    super.key,
    required this.api,
    required this.item,
    required this.writable,
    required this.failedThumbnails,
    required this.onOpenOrPreview,
    required this.onDownload,
    required this.onShare,
  });

  final LightIsleApi api;
  final FileEntry item;
  final bool writable;
  final Set<String> failedThumbnails;
  final VoidCallback onOpenOrPreview;
  final VoidCallback onDownload;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      tint: palette['brandAmber'],
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'QUICK INSPECTOR',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: palette['brandAmber'],
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: 132,
              child: FileCardCover(
                api: api,
                item: item,
                failedThumbnails: failedThumbnails,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            fileKindLabel(item),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          IsleKeyValueRow(
            label: '大小',
            value: item.isFolder ? '文件夹' : formatBytes(item.size),
          ),
          IsleKeyValueRow(
            label: '修改于',
            value: item.modified == null ? '未知' : formatDateTime(item.modified!),
          ),
          IsleKeyValueRow(
            label: '所在位置',
            value: fileRelativeParentLabel(item.path),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onOpenOrPreview,
                icon: Icon(
                  item.isFolder
                      ? Icons.folder_open_rounded
                      : Icons.visibility_outlined,
                  size: 16,
                ),
                label: Text(item.isFolder ? '进入目录' : '预览'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onDownload,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('下载'),
              ),
              if (writable)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onShare,
                  icon: const Icon(Icons.ios_share_outlined, size: 16),
                  label: const Text('分享'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
