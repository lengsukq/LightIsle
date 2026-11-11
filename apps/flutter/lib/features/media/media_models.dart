part 'cinema_models.dart';

typedef MediaJson = Map<String, dynamic>;

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

/// iOS Live Photos are backed up as the original still and a separate
/// companion MOV. Only link a UNIQUE same-folder, same-stem motion file with
/// a near-identical capture timestamp; do not guess across unrelated photos.
PhotoAsset? livePhotoMotionFor(PhotoAsset still, List<PhotoAsset> items) {
  if (still.isVideo ||
      !RegExp(
        r'\.(heic|heif|jpg|jpeg)$',
        caseSensitive: false,
      ).hasMatch(still.name)) {
    return null;
  }
  final dot = still.path.lastIndexOf('.');
  if (dot < 0) return null;
  final stem = still.path.substring(0, dot).toLowerCase();
  final candidates = items
      .where(
        (asset) =>
            asset.isVideo &&
            RegExp(r'\.mov$', caseSensitive: false).hasMatch(asset.path) &&
            asset.path
                    .substring(0, asset.path.lastIndexOf('.'))
                    .toLowerCase() ==
                stem &&
            (asset.takenAt - still.takenAt).abs() <= 15,
      )
      .toList();
  return candidates.length == 1 ? candidates.single : null;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

double? _asNullableDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return value?.toString().toLowerCase() == 'true';
}

String _asString(Object? value) => value?.toString() ?? '';

class PhotoAsset {
  const PhotoAsset({
    required this.id,
    required this.path,
    required this.name,
    required this.type,
    required this.size,
    required this.takenAt,
    required this.favorite,
    this.personalFavorite = false,
    required this.canWrite,
    this.probeStatus = '',
    this.browserPlayback = '',
    this.mime = '',
    this.container = '',
    this.videoCodec = '',
    this.audioCodec = '',
    this.durationSeconds = 0,
    this.width = 0,
    this.height = 0,
    this.orientation = 0,
    this.capturedAt = '',
    this.latitude,
    this.longitude,
    this.cameraMake = '',
    this.cameraModel = '',
    this.lensModel = '',
    this.iso = 0,
    this.fNumber = 0,
    this.exposureSeconds = 0,
    this.focalLength = 0,
  });

  final int id;
  final String path;
  final String name;
  final String type;
  final int size;
  final int takenAt;
  final bool favorite;
  final bool personalFavorite;
  final bool canWrite;
  final String probeStatus;
  final String browserPlayback;
  final String mime;
  final String container;
  final String videoCodec;
  final String audioCodec;
  final double durationSeconds;
  final int width;
  final int height;
  final int orientation;
  final String capturedAt;
  final double? latitude;
  final double? longitude;
  final String cameraMake;
  final String cameraModel;
  final String lensModel;
  final int iso;
  final double fNumber;
  final double exposureSeconds;
  final double focalLength;

  bool get isVideo => type.toLowerCase() == 'video';

  /// Display aspect ratio corrected for EXIF orientation (5-8 rotate 90° or 270°).
  double? get displayAspectRatio {
    if (width <= 0 || height <= 0) return null;
    final rotated = orientation >= 5 && orientation <= 8;
    final w = rotated ? height : width;
    final h = rotated ? width : height;
    if (w <= 0 || h <= 0) return null;
    return w / h;
  }

  /// Proprietary RAW originals are indexed and downloadable, but Flutter's
  /// standard image codecs cannot promise to decode them on every platform.
  bool get isRaw => RegExp(
    r'\.(dng|cr2|cr3|nef|arw|raf|rw2|orf|pef)$',
    caseSensitive: false,
  ).hasMatch(name);

