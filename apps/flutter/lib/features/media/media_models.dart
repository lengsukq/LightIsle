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

/// One audio track of a film container, as reported by the server's ffprobe
/// (transcode stack). [audioIndex] is the relative index used to request a
/// specific audio mapping in an HLS session.
class CinemaAudioTrack {
  const CinemaAudioTrack({
    required this.streamIndex,
    required this.audioIndex,
    this.codec = '',
    this.language = '',
    this.title = '',
    this.channels = 0,
  });

  final int streamIndex;
  final int audioIndex;
  final String codec;
  final String language;
  final String title;
  final int channels;

  String get label {
    final parts = <String>[
      if (title.isNotEmpty) title else if (language.isNotEmpty) language else '音轨 ${audioIndex + 1}',
      if (codec.isNotEmpty) codec,
      if (channels > 0) '$channels ch',
    ];
    return parts.join(' · ');
  }

  factory CinemaAudioTrack.fromJson(MediaJson json) => CinemaAudioTrack(
        streamIndex: (json['streamIndex'] as num?)?.toInt() ?? 0,
        audioIndex: (json['audioIndex'] as num?)?.toInt() ?? 0,
        codec: (json['codec'] as String?) ?? '',
        language: (json['language'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        channels: (json['channels'] as num?)?.toInt() ?? 0,
      );
}

/// One subtitle track of a film container. Bitmap subtitles report
/// [extractable] = false and cannot be rendered by the text pipeline.
class CinemaSubtitleTrack {
  const CinemaSubtitleTrack({
    required this.streamIndex,
    this.codec = '',
    this.language = '',
    this.title = '',
    required this.extractable,
  });

  final int streamIndex;
  final String codec;
  final String language;
  final String title;
  final bool extractable;

  String get label {
    final languageLabel = switch (language) {
      'chi' || 'zh' => '中文',
      'eng' || 'en' => '英文',
      '' => '内嵌',
      _ => language,
    };
    final parts = <String>[
      '内嵌 $languageLabel',
      if (codec.isNotEmpty) codec,
    ];
    return '${parts.join(' · ')}（样式简化）';
  }

  factory CinemaSubtitleTrack.fromJson(MediaJson json) => CinemaSubtitleTrack(
        streamIndex: (json['streamIndex'] as num?)?.toInt() ?? 0,
        codec: (json['codec'] as String?) ?? '',
        language: (json['language'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        extractable: (json['extractable'] as bool?) ?? false,
      );
}

/// Audio and text-subtitle listing for one film.
class CinemaTrackInfo {
  const CinemaTrackInfo({
    required this.audio,
    required this.subtitles,
  });

  final List<CinemaAudioTrack> audio;
  final List<CinemaSubtitleTrack> subtitles;

  factory CinemaTrackInfo.fromJson(MediaJson json) {
    final audio = <CinemaAudioTrack>[];
    final subtitles = <CinemaSubtitleTrack>[];
    final rawAudio = json['audio'];
    if (rawAudio is List) {
      for (final item in rawAudio) {
        if (item is Map) {
          audio.add(
            CinemaAudioTrack.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final rawSubtitles = json['subtitles'];
    if (rawSubtitles is List) {
      for (final item in rawSubtitles) {
        if (item is Map) {
          subtitles.add(
            CinemaSubtitleTrack.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return CinemaTrackInfo(audio: audio, subtitles: subtitles);
  }
}

/// One HLS transcode session started by the server.
class CinemaHlsSession {
  const CinemaHlsSession({
    required this.sessionId,
    required this.start,
    required this.profile,
    required this.audioTrack,
    required this.ready,
    this.quality = 'source',
  });

  final String sessionId;
  final double start;
  final String profile;
  final int audioTrack;
  final bool ready;
  final String quality;

  factory CinemaHlsSession.fromJson(MediaJson json) => CinemaHlsSession(
        sessionId: (json['sessionId'] as String?) ?? '',
        start: (json['start'] as num?)?.toDouble() ?? 0,
        profile: (json['profile'] as String?) ?? 'remux',
        audioTrack: (json['audioTrack'] as num?)?.toInt() ?? 0,
        ready: (json['ready'] as bool?) ?? false,
        quality: (json['quality'] as String?) ?? 'source',
      );
}

/// A filename-derived show aggregated by the server.
class CinemaSeriesInfo {
  const CinemaSeriesInfo({
    required this.id,
    required this.name,
    this.tmdbId = 0,
    this.overview = '',
    this.posterURL = '',
    required this.episodeCount,
    required this.watchedCount,
    this.year = 0,
    this.nextFilmId = 0,
    this.nextTitle = '',
    this.inProgress = false,
    this.position = 0,
    this.duration = 0,
  });

  final int id;
  final String name;
  final int tmdbId;
  final String overview;
  final String posterURL;
  final int episodeCount;
  final int watchedCount;
  final int year;
  final int nextFilmId;
  final String nextTitle;
  final bool inProgress;
  final double position;
  final double duration;

  bool get hasContinue => nextFilmId > 0;

  factory CinemaSeriesInfo.fromJson(MediaJson json) => CinemaSeriesInfo(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: (json['name'] as String?) ?? '',
        tmdbId: (json['tmdbId'] as num?)?.toInt() ?? 0,
        overview: (json['overview'] as String?) ?? '',
        posterURL: (json['posterURL'] as String?) ?? '',
        episodeCount: (json['episodeCount'] as num?)?.toInt() ?? 0,
        watchedCount: (json['watchedCount'] as num?)?.toInt() ?? 0,
        year: (json['year'] as num?)?.toInt() ?? 0,
        nextFilmId: (json['nextFilmId'] as num?)?.toInt() ?? 0,
        nextTitle: (json['nextTitle'] as String?) ?? '',
        inProgress: (json['inProgress'] as bool?) ?? false,
        position: (json['position'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
      );
}

/// Server-side TMDB scrape state for the administrator task view.
class CinemaScrapeStatus {
  const CinemaScrapeStatus({
    required this.running,
    required this.processed,
    required this.matched,
    required this.tmdbConfigured,
  });

  final bool running;
  final int processed;
  final int matched;
  final bool tmdbConfigured;

  factory CinemaScrapeStatus.fromJson(MediaJson json) => CinemaScrapeStatus(
        running: (json['running'] as bool?) ?? false,
        processed: (json['processed'] as num?)?.toInt() ?? 0,
        matched: (json['matched'] as num?)?.toInt() ?? 0,
        tmdbConfigured: (json['tmdbConfigured'] as bool?) ?? false,
      );
}
