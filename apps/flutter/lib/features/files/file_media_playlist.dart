import '../media/media_models.dart';
import 'file_models.dart';
import 'file_preview_support.dart';

/// Snapshot of the folder's media, reused by the same gallery viewer as
/// Photos. No extra media player or playlist state is maintained by Files.
final class FileMediaPlaylist {
  FileMediaPlaylist._(this.assets, this.initialIndex);

  final List<PhotoAsset> assets;
  final int initialIndex;

  static FileMediaPlaylist fromDirectory(
    List<FileEntry> loaded,
    FileEntry initial,
  ) {
    final entries = <FileEntry>[
      for (final file in loaded)
        if (!file.isFolder && _isMedia(file.name)) file,
    ];
    if (!entries.any((item) => item.path == initial.path)) {
      entries.insert(0, initial);
    }
    final assets = <PhotoAsset>[
      for (var i = 0; i < entries.length; i++)
        PhotoAsset(
          id: i + 1,
          path: entries[i].path,
          name: entries[i].name,
          type: classifyFilePreview(entries[i].name) == FilePreviewKind.video
              ? 'video'
              : 'photo',
          size: entries[i].size,
          takenAt: (entries[i].modified?.millisecondsSinceEpoch ?? 0) ~/ 1000,
          favorite: false,
          canWrite: entries[i].canWrite,
        ),
    ];
    return FileMediaPlaylist._(
      List.unmodifiable(assets),
      assets.indexWhere((asset) => asset.path == initial.path),
    );
  }

  static bool _isMedia(String name) {
    final kind = classifyFilePreview(name);
    return kind == FilePreviewKind.image || kind == FilePreviewKind.video;
  }
}
