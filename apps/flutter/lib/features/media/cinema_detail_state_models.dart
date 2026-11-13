import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'cinema_metadata_repository.dart';
import 'dlna_cast.dart';
import 'media_models.dart';

/// Encapsulates active video controller, HLS transcoding session, and playback
/// transport runtime state for [CinemaDetailDialog].
class CinemaPlaybackSessionState {
  VideoPlayerController? controller;
  bool loading = true;
  bool busy = false;
  bool closing = false;
  bool completionSaved = false;
  bool hasQueuedFinalSave = false;

  // HLS playback starts at its requested offset; saved positions remain
  // relative to the original file.
  CinemaHlsSession? hlsSession;
  CinemaTrackInfo? tracks;
  bool transcodeStarting = false;
  bool directLocalActive = false;

  double playbackSpeed = 1.0;
  double volume = 1.0;
  double? seekDraft;
  double lastNonZeroVolume = 1.0;

  String? playbackMessage;
  String? progressSaveMessage;

  // Coalesce high-frequency video tick notifications so non-timeline UI only
  // rebuilds when transport state or active subtitle text actually changes.
  bool lastPlaying = false;
  bool lastInitialized = false;
  int lastDisplayedSecond = -1;
  String? lastSubtitleText;

  bool consumeShouldRebuild(
    VideoPlayerValue value, {
    required bool playerOnly,
    required String? subtitleText,
  }) {
    final second = value.position.inSeconds;
    final dirty =
        value.isPlaying != lastPlaying ||
        value.isInitialized != lastInitialized ||
        subtitleText != lastSubtitleText ||
        (!playerOnly && second != lastDisplayedSecond);
    lastPlaying = value.isPlaying;
    lastInitialized = value.isInitialized;
    lastSubtitleText = subtitleText;
    lastDisplayedSecond = second;
    return dirty;
  }

  bool get isVideoReady {
    final active = controller;
    return active != null &&
        active.value.isInitialized &&
        !active.value.hasError;
  }
}

/// Encapsulates active subtitle cues, language selection, typography, and sync
/// offset state for [CinemaDetailDialog].
class CinemaSubtitleViewState {
  String captionLanguage = 'off';
  List<SubtitleCue> cues = const [];
  int generation = 0;
  double fontSize = 17.0;
  double offsetSeconds = 0.0;
  String? message;
}

/// Encapsulates same-directory episode playlist discovery and auto-advance
/// state for [CinemaDetailDialog].
class CinemaDirectoryPlaylistState {
  List<CinemaFilm> directoryFilms = const [];
  bool loading = false;
  bool loaded = false;
  int generation = 0;
  bool autoPlayNext = false;
  bool nextEpisodeBusy = false;
}

/// Encapsulates NFO import, TMDB search/match, and Douban search/match state
/// for [CinemaDetailDialog].
class CinemaMetadataMatchState {
  CinemaMetadataMatchState({required String initialQuery})
    : tmdbQueryController = TextEditingController(text: initialQuery);

  final TextEditingController tmdbTokenController = TextEditingController();
  final TextEditingController tmdbQueryController;

  bool busy = false;
  bool tmdbSearching = false;
  bool tmdbMatching = false;
  bool doubanSearching = false;
  int generation = 0;

  List<TMDBCandidate> tmdbCandidates = const [];
  List<DoubanCandidate> doubanCandidates = const [];

  String? message;
  String? tmdbMessage;
  String? doubanMessage;
  bool isError = false;

  bool get isAnyBusy =>
      busy || tmdbSearching || tmdbMatching || doubanSearching;

  void dispose() {
    generation++;
    tmdbTokenController.clear();
    tmdbTokenController.dispose();
    tmdbQueryController.dispose();
  }
}

/// Encapsulates player overlay chrome visibility, draggable dock position,
/// fullscreen flags, and active modal sheets for [CinemaDetailDialog].
class CinemaPlayerChromeState {
  final FocusNode playerFocusNode = FocusNode();
  bool visible = true;
  bool dockManuallyCollapsed = false;
  Offset dockDragOffset = Offset.zero;
  bool fillScreen = false;
  bool windowFullscreen = false;
  bool showPlayerDetails = false;
  bool showPlaylistSheet = false;
  Timer? hideTimer;

  bool get isDockMoved =>
      dockDragOffset.dx.abs() > 2 || dockDragOffset.dy.abs() > 2;

  void cancelTimer() {
    hideTimer?.cancel();
    hideTimer = null;
  }

  void dispose() {
    cancelTimer();
    playerFocusNode.dispose();
  }
}

/// Encapsulates temporary shortcut HUD feedback and hold-to-fast-forward timer
/// state for [CinemaDetailDialog].
class CinemaShortcutHudState {
  IconData? icon;
  String? label;
  Timer? hideTimer;
  Timer? rightHoldTimer;
  bool rightKeyDown = false;
  bool rightHold2xActive = false;
  double speedBeforeHold = 1.0;

  void cancelTimers() {
    hideTimer?.cancel();
    hideTimer = null;
    rightHoldTimer?.cancel();
    rightHoldTimer = null;
  }
}

/// Encapsulates DLNA casting, offline caching progress, and file action busy
/// flags for [CinemaDetailDialog].
class CinemaExternalActionState {
  bool mediaActionBusy = false;
  double? offlineProgress;
  DlnaCastSession? castSession;
}
