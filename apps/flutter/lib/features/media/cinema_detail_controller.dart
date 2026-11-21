import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/native_video_bridge.dart';
import 'android_pip_session.dart';
import 'cinema_decode_preference.dart';
import 'cinema_detail_player_progress.dart';
import 'cinema_detail_player_state.dart';
import 'cinema_detail_state_models.dart';
import 'cinema_episode_navigator.dart';
import 'cinema_metadata_repository.dart';
import 'cinema_pip_lifecycle_policy.dart';
import 'cinema_progress_save_queue.dart';
import 'cinema_subtitle_repository.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'shared_video_player_controls.dart';

/// Owns runtime playback, subtitle, playlist, metadata matching, chrome,
/// shortcut HUD, and PiP state for [CinemaDetailDialog] without holding a
/// [BuildContext].
class CinemaDetailController extends ChangeNotifier {
  CinemaDetailController({
    required this.api,
    required CinemaFilm initialFilm,
    required this.isAdmin,
    this.accountName = '',
    this.playlist = const [],
    required this.onRename,
    required this.onProgressUpdated,
    this.playerOnly = false,
    this.onAutoAdvanceNextEpisode,
  }) : film = initialFilm,
       metaMatch = CinemaMetadataMatchState(initialQuery: initialFilm.title) {
    playbackEngine = CinemaPlaybackEngine(this);
    progressCoordinator = CinemaProgressCoordinator(this);
    pip = _createPipSession();
  }

  static double? sessionVolume;
  static double? sessionSpeed;

  static const qualityTiers = <(String, String, int)>[
    ('1080', '1080P', 1080),
    ('720', '720P', 720),
    ('480', '480P', 480),
  ];

  static const supportedSpeeds = <double>[0.75, 1.0, 1.25, 1.5, 2.0];

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final List<CinemaFilm> playlist;
  final Future<CinemaFilm> Function(CinemaFilm film) onRename;
  final ValueChanged<CinemaFilm> onProgressUpdated;
  final bool playerOnly;
  final Future<void> Function()? onAutoAdvanceNextEpisode;

  CinemaFilm film;
  final CinemaPlaybackSessionState playback = CinemaPlaybackSessionState();
  final CinemaSubtitleViewState subtitles = CinemaSubtitleViewState();
  final CinemaDirectoryPlaylistState playlistState =
      CinemaDirectoryPlaylistState();
  final CinemaMetadataMatchState metaMatch;
  final CinemaPlayerChromeState chrome = CinemaPlayerChromeState();
  final CinemaShortcutHudState hud = CinemaShortcutHudState();
  final CinemaExternalActionState externalActions = CinemaExternalActionState();
  final CinemaProgressSaveQueue progressQueue = CinemaProgressSaveQueue();

  late final AndroidPipSession pip;
  late final CinemaPlaybackEngine playbackEngine;
  late final CinemaProgressCoordinator progressCoordinator;

  bool _disposed = false;
  bool get isDisposed => _disposed;
  bool get isActive => !_disposed;

  CinemaMetadataRepository get metadataRepository =>
      CinemaMetadataRepository(api);
  CinemaSubtitleRepository get subtitleRepository =>
      CinemaSubtitleRepository(api);

  void notify() {
    if (!_disposed) notifyListeners();
  }

  void mutate(VoidCallback fn) {
    fn();
    notify();
  }

  void initialize() {
    pip.attach();
    unawaited(playbackEngine.restorePlaybackSpeed());
    unawaited(restorePlaybackVolume());
    unawaited(restoreAutoplayNext());
    unawaited(CinemaDecodePreference.load());
    unawaited(playbackEngine.loadDetailAndPlayer());
  }

