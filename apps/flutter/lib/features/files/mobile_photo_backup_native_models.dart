/// Data models for native `lightisle/photos` channel inspections, pagination,
/// and OS-confirmed asset deletions.
class PausePhotoBackupException implements Exception {
  const PausePhotoBackupException();
}

class NativeStreamInspection {
  const NativeStreamInspection({
    required this.size,
    required this.modified,
    required this.generation,
    required this.digest,
    required this.chunkDigests,
  });

  final int size;
  final int modified;
  final int generation;
  final String digest;
  final List<String> chunkDigests;
}

class NativePhotoDeleteResult {
  const NativePhotoDeleteResult({
    required this.deleted,
    required this.cancelled,
    required this.deletedCount,
    required this.alreadyMissingCount,
    this.deletedAssetIds = const <String>[],
  });

  final bool deleted;
  final bool cancelled;
  final int deletedCount;
  final int alreadyMissingCount;
  final List<String> deletedAssetIds;
}

class NativeIosAssetInspection {
  const NativeIosAssetInspection({
    required this.exists,
    required this.modificationDateMs,
    required this.assetGeneration,
    required this.generations,
    required this.hasPhoto,
    required this.hasRaw,
    required this.hasLiveVideo,
    required this.hasVideo,
    required this.requiredAssetIds,
  });

  final bool exists;
  final int modificationDateMs;
  final int assetGeneration;
  final Map<String, int> generations;
  final bool hasPhoto;
  final bool hasRaw;
  final bool hasLiveVideo;
  final bool hasVideo;
  final List<String> requiredAssetIds;

  static NativeIosAssetInspection fromMap(Map<String, dynamic> raw) {
    final rawGens = raw['generations'];
    final generations = <String, int>{};
    if (rawGens is Map) {
      rawGens.forEach((key, value) {
        final k = key?.toString().trim() ?? '';
        if (k.isNotEmpty && value is num) {
          generations[k] = value.toInt();
        }
      });
    }
    final rawRequired = raw['requiredAssetIds'];
    final requiredAssetIds = rawRequired is List
        ? rawRequired
              .map((e) => e?.toString().trim() ?? '')
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return NativeIosAssetInspection(
      exists: raw['exists'] == true,
      modificationDateMs: (raw['modificationDate'] as num?)?.toInt() ?? 0,
      assetGeneration: (raw['assetGeneration'] as num?)?.toInt() ?? 0,
      generations: generations,
      hasPhoto: raw['hasPhoto'] == true,
      hasRaw: raw['hasRaw'] == true,
      hasLiveVideo: raw['hasLiveVideo'] == true,
      hasVideo: raw['hasVideo'] == true,
      requiredAssetIds: requiredAssetIds,
    );
  }
}

class PhotoPageResponse {
  const PhotoPageResponse({
    required this.supportsStream,
    required this.rows,
    required this.omittedItems,
    required this.storeVersionID,
    required this.oversizedCount,
    required this.invalidCount,
    required this.nextCursor,
  });

  final bool supportsStream;
  final List<Map<String, dynamic>> rows;
  final Iterable<Map<String, dynamic>> omittedItems;
  final String storeVersionID;
  final int oversizedCount;
  final int invalidCount;
  final String nextCursor;
}