  factory PhotoAsset.fromJson(MediaJson json) {
    final id = _asInt(json['id']);
    if (id < 1) throw const FormatException('Invalid photo asset id');
    return PhotoAsset(
      id: id,
      path: _asString(json['path']),
      name: _asString(json['name']),
      type: _asString(json['type']),
      size: _asInt(json['size']),
      takenAt: _asInt(json['takenAt']),
      favorite: _asBool(json['favorite']),
      personalFavorite: _asBool(json['personalFavorite']),
      // Missing write hints fail closed for members. Admins have a separate
      // role capability in the UI.
      canWrite: _asBool(json['canWrite']),
      probeStatus: _asString(json['probeStatus']),
      browserPlayback: _asString(json['browserPlayback']),
      mime: _asString(json['mime']),
      container: _asString(json['container']),
      videoCodec: _asString(json['videoCodec']),
      audioCodec: _asString(json['audioCodec']),
      durationSeconds: _asDouble(json['durationSeconds']),
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      orientation: _asInt(json['orientation']),
      capturedAt: _asString(json['capturedAt']),
      latitude: _asNullableDouble(json['latitude']),
      longitude: _asNullableDouble(json['longitude']),
      cameraMake: _asString(json['cameraMake']),
      cameraModel: _asString(json['cameraModel']),
      lensModel: _asString(json['lensModel']),
      iso: _asInt(json['iso']),
      fNumber: _asDouble(json['fNumber']),
      exposureSeconds: _asDouble(json['exposureSeconds']),
      focalLength: _asDouble(json['focalLength']),
    );
  }

  PhotoAsset withFavorite(bool value) => PhotoAsset(
    id: id,
    path: path,
    name: name,
    type: type,
    size: size,
    takenAt: takenAt,
    favorite: value,
    personalFavorite: personalFavorite,
    canWrite: canWrite,
    probeStatus: probeStatus,
    browserPlayback: browserPlayback,
    mime: mime,
    container: container,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    durationSeconds: durationSeconds,
    width: width,
    height: height,
    orientation: orientation,
    capturedAt: capturedAt,
    latitude: latitude,
    longitude: longitude,
    cameraMake: cameraMake,
    cameraModel: cameraModel,
    lensModel: lensModel,
    iso: iso,
    fNumber: fNumber,
    exposureSeconds: exposureSeconds,
    focalLength: focalLength,
  );

  PhotoAsset withPersonalFavorite(bool value) => PhotoAsset(
    id: id,
    path: path,
    name: name,
    type: type,
    size: size,
    takenAt: takenAt,
    favorite: favorite,
    personalFavorite: value,
    canWrite: canWrite,
    probeStatus: probeStatus,
    browserPlayback: browserPlayback,
    mime: mime,
    container: container,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    durationSeconds: durationSeconds,
    width: width,
    height: height,
    orientation: orientation,
    capturedAt: capturedAt,
    latitude: latitude,
    longitude: longitude,
    cameraMake: cameraMake,
    cameraModel: cameraModel,
    lensModel: lensModel,
    iso: iso,
    fNumber: fNumber,
    exposureSeconds: exposureSeconds,
    focalLength: focalLength,
  );
}

class MediaAlbum {
  const MediaAlbum({
    required this.id,
    required this.name,
    required this.count,
    this.coverAssetId = 0,
  });

  final int id;
  final String name;
  final int count;

  /// Zero means no visible asset is available as a cover.
  final int coverAssetId;

  factory MediaAlbum.fromJson(MediaJson json) => MediaAlbum(
    id: _asInt(json['id']),
    name: _asString(json['name']),
    count: _asInt(json['count']),
    coverAssetId: _asInt(json['coverAssetId']),
  );
}

class MediaScanStatus {
  const MediaScanStatus({
    this.running = false,
    this.operation = '',
    this.scanned = 0,
    this.visited = 0,
    this.found = 0,
    this.lastDone = 0,
    this.lastError = '',
  });

  final bool running;
  final String operation;
  final int scanned;
  final int visited;
  final int found;
  final int lastDone;
  final String lastError;

  factory MediaScanStatus.fromJson(Object? value) {
    if (value is! Map) return const MediaScanStatus();
    final json = Map<String, dynamic>.from(value);
    return MediaScanStatus(
      running: _asBool(json['running']),
      operation: _asString(json['operation']),
      scanned: _asInt(json['scanned']),
      visited: _asInt(json['visited']),
      found: _asInt(json['found']),
      lastDone: _asInt(json['lastDone']),
      lastError: _asString(json['lastError']),
    );
  }
}