  AndroidPipSession _createPipSession() {
    return AndroidPipSession(
      onChanged: notify,
      onTimeout: () {
        if (_disposed) return;
        mutate(() {
          playback.playbackMessage = '未确认进入画中画，请在设备设置中检查权限。';
        });
        if (CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(
          WidgetsBinding.instance.lifecycleState,
        )) {
          unawaited(queueProgressSave(force: true));
          unawaited(playback.controller?.pause());
        }
      },
      onError: (error) {
        if (_disposed) return;
        mutate(
          () => playback.playbackMessage = error == null
              ? '无法进入画中画，请检查系统权限。'
              : mediaErrorLabel(error),
        );
      },
      onExit: () {
        if (!_disposed &&
            CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(
              WidgetsBinding.instance.lifecycleState,
            )) {
          unawaited(queueProgressSave(force: true));
          unawaited(playback.controller?.pause());
        }
      },
    );
  }

  void handleAppLifecycleState(AppLifecycleState state) {
    if (CinemaPipLifecyclePolicy.shouldPauseOnLifecycle(
      state,
      pipRequested: pip.requested,
      pipActive: pip.active,
    )) {
      unawaited(queueProgressSave(force: true));
      final video = playback.controller;
      if (video?.value.isPlaying == true) unawaited(video!.pause());
    }
  }

  @override
  void dispose() {
    hud.cancelTimers();
    chrome.dispose();
    if (chrome.windowFullscreen) {
      unawaited(exitNativeFullscreen());
    }
    final castSession = externalActions.castSession;
    if (castSession != null) {
      unawaited(castSession.stop().catchError((Object _) {}));
      externalActions.castSession = null;
    }
    pip.dispose();
    playlistState.generation++;
    metaMatch.dispose();
    subtitles.generation++;
    if (!playback.hasQueuedFinalSave) {
      playback.hasQueuedFinalSave = true;
      unawaited(queueProgressSave(force: true));
    }
    final video = playback.controller;
    video?.removeListener(playbackEngine.onVideoChanged);
    video?.dispose();
    _disposed = true;
    super.dispose();
  }

  // --- Playback & progress delegation ---

  String get currentQualityKey => playbackEngine.currentQualityKey;

  List<(String, String)> qualityOptions() => playbackEngine.qualityOptions();

  double get originalPlaybackSeconds => playbackEngine.originalPlaybackSeconds;

  double get knownFilmDuration => playbackEngine.knownFilmDuration;

  double get originalPlaybackDuration =>
      playbackEngine.originalPlaybackDuration;

  Future<void> loadDetailAndPlayer({
    double? seekTo,
    bool forceDirect = false,
    bool fallbackFromNoFfmpeg = false,
  }) => playbackEngine.loadDetailAndPlayer(
    seekTo: seekTo,
    forceDirect: forceDirect,
    fallbackFromNoFfmpeg: fallbackFromNoFfmpeg,
  );

  Future<void> startTranscode({
    double? start,
    int audio = 0,
    String quality = 'source',
    bool allowDirectFallback = true,
  }) => playbackEngine.startTranscode(
    start: start,
    audio: audio,
    quality: quality,
    allowDirectFallback: allowDirectFallback,
  );

  Future<void> switchAudio(int audioIndex) =>
      playbackEngine.switchAudio(audioIndex);

  Future<void> switchQuality(String quality) =>
      playbackEngine.switchQuality(quality);

  Future<void> setPlaybackSpeed(double speed) =>
      playbackEngine.setPlaybackSpeed(speed);

  Future<void> seekAbsolute(double absoluteSeconds) =>
      playbackEngine.seekAbsolute(absoluteSeconds);

  Future<void> seekRelative(double deltaSeconds) =>
      playbackEngine.seekRelative(deltaSeconds);

  Future<void> restartFromBeginning() => playbackEngine.restartFromBeginning();

  Future<void> togglePlayPause({bool revealChromeAfter = false}) async {
    final video = playback.controller;
    if (video == null) return;
    if (video.value.isPlaying) {
      await video.pause();
      unawaited(queueProgressSave(force: true));
    } else {
      await video.play();
    }
    if (revealChromeAfter) revealChrome();
    notify();
  }

