typedef MediaJson = Map<String, dynamic>;

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
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

  bool get isVideo => type.toLowerCase() == 'video';

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
  );
}

class MediaAlbum {
  const MediaAlbum({required this.id, required this.name, required this.count});

  final int id;
  final String name;
  final int count;

  factory MediaAlbum.fromJson(MediaJson json) => MediaAlbum(
    id: _asInt(json['id']),
    name: _asString(json['name']),
    count: _asInt(json['count']),
  );
}

class MediaScanStatus {
  const MediaScanStatus({
    this.running = false,
    this.scanned = 0,
    this.visited = 0,
    this.found = 0,
    this.lastDone = 0,
    this.lastError = '',
  });

  final bool running;
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
      scanned: _asInt(json['scanned']),
      visited: _asInt(json['visited']),
      found: _asInt(json['found']),
      lastDone: _asInt(json['lastDone']),
      lastError: _asString(json['lastError']),
    );
  }
}

class CinemaFilm {
  const CinemaFilm({
    required this.id,
    required this.title,
    required this.path,
    required this.kind,
    required this.series,
    required this.season,
    required this.episode,
    required this.year,
    required this.size,
    required this.playable,
    required this.mime,
    required this.probeStatus,
    required this.browserPlayback,
    required this.container,
    required this.videoCodec,
    required this.audioCodec,
    required this.durationSeconds,
    required this.width,
    required this.height,
    required this.position,
    required this.duration,
    required this.completed,
    this.capturedAt = '',
    this.overview = '',
    this.rating = 0,
    this.metadataSource = '',
    this.posterURL = '',
  });

  final int id;
  final String title;
  final String path;
  final String kind;
  final String series;
  final int season;
  final int episode;
  final int year;
  final int size;
  final bool playable;
  final String mime;
  final String probeStatus;
  final String browserPlayback;
  final String container;
  final String videoCodec;
  final String audioCodec;
  final double durationSeconds;
  final int width;
  final int height;
  final double position;
  final double duration;
  final bool completed;
  final String capturedAt;
  final String overview;
  final double rating;
  final String metadataSource;
  final String posterURL;

  bool get isSeries => kind.toLowerCase() == 'series';
  bool get canAttemptPlayback => browserPlayback != 'download-only' && playable;
  bool get canResume => position > 5 && !completed;

  factory CinemaFilm.fromJson(MediaJson json) {
    final id = _asInt(json['id']);
    if (id < 1) throw const FormatException('Invalid cinema film id');
    final playback = _asString(json['browserPlayback']);
    final playable = json.containsKey('playable')
        ? _asBool(json['playable'])
        : playback != 'download-only';
    return CinemaFilm(
      id: id,
      title: _asString(json['title']),
      path: _asString(json['path']),
      kind: _asString(json['kind']),
      series: _asString(json['series']),
      season: _asInt(json['season']),
      episode: _asInt(json['episode']),
      year: _asInt(json['year']),
      size: _asInt(json['size']),
      playable: playable,
      mime: _asString(json['mime']),
      probeStatus: _asString(json['probeStatus']),
      browserPlayback: playback.isEmpty
          ? (playable ? 'unverified-direct' : 'download-only')
          : playback,
      container: _asString(json['container']),
      videoCodec: _asString(json['videoCodec']),
      audioCodec: _asString(json['audioCodec']),
      durationSeconds: _asDouble(json['durationSeconds']),
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      position: _asDouble(json['position']),
      duration: _asDouble(json['duration']),
      completed: _asBool(json['completed']),
      capturedAt: _asString(json['capturedAt']),
      overview: _asString(json['overview']),
      rating: _asDouble(json['rating']),
      metadataSource: _asString(json['metadataSource']),
      posterURL: _asString(json['posterURL']),
    );
  }

  CinemaFilm withTitle(String value) => CinemaFilm(
    id: id,
    title: value,
    path: path,
    kind: kind,
    series: series,
    season: season,
    episode: episode,
    year: year,
    size: size,
    playable: playable,
    mime: mime,
    probeStatus: probeStatus,
    browserPlayback: browserPlayback,
    container: container,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    durationSeconds: durationSeconds,
    width: width,
    height: height,
    position: position,
    duration: duration,
    completed: completed,
    capturedAt: capturedAt,
    overview: overview,
    rating: rating,
    metadataSource: metadataSource,
    posterURL: posterURL,
  );

  CinemaFilm withProgress({
    required double newPosition,
    required double newDuration,
    required bool isCompleted,
  }) => CinemaFilm(
    id: id,
    title: title,
    path: path,
    kind: kind,
    series: series,
    season: season,
    episode: episode,
    year: year,
    size: size,
    playable: playable,
    mime: mime,
    probeStatus: probeStatus,
    browserPlayback: browserPlayback,
    container: container,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    durationSeconds: durationSeconds,
    width: width,
    height: height,
    position: newPosition,
    duration: newDuration,
    completed: isCompleted,
    capturedAt: capturedAt,
    overview: overview,
    rating: rating,
    metadataSource: metadataSource,
    posterURL: posterURL,
  );
}

class TMDBCandidate {
  const TMDBCandidate({
    required this.id,
    required this.kind,
    required this.title,
    this.year = '',
    this.overview = '',
    this.rating = 0,
    this.posterURL = '',
  });

  final int id;
  final String kind;
  final String title;
  final String year;
  final String overview;
  final double rating;
  final String posterURL;

  factory TMDBCandidate.fromJson(MediaJson json) {
    final id = _asInt(json['id']);
    final title = _asString(json['title']).trim();
    if (id < 1 || title.isEmpty) {
      throw const FormatException('Invalid TMDB candidate');
    }
    return TMDBCandidate(
      id: id,
      kind: _asString(json['kind']),
      title: title,
      year: _asString(json['year']),
      overview: _asString(json['overview']),
      rating: _asDouble(json['rating']),
      posterURL: _asString(json['posterURL']),
    );
  }
}

class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;

  bool contains(Duration position) => position >= start && position <= end;
}

List<SubtitleCue> parseWebVtt(String source) {
  Duration? timestamp(String value) {
    final match = RegExp(r'^(?:(\d{1,2}):)?(\d{2}):(\d{2})[.,](\d{3})$')
        .firstMatch(value.trim());
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
    final milliseconds = int.tryParse(match.group(4) ?? '') ?? 0;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  final normalized = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceFirst('\uFEFF', '');
  final blocks = normalized.split(RegExp(r'\n\s*\n'));
  final cues = <SubtitleCue>[];
  for (final block in blocks) {
    final lines = block.split('\n').map((line) => line.trimRight()).toList();
    final timingIndex = lines.indexWhere((line) => line.contains('-->'));
    if (timingIndex < 0) continue;
    final sides = lines[timingIndex].split('-->');
    if (sides.length != 2) continue;
    final startToken = sides[0].trim();
    final endToken = sides[1].trim().split(RegExp(r'\s+')).first;
    final start = timestamp(startToken);
    final end = timestamp(endToken);
    final text = lines.skip(timingIndex + 1).join('\n').trim();
    if (start == null || end == null || end <= start || text.isEmpty) continue;
    cues.add(SubtitleCue(start: start, end: end, text: text));
  }
  return List.unmodifiable(cues);
}
