import '../../core/lightisle_api.dart';
import 'media_models.dart';

/// Shared albums are managed by administrators, whereas private albums are
/// always scoped by the server to the current signed-in account.
enum PhotoAlbumScope { shared, personal }

class PhotoAlbumBatchResult {
  const PhotoAlbumBatchResult({
    required this.completed,
    required this.cancelled,
    this.error,
  });

  final int completed;
  final bool cancelled;
  final Object? error;
}

class PhotoAlbumRepository {
  const PhotoAlbumRepository(this.api);

  final LightIsleApi api;

  String _collection(PhotoAlbumScope scope) => scope == PhotoAlbumScope.shared
      ? '/api/v2/photos/albums'
      : '/api/v2/photos/private-albums';

  Future<List<MediaAlbum>> list(PhotoAlbumScope scope) async {
    final response = await api.get(_collection(scope));
    final raw = response['albums'];
    if (raw is! List) return const <MediaAlbum>[];
    return List.unmodifiable(
      raw.whereType<Map>().map(
        (item) => MediaAlbum.fromJson(Map<String, dynamic>.from(item)),
      ),
    );
  }

  /// A selected batch is tied to the original account and physical disk.
  /// Recheck before each write: a root switch must not continue mutating a
  /// similarly named album on another disk.
  Future<PhotoAlbumBatchResult> addManyToPrivateAlbum({
    required int albumId,
    required Iterable<int> assetIds,
    required bool Function() stillCurrent,
  }) async {
    final ids = List<int>.unmodifiable(assetIds);
    if (albumId < 1 ||
        ids.isEmpty ||
        ids.length > 50 ||
        ids.any((id) => id < 1)) {
      throw ArgumentError('Select 1–50 valid photos and one private album');
    }
    var completed = 0;
    for (final id in ids) {
      if (!stillCurrent()) {
        return PhotoAlbumBatchResult(completed: completed, cancelled: true);
      }
      try {
        await addItem(PhotoAlbumScope.personal, albumId: albumId, assetId: id);
        completed++;
      } catch (error) {
        return PhotoAlbumBatchResult(
          completed: completed,
          cancelled: false,
          error: error,
        );
      }
    }
    return PhotoAlbumBatchResult(completed: completed, cancelled: false);
  }

  Future<void> save(
    PhotoAlbumScope scope, {
    required String name,
    int? albumId,
  }) async {
    if (albumId != null && albumId < 1) {
      throw ArgumentError.value(albumId, 'albumId', 'Invalid album ID');
    }
    await api.send(
      albumId == null ? 'POST' : 'PATCH',
      albumId == null ? _collection(scope) : '${_collection(scope)}/$albumId',
      body: <String, String>{'name': name},
    );
  }

  /// Deleting an album only deletes the collection and its associations,
  /// never the underlying media files.
  Future<void> delete(PhotoAlbumScope scope, int albumId) async {
    if (albumId < 1) {
      throw ArgumentError.value(albumId, 'albumId', 'Invalid album ID');
    }
    await api.send('DELETE', '${_collection(scope)}/$albumId');
  }

  Future<void> addItem(
    PhotoAlbumScope scope, {
    required int albumId,
    required int assetId,
  }) async {
    _checkIDs(albumId, assetId);
    await api.send(
      'POST',
      '${_collection(scope)}/$albumId/items',
      body: <String, int>{'assetId': assetId},
    );
  }

  Future<void> removeItem(
    PhotoAlbumScope scope, {
    required int albumId,
    required int assetId,
  }) async {
    _checkIDs(albumId, assetId);
    await api.send('DELETE', '${_collection(scope)}/$albumId/items/$assetId');
  }

  static void _checkIDs(int albumId, int assetId) {
    if (albumId < 1 || assetId < 1) {
      throw ArgumentError('Album and media IDs must be positive');
    }
  }
}