  void setSeekDraft(double? value, {bool reveal = false}) {
    if (reveal) revealChrome();
    mutate(() => playback.seekDraft = value);
  }

  Future<bool> queueProgressSave({
    bool force = false,
    bool completed = false,
  }) =>
      progressCoordinator.queueProgressSave(force: force, completed: completed);

  Future<void> markWatched({required bool completed}) =>
      progressCoordinator.markWatched(completed: completed);

  // --- Chrome, fullscreen, dock & PiP ---

  bool shouldShowPlayerChrome(bool videoReady) {
    final video = playback.controller;
    return !chrome.dockManuallyCollapsed &&
        (chrome.visible ||
            playback.loading ||
            !videoReady ||
            video == null ||
            !video.value.isPlaying ||
            chrome.showPlayerDetails ||
            chrome.showPlaylistSheet ||
            playback.progressSaveMessage != null ||
            externalActions.offlineProgress != null);
  }

  void revealChrome() {
    if (_disposed) return;
    if (!chrome.visible) {
      mutate(() => chrome.visible = true);
    }
    scheduleChromeHide();
  }

  void scheduleChromeHide() {
    chrome.cancelTimer();
    final isTestBinding = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('Test');
    if (isTestBinding) return;
    chrome.hideTimer = Timer(const Duration(milliseconds: 3400), () {
      if (_disposed) return;
      final video = playback.controller;
      if (video != null &&
          video.value.isInitialized &&
          video.value.isPlaying &&
          !chrome.showPlayerDetails &&
          !chrome.showPlaylistSheet &&
          playback.seekDraft == null &&
          playback.progressSaveMessage == null &&
          externalActions.offlineProgress == null) {
        mutate(() => chrome.visible = false);
      }
    });
  }

  void toggleChrome() {
    if (_disposed) return;
    if (chrome.visible) {
      chrome.cancelTimer();
      mutate(() => chrome.visible = false);
    } else {
      revealChrome();
    }
  }

  void setShowPlayerDetails(bool opening, {bool pauseWhenOpening = false}) {
    if (opening && pauseWhenOpening) {
      unawaited(playback.controller?.pause());
      unawaited(queueProgressSave(force: true));
    }
    mutate(() => chrome.showPlayerDetails = opening);
  }

  void setShowPlaylistSheet(bool visible) {
    mutate(() => chrome.showPlaylistSheet = visible);
  }

  void togglePlaylistSheet() {
    final opening = !chrome.showPlaylistSheet;
    if (opening) {
      revealChrome();
      if (!playlistState.loaded) {
        unawaited(refreshDirectoryPlaylist());
      }
    }
    mutate(() {
      chrome.showPlaylistSheet = opening;
      if (opening) chrome.showPlayerDetails = false;
    });
  }

  void toggleFillScreen() {
    revealChrome();
    mutate(() => chrome.fillScreen = !chrome.fillScreen);
  }

  void updateDockDragOffset(Offset delta, Size screenSize) {
    revealChrome();
    final maxDx = ((screenSize.width - 320) / 2).clamp(0.0, screenSize.width);
    final minDy = -(screenSize.height - 160).clamp(0.0, screenSize.height);
    mutate(() {
      chrome.dockDragOffset = Offset(
        (chrome.dockDragOffset.dx + delta.dx).clamp(-maxDx, maxDx),
        (chrome.dockDragOffset.dy + delta.dy).clamp(minDy, 12.0),
      );
    });
  }

  void resetDockDragOffset({bool reveal = false}) {
    if (reveal) revealChrome();
    mutate(() => chrome.dockDragOffset = Offset.zero);
  }

  void collapseDock() {
    chrome.cancelTimer();
    mutate(() {
      chrome.dockManuallyCollapsed = true;
      chrome.visible = false;
    });
  }

