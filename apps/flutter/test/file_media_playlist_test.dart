import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/files/file_media_playlist.dart';
import 'package:lightisle/features/files/file_models.dart';

FileEntry mediaEntry(
  String path, {
  bool folder = false,
  bool writable = false,
  DateTime? modified,
}) => FileEntry(
  name: path.split('/').last,
  path: path,
  type: folder ? 'folder' : 'file',
  size: 100,
  modified: modified,
  canWrite: writable,
);

void main() {
  test(
    'media playlist reuses ordered file entries and keeps read permissions',
    () {
      final modified = DateTime.utc(2026, 11, 1);
      final playlist = FileMediaPlaylist.fromDirectory([
        mediaEntry('album/picture.jpg', writable: false, modified: modified),
        mediaEntry('album/doc.txt'),
        mediaEntry('album/movie.mp4', writable: true),
        mediaEntry('album/subfolder', folder: true),
      ], mediaEntry('album/movie.mp4', writable: true));
      expect(playlist.assets.map((asset) => asset.path), [
        'album/picture.jpg',
        'album/movie.mp4',
      ]);
      expect(playlist.initialIndex, 1);
      expect(playlist.assets.first.isVideo, false);
      expect(playlist.assets.first.canWrite, false);
      expect(
        playlist.assets.first.takenAt,
        modified.millisecondsSinceEpoch ~/ 1000,
      );
      expect(playlist.assets.last.isVideo, true);
      expect(playlist.assets.last.canWrite, true);
      expect(() => playlist.assets.clear(), throwsUnsupportedError);
    },
  );

  test(
    'media not present in current page is prepended to its own playlist',
    () {
      final playlist = FileMediaPlaylist.fromDirectory([
        mediaEntry('a.png'),
        mediaEntry('b.mov'),
      ], mediaEntry('not-loaded.mp4'));
      expect(playlist.initialIndex, 0);
      expect(playlist.assets.map((asset) => asset.path), [
        'not-loaded.mp4',
        'a.png',
        'b.mov',
      ]);
    },
  );
}