  void restoreDock() {
    mutate(() => chrome.dockManuallyCollapsed = false);
    revealChrome();
  }

  Future<void> toggleFullscreen() async {
    final next = !chrome.windowFullscreen;
    mutate(() => chrome.windowFullscreen = next);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      try {
        await NativeVideoBridge.toggleFullScreen();
      } catch (_) {
        // Fallback cleanly if channel is unavailable in tests.
      }
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        await SystemChrome.setEnabledSystemUIMode(
          next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } catch (_) {
        // System UI mode toggling is best-effort on restricted test bindings.
      }
    }
  }

  Future<void> exitNativeFullscreen() async {
    if (!chrome.windowFullscreen) return;
    chrome.windowFullscreen = false;
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      try {
        await NativeVideoBridge.exitFullScreen();
      } catch (_) {
        // Window channel may already be detached on teardown.
      }
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (_) {
        // System UI restoration is best-effort on teardown.
      }
    }
  }

  Future<void> enterPiP() async {
    if (playback.controller?.value.isInitialized == true) {
      await pip.enter();
    }
  }

  // --- Volume & shortcut HUD ---

  void showShortcutHud(IconData icon, String label, {bool persistent = false}) {
    hud.hideTimer?.cancel();
    mutate(() {
      hud.icon = icon;
      hud.label = label;
    });
    if (persistent) return;
    hud.hideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_disposed) return;
      mutate(() {
        hud.icon = null;
        hud.label = null;
      });
    });
  }

  Future<void> restorePlaybackVolume() async {
    final cached = sessionVolume;
    if (cached != null) {
      playback.volume = cached;
      if (cached > 0) playback.lastNonZeroVolume = cached;
      await playback.controller?.setVolume(cached);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble('lightisle_cinema_volume');
      if (_disposed || saved == null || !saved.isFinite) return;
      final clamped = saved.clamp(0.0, 1.0).toDouble();
      sessionVolume = clamped;
      mutate(() {
        playback.volume = clamped;
        if (clamped > 0) playback.lastNonZeroVolume = clamped;
      });
      await playback.controller?.setVolume(clamped);
    } catch (_) {
      // Missing test/desktop prefs must never block playback.
    }
  }

  Future<void> setPlayerVolume(double value, {bool showHud = false}) async {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    sessionVolume = clamped;
    mutate(() {
      playback.volume = clamped;
      if (clamped > 0) playback.lastNonZeroVolume = clamped;
    });
    await playback.controller?.setVolume(clamped);
    if (showHud) {
      final pct = (clamped * 100).round();
      showShortcutHud(
        clamped == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        clamped == 0 ? '已静音' : '音量 $pct%',
      );
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lightisle_cinema_volume', clamped);
    } catch (_) {}
  }

  Future<void> toggleMuteShortcut() async {
    final video = playback.controller;
    final current = video?.value.volume ?? playback.volume;
    if (current > 0.001) {
      playback.lastNonZeroVolume = current;
      await setPlayerVolume(0, showHud: true);
    } else {
      final restore = playback.lastNonZeroVolume > 0.01
          ? playback.lastNonZeroVolume
          : 1.0;
      await setPlayerVolume(restore, showHud: true);
    }
  }

  void startRightArrowHold() {
    hud.rightKeyDown = true;
    hud.rightHold2xActive = false;
    hud.rightHoldTimer?.cancel();
    hud.rightHoldTimer = Timer(
      const Duration(milliseconds: 280),
      enterHold2xFastForward,
    );
  }

  void enterHold2xFastForward() {
    final video = playback.controller;
    if (!hud.rightKeyDown ||
        hud.rightHold2xActive ||
        video == null ||
        !video.value.isInitialized) {
      return;
    }
    hud.speedBeforeHold = playback.playbackSpeed;
    hud.rightHold2xActive = true;
    unawaited(video.setPlaybackSpeed(2.0));
    showShortcutHud(Icons.fast_forward_rounded, '2.0x 倍速播放中', persistent: true);
  }

  void finishRightArrowHoldOrSeek() {
    hud.rightHoldTimer?.cancel();
    hud.rightHoldTimer = null;
    final wasHold = hud.rightHold2xActive;
    hud.rightKeyDown = false;
    hud.rightHold2xActive = false;
    final video = playback.controller;
    if (wasHold) {
      if (video != null && video.value.isInitialized) {
        unawaited(video.setPlaybackSpeed(hud.speedBeforeHold));
      }
      showShortcutHud(
        Icons.speed_rounded,
        '已恢复 ${SharedVideoPlayerStyle.formatSpeedLabel(hud.speedBeforeHold)}',
      );
      return;
    }
    revealChrome();
    unawaited(seekRelative(10));
    showShortcutHud(Icons.forward_10_rounded, '快进 10 秒');
  }

  // --- Subtitles ---

  SubtitleCue? get activeCue {
    final position = playback.controller?.value.position;
    if (position == null) return null;
    final hlsStartMs = ((playback.hlsSession?.start ?? 0) * 1000).round();
    final adjusted =
        position +
        Duration(milliseconds: hlsStartMs) -
        Duration(milliseconds: (subtitles.offsetSeconds * 1000).round());
    for (final cue in subtitles.cues) {
      if (cue.contains(adjusted)) return cue;
    }
    return null;
  }

  void setSubtitleFontSize(double size) {
    mutate(() => subtitles.fontSize = size);
  }

  void adjustSubtitleOffset(String arg) {
    mutate(() {
      if (arg == 'reset') {
        subtitles.offsetSeconds = 0.0;
      } else {
        final delta = double.tryParse(arg) ?? 0.0;
        subtitles.offsetSeconds = (subtitles.offsetSeconds + delta).clamp(
          -10.0,
          10.0,
        );
      }
      final sign = subtitles.offsetSeconds >= 0 ? '+' : '';
      subtitles.message = subtitles.offsetSeconds == 0.0
          ? '字幕时间偏移已重置'
          : '字幕时间偏移：$sign${subtitles.offsetSeconds.toStringAsFixed(1)} 秒';
    });
  }

  void handleCaptionMenuSelection(String value) {
    if (value == 'import') {
      unawaited(importLocalSubtitles());
    } else if (value.startsWith('size:')) {
      final parsed = double.tryParse(value.substring(5));
      if (parsed != null) setSubtitleFontSize(parsed);
    } else if (value.startsWith('offset:')) {
      adjustSubtitleOffset(value.substring(7));
    } else if (value != 'local') {
      unawaited(loadSubtitles(value));
    }
  }

  bool _subtitleRequestCurrent(
    int generation,
    int filmId,
    String rootIdentity,
  ) =>
      !_disposed &&
      generation == subtitles.generation &&
      film.id == filmId &&
      (api.selectedRoot?.identity ?? 'default') == rootIdentity;

  Future<void> loadSubtitles(String language) async {
    final generation = ++subtitles.generation;
    final filmId = film.id;
    final rootIdentity = api.selectedRoot?.identity ?? 'default';
    mutate(() {
      subtitles.captionLanguage = language;
      subtitles.message = null;
      subtitles.cues = const [];
    });
    if (language == 'off') return;
    try {
      final cues = await subtitleRepository.load(filmId, language);
      if (!_subtitleRequestCurrent(generation, filmId, rootIdentity)) return;
      mutate(() {
        subtitles.cues = cues;
        subtitles.message = cues.isEmpty ? '字幕文件没有可显示的内容。' : null;
      });
    } catch (error) {
      if (!_subtitleRequestCurrent(generation, filmId, rootIdentity)) return;
      mutate(() {
        subtitles.message =
            error is LightIsleApiException && error.code == 'film_not_found'
            ? '未找到匹配字幕，或此影片已被移除。'
            : mediaErrorLabel(error);
      });
    }
  }

  /// An optional, one-session subtitle source from this device.
  Future<void> importLocalSubtitles() async {
    final generation = ++subtitles.generation;
    final filmId = film.id;
    final rootIdentity = api.selectedRoot?.identity ?? 'default';
    try {
      final selected = await subtitleRepository.importLocal();
      if (selected == null ||
          !_subtitleRequestCurrent(generation, filmId, rootIdentity)) {
        return;
      }
      mutate(() {
        subtitles.captionLanguage = 'local';
        subtitles.cues = selected.cues;
        subtitles.message = '已加载：${selected.name}（仅本次播放）';
      });
    } catch (error) {
      if (_subtitleRequestCurrent(generation, filmId, rootIdentity)) {
        mutate(() => subtitles.message = '无法加载字幕：${mediaErrorLabel(error)}');
      }
    }
  }

  // --- Playlist & film mutations ---

  List<CinemaFilm> get sameDirectoryFilms =>
      CinemaEpisodeNavigator.buildSameDirectoryPlaylist(film, <CinemaFilm>[
        ...playlist,
        ...playlistState.directoryFilms,
      ]);

  int get currentPlaylistIndex {
    final items = sameDirectoryFilms;
    final idx = items.indexWhere((item) => item.id == film.id);
    return idx < 0 ? 0 : idx;
  }

  CinemaFilm? get previousPlaylistFilm {
    final items = sameDirectoryFilms;
    final idx = currentPlaylistIndex;
    return idx > 0 ? items[idx - 1] : null;
  }

  CinemaFilm? get nextPlaylistFilm {
    final items = sameDirectoryFilms;
    final idx = currentPlaylistIndex;
    return idx >= 0 && idx + 1 < items.length ? items[idx + 1] : null;
  }

  Future<void> restoreAutoplayNext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_disposed) {
        mutate(
          () => playlistState.autoPlayNext =
              prefs.getBool('lightisle_cinema_autoplay_next') ?? false,
        );
      }
    } catch (_) {
      // Opt-in defaults to off when preferences cannot load.
    }
  }

  Future<void> setAutoplayNext(bool value) async {
    mutate(() => playlistState.autoPlayNext = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('lightisle_cinema_autoplay_next', value);
    } catch (_) {
      // Session selection still works.
    }
  }

  Future<void> refreshDirectoryPlaylist({bool force = false}) async {
    if (playback.closing ||
        playlistState.loading ||
        (!force && playlistState.loaded)) {
      return;
    }
    final generation = ++playlistState.generation;
    final currentID = film.id;
    final currentRoot = api.selectedRoot?.identity ?? 'default';
    bool stillCurrent() =>
        !_disposed &&
        !playback.closing &&
        generation == playlistState.generation &&
        film.id == currentID &&
        (api.selectedRoot?.identity ?? 'default') == currentRoot;
    mutate(() => playlistState.loading = true);
    try {
      final items = await CinemaEpisodeNavigator(api).loadSameDirectory(film);
      if (!stillCurrent()) return;
      mutate(() {
        playlistState.directoryFilms = items;
        playlistState.loaded = true;
      });
    } catch (_) {
      if (stillCurrent()) {
        mutate(() => playlistState.loaded = true);
      }
    } finally {
      if (stillCurrent()) {
        mutate(() => playlistState.loading = false);
      }
    }
  }

  Future<CinemaFilm?> findNextEpisode() {
    return CinemaEpisodeNavigator(api).findNext(film);
  }

  Future<void> renameFilm() async {
    mutate(() => playback.busy = true);
    try {
      final updated = await onRename(film);
      if (!_disposed) mutate(() => film = updated);
    } catch (error) {
      if (!_disposed) {
        mutate(() => playback.playbackMessage = mediaErrorLabel(error));
      }
    } finally {
      if (!_disposed) mutate(() => playback.busy = false);
    }
  }
}
